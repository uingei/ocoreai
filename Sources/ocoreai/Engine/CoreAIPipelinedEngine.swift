// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
// Provenance: derived from coreai-models InferenceEngines/CoreAIPipelinedEngine.swift
//   (introduced 2026-08-13, ocoreai 558afab; upstream file created in #146 0bc7bc3, 2026-08-14).
//   Absorbed: #169 413947a (GPU sampler error propagation).
//   Absorbed: #170 031cb54 pipelined constrained sampling (runConstrainedCompletion,
//     tokenizeJumpForward, _encodeStepForConstrainedGeneration, maxJumpForwardTokens)
//     — 2026-08-20 ocoreai main; encode routed via _CoreAIEncodeHelpers.encodeWithStates;
//     PipelineGate omitted (sequential loop, ≤1 encode in flight).
//   ocoreai 2026-08-18 audit: no derived-file drift otherwise; see ~/wiki.

#if canImport(CoreAI)
import CoreAI
import Foundation
import Metal
import MetalPerformanceShaders
import Synchronization
import os
import Tokenizers

// MARK: - Timing

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    let (secs, attoseconds) = duration.components
    return (Double(secs) + Double(attoseconds) / 1e18) * 1000.0
}

// MARK: - Constants

/// Maximum number of in-flight pipeline stages. Shared by the backpressure gate
/// and all buffer rotation logic to guarantee no two concurrent stages alias
/// the same memory.
private let pipelineDepth = 3
private let averageExpectedPromptSize = 256
private let temperatureTolerance: Double = 0.001

/// MPSNDArray enforces 64-byte row-stride alignment on backing buffers.
private let minimumMPSNDArrayBufferSize = 64

// MARK: - Core AI Pipelined Engine (Public Wrapper)

/// GPU-pipelined inference engine using Core AI's encode API.
///
/// Key features:
/// - Non-blocking GPU encoding via `InferenceFunction.encode`
/// - GPU-direct token sampling (argmax/topK) via MPSGraph compute shaders
/// - Pipeline-depth-matched buffer rotation for CPU/GPU overlap
/// - Growing KV cache with pipelined expansion
/// - All tensors are owned MTLBuffers — Core AI never allocates/frees them
@available(macOS 27.0, iOS 27.0, *)
final class CoreAIPipelinedEngine: InferenceEngine, ConstrainedGenerationCapable, Sendable {
    typealias ConfigType = InternalModelConfig

    nonisolated(unsafe) private var engine: EngineImpl

    /// Token history for implicit prefix caching. Marked nonisolated(unsafe) because
    /// mutations are serialized by the generation lifecycle: generate() awaits any prior
    /// Task before starting, and the forwarding `async let` only appends tokens while
    /// runCompletion holds the engine lock. No concurrent writes are possible when the
    /// cancel-and-await contract is upheld.
    nonisolated(unsafe) private var history = TokenHistory()
    nonisolated(unsafe) private(set) var lastPrefixHitCount: Int = 0
    private let engineInUse = Atomic<Bool>(false)

    /// Cached constrained-generation session (xgrammar compiler + matcher), keyed by
    /// JSON schema. Empty slot on checkout — concurrent callers get independent sessions.
    private let _constrainedSessionCache = Mutex<ConstrainedSessionHandle?>(nil)
    let config: InternalModelConfig

    // Generation lifecycle
    private let _activeToken = Mutex<GenerationToken?>(nil)
    private let _generationTask = Mutex<Task<Void, Never>?>(nil)

    var isBusy: Bool { _activeToken.withLock { $0 != nil } }

    var processedTokenCount: Int { engine.processedTokenCount }

    init(
        config: InternalModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions = EngineOptions()
    ) async throws {
        let engine = try await EngineImpl(
            config: config, preparedModel: preparedModel, options: options)
        self.engine = engine
        self.config = config
    }

