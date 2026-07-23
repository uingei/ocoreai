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
import MLXVLM

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
	import CoreAI
#endif

import MLXLLM
import MLXLMCommon

// MARK: - Content helper

/// Convert ContentPolymorphic to String for tokenization input.
/// - Returns: (text to tokenize, count of non-text parts silently dropped)
func contentToString(_ content: ContentPolymorphic?) -> (String, Int) {
	guard let content else { return ("", 0) }
	switch content {
	case let .text(s): return (s, 0)
	case let .parts(parts):
		let texts = parts.compactMap(\.text)
		let dropped = parts.count - texts.count
		return (texts.joined(separator: " "), dropped)
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

	/// Models currently being loaded — prevents concurrent duplicate loads.
	private var loadingModels: Set<String> = []

	/// Model last-access timestamps for LRU eviction (modelId → Instant)
	private var modelLastAccess: [String: ContinuousClock.Instant] = [:]

	/// Maximum models to keep in memory before LRU eviction kicks in
	let maxLoadedModels: Int

	/// Paged KV cache (optional — nil when feature disabled).
	/// In-memory block pool with LRU eviction, replacing old KVCacheManager
	/// SSD cold-store anti-pattern. Tracks active sessions and evicts on memory pressure.
	private let pagedKVCache: PagedKVCache?

	/// Memory tracker — reports GPU memory allocations to MemoryTracker.
	let memoryTracker: MemoryTracker?

	// MARK: - Model Loading

	#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		// Type-erased storage — CoreAIModelLoader is @available(macOS 27.0, *)
		// so it leaks transitively into EnginePool (dep target 26).
		private var _coreAIPreparedModelLoader: Any?
	#endif

	let mlxModelLoader: MLXModelLoader
	let sessionPool: MLXSessionPool?
	/// Shared draft model for speculative decoding — loaded once, reused across all models.
	private var draftModelHandle: (any MLXModelHandle)?
	/// MTP assistant drafter container — loaded once, reused across MTP inference calls.
	internal var mtpDrafterContainer: MLXLMCommon.MTPDrafterContainer?

	// MARK: - Runtime Parameter Store (hot-swappable)

	private var modelSamplingDefaults: [String: ModelSamplingConfig] = [:]

	/// Tracked inference tasks — used by ``shutdown()`` to cancel + await all running inferences
	private var trackedTasks: [Task<Void, Never>] = []

	/// Token for ModelScope Hub API (used by HubConfigFetcher + MLXModelLoader)
	private let modelScopeToken: String?

	/// Runtime hardware-aware routing — nil when HardwareRouter is not available.
	/// When set, every inference request queries the router for recommendedChannel
	/// before dispatching to a backend.
	internal let hardwareRouter: HardwareRouter?
	
	/// Tool registry for bridging to ChatSession tool dispatch.
	internal let toolRegistry: ToolRegistry?

	init(
		config: EnginePoolConfig,
		logger: Logger,
		tokenizerManager: TokenizerManager,
		pagedKVCacheConfig: PagedKVCacheConfig? = nil,
		blockPoolConfig: BlockPoolConfig? = nil,
		coreAILoadingConfig: Any? = nil,
		memoryTracker: MemoryTracker? = nil,
		modelScopeToken: String? = nil,
		hfToken: String? = nil,
		hardwareRouter: HardwareRouter? = nil,
		toolRegistry: ToolRegistry? = nil,
	) {
		self.modelScopeToken = modelScopeToken
		self.toolRegistry = toolRegistry
		self.hardwareRouter = hardwareRouter
		precondition(config.maxConcurrentSessions > 0, "maxConcurrentSessions must be positive")
		precondition(config.maxQueueSize > 0, "maxQueueSize must be positive")
		precondition(config.warmupTokens > 0, "warmupTokens must be positive")
		self.config = config
		self.logger = logger
		self.tokenizerManager = tokenizerManager
		if let pagedKVConfig = pagedKVCacheConfig, let poolConfig = blockPoolConfig {
			pagedKVCache = PagedKVCache(
				poolConfig: poolConfig,
				cacheConfig: pagedKVConfig,
				logger: logger,
			)
		} else {
			pagedKVCache = nil
		}
		self.memoryTracker = memoryTracker
		self.maxLoadedModels = 4
		#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
			if #available(macOS 27.0, *) {
				_coreAIPreparedModelLoader = CoreAIModelLoader(
					config: coreAILoadingConfig as? CoreAILoadingConfig ?? CoreAILoadingConfig(),
					logger: logger,
				)
				logger.info("CoreAIModelLoader initialized (v15 two-phase specialization)")
			} else {
				logger.info("CoreAI SDK present but macOS < 27.0 — skipping CoreAI backend")
			}
		#endif
		mlxModelLoader = MLXModelLoader(
			logger: logger,
			modelScopeToken: modelScopeToken,
			hfToken: hfToken,
		)
		logger.info("MLXModelLoader initialized (MLXLLM backend)")

		if let poolConfig = config.sessionPoolConfig, poolConfig.enabled {
			sessionPool = MLXSessionPool(config: poolConfig, logger: logger)
			logger.info("MLXSessionPool enabled (max=\(poolConfig.maxSessions), ttl=\(poolConfig.sessionTTLSeconds)s)")
		} else {
			sessionPool = nil
			logger.info("MLXSessionPool disabled (create-and-destroy per request)")
		}

		// Log speculative decoding status
			if config.specDecoding.enabled {
				if let draftId = config.specDecoding.draftModelId {
					logger.info("Speculative decoding enabled (draft: \(draftId), lazy load on first model)")
				} else {
					logger.info("Speculative decoding enabled (draft model ID not set)")
				}
			} else {
				logger.info("Speculative decoding disabled")
			}
		// Register MTP drafter types (idempotent, async)
		Task {
			await Gemma4AssistantRegistration.register()
			logger.info("MTP drafter types registered")
		}
	}

	// MARK: - Tokenization

	func tokenize(modelId: String, messages: [Message]) async throws -> [Int32] {
		guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
			throw AppError.modelNotFound(modelId)
		}
		let dicts: [[String: String]] = messages.map { msg -> [String: String] in
			let (text, dropped) = contentToString(msg.content)
			if dropped > 0 {
				self.logger.warning("Dropped \(dropped) non-text content part(s) for \(msg.role) message")
			}
			return ["role": msg.role, "content": text]
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
		// 1. Fast path: already loaded and ready
		if let model = loadedModels[modelId] {
			return try await _acquireSession(model: model, modelId: modelId)
		}

		// 2. Another caller is loading this model — wait for it to finish.
		// Uses 1s sleep (down from 200ms) to reduce mailbox wake-up frequency
		// on longer model downloads (30s+). Actor mailbox is NOT blocked during
		// Task.sleep — Swift actors yield at each suspend point.
		try await waitForLoading(modelId: modelId, timeoutSeconds: 120)
		// Model should now be loaded — try acquire again
		if let model = loadedModels[modelId] {
			return try await _acquireSession(model: model, modelId: modelId)
		}

		// 3. Not loaded — start the load
		loadingModels.insert(modelId)
		defer { loadingModels.remove(modelId) }

		// Double-check after defer setup (another caller may have finished between check & insert)
		if loadedModels[modelId] != nil {
			return try await _acquireSession(modelId: modelId)
		}

		loadedModels[modelId] = try await loadModel(modelId)

		// 4. Load succeeded — acquire session
		return try await _acquireSession(modelId: modelId)
	}

	/// Acquire a session for an already-loaded model.
	/// Reads `loadedModels[modelId]` at call time to get the latest reference.
	private func _acquireSession(modelId: String) async throws -> EngineHandle {
		guard let model = loadedModels[modelId] else {
			throw AppError.engineUnavailable
		}
		return try await _acquireSession(model: model, modelId: modelId)
	}

	private func _acquireSession(model: LoadedModel, modelId: String) async throws -> EngineHandle {
		// Touch model access time for LRU tracking
		touchModelAccess(modelId)

		// Evict idle models if pool is full
		await evictIdleModelsIfNeeded()

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
			],
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

	/// Wait for another caller to finish loading ``modelId``.
	///
	/// Uses a ``ContinuousClock`` deadline instead of busy-spinning.
	/// Each tick: check cancellation, check deadline, check if model is now loaded,
	/// then suspend for 1 s.  The actor mailbox is NOT blocked during the sleep —
	/// Swift actors yield at each suspend point.
	private func waitForLoading(modelId: String, timeoutSeconds: Int) async throws {
		let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
		while loadingModels.contains(modelId) {
			try Task.checkCancellation()
			guard ContinuousClock.now < deadline else {
				throw AppError.engineUnavailable
			}
			try await Task.sleep(until: deadline, clock: .continuous)
		}
	}

	// MARK: - Model LRU Eviction

	/// Record a timestamped access for LRU tracking.
	private func touchModelAccess(_ modelId: String) {
		modelLastAccess[modelId] = .now
	}

	/// When the model pool reaches capacity, evict the least-recently-used idle model.
	/// Only models with zero active sessions are eligible.
	private func evictIdleModelsIfNeeded() async {
		guard loadedModels.count >= maxLoadedModels else { return }

		// Find idle models (zero active sessions) sorted by last access (oldest first)
		var idleModels: [(id: String, accessed: ContinuousClock.Instant)] = []
		for (id, model) in loadedModels {
			if model.activeSessions == 0 {
				let access = modelLastAccess[id] ?? ContinuousClock.now
				idleModels.append((id, access))
			}
		}

		// Sort by access time — oldest first
		idleModels.sort { $0.accessed < $1.accessed }

		// Evict the oldest idle model
		if let target = idleModels.first {
			logger.info("LRU eviction: model \(target.id) (pool: \(loadedModels.count)/\(maxLoadedModels))")
			await unloadModel(target.id)
		}
	}

	// MARK: - Model Loading

	/// Check whether this model ID refers to a remote hub model.
	/// Exposed for ModelManager cache-check optimization.
	nonisolated func isHubModel(_ modelId: String) -> Bool {
		// Bare "org/repo" pattern: contains a slash and is not an absolute/local path
		return modelId.contains("/") && !modelId.hasPrefix("/") && !modelId.hasPrefix("~/")
	}

	private func loadModel(_ modelId: String) async throws -> LoadedModel {
		logger.info("Loading model: \(modelId)")

		// Resolve repo id — strip hf: prefix if present
		let repoId: String = if modelId.hasPrefix("hf:") {
			String(modelId.dropFirst(3))
		} else {
			modelId
		}

		// Fetch remote config — hf: prefix → HF, otherwise defaultHub (modelscope)
		let isHF = modelId.hasPrefix("hf:")
		let resolved: (vocabSize: Int, maxContextLength: Int)?
		if isHF {
			resolved = await HubConfigFetcher.fetchHuggingFaceConfig(repoId: repoId, logger: logger)
		} else {
			resolved = await HubConfigFetcher.fetchModelScopeConfig(repoId: repoId, token: modelScopeToken, logger: logger)
		}

		let modelConfig = ModelConfig(
			name: modelId,
			function: "default",
			vocabSize: resolved?.vocabSize ?? 151_936,
			maxContextLength: resolved?.maxContextLength ?? 131_072,
			chunkThreshold: 8,
			prefillChunkSize: 4096,
		)
		let modelURL = URL(fileURLWithPath: modelId)
		// Stub configData for coreai path; actual weights come from hub download
		let configData = "{}".data(using: .utf8) ?? Data()
		logger.info("Model \(modelId) is a hub model — MLXModelLoader will resolve \(resolved != nil ? "(remote config resolved)" : "(using defaults)")")

		#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
			if #available(macOS 27.0, *),
			   let loader = _coreAIPreparedModelLoader as? CoreAIModelLoader
			{
				let preparedModel = try await loader.load(
					modelURL: modelURL,
					modelId: modelId,
				)

				let loadTag = preparedModel.isSpecialized ? "specialized" : "fallback (EngineFactory)"
				logger.info(
					"Model \(modelId) prepared: \(loadTag)",
					metadata: [
						"specialized": .string(String(preparedModel.isSpecialized)),
					],
				)

				return LoadedModel(
					configData: configData,
					modelURL: modelURL,
					modelConfig: modelConfig,
					preparedModel: preparedModel,
					logger: logger,
				)
			} else {
				logger.info("CoreAI unavailable on this macOS version — falling back to MLX")
			}
		#endif
		// VLM detection: check processor_config.json before loading
		let isVlmModel = MLXModelLoader.isVLMModel(at: modelURL)
		logger.info(
			"MLX model \(modelId) \(isVlmModel ? "VLM" : "LLM") detected via isVLMModel",
		)

		let mlxHandle = try await mlxModelLoader.load(
			modelURL: modelURL,
			modelId: modelId,
		)
		logger.info("MLX model \(modelId) loaded successfully")

		#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
			var model: LoadedModel
			if #available(macOS 27.0, *) {
				let prepared = CoreAIPreparedModel.fallback()
				model = LoadedModel(
					configData: configData,
					modelURL: modelURL,
					modelConfig: modelConfig,
					preparedModel: prepared,
					logger: logger,
				)
			} else {
				model = LoadedModel(
					configData: configData,
					modelURL: modelURL,
					modelConfig: modelConfig,
					preparedModel: nil,
					logger: logger,
				)
			}
		#else
			var model = LoadedModel(
				configData: configData,
				modelURL: modelURL,
				modelConfig: modelConfig,
				logger: logger,
			)
		#endif
		model.setMLXHandle(mlxHandle)
		model.isVlm = isVlmModel
		model.kvCacheQuantization = config.kvCacheQuantization
		// Configure speculative decoding — lazy-load draft model on first model load
		model.setSpecDecodingConfig(config.specDecoding)
		if config.specDecoding.enabled {
			// MTP mode: load assistant drafter via MLXModelLoader
				// Guard: only Gemma-4 models have known-compatible assistant drafter
				// Unknown families skip loading to prevent token table mismatch
				if config.specDecoding.mode == "mtp" && !model.hasMTPDrafter {
					let isGemma = modelId.lowercased().contains("gemma")
					if !isGemma {
						logger.warning(
							"Speculative decoding in 'mtp' mode requires a Gemma-4 model — model \(modelId) is not Gemma, MTP drafter skipped. Set specDecoding.mode to 'traditional' or disable specDecoding."
						)
					} else {
						// P0-fix (mlx-swift-lm#415 78eaa5b): Gemma 4 12B (gemma4_unified)
						// uses a distinct drafter — gemma4_unified_assistant. The 12B model
						// id contains neither "31" nor "26", so defaulting to 26B drafter
						// causes token-table mismatch and MTP failure.
						let drafterModelId: String
						if modelId.lowercased().contains("12") {
							drafterModelId = "mlx-community/gemma-4-12B-it-assistant-bf16"
						} else if modelId.lowercased().contains("31") {
							drafterModelId = "mlx-community/gemma-4-31B-it-assistant-bf16"
						} else {
							drafterModelId = "mlx-community/gemma-4-26B-A4B-it-assistant-bf16"
						}
						do {
							self.mtpDrafterContainer = try await mlxModelLoader.loadMTPDrafter(modelId: drafterModelId)
							logger.info("MTP Drafter loaded for \(modelId): \(drafterModelId)")
						} catch {
							logger.warning("MTP Drafter load failed: \(error)")
						}
					}
				}
			// Traditional mode: lazy-load draft model
			if let draft = self.draftModelHandle {
				model.setDraftModel(draft)
			} else if self.draftModelHandle == nil,
			        let draftId = config.specDecoding.draftModelId {
				// Lazy-load draft model once
				// Draft models default to HF — no source param needed
				let draftURL = URL(fileURLWithPath: draftId)
				do {
					let draftHandle = try await mlxModelLoader.load(
						modelURL: draftURL,
						modelId: draftId,
					)
					self.draftModelHandle = draftHandle
					model.setDraftModel(draftHandle)
					logger.info("Speculative decoding draft model loaded: \(draftId)")
				} catch {
					logger.warning("Speculative decoding draft model load failed: \(error)")
				}
			} else {
				logger.warning("Speculative decoding enabled but no draft model — falling back to standard generation")
			}
		}
		return model
	}

	// MARK: - Inspection

	/// Snapshot model list without holding actor projection on live LoadedModel entries.
	/// Returns an independent copy — safe to call from @MainActor without risking
	/// EXC_BAD_ACCESS from concurrent LRU eviction / updateSamplingConfig.
	func listModels() async -> [[String: String]] {
		var result: [[String: String]] = []
		// Grab stable model IDs first — keys are isolated to this actor
		let ids = loadedModels.keys
		for id in ids {
			if let model = loadedModels[id] {
				let active = model.activeSessions
				var entry: [String: String] = [
					"id": id,
					"max_context_length": String(model.modelConfig.maxContextLength),
					"vocab_size": String(model.modelConfig.vocabSize),
					"tokenizer": model.modelConfig.tokenizer,
					"active_sessions": String(active),
				]
				#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
					if #available(macOS 27.0, *) {
						entry["specialized"] = String(
							(model._preparedModel as? CoreAIPreparedModel)?.isSpecialized ?? false
						)
					}
				#endif
				entry["vlm"] = String(model.isVlm)
				result.append(entry)
			}
		}
		return result
	}

	func engineSummary() async -> EngineSummary {
		let gpuCacheGB: Double = if let paged = pagedKVCache {
			await Double(paged.getMemoryBytes()) / 1_073_741_824.0
		} else {
			0.0
		}
		#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
			var specializedCount: Int
			if #available(macOS 27.0, *) {
				specializedCount = loadedModels.values.count(
					where: { ($0._preparedModel as? CoreAIPreparedModel)?.isSpecialized == true }
				)
			} else {
				specializedCount = loadedModels.values.count(where: { $0.isVlm })
			}
		#else
			let specializedCount = loadedModels.values.count(where: { $0.isVlm })
		#endif
		let modelIds = loadedModels.keys.sorted()
		return EngineSummary(
			loadedModels: loadedModels.count,
			activeSessions: loadedModels.values.reduce(0) { $0 + $1.activeSessions },
			modelIds: modelIds,
			gpuCacheGB: gpuCacheGB,
			specializedModels: specializedCount,
		)
	}

	/// Check if a model is currently loaded in the pool.
	func isModelLoaded(_ modelId: String) -> Bool {
		loadedModels[modelId] != nil
	}
	
	/// Check if a model is currently being loaded (download + warmup in progress).
	func isModelLoading(_ modelId: String) -> Bool {
		loadingModels.contains(modelId)
	}
	
	/// Return the set of model IDs currently being loaded.
	func getLoadingModelIds() -> Set<String> {
		loadingModels
	}
	
	/// Return the first loaded model ID (useful for fallback/summarization).
	func firstLoadedModelId() -> String? {
		loadedModels.keys.first
	}

	func loadedModelCount() -> Int {
		loadedModels.count
	}

	func gpuCacheUsageGB() async -> Double {
		guard let paged = pagedKVCache else { return 0.0 }
		return await Double(paged.getMemoryBytes()) / 1_073_741_824.0
	}

		func getMLXModelAndTokenizer(modelId: String) -> MLXLMCommon.ModelContainer? {
			guard let loaded = loadedModels[modelId], let handle = loaded.mlxModelHandle else {
				return nil
			}
			return handle.modelContainer
		}

	// MARK: - Runtime Parameter API (hot-swap)

	func getSamplingConfig(modelId: String) -> ModelSamplingConfig {
		modelSamplingDefaults[modelId] ?? .default
	}

	/// Per-model sampling config override (lazy, single actor mailbox hop).
	func updateSamplingConfig(modelId: String, config: ModelSamplingConfig) {
		modelSamplingDefaults[modelId] = config
		logger.info("Sampling config updated for model: \\(modelId)")
	}

	/// Batch-update sampling configs in a single actor mailbox round-trip.
	func updateSamplingConfigs(_ configs: [String: ModelSamplingConfig]) {
		for (modelId, config) in configs {
			modelSamplingDefaults[modelId] = config
		}
		logger.info("Batch sampling config updated for \\(configs.count) models")
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

	func registerTrackedTask(_ task: Task<Void, Never>) async {
		trackedTasks.append(task)
	}

	func removeTrackedTask(_ task: Task<Void, Never>) async {
		trackedTasks.removeAll { $0 == task }
	}

	// MARK: - Single Model Unload (hot-switch support)

	/// Unload a single model from the pool, releasing GPU memory.
	/// Waits for active sessions to drain before removing.
	///
	/// P0-fix: Keeps model in `loadingModels` during the entire drain + cleanup
	/// window so that concurrent `acquire()` calls will wait rather than trigger
	/// a reload of a model being actively cleaned up.
	/// Respects `Task.isCancelled` throughout the drain loop — cancelling
	/// the unload aborts cleanup and puts the model back in `loadedModels`.
	///
	/// - Parameter modelId: The model to unload
	/// - Returns: `true` if the model was unloaded, `false` if it wasn't loaded
	@discardableResult
	func unloadModel(_ modelId: String) async -> Bool {
		guard let model = loadedModels.removeValue(forKey: modelId) else {
			logger.info("Model not loaded, skip unload: \(modelId)")
			return false
		}

		// P0-fix: mark as loading so concurrent acquire() won't trigger reload
		loadingModels.insert(modelId)
		defer { loadingModels.remove(modelId) }

		logger.info("Unloading model: \(modelId)")

		// Wait for active sessions to naturally drain (up to 30s)
		// Responds to Task cancellation — if cancelled, restore model and abort.
		let deadline = ContinuousClock.now + .seconds(30)
		while model.activeSessions > 0, ContinuousClock.now < deadline {
			do {
				try Task.checkCancellation()
				try await Task.sleep(for: .milliseconds(500))
			} catch {
				// Task was cancelled — restore model to loaded state and abort cleanup
				loadedModels[modelId] = model
				logger.info("Unload cancelled, model restored: \(modelId)")
				return false
			}
		}

		if model.activeSessions > 0 {
			logger.warning("Model \(modelId) still has \(model.activeSessions) active sessions — force releasing")
		}

		model.cleanup()

		// Also clear cached tokenizer to free memory
		await tokenizerManager.removeTokenizer(for: modelId)

		// Clear sampling overrides so next load uses defaults
		modelSamplingDefaults.removeValue(forKey: modelId)

		// Clear session pool to prevent dangling GPU weight references
		await sessionPool?.clear(modelId: modelId)

		// Clear LRU access timestamp
		modelLastAccess.removeValue(forKey: modelId)

		logger.info("Model unloaded: \(modelId)")
		return true
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

		if let pool = sessionPool {
			await pool.clear()
		}

		if let paged = pagedKVCache {
			await paged.shutdown()
		}

		for model in loadedModels.values {
			model.cleanup()
		}
		loadedModels.removeAll()
	}
}
