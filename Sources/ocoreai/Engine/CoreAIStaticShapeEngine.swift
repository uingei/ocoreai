// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — aligned with coreai-models CoreAIStaticShapeEngine.swift HEAD f401272
//
/// Static-shape inference engine using Core AI chunked models (.aimodel).
///
/// Model Contract:
/// - **Extend functions**: `extend_<context>_<seq>` or `prompt_opt_<context>_<seq>` (chunked)
/// - **Gather functions**: `gather_embeddings_<batchSize>` (optional)
/// - **Embedding table**: loaded once at init via `load_embeddings`
/// - **2 states**: `key_cache` + `value_cache` (fixed NDArray, no growth)
/// - **1 output**: `out_logits`
///
/// KV cache allocated ONCE to max-context descriptor shape, reused across all
/// extend functions (same shape, strides, interleaveLayout).
/// Chunked prefill via multiple extend calls. CPU fallback sampler.

#if canImport(CoreAI)

import CoreAI
import Foundation
import Logging
import Synchronization

private enum StaticShapeLog {
    static let log = Logger(label: "ocoreai.coreai.staticshape")
}

// MARK: - CoreAI StaticShape Engine

@available(macOS 27.0, iOS 27.0, *)
final class CoreAIStaticShapeEngine: InferenceEngine, @unchecked Sendable {
    typealias ConfigType = InternalModelConfig
    typealias TokenId = Int32

    /// IO name contracts — aligns with upstream StaticShapeEngine.
    private static let keyCacheName = "key_cache"
    private static let valueCacheName = "value_cache"
    private static let logitsOutputName = "out_logits"

    var supportsLogits: Bool { true }
    let config: InternalModelConfig

    // CoreAI model handle
    private let model: AIModel

    // Lazily loaded inference functions, keyed by name.
    private var functions: [String: InferenceFunction]

    // Function name categories
    private let extendFunctionNames: [String]
    private let gatherFunctionNames: Set<String>

    // Embedding table loaded once at init
    private let embeddingTable: NDArray

    // Largest query length — prefill threshold
    private let maxQueryLength: Int

    // Fixed-size KV cache — reused, never reallocated
    private var keyCache: NDArray
    private var valueCache: NDArray

    // State
    public private(set) var processedTokenCount: Int = 0
    private var history = TokenHistory()
    public private(set) var lastPrefixHitCount: Int = 0
    private let _activeToken = Mutex<GenerationToken?>(nil)
    public var isBusy: Bool { _activeToken.withLock { $0 != nil } }

    func clearTokenIfActive(_ token: GenerationToken) {
        _activeToken.withLock { if $0 === token { $0 = nil } }
    }

    // MARK: - Init

    init(
        config: InternalModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions
    ) async throws {
        self.config = config
        self.model = preparedModel.model
        self.functions = [:]

        let allNames = model.functionNames

        // Categorize
        self.extendFunctionNames =
            allNames.filter { $0.hasPrefix("extend") || $0.hasPrefix("prompt") }.sorted()
        self.gatherFunctionNames = Set(allNames.filter { $0.hasPrefix("gather_embeddings") })

        // Max query length from function names
        self.maxQueryLength =
            extendFunctionNames.compactMap { name -> Int? in
                name.split(separator: "_").last.flatMap { Int($0) }
            }.max() ?? 64

        // Find max-context extend function (for KV cache descriptors)
        var largestContext: (String, InferenceFunctionDescriptor)?
        for name in extendFunctionNames {
            let desc = try Self.requireDescriptor(model: model, functionName: name)
            if Self.contextLength(descriptor: desc, config: config) == config.maxContextLength {
                largestContext = (name, desc)
                break
            }
        }
        guard let (largestName, largestDesc) = largestContext else {
            throw InferenceRuntimeError.invalidState(
                "No extend function for max context \u{5c}\(config.maxContextLength)")
        }

        try Self.validateIOContract(descriptor: largestDesc, functionName: largestName)
        self.embeddingTable = try await Self.loadEmbeddingTable(from: model)

        // Allocate KV cache
        if case .ndArray(let kd) = largestDesc.stateDescriptor(of: Self.keyCacheName),
            case .ndArray(let vd) = largestDesc.stateDescriptor(of: Self.valueCacheName)
        {
            self.keyCache = NDArray(descriptor: kd)
            self.valueCache = NDArray(descriptor: vd)
        } else {
            throw InferenceRuntimeError.invalidState(
                "No KV cache state in \u{5c}\(largestName)")
        }
    }

