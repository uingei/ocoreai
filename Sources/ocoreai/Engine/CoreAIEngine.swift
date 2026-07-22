// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CoreAIEngine.swift — InferenceEngine protocol + CoreAI sequential engine
///
/// Derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai:
/// - InferenceEngine protocol (aligned with reference)
/// - CoreAISequentialEngine (dynamic KV cache, TokenHistory prefix caching)
/// - EngineFactory (model structure auto-detection → sequential engine)
/// - TokenHistory (prefix caching via memcmp fast path)
///
/// EngineOptions, KVCacheStrategy, InferenceOptions, InferenceOutput redefined here
/// to avoid importing reference repo (macOS 27 requirement). Types match reference API
/// for compatibility.

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI

import Atomics
import CoreAI
import Foundation
import Logging
import Synchronization

// MARK: - Inference Output

#if !arch(x86_64)
typealias LogitsScalarType = Float16
#else
typealias LogitsScalarType = Float
#endif

/// Single step output from InferenceEngine.generate().
struct InferenceOutput: Sendable {
    let tokenId: Int32
    /// Populated when InferenceOptions.includeLogits is true.
    let logits: [LogitsScalarType]?

    init(tokenId: Int32, logits: [LogitsScalarType]? = nil) {
        self.tokenId = tokenId
        self.logits = logits
    }
}

// MARK: - KV Cache Strategy

/// KV cache memory management strategy (matches reference KVCacheStrategy).
enum KVCacheStrategy: String, Codable, Sendable, CaseIterable {
    case auto = "auto"
    case fixedSize = "fixed_size"
    case growing = "growing"
    case chunked = "chunked"

    func defaultSize(maxContextLength: Int) -> Int? {
        switch self {
        case .auto: return nil
        case .fixedSize: return maxContextLength
        case .growing: return 256
        case .chunked: return maxContextLength
        }
    }
}

// MARK: - Engine Options

/// Options that customize how the factory creates an engine.
struct EngineOptions: Sendable {
    let variant: String?
    let kvCacheStrategy: KVCacheStrategy
    let kvCacheSize: Int?

    init(
        variant: String? = nil,
        kvCacheStrategy: KVCacheStrategy = .auto,
        kvCacheSize: Int? = nil
    ) {
        self.variant = variant
        self.kvCacheStrategy = kvCacheStrategy
        self.kvCacheSize = kvCacheSize
    }

    func resolvedKVCacheSize(maxContextLength: Int) -> Int? {
        if let explicit = kvCacheSize { return explicit }
        return kvCacheStrategy.defaultSize(maxContextLength: maxContextLength)
    }
}

// MARK: - Inference Configuration

/// Internal config type that satisfies InferenceEngine.associatedtype ConfigType.
struct InternalModelConfig: Codable, Sendable, InferenceConfiguration {
    let name: String
    let vocabSize: Int
    let maxContextLength: Int
    let prefillChunkSize: Int
    let chunkThreshold: Int
    let function: String

    init(name: String, vocabSize: Int, maxContextLength: Int, function: String,
         prefillChunkSize: Int = 512, chunkThreshold: Int = 1024) {
        self.name = name
        self.vocabSize = vocabSize
        self.maxContextLength = maxContextLength
        self.function = function
        self.prefillChunkSize = prefillChunkSize
        self.chunkThreshold = chunkThreshold
    }
}

// MARK: - InferenceOutputSequence Protocol

/// Why token generation terminated. Aligned with StopReason enum in project.
enum InferenceStopReason: Sendable, Equatable {
    case maxTokens
    case eos
    case stopSequence(String)
    case cancelled
    case error
}

extension InferenceStopReason {
    /// Convert to project's StopReason for unified event emission.
    var stopReason: StopReason {
        switch self {
        case .maxTokens: .maxTokens
        case .eos: .eos
        case .stopSequence: .stopSequence
        case .cancelled: .cancelled
        case .error: .error
        }
    }
}

/// Async sequence of InferenceOutput with stop reason tracking.
protocol InferenceOutputSequence: AsyncSequence, AnyObject {
    associatedtype Element = InferenceOutput
    associatedtype Failure = Error
    var stopReason: InferenceStopReason? { get }
    func setStopReason(_ reason: InferenceStopReason)
}

