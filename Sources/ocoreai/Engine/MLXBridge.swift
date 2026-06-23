// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// MLXBridge.swift — MLX inference bridge
//
// Compiled only when 'mlx' trait is active. Implements:
#if mlx
//   - MLXModelLoader (actor) — downloads & loads models via ModelScope or HF
//   - MLX inference session management — create, execute, track
//   - Sampling parameter bridge — MLXSamplingConfig → GenerateParameters
//   - Model registry — track loaded models by path or model identifier
//
// ### Architecture:
// - Models can be loaded from:
//   1. Local path: `file:///path/to/model/`
//   2. ModelScope Hub: `mscope:Qwen/Qwen2.5-7B-Instruct`
//   3. HuggingFace Hub: (reserved via mlx-hub)
//
// ### MLX Stack (mlx-swift-lm):
//   LLMModelFactory.load(fromDownloader:)
//     → ModelContainer  (thread-safe shell around ModelContext)
//       → ChatSession  (KVCache + generate + tokenization)
//         → streamResponse / respond → String / AsyncThrowingStream

#if mlx

import Foundation
import Logging
import MLXLLM
import MLXLMCommon

// MARK: - Local Tokenizer Loader

/// Minimal ``MLXLMCommon.TokenizerLoader`` that creates a GPT-style BPE tokenizer
/// from a local model directory. Used by ``LLMModelFactory`` under the `mlx` trait.
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader, Sendable {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(directory: directory)
    }
}

/// Minimal ``MLXLMCommon.Tokenizer`` that throws if accidentally invoked.
///
/// Under `mlx` trait, ``LLMModelFactory`` loads the real tokenizer from model files.
/// This satisfies the protocol but fails fast if any code path calls it directly.
private struct LocalTokenizer: MLXLMCommon.Tokenizer, Sendable {
    init(directory: URL) {}

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        fatalError("LocalTokenizer should not be called — MLX loads tokenizer from model files under mlx trait")
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        fatalError("LocalTokenizer should not be called — MLX loads tokenizer from model files under mlx trait")
    }

    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }

    var bosToken: String? { "<|begin_of_text|>" }
    var eosToken: String? { "<|end_of_text|>" }
    var unknownToken: String? { "<unk>" }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        fatalError("LocalTokenizer should not be called — MLX loads tokenizer from model files under mlx trait")
    }
}

// MARK: - MLX Model Handle

/// Protocol for an MLX-loaded model handle — hides MLX-specific types
/// so EngineManager can talk to it without directly importing MLXLLM.
protocol MLXModelHandle: Sendable {
    /// The MLX model container providing thread-safe chat inference.
    var modelContainer: MLXLMCommon.ModelContainer { get }
    /// Human-readable model identifier.
    var modelId: String { get }
    /// Number of layers (for cache tracking).
    var layerCount: Int { get }
}

/// Concrete handle backed by an MLX ``ModelContainer``.
///
/// Wraps a ``ModelContainer`` so the engine manager can treat it as
/// an opaque inference endpoint without touching MLX internals.
final class MLXModelHandleImpl: MLXModelHandle {
    let modelContainer: MLXLMCommon.ModelContainer
    let modelId: String
    let layerCount: Int

    init(modelContainer: MLXLMCommon.ModelContainer, modelId: String) {
        self.modelContainer = modelContainer
        self.modelId = modelId
        // Layer count approximated — available from modelContainer.metadata after load
        self.layerCount = 0
    }
}

// MARK: - MLX Model Loader