    convenience init(
        config: InternalModelConfig,
        modelURL: URL,
        options: EngineOptions
    ) async throws {
        let pm = try await PreparedModel.prepare(at: modelURL, functionName: config.function)
        try await self.init(config: config, preparedModel: pm, options: options)
    }

    // MARK: - Helpers

    private static func requireDescriptor(
        model: AIModel, functionName: String
    ) throws -> InferenceFunctionDescriptor {
        guard let desc = model.functionDescriptor(for: functionName) else {
            throw InferenceRuntimeError.invalidState("No descriptor: \u{5c}\(functionName)")
        }
        return desc
    }

    private static func contextLength(
        descriptor: InferenceFunctionDescriptor, config: InternalModelConfig
    ) -> Int {
        if case .ndArray(let kd) = descriptor.stateDescriptor(of: Self.keyCacheName) {
            if kd.shape.contains(-1) { return config.maxContextLength }
            return kd.shape.max() ?? config.maxContextLength
        }
        return config.maxContextLength
    }

    private static func validateIOContract(
        descriptor: InferenceFunctionDescriptor, functionName: String
    ) throws {
        guard descriptor.outputNames.contains(Self.logitsOutputName) else {
            throw InferenceRuntimeError.invalidState(
                "\u{5c}\(functionName) missing output \u{5c}\(Self.logitsOutputName)")
        }
        if descriptor.stateNames.count == 1 {
            throw InferenceRuntimeError.invalidState(
                "\u{5c}\(functionName) has 1 state, expected 0 or 2")
        }
        if descriptor.stateNames.count >= 2 {
            guard descriptor.stateNames.contains(Self.keyCacheName),
                descriptor.stateNames.contains(Self.valueCacheName)
            else {
                throw InferenceRuntimeError.invalidState(
                    "\u{5c}\(functionName) missing KV cache states")
            }
        }
    }

    private static func loadEmbeddingTable(from model: AIModel) async throws -> NDArray {
        guard let fn = try model.loadFunction(named: "load_embeddings") else {
            throw InferenceRuntimeError.invalidState("Missing load_embeddings function")
        }
        guard case .ndArray(let desc) = fn.descriptor.outputDescriptor(of: "embedding_table") else {
            throw InferenceRuntimeError.invalidState(
                "load_embeddings has no embedding_table output")
        }
        var arr = NDArray(descriptor: desc)
        var outViews = InferenceFunction.MutableViews()
        outViews.insert(&arr, for: "embedding_table")
        _ = try await fn.run(inputs: [:], outputViews: outViews)
        return arr
    }

    private func loadFunction(named name: String) throws -> InferenceFunction {
        if let c = functions[name] { return c }
        guard let fn = try model.loadFunction(named: name) else {
            throw InferenceRuntimeError.invalidState("Cannot load: \u{5c}\(name)")
        }
        functions[name] = fn
        return fn
    }

    private func functionDescriptor(for name: String) throws -> InferenceFunctionDescriptor {
        if let c = functions[name] { return c.descriptor }
        guard let desc = model.functionDescriptor(for: name) else {
            throw InferenceRuntimeError.invalidState("No descriptor: \u{5c}\(name)")
        }
        return desc
    }

    private func queryLength(of functionName: String) throws -> Int {
        let desc = try functionDescriptor(for: functionName)
        if let txName = desc.inputNames.first(where: { $0.contains("transformer_input") }),
            case .ndArray(let nd) = desc.inputDescriptor(of: txName), nd.shape.count >= 2
        {
            return nd.shape[1]
        }
        let parts = functionName.split(separator: "_")
        return parts.last.flatMap { Int($0) } ?? 1
    }

    // MARK: - Graph Selection