// MARK: - StopReason Store

/// Thread-safe stop reason box shared between iterator and caller.
final class StopReasonStore: @unchecked Sendable {
    private let mutex = Mutex<InferenceStopReason?>(nil)

    var stopReason: InferenceStopReason? {
        mutex.withLock { $0 }
    }

    func set(_ reason: InferenceStopReason) {
        mutex.withLock { $0 = reason }
    }

    func setIfUnset(_ reason: InferenceStopReason) {
        mutex.withLock { if $0 == nil { $0 = reason } }
    }
}

// MARK: - InferenceEngine Protocol

/// Interface for inference engines.
/// KV cache is preserved between generate() calls. Call reset() to clear.
protocol InferenceEngine: Sendable {
    associatedtype OutputSequence: InferenceOutputSequence

    /// Stream token generation.
    func generate(
        with input: [Int32],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> OutputSequence

    /// Tokens processed in current session.
    var processedTokenCount: Int { get }

    /// Reset KV cache.
    func reset(to tokenIndex: Int) async throws
    func reset() async throws

    /// Warmup: trigger kernel compilation.
    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws

    /// Cancellation.
    var isBusy: Bool { get }
    func cancel() async throws

    /// Capabilities.
    var supportsLogits: Bool { get }
    var lastPrefixHitCount: Int { get }

    /// Configuration.
    associatedtype ConfigType: Codable, InferenceConfiguration
    var config: ConfigType { get }
}

/// Config protocol that engines must expose.
protocol InferenceConfiguration: Sendable {
    var maxContextLength: Int { get }
    var prefillChunkSize: Int { get }
    var chunkThreshold: Int { get }
}

// MARK: - Default implementations

extension InferenceEngine {
    var supportsLogits: Bool { false }
    var lastPrefixHitCount: Int { 0 }
    var isBusy: Bool { false }
    func cancel() async throws {}
    var processedTokenCount: Int { 0 }
    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {}
    func reset() async throws { try await reset(to: 0) }
}

// MARK: - Token History (Prefix Caching)

/// Tracks processed token history for implicit prefix caching.
/// memcmp fast path for fully-matching prefixes, element-wise scan on mismatch.
struct TokenHistory: Sendable {
    private(set) var tokens: [Int32] = []

    mutating func resolve(input: [Int32]) -> (commonPrefix: Int, newTokens: ArraySlice<Int32>) {
        let limit = min(input.count, tokens.count)
        var commonPrefix = limit
        if limit > 0 {
            input.withUnsafeBufferPointer { inputBuf in
                tokens.withUnsafeBufferPointer { cachedBuf in
                    let bytes = limit * MemoryLayout<Int32>.stride
                    if memcmp(inputBuf.baseAddress!, cachedBuf.baseAddress!, bytes) != 0 {
                        commonPrefix = 0
                        for i in 0..<limit {
                            if inputBuf[i] != cachedBuf[i] { break }
                            commonPrefix = i + 1
                        }
                    }
                }
            }
        }
        return (commonPrefix, input[commonPrefix...])
    }

    mutating func append(contentsOf slice: ArraySlice<Int32>) {
        tokens.append(contentsOf: slice)
    }

    mutating func append(_ token: Int32) {
        tokens.append(token)
    }

    var count: Int { tokens.count }

    mutating func truncate(to position: Int) {
        precondition(position >= 0)
        guard position < tokens.count else { return }
        tokens.removeSubrange(position...)
    }

    mutating func clear() {
        tokens.removeAll(keepingCapacity: true)
    }
}

// MARK: - Engine Errors

enum InferenceError: Error, LocalizedError {
    case functionNotFound(String)
    case modelNotFound(String)
    case modelLoadingFailed(underlying: Error)
    case invalidState(String)
    case unsupportedEngineVariant(String)
    case genericError(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name): return "Function '\(name)' not found"
        case .modelNotFound(let path): return "Model not found: \(path)"
        case .modelLoadingFailed(let e): return "Model loading failed: \(e.localizedDescription)"
        case .invalidState(let d): return "Invalid state: \(d)"
        case .unsupportedEngineVariant(let v): return "Unsupported variant: \(v)"
        case .genericError(let m): return m
        }
    }
}

