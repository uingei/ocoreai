// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — aligned with coreai-models CoreAISequentialEngine.swift HEAD a5ece33
//
/// Clean Core AI inference engine built from public APIs.
///
/// Model Contract:
/// - **2 inputs**: `input_ids` (Int32), `position_ids` (Int32)
/// - **1 output**: `logits` (LogitsScalarType)
/// - **2–4 states**: KV cache pair + optional persistent states (hybrid models)
///
/// KV cache grows dynamically with 2× expansion. Chunked prefill for long prompts.
/// GenerationToken cancellation. TokenHistory prefix caching.
///
/// Replaces old `CoreAIEngine.swift` which had:
/// - Hard-coded 2-state guard, manual KV, no chunked prefill
/// - Mutex cancel, no profiling, no hybrid model support

#if canImport(CoreAI)
import CoreAI
import Foundation
import Synchronization

// MARK: - Prefill Strategy

/// Determines the optimal prefill strategy based on prompt size.
enum PrefillStrategy {
    case chunked(chunkSize: Int)
    case wholeBatch
    case oneAtATime
}

// MARK: - Core AI Sequential Engine

@available(macOS 27.0, iOS 27.0, *)
// Sendable safety: all storage is `let` (immutable after init); the only mutable
// state lives in a `Mutex`-guarded lock (NSRecursiveLock), never accessed unsynchronized.
final class CoreAISequentialEngine: InferenceEngine, @unchecked Sendable {
    typealias ConfigType = InternalModelConfig
    typealias TokenId = Int32

    var supportsLogits: Bool { true }
    var vocabSize: Int { config.vocabSize }
    let config: InternalModelConfig

    // Core AI function handle + descriptor
    private let function: InferenceFunction
    private let functionDescriptor: InferenceFunctionDescriptor

    // I/O names from descriptor
    private let inputIdsName: String
    private let positionIdsName: String
    private let logitsName: String

    // State management via StateHandler abstraction
    private var kvCache: any SyncStateHandler
    private var additionalStates: FixedNDArrayState?
    private var hasNonTruncatableStates: Bool

    // Descriptors for dynamic shape resolution
    private let inputIdsDescriptor: NDArrayDescriptor
    private let positionIdsDescriptor: NDArrayDescriptor
    private let logitsDescriptor: NDArrayDescriptor

    // Persistent arrays — reused across steps
    private var logitsArray: NDArray
    private var inputIdsArray: NDArray
    private var cachedInputBatchSize: Int
    private var cachedLogitsBatchSize: Int

    // Track processed tokens for incremental inference
    public private(set) var processedTokenCount: Int = 0

    // Token history for implicit prefix caching
    private var history = TokenHistory()
    public private(set) var lastPrefixHitCount: Int = 0

    // Generation token tracking
    private let _activeToken = Mutex<GenerationToken?>(nil)
    public var isBusy: Bool { _activeToken.withLock { $0 != nil } }

    /// Clear the engine's active token if it matches the given token.
    func clearTokenIfActive(_ token: GenerationToken) {
        _activeToken.withLock { if $0 === token { $0 = nil } }
    }

    // MARK: - Init

