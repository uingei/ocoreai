// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// CoreAI model loader — two-phase load with specialization and caching
// Compiled only when 'coreai' trait is active
#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI

import CoreAI
import Foundation
import Logging

// MARK: - Prepared Model Wrapper

/// Wraps a CoreAI specialized model ready for inference.
/// Bridges the gap between macOS 27 SDK CoreAI types and ocoreai's engine layer.
///
/// - **After (v15)**: `AIModel(contentsOf:options:)` at load time,
///   `InferenceFunction` reused across requests via ``CoreAIModelHandle``
@available(macOS 27.0, *)
struct CoreAIPreparedModel: @unchecked Sendable {
	/// The specialized AIModel, ready for inference (nil when using fallback path).
	let aiModel: AIModel?

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
	///   - specializationOptions: Configuration used during specialization
	/// - Returns: Prepared model ready for inference
	static func prepared(
		aiModel: AIModel,
		specializationOptions: SpecializationOptions,
	) -> CoreAIPreparedModel {
		CoreAIPreparedModel(
			aiModel: aiModel,
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
			isSpecialized: false,
			specializationOptions: SpecializationOptions(preferredComputeUnitKind: .gpu),
			preparedAt: Date(),
		)
	}
}

// MARK: - Compute Target Configuration

/// Configurable compute unit targeting for model specialization.
/// Maps to ``ComputeUnitKind`` internally.
public struct ComputeTarget: Codable, Sendable {
	/// Target compute unit
	public enum Kind: String, Codable, Sendable {
		/// Automatic selection (default, recommended)
		case any
		/// CPU only
		case cpu
		/// GPU accelerated
		case gpu
		/// Neural Engine (most energy efficient on Apple Silicon)
		case neuralEngine

		/// Convert to ``ComputeUnitKind``
		@available(macOS 27.0, *)
		var computeUnitKind: ComputeUnitKind {
			switch self {
			case .any: .gpu
			case .cpu: .cpu
			case .gpu: .gpu
			case .neuralEngine: .neuralEngine
			}
		}
	}

	/// Target compute unit kind (defaults to automatic)
	var kind: Kind = .any

	/// Convert to ``ComputeUnitKind``
	@available(macOS 27.0, *)
	var computeUnitKind: ComputeUnitKind {
		kind.computeUnitKind
	}
}

// MARK: - Model Loading Configuration

/// Configuration for the two-phase Core AI model loading pipeline.
struct CoreAILoadingConfig: Codable, Sendable {
	/// Whether to enable specialized model loading (default: true)
	var enableSpecialization: Bool = true

	/// Timeout for model specialization (seconds)
	var specializationTimeout: TimeInterval = 120.0

	/// Whether to fall back to EngineFactory if specialization fails
	var fallBackToEngineFactory: Bool = true

	/// Target compute unit for specialization
	var computeTarget: ComputeTarget = .init()

	/// Default production configuration
	static let production: CoreAILoadingConfig = {
		var config = CoreAILoadingConfig()
		config.enableSpecialization = true
		config.fallBackToEngineFactory = true
		config.computeTarget = ComputeTarget(kind: .any)
		return config
	}()
}

// MARK: - Core AI Model Loader

/// Performs Core AI model loading with specialization and caching.
///
/// Reference: coreai-models uses `AIModel(contentsOf:options:)` directly.
/// `AIModelAsset` is only used for structure probing (not specialization).
/// @available(macOS 27.0, *) because this actor stores AIModel references.
@available(macOS 27.0, *)
actor CoreAIModelLoader {
	// MARK: - State

	private let config: CoreAILoadingConfig
	private let logger: Logger

	// MARK: - Initialization

	/// Create a model loader with the given configuration.
	///
	/// - Parameters:
	///   - config: Loading configuration
	///   - logger: Observability logger
	init(config: CoreAILoadingConfig, logger: Logger) {
		self.config = config
		self.logger = logger
	}

	// MARK: - Model Loading

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

		logger.info("Starting Core AI load for \(modelId) from \(modelURL.path)")
		let start = ContinuousClock.now

		do {
			// Load and specialize in one step — this is how coreai-models does it
			let options = SpecializationOptions(
				preferredComputeUnitKind: config.computeTarget.computeUnitKind,
			)

			let aiModel = try await AIModel(
				contentsOf: modelURL,
				options: options,
			)

			let prepared = CoreAIPreparedModel.prepared(
				aiModel: aiModel,
				specializationOptions: options,
			)

			let elapsed = ContinuousClock.now - start
			let ms = Double(elapsed.components.seconds) * 1000.0
				+ Double(elapsed.components.attoseconds) / 1e15
			logger.info(
				"Core AI load complete: \(modelId) \(prepared.isSpecialized ? "specialized" : "loaded") in \(String(format: "%.0fms", ms))",
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

	// MARK: - Teardown

	/// Clear any cached state.
	func teardown() {
		logger.info("CoreAIModelLoader teardown complete")
	}
}

#endif