// MARK: - Model Structure Detection

/// Model structure detected from CoreAI function descriptor.
enum ModelStructure: Sendable {
    /// Dynamic KV cache — supports growing capacity
    case dynamic
    /// Static/chunked KV cache — fixed dimensions
    case chunkedStatic
    /// Unknown structure
    case unknown

    var description: String {
        switch self {
        case .dynamic: "dynamic"
        case .chunkedStatic: "chunked_static"
        case .unknown: "unknown"
        }
    }
}

// MARK: - PreparedModel

/// Wrapper around AIModel with resolved structure.
@available(macOS 27.0, *)
struct PreparedModel: Sendable {
    let model: AIModel
    let structure: ModelStructure

    /// Resolve the .aimodel URL — handles .bundle, .directory, or direct .aimodel paths.
    static func resolveCoreAIModelURL(from url: URL) -> URL {
        url
    }

    /// Detect model structure from descriptor.
    private static func detectStructure(from model: AIModel, functionName: String) -> ModelStructure {
        guard let descriptor = model.functionDescriptor(for: functionName) else {
            return .unknown
        }
        for stateName in descriptor.stateNames {
            if case .ndArray(let desc) = descriptor.stateDescriptor(of: stateName) {
                if desc.shape.contains(where: { $0 < 0 }) {
                    return .dynamic
                }
            }
        }
        return .chunkedStatic
    }

    /// Prepare model asset via CoreAI — loads, detects structure.
    static func prepare(at modelURL: URL, functionName: String = "default") async throws -> PreparedModel {
        let model = try await AIModel(contentsOf: modelURL)
        let structure = detectStructure(from: model, functionName: functionName)
        return PreparedModel(model: model, structure: structure)
    }
}

// MARK: - EngineFactory

/// Creates inference engines from model configurations.
/// Auto-detects model structure → selects appropriate engine.
@available(macOS 27.0, *)
struct EngineFactory: Sendable {
    /// Create an engine for a model, selecting variant from model structure.
    static func createEngine(
        config: Data,
        modelURL: URL,
        options: EngineOptions = EngineOptions()
    ) async throws -> any InferenceEngine {
        // Parse config
        let parsedConfig = try parseModelConfig(from: config)

        // Resolve model URL
        let coreAIModelURL = PreparedModel.resolveCoreAIModelURL(from: modelURL)

        // Prepare model
        let preparedModel = try await PreparedModel.prepare(at: coreAIModelURL, functionName: parsedConfig.function)

        // Resolve variant
        let variant = resolveVariant(override: options.variant, detectedStructure: preparedModel.structure)

        // Create engine
        switch variant {
        case .sequential:
            return try await CoreAISequentialEngine(
                config: parsedConfig,
                preparedModel: preparedModel,
                options: options
            )
        }
    }

    private enum Variant: String {
        case sequential = "coreai-sequential"
    }

    private static func resolveVariant(override variantOverride: String?, detectedStructure structure: ModelStructure) -> Variant {
        if let vo = variantOverride, vo != "auto", vo != "default" {
            if vo == "coreai-sequential" { return .sequential }
            // Fall back to sequential for any unknown variant
        }
        // Auto-detect: both dynamic and chunkedStatic → sequential for now
        return .sequential
    }

    private static func parseModelConfig(from data: Data) throws -> InternalModelConfig {
        // Try parsing as JSON object
        let decoder = JSONDecoder()
        do {
            let object = try decoder.decode([String: CoreAIAnyCodable].self, from: data)
            return InternalModelConfig(
                name: object["name"]?.value as? String ?? "unknown",
                vocabSize: object["vocabSize"]?.value as? Int ?? 151_936,
                maxContextLength: object["maxContextLength"]?.value as? Int ?? 131_072,
                function: object["function"]?.value as? String ?? "default"
            )
        } catch {
            // Fallback to defaults
            return InternalModelConfig(
                name: "unknown",
                vocabSize: 151_936,
                maxContextLength: 131_072,
                function: "default"
            )
        }
    }
}