    /// Pick forward graph by walking (context, seq) pairs from extend function names,
    /// selecting smallest context > currentPosition and seq >= numInputTokens.
    private func forwardGraph(
        numInputTokens: Int, currentPosition: Int, isPrefill: Bool
    ) throws -> String {
        var pairs: [(Int, Int)] = []
        for name in extendFunctionNames {
            let parts = Array(name.split(separator: "_").suffix(2))
            guard parts.count == 2,
                let ctx = Int(parts[0]),
                let seq = Int(parts[1])
            else { continue }
            pairs.append((ctx, seq))
        }
        let sorted = pairs.sorted(by: { $0.1 < $1.1 })
        guard let maxPair = sorted.last else {
            throw InferenceRuntimeError.invalidState("No extend functions")
        }
        let selectedSeq = sorted.first(where: { $0.1 >= numInputTokens })?.1 ?? maxPair.1
        let candidates = pairs.filter { $0.1 == selectedSeq }
        guard
            let selected =
                candidates
                .sorted(by: { $0.0 < $1.0 })
                .first(where: { $0.0 > currentPosition })
        else {
            throw InferenceRuntimeError.invalidState(
                "No graph: cache>=\u{5c} \(currentPosition), seq=\u{5c}\(selectedSeq)")
        }
        let prefix = isPrefill ? "prompt_opt_" : "extend_"
        return prefix + "\(selected.0)_\(selected.1)"
    }

    // MARK: - Causal Mask

    private static func fillCausalMask(
        _ view: consuming NDArray.MutableView<LogitsScalarType>,
        tokensInBatch: Int,
        alignedStep: Int
    ) {
        view.withUnsafeMutablePointer { ptr, shape, strides in
            for ctx in 0 ..< shape[1] {
                for q in 0 ..< shape[3] {
                    ptr[ctx &* strides[1] &+ q &* strides[3]] = LogitsScalarType(-40000.0)
                }
            }
            for q in 0 ..< tokensInBatch {
                let qp = alignedStep + q
                let ub = min(qp, shape[1] &- 1)
                for ctx in 0 ... ub {
                    ptr[ctx &* strides[1] &+ q &* strides[3]] = 0
                }
            }
        }
    }

    // MARK: - InferenceEngine.generate()

    public func generate(
        with input: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> GenerationSequence {
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }

        if !history.isEmpty {
            let (cp, _) = history.resolve(input: input)
            if cp < input.count && cp < history.count {
                processedTokenCount = 0
                history.clear()
            } else if processedTokenCount >= input.count {
                let rt = Swift.max(0, cp - 1)
                processedTokenCount = rt
                history.truncate(to: rt)
            }
            lastPrefixHitCount = cp
        }

        let token = GenerationToken()
        _activeToken.withLock { $0 = token }
        return GenerationSequence(
            engine: self, input: input,
            samplingConfiguration: samplingConfiguration,
            inferenceOptions: inferenceOptions,
            generationToken: token
        )
    }

    // MARK: - Inference (per iterator step)

    func inference(
        inputTokens: [Int32],
        samplingConfig: SamplingConfiguration,
        returnsLogits: Bool
    ) async throws -> (logits: [LogitsScalarType]?, token: Int32) {
        let total = inputTokens.count
        guard processedTokenCount < total else {
            throw InferenceRuntimeError.invalidState("No new tokens")
        }

        var logitBuffer = [LogitsScalarType](repeating: 0, count: config.vocabSize)
        var pos = processedTokenCount

        while pos < total {
            let remaining = total - pos
            let usePrefill = remaining > maxQueryLength
            let graphName = try forwardGraph(
                numInputTokens: remaining, currentPosition: pos, isPrefill: usePrefill)

            let batchSize = try queryLength(of: graphName)
            let bs = (pos / batchSize) * batchSize
            let be = Swift.min(bs + batchSize - 1, total - 1)
            let tib = be - bs + 1

            let inputs = try await buildInputs(
                graphName: graphName, batchTokens: inputTokens[bs ... be],
                batchSize: batchSize, alignedStep: bs, tokensInBatch: tib)

            let fn = try loadFunction(named: graphName)
            let desc = try functionDescriptor(for: graphName)

            guard case .ndArray(let kd) = desc.stateDescriptor(of: Self.keyCacheName),
                case .ndArray(let vd) = desc.stateDescriptor(of: Self.valueCacheName)
            else {
                throw InferenceRuntimeError.invalidState("No KV cache desc for \(graphName)")
            }

            let kvm0 = _overrideLifetime(
                keyCache.mutableRawView().slice(at: kd.shape.map { 0 ..< $0 }),
                borrowing: Void())
            let kvm1 = _overrideLifetime(
                valueCache.mutableRawView().slice(at: vd.shape.map { 0 ..< $0 }),
                borrowing: Void())

            var states = InferenceFunction.MutableViews()
            states.insert(kvm0, for: Self.keyCacheName)
            states.insert(kvm1, for: Self.valueCacheName)

            var outputs = try await fn.run(
                inputs: inputs, states: states,
                outputViews: InferenceFunction.MutableViews())

            if !usePrefill, let la = outputs.remove(Self.logitsOutputName)?.ndArray {
                let lv = la.view(as: LogitsScalarType.self)
                guard let lg = lv.contiguousElements else {
                    throw InferenceRuntimeError.invalidState("Non-contiguous logits")
                }
                let off = (tib - 1) * config.vocabSize
                for i in 0 ..< config.vocabSize { logitBuffer[i] = lg[off + i] }
            }

            pos = be + 1
            processedTokenCount = pos
        }

        let nextToken = samplingConfig.fallbackSampler(from: &logitBuffer)
        return (logits: returnsLogits ? logitBuffer : nil, token: nextToken)
    }

