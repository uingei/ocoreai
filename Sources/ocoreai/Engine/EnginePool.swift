// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EnginePool.swift — Orchestration actor for the engine pool
///
/// Extracted from EngineManager.swift (was 1424 lines).
/// This file contains only the actor's state, initialization,
/// model loading, session acquisition/release, tokenization,
/// inspection, and shutdown.
///
/// Inference execution was moved to EngineInference.swift
/// (actor extension) to keep responsibilities separate.

import Atomics
import Foundation
import Logging

#if coreai
import CoreAI
import CoreAILanguageModels
import CoreAIShared
#endif

#if mlx
import MLXLLM
import MLXLMCommon
#endif

// MARK: - Content helper

/// Convert ContentPolymorphic to String for tokenization input.
func contentToString(_ content: ContentPolymorphic?) -> String {
    guard let content = content else { return "" }
    switch content {
    case .text(let s): return s
    case .parts(let parts): return parts.compactMap { $0.text }.joined(separator: " ")
    }
}

// MARK: - Engine Pool Actor

/// Shared engine pool with ``actor`` isolation for mutable ``loadedModels``.
///
/// Responsible for:
/// - Lazy model loading on first request
/// - Tokenization/detokenization via ``TokenizerManager``
/// - Session acquisition/release bookkeeping
/// - TaskGroup inference dispatch (never blocks the actor)
/// - Runtime sampling parameter hot-swap
/// - Graceful shutdown
actor EnginePool {

    // MARK: - State

    /// Immutable pool configuration
    let config: EnginePoolConfig

    /// Logger for observability
    let logger: Logger

    /// Tokenizer registry (shared, thread-safe actor)
    let tokenizerManager: TokenizerManager

    /// Loaded model instances keyed by model ID
    var loadedModels: [String: LoadedModel] = [:]

    /// Paged KV cache (optional — nil when feature disabled).
    /// In-memory block pool with LRU eviction, replacing old KVCacheManager
    /// SSD cold-store anti-pattern. Tracks active sessions and evicts on memory pressure.
    private let pagedKVCache: PagedKVCache?

    /// Memory tracker — reports GPU memory allocations to MemoryTracker.
    private let memoryTracker: MemoryTracker?

    // MARK: - Model Loading
    
#if coreai
    private let coreAIPreparedModelLoader: CoreAIModelLoader
#endif

#if mlx
    let mlxModelLoader: MLXModelLoader
    let sessionPool: MLXSessionPool?
#endif

    // MARK: - Runtime Parameter Store (hot-swappable)

    private var modelSamplingDefaults: [String: ModelSamplingConfig] = [:]

    /// Tracked inference tasks — used by ``shutdown()`` to cancel + await all running inferences
    private var trackedTasks: [Task<Void, Never>] = []

    // MARK: - Initialization

    init(
        config: EnginePoolConfig = .default,
        logger: Logger,
        tokenizerManager: TokenizerManager,
        pagedKVCacheConfig: PagedKVCacheConfig? = nil,
        blockPoolConfig: BlockPoolConfig? = nil,
        coreAILoadingConfig: CoreAILoadingConfig = .init(),
        memoryTracker: MemoryTracker? = nil,
        hfToken: String? = nil,
        modelScopeToken: String? = nil
    ) {
        precondition(config.maxConcurrentSessions > 0, "maxConcurrentSessions must be positive")
        precondition(config.maxQueueSize > 0, "maxQueueSize must be positive")
        precondition(config.warmupTokens > 0, "warmupTokens must be positive")
        self.config = config
        self.logger = logger
        self.tokenizerManager = tokenizerManager
        if let pagedKVConfig = pagedKVCacheConfig, let poolConfig = blockPoolConfig {
            self.pagedKVCache = PagedKVCache(
                poolConfig: poolConfig,
                cacheConfig: pagedKVConfig,
                logger: logger
            )
        } else {
            self.pagedKVCache = nil
        }
        self.memoryTracker = memoryTracker
#if coreai
        self.coreAIPreparedModelLoader = CoreAIModelLoader(
            config: coreAILoadingConfig,
            logger: logger
        )
        logger.info("CoreAIModelLoader initialized (v15 two-phase specialization)")
#endif
#if mlx
        self.mlxModelLoader = MLXModelLoader(
            logger: logger,
            modelScopeToken: modelScopeToken,
            hfToken: hfToken
        )
        logger.info("MLXModelLoader initialized (MLXLLM backend)")

        if let poolConfig = config.sessionPoolConfig, poolConfig.enabled {
            self.sessionPool = MLXSessionPool(config: poolConfig, logger: logger)
            logger.info("MLXSessionPool enabled (max=\(poolConfig.maxSessions), ttl=\(poolConfig.sessionTTLSeconds)s)")
        } else {
            self.sessionPool = nil
            logger.info("MLXSessionPool disabled (create-and-destroy per request)")
        }
#else
        logger.info("EnginePool initialized (no inference trait — stub backend)")
#endif
    }

    // MARK: - Tokenization

    func tokenize(modelId: String, messages: [Message]) async throws -> [Int32] {
        guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
            throw AppError.modelNotFound(modelId)
        }
        let dicts: [[String: String]] = messages.map {
            ["role": $0.role, "content": contentToString($0.content)]
        }
        return try await provider.tokenize(messages: dicts)
    }

    func detokenize(modelId: String, tokens: [Int32]) async throws -> String {
        guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
            throw AppError.modelNotFound(modelId)
        }
        return try await provider.detokenize(tokenIds: tokens)
    }

    // MARK: - Acquire / Release

    func acquire(model modelId: String) async throws -> EngineHandle {
        if loadedModels[modelId] == nil {
            loadedModels[modelId] = try await loadModel(modelId)
        }
        guard let model = loadedModels[modelId] else {
            throw AppError.engineUnavailable
        }

        try await model.prewarmIfNeeded(config.warmupTokens)
        model.acquireSession()

        let sessionId = UUID().uuidString
        if let paged = pagedKVCache {
            try await paged.attach(sessionId: sessionId)
        }

        logger.info(
            "Session acquired",
            metadata: [
                "model": .string(modelId),
                "active": .string(String(model.activeSessions)),
                "session": .string(sessionId),
            ]
        )

        return EngineHandle(modelId: modelId, sessionId: sessionId, pool: self)
    }

    func releaseSession(modelId: String, sessionId: String) async {
        loadedModels[modelId]?.releaseSession()
        await pagedKVCache?.evictSession(sessionId: sessionId)
    }

    func markSessionActive(sessionId: String) async {
        await pagedKVCache?.markActive(sessionId: sessionId)
    }

    // MARK: - Model Loading

    private func loadModel(_ modelId: String) async throws -> LoadedModel {
        logger.info("Loading model: \(modelId)")

        var configURL = URL(fileURLWithPath: config.modelConfigPath)
        let candidate = configURL
            .appendingPathComponent(modelId)
            .appendingPathComponent("config.json")
        if candidate.isFileURL, FileManager.default.fileExists(atPath: candidate.path) {
            configURL = candidate
        }

        let configData = try Data(contentsOf: configURL)
        let modelConfig = try ModelConfig(parsing: configData)
        try modelConfig.validate()

        let baseDir = URL(fileURLWithPath: config.modelDirectory)
            .appendingPathComponent(modelId)
        let modelName = modelConfig.serializedModel.first ?? "\(modelId).aimodel"
        let modelURL = baseDir.appendingPathComponent(modelName)

        logger.info("Model \(modelId) metadata loaded")

#if coreai
        let preparedModel = try await coreAIPreparedModelLoader.load(
            modelURL: modelURL,
            modelId: modelId
        )

        let loadTag = preparedModel.isSpecialized ? "specialized" : "fallback (EngineFactory)"
        logger.info(
            "Model \(modelId) prepared: \(loadTag)",
            metadata: [
                "specialized": .string(String(preparedModel.isSpecialized)),
            ]
        )

        return LoadedModel(
            configData: configData,
            modelURL: modelURL,
            modelConfig: modelConfig,
            preparedModel: preparedModel,
            logger: logger
        )
#endif
#if mlx
        let mlxHandle = try await mlxModelLoader.load(
            modelURL: modelURL,
            modelId: modelId
        )
        logger.info("MLX model \(modelId) loaded successfully")

        let model = LoadedModel(
            configData: configData,
            modelURL: modelURL,
            modelConfig: modelConfig,
            logger: logger
        )
        model.setMLXHandle(mlxHandle)
        model.kvCacheQuantization = config.kvCacheQuantization
        return model
#else
        return LoadedModel(
            configData: configData,
            modelURL: modelURL,
            modelConfig: modelConfig,
            logger: logger
        )
#endif
    }

    // MARK: - Inspection

    func listModels() -> [[String: String]] {
        loadedModels.compactMap { id, model in
            [
                "id": id,
                "max_context_length": String(model.modelConfig.maxContextLength),
                "vocab_size": String(model.modelConfig.vocabSize),
                "tokenizer": model.modelConfig.tokenizer,
            ]
        }
    }

    func engineSummary() async -> EngineSummary {
        let gpuCacheGB: Double
        if let paged = pagedKVCache {
            gpuCacheGB = Double(await paged.getMemoryBytes()) / 1_073_741_824.0
        } else {
            gpuCacheGB = 0.0
        }
#if coreai
        let specializedCount = loadedModels.values.filter { $0.preparedModel.isSpecialized }.count
#else
        let specializedCount = 0
#endif
        let modelIds = loadedModels.keys.sorted()
        return EngineSummary(
            loadedModels: loadedModels.count,
            activeSessions: loadedModels.values.reduce(0, { $0 + $1.activeSessions }),
            modelIds: modelIds,
            gpuCacheGB: gpuCacheGB,
            specializedModels: specializedCount
        )
    }

    func loadedModelCount() -> Int { loadedModels.count }

    func gpuCacheUsageGB() async -> Double {
        guard let paged = pagedKVCache else { return 0.0 }
        return Double(await paged.getMemoryBytes()) / 1_073_741_824.0
    }

