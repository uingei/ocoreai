// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoadedModel.swift — Per-model lifecycle (warmup, CAS lock, session count)
///
/// Extracted from EngineManager.swift. Owns the atomic state for a single
/// loaded model: prewarm guard, inference contention, and session tracking.

import Atomics
import Foundation
import Logging

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
	import CoreAI
#endif

import MLXLLM
import MLXLMCommon

// MARK: - LoadedModel

/// Per-model engine state — immutable metadata with atomic counters.
///
/// Manages warmup lifecycle (CAS-guarded), inference contention (CAS lock),
/// and session counting (atomic). Marked `@unchecked Sendable` because mutable
/// atomics carry cross-execution-context state that the compiler cannot verify.
final class LoadedModel: @unchecked Sendable {
	// MARK: - Metadata

	/// Raw model config binary data
	let configData: Data

	/// Resolved filesystem path to model weights
	let modelURL: URL

	/// Parsed model configuration (context length, vocab, tokenizer)
	let modelConfig: ModelConfig

	#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		/// v15: Specialized Core AI model — compiled once at load time, reused across requests.
		/// Stored as Any? to break @available(27.0) transitive leakage into LoadedModel.
		var _preparedModel: Any?

		/// Cached inference engine — created once per LoadedModel, reused across requests.
		/// CoreAI 34f0db3: engine preserves KV cache across turns; no per-turn reset needed.
		private var cachedEngine: (any InferenceEngine)?
	#endif

	/// Engine options (KV cache strategy, etc.)
	let engineOptions: EngineOptions

	/// MLXLLM model handle — loaded once at load time, reused across inference
	var mlxModelHandle: (any MLXModelHandle)?
	/// Whether this model is a VLM (multi-modal: vision + language)
	/// Set during loadModel() via MLXModelLoader.isVLMModel detection.
	var isVlm: Bool = false
	var kvCacheQuantization: KVCacheQuantizationConfig = .default
	/// Speculative decoding config from backend settings. Set via setSpecDecodingConfig.
	var specDecodingConfig: SpecDecodingConfig = .default
	/// Draft model for speculative decoding — loaded by EnginePool, reused across sessions.
	private var draftModelHandle: (any MLXModelHandle)?
	/// MTP assistant drafter container — loaded by EnginePool, reused across MTP inference calls.
	private var _mtpDrafterContainer: MLXLMCommon.MTPDrafterContainer?

	/// Logger for observability
	let logger: Logger

	// MARK: - Speculative Decoding (MLX only)

	/// Configure speculative decoding for this loaded model.
	/// Called once after model loading, before any inference session is created.
	func setSpecDecodingConfig(_ config: SpecDecodingConfig) {
			specDecodingConfig = config
		}

		/// Set the loaded draft model for speculative decoding.
		/// EnginePool loads the draft model via MLXModelLoader and stores it here.
		func setDraftModel(_ handle: any MLXModelHandle) {
			draftModelHandle = handle
			logger.info("Speculative decoding enabled — draft model loaded")
		}

		/// Check if MTP drafter is loaded.
		var hasMTPDrafter: Bool {
			_mtpDrafterContainer != nil
		}
		/// EnginePool loads the drafter via MLXModelLoader.loadMTPDrafter and stores it here.
		func setMTPDrafter(_ drafter: MLXLMCommon.MTPDrafterContext) {
			_mtpDrafterContainer = MLXLMCommon.MTPDrafterContainer(context: drafter)
			logger.info("MTP drafer container set on loaded model")
		}