    // MARK: - Build Inputs

    private func buildInputs<T: Collection<Int32>>(
        graphName: String, batchTokens: T,
        batchSize: Int, alignedStep: Int, tokensInBatch: Int
    ) async throws -> [String: NDArray] {
        let desc = try functionDescriptor(for: graphName)
        var inputs = [String: NDArray]()

        if desc.inputNames.contains("embedding_table") {
            inputs["embedding_table"] = embeddingTable
        }

        if let txName = desc.inputNames.first(where: { $0.contains("transformer_input") }) {
            let gName = "gather_embeddings_\(batchSize)"
            guard gatherFunctionNames.contains(gName) else {
                throw InferenceRuntimeError.invalidState("No gather: \(gName)")
            }
            guard
                let gathered = try await runGather(
                    tokenIDs: Array(batchTokens), batchSize: batchSize)
            else { throw InferenceRuntimeError.invalidState("Gather \(gName) no output") }
            inputs[txName] = gathered
        }

        guard let posName = desc.inputNames.first(where: { $0.contains("pos") }) else {
            throw InferenceRuntimeError.invalidState("No pos input in \(graphName)")
        }
        if case .ndArray(let nd) = desc.inputDescriptor(of: posName) {
            var pos = NDArray(descriptor: nd)
            let pv = pos.mutableView(as: UInt16.self)
            guard var ps = pv.contiguousElements else {
                throw InferenceRuntimeError.invalidState("pos non-contiguous")
            }
            for i in 0 ..< batchSize { ps[i] = UInt16(alignedStep + i) }
            inputs[posName] = pos
        }

        if case .ndArray(let nd) = desc.inputDescriptor(of: "causal_mask") {
            var mask = NDArray(descriptor: nd)
            let mv = mask.mutableView(as: LogitsScalarType.self)
            Self.fillCausalMask(mv, tokensInBatch: tokensInBatch, alignedStep: alignedStep)
            inputs["causal_mask"] = mask
        }

        if let sName = desc.inputNames.first(where: { $0.contains("step") && !$0.contains("pos") }),
            case .ndArray(let nd) = desc.inputDescriptor(of: sName)
        {
            var step = NDArray(descriptor: nd)
            let sv = step.mutableView(as: Int32.self)
            guard var ss = sv.contiguousElements else {
                throw InferenceRuntimeError.invalidState("step non-contiguous")
            }
            ss[0] = Int32(alignedStep)
            inputs[sName] = step
        }

        return inputs
    }

    // MARK: - Gather

    private func runGather(tokenIDs: [Int32], batchSize: Int) async throws -> NDArray? {
        let name = "gather_embeddings_\(batchSize)"
        let fn = try loadFunction(named: name)
        let desc = try functionDescriptor(for: name)

        guard let td = desc.inputDescriptor(of: "in_new_token_ids"),
            case .ndArray(let nd) = td
        else {
            throw InferenceRuntimeError.invalidState("No token desc for \(name)")
        }

        var ta = NDArray(descriptor: nd)
        let tv = ta.mutableView(as: Int32.self)
        guard var sp = tv.contiguousElements else {
            throw InferenceRuntimeError.invalidState("token array non-contiguous")
        }

        if nd.shape.count == 2 {
            for i in 0 ..< Swift.min(batchSize, tokenIDs.count) { sp[i] = tokenIDs[i] }
        } else {
            sp[0] = tokenIDs[0]
        }

        var out = try await fn.run(
            inputs: ["in_new_token_ids": ta],
            states: InferenceFunction.MutableViews(),
            outputViews: InferenceFunction.MutableViews())

        return out.remove("out_transformer_input")?.ndArray
            ?? out.remove(desc.outputNames.first ?? "")?.ndArray
    }

