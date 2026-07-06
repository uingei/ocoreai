// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoadedModel.swift — Per-model lifecycle (warmup, CAS lock, session count)
///
/// Extracted from EngineManager.swift. Owns the atomic state for a single
/// loaded model: prewarm guard, inference contention, and session tracking.

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

	#if coreai
		/// v15: Specialized Core AI model — compiled once at load time, reused across requests
		let preparedModel: CoreAIPreparedModel

		/// Engine options (KV cache strategy, etc.)
		let engineOptions: EngineOptions

		/// Cached inference engine — created once per LoadedModel, reused across requests.
		/// CoreAI 34f0db3: engine preserves KV cache across turns; no per-turn reset needed.
		private var cachedEngine: (any InferenceEngine)?
	#endif

	#if mlx
		/// MLXLLM model handle — loaded once at load time, reused across inference
		var mlxModelHandle: (any MLXModelHandle)?
		var kvCacheQuantization: KVCacheQuantizationConfig = .default
		/// Speculative decoding config from backend settings. Set via setSpecDecodingConfig.
		var specDecodingConfig: SpecDecodingConfig = .default
		/// Draft model for speculative decoding — loaded by EnginePool, reused across sessions.
		private var draftModelHandle: (any MLXModelHandle)?
	#endif

	/// Logger for observability
	let logger: Logger

	// MARK: - Speculative Decoding (MLX only)

	/// Configure speculative decoding for this loaded model.
	/// Called once after model loading, before any inference session is created.
	#if mlx
		func setSpecDecodingConfig(_ config: SpecDecodingConfig) {
			specDecodingConfig = config
		}

		/// Set the loaded draft model for speculative decoding.
		/// EnginePool loads the draft model via MLXModelLoader and stores it here.
		func setDraftModel(_ handle: any MLXModelHandle) {
			draftModelHandle = handle
			logger.info("Speculative decoding enabled — draft model loaded")
		}

		/// Build ``SpeculativeDecodingConfig`` for ChatSession initialization.
		///
		/// Returns `nil` when:
		/// - Speculative decoding is disabled in config (`enabled: false`)
		/// - Mode is "mtp" — MTP does not use a separate draft model and needs
		///   its own inference path (MTPSpeculativeTokenIterator), not yet wired.
		///   Emits a user-visible warning so the operator knows SDC is off.
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
	#endif

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

#if coreai
		do {
			// Use cached engine — CoreAI 34f0db3: single engine per model preserves KV cache
			let engine = try await getCachedEngine()
			let seq = try engine.generate(
				with: Array(repeating: 0, count: 8),
				samplingConfiguration: SamplingConfiguration(),
				inferenceOptions: InferenceOptions(maxTokens: warmupTokens),
			)
			// Drain stream to complete warmup
			for try await _ in seq {}
		} catch {
			logger.warning("Warmup skipped (non-fatal): \(error)")
		}
#elseif mlx
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
			// Consume first chunk then exit — no need to drain the full stream
			for try await chunk in genStream {
				_ = chunk
				break
			}
		} catch {
			logger.warning("MLX warmup skipped (non-fatal): \(error)")
		}
#else
		// Stub warmup — no inference backend available
		logger.info("Warmup skipped (no inference trait)")
#endif

		let dur = startTime.duration(to: ContinuousClock.now)
		let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
		logger.info("Prewarmed in \(String(format: "%.1f", elapsed))ms")
	}

	// MARK: - Inference Contention Guard (CAS lock)

	/// Atomic lock — `true` while inference is running on this model
	private let inferenceGuard = ManagedAtomic<Bool>(false)

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

	#if coreai
		/// Get cached inference engine — create on first call, reuse thereafter.
		/// CoreAI 34f0db3: engines should be singletons per LoadedModel to preserve KV cache.
		/// Double-checked locking: inferenceGuard serializes access, but prewarm
		/// can call getCachedEngine outside the guard. The CAS ensures only one
		/// engine is created even under concurrent calls.
		func getCachedEngine() async throws -> any InferenceEngine {
			// Fast path: check cache without lock
			if let cached = cachedEngine {
				return cached
			}
			// Slow path: serialise creation via inferenceGuard CAS
			guard tryAcquireInference() else {
				// Another caller is creating the engine — wait briefly and retry
				try await Task.sleep(for: .milliseconds(10))
				return try await getCachedEngine()
			}
			defer { releaseInference() }
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
	func cleanup() {
		sessionCount.store(0, ordering: .relaxed)
	}

	// MARK: - Initialization

	#if coreai
		/// Create a loaded model instance with resolved config, weights, specialized model, and engine options.
		///
		/// - Parameters:
		///   - configData: Raw config binary
		///   - modelURL: Weight filesystem path
		///   - modelConfig: Parsed model configuration
		///   - preparedModel: v15 specialized Core AI model (cached for reuse)
		///   - logger: Observability logger
		init(configData: Data, modelURL: URL, modelConfig: ModelConfig, preparedModel: CoreAIPreparedModel, logger: Logger) {
			self.configData = configData
			self.modelURL = modelURL
			self.modelConfig = modelConfig
			self.preparedModel = preparedModel
			engineOptions = EngineOptions(kvCacheStrategy: .auto)
			#if mlx
				mlxModelHandle = nil
			#endif
			self.logger = logger
		}
	#else // coreai — mlx path or stub
		/// Initialize model (mlx handle or neither-build stub).
		/// In mlx mode, ``mlxModelHandle`` is set via ``setMLXHandle(_:)`` after init.
		init(configData: Data, modelURL: URL, modelConfig: ModelConfig, logger: Logger) {
			self.configData = configData
			self.modelURL = modelURL
			self.modelConfig = modelConfig
			#if mlx
				mlxModelHandle = nil
			#endif
			self.logger = logger
		}

		#if mlx
			/// Set MLX model handle after model loading completes.
			func setMLXHandle(_ handle: any MLXModelHandle) {
				mlxModelHandle = handle
			}
		#endif
	#endif // coreai
}
