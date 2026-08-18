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
/// Upstream provenance (2026-08-18 audit — ocoreai-native glue, NOT verbatim copies;
/// upstream files it mirrors: InferenceEngines/{InferenceEngine,EngineFactory,TokenHistory,
/// GenerationToken,InputEmbeddings,KVCacheShared}.swift):
///   - TokenHistory / EngineFactory / GenerationToken / InputEmbeddings / KVCacheShared:
///     0 commits changed @ a5ece33..21dc8ad — aligned.
///   - InferenceEngine.swift: 1 upstream commit in range (protocol addition, #146 0bc7bc3) —
///     ocoreai keeps its simplified protocol variant + CoreAISequentialEngine inline;
///     CoreAISequentialEngine.swift (the engine): 0 commits, anchor 5ba2309 (2026-08-11) current.
///     Constrained-generation protocol (#146) → tracked as pending on CoreAIPipelinedEngine.
/// EngineOptions, KVCacheStrategy, InferenceOptions, InferenceOutput redefined here
/// to avoid importing reference repo (macOS 27 requirement). Types match reference API
/// for compatibility.

// MARK: - Engine Errors (always available — used by EngineInference outside CoreAI path too)

enum InferenceError: Error, Sendable {
    case functionNotFound(String)
    case modelNotFound(String)
    case modelLoadingFailed(String)
    case invalidState(String)
    case unsupportedEngineVariant(String)
    case guidedGenerationFailed(String)
    case mtpPathFailed(String)
    case tokenizerBuildFailed(String)
    case grammarBuildFailed(String)
    case standardPathFailed(String)
    case contextExceeded(Int, Int)
    case engineUnavailable(String)
    case genericError(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name): return "Function '\(name)' not found"
        case .modelNotFound(let path): return "Model not found: \(path)"
        case .modelLoadingFailed(let msg): return "Model loading failed: \(msg)"
        case .invalidState(let d): return "Invalid state: \(d)"
        case .unsupportedEngineVariant(let v): return "Unsupported variant: \(v)"
        case .guidedGenerationFailed(let msg): return "Guided generation failed: \(msg)"
        case .mtpPathFailed(let msg): return "MTP generation failed: \(msg)"
        case .tokenizerBuildFailed(let msg): return "Grammar tokenizer failed: \(msg)"
        case .grammarBuildFailed(let msg): return "Grammar constraint failed: \(msg)"
        case .standardPathFailed(let msg): return "Inference failed: \(msg)"
        case .contextExceeded(let tokens, _):
            return "Input \\(tokens) exceeds max context limit"
        case .engineUnavailable(_): return "Engine unavailable"
        case .genericError(let m): return m
        }
    }
}

#if canImport(CoreAI)

import Atomics
import CoreAI
import Foundation
import Logging