/// Load an MLX model from local filesystem, ModelScope Hub, or HuggingFace.
///
/// Conforms to ``ModelContainer`` lifecycle — downloads model files,
/// resolves tokenizer, initializes ``LLMModelFactory``, and returns a
/// ready-to-use inference handle.
actor MLXModelLoader {

    // MARK: - Configuration

    private let logger: Logger
    private let cacheBase: URL
    private let defaultHub: String // "modelscope" or "huggingface"
    private let modelScopeToken: String?
    private let hfToken: String?

    /// Create the MLX model loader.
    ///
    /// - Parameters:
    ///   - logger: Observability logger
    ///   - cacheBase: Base directory for model downloads
    ///   - defaultHub: Default hub provider (modelscope/huggingface)
    ///   - modelScopeToken: Optional ModelScope auth token
    ///   - hfToken: Optional HuggingFace API token (for gated models)
    init(
        logger: Logger,
        cacheBase: URL? = nil,
        defaultHub: String = "modelscope",
        modelScopeToken: String? = nil,
        hfToken: String? = nil
    ) {
        self.logger = logger
        self.cacheBase = cacheBase ?? {
            let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            return urls.first?.appendingPathComponent("ocoreai/mlx")
                ?? URL(fileURLWithPath: "/tmp/ocoreai-mlx-cache")
        }()
        self.defaultHub = defaultHub
        self.modelScopeToken = modelScopeToken
        self.hfToken = hfToken ?? ProcessInfo.processInfo.environment["HF_TOKEN"]
        // Ensure cache exists
        try? FileManager.default.createDirectory(
            at: self.cacheBase, withIntermediateDirectories: true)
    }

    // MARK: - Model Loading

    /// Load model from local filesystem or remote hub.
    ///
    /// - Parameters:
    ///   - modelURL: Filesystem path, ModelScope id, or hub repo identifier
    ///   - modelId: Model identifier for logging
    /// - Returns: Loaded ``MLXModelHandle`` ready for inference
    func load(modelURL: URL, modelId: String) async throws -> (any MLXModelHandle) {
        logger.info("Loading MLX model \(modelId) from \(modelURL.path)")
        let start = ContinuousClock.now

        // 1. Parse model source
        let source = MLXModelLoader.parseSource(modelURL.path)

        // 2. Load model using appropriate loader
        let container: MLXLMCommon.ModelContainer
        switch source {
        case .local(let localPath):
            container = try await loadLocalModel(
                at: URL(fileURLWithPath: localPath), modelId: modelId)

        case .mscope(let repoId):
            container = try await loadModelFromHub(
                provider: .modelScope, repoId: repoId, modelId: modelId)

        case .huggingFace(let repoId):
            container = try await loadModelFromHub(
                provider: .huggingFace, repoId: repoId, modelId: modelId)

        default:
            // Attempt as local path first, then hub
            container = try await loadLocalModelWithHubFallback(
                url: modelURL, modelId: modelId)
        }

        // 3. Measure elapsed time
        let elapsed = ContinuousClock.now.duration(to: start)
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15
        logger.info("MLX model \(modelId) loaded in \(String(format: "%.0fms", ms))")

        return MLXModelHandleImpl(modelContainer: container, modelId: modelId)
    }

    // MARK: - Local Model Loading

    /// Load from a local directory containing model files.
    private func loadLocalModel(at directory: URL, modelId: String) async throws
        -> MLXLMCommon.ModelContainer
    {
        logger.info("Using local path for \(modelId): \(directory.path)")
        do {
            let factory = LLMModelFactory.shared
            return try await factory.loadContainer(
                from: directory,
                using: LocalTokenizerLoader()
            )
        } catch {
            logger.error("Local load failed for \(modelId): \(error.localizedDescription)")
            throw MLXLoadError.localLoadFailed(path: directory.path, error: error.localizedDescription)
        }
    }

    /// Load from local path with Hub fallback.
    private func loadLocalModelWithHubFallback(url: URL, modelId: String) async throws
        -> MLXLMCommon.ModelContainer
    {
        // Try local first
        do {
            return try await loadLocalModel(at: url, modelId: modelId)
        } catch {
            logger.warning("Local path failed for \(modelId), trying hub: \(error.localizedDescription)")
        }

        // Attempt as hub download using repo id (last path component)
        let repoId = url.lastPathComponent
        return try await loadModelFromHub(
            provider: .modelScope, repoId: repoId, modelId: modelId)
    }

    // MARK: - Hub Loading

    enum HubProvider {
        case modelScope
        case huggingFace
    }

    /// Download and load from Hub (ModelScope or HuggingFace).
    private func loadModelFromHub(
        provider: HubProvider,
        repoId: String,
        modelId: String
    ) async throws -> MLXLMCommon.ModelContainer {
        let downloader: MLXLMCommon.Downloader
        switch provider {
        case .modelScope:
            logger.info("Downloading from ModelScope: \(repoId)")
            downloader = ModelScopeDownloader()
        case .huggingFace:
            logger.info("Downloading from HuggingFace: \(repoId)")
            downloader = HuggingFaceDownloader(token: hfToken)
        }
        let start = ContinuousClock.now
        let directory = try await downloader.download(
            id: repoId,
            revision: nil,
            matching: [],
            useLatest: false,
            progressHandler: { _ in }
        )
        let factory = LLMModelFactory.shared
        let container = try await factory.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )
        let elapsed = ContinuousClock.now.duration(to: start)
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15
        logger.info("Hub download \(repoId) completed in \(String(format: "%.0fms", ms))")
        return container
    }

    // MARK: - Model Source Parsing

    /// Parse a model source string or path to determine where the model lives.
     enum ModelSource {
        case local(String)
        case mscope(String)
        case huggingFace(String)
        case unknown(String)
    }

    nonisolated static func parseSource(_ path: String) -> ModelSource {
        // 1. Check for modelscope prefix
        if path.hasPrefix("mscope:") {
            let repoId = String(path.dropFirst(7))
            return .mscope(repoId)
        }
        // 2. Check for huggingface prefix
        if path.hasPrefix("hf:") || path.hasPrefix("huggingface:") {
            let prefix = path.hasPrefix("hf:") ? 3 : 12
            let repoId = String(path.dropFirst(prefix))
            return .huggingFace(repoId)
        }
        // 3. Is it a local file path?
        if path.hasPrefix("/") || path.hasPrefix("~/") {
            return .local(path)
        }
        // 4. Default: treat as local path (backwards compat)
        return .local(path)
    }

    // MARK: - Teardown

    /// Release loader resources.
    func teardown() {
        logger.info("MLXModelLoader teardown requested")
        // Note: ModelCache is shared and lives beyond this actor;
        // actual unloading happens when containers are de-referenced.
    }
}