#if mlx
    func getMLXModelAndTokenizer(modelId: String) -> MLXLMCommon.ModelContainer? {
        guard let loaded = loadedModels[modelId], let handle = loaded.mlxModelHandle else {
            return nil
        }
        return handle.modelContainer
    }
#else
    func getMLXModelAndTokenizer(modelId: String) -> Bool? {
        return false
    }
#endif

    // MARK: - Runtime Parameter API (hot-swap)

    func getSamplingConfig(modelId: String) -> ModelSamplingConfig {
        modelSamplingDefaults[modelId] ?? .default
    }

    func updateSamplingConfig(modelId: String, config: ModelSamplingConfig) {
        modelSamplingDefaults[modelId] = config
        logger.info("Sampling config updated for model: \(modelId)")
    }

    func resetSamplingConfig(modelId: String) {
        modelSamplingDefaults.removeValue(forKey: modelId)
        logger.info("Sampling config reset to defaults for model: \(modelId)")
    }

    func resetAllSamplingConfig() {
        modelSamplingDefaults.removeAll()
        logger.info("All sampling configs reset to defaults")
    }

    // MARK: - Tracked Task Management

    func registerTrackedTask(_ task: Task<Void, Never>) {
        trackedTasks.append(task)
    }

    func removeTrackedTask(_ task: Task<Void, Never>) {
        trackedTasks.removeAll { $0 == task }
    }

    // MARK: - Graceful Shutdown

    func shutdown() async {
        let tasksToWait = trackedTasks
        trackedTasks.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for task in tasksToWait {
                group.addTask {
                    task.cancel()
                    _ = await Task { await task.value }.value
                }
            }
        }
        logger.info("All tracked inference tasks cancelled")

        #if mlx
        if let pool = sessionPool {
            await pool.clear()
        }
        #endif

        if let paged = pagedKVCache {
            await paged.shutdown()
        }

        for model in loadedModels.values {
            model.cleanup()
        }
        loadedModels.removeAll()
    }
}