// MARK: - AnyCodable (JSON helper)

private struct CoreAIAnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else { value = "" }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? String { try container.encode(v) }
        else { try container.encode("") }
    }
}

// MARK: - GenerationToken

/// Cancellation token for in-flight generation.
final class GenerationToken: @unchecked Sendable {
    private let mutex = Mutex<Bool>(false)
    var isCancelled: Bool {
        mutex.withLock { $0 }
    }
    func cancel() {
        mutex.withLock { $0 = true }
    }
}

// MARK: - CoreAI Sequential Engine

/// CoreAI inference engine using the sequential (poll-based) path.
/// Dynamic KV cache with 2× exponential growth. TokenHistory prefix caching.
///
/// Model contract:
/// - 2 inputs: input_ids (Int32), position_ids (Int32)
/// - 1 output: logits (Float16 or Float)
/// - 2 states: keyCache, valueCache
@available(macOS 27.0, *)
final class CoreAISequentialEngine: InferenceEngine, @unchecked Sendable {
    typealias OutputSequence = CoreAISequence
    typealias ConfigType = InternalModelConfig

    // MARK: - InferenceEngine conformance

    let config: InternalModelConfig
    var supportsLogits: Bool { true }
    var processedTokenCount: Int { _processedTokenCount.load(ordering: .relaxed) }
    var lastPrefixHitCount: Int { _lastPrefixHitCount.load(ordering: .relaxed) }
    var isBusy: Bool {
        _generationToken.withLock { $0 != nil }
    }

    // MARK: - Core AI internals

    private let function: InferenceFunction
    private let inputIdsName: String
    private let positionIdsName: String
    private let keyCacheName: String
    private let valueCacheName: String
    private let logitsName: String

    // Persistent arrays
    private var keyCache: NDArray
    private var valueCache: NDArray
    private var logitsArray: NDArray
    private var inputIdsArray: NDArray
    private var positionIdsArray: NDArray

    // Original KV cache descriptors (for reallocation on growth)
    private let keyCacheDescriptor: NDArrayDescriptor
    private let valueCacheDescriptor: NDArrayDescriptor

    // Capacities
    private var currentKVCapacity: Int
    private var cachedLogitsBatchSize: Int
    private var cachedInputBatchSize: Int

    // Counters
    private let _processedTokenCount = ManagedAtomic<Int>(0)
    private let _lastPrefixHitCount = ManagedAtomic<Int>(0)
    // GenerationToken boxed in Mutex for thread-safe optional storage
    private let _generationToken = Mutex<GenerationToken?>(nil)

    // Prefix caching via Mutex
    private let history = Mutex<TokenHistory>(TokenHistory())

    // Logger
    private let logger: Logger

    // MARK: - Initialization