		/// Build ``SpeculativeDecodingConfig`` for ChatSession initialization.
		///
		/// Returns `nil` when:
		/// - Speculative decoding is disabled in config (`enabled: false`)
		/// - Mode is "mtp" — MTP uses its own inference path via `generate(...,
		///   mtpDrafer:, blockSize:)`, not ChatSession-based speculative decoding.
		/// - No draft model has been loaded for "traditional" mode
		func createSpeculativeConfig() -> MLXLMCommon.SpeculativeDecodingConfig? {
			guard specDecodingConfig.enabled else { return nil }

			// MTP mode: speculative decoding via main model's own MTP layers.
			// This requires MTPSpeculativeTokenIterator — not yet connected, so we
			// return nil and log a WARNING (not info) so the operator sees it.
			if specDecodingConfig.mode == "mtp" {
				logger.warning("Speculative decoding configured as mode='mtp' but MTP SDC not wired, running without speculation.")
				return nil
			}

			// Traditional mode: draft model proposes tokens, main model verifies
			guard let handle = mlxModelHandle else { return nil }

			// The actual draft model that proposes tokens
			let draftHandle = draftModelHandle ?? handle
			if draftModelHandle == nil {
				logger.warning("Speculative decoding enabled but no draft model — may cause issues if main model is used")
			}

			let memPolicy: MLXLMCommon.SpeculativeDecodingMemoryPolicy? =
				specDecodingConfig.memoryPolicy == "recommendedWorkingSet"
				? .recommendedWorkingSet
				: nil

			return MLXLMCommon.SpeculativeDecodingConfig(
				draftModel: draftHandle.modelContainer,
				numDraftTokens: specDecodingConfig.numDraftTokens,
				memoryPolicy: memPolicy
			)
		}

	// MARK: - Warmup (CAS-guarded, runs once)

	/// Atomic flag — `true` after prewarm completes
	private let wasPrewarmed = ManagedAtomic<Bool>(false)

	/// Run the warmup (preflight) inference once, guarded by CAS.
	///
	/// - Parameter warmupTokens: Number of tokens to generate during warmup
	func prewarmIfNeeded(_ warmupTokens: Int) async throws {
		// CAS exchange: only the first caller enters; others return immediately
		guard wasPrewarmed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }

		logger.info("Prewarming \(modelConfig.name ?? "model")...")
		let startTime = ContinuousClock.now

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		if #available(macOS 27.0, *) {
			do {
				// Use cached engine — CoreAI 34f0db3: single engine per model preserves KV cache
				let engine = try await getCachedEngine()
				let seq = try await engine.generate(
					with: Array(repeating: 0, count: 8),
					samplingConfiguration: SamplingConfiguration(),
					inferenceOptions: InferenceOptions(maxTokens: warmupTokens),
				)
				// Drain stream to complete warmup
				for try await _ in seq {}
			} catch {
				logger.warning("Warmup skipped (non-fatal): \(error)")
			}
		}
	#else
		do {
			guard let handle = mlxModelHandle else {
				logger.warning("MLX warmup skipped: no model handle")
				return
			}
			let mlxMessages: [Chat.Message] = [.init(role: .user, content: "warmup")]
			let mlxParams = makeGenerateParameters(
				from: SamplingConfiguration(),
				maxTokens: warmupTokens,
				kvCacheQuant: kvCacheQuantization,
			)
			let session = ChatSession(
				handle.modelContainer,
				speculativeDecoding: createSpeculativeConfig(),
				generateParameters: mlxParams,
			)
			let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
				session.streamDetails(to: mlxMessages)
			// Drain the full warmup stream — ensures Metal kernels are compiled
			// and the pipeline is fully warm before the first real inference.
			// The warmupTokens config limits how many tokens are generated.
			for try await _ in genStream {}
		} catch {
			logger.warning("MLX warmup skipped (non-fatal): \(error)")
		}
	#endif

		let dur = startTime.duration(to: ContinuousClock.now)
		let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
		logger.info("Prewarmed in \(String(format: "%.1f", elapsed))ms")
	}

	// MARK: - Inference Contention Guard (CAS lock)

	/// Atomic lock — `true` while inference is running on this model
	private let inferenceGuard = ManagedAtomic<Bool>(false)

	/// Dedicated CAS for engine-cache initialization. Decoupled from ``inferenceGuard``
	/// so that concurrent inference requests are NOT blocked/rejected while the
	/// engine is still being created.
	private let engineCacheGuard = ManagedAtomic<Bool>(false)

	/// Attempt to acquire the inference lock (non-blocking CAS).
	///
	/// - Returns: `true` if lock acquired, `false` if another inference is active
	func tryAcquireInference() -> Bool {
		inferenceGuard.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
	}

	/// Release the inference lock (called via ``defer``)
	func releaseInference() {
		inferenceGuard.store(false, ordering: .releasing)
	}

	// MARK: - Session Counting (atomic)

	/// Session counter — ManagedAtomic for cross-concurrency safety.
	private let sessionCount = ManagedAtomic<Int>(0)

	/// Current active session count
	var activeSessions: Int {
		sessionCount.load(ordering: .relaxed)
	}

	/// Increment session counter
	func acquireSession() {
		sessionCount.wrappingIncrement(ordering: .relaxed)
	}

	/// Decrement session counter
	func releaseSession() {
		sessionCount.wrappingDecrement(ordering: .relaxed)
	}

	// MARK: - Engine Resolution (CoreAI)

	#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		/// Get cached inference engine — create on first call, reuse thereafter.
		/// CoreAI 34f0db3: engines should be singletons per LoadedModel to preserve KV cache.
		///
		/// Uses dedicated ``engineCacheGuard`` CAS to protect cache initialization.
		/// Decoupled from ``inferenceGuard`` so that concurrent inference requests
		/// are NOT rejected while the engine is still being created.
		@available(macOS 27.0, *)
		func getCachedEngine() async throws -> any InferenceEngine {
			// Fast path: check cache without lock
			if let cached = cachedEngine {
				return cached
			}
			// Slow path: serialise creation via dedicated engine-cache CAS lock
			guard engineCacheGuard.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else {
				// Another caller is creating the engine — wait briefly and retry
				try await Task.sleep(for: .milliseconds(10))
				return try await getCachedEngine()
			}
			defer { engineCacheGuard.store(false, ordering: .releasing) }
			// Double-check after acquiring lock
			if let cached = cachedEngine {
				return cached
			}
			let engine: any InferenceEngine = try await EngineFactory.createEngine(
				config: configData,
				modelURL: modelURL,
				options: engineOptions,
			)
			cachedEngine = engine
			return engine
		}

		/// Reset engine cache — used on model switch or hard error recovery.
		/// CoreAI 34f0db3: per-turn reset removed; TokenHistory.resolve handles prefix reuse.
		func resetCacheIfNeeded() {
			cachedEngine = nil
		}
	#endif

	// MARK: - Cleanup

	/// Release all session state on shutdown.
	/// P1-fix: clear CoreAI cached artifacts and MLX model handles to free
	/// Unified Memory held by compiled models, KV cache, and GPU weights.
	func cleanup() {
		sessionCount.store(0, ordering: .relaxed)

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		// P1-fix: Clear CoreAI engine cache + prepared model to release GPU memory.
		// Without this, the cached InferenceFunction + NDArrays + AIModel asset
		// stay resident even after unloadModel() completes, causing Unified Memory
		// accumulation under model-switch workloads.
		cachedEngine = nil
		_preparedModel = nil
		logger.info("CoreAI engine + prepared model released")
#endif

		// P1-fix: Clear MLX model handles + drafter to release GPU weights
		mlxModelHandle = nil
		draftModelHandle = nil
		_mtpDrafterContainer = nil
	}

	// MARK: - Initialization

	/// Set MLX model handle after model loading completes.
	/// Defined at class level — `mlxModelHandle` is always available regardless of #if config.
	func setMLXHandle(_ handle: any MLXModelHandle) {
		mlxModelHandle = handle
	}
	
#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		/// CoreAI-specific initializer.
		init(configData: Data, modelURL: URL, modelConfig: ModelConfig, preparedModel: Any? = nil, logger: Logger) {
			self.configData = configData
			self.modelURL = modelURL
			self.modelConfig = modelConfig
			self._preparedModel = preparedModel
			engineOptions = EngineOptions(kvCacheStrategy: .auto)
			mlxModelHandle = nil
			self.logger = logger
		}
#else
		/// MLX/fallback initializer (CoreAI disabled or absent).
		init(configData: Data, modelURL: URL, modelConfig: ModelConfig, logger: Logger) {
			self.configData = configData
			self.modelURL = modelURL
			self.modelConfig = modelConfig
			engineOptions = EngineOptions(kvCacheStrategy: .auto)
			#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
				_preparedModel = nil
			#else
				// _preparedModel not declared when CoreAI absent
			#endif
			mlxModelHandle = nil
			self.logger = logger
		}
#endif
}