// MARK: - Mutex shim lives in Engine/Mutex.swift (decoupled from CoreAI gate)

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
    let eosTokenId: Int32

    init(
        name: String, vocabSize: Int, maxContextLength: Int, function: String,
        prefillChunkSize: Int = 512, chunkThreshold: Int = 1024, eosTokenId: Int32 = 0
    ) {
        self.name = name
        self.vocabSize = vocabSize
        self.maxContextLength = maxContextLength
        self.function = function
        self.prefillChunkSize = prefillChunkSize
        self.chunkThreshold = chunkThreshold
        self.eosTokenId = eosTokenId
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
protocol InferenceOutputSequence: AsyncSequence {
    associatedtype Element = InferenceOutput
    associatedtype Failure = Error
    var stopReason: InferenceStopReason? { get }
    func setStopReason(_ reason: InferenceStopReason)
}

// MARK: - StopReason Store

/// Thread-safe stop reason box shared between iterator and caller.
@available(macOS 27.0, iOS 27.0, *)
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
    typealias TokenId = Int32
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
        guard limit > 0 else {
            return (0, input[...])
        }
        // Element-wise scan for the common prefix. Avoids the memcmp fast path
        // (which required force-unwrapping baseAddress of the buffer pointers);
        // the per-element loop is the safe equivalent and only runs once per
        // inference round, not per token.
        var common = 0
        var i = 0
        while i < limit && input[i] == tokens[i] {
            common += 1
            i += 1
        }
        return (common, input[common...])
    }

    mutating func append(contentsOf slice: ArraySlice<Int32>) {
        tokens.append(contentsOf: slice)
    }

    mutating func append(_ token: Int32) {
        tokens.append(token)
    }

    var count: Int { tokens.count }
    var isEmpty: Bool { tokens.isEmpty }

    /// Trim front so the array never exceeds `maxCapacity`.
    /// P0-fix: bounds TokenHistory growth to O(context_length) not O(total_tokens).
    mutating func trim(maxCapacity: Int) {
        guard tokens.count > maxCapacity else { return }
        let keep = maxCapacity
        tokens.removeFirst(tokens.count - keep)
    }

    mutating func truncate(to position: Int) {
        // P0-fix: guard instead of precondition (engine internals must not release-crash)
        guard position >= 0 else { return }
        guard position < tokens.count else { return }
        tokens.removeSubrange(position...)
    }

    mutating func clear() {
        tokens.removeAll(keepingCapacity: true)
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
@available(macOS 27.0, iOS 27.0, *)
struct PreparedModel: Sendable {
    let model: AIModel
    let structure: ModelStructure

    /// Resolve the .aimodel URL — handles .bundle, .directory, or direct .aimodel paths.
    static func resolveCoreAIModelURL(from url: URL) -> URL {
        url
    }

    /// Detect model structure from descriptor.
    private static func detectStructure(from model: AIModel, functionName: String) -> ModelStructure
    {
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
    static func prepare(at modelURL: URL, functionName: String = "default") async throws
        -> PreparedModel
    {
        let model = try await AIModel(contentsOf: modelURL)
        let structure = detectStructure(from: model, functionName: functionName)
        return PreparedModel(model: model, structure: structure)
    }
}

// MARK: - EngineFactory

/// Creates inference engines from model configurations.
/// Auto-detects model structure → selects appropriate engine.
@available(macOS 27.0, iOS 27.0, *)
struct EngineFactory: Sendable {
    private static let log = Logger(label: "ocoreai.coreai.enginefactory")
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
        let preparedModel = try await PreparedModel.prepare(
            at: coreAIModelURL, functionName: parsedConfig.function)

        // Resolve variant with fallback chain: when auto-detect picks an
        // unimplemented variant, gracefully fall back to sequential (the only
        // engine we have). User overrides still throw — explicit intent wins.
        let variant = try resolveVariantWithFallback(
            override: options.variant, detectedStructure: preparedModel.structure)

        log.info(
            "CoreAI engine variant: \(variant.rawValue), structure: \(preparedModel.structure.description)"
        )

        // Create engine
        switch variant {
        case .sequential:
            return try await CoreAISequentialEngine(
                config: parsedConfig,
                preparedModel: preparedModel,
                options: options
            )
        case .pipelined:
            // CoreAIPipelinedEngine implements the same InferenceEngine contract
            // as the other two variants (generate/reset(to:)/warmup/cancel).
            // Grammar/constrained decoding is not wired to the pipelined decode
            // loop yet (tracks upstream coreai-models #146/#170 — GPU bitmask).
            // A grammar request hitting this engine warns and runs unconstrained
            // (EngineInference CoreAI branch). Auto-detect keeps the
            // grammar-capable sequential path for .dynamic structures.
            return try await CoreAIPipelinedEngine(
                config: parsedConfig,
                preparedModel: preparedModel,
                options: options
            )
        case .staticShape:
            return try await CoreAIStaticShapeEngine(
                config: parsedConfig,
                preparedModel: preparedModel,
                options: options
            )
        }
    }

    // Engine variant registry — aligned with upstream coreai-models EngineFactory
    private enum Variant: String, Sendable, CaseIterable {
        case sequential = "coreai-sequential"
        case pipelined = "coreai-pipelined"
        case staticShape = "static-shape"
    }

    /// Auto-detect variant, then fall back to sequential when the detected
    /// variant is not yet implemented in ocoreai. User overrides still throw.
    ///
    /// Upstream (coreai-models EngineFactory) has CoreAIPipelinedEngine and
    /// StaticShapeEngine so it can honor the auto-detected variant directly.
    /// ocoreai only has CoreAISequentialEngine, so dynamic → pipelined would
    /// always fail. The fallback chain closes this gap:
    ///   auto → detected → available? → yes: use it
    ///                    → no:  warn + fall back to sequential
    private static func resolveVariantWithFallback(
        override variantOverride: String?,
        detectedStructure structure: ModelStructure
    ) throws -> Variant {
        // User-specified override: honor explicit intent (may throw if unavailable)
        if let vo = variantOverride, vo != "auto", vo != "default" {
            return try resolveVariant(override: vo, detectedStructure: structure)
        }

        // Auto-detect, then fall back to sequential for unimplemented variants
        // — but only when sequential is actually compatible with the model structure.
        let detected = autoDetectVariant(structure: structure)
        if detected == .sequential {
            return .sequential
        }
        // Guard: sequential engine cannot handle chunked-static models
        // (upstream checkVariantCompatibility returns false).
        // Rather than silently run an incompatible engine, reject with a clear error.
        guard checkVariantCompatibility(variant: .sequential, structure: structure).compatible
        else {
            throw InferenceError.unsupportedEngineVariant(
                "Model structure '\(structure.description)' requires '\(detected.rawValue)' engine (not yet available). Auto-detection selected '\(detected.rawValue)' but it is unimplemented, and sequential is incompatible with this structure."
            )
        }
        Self.log.info(
            "CoreAI auto-detected variant '\(detected.rawValue)' not yet implemented — falling back to sequential for structure \(structure.description)"
        )
        return .sequential
    }

    /// Auto-detect optimal variant from model structure.
    /// Mirrors upstream EngineFactory.autoDetectVariant —
    /// dynamic → pipelined (GPU), chunkedStatic → staticShape (ANE).
    private static func autoDetectVariant(structure: ModelStructure) -> Variant {
        switch structure {
        case .dynamic: return .pipelined
        case .chunkedStatic: return .staticShape
        case .unknown: return .sequential
        }
    }

    /// Check if a variant override is compatible with the model structure.
    /// Mirrors upstream EngineFactory.checkVariantCompatibility.
    private static func checkVariantCompatibility(
        variant: Variant,
        structure: ModelStructure
    ) -> (compatible: Bool, warning: String?) {
        switch (variant, structure) {
        case (.staticShape, .dynamic):
            return (
                false, "Static-shape variant requires chunked static model (extend_* functions)"
            )
        case (.pipelined, .chunkedStatic):
            return (false, "Core AI pipelined variant requires dynamic model")
        case (.sequential, .chunkedStatic):
            return (false, "Sequential variant requires dynamic model")
        case (_, .dynamic), (_, .chunkedStatic):
            return (true, nil)
        default:
            return (false, "LLM engine variants are incompatible with this model structure")
        }
    }

    private static func resolveVariant(
        override variantOverride: String?,
        detectedStructure structure: ModelStructure
    ) throws -> Variant {
        if let vo = variantOverride, vo != "auto", vo != "default" {
            if let variant = Variant(rawValue: vo) {
                let (compatible, warning) = checkVariantCompatibility(
                    variant: variant, structure: structure)
                if let warning {
                    log.warning("CoreAI variant override: \(warning)")
                }
                if !compatible {
                    throw InferenceError.unsupportedEngineVariant(
                        "Variant '\(vo)' incompatible with model structure '\(structure.description)'"
                    )
                }
                return variant
            }
            throw InferenceError.unsupportedEngineVariant(
                "Unknown variant '\(vo)'. Valid: auto, coreai-sequential, coreai-pipelined, static-shape"
            )
        }
        return autoDetectVariant(structure: structure)
    }

    private static func parseModelConfig(from data: Data) throws -> InternalModelConfig {
        // Decode using snake_case keys to match upstream ModelConfig (parsing:) exactly.
        // Upstream keys: vocab_size, max_context_length, serialized_model, tokenizer, function
        struct RawConfig: Decodable {
            let name: String
            let vocabSize: Int?
            let maxContextLength: Int?
            let function: String?

            enum CodingKeys: String, CodingKey {
                case name
                case vocabSize = "vocab_size"
                case maxContextLength = "max_context_length"
                case function
            }
        }

        let decoder = JSONDecoder()
        do {
            let raw = try decoder.decode(RawConfig.self, from: data)
            return InternalModelConfig(
                name: raw.name,
                vocabSize: raw.vocabSize ?? Self.defaultVocabSize,
                maxContextLength: raw.maxContextLength ?? Self.defaultMaxContextLength,
                function: raw.function ?? "main"
            )
        } catch {
            log.warning(
                "CoreAI config parsing failed: \(error.localizedDescription) — using defaults")
            return InternalModelConfig(
                name: "unknown",
                vocabSize: Self.defaultVocabSize,
                maxContextLength: Self.defaultMaxContextLength,
                function: "main"
            )
        }
    }

    /// Safe defaults for CoreAI model config when JSON is missing or unparseable.
    /// These are intentionally broad to cover most models — the actual vocab size
    /// is probed from the logits descriptor at engine creation time (L720), so the
    /// default only matters before the first forward pass.
    private static let defaultVocabSize = 32_768
    private static let defaultMaxContextLength = 131_072
}

// MARK: - GenerationToken

/// Cancellation token for in-flight generation.
@available(macOS 27.0, iOS 27.0, *)
final class GenerationToken: @unchecked Sendable {
    private let mutex = Mutex<Bool>(false)
    var isCancelled: Bool {
        mutex.withLock { $0 }
    }
    func cancel() {
        mutex.withLock { $0 = true }
    }
}

// MARK: - CoreAI Sequential Engine (Replaced by CoreAISequentialEngine 对齐 upstream)

#endif  // canImport(CoreAI)