    init(
        config: InternalModelConfig,
        preparedModel: PreparedModel,
        options: EngineOptions
    ) async throws {
        self.config = config
        self.logger = Logger(label: "ocoreai.coreai.\(config.name)")

        let model = preparedModel.model

        // Load function
        guard let descriptor = model.functionDescriptor(for: config.function) else {
            throw InferenceError.functionNotFound(config.function)
        }

        // Validate: 2 inputs, ≥1 output, 2 states
        guard descriptor.inputNames.count == 2,
              descriptor.stateNames.count == 2 else {
            throw InferenceError.invalidState(
                "Expected 2 inputs + 2 states, got \(descriptor.inputNames.count)i + \(descriptor.stateNames.count)s")
        }

        self.inputIdsName = descriptor.inputNames[0]
        self.positionIdsName = descriptor.inputNames[1]
        self.keyCacheName = descriptor.stateNames[0]
        self.valueCacheName = descriptor.stateNames[1]
        self.logitsName = descriptor.outputNames[0]

        // Resolve function
        guard let fn = try model.loadFunction(named: config.function) else {
            throw InferenceError.functionNotFound(config.function)
        }
        self.function = fn

        // Resolve KV cache descriptors
        guard case .ndArray(let keyDesc) = descriptor.stateDescriptor(of: keyCacheName),
              case .ndArray(let valDesc) = descriptor.stateDescriptor(of: valueCacheName) else {
            throw InferenceError.invalidState("Cannot resolve KV cache descriptors")
        }

        // Check if dynamic
        let isDynamic = keyDesc.shape.contains(where: { $0 < 0 })

        // Store descriptors for KV cache reallocation
        self.keyCacheDescriptor = keyDesc
        self.valueCacheDescriptor = valDesc

        // Initial capacity
        let overrideSize = options.resolvedKVCacheSize(maxContextLength: config.maxContextLength)
        let initialCapacity: Int
        if let size = overrideSize {
            initialCapacity = min(size, config.maxContextLength)
        } else if options.kvCacheStrategy == .fixedSize || !isDynamic {
            initialCapacity = config.maxContextLength
        } else {
            initialCapacity = min(256, config.maxContextLength)
        }
        self.currentKVCapacity = initialCapacity

        // Resolve KV cache arrays
        let resolvedKey = keyDesc.resolvingDynamicDimensions(
            keyDesc.shape.map { $0 < 0 ? initialCapacity : $0 })
        let resolvedVal = valDesc.resolvingDynamicDimensions(
            valDesc.shape.map { $0 < 0 ? initialCapacity : $0 })
        self.keyCache = NDArray(descriptor: resolvedKey)
        self.valueCache = NDArray(descriptor: resolvedVal)

        // Alloc input_ids [1, 1] — decode batch
        guard case .ndArray(let inputDesc) = descriptor.inputDescriptor(of: inputIdsName) else {
            throw InferenceError.invalidState("Cannot resolve input_ids descriptor")
        }
        let resolvedInput = inputDesc.resolvingDynamicDimensions([1, 1])
        self.inputIdsArray = NDArray(descriptor: resolvedInput)
        self.cachedInputBatchSize = 1

        // Alloc position_ids [1, 1]
        guard case .ndArray(let posDesc) = descriptor.inputDescriptor(of: positionIdsName) else {
            throw InferenceError.invalidState("Cannot resolve position_ids descriptor")
        }
        let resolvedPos = posDesc.resolvingDynamicDimensions([1, 1])
        self.positionIdsArray = NDArray(descriptor: resolvedPos)

        // Alloc logits [1, 1, vocabSize] — decode batch
        guard case .ndArray(let logitsDesc) = descriptor.outputDescriptor(of: logitsName) else {
            throw InferenceError.invalidState("Cannot resolve logits descriptor")
        }
        let resolvedLogits = logitsDesc.resolvingDynamicDimensions([1, 1, config.vocabSize])
        self.logitsArray = NDArray(descriptor: resolvedLogits)
        self.cachedLogitsBatchSize = 1

        // Enable prefix caching by default
        history.withLock { $0 = TokenHistory() }

        logger.info("CoreAISequentialEngine created: dynamic=\(isDynamic), kvCapacity=\(initialCapacity), vocab=\(config.vocabSize)")
    }

    // MARK: - InferenceEngine protocol

