// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// CoreAI model loader — compiled only when 'coreai' trait is active
#if canImport(CoreAI)

	/// CoreAIModelLoader.swift — Two-phase Core AI model loading bridge (v15)
	///
	/// Replaces the legacy per-request EngineFactory.createEngine pattern with
	/// an official Apple Core AI two-phase specialization pipeline:
	///
	///   1. AIModelAsset(contentsOf: url)           — unspecialized load (once)
	///   2. asset.specialize(options: cache:)       — device-targeted compile (once)
	///   3. AIModel.reuse for inference             — per-request, no recompilation
	///
	/// ### Architecture Notes:
	/// - The specialized ``AIModel`` is cached in ``LoadedModel`` and reused across
	///   all inference requests for that model, eliminating per-request compile overhead.
	/// - ``AIModelCache`` is used when configured, persisting compiled artifacts to disk.
	/// - Falls back gracefully to ``EngineFactory.createEngine`` if specialization fails.

	import CoreAI
	import CoreAILanguageModels
	import Foundation
	import Logging

	// MARK: - Core AI Model Specialization Handle

	/// Holds the specialized ``AIModel`` for reuse across inference calls.
	///
	/// Created once at model load time. Immutable and ``Sendable``.
	struct CoreAIPreparedModel {
		/// The specialized AIModel, ready for inference (nil when using fallback path).
		let aiModel: AIModel?

		/// The cached model handle for stateful session tracking.
		let modelHandle: AIModelCache.Handle?

		/// Whether this model was successfully specialized (vs. legacy fallback).
		let isSpecialized: Bool

		/// Configuration used for specialization (for diagnostics).
		let specializationOptions: SpecializationOptions

		/// Creation timestamp for observability.
		let preparedAt: Date

		/// Create a prepared model with specialization.
		///
		/// - Parameters:
		///   - aiModel: The specialized AIModel instance
		///   - modelHandle: Optional cache handle for persistence
		///   - specializationOptions: Configuration used during specialization
		/// - Returns: Prepared model ready for inference
		static func prepared(
			aiModel: AIModel,
			modelHandle: AIModelCache.Handle? = nil,
			specializationOptions: SpecializationOptions,
		) -> CoreAIPreparedModel {
			CoreAIPreparedModel(
				aiModel: aiModel,
				modelHandle: modelHandle,
				isSpecialized: true,
				specializationOptions: specializationOptions,
				preparedAt: Date(),
			)
		}

		/// Create an unprepared (fallback) placeholder.
		///
		/// - Returns: Fallback instance used when specialization is skipped or fails
		static func fallback() -> CoreAIPreparedModel {
			CoreAIPreparedModel(
				aiModel: nil,
				modelHandle: nil,
				isSpecialized: false,
				specializationOptions: SpecializationOptions(),
				preparedAt: Date(),
			)
		}
	}

	// MARK: - Compute Target Configuration

	/// Configurable compute unit targeting for model specialization.
	/// Maps to ``ComputeUnitKind`` internally.
	struct ComputeTarget: Codable {
		/// Target compute unit
		enum Kind: String, Codable {
			/// Automatic selection (default, recommended)
			case any
			/// CPU only
			case cpu
			/// GPU accelerated
			case gpu
			/// Neural Engine (most energy efficient on Apple Silicon)
			case neuralEngine

			/// Convert to ``ComputeUnitKind``
			var computeUnitKind: ComputeUnitKind {
				switch self {
				case .any: .any
				case .cpu: .cpu
				case .gpu: .gpu
				case .neuralEngine: .ne
				}
			}
		}

		/// Target compute unit kind (defaults to automatic)
		var kind: Kind = .any

		/// Convert to ``ComputeUnitKind``
		var computeUnitKind: ComputeUnitKind {
			kind.computeUnitKind
		}
	}

	// MARK: - Model Loading Configuration

	/// Configuration for the two-phase Core AI model loading pipeline.
	struct CoreAILoadingConfig: Codable {
		/// Whether to enable specialized model loading (default: true)
		var enableSpecialization: Bool = true

		/// Whether to use AIModelCache for compiled artifacts
		var enableCache: Bool = true

		/// Target compute unit for specialization
		var computeTarget: ComputeTarget = .init()

		/// Cache directory path (used when cache is enabled).
		/// Resolves to `~/Library/Caches/ocoreai/models/` on macOS,
		/// avoiding macOS tmpwatch cleanup of /tmp.
		var cacheDirectory: String?

		/// Resolve to a real filesystem path — defaults to ~/Library/Caches/ocoreai/models/
		var resolvedCacheDirectory: String {
			if let dir = cacheDirectory, !dir.isEmpty {
				return dir
			}
			let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
				?? URL(fileURLWithPath: "/tmp/ocoreai-cache")
			#if os(iOS) || os(visionOS)
				return caches.appendingPathComponent("ocoreai").appendingPathComponent("models").path
			#else
				let url = caches.appendingPathComponent("ocoreai").appendingPathComponent("models")
				try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
				return url.path
			#endif
		}

		/// Timeout for model specialization (seconds)
		var specializationTimeout: TimeInterval = 120.0

		/// Whether to fall back to EngineFactory if specialization fails
		var fallBackToEngineFactory: Bool = true

		/// Default production configuration
		static let production: CoreAILoadingConfig = {
			var config = CoreAILoadingConfig()
			config.enableSpecialization = true
			config.enableCache = true
			config.computeTarget = ComputeTarget(kind: .any)
			return config
		}()
	}

	// MARK: - Core AI Model Loader

	/// Performs two-phase Core AI model loading with specialization and caching.
	actor CoreAIModelLoader {
		// MARK: - State

		private let config: CoreAILoadingConfig
		private let logger: Logger

		/// Cache instance (created once, shared across models)
		private var cache: AIModelCache?

		// MARK: - Initialization

		/// Create a model loader with the given configuration.
		///
		/// - Parameters:
		///   - config: Loading configuration
		///   - logger: Observability logger
		init(config: CoreAILoadingConfig, logger: Logger) {
			self.config = config
			self.logger = logger

			// Initialize cache if enabled
			if config.enableCache {
				cache = AIModelCache(
					directory: URL(fileURLWithPath: config.resolvedCacheDirectory),
					name: "ocoreai-cache",
				)
				logger.info("AIModelCache initialized at \(config.resolvedCacheDirectory)")
			}
		}

		// MARK: - Two-Phase Loading

		/// Load and specialize a model using the official Core AI pipeline.
		///
		/// - Parameters:
		///   - modelURL: Filesystem path to the ``.aimodel`` file
		///   - modelId: Model identifier (for logging)
		/// - Returns: Prepared model ready for inference
		/// - Throws: ``CoreAIBridgeError`` if loading fails
		func load(modelURL: URL, modelId: String) async throws -> CoreAIPreparedModel {
			guard config.enableSpecialization else {
				logger.info("Specialization disabled for \(modelId), using fallback")
				return CoreAIPreparedModel.fallback()
			}

			logger.info("Starting two-phase load for \(modelId) from \(modelURL.path)")
			let start = ContinuousClock.now

			do {
				// Phase 1: Load as AIModelAsset (unspecialized)
				let asset = AIModelAsset(contentsOf: modelURL)
				logger.info("Phase 1 complete: AIModelAsset loaded for \(modelId)")

				// Phase 2: Specialize for target device
				let options = SpecializationOptions(
					computeUnitKind: config.computeTarget.computeUnitKind,
				)

				let prepared: CoreAIPreparedModel

				if let cache {
					do {
						// Attempt cache hit first
						let cached = try await cache.load(
							for: modelId,
							asset: asset,
						)
						prepared = CoreAIPreparedModel.prepared(
							aiModel: cached,
							modelHandle: cached.cacheHandle,
							specializationOptions: options,
						)
						logger.info("Cache HIT for \(modelId)")
					} catch {
						// Cache miss or error — proceed with fresh specialization
						logger.info("Cache miss for \(modelId), specializing fresh")
						prepared = try await specialize(
							asset: asset,
							options: options,
							modelId: modelId,
						)
					}
				} else {
					// No cache — just specialize
					prepared = try await specialize(
						asset: asset,
						options: options,
						modelId: modelId,
					)
				}

				let elapsed = ContinuousClock.now.timeIntervalSinceInstant(start)
				let ms = Double(elapsed.components.seconds) * 1000.0
					+ Double(elapsed.components.attoseconds) / 1e15
				logger.info(
					"Phase 2 complete: \(modelId) \(prepared.isSpecialized ? "specialized" : "loaded") in \(String(format: "%.0fms", ms))",
				)

				return prepared

			} catch {
				if config.fallBackToEngineFactory {
					logger.warning(
						"Core AI specialization failed for \(modelId): \(error.localizedDescription). Falling back to EngineFactory.",
					)
					return CoreAIPreparedModel.fallback()
				} else {
					throw CoreAIBridgeError.specializationFailed(error.localizedDescription)
				}
			}
		}

		// MARK: - Specialization

		/// Specialize a model asset for the target device.
		///
		/// - Parameters:
		///   - asset: The unspecialized model asset
		///   - options: Specialization configuration
		///   - modelId: Model identifier (for logging)
		/// - Returns: Prepared model ready for inference
		private func specialize(
			asset: AIModelAsset,
			options: SpecializationOptions,
			modelId: String,
		) async throws -> CoreAIPreparedModel {
			logger.info("Specializing \(modelId) with options: \(options)")

			if let cache {
				// Specialize with cache
				let specialized = try await asset.specialize(
					options: options,
					cache: cache,
				)
				return CoreAIPreparedModel.prepared(
					aiModel: specialized,
					modelHandle: specialized.cacheHandle,
					specializationOptions: options,
				)
			} else {
				// Specialize without cache
				let specialized = try await asset.specialize(options: options)
				return CoreAIPreparedModel.prepared(
					aiModel: specialized,
					modelHandle: nil,
					specializationOptions: options,
				)
			}
		}

		// MARK: - Teardown

		/// Release all cached models and clear the cache.
		func teardown() {
			cache = nil
			logger.info("CoreAIModelLoader cache cleared")
		}
	}
#endif
