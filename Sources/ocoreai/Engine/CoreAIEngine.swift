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
/// Upstream provenance (ocoreai-native glue, NOT verbatim copies;
/// upstream files it mirrors: InferenceEngines/{InferenceEngine,EngineFactory,TokenHistory,
/// GenerationToken,InputEmbeddings,KVCacheShared}.swift):
///   - TokenHistory / EngineFactory / GenerationToken / InputEmbeddings / KVCacheShared:
///     0 commits changed @ a5ece33..21dc8ad — aligned.
///   - InferenceEngine.swift: 1 upstream commit in range (protocol addition, #146 0bc7bc3) —
///     ocoreai keeps its simplified protocol variant + CoreAISequentialEngine inline;
///     CoreAISequentialEngine.swift (the engine): 0 commits, anchor 5ba2309 current.
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
            return "Input \(tokens) exceeds max context limit"
        case .engineUnavailable(_): return "Engine unavailable"
        case .genericError(let m): return m
        }
    }
}

#if canImport(CoreAI)

import Atomics
import CoreAI
import CoreGraphics
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
    /// Override for the prefill chunk size (tokens per chunk).
    /// When set, takes precedence over model metadata and engine defaults.
    let prefillChunkSize: Int?
    /// Override for the chunk threshold (minimum prompt tokens to trigger chunking).
    /// When set, takes precedence over model metadata and engine defaults.
    let prefillChunkThreshold: Int?

    init(
        variant: String? = nil,
        kvCacheStrategy: KVCacheStrategy = .auto,
        kvCacheSize: Int? = nil,
        prefillChunkSize: Int? = nil,
        prefillChunkThreshold: Int? = nil
    ) {
        self.variant = variant
        self.kvCacheStrategy = kvCacheStrategy
        self.kvCacheSize = kvCacheSize
        self.prefillChunkSize = prefillChunkSize
        self.prefillChunkThreshold = prefillChunkThreshold
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
    var prefillChunkSize: Int
    var chunkThreshold: Int
    let function: String
    let eosTokenId: Int32

    init(
        name: String, vocabSize: Int, maxContextLength: Int, function: String,
        prefillChunkSize: Int? = nil, chunkThreshold: Int? = nil, eosTokenId: Int32 = 0
    ) {
        self.name = name
        self.vocabSize = vocabSize
        self.maxContextLength = maxContextLength
        self.function = function
        // Layered prefill chunking (coreai-models #240, 0d6c0bf): explicit value
        // wins; otherwise the memory-based default (threshold = 2× chunk size),
        // replacing the fixed 512/1024 that made ocoreai fork from upstream
        // (2048/4096 on a 16-36 GB host).
        self.prefillChunkSize = prefillChunkSize ?? defaultPrefillChunkSize()
        self.chunkThreshold = chunkThreshold ?? self.prefillChunkSize * 2
        self.eosTokenId = eosTokenId
    }

    /// Apply runtime chunking overrides (coreai-models #240, 0d6c0bf).
    /// Mirrors upstream `ModelConfig.applyChunkingOverrides`: a `nil` or
    /// non-positive value falls through to the model/memory default.
    mutating func applyChunkingOverrides(
        prefillChunkSize: Int?,
        prefillChunkThreshold: Int?
    ) {
        if let size = prefillChunkSize, size > 0 {
            self.prefillChunkSize = size
        }
        if let threshold = prefillChunkThreshold, threshold > 0 {
            self.chunkThreshold = threshold
        }
    }
}

// MARK: - Chunking defaults (coreai-models #240, 0d6c0bf — layered resolution)