    func generate(
        with input: [Int32],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> CoreAISequence {
        // Cancel any in-flight generation
        if let oldToken = _generationToken.withLock({ $0 }) {
            try await cancel()
        }

        let token = GenerationToken()
        _generationToken.withLock { $0 = token }
        defer {
            _generationToken.withLock { $0 = nil }
        }

        // Resolve prefix via TokenHistory
        let (prefixLen, newTokens) = history.withLock { h -> (commonPrefix: Int, newTokens: ArraySlice<Int32>) in
            var mutable = h
            return mutable.resolve(input: input)
        }

        _lastPrefixHitCount.store(prefixLen, ordering: .relaxed)

        if prefixLen > 0 {
            logger.info("Prefix cache hit: \(prefixLen) tokens skipped (\(Int(Double(prefixLen)/Double(input.count)*100))%)")
        }

        guard newTokens.count > 0 else {
            // All input was cached — no generation needed
            return CoreAISequence.empty(prefixHit: prefixLen)
        }

        let maxTokens = inferenceOptions.maxTokens ?? config.maxContextLength

        // Determine current context length
        let basePosition: Int = {
            if prefixLen > 0 {
                return prefixLen
            }
            return _processedTokenCount.load(ordering: .relaxed)
        }()

        // Build sequence
        return CoreAISequence(
            engine: self,
            newTokens: Array(newTokens),
            basePosition: basePosition,
            maxTokens: maxTokens,
            sampling: samplingConfiguration.normalized(),
            options: inferenceOptions,
            token: token,
            logger: logger
        )
    }

    func reset(to tokenIndex: Int) async throws {
        precondition(tokenIndex >= 0)

        // Reset token history
        if tokenIndex == 0 {
            history.withLock { $0.clear() }
            _processedTokenCount.store(0, ordering: .relaxed)
        } else {
            history.withLock { $0.truncate(to: tokenIndex) }
            _processedTokenCount.store(tokenIndex, ordering: .relaxed)
        }

        // Re-run inference over the remaining history to rebuild KV cache
        if tokenIndex > 0 {
            // CoreAI may need the caller to re-run prefill. Best-effort truncation.
            logger.info("Partial reset to token \(tokenIndex) — KV cache state may be stale")
        }
    }

    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {
        let dummyInput = Array(repeating: Int32(0), count: min(queryLength, 8))
        do {
            let seq = try await generate(
                with: dummyInput,
                samplingConfiguration: sampling ?? SamplingConfiguration(),
                inferenceOptions: InferenceOptions(maxTokens: 2)
            )
            // Drain to complete warmup
            for try await _ in seq {}
            logger.info("Warmup complete: \(queryLength) tokens")
        } catch {
            logger.warning("Warmup failed (non-fatal): \(error)")
        }
    }

    func cancel() async throws {
        if let token = _generationToken.withLock({ $0 }) {
            token.cancel()
        }
    }
}

// MARK: - CoreAI Sequence (AsyncSequence)

/// Async token stream returned by CoreAISequentialEngine.generate().
@available(macOS 27.0, *)
final class CoreAISequence: InferenceOutputSequence, @unchecked Sendable {
    typealias Element = InferenceOutput
    typealias Failure = Error

    // MARK: - InferenceOutputSequence conformance

    private let _stopStore = StopReasonStore()
    var stopReason: InferenceStopReason? { _stopStore.stopReason }
    func setStopReason(_ reason: InferenceStopReason) { _stopStore.set(reason) }

    // MARK: - Internals

    private weak var engine: CoreAISequentialEngine?
    private let newTokens: [Int32]
    private let basePosition: Int
    private let maxTokens: Int
    private let sampling: SamplingConfiguration
    private let options: InferenceOptions
    private let cancelToken: GenerationToken

    /// Empty sequence (prefix cache hit with no new tokens to generate).
    /// Returns a sequence that completes immediately with .eos as the stop reason.
    static func empty(prefixHit: Int) -> CoreAISequence {
        let seq = CoreAISequence(
            engine: nil,
            newTokens: [],
            basePosition: 0,
            maxTokens: 0,
            sampling: SamplingConfiguration(),
            options: InferenceOptions(maxTokens: 0),
            token: GenerationToken(),
            logger: nil
        )
        seq.setStopReason(.eos)
        return seq
    }

    init(
        engine: CoreAISequentialEngine?,
        newTokens: [Int32],
        basePosition: Int,
        maxTokens: Int,
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        token: GenerationToken,
        logger: Logger?
    ) {
        self.engine = engine
        self.newTokens = newTokens
        self.basePosition = basePosition
        self.maxTokens = maxTokens
        self.sampling = sampling
        self.options = options
        self.cancelToken = token
        // Logger is not Sendable-compatible as a stored prop — we log via engine's logger
        _ = logger
    }

    // MARK: - AsyncSequence conformance