// MARK: - MLX Sampling Configuration

/// Convert ``SamplingConfiguration`` to mlx-swift-lm ``GenerateParameters``.
///
/// Maps ocoreai sampling fields:
///   temperature → GenerateParameters.maximumTokenCount
///   topP → GenerateParameters.topK
///   topK → GenerateParameters.topP
///   seed → GenerateParameters.seed (mapped)
///   repetitionPenalty → GenerateParameters.logitBias
///
/// Default max tokens capped at 8192 (4K generation window).
nonisolated func makeGenerateParameters(
    from sampling: SamplingConfiguration,
    maxTokens: Int?,
    kvCacheQuant: KVCacheQuantizationConfig? = nil
) -> MLXLMCommon.GenerateParameters {
    var params = MLXLMCommon.GenerateParameters()
    // Apply per-generation limits
    params.maxTokens = maxTokens ?? 1024
    // KV cache dynamic quantization - FP16 -> INT4/INT8 after N tokens
    if let config = kvCacheQuant, config.enabled, let bits = config.bits {
        params.kvBits = bits
        params.kvGroupSize = config.groupSize
        params.quantizedKVStart = config.quantizedKVStart
    }
    // Sampling config
    if let temp = sampling.temperature, temp > 0 {
        params.temperature = Float(temp)
    }
    if let topP = sampling.topP, topP > 0 {
        params.topP = Float(topP)
    }
    if let topK = sampling.topK {
        params.topK = topK
    }
    if let repPen = sampling.repetitionPenalty, repPen > 0 {
        params.repetitionPenalty = Float(repPen)
    }
    return params
}

// MARK: - MLX Chat Message helpers

/// Convert internal ``Message`` (ocoreai type) to ``Chat.Message`` (mlx-swift-lm).
///
/// ocoreai ``Message`` has `role` + `content` (text or parts).
/// mlx-swift-lm uses ``Chat.Message`` with strong typing for role + rich content.
nonisolated func toMLXChatMessage(_ msg: Message) -> Chat.Message {
    switch msg.role {
    case "system":
        return Chat.Message.system(toMessageText(msg))
    case "assistant":
        return Chat.Message.assistant(toMessageText(msg))
    case "tool":
        return Chat.Message.tool(toMessageText(msg))
    default:
        return Chat.Message.user(toMessageText(msg))
    }
}

/// Extract text content from a message, flattening parts if needed.
nonisolated private func toMessageText(_ msg: Message) -> String {
    switch msg.content {
    case .some(.text(let s)): return s
    case .some(.parts(let parts)):
        return parts.compactMap { $0.text }.joined(separator: "\n")
    case .none: return ""
    }
}

// MARK: - Error types for MLX loading

enum MLXLoadError: LocalizedError {
    case localLoadFailed(path: String, error: String)
    case hubDownloadFailed(repoId: String, error: String)
    case invalidHubId(String)

    var errorDescription: String? {
        switch self {
        case .localLoadFailed(let path, let err):
            return "Local model load failed at \(path): \(err)"
        case .hubDownloadFailed(let repo, let err):
            return "Hub download failed for '\(repo)': \(err)"
        case .invalidHubId(let id):
            return "Invalid hub identifier: \(id)"
        }
    }
}

#endif // mlx

#endif // outer mlx