    /// Atomically claim exclusive use of `engine`.
    ///
    /// Throws `InferenceRuntimeError.invalidState` when another caller holds the lock,
    /// eliminating fatalError from the hot path.
    private func acquireEngine() throws {
        let (exchanged, _) = engineInUse.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiring
        )
        guard exchanged else {
            throw InferenceRuntimeError.invalidState("CoreAI pipelined engine already in use")
        }
    }

    /// Try to claim exclusive use of `engine` without trapping.
    ///
    /// Returns `true` if the caller now holds it (and must call `releaseEngine`), `false` if
    /// another caller holds it.
    private func tryAcquireEngine() -> Bool {
        let (exchanged, _) = engineInUse.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiring
        )
        return exchanged
    }

    private func releaseEngine() {
        engineInUse.store(false, ordering: .releasing)
    }

    func generate(
        with input: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> GenerationSequence {
        if inferenceOptions.includeLogits {
            throw InferenceRuntimeError.invalidArgument(
                "CoreAI pipelined engine does not support logits (GPU-side sampling). "
                    + "Use a sequential engine for constrained generation or evaluation."
            )
        }
        if inferenceOptions.forcedContinuation != nil {
            throw InferenceRuntimeError.invalidArgument(
                "CoreAI pipelined engine does not support forcedContinuation (GPU-side sampling). "
                    + "Use a sequential engine for evaluation."
            )
        }

        // Serialize: if a prior generation is still winding down (GPU drain),
        // cancel it and wait for the engine slot to be released.
        if let priorTask = _generationTask.withLock({ $0 }) {
            _activeToken.withLock { $0?.cancel() }
            await priorTask.value
        }

        let maxTokens = inferenceOptions.maxTokens
        let stopReasonStore = StopReasonStore()
        let (base, outputContinuation) =
            AsyncThrowingStream<InferenceOutput, any Error>.makeStream()

        let token = GenerationToken()
        _activeToken.withLock { $0 = token }

        let task = Task {
            do {
                try self.acquireEngine()
            } catch {
                stopReasonStore.set(.error)
                outputContinuation.finish(throwing: error)
                return
            }
            defer {
                self.releaseEngine()
                // Only clear if this generation still owns both slots
                if self._activeToken.withLock({ $0 === token }) {
                    self._activeToken.withLock { $0 = nil }
                    self._generationTask.withLock { $0 = nil }
                }
            }
            do {
                let (tokenStream, tokenContinuation) =
                    AsyncThrowingStream<InferenceEngine.TokenId, any Error>.makeStream()

                outputContinuation.onTermination = { @Sendable _ in
                    tokenContinuation.finish()
                }

                // Implicit prefix caching: resolve input against history
                var (commonPrefix, resolvedNewTokens) = self.history.resolve(input: input)
                self.lastPrefixHitCount = commonPrefix

                // Detect TRUE divergence before backup (tokens actually differ)
                let isDivergence = commonPrefix < input.count && commonPrefix < self.history.count

                // Ensure at least 1 token for prefill (seeds the decode loop).
                // Back up by 1 if the entire input is cached.
                if resolvedNewTokens.isEmpty && commonPrefix > 0 {
                    commonPrefix -= 1
                    resolvedNewTokens = input[commonPrefix...]
                }

                if isDivergence {
                    // Tokens differ — full reset (partial rewind corrupts buffer rotation)
                    await self.engine.computeStream.currentWorkCompleted()
                    self.engine.reset()
                    self.history.clear()
                    resolvedNewTokens = input[...]
                    commonPrefix = 0
                } else if self.engine.hasNonTruncatableStates {
                    // Hybrid model: recurrent state can't be partially rewound.
                    // Full reset and replay the entire prompt.
                    if commonPrefix < self.engine.processedTokenCount {
                        await self.engine.computeStream.currentWorkCompleted()
                        self.engine.reset()
                        self.history.clear()
                        resolvedNewTokens = input[...]
                        commonPrefix = 0
                    }
                } else if commonPrefix < self.engine.processedTokenCount {
                    // Pure extension — partial rewind (buffer phase preserved)
                    await self.engine.computeStream.currentWorkCompleted()
                    self.engine.processedTokenCount = commonPrefix
                    self.engine.step = commonPrefix
                    self.history.truncate(to: commonPrefix)
                }

                let newTokens = Array(resolvedNewTokens)

                async let forwarding: Void = {
                    do {
                        for try await token in tokenStream {
                            self.history.append(token)
                            let result = outputContinuation.yield(InferenceOutput(tokenId: token))
                            if case .terminated = result {
                                tokenContinuation.finish()
                                break
                            }
                        }
                    } catch {
                        outputContinuation.finish(throwing: error)
                    }
                }()

                // Track prefill tokens BEFORE runCompletion — the forwarding loop
                // concurrently appends generated tokens, so prefill must come first.
                if !newTokens.isEmpty {
                    self.history.append(contentsOf: newTokens[...])
                }

                try await self.engine.runCompletion(
                    prompt: newTokens,
                    sampler: samplingConfiguration,
                    maxTokens: maxTokens,
                    yieldingTo: tokenContinuation
                )

                tokenContinuation.finish()
                await forwarding
                stopReasonStore.setIfUnset(.maxTokens)
                outputContinuation.finish()
            } catch is CancellationError {
                stopReasonStore.set(.cancelled)
                outputContinuation.finish()
            } catch {
                stopReasonStore.set(.error)
                outputContinuation.finish(throwing: error)
            }
        }
        _generationTask.withLock { $0 = task }
        return GenerationSequence(base: base, stopReasonStore: stopReasonStore)
    }

    /// Wait for any in-flight generate() Task to return the engine.
    ///
    /// Throws `InferenceRuntimeError.invalidState` after 5 s of spinning
    /// so callers (reset/cancel) get a proper error instead of a trap.
    private func drain() throws {
        var attempts = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while engineInUse.load(ordering: .acquiring) {
            attempts += 1
            guard ContinuousClock.now < deadline else {
                throw InferenceRuntimeError.invalidState(
                    "CoreAI pipelined engine did not release after 5 s — tokenSequence Task may be stuck (spun \(attempts) times)"
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func cancel() async throws {
        let task: Task<Void, Never>? = _generationTask.withLock { task in
            task?.cancel()
            defer { task = nil }
            return task
        }
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
        await task?.value
    }

    func reset(to tokenIndex: Int) async throws {
        precondition(
            tokenIndex >= 0 && tokenIndex <= processedTokenCount,
            "reset(to: \(tokenIndex)) out of range [0, \(processedTokenCount)]")
        if tokenIndex == 0 {
            // Full reset: cancel + drain + clear everything
            _activeToken.withLock {
                $0?.cancel()
                $0 = nil
            }
            _generationTask.withLock {
                $0?.cancel()
                $0 = nil
            }
            try drain()
            await engine.computeStream.currentWorkCompleted()
            guard tryAcquireEngine() else { return }
            defer { releaseEngine() }
            engine.reset()
            history.clear()
        } else {
            // Partial reset: wait for generation to finish naturally, then rewind counter.
            // Do NOT cancel — cancelling corrupts the pipeline's double-buffer state.
            // The KV cache is valid up to processedTokenCount after natural completion.
            if engine.hasNonTruncatableStates {
                throw InferenceRuntimeError.invalidState(
                    "Partial reset is not supported for hybrid models with recurrent state. "
                        + "Use reset(to: 0) and replay the prefix.")
            }
            try drain()
            await engine.computeStream.currentWorkCompleted()
            guard tryAcquireEngine() else { return }
            defer { releaseEngine() }
            engine.processedTokenCount = tokenIndex
            engine.step = tokenIndex
            history.truncate(to: tokenIndex)
        }
    }

    func cleanup() async throws {
        let cleanupSpan = InstrumentsProfiler.beginCleanup(engine: "CoreAI-Pipelined")
        if tryAcquireEngine() {
            let stream = engine.computeStream
            releaseEngine()
            await stream.currentWorkCompleted()
        }
        cleanupSpan.end()
    }

    func validateSamplingStrategy(_ config: SamplingConfiguration) throws {
        // All sampling configurations are now supported by the GPU sampler:
        // greedy, temperature, topK, topP, and minP.
    }

    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {
        try acquireEngine()
        defer { releaseEngine() }
        try await engine.performWarmup(queryLength: queryLength, samplingConfig: sampling)
    }

    /// Semi-pipelined GPU-accelerated constrained generation loop.
    ///
    /// Unlike `generate()` which fires steps asynchronously, each token is
    /// awaited before the next bitmask is computed (grammar state is sequential),
    /// but inference overlaps with bitmask computation within each step.
    ///
    /// The handle is returned to `ConstrainedGenerationCapable`'s internal cache
    /// automatically when the Task completes, even on error or cancellation.
    func generateConstrained(
        with input: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        maxTokens: Int,
        session: ConstrainedSessionHandle
    ) throws -> InferenceTokenSequence {
        if _generationTask.withLock({ $0 }) != nil || engineInUse.load(ordering: .acquiring) {
            throw InferenceRuntimeError.invalidState(
                "generateConstrained called while a prior generation is still in flight — caller must drain first"
            )
        }

        let (stream, continuation) = AsyncThrowingStream<Int32, Error>.makeStream()
        let stopReasonStore = StopReasonStore()

        let isCancelled = Atomic<Bool>(false)
        continuation.onTermination = { _ in
            isCancelled.store(true, ordering: .relaxed)
        }

        let token = GenerationToken()
        _activeToken.withLock { $0 = token }

        let task = Task {
            do {
                try self.acquireEngine()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            defer {
                self.releaseEngine()
                self.storeConstrainedSessionForReuse(session)
                if self._activeToken.withLock({ $0 === token }) {
                    self._activeToken.withLock { $0 = nil }
                    self._generationTask.withLock { $0 = nil }
                }
            }
            self.engine.reset()
            self.history.clear()
            do {
                try await self.engine.runConstrainedCompletion(
                    prompt: input,
                    sampler: samplingConfiguration,
                    session: session,
                    maxTokens: maxTokens,
                    isCancelled: isCancelled,
                    yieldingTo: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        _generationTask.withLock { $0 = task }

        return InferenceTokenSequence(stream: stream, stopReasonStore: stopReasonStore)
    }

    // MARK: - Constrained Session Cache

    /// Check out a constrained session from the cache, or create a new one.
    /// The cache slot is emptied — concurrent calls get independent sessions.
    func getOrCreateConstrainedSession(
        jsonSchema: String,
        tokenizer: any Tokenizer,
        vocabSize: Int,
        stopTokenIds: [Int32]?
    ) throws -> ConstrainedSessionHandle {
        if let cached: ConstrainedSessionHandle = _constrainedSessionCache.withLock({ cache in
            guard let box = cache, box.schema == jsonSchema else {
                cache = nil
                return nil
            }
            cache = nil
            return box
        }) {
            cached.reset()
            return cached
        }
        let session = try ConstrainedGenerationSession(
            jsonSchema: jsonSchema,
            tokenizer: tokenizer,
            vocabSize: vocabSize,
            stopTokenIds: stopTokenIds
        )
        return ConstrainedSessionHandle(session: session, tokenizer: tokenizer)
    }

    /// Return a session box to the cache for reuse by the next call.
    func storeConstrainedSessionForReuse(_ box: ConstrainedSessionHandle) {
        _constrainedSessionCache.withLock { $0 = box }
    }
}

// MARK: - Pipeline Depth Gate

/// Bounds in-flight encode calls so MPSGraph's per-encode scratch
/// (sized by the graph's max shape — multiple GB on large models) can't accumulate.
///
/// Without this, the decode loop submits encodes (~220/s) faster than the
/// sampler callback drains them (~70/s); depth grows until
/// `MPSCommandBufferImageCache` fails to allocate another private MTLBuffer.
///
/// Capacity matches `pipelineDepth` — covers {logits encode + sampler commit + optional KV-cache grow};
/// deeper queues only cost memory.
///
/// Class, not actor: `release()` runs synchronously from the Metal callback —
/// an actor would force `Task { await release() }` with ordering ambiguity.
/// `internal` (not `private`) so `PipelineGateTests` can reach it.
@available(macOS 27.0, iOS 27.0, *)
final class PipelineGate: Sendable {
    private struct State: Sendable {
        var inFlight: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Take a slot; suspend if all slots are busy.
    func acquire() async {
        // Fast path: take a slot without suspending.
        let takenImmediately = state.withLock { state -> Bool in
            guard state.inFlight < capacity else { return false }
            state.inFlight += 1
            return true
        }
        if takenImmediately { return }

        // Slow path: enqueue a waiter. Re-check under the lock in case a slot
        // opened between the fast path and now.
        await withCheckedContinuation { cont in
            let runImmediately = state.withLock { state -> Bool in
                if state.inFlight < capacity {
                    state.inFlight += 1
                    return true
                }
                state.waiters.append(cont)
                return false
            }
            if runImmediately { cont.resume() }
        }
    }

    /// Give back a slot. Called from the sampler's GPU-completion callback on a
    /// Metal callback thread; resumes any pending waiter (slot transferred
    /// directly without decrementing `inFlight`) or decrements the count.
    ///
    /// The waiter is resumed *outside* the lock so a rescheduled task can't
    /// re-enter `acquire` while we still hold it.
    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if !state.waiters.isEmpty {
                // Slot transferred to the woken waiter — inFlight count unchanged.
                return state.waiters.removeFirst()
            }
            state.inFlight -= 1
            return nil
        }
        waiter?.resume()
    }

    // Test-only introspection. Kept as underscored names to discourage
    // production use; exercised by PipelineGateTests.

    var _inFlightForTesting: Int {
        state.withLock { $0.inFlight }
    }

    var _waitersForTesting: Int {
        state.withLock { $0.waiters.count }
    }
}

// MARK: - Engine Implementation

@available(macOS 27.0, iOS 27.0, *)
private struct EngineImpl: ~Copyable {
    var vocabSize: Int { config.vocabSize }

    let config: InternalModelConfig
    let options: EngineOptions
    let function: InferenceFunction

    // Prefill chunks run here when the asset has this graph. It produces no logits, so
    // the last prompt token still goes through `function` to seed sampling.
    let prefillFunction: InferenceFunction?
    /// Chunk width used when a prefill graph is present: `config.prefillChunkSize` capped
    /// at the context width. Applies only to the prefill-graph path.
    let prefillMaxQueryLength: Int
    let pipelineQueue: MTLCommandQueue
    let computeStream: ComputeStream
    let device: MTLDevice

    // Descriptor metadata
    let inputIdsName: String
    let positionIdsName: String
    let keyCacheName: String
    let valueCacheName: String
    let logitsOutputName: String
    let keyCacheScalarType: NDArray.ScalarType
    let valueCacheScalarType: NDArray.ScalarType

    // Base descriptors for shape resolution (preferredStrides, not contiguous)
    let inputIdsBaseDesc: NDArrayDescriptor
    let positionIdsBaseDesc: NDArrayDescriptor
    let logitsBaseDesc: NDArrayDescriptor

    // Owned MTLBuffers
    var inputTokensBuffer: MTLBuffer
    var cachePositionBuffers: [MTLBuffer]
    var decodeOutputBuffers: [MTLBuffer]
    var decodeLogitsBuffers: [MTLBuffer]

    // KV cache — reuses CoreAIKVCache protocol from KVCache+CoreAI.swift
    var kvCache: any CoreAIKVCache

    // Linear attention state bindings for hybrid models (nil for pure transformer models).
    // States 0/1 are KV cache; additional states handled by handler.
    var additionalStates: FixedMTLBufferState?
    var hasNonTruncatableStates: Bool

    // Logits — reuses GrowingLogitsBuffer from TensorStorage+CoreAI.swift
    var logits: GrowingLogitsBuffer

    // GPU sampler — reuses MPSGraphSampler from MPSGraphSamplers.swift
    var cachedSampler: (any MPSGraphSampler)?
    var cachedSamplerTemperature: Double?

    // GPU repetition penalty state (coreai-models #176). Non-nil only when the
    // active sampling configuration has repetitionPenalty > 1.0 on the pipelined
    // engine. Owns a per-depth ring of Float16 penalty buffers read by the
    // composite sampler's penalty stage.
    var penaltyState: RepetitionPenaltyGPUState?

    // State
    var processedTokenCount: Int = 0
    var step: Int = 0

    // Backpressure gate — see PipelineGate doc-comment for the failure mode it prevents.
    // Capacity matches pipeline depth: {encode logits + sampler commit + optional KV-cache grow} in flight.
    let inFlightGate = PipelineGate(capacity: pipelineDepth)

    // MARK: - Init

    init(
        config: InternalModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions = EngineOptions()
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw InferenceRuntimeError.genericError("Failed to create Metal device")
        }

        let model = preparedModel.model

        // Get function descriptor
        guard let descriptor = model.functionDescriptor(for: config.function) else {
            throw InferenceRuntimeError.genericError(
                "Cannot find function '\(config.function)' in model")
        }

        // Validate: 2 inputs, 1+ output, 2 states
        guard descriptor.inputNames.count == 2 else {
            throw InferenceRuntimeError.invalidInputType(
                "Expected 2 inputs, got \(descriptor.inputNames.count): \(descriptor.inputNames)")
        }
        guard descriptor.outputNames.count >= 1 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 1 output, got \(descriptor.outputNames.count)")
        }
        guard descriptor.stateNames.count >= 2 && descriptor.stateNames.count <= 4 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected 2–4 states, got \(descriptor.stateNames.count): \(descriptor.stateNames)"
            )
        }

        // Classify states using the shared factory logic
        let classified = StateHandlerFactory.classifyStates(
            descriptor: descriptor, stateKinds: nil, verbose: descriptor.stateNames.count > 2)

        // Find the growing KV pair (first two states with .kvCache kind)
        let growingNames = classified.filter { $0.kind == .kvCache }.map(\.name)
        guard growingNames.count >= 2 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 2 growing KV cache states, found \(growingNames.count) "
                    + "in: \(classified.map { "\($0.name)=\($0.kind.rawValue)" })")
        }
        let keyCacheName = growingNames[0]
        let valueCacheName = growingNames[1]

        // Fixed states: everything that isn't the primary growing KV pair
        let fixedNames =
            classified
            .filter { $0.kind == .slidingCache || $0.kind == .fixed }
            .map(\.name)
        // Additional growing states beyond the primary pair
        let extraGrowingNames = Array(growingNames.dropFirst(2))

        // Extract names
        let inputIdsName = descriptor.inputNames[0]
        let positionIdsName = descriptor.inputNames[1]
        let logitsOutputName = descriptor.outputNames[0]

        // Extract state descriptors for KV cache shape/type
        guard case .ndArray(let keyCacheDesc) = descriptor.stateDescriptor(of: keyCacheName),
            case .ndArray(let valueCacheDesc) = descriptor.stateDescriptor(of: valueCacheName)
        else {
            throw InferenceRuntimeError.invalidOutputType("Cannot get KV cache state descriptors")
        }

        // Extract input descriptors
        guard case .ndArray(let inputIdsDesc) = descriptor.inputDescriptor(of: inputIdsName) else {
            throw InferenceRuntimeError.invalidInputType(
                "Cannot get descriptor for '\(inputIdsName)'")
        }
        guard case .ndArray(let posIdsDesc) = descriptor.inputDescriptor(of: positionIdsName) else {
            throw InferenceRuntimeError.invalidInputType(
                "Cannot get descriptor for '\(positionIdsName)'")
        }

        // Extract logits descriptor
        guard case .ndArray(let logitsDesc) = descriptor.outputDescriptor(of: logitsOutputName)
        else {
            throw InferenceRuntimeError.invalidOutputType(
                "Cannot get descriptor for '\(logitsOutputName)'")
        }
        guard logitsDesc.scalarType == .float16 else {
            throw InferenceRuntimeError.unsupportedLogitsType(
                "Only float16 logits supported, got \(logitsDesc.scalarType)")
        }

        // Allocate inputTokens MTLBuffer
        let inputTokensByteCount = config.maxContextLength * inputIdsDesc.scalarType.byteSize
        guard
            let inputTokensBuf = device.makeBuffer(
                length: inputTokensByteCount, options: .storageModeShared)
        else {
            throw InferenceRuntimeError.bufferAllocationFailed(
                "inputTokens (\(inputTokensByteCount) bytes)")
        }

        // Allocate pipeline-depth-matched cache position buffers
        let cachePosSize = config.maxContextLength * posIdsDesc.scalarType.byteSize
        var cachePosBuffers: [MTLBuffer] = []
        for _ in 0 ..< pipelineDepth {
            guard let buf = device.makeBuffer(length: cachePosSize, options: .storageModeShared)
            else {
                throw InferenceRuntimeError.bufferAllocationFailed(
                    "cachePositions (\(cachePosSize) bytes)")
            }
            cachePosBuffers.append(buf)
        }

        // Pre-populate cache positions with [0, 1, ..., maxCtx-1]
        for buf in cachePosBuffers {
            let ptr = buf.contents().bindMemory(to: Int32.self, capacity: config.maxContextLength)
            for i in 0 ..< config.maxContextLength {
                ptr[i] = Int32(i)
            }
        }

        // Allocate pipeline-depth-matched decode output buffers (sampler writes next token)
        var decodeOutBuffers: [MTLBuffer] = []
        for _ in 0 ..< pipelineDepth {
            let decodeOutSize = max(minimumMPSNDArrayBufferSize, MemoryLayout<Int32>.size)
            guard let buf = device.makeBuffer(length: decodeOutSize, options: .storageModeShared)
            else {
                throw InferenceRuntimeError.bufferAllocationFailed(
                    "decodeOutputBuffer (\(decodeOutSize) bytes)")
            }
            decodeOutBuffers.append(buf)
        }

        // Allocate pipeline-depth-matched decode logits buffers (inference writes logits for decode)
        let decodeLogitsSize = config.vocabSize * MemoryLayout<UInt16>.size
        var decodeLogBufs: [MTLBuffer] = []
        for _ in 0 ..< pipelineDepth {
            guard let buf = device.makeBuffer(length: decodeLogitsSize, options: .storageModeShared)
            else {
                throw InferenceRuntimeError.bufferAllocationFailed(
                    "decodeLogitsBuffer (\(decodeLogitsSize) bytes)")
            }
            decodeLogBufs.append(buf)
        }

        // Create KV cache using factory — pass original descriptors (with -1 dynamic dims intact)
        // so the factory can correctly detect growing vs static support via isDynamicKVCache().
        let kvCacheLocal = try KVCacheFactory.make(
            options: options,
            device: device,
            keyReqs: keyCacheDesc,
            valueReqs: valueCacheDesc,
            maxContextLength: config.maxContextLength
        )

        let resolvedSize = options.resolvedKVCacheSize(maxContextLength: config.maxContextLength)

        // Allocate fixed-size buffers for additional persistent states (sliding caches, hybrid states).
        var additionalStatesLocal: FixedMTLBufferState? = nil
        let allFixedNames = fixedNames + extraGrowingNames  // extra growing get resolved to max size
        if !allFixedNames.isEmpty {
            var extraStates: [(name: String, descriptor: NDArrayDescriptor)] = []
            for name in allFixedNames {
                guard case .ndArray(let desc) = descriptor.stateDescriptor(of: name) else {
                    throw InferenceRuntimeError.invalidOutputType(
                        "Cannot get descriptor for persistent state '\(name)'")
                }
                // Resolve dynamic dims to max for any extra growing states
                let resolved =
                    desc.shape.contains(where: { $0 < 0 })
                    ? desc.resolvingDynamicDimensions(
                        desc.shape.map { $0 < 0 ? config.maxContextLength : $0 })
                    : desc
                extraStates.append((name, resolved))
            }
            additionalStatesLocal = try FixedMTLBufferState(states: extraStates, device: device)
        }

        // Without a prefill graph, prefill runs through `function` exactly as before.
        let prefillMaxQueryLen = prefillQueryLength(
            prefillChunkSize: config.prefillChunkSize,
            maxContextLength: config.maxContextLength)
        let prefillFn = try loadPrefillGraph(
            from: model, matching: descriptor, mainName: config.function)
        if prefillFn != nil {
            CLILogger.log("Found '\(prefillGraphFunctionName)' graph — prefill skips the LM head")
        }

        // Create growing logits buffer (reuses TensorStorage+CoreAI.swift).
        // With a prefill graph, `function` only ever sees one token, so a prompt-sized
        // logits buffer — hundreds of MB at large vocabularies — would go unused.
        let logitsRef = try GrowingLogitsBuffer(
            device: device,
            descriptor: descriptor,
            name: logitsOutputName,
            vocabSize: config.vocabSize,
            maxCapacity: config.maxContextLength,
            initialCapacity: prefillLogitsInitialCapacity(
                hasPrefillGraph: prefillFn != nil,
                averagePromptSize: averageExpectedPromptSize
            )
        )

        // Load inference function
        guard let fn = try model.loadFunction(named: config.function) else {
            throw InferenceRuntimeError.genericError(
                "Cannot load function '\(config.function)'")
        }

        guard let pipelineQueue = device.makeCommandQueue() else {
            throw InferenceRuntimeError.invalidState(
                "Failed to allocate MTLCommandQueue for CoreAIPipelinedEngine")
        }
        pipelineQueue.label = "CoreAIPipelinedEngine.queue"
        let computeStream = ComputeStream(commandQueue: pipelineQueue)

        // Assign
        self.config = config
        self.options = options
        self.function = fn
        self.prefillFunction = prefillFn
        self.prefillMaxQueryLength = prefillMaxQueryLen
        self.pipelineQueue = pipelineQueue
        self.computeStream = computeStream
        self.device = device
        self.inputIdsName = inputIdsName
        self.positionIdsName = positionIdsName
        self.keyCacheName = keyCacheName
        self.valueCacheName = valueCacheName
        self.logitsOutputName = logitsOutputName
        self.keyCacheScalarType = keyCacheDesc.scalarType
        self.valueCacheScalarType = valueCacheDesc.scalarType
        self.inputIdsBaseDesc = inputIdsDesc
        self.positionIdsBaseDesc = posIdsDesc
        self.logitsBaseDesc = logitsDesc
        self.inputTokensBuffer = inputTokensBuf
        self.cachePositionBuffers = cachePosBuffers
        self.decodeOutputBuffers = decodeOutBuffers
        self.decodeLogitsBuffers = decodeLogBufs
        self.kvCache = kvCacheLocal
        self.additionalStates = additionalStatesLocal
        self.hasNonTruncatableStates = classified.contains(where: { $0.kind == .fixed })
        self.logits = logitsRef
        self.cachedSampler = nil
        self.cachedSamplerTemperature = nil
        self.penaltyState = nil

    }

    // MARK: - Sampler

    private mutating func getOrCreateSampler(for config: SamplingConfiguration) throws
        -> any MPSGraphSampler
    {
        let config = config.normalized()
        let temperature = config.temperature

        if let existingSampler = cachedSampler, let existingTemp = cachedSamplerTemperature {
            /* temperature is Double? */
            let existingIsGreedy = (existingTemp ?? 0) == 0
            let requestedIsGreedy = temperature == 0

            if existingIsGreedy != requestedIsGreedy {
                throw InferenceRuntimeError.genericError(
                    "Sampling configuration changed mid-generation. Call reset() first.")
            }
            if !existingIsGreedy && !requestedIsGreedy
                && abs(existingTemp - (temperature ?? 0)) > temperatureTolerance
            {
                throw InferenceRuntimeError.genericError(
                    "Temperature changed mid-generation (\(existingTemp) -> \(temperature)). Call reset() first."
                )
            }
            return existingSampler
        }

        // Create penalized sampler if repetition penalty is configured
        // (aligned with upstream coreai-models CoreAIPipelinedEngine.#176).
        // needsRepetitionPenalty implies repetitionPenalty != nil (InferenceStubs:155-160),
        // so `if let` here is behavior-preserving.
        if config.needsRepetitionPenalty, let penalty = config.repetitionPenalty {
            if config.temperature == 0 {
                throw InferenceRuntimeError.invalidArgument(
                    "Repetition penalty with greedy sampling is not supported on pipelined engine. "
                        + "Use temperature > 0, or use a sequential engine.")
            }
            if penaltyState == nil {
                penaltyState = try RepetitionPenaltyGPUState(
                    device: device,
                    vocabSize: self.config.vocabSize,
                    pipelineDepth: pipelineDepth,
                    penalty: penalty,
                    windowSize: config.repetitionPenaltyWindow
                )
            }
        }

        let newSampler = try MPSGraphSamplerFactory.makeSampler(
            device: device,
            vocabSize: self.config.vocabSize,
            config: config
        )
        cachedSampler = newSampler
        cachedSamplerTemperature = temperature
        return newSampler
    }

    // MARK: - Core Encode Step

    /// Encodes inference + GPU sampling for one step.
    ///
    /// 1. Construct RawView/MutableRawView from MTLBuffers with current shapes
    /// 2. Encode to ComputeStream (non-blocking)
    /// 3. withMetal3Queue: encode GPU argmax/topK (writes to rotating decodeOutputBuffers)
    /// 4. Callback yields token
    private mutating func _encodeNextStepGPU(
        tokens: some Collection<Int32>,
        gpuSampler: any MPSGraphSampler,
        yieldingTo continuation: AsyncThrowingStream<InferenceEngine.TokenId, Error>.Continuation
    ) async throws {
        let currentStep = processedTokenCount

        let actualTokenCount = tokens.isEmpty ? 1 : tokens.count
        let queryLength = actualTokenCount

        defer {
            processedTokenCount += actualTokenCount
            step += 1
        }

        let encodeStepID = InstrumentsProfiler.beginCustomInterval(
            name: "CoreAIPipelinedEncodeNextStep",
            details: "step=\(currentStep) qLen=\(queryLength)"
        )

        // PrepareStep: write tokens + build views
        let prepareSpan = InstrumentsProfiler.beginPrepareStep(
            step: currentStep, operation: "write+build", engine: "CoreAI-Pipelined")

        // Prefill: write tokens at their natural position so this step's region is disjoint
        // from any prior chunk's region still in-flight on the GPU (encode holds a live
        // MTLBuffer reference; no encodeWriteOperands serialization available in Core AI).
        // Decode: token is in the previous step's decodeOutputBuffer — no CPU write needed.
        let tokenByteOffset = processedTokenCount * MemoryLayout<Int32>.size
        if !tokens.isEmpty {
            let ptr = inputTokensBuffer.contents().bindMemory(
                to: Int32.self, capacity: processedTokenCount + queryLength)
            for (i, token) in tokens.enumerated() {
                ptr[processedTokenCount + i] = token
            }
        }

        // Select cache position buffer for this step (pipeline-depth-matched rotation)
        let cachePosBuffer = cachePositionBuffers[step % pipelineDepth]
        let posLength = processedTokenCount + queryLength

        // Build Inputs as AsyncValue (from MTLBuffers)
        let tokenShape = [1, queryLength]
        let tokenStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tokenShape)
        let tokenValue: InferenceFunction.AsyncValue
        if tokens.isEmpty {
            // Decode: read input token from previous step's decode output buffer
            tokenValue = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: decodeOutputBuffers[(step + pipelineDepth - 1) % pipelineDepth],
                byteOffset: 0,
                scalarType: .int32,
                shape: tokenShape,
                strides: tokenStrides
            )
        } else {
            // Prefill: read from inputTokensBuffer at natural position
            tokenValue = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: inputTokensBuffer,
                byteOffset: tokenByteOffset,
                scalarType: .int32,
                shape: tokenShape,
                strides: tokenStrides
            )
        }
        let posShape = [1, posLength]
        let posStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: posShape)
        let posValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: cachePosBuffer,
            byteOffset: 0,
            scalarType: .int32,
            shape: posShape,
            strides: posStrides
        )

        let asyncInputs: [String: InferenceFunction.AsyncValue] = [
            inputIdsName: tokenValue,
            positionIdsName: posValue,
        ]

        // Build States as AsyncMutableValue (KV cache, in-place update)
        let keyBuffer = kvCache.keyBinding.metalBuffer
        let keyShape = kvCache.keyBinding.layout.shape
        let keyStrides = kvCache.keyBinding.layout.strides
        var keyState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: keyBuffer,
            byteOffset: 0,
            scalarType: keyCacheScalarType,
            shape: keyShape,
            strides: keyStrides
        )
        let valBuffer = kvCache.valueBinding.metalBuffer
        let valShape = kvCache.valueBinding.layout.shape
        let valStrides = kvCache.valueBinding.layout.strides
        var valState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: valBuffer,
            byteOffset: 0,
            scalarType: valueCacheScalarType,
            shape: valShape,
            strides: valStrides
        )

        // Build Output as AsyncMutableValue (logits)
        // Decode uses per-step rotating buffer; prefill uses the shared growing buffer.
        let logitsOutputBuffer =
            tokens.isEmpty ? decodeLogitsBuffers[step % pipelineDepth] : logits.metalBuffer
        let logitsShape = [1, queryLength, vocabSize]
        let logitsStrides = try resolvedStrides(descriptor: logitsBaseDesc, shape: logitsShape)

        prepareSpan.end()

        // Backpressure: cap outstanding encode calls
        await inFlightGate.acquire()

        // Encode inference using the public encode() API.
        // This commits + uses runAfterSyncPoint (no stream wait) — enables true pipelining.
        let logitsSpan = InstrumentsProfiler.beginLogitsInference(
            step: currentStep, tokens: queryLength, engine: "CoreAI-Pipelined")

        // Swift 6 lifetime safety: AsyncMutableViews uses @lifetime(self: &mutableValue)
        // on insert(), so all inserts + consume must be in the same scope without branching.
        try _CoreAIEncodeHelpers.encodeWithStates(
            function: function, inputs: asyncInputs,
            keyState: &keyState, keyCacheName: keyCacheName,
            valState: &valState, valueCacheName: valueCacheName,
            additionalStates: additionalStates,
            logitsBuffer: logitsOutputBuffer, logitsName: logitsOutputName,
            logitsShape: logitsShape, logitsStrides: logitsStrides,
            computeStream: computeStream)
        logitsSpan.end()

        // GPU sampling via Metal queue
        let localGPUSampler = gpuSampler
        let outputBuffer = decodeOutputBuffers[step % pipelineDepth]
        let samplerLogitsBuffer =
            tokens.isEmpty ? decodeLogitsBuffers[step % pipelineDepth] : logits.metalBuffer
        let logitsOffset = (actualTokenCount - 1) * vocabSize * MemoryLayout<UInt16>.size
        let samplerStrategy = gpuSampler is MPSGraphArgmaxSampler ? "GPU-argmax" : "GPU-composite"
        let samplerTemperature = cachedSamplerTemperature ?? 0.0

        let sampleSpan = InstrumentsProfiler.beginSampleEncoding(
            step: currentStep, strategy: samplerStrategy, temperature: samplerTemperature)

        do {
            let queue = pipelineQueue
            let localInFlightGate = inFlightGate
            let localPenaltyState = penaltyState
            let completionCallback: (Int32, Error?) -> Void = { nextToken, error in
                // Update penalty state BEFORE releasing the gate, so the next
                // buffer(forStep:) call in this slot sees the token.
                localPenaltyState?.recordToken(nextToken)
                // Release the pipeline slot acquired before encode. Happens on
                // Metal's callback thread — PipelineGate.release() is thread-safe.
                localInFlightGate.release()
                if let error {
                    // GPU sampler failure: surface it in the generation stream
                    // instead of silently emitting token id 0 (coreai-models #169).
                    continuation.finish(throwing: error)
                    return
                }
                InstrumentsProfiler.endCustomInterval(
                    name: "CoreAIPipelinedEncodeNextStep",
                    signpostID: encodeStepID,
                    details: "token=\(nextToken)"
                )
                continuation.yield(nextToken)
            }

            if queryLength == 1 {
                // Penalty-aware path for decode steps when the sampler was compiled
                // with the repetition-penalty stage (aligned with upstream #176).
                if let state = localPenaltyState,
                    let compositeSampler = localGPUSampler as? MPSGraphCompositeSampler,
                    compositeSampler.penaltyEnabled
                {
                    let penaltyBuf = state.buffer(forStep: currentStep)
                    compositeSampler.encode(
                        to: queue,
                        logitsBuffer: samplerLogitsBuffer,
                        logitsOffset: logitsOffset,
                        penaltyBuffer: penaltyBuf,
                        outputBuffer: outputBuffer,
                        outputOffset: 0,
                        completion: completionCallback
                    )
                    sampleSpan.end()
                    return
                }
                do {
                    try localGPUSampler.encode(
                        to: queue,
                        logitsBuffer: samplerLogitsBuffer,
                        logitsOffset: logitsOffset,
                        outputBuffer: outputBuffer,
                        outputOffset: 0,
                        completion: completionCallback
                    )
                } catch {
                    // Synchronous throw (e.g. graph/compilation failure): release
                    // the pipeline gate acquired above and propagate to the stream.
                    localInFlightGate.release()
                    continuation.finish(throwing: error)
                    sampleSpan.end()
                    return
                }
            } else {
                localGPUSampler.encodeWithSlice(
                    to: queue,
                    logitsBuffer: samplerLogitsBuffer,
                    queryLength: actualTokenCount,
                    outputBuffer: outputBuffer,
                    outputOffset: 0,
                    completion: completionCallback
                )
            }
        }

        sampleSpan.end()
    }

    // MARK: - Token Generation

    private mutating func generateTokenBatch(
        count: Int,
        gpuSampler: any MPSGraphSampler,
        yieldingTo continuation: AsyncThrowingStream<InferenceEngine.TokenId, Error>.Continuation,
        isCancelled: borrowing Atomic<Bool>
    ) async throws {
        for _ in 0 ..< count {
            guard !isCancelled.load(ordering: .relaxed) else { return }
            try await _encodeNextStepGPU(
                tokens: [],
                gpuSampler: gpuSampler,
                yieldingTo: continuation
            )
        }
    }

    // MARK: - KV Cache Growth

    private mutating func growKVCacheAndRebind(neededCapacity: Int) async throws {
        let cacheSpan = InstrumentsProfiler.beginCacheManagement(
            step: processedTokenCount, operation: "grow", engine: "CoreAI-Pipelined")

        do {
            do {
                let queue = pipelineQueue
                guard let cmdBuf = queue.makeCommandBuffer() else {
                    throw KVCacheError.allocationFailed(0)
                }

                if (try kvCache.encodePipelinedExpansion(
                    forContextLength: neededCapacity,
                    commandBuffer: cmdBuf)) != nil
                {
                } else {
                    throw KVCacheError.capacityExceeded(
                        needed: neededCapacity, available: kvCache.currentCapacity)
                }
            }
        } catch {
            cacheSpan.end()
            throw error
        }
        cacheSpan.end()
    }

    // MARK: - Run Completion

    mutating func runCompletion(
        prompt: [InferenceEngine.TokenId],
        sampler: SamplingConfiguration,
        maxTokens: Int?,
        yieldingTo continuation: AsyncThrowingStream<InferenceEngine.TokenId, Error>.Continuation
    ) async throws {
        let gpuSampler = try getOrCreateSampler(for: sampler)

        let isCancelled = Atomic<Bool>(false)
        continuation.onTermination = { _ in
            isCancelled.store(true, ordering: .relaxed)
        }

        let contextLeftAfterPrompt = config.maxContextLength - processedTokenCount - prompt.count
        guard contextLeftAfterPrompt >= 1 else {
            throw InferenceRuntimeError.contextLengthExceeded(
                processedTokenCount, config.maxContextLength)
        }
        let totalMaxTokens = min(maxTokens ?? Int.max, contextLeftAfterPrompt)

        // Pre-grow KV cache for prompt
        let promptCapacityNeeded = min(
            processedTokenCount + prompt.count + totalMaxTokens, config.maxContextLength)
        if promptCapacityNeeded > kvCache.currentCapacity {
            do {
                let queue = pipelineQueue
                let grew = try kvCache.ensureCapacity(
                    forContextLength: promptCapacityNeeded, queue: queue)
                if grew {
                }
            }
        }

        // Prefill the prompt, then sample from the tokens prefill left behind.
        // Skip it entirely if the prompt is empty (prefix-cached continuation).
        if !prompt.isEmpty {
            let prefillTokens = try await prefill(prompt: prompt)

            // Process the remaining prompt tokens with sampling
            try await _encodeNextStepGPU(
                tokens: prefillTokens,
                gpuSampler: gpuSampler,
                yieldingTo: continuation
            )
        }

        // Generate-Grow-Continue loop
        var remainingTokens = totalMaxTokens - 1

        while remainingTokens > 0 {
            guard !isCancelled.load(ordering: .relaxed) else { break }

            let availableSlots = kvCache.currentCapacity - processedTokenCount
            let tokensThisRound = min(remainingTokens, availableSlots)

            if tokensThisRound > 0 {
                try await generateTokenBatch(
                    count: tokensThisRound,
                    gpuSampler: gpuSampler,
                    yieldingTo: continuation,
                    isCancelled: isCancelled
                )
                remainingTokens -= tokensThisRound
            }

            if remainingTokens > 0 {
                let neededCapacity = processedTokenCount + remainingTokens
                try await growKVCacheAndRebind(neededCapacity: neededCapacity)
            }
        }

        // Sentinel: submit an empty command buffer on the same serial queue.
        // Its addCompletedHandler fires after all real sampler callbacks (serial
        // queue FIFO ordering via MTLDispatchListApply), guaranteeing every
        // continuation.yield has returned before the caller calls finish().
        // We use a bare command buffer instead of the sampler to avoid the shared
        // MPSGraphExecutableExecutionDescriptor issue in MPSGraphCompositeSampler.
        await withCheckedContinuation { (sentinelCont: CheckedContinuation<Void, Never>) in
            do {
                let queue = pipelineQueue
                guard let cmdBuf = queue.makeCommandBuffer() else {
                    sentinelCont.resume()
                    return
                }
                cmdBuf.addCompletedHandler { _ in sentinelCont.resume() }
                cmdBuf.commit()
            }
        }
    }

    // MARK: - Chunked Prefill

    /// Prefill the part of the prompt that needs no logits, returning the tokens that do.
    ///
    /// With a `prefill` graph, everything but the final token goes through it in chunks:
    /// it has no LM head, so it can't seed sampling, and one token is held back.
    /// Without one, `function` serves prefill too, chunked only above `chunkThreshold`.
    private mutating func prefill(prompt: [Int32]) async throws -> ArraySlice<Int32> {
        if prefillFunction != nil {
            var head = prompt.dropLast()
            for chunk in prefillChunkSizes(
                tokenCount: prompt.count, chunkSize: prefillMaxQueryLength,
                heldBack: prefillHeldBackTokens(hasPrefillGraph: true))
            {
                try await _encodeChunk(tokens: Array(head.prefix(chunk)))
                head = head.dropFirst(chunk)
            }
            return prompt.suffix(1)
        }

        if prompt.count > config.chunkThreshold {
            return try await processChunkedInput(tokens: prompt)
        }

        if try logits.ensureCapacity(forContextLength: max(1, prompt.count)) {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .memory
            CLILogger.log(
                "Logits buffer grew to capacity \(logits.currentCapacity) (\(fmt.string(fromByteCount: Int64(logits.currentByteCount))))"
            )
        }
        return prompt[...]
    }

    mutating func processChunkedInput(tokens: [Int32]) async throws -> ArraySlice<Int32> {
        let chunkSize = config.prefillChunkSize
        var remainingTokens = tokens[...]

        try logits.ensureCapacity(forContextLength: chunkSize)

        while remainingTokens.count > chunkSize {
            let chunk = Array(remainingTokens.prefix(chunkSize))
            try await _encodeChunk(tokens: chunk)
            remainingTokens = remainingTokens.dropFirst(chunkSize)
        }

        return remainingTokens
    }

    private mutating func _encodeChunk(tokens: [Int32]) async throws {
        let queryLength = tokens.count
        let currentStep = processedTokenCount
        let graphName = prefillFunction != nil ? prefillGraphFunctionName : config.function

        let chunkID = InstrumentsProfiler.beginCustomInterval(
            name: "CoreAIPipelinedChunk",
            details: "step=\(currentStep) qLen=\(queryLength) graph=\(graphName)"
        )

        // Write at the chunk's natural position so each chunk occupies a disjoint
        // region of inputTokensBuffer. Encode holds a live MTLBuffer reference — writing
        // all chunks at offset 0 would race with the GPU reading the previous chunk.
        let ptr = inputTokensBuffer.contents().bindMemory(
            to: Int32.self, capacity: processedTokenCount + queryLength)
        for (i, token) in tokens.enumerated() {
            ptr[processedTokenCount + i] = token
        }

        let cachePosBuffer = cachePositionBuffers[step % pipelineDepth]
        let posLength = processedTokenCount + queryLength

        // Build async values and encode
        let tokenShape = [1, queryLength]
        let tokenStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tokenShape)
        let posShape = [1, posLength]
        let posStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: posShape)

        let tokenValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: inputTokensBuffer,
            byteOffset: processedTokenCount * MemoryLayout<Int32>.size,
            scalarType: .int32, shape: tokenShape, strides: tokenStrides)
        let posValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: cachePosBuffer, byteOffset: 0,
            scalarType: .int32, shape: posShape, strides: posStrides)

        let asyncInputs: [String: InferenceFunction.AsyncValue] = [
            inputIdsName: tokenValue, positionIdsName: posValue,
        ]

        let keyBuffer = kvCache.keyBinding.metalBuffer
        let keyShape = kvCache.keyBinding.layout.shape
        let keyStrides = kvCache.keyBinding.layout.strides
        let valBuffer = kvCache.valueBinding.metalBuffer
        let valShape = kvCache.valueBinding.layout.shape
        let valStrides = kvCache.valueBinding.layout.strides
        var keyState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: keyBuffer, byteOffset: 0,
            scalarType: keyCacheScalarType, shape: keyShape, strides: keyStrides)
        var valState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: valBuffer, byteOffset: 0,
            scalarType: valueCacheScalarType, shape: valShape, strides: valStrides)
        if let prefillFn = prefillFunction {
            try _CoreAIEncodeHelpers.encodeWithStatesNoOutputs(
                function: prefillFn, inputs: asyncInputs,
                keyState: &keyState, keyCacheName: keyCacheName,
                valState: &valState, valueCacheName: valueCacheName,
                additionalStates: additionalStates,
                computeStream: computeStream)
        } else {
            let logitsShape = [1, queryLength, vocabSize]
            try _CoreAIEncodeHelpers.encodeWithStates(
                function: function, inputs: asyncInputs,
                keyState: &keyState, keyCacheName: keyCacheName,
                valState: &valState, valueCacheName: valueCacheName,
                additionalStates: additionalStates,
                logitsBuffer: logits.metalBuffer, logitsName: logitsOutputName,
                logitsShape: logitsShape,
                logitsStrides: try resolvedStrides(descriptor: logitsBaseDesc, shape: logitsShape),
                computeStream: computeStream)
        }

        processedTokenCount += queryLength
        step += 1
        InstrumentsProfiler.endCustomInterval(name: "CoreAIPipelinedChunk", signpostID: chunkID)
    }

    mutating func reset() {
        let span = InstrumentsProfiler.beginReset(engine: "CoreAI-Pipelined")
        processedTokenCount = 0
        step = 0
        cachedSampler = nil
        cachedSamplerTemperature = nil
        // Clear the GPU penalty ring so a new conversation doesn't inherit
        // penalty state from the previous one (aligned with upstream reset()).
        penaltyState?.reset()
        // Zero SSM states so the next conversation starts from a clean slate.
        additionalStates?.reset()
        span.end()
    }

    // MARK: - Warmup

    mutating func performWarmup(queryLength: Int, samplingConfig: SamplingConfiguration?)
        async throws
    {
        let warmupStart = ContinuousClock.now
        let warmupSpan = InstrumentsProfiler.beginWarmup()

        // A single warmup at any shape primes the framework's internal caches
        // (reshape, kernel compilation, state pool). Benchmarks show no benefit
        // from warming every bucket shape — the jump from none→any is what matters.
        let defaultWarmupLength = 256

        var shapesToWarm: [Int]
        if queryLength > 0 {
            shapesToWarm = [queryLength]
        } else {
            shapesToWarm = [1, defaultWarmupLength]
        }
        if prefillFunction != nil {
            // Multi-token shapes warm the prefill graph, so `function` needs its own
            // single-token pass.
            shapesToWarm = shapesToWarm.map { $0 > 1 ? min($0, prefillMaxQueryLength) : $0 }
            if !shapesToWarm.contains(1) { shapesToWarm.append(1) }
        }

        let maxShape = shapesToWarm.last ?? 1
        // `function` only produces prompt-wide logits when there's no prefill graph.
        try logits.ensureCapacity(forContextLength: prefillFunction != nil ? 1 : maxShape)

        do {
            let queue = pipelineQueue
            if try kvCache.ensureCapacity(forContextLength: maxShape, queue: queue) {
            }
        }

        let warmupSampler = try MPSGraphSamplerFactory.makeSampler(
            device: device,
            vocabSize: config.vocabSize,
            temperature: samplingConfig?.temperature ?? 0
        )

        for shape in shapesToWarm {
            // Write dummy tokens
            let ptr = inputTokensBuffer.contents().bindMemory(to: Int32.self, capacity: shape)
            for i in 0 ..< shape { ptr[i] = 1 }

            let cachePosBuffer = cachePositionBuffers[step % pipelineDepth]
            let posLength = processedTokenCount + shape

            let tShape = [1, shape]
            let tStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tShape)
            let pShape = [1, posLength]
            let pStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: pShape)

            let tokenValue = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: inputTokensBuffer, byteOffset: 0,
                scalarType: .int32, shape: tShape, strides: tStrides)
            let posValue = unsafe InferenceFunction.AsyncValue(
                unsafeBuffer: cachePosBuffer, byteOffset: 0,
                scalarType: .int32, shape: pShape, strides: pStrides)
            let asyncInputs: [String: InferenceFunction.AsyncValue] = [
                inputIdsName: tokenValue, positionIdsName: posValue,
            ]

            let keyBuffer = kvCache.keyBinding.metalBuffer
            let kShape = kvCache.keyBinding.layout.shape
            let kStrides = kvCache.keyBinding.layout.strides
            let valBuffer = kvCache.valueBinding.metalBuffer
            let vShape = kvCache.valueBinding.layout.shape
            let vStrides = kvCache.valueBinding.layout.strides
            var keyState = unsafe InferenceFunction.AsyncMutableValue(
                unsafeBuffer: keyBuffer, byteOffset: 0,
                scalarType: keyCacheScalarType, shape: kShape, strides: kStrides)
            var valState = unsafe InferenceFunction.AsyncMutableValue(
                unsafeBuffer: valBuffer, byteOffset: 0,
                scalarType: valueCacheScalarType, shape: vShape, strides: vStrides)
            // Multi-token shapes must run on the prefill graph when there is one. Not just
            // to avoid compiling unused kernels: the logits buffer holds a single row in
            // that case, so a wide warmup on `function` would overrun it.
            if shape > 1, let prefillFn = prefillFunction {
                try _CoreAIEncodeHelpers.encodeWithStatesNoOutputs(
                    function: prefillFn, inputs: asyncInputs,
                    keyState: &keyState, keyCacheName: keyCacheName,
                    valState: &valState, valueCacheName: valueCacheName,
                    additionalStates: additionalStates,
                    computeStream: computeStream)
                step += 1
                continue
            }

            let lShape = [1, shape, vocabSize]
            let lStrides = try resolvedStrides(descriptor: logitsBaseDesc, shape: lShape)

            try _CoreAIEncodeHelpers.encodeWithStates(
                function: function, inputs: asyncInputs,
                keyState: &keyState, keyCacheName: keyCacheName,
                valState: &valState, valueCacheName: valueCacheName,
                additionalStates: additionalStates,
                logitsBuffer: logits.metalBuffer, logitsName: logitsOutputName,
                logitsShape: lShape, logitsStrides: lStrides,
                computeStream: computeStream)

            // Warm up argmax kernel using pipeline-matched decode buffers
            let warmupLogitsBuffer = decodeLogitsBuffers[step % pipelineDepth]
            let warmupOutputBuffer = decodeOutputBuffers[step % pipelineDepth]
            let logitsOffset = (shape - 1) * vocabSize * MemoryLayout<UInt16>.size

            do {
                let queue = pipelineQueue
                try warmupSampler.encode(
                    to: queue,
                    logitsBuffer: warmupLogitsBuffer,
                    logitsOffset: logitsOffset,
                    outputBuffer: warmupOutputBuffer,
                    outputOffset: 0,
                    completion: { _, _ in }
                )
            } catch {
                // Sync throw (graph/compilation) during warmup — propagate to the
                // caller (performWarmup is async throws). No pipeline gate acquired.
                throw error
            }

            step += 1
        }

        await computeStream.currentWorkCompleted()
        reset()

        warmupSpan.end()
        let warmupElapsed = milliseconds(since: warmupStart)
    }

    // MARK: - Constrained Run Completion

    static let maxJumpForwardTokens = 64

    /// Semi-pipelined constrained generation loop.
    ///
    /// Unlike `runCompletion` which fires steps asynchronously, this awaits each
    /// token before computing the next bitmask (grammar state is sequential).
    mutating func runConstrainedCompletion(
        prompt: [Int32],
        sampler: SamplingConfiguration,
        session: ConstrainedSessionHandle,
        maxTokens: Int,
        isCancelled: borrowing Atomic<Bool>,
        yieldingTo continuation: AsyncThrowingStream<Int32, Error>.Continuation
    ) async throws {
        let gpuSampler = try getOrCreateSampler(for: sampler)

        guard let bitmaskBuffer = try gpuSampler.bitmaskBuffer else {
            throw InferenceRuntimeError.invalidArgument(
                "Constrained generation requires a sampler that supports bitmask application")
        }

        // Pre-grow KV cache
        let totalNeeded = prompt.count + maxTokens
        try kvCache.ensureCapacity(forContextLength: totalNeeded, queue: pipelineQueue)

        // Prefill prompt (unconstrained — grammar doesn't constrain the prompt)
        let prefillTokens: [Int32]
        if prompt.count > config.chunkThreshold {
            let remaining = try await processChunkedInput(tokens: prompt)
            prefillTokens = Array(remaining)
        } else {
            prefillTokens = prompt
        }

        try logits.ensureCapacity(forContextLength: max(1, prefillTokens.count))

        // Fill initial bitmask
        let bitmaskPtr = bitmaskBuffer.contents().assumingMemoryBound(to: Int32.self)
        let initialMask = session.fillBitmask(into: bitmaskPtr)
        if case .terminated = initialMask { return }
        let applyInitialMask = initialMask == .constrained

        // Encode prefill and sample first token
        var lastToken: Int32 = try await withCheckedThrowingContinuation { cont in
            do {
                try _encodeStepForConstrainedGeneration(
                    tokens: prefillTokens,
                    gpuSampler: gpuSampler,
                    applyBitmask: applyInitialMask
                ) { token, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: token)
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }

        continuation.yield(lastToken)

        // Constrained decode loop
        var generated = 1
        while generated < maxTokens {
            guard !isCancelled.load(ordering: .relaxed) else { break }
            try Task.checkCancellation()

            if !session.acceptToken(lastToken) { break }
            if session.isTerminated { break }

            // Jump-forward: deterministic grammar segments batch-encoded
            if let jumpString = session.findJumpForwardString(),
                let jumpTokens = tokenizeJumpForward(jumpString, session: session)
            {
                let bitmaskPtr = bitmaskBuffer.contents().assumingMemoryBound(to: Int32.self)
                let postJumpMask = session.fillBitmask(into: bitmaskPtr)
                if case .terminated = postJumpMask { break }
                let applyMaskAfterJump = postJumpMask == .constrained

                lastToken = try await withCheckedThrowingContinuation { cont in
                    do {
                        try _encodeStepForConstrainedGeneration(
                            tokens: [lastToken] + jumpTokens,
                            gpuSampler: gpuSampler,
                            applyBitmask: applyMaskAfterJump
                        ) { token, error in
                            if let error = error {
                                cont.resume(throwing: error)
                            } else {
                                cont.resume(returning: token)
                            }
                        }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }

                for jt in jumpTokens { continuation.yield(jt) }
                continuation.yield(lastToken)
                generated += jumpTokens.count + 1
                continue
            }

            // Fill bitmask
            let bitmaskPtr = bitmaskBuffer.contents().assumingMemoryBound(to: Int32.self)
            let bitmaskResult = session.fillBitmask(into: bitmaskPtr)
            if case .terminated = bitmaskResult { break }
            let applyMask = bitmaskResult == .constrained

            lastToken = try await withCheckedThrowingContinuation { cont in
                do {
                    try _encodeStepForConstrainedGeneration(
                        tokens: [],
                        gpuSampler: gpuSampler,
                        applyBitmask: applyMask
                    ) { token, error in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume(returning: token)
                        }
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }

            continuation.yield(lastToken)
            generated += 1
        }

        // Drain: sentinel command buffer to ensure all GPU work completes
        await withCheckedContinuation { (sentinelCont: CheckedContinuation<Void, Never>) in
            do {
                let queue = pipelineQueue
                guard let cmdBuf = queue.makeCommandBuffer() else {
                    sentinelCont.resume()
                    return
                }
                cmdBuf.addCompletedHandler { _ in sentinelCont.resume() }
                cmdBuf.commit()
            }
        }
    }

    /// Tokenize a jump-forward string and accept each token in the grammar.
    private func tokenizeJumpForward(
        _ string: String,
        session: ConstrainedSessionHandle
    ) -> [Int32]? {
        let tokenIds = session.tokenizeForJumpForward(string)
        guard !tokenIds.isEmpty else { return nil }

        let byteLength = string.utf8.count
        var safeCount = 0
        for i in 1 ... tokenIds.count {
            let prefixDecoded = session.decodeTokens(Array(tokenIds.prefix(i)))
            if prefixDecoded.utf8.count < byteLength {
                safeCount = i
            } else {
                break
            }
        }
        guard safeCount > 0, safeCount <= Self.maxJumpForwardTokens else { return nil }

        let safeTokens = Array(tokenIds.prefix(safeCount))

        var accepted = 0
        for tokenId in safeTokens {
            if !session.acceptToken(tokenId) {
                if accepted > 0 { session.rollback(accepted) }
                return nil
            }
            accepted += 1
        }

        return safeTokens
    }

    /// Single encode step for constrained generation (prefill or decode).
    private mutating func _encodeStepForConstrainedGeneration(
        tokens: [Int32],
        gpuSampler: any MPSGraphSampler,
        applyBitmask: Bool,
        completion: @escaping (Int32, Error?) -> Void
    ) throws {
        let actualTokenCount = tokens.isEmpty ? 1 : tokens.count
        let queryLength = actualTokenCount

        defer {
            processedTokenCount += actualTokenCount
            step += 1
        }

        let tokenByteOffset = processedTokenCount * MemoryLayout<Int32>.size
        if !tokens.isEmpty {
            let ptr = inputTokensBuffer.contents().bindMemory(
                to: Int32.self, capacity: processedTokenCount + queryLength)
            for (i, token) in tokens.enumerated() {
                ptr[processedTokenCount + i] = token
            }
        }

        let cachePosBuffer = cachePositionBuffers[step % pipelineDepth]
        let posLength = processedTokenCount + queryLength

        let tokenShape = [1, queryLength]
        let tokenStrides = try resolvedStrides(descriptor: inputIdsBaseDesc, shape: tokenShape)
        let tokenValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: inputTokensBuffer,
            byteOffset: tokens.isEmpty ? 0 : tokenByteOffset,
            scalarType: .int32,
            shape: tokenShape,
            strides: tokenStrides
        )
        let posShape = [1, posLength]
        let posStrides = try resolvedStrides(descriptor: positionIdsBaseDesc, shape: posShape)
        let posValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: cachePosBuffer,
            byteOffset: 0,
            scalarType: .int32,
            shape: posShape,
            strides: posStrides
        )

        let asyncInputs: [String: InferenceFunction.AsyncValue] = [
            inputIdsName: tokenValue,
            positionIdsName: posValue,
        ]

        let keyBuffer = kvCache.keyBinding.metalBuffer
        let keyShape = kvCache.keyBinding.layout.shape
        let keyStrides = kvCache.keyBinding.layout.strides
        var keyState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: keyBuffer, byteOffset: 0,
            scalarType: keyCacheScalarType, shape: keyShape, strides: keyStrides
        )
        let valBuffer = kvCache.valueBinding.metalBuffer
        let valShape = kvCache.valueBinding.layout.shape
        let valStrides = kvCache.valueBinding.layout.strides
        var valState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: valBuffer, byteOffset: 0,
            scalarType: valueCacheScalarType, shape: valShape, strides: valStrides
        )

        let logitsBuffer = logits.metalBuffer
        let logitsShape = [1, queryLength, vocabSize]
        let logitsStrides = try resolvedStrides(descriptor: logitsBaseDesc, shape: logitsShape)

        // NOTE: no PipelineGate here (unlike runCompletion's async encode). The
        // constrained loop is strictly sequential — each step awaits the previous
        // step's sampled token before encoding the next — so at most one encode
        // is in flight and the backpressure gate cannot stack.

        try _CoreAIEncodeHelpers.encodeWithStates(
            function: function, inputs: asyncInputs,
            keyState: &keyState, keyCacheName: keyCacheName,
            valState: &valState, valueCacheName: valueCacheName,
            additionalStates: additionalStates,
            logitsBuffer: logitsBuffer, logitsName: logitsOutputName,
            logitsShape: logitsShape, logitsStrides: logitsStrides,
            computeStream: computeStream
        )

        // GPU sampling via Metal queue
        let queue = pipelineQueue
        let outputBuffer = inputTokensBuffer

        do {
            if queryLength == 1 {
                try gpuSampler.encode(
                    to: queue, logitsBuffer: logitsBuffer, logitsOffset: 0,
                    outputBuffer: outputBuffer, outputOffset: 0,
                    applyBitmask: applyBitmask,
                    completion: { token, error in
                        completion(token, error)
                    }
                )
            } else if let compositeSampler = gpuSampler as? MPSGraphCompositeSampler {
                compositeSampler.encodeWithSlice(
                    to: queue, logitsBuffer: logitsBuffer, queryLength: actualTokenCount,
                    outputBuffer: outputBuffer, outputOffset: 0,
                    applyBitmask: applyBitmask,
                    completion: { token, error in
                        completion(token, error)
                    }
                )
            } else if let argmaxSampler = gpuSampler as? MPSGraphArgmaxSampler {
                argmaxSampler.encodeWithSlice(
                    to: queue, logitsBuffer: logitsBuffer, queryLength: actualTokenCount,
                    outputBuffer: outputBuffer, outputOffset: 0,
                    applyBitmask: applyBitmask,
                    completion: { token, error in
                        completion(token, error)
                    }
                )
            } else {
                gpuSampler.encodeWithSlice(
                    to: queue, logitsBuffer: logitsBuffer, queryLength: actualTokenCount,
                    outputBuffer: outputBuffer, outputOffset: 0,
                    completion: { token, error in
                        completion(token, error)
                    }
                )
            }
        } catch {
            completion(0, error)
        }
    }
}