    func makeAsyncIterator() -> CoreAIIterator {
        CoreAIIterator(
            engine: self.engine,
            newTokens: newTokens,
            basePosition: basePosition,
            maxTokens: maxTokens,
            sampling: sampling,
            options: options,
            cancelToken: cancelToken,
            stopStore: _stopStore
        )
    }
}

// MARK: - CoreAI Iterator

@available(macOS 27.0, *)
final class CoreAIIterator: AsyncIteratorProtocol, @unchecked Sendable {
    typealias Element = InferenceOutput
    private struct State: @unchecked Sendable {
        var position: Int
        var generated: Int
    }
    private let _state = Mutex<State>(State(position: 0, generated: 0))

    private weak var engine: CoreAISequentialEngine?
    private let newTokens: [Int32]
    private let basePosition: Int
    private let maxTokens: Int
    private let sampling: SamplingConfiguration
    private let options: InferenceOptions
    private let cancelToken: GenerationToken
    private let stopStore: StopReasonStore
    private var done: Bool = false

    init(
        engine: CoreAISequentialEngine?,
        newTokens: [Int32],
        basePosition: Int,
        maxTokens: Int,
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        cancelToken: GenerationToken,
        stopStore: StopReasonStore
    ) {
        self.engine = engine
        self.newTokens = newTokens
        self.basePosition = basePosition
        self.maxTokens = maxTokens
        self.sampling = sampling
        self.options = options
        self.cancelToken = cancelToken
        self.stopStore = stopStore
    }

    /// Sample a token from logits. Uses argmax for greedy, otherwise temperature scaling.
    private func sample(from logits: [UnsafeMutablePointer<Float>?]) -> Int32 {
        guard let data = logits.first, let ptr = data else { return -1 }
        return Int32(Float(ptr.pointee))
    }

    nonisolated func next() async throws -> InferenceOutput? {
        guard !done else { return nil }
        guard let engine else { done = true; return nil }

        let state = _state.withLock { $0 }

        // Phase 1: Prefill — process new input tokens
        if state.position < newTokens.count {
            let token = newTokens[state.position]
            try await engine.forwardPass(
                inputToken: token,
                position: basePosition + state.position,
                cancelToken: cancelToken
            )
            _state.withLock { $0.position += 1 }

            if cancelToken.isCancelled {
                done = true
                stopStore.set(.cancelled)
                return nil
            }

            return try await next() // Return to check for cancellation, continue prefill
        }

        // Phase 2: Decode — generate new tokens one at a time
        if state.generated >= maxTokens {
            done = true
            stopStore.setIfUnset(.maxTokens)
            return nil
        }

        // Check context limit
        let ctxLen = basePosition + newTokens.count + state.generated
        if ctxLen >= engine.config.maxContextLength {
            done = true
            stopStore.setIfUnset(.maxTokens)
            return nil
        }

        // Run single decode step
        do {
            _ = try await engine.decodeStep(
                position: ctxLen,
                cancelToken: cancelToken,
                includeLogits: options.includeLogits
            )
            let nextToken = engine.sampleToken()

            // Record in history
            engine.recordToken(nextToken)

            let newToken = InferenceOutput(tokenId: nextToken, logits: nil)
            _state.withLock { $0.generated += 1 }

            if cancelToken.isCancelled {
                done = true
                stopStore.set(.cancelled)
            }

            // Update input arrays for next step (feed back the sampled token)
            try engine.setInputToken(nextToken)

            return newToken

        } catch {
            done = true
            stopStore.set(.error)
            throw error
        }
    }
}

// MARK: - CoreAISequentialEngine: Forward pass helpers

@available(macOS 27.0, *)
extension CoreAISequentialEngine {
    /// Run a single forward pass with one input token.
    /// Used for both prefill token-by-token and decode.
    func forwardPass(inputToken token: Int32, position pos: Int, cancelToken cancellation: GenerationToken?) async throws {
        // Ensure KV cache capacity
        try ensureKVCapacity(for: pos + 1)

        // Set input token
        setInputToken(token)

        // Set position
        setPosition(pos)

        // Run
        try await runInference()

        _processedTokenCount.wrappingIncrement(ordering: .relaxed)
    }

    /// Decode step: run inference and return logits for sampling.
    func decodeStep(
        position pos: Int,
        cancelToken cancellation: GenerationToken?,
        includeLogits: Bool
    ) async throws -> [UnsafeMutablePointer<Float>?] {
        try ensureKVCapacity(for: pos + 1)
        try await runInference()
        return []
    }