    // MARK: - Lifecycle

    public func cancel() async throws {
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    public func reset(to tokenIndex: Int) async throws {
        guard tokenIndex >= 0 && tokenIndex <= processedTokenCount else {
            throw InferenceRuntimeError.invalidState("reset out of range")
        }
        _activeToken.withLock {
            $0?.cancel()
            $0 = nil
        }
        if tokenIndex == 0 {
            processedTokenCount = 0
            history.clear()
        } else {
            processedTokenCount = tokenIndex
            history.truncate(to: tokenIndex)
        }
    }

    public func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {
        for fnName in extendFunctionNames { _ = try loadFunction(named: fnName) }
        try await reset()
    }
}

// MARK: - GenerationSequence

@available(macOS 27.0, iOS 27.0, *)
extension CoreAIStaticShapeEngine {
    struct GenerationSequence: InferenceOutputSequence {
        typealias Element = InferenceOutput
        typealias Failure = Error

        let engine: CoreAIStaticShapeEngine
        let input: [Int32]
        let samplingConfiguration: SamplingConfiguration
        let inferenceOptions: InferenceOptions
        let generationToken: GenerationToken

        private let stopReasonStore = StopReasonStore()

        var stopReason: InferenceStopReason? { stopReasonStore.stopReason }
        func setStopReason(_ reason: InferenceStopReason) { stopReasonStore.set(reason) }

        func makeAsyncIterator() -> Iterator {
            Iterator(
                engine: engine, input: input,
                samplingConfiguration: samplingConfiguration,
                inferenceOptions: inferenceOptions,
                stopReasonStore: stopReasonStore,
                generationToken: generationToken)
        }
    }
}

// MARK: - Iterator

@available(macOS 27.0, iOS 27.0, *)
extension CoreAIStaticShapeEngine.GenerationSequence {
    final class Iterator: AsyncIteratorProtocol {
        typealias Element = InferenceOutput
        typealias Failure = Error

        private let engine: CoreAIStaticShapeEngine
        private let samplingConfig: SamplingConfiguration
        private let returnsLogits: Bool
        private let forcedContinuation: [Int32]?
        private let maxTokens: Int
        private let stopReasonStore: StopReasonStore
        private let generationToken: GenerationToken
        private var inputTokens: [Int32]
        private var step: Int = 0
        private var finished: Bool = false

        init(
            engine: CoreAIStaticShapeEngine, input: [Int32],
            samplingConfiguration cfg: SamplingConfiguration,
            inferenceOptions: InferenceOptions,
            stopReasonStore: StopReasonStore,
            generationToken: GenerationToken
        ) {
            self.engine = engine
            self.samplingConfig = cfg.normalized()
            self.returnsLogits = inferenceOptions.includeLogits
            self.forcedContinuation = inferenceOptions.forcedContinuation
            self.stopReasonStore = stopReasonStore
            self.generationToken = generationToken
            self.inputTokens = input
            if let fc = inferenceOptions.forcedContinuation {
                self.maxTokens = fc.count
            } else {
                self.maxTokens = Swift.min(
                    inferenceOptions.maxTokens ?? Int.max,
                    Swift.max(0, engine.config.maxContextLength - input.count))
            }
        }

        deinit { engine.clearTokenIfActive(generationToken) }

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
                let old = engine.processedTokenCount
                let (logits, sampled) = try await engine.inference(
                    inputTokens: inputTokens,
                    samplingConfig: samplingConfig,
                    returnsLogits: returnsLogits || forcedContinuation != nil)
                let slice = inputTokens[old ..< engine.processedTokenCount]
                engine.history.append(contentsOf: slice)
                if generationToken.isCancelled {
                    stopReasonStore.set(.cancelled)
                    finishAndRelease()
                    return nil
                }
                let nt = forcedContinuation?[step] ?? sampled
                inputTokens.append(nt)
                step += 1
                return InferenceOutput(tokenId: nt, logits: returnsLogits ? logits : nil)
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