@available(macOS 27.0, iOS 27.0, *)
extension CoreAIPipelinedEngine {
    /// Async sequence of `InferenceOutput` produced by `generate()`.
    ///
    /// Unlike the CPU engines, the pipelined engine samples on-device and drives
    /// output from a producer `Task`, so this sequence forwards an underlying
    /// `AsyncThrowingStream`. The producer records the `stopReason` directly.
    struct GenerationSequence: InferenceOutputSequence {
        typealias Element = InferenceOutput
        typealias Failure = Error

        let base: AsyncThrowingStream<InferenceOutput, any Error>
        let stopReasonStore: StopReasonStore

        var stopReason: InferenceStopReason? { stopReasonStore.stopReason }

        func setStopReason(_ reason: InferenceStopReason) {
            stopReasonStore.set(reason)
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(base: base.makeAsyncIterator(), stopReasonStore: stopReasonStore)
        }
    }
}

@available(macOS 27.0, iOS 27.0, *)
extension CoreAIPipelinedEngine.GenerationSequence {
    struct Iterator: AsyncIteratorProtocol {
        typealias Element = InferenceOutput
        typealias Failure = Error

        var base: AsyncThrowingStream<InferenceOutput, any Error>.AsyncIterator
        let stopReasonStore: StopReasonStore

        mutating func next() async throws -> InferenceOutput? {
            do {
                return try await base.next()
            } catch is CancellationError {
                // The producer Task is independent and won't observe the
                // consumer's cancellation, so record it from the consumer side.
                stopReasonStore.set(.cancelled)
                throw CancellationError()
            } catch {
                stopReasonStore.set(.error)
                throw error
            }
        }
    }
}

#endif