    init(
        config: InternalModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions = EngineOptions()
    ) async throws {
        self.config = config

        let model = preparedModel.model

        // Get function descriptor
        guard let descriptor = model.functionDescriptor(for: config.function) else {
            throw InferenceRuntimeError.genericError(
                "Cannot find function '\(config.function)' in model")
        }
        self.functionDescriptor = descriptor

        // Validate: 2 inputs, 1+ output, 2-4 states
        guard descriptor.inputNames.count == 2 else {
            throw InferenceRuntimeError.invalidInputType(
                "Expected 2 inputs, got \(descriptor.inputNames.count)")
        }
        guard descriptor.outputNames.count >= 1 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 1 output, got \(descriptor.outputNames.count)")
        }
        guard descriptor.stateNames.count >= 2 && descriptor.stateNames.count <= 4 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected 2-4 states (KV cache + optional persistent), got \(descriptor.stateNames.count)"
            )
        }

        // Extract names
        self.inputIdsName = descriptor.inputNames[0]
        self.positionIdsName = descriptor.inputNames[1]
        self.logitsName = descriptor.outputNames[0]

        // Extract input descriptors
        guard case .ndArray(let inputDesc) = descriptor.inputDescriptor(of: inputIdsName) else {
            throw InferenceRuntimeError.invalidInputType(
                "Cannot get descriptor for '\(inputIdsName)'")
        }
        self.inputIdsDescriptor = inputDesc

        guard case .ndArray(let posDesc) = descriptor.inputDescriptor(of: positionIdsName) else {
            throw InferenceRuntimeError.invalidInputType(
                "Cannot get descriptor for '\(positionIdsName)'")
        }
        self.positionIdsDescriptor = posDesc

        // Extract logits descriptor — validate f16
        guard case .ndArray(let logitsDesc) = descriptor.outputDescriptor(of: logitsName) else {
            throw InferenceRuntimeError.invalidOutputType(
                "Cannot get descriptor for '\(logitsName)'")
        }
        guard logitsDesc.scalarType == .float16 else {
            throw InferenceRuntimeError.unsupportedLogitsType("Only float16 logits supported")
        }
        self.logitsDescriptor = logitsDesc

        // Create state handlers from descriptor via factory
        let stateHandlers = try StateHandlerFactory.createSyncHandlers(
            descriptor: descriptor,
            maxContextLength: config.maxContextLength,
            options: options
        )
        self.kvCache = stateHandlers.kvCache
        self.additionalStates = stateHandlers.additionalStates
        self.hasNonTruncatableStates = stateHandlers.hasNonTruncatableStates

        // Allocate initial logits (decode steady state: batch=1)
        let initLogitsDesc = logitsDesc.resolvingDynamicDimensions([1, 1, config.vocabSize])
        self.logitsArray = NDArray(descriptor: initLogitsDesc)
        self.cachedLogitsBatchSize = 1

        // Allocate initial input_ids (decode: [1, 1])
        let initInputDesc = inputIdsDescriptor.resolvingDynamicDimensions([1, 1])
        self.inputIdsArray = NDArray(descriptor: initInputDesc)
        self.cachedInputBatchSize = 1

        // Load inference function
        guard let fn = try model.loadFunction(named: config.function) else {
            throw InferenceRuntimeError.genericError("Cannot load function '\(config.function)'")
        }
        self.function = fn
    }

    /// Convenience init with direct model URL.
    public convenience init(
        config: InternalModelConfig,
        modelURL: URL,
        options: EngineOptions = EngineOptions()
    ) async throws {
        let preparedModel = try await PreparedModel.prepare(at: modelURL)
        try await self.init(config: config, preparedModel: preparedModel, options: options)
    }

    // MARK: - Prefill Strategy

    private func selectPrefillStrategy(newTokenCount: Int) -> PrefillStrategy {
        if newTokenCount > config.chunkThreshold {
            return .chunked(chunkSize: config.prefillChunkSize)
        }
        return .wholeBatch
    }

    // MARK: - Token Batch Processing

    /// Process a batch of tokens in a single forward pass.
    private func processTokenBatch(_ tokens: ArraySlice<Int32>) async throws -> [LogitsScalarType] {
        let batchSize = tokens.count
        guard batchSize > 0 else {
            throw InferenceRuntimeError.invalidState("Cannot process empty token batch")
        }

        _ = try kvCache.ensureCapacity(forContextLength: processedTokenCount + batchSize)

        // Reuse inputIdsArray when batch size unchanged
        if cachedInputBatchSize != batchSize {
            let resolvedInputDesc = inputIdsDescriptor.resolvingDynamicDimensions([1, batchSize])
            inputIdsArray = NDArray(descriptor: resolvedInputDesc)
            cachedInputBatchSize = batchSize
        }
        fillNDArray(&inputIdsArray, as: Int32.self, with: tokens)

        // Build position_ids: [0, 1, ..., processedTokenCount + batchSize - 1]
        let totalPositions = processedTokenCount + batchSize
        let resolvedPosDesc = positionIdsDescriptor.resolvingDynamicDimensions([1, totalPositions])
        var positionIds = NDArray(descriptor: resolvedPosDesc)
        fillNDArray(&positionIds, as: Int32.self, count: totalPositions) { Int32($0) }

        // Reuse logitsArray when batch size unchanged
        if cachedLogitsBatchSize != batchSize {
            let resolvedLogitsDesc = logitsDescriptor.resolvingDynamicDimensions([
                1, batchSize, config.vocabSize,
            ])
            logitsArray = NDArray(descriptor: resolvedLogitsDesc)
            cachedLogitsBatchSize = batchSize
        }

        // Execute inference with states
        try await runWithStates(
            function: function,
            inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIds],
            primary: kvCache,
            secondary: additionalStates,
            outputArray: &logitsArray,
            outputName: logitsName
        )

        // Read logits from NDArray
        let totalLogits = batchSize * config.vocabSize
        let logitBuffer = readNDArray(logitsArray, as: LogitsScalarType.self, count: totalLogits)

        processedTokenCount += batchSize

        return logitBuffer
    }

    // MARK: - Chunked Prefill

    private func processChunkedPrompt(
        tokens: ArraySlice<Int32>,
        chunkSize: Int
    ) async throws -> [LogitsScalarType] {
        var lastLogits: [LogitsScalarType] = []
        var remainingTokens = tokens
        var chunkIndex = 0

        while !remainingTokens.isEmpty {
            let currentChunkSize = min(chunkSize, remainingTokens.count)
            let chunkEnd = remainingTokens.startIndex + currentChunkSize
            let chunk = remainingTokens[remainingTokens.startIndex ..< chunkEnd]

            lastLogits = try await processTokenBatch(chunk)
            remainingTokens = remainingTokens[chunkEnd...]
            chunkIndex += 1
        }

        return lastTokenLogits(from: lastLogits, vocabSize: config.vocabSize)
    }

    // MARK: - Constrained Decoding Step

    /// Single decode step that returns raw logits instead of sampling.
    /// The caller applies grammar masking to logits, samples, then feeds
    /// the chosen token back via `feedToken(_:to:)`.
    ///
    /// Used by EngineInference for grammar-constrained generation — the
    /// core loop: prefill → decodeStep → mask logits → sample → accept → repeat.
    struct DecodeStepLogits {
        let logits: [LogitsScalarType]
        let vocabSize: Int
    }

    /// Returns raw logits for the next decode position.
    /// - Parameter input: The input tokens already processed (used for prefill).
    /// - Returns: Logits array of length `vocabSize`, or `nil` if prefill is done
    ///   and the engine is ready for feed-token calls.
    func startConstrainedDecoding(
        with input: [TokenId],
        maxTokens: Int
    ) async throws -> DecodeStepLogits? {
        // Run prefill — same logic as Iterator.next() but returns logits
        guard processedTokenCount < input.count else {
            return nil  // prefill already complete, call feedToken instead
        }

        let oldProcessedCount = processedTokenCount
        let newTokens = input[processedTokenCount...]
        let strategy = selectPrefillStrategy(newTokenCount: newTokens.count)

        let logitBuffer: [LogitsScalarType]
        switch strategy {
        case .chunked(let chunkSize):
            logitBuffer = try await processChunkedPrompt(tokens: newTokens, chunkSize: chunkSize)
        case .wholeBatch:
            let allLogits = try await processTokenBatch(newTokens)
            logitBuffer = lastTokenLogits(from: allLogits, vocabSize: config.vocabSize)
        case .oneAtATime:
            var lastLogits: [LogitsScalarType] = []
            for j in newTokens.indices {
                lastLogits = try await processTokenBatch(newTokens[j ... j])
            }
            logitBuffer = lastLogits
        }

        // Update history
        let processedSlice = input[oldProcessedCount ..< processedTokenCount]
        history.append(contentsOf: processedSlice)

        return DecodeStepLogits(logits: logitBuffer, vocabSize: config.vocabSize)
    }

    /// Feed a token sampled after grammar masking. This advances the engine
    /// by one decode step and returns logits for the caller to mask again.
    /// Returns `nil` when context length is reached.
    func feedToken(_ tokenId: TokenId, maxTokens: Int) async throws -> DecodeStepLogits? {
        // Push the chosen token into the decode history
        history.append(tokenId)

        // Run one decode step
        let oneToken: ArraySlice<TokenId> = [tokenId][...]
        let logitBuffer = try await processTokenBatch(oneToken)

        return DecodeStepLogits(logits: logitBuffer, vocabSize: config.vocabSize)
    }

    // MARK: - Generate (primary API)

    public func generate(
        with input: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> GenerationSequence {
        // Cancel any prior generation
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }

        // Implicit prefix caching: resolve input against history
        if !history.isEmpty {
            let (commonPrefix, _) = history.resolve(input: input)
            if hasNonTruncatableStates {
                // Hybrid model: recurrent state can't be partially rewound
                if commonPrefix < history.count || processedTokenCount >= input.count {
                    internalReset(to: 0)
                }
                lastPrefixHitCount = 0
            } else if commonPrefix < input.count && commonPrefix < history.count {
                // Divergence
                internalReset(to: 0)
                lastPrefixHitCount = commonPrefix
            } else if processedTokenCount >= input.count {
                // Pure extension: rewind for seeding
                let resetTo = max(0, commonPrefix - 1)
                internalReset(to: resetTo)
                lastPrefixHitCount = commonPrefix
            } else {
                lastPrefixHitCount = commonPrefix
            }
        }

        let token = GenerationToken()
        _activeToken.withLock { $0 = token }
        return GenerationSequence(
            engine: self,
            input: input,
            samplingConfiguration: samplingConfiguration,
            inferenceOptions: inferenceOptions,
            generationToken: token
        )
    }

    // MARK: - Lifecycle

    /// Wait for any in-flight generate() to finish.
    private func drain() {
        var attempts = 0
        while _activeToken.withLock({ $0 != nil }) {
            attempts += 1
            if attempts > 5000 {
                assertionFailure("Sequential engine drain() timeout")
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    public func cancel() async throws {
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    public func reset(to tokenIndex: Int) async throws {
        // P0-fix: throw instead of precondition (engine internals must not release-crash)
        guard tokenIndex >= 0 && tokenIndex <= processedTokenCount else {
            throw InferenceRuntimeError.invalidState(
                "reset(to: \(tokenIndex)) out of range [0, \(processedTokenCount)]")
        }
        if tokenIndex != 0 && hasNonTruncatableStates {
            throw InferenceRuntimeError.invalidState(
                "Partial reset not supported for hybrid models with recurrent state")
        }
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
        internalReset(to: tokenIndex)
    }

    /// Internal reset without cancelling the active generation token.
    func internalReset(to tokenIndex: Int) {
        if tokenIndex == 0 {
            processedTokenCount = 0
            history.clear()
            kvCache.reset()
            additionalStates?.reset()
        } else {
            processedTokenCount = tokenIndex
            history.truncate(to: tokenIndex)
        }
    }

    public func cleanup() {
        // Release engine resources
        drain()
    }
}

// MARK: - GenerationSequence

@available(macOS 27.0, iOS 27.0, *)
extension CoreAISequentialEngine {
    /// Async sequence of `InferenceOutput` produced by `generate()`.
    struct GenerationSequence: InferenceOutputSequence {
        typealias Element = InferenceOutput
        typealias Failure = Error

        let engine: CoreAISequentialEngine
        let input: [CoreAISequentialEngine.TokenId]
        let samplingConfiguration: SamplingConfiguration
        let inferenceOptions: InferenceOptions
        let generationToken: GenerationToken

        let stopReasonStore = StopReasonStore()

        var stopReason: InferenceStopReason? { stopReasonStore.stopReason }

        func setStopReason(_ reason: InferenceStopReason) {
            stopReasonStore.set(reason)
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(
                engine: engine,
                input: input,
                samplingConfiguration: samplingConfiguration,
                inferenceOptions: inferenceOptions,
                stopReasonStore: stopReasonStore,
                generationToken: generationToken
            )
        }
    }
}

// MARK: - Iterator

@available(macOS 27.0, iOS 27.0, *)
extension CoreAISequentialEngine.GenerationSequence {
    final class Iterator: AsyncIteratorProtocol {
        typealias Element = InferenceOutput
        typealias Failure = Error

        private let engine: CoreAISequentialEngine
        private let samplingConfiguration: SamplingConfiguration
        private let returnsLogits: Bool
        private let forcedContinuation: [CoreAISequentialEngine.TokenId]?
        private let maxTokens: Int
        private let stopReasonStore: StopReasonStore
        private let generationToken: GenerationToken

        private var inputTokens: [CoreAISequentialEngine.TokenId]
        private var step: Int = 0
        private var finished: Bool = false
        // Prompt length at turn start — repetition penalty only penalizes
        // tokens generated this turn (inputTokens[generationStartOffset...]).
        // Aligned with upstream coreai-models CoreAISequentialEngine (5660fc6).
        private let generationStartOffset: Int

        init(
            engine: CoreAISequentialEngine,
            input: [CoreAISequentialEngine.TokenId],
            samplingConfiguration: SamplingConfiguration,
            inferenceOptions: InferenceOptions,
            stopReasonStore: StopReasonStore,
            generationToken: GenerationToken
        ) {
            self.engine = engine
            self.samplingConfiguration = samplingConfiguration.normalized()
            self.returnsLogits = inferenceOptions.includeLogits
            self.forcedContinuation = inferenceOptions.forcedContinuation
            if let forced = inferenceOptions.forcedContinuation {
                self.maxTokens = forced.count
            } else {
                self.maxTokens = Swift.min(
                    inferenceOptions.maxTokens ?? Int.max,
                    Swift.max(0, engine.config.maxContextLength - input.count)
                )
            }
            self.stopReasonStore = stopReasonStore
            self.generationToken = generationToken
            self.inputTokens = input
            self.generationStartOffset = input.count
        }

        deinit {
            engine.clearTokenIfActive(generationToken)
        }

        @MainActor
        func next() async throws -> InferenceOutput? {
            if finished { return nil }

            if generationToken.isCancelled {
                stopReasonStore.set(.cancelled)
                finishAndRelease()
                return nil
            }

            guard step < maxTokens else {
                stopReasonStore.setIfUnset(.maxTokens)
                finishAndRelease()
                return nil
            }

            do {
                try Task.checkCancellation()

                guard engine.processedTokenCount < inputTokens.count else {
                    throw InferenceRuntimeError.invalidState("No new tokens to process")
                }

                let oldProcessedCount = engine.processedTokenCount
                let newTokens = inputTokens[engine.processedTokenCount...]
                let strategy = engine.selectPrefillStrategy(newTokenCount: newTokens.count)

                let logitBuffer: [LogitsScalarType]
                switch strategy {
                case .chunked(let chunkSize):
                    logitBuffer = try await engine.processChunkedPrompt(
                        tokens: newTokens, chunkSize: chunkSize)
                case .wholeBatch:
                    let allLogits = try await engine.processTokenBatch(newTokens)
                    logitBuffer = lastTokenLogits(
                        from: allLogits, vocabSize: engine.config.vocabSize)
                case .oneAtATime:
                    var lastLogits: [LogitsScalarType] = []
                    for j in newTokens.indices {
                        lastLogits = try await engine.processTokenBatch(newTokens[j ... j])
                    }
                    logitBuffer = lastLogits
                }

                // Update history with newly processed tokens
                let processedSlice = inputTokens[oldProcessedCount ..< engine.processedTokenCount]
                engine.history.append(contentsOf: processedSlice)

                // Check cancellation after inference
                if generationToken.isCancelled {
                    stopReasonStore.set(.cancelled)
                    finishAndRelease()
                    return nil
                }

                let nextToken: Int32
                if let forced = forcedContinuation {
                    nextToken = forced[step]
                } else {
                    var mutableLogits = logitBuffer
                    nextToken = samplingConfiguration.fallbackSampler(
                        from: &mutableLogits, tokenHistory: inputTokens[generationStartOffset...])
                }

                // Check for EOS
                if nextToken == engine.config.eosTokenId {
                    stopReasonStore.set(.eos)
                    inputTokens.append(nextToken)
                    engine.history.append(nextToken)
                    step += 1
                    finishAndRelease()
                    return InferenceOutput(
                        tokenId: nextToken, logits: returnsLogits ? logitBuffer : nil)
                }

                inputTokens.append(nextToken)
                step += 1

                return InferenceOutput(
                    tokenId: nextToken,
                    logits: returnsLogits ? logitBuffer : nil
                )
            } catch is CancellationError {
                stopReasonStore.set(.cancelled)
                finishAndRelease()
                throw CancellationError()
            } catch {
                stopReasonStore.set(.error)
                finishAndRelease()
                throw error
            }
        }

        private func finishAndRelease() {
            guard !finished else { return }
            finished = true
            engine.clearTokenIfActive(generationToken)
        }
    }
}

#endif  // canImport(CoreAI)