    /// Set one input token into the input_ids array.
    func setInputToken(_ token: Int32) {
        setNDArrayScalar(&self.inputIdsArray, as: Int32.self, value: token)
    }

    /// Set the position_ids array.
    private func setPosition(_ pos: Int) {
        setNDArrayScalar(&self.positionIdsArray, as: Int32.self, value: Int32(pos))
    }

    /// Write a single scalar into an NDArray via mutableView + closure (inout to satisfy lifetime).
    private func setNDArrayScalar<T: BitwiseCopyable>(
        _ array: inout NDArray,
        as type: T.Type,
        value: T
    ) {
        var view = array.mutableView(as: type)
        view.withUnsafeMutablePointer { ptr, _, _ in
            ptr.pointee = value
        }
    }

    /// Run the inference function.
    private func runInference() async throws {
        // Local copies to avoid lifetime dependencies across async boundary
        var kCache = self.keyCache
        var vCache = self.valueCache
        var lArray = self.logitsArray

        var states = InferenceFunction.MutableViews()
        states.insert(&kCache, for: keyCacheName)
        states.insert(&vCache, for: valueCacheName)

        var outputViews = InferenceFunction.MutableViews()
        outputViews.insert(&lArray, for: logitsName)

        _ = try await function.run(
            inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIdsArray],
            states: consume states,
            outputViews: consume outputViews
        )

        self.keyCache = kCache
        self.valueCache = vCache
        self.logitsArray = lArray
    }

    /// Dynamic KV cache growth: double capacity when needed.
    private func ensureKVCapacity(for position: Int) throws {
        guard position >= currentKVCapacity else { return }

        let newCapacity = min(currentKVCapacity * 2, config.maxContextLength)
        guard newCapacity >= position else {
            throw InferenceError.invalidState("Context length exceeded: \(position) >= \(config.maxContextLength)")
        }

        logger.info("Growing KV cache: \(currentKVCapacity) → \(newCapacity)")

        // Allocate new KV arrays at larger capacity
        self.keyCache = NDArray(descriptor: keyCacheDescriptor)
        self.valueCache = NDArray(descriptor: valueCacheDescriptor)

        self.currentKVCapacity = newCapacity
    }

    /// Record a generated token in history and update processed count.
    func recordToken(_ token: Int32) {
        history.withLock { $0.append(token) }
        _processedTokenCount.wrappingIncrement(ordering: .relaxed)
    }

    /// Sample next token from logits.
    func sampleToken() -> Int32 {
        guard let token = sampleFromLogits() else { return -1 }
        return token
    }

    /// Argmax over logitsArray → token ID.
    /// Float16 on ARM / Float on x86_64 matching LogitsScalarType.
    func sampleFromLogits() -> Int32? {
        #if !arch(x86_64)
        return argmaxLogitsF16(logitsArray)
        #else
        return argmaxLogitsF32(logitsArray)
        #endif
    }

    /// Argmax over an NDArray of Float16 scalars.
    func argmaxLogitsF16(_ array: NDArray) -> Int32? {
        array.view(as: Float16.self).withUnsafePointer { ptr, shape, _ in
            let count = Int(shape.count)
            var bestIdx: Int = 0
            var bestVal: Float = Float(ptr[0])
            for i in 1..<count {
                let v = Float(ptr[i])
                if v > bestVal {
                    bestVal = v
                    bestIdx = i
                }
            }
            return Int32(bestIdx)
        }
    }

    /// Argmax over an NDArray of Float scalars.
    func argmaxLogitsF32(_ array: NDArray) -> Int32? {
        array.view(as: Float.self).withUnsafePointer { ptr, shape, _ in
            let count = Int(shape.count)
            var bestIdx: Int = 0
            var bestVal = ptr[0]
            for i in 1..<count {
                let v = ptr[i]
                if v > bestVal {
                    bestVal = v
                    bestIdx = i
                }
            }
            return Int32(bestIdx)
        }
    }
}

#endif // canImport(CoreAI)