/// Memory-based prefill chunk size. Verbatim from coreai-models
/// `InferenceEngine.swift` (0d6c0bf): the old fixed `min(512, 1024)` default
/// made a 32K prompt burn ~9.6 GB in one unchunked pass; 2048-token chunks drop
/// that to ~620 MB.
func defaultPrefillChunkSize() -> Int {
    let bytes = ProcessInfo.processInfo.physicalMemory
    let gb = bytes / (1024 * 1024 * 1024)
    if gb <= 24 { return 2048 }
    return 4096
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
///
/// New-style typed-failure declaration (`Element` + `Failure` primary
/// associated types, mirrors upstream coreai-models verbatim) so
/// `makeAsyncIterator()` yields `any AsyncIteratorProtocol<InferenceOutput, Error>`
/// and the decoded-strategy layer (copied from upstream) can store it in an
/// existential without a compiler bad-diagnostic. All conformers already alias
/// `Element = InferenceOutput` + `Failure = Error` with `next() async throws`.
///
/// The two-parameter typed-failure form `AsyncSequence<Element, Failure>` is
/// only available on a newer OS baseline than this module's deployment floor,
/// so gate the protocol (and everything that depends on it) to the
/// `@available(macOS 27.0, iOS 27.0, *)` convention already used by every
/// conformer and consumer below.
@available(macOS 27.0, iOS 27.0, *)
protocol InferenceOutputSequence: AsyncSequence<InferenceOutput, Error> {
    /// Why generation stopped. Nil while the stream is still active.
    var stopReason: InferenceStopReason? { get }

    /// Record why generation stopped. Called by the engine iterator for
    /// natural completion and by consumers that stop early (EOS, stop sequence).
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
@available(macOS 27.0, iOS 27.0, *)
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

/// Multimodal engine: text engine (`InferenceEngine`) plus image/video
/// encode + embedded-input generate. Mirrors upstream coreai-models
/// `InferenceEngines/InferenceEngine.swift` L308-331 verbatim (coreai-models
/// HEAD 5716935).
@available(macOS 27.0, iOS 27.0, *)
protocol MultimodalInferenceEngine: InferenceEngine {
    /// Encode an image into embeddings suitable for injection into the VLM.
    /// Returns the embedded representation — caller decides whether to cache.
    func encodeImage(at url: URL) async throws -> InputEmbeddings

    /// Encode a CGImage into embeddings.
    func encodeImage(cgImage: CGImage) async throws -> InputEmbeddings

    /// Encode video frames into concatenated embeddings for injection into the VLM.
    func encodeVideo(_ video: VideoInput) async throws -> InputEmbeddings

    /// Generate tokens from a token sequence with embedded image regions.
    func generate(
        with input: InputEmbeddings,
        tokens: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> OutputSequence
}

/// Config protocol that engines must expose.
protocol InferenceConfiguration: Sendable {
    var maxContextLength: Int { get }
    var prefillChunkSize: Int { get }
    var chunkThreshold: Int { get }
}

// MARK: - Default implementations

@available(macOS 27.0, iOS 27.0, *)
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

    // Non-mutating: pure query over `tokens` (no mutation of history state),
    // matching coreai-models upstream `TokenHistory.resolve` semantics.
    func resolve(input: [Int32]) -> (commonPrefix: Int, newTokens: ArraySlice<Int32>) {
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
    /// bounds TokenHistory growth to O(context_length) not O(total_tokens).
    mutating func trim(maxCapacity: Int) {
        guard tokens.count > maxCapacity else { return }
        let keep = maxCapacity
        tokens.removeFirst(tokens.count - keep)
    }

    mutating func truncate(to position: Int) {
        // guard instead of precondition (engine internals must not release-crash)
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

    /// Specialization options derived from the detected structure.
    /// Mirrors upstream coreai-models `ModelStructure.specializationOptions`
    /// (ModelStructure.swift L71, macOS 27 SDK):
    /// - `.dynamic` → prefer `.gpu` + `expectFrequentReshapes`
    /// - `.chunkedStatic` / `.unknown` → prefer `.neuralEngine`
    ///
    /// Loading a dynamic (growing-KV-cache) LM **without** options sends it
    /// down MPSGraph's default ANE dynamic path, which crashes inside the
    /// ANE rewrite pass (`ANECRegionCallOpRewritePattern` → null-deref,
    /// SIGSEGV). Reproduced 09-15 against a qwen3-0.6b dynamic `.aimodel`;
    /// the upstream runner loading the same asset with structure-derived
    /// options succeeds (EXIT 0, coherent text). Aligned 09-15 — the vendored
    /// `prepare` had dropped the options.
    @available(macOS 27.0, iOS 27.0, *)
    var specializationOptions: SpecializationOptions {
        switch self {
        case .dynamic:
            var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
            options.expectFrequentReshapes = true
            return options
        case .chunkedStatic, .unknown:
            return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        }
    }
}

// MARK: - PreparedModel

/// Wrapper around AIModel with resolved structure.
@available(macOS 27.0, iOS 27.0, *)
struct PreparedModel: Sendable {
    let model: AIModel
    let structure: ModelStructure

    /// Resolve the model URL to a loadable Core AI asset.
    ///
    /// Mirrors upstream coreai-models `ModelBundle.resolveAssetURL`
    /// (ModelBundle.swift) + `requireModelURL`: the llm-runner feeds
    /// `prepare` the `assets.<key>` URL resolved from the bundle's
    /// metadata.json — NOT the bare bundle directory. A directory that holds
    /// metadata.json + tokenizer + assets (the export pipeline's surface) has
    /// no asset of its own; `AIModel(contentsOf:)` on it fails
    /// `corruptedMetadata: Metadata missing asset version` (observed 09-15).
    /// Resolution: direct asset → as-is; metadata-declared asset → its path;
    /// `.aimodel` → `.aimodelc` compiled variant; otherwise the first
    /// `.aimodel`/`.aimodelc` entry (stable-sorted, as upstream).
    static func resolveCoreAIModelURL(from url: URL) -> URL {
        let exts: Set<String> = ["aimodel", "aimodelc"]
        if exts.contains(url.pathExtension) { return url }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return url
        }

        var entries: [URL] = []
        do {
            entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            return url
        }

        // 1) metadata.json `assets.main` (or first declared asset) when it
        //    points at a real file in this directory — the upstream
        //    `requireModelURL(for: .main)` contract.
        if let meta = (try? Data(contentsOf: url.appendingPathComponent("metadata.json"))),
            let obj = try? JSONSerialization.jsonObject(with: meta),
            let dict = obj as? [String: Any],
            let assets = dict["assets"] as? [String: String]
        {
            let candidates = assets["main"] ?? assets.values.first
            if let name = candidates, exts.contains((name as NSString).pathExtension),
                fm.fileExists(atPath: url.appendingPathComponent(name).path)
            {
                let declared = url.appendingPathComponent(name)
                // 2) compiled variant fallback (post-`coreai-build compile`).
                if name.hasSuffix(".aimodel"),
                    fm.fileExists(atPath: url.appendingPathComponent(name + "c").path)
                {
                    return url.appendingPathComponent(name + "c")
                }
                return declared
            }
        }

        // 3) First asset in the directory.
        let sorted = entries.filter { exts.contains($0.pathExtension) }.sorted { $0.path < $1.path }
        return sorted.first ?? url
    }

    /// Core AI asset extensions — a model is a CoreAI specialization target only if
    /// it contains one of these. Mirrors upstream coreai-models
    /// `ModelStructure.assetExtensions` (`.aimodel` / `.aimodelc`).
    ///
    /// A Hub/MLX model directory (HF `safetensors`, tokenizer, …) has none —
    /// `AIModel(contentsOf:)` on it is guaranteed to fail (`Missing hash file`,
    /// observed 09-15 live log ×3). Callers use this to gate specialization
    /// attempts instead of catching the runtime error.
    static func hasCoreAIAsset(at url: URL) -> Bool {
        let extensions: Set<String> = ["aimodel", "aimodelc"]
        // A path ending in a known asset extension IS the asset (asset bundles
        // are themselves directories, so check this before scanning as a dir).
        if extensions.contains(url.pathExtension) { return true }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
        } catch {
            return false
        }
        return entries.contains { extensions.contains($0.pathExtension) }
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

    /// Prepare model asset via CoreAI — probes structure first, then loads
    /// with structure-derived specialization options.
    ///
    /// Aligned to upstream coreai-models `ModelStructure.prepare`
    /// (CoreAIShared/Runtime/ModelStructure.swift L195-215): probe the asset
    /// without specializing, pick `SpecializationOptions` from the structure,
    /// then `AIModel(contentsOf:options:)`. Loading a dynamic (growing-KV-cache)
    /// LM without options takes MPSGraph's default ANE dynamic path, which
    /// crashes in the ANE rewrite pass (`ANECRegionCallOpRewritePattern`
    /// null-deref → SIGSEGV) — reproduced 09-15 against a qwen3-0.6b dynamic
    /// `.aimodel` (upstream runner, same asset, with options: EXIT 0).
    static func prepare(at modelURL: URL, functionName: String = "default") async throws
        -> PreparedModel
    {
        let probedStructure = probeStructure(at: modelURL)
        let options = probedStructure.specializationOptions
        let model = try await AIModel(contentsOf: modelURL, options: options)
        let structure = detectStructure(from: model, functionName: functionName)
        return PreparedModel(model: model, structure: structure)
    }

    /// Probe model structure via `AIModelAsset.summary()` without triggering
    /// specialization. Mirrors upstream `probeStructure` (ModelStructure.swift
    /// L219-235): a non-empty function list with extend-prefixed static-graph
    /// markers → `.chunkedStatic`; anything else (or probe failure) defaults
    /// to `.dynamic` — the safe choice, since `.dynamic` maps to
    /// `.gpu + expectFrequentReshapes`.
    @available(macOS 27.0, iOS 27.0, *)
    private static func probeStructure(at url: URL) -> ModelStructure {
        do {
            let asset = try AIModelAsset(contentsOf: url)
            if let summary = try asset.summary(includingStatistics: false) {
                let names = summary.functions.map { $0.name }
                guard !names.isEmpty else { return .dynamic }
                let extendFunctions = names.filter { $0.hasPrefix("extend") }
                if !extendFunctions.isEmpty
                    && names.contains(where: {
                        $0.hasSuffix("load_embeddings")
                            || $0 == "load_embeddings"
                    })
                {
                    return .chunkedStatic
                }
                return .dynamic
            }
            return .dynamic
        } catch {
            return .dynamic
        }
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
        // Lane inference: a VLM bundle (assets.vision + assets.embedding present)
        // routes to `CoreAISequentialVLMEngine`; everything else falls through to
        // the LLM structure-detect path unchanged. `VLMBundleDetector.load` is
        // pure Foundation (no CoreAI import) and returns nil for non-VLM bundles,
        // so the LLM path costs nothing extra.
        //
        // 09-17 ANE-VLM wiring — the in-tree `CoreAISequentialVLMEngine` (1241 L,
        // absorbed 09-16) previously had NO factory branch: `createEngine` only
        // knew the three LLM variants, so an ANE-selected VLM request hit the
        // `EngineInference` gate (L1682) and fell back to GPU. This branch closes
        // that factory gap. The message → (placeholder tokens + InputEmbeddings)
        // assembly (`EngineInference` ANE-multimodal branch, upstream llm-runner's
        // `runVLMGeneration`) is deferred: it needs a live `.aimodelc` VLM bundle
        // + the `buildVLMPromptFromChatTemplate` equivalent, which is the next
        // piece once a VLM asset is available.
        if let vlmMetadata = VLMBundleDetector.load(at: modelURL) {
            let visionStatus = vlmMetadata.visionConfig == nil ? "absent" : "present"
            log.info(
                "ANE-VLM lane: \(vlmMetadata.name) → CoreAISequentialVLMEngine (visionConfig \(visionStatus))"
            )
            return try await createVLMEngine(
                config: config, metadata: vlmMetadata, bundleURL: modelURL, options: options)
        }

        // Parse config
        var parsedConfig = try parseModelConfig(from: config)

        // Apply runtime chunking overrides (coreai-models #240, 0d6c0bf) —
        // mirrors upstream EngineFactory applying `applyChunkingOverrides`
        // before engine construction. ocoreai's `InternalModelConfig` is a
        // value type: the override lands on this copy, all three engines see it.
        parsedConfig.applyChunkingOverrides(
            prefillChunkSize: options.prefillChunkSize,
            prefillChunkThreshold: options.prefillChunkThreshold
        )

        // Resolve model URL
        let coreAIModelURL = PreparedModel.resolveCoreAIModelURL(from: modelURL)

        // Prepare model
        let preparedModel = try await PreparedModel.prepare(
            at: coreAIModelURL, functionName: parsedConfig.function)

        // Resolve variant: user override wins (throws if incompatible), otherwise
        // auto-detect from model structure (dynamic → pipelined,
        // chunkedStatic → staticShape). Aligned with upstream coreai-models
        // EngineFactory — ocoreai implements all three variants, no fallback layer.
        let variant = try resolveVariant(
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

    /// ANE-VLM engine creation — the factory branch that `VLMBundleDetector.swift`
    /// (L121-125) documents. Resolves the bundle's three component assets
    /// (main/vision/embedding) via `VLMBundleMetadata.componentPath`, prepares each
    /// with `PreparedModel.prepare` (structure probe + specialization options —
    /// the same ANE-rewrite crash guard as the LLM path, reproduced 09-15), then
    /// constructs `CoreAISequentialVLMEngine`.
    ///
    /// `vision` block contract: mirrors upstream `LanguageBundle` (L52-53) —
    /// `kind == .vlm && visionConfig == nil → missingField("vision")`. Detection
    /// is relaxed to the asset keys only (per `VLMBundleMetadata` docs); the
    /// factory re-enforces the vision-block requirement so a bundle with a
    /// malformed vision block fails here with a precise error instead of
    /// producing garbage embeddings with guessed CLIP defaults.
    static func createVLMEngine(
        config: Data,
        metadata: VLMBundleMetadata,
        bundleURL: URL,
        options: EngineOptions = EngineOptions()
    ) async throws -> CoreAISequentialVLMEngine {
        let baseConfig = try parseModelConfig(from: config)

        // Resolve the three component assets. `componentPath` returns nil for a
        // missing variant — surface it as a precise error rather than a later
        // crash inside `AIModel(contentsOf:)`.
        func requireComponent(_ key: String) throws -> URL {
            guard let path = metadata.componentPath(key, in: bundleURL) else {
                throw InferenceRuntimeError.modelNotFound(
                    "VLM bundle \(metadata.name): no .aimodel/.aimodelc asset for role '\(key)'"
                )
            }
            return path
        }
        let mainPath = try requireComponent(VLMBundleMetadata.assetMain)
        let visionPath = try requireComponent(VLMBundleMetadata.assetVision)
        let embedPath = try requireComponent(VLMBundleMetadata.assetEmbedding)

        log.info(
            "ANE-VLM components: main=\(mainPath.lastPathComponent) vision=\(visionPath.lastPathComponent) embed=\(embedPath.lastPathComponent)"
        )

        guard let visionConfig = metadata.visionConfig else {
            throw InferenceRuntimeError.invalidArgument(
                "VLM bundle \(metadata.name): missing 'vision' block in metadata.json. "
                    + "Required for ANE-VLM routing — mirrors upstream LanguageBundle L52-53."
            )
        }
        let vlmConfig = VLMModelConfig(
            base: baseConfig,
            visionConfig: visionConfig,
            prefillChunkSizeOverride: options.prefillChunkSize,
            prefillChunkThresholdOverride: options.prefillChunkThreshold
        )

        // Prepare all three components (the same structure probe +
        // specialization-options ANE-rewrite crash guard as the LLM path).
        // Sequential load with per-component precise errors — three small
        // assets ≈ one LLM bundle, and a failed component must name itself.
        let mainLoaded = try await prepareComponent(VLMBundleMetadata.assetMain, mainPath)
        let visionLoaded = try await prepareComponent(VLMBundleMetadata.assetVision, visionPath)
        let embedLoaded = try await prepareComponent(VLMBundleMetadata.assetEmbedding, embedPath)

        return try await CoreAISequentialVLMEngine(
            config: vlmConfig,
            visionModel: visionLoaded,
            embedModel: embedLoaded,
            llmModel: mainLoaded,
            options: options
        )
    }

    private static func prepareComponent(_ role: String, _ path: URL) async throws -> PreparedModel
    {
        do {
            return try await PreparedModel.prepare(at: path)
        } catch {
            throw InferenceRuntimeError.modelLoadingFailed(
                "VLM component '\(role)' at \(path.lastPathComponent) failed to prepare: \(error)")
        }
    }

    // Engine variant registry — aligned with upstream coreai-models EngineFactory.
    // internal (not private) so EngineVariantRoutingTests can exercise the table.
    enum Variant: String, Sendable, CaseIterable {
        case sequential = "coreai-sequential"
        case pipelined = "coreai-pipelined"
        case staticShape = "static-shape"
    }

    /// Auto-detect optimal variant from model structure.
    /// Mirrors upstream EngineFactory.autoDetectVariant —
    /// dynamic → pipelined (GPU), chunkedStatic → staticShape (ANE).
    /// internal (not private) so EngineVariantRoutingTests can exercise it.
    static func autoDetectVariant(structure: ModelStructure) -> Variant {
        switch structure {
        case .dynamic: return .pipelined
        case .chunkedStatic: return .staticShape
        case .unknown: return .sequential
        }
    }

    /// Check if a variant override is compatible with the model structure.
    /// Mirrors upstream EngineFactory.checkVariantCompatibility.
    /// internal (not private) so EngineVariantRoutingTests can exercise it.
    static func checkVariantCompatibility(
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

    /// Resolve the final variant: explicit override (validated) or auto-detect.
    /// internal (not private) so EngineVariantRoutingTests can exercise it.
    static func resolveVariant(
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
            /// metadata.json chunking overrides (coreai-models #240, 0d6c0bf —
            /// second resolution layer: CLI/options > metadata.json > memory default).
            let prefillChunkSize: Int?
            let prefillChunkThreshold: Int?

            enum CodingKeys: String, CodingKey {
                case name
                case vocabSize = "vocab_size"
                case maxContextLength = "max_context_length"
                case function
                case prefillChunkSize = "prefill_chunk_size"
                case prefillChunkThreshold = "prefill_chunk_threshold"
            }
        }

        let decoder = JSONDecoder()
        do {
            let raw = try decoder.decode(RawConfig.self, from: data)
            return InternalModelConfig(
                name: raw.name,
                vocabSize: raw.vocabSize ?? Self.defaultVocabSize,
                maxContextLength: raw.maxContextLength ?? Self.defaultMaxContextLength,
                function: raw.function ?? "main",
                prefillChunkSize: raw.prefillChunkSize,
                chunkThreshold: raw.prefillChunkThreshold
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
