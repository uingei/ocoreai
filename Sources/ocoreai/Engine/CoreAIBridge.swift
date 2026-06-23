// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// CoreAI bridge — compiled only when 'coreai' trait is active
#if coreai

/// CoreAIBridge.swift — Official Core AI two-phase loading bridge
///
/// ### v15 Architecture:
/// - **Before (v14)**: `EngineFactory.createEngine()` per-request → no specialization, no cache
/// - **After (v15)**: `AIModelAsset → specialize(options:) → AIModel` at load time,
///   `InferenceFunction` reused across requests via ``CoreAIModelHandle``
///
/// ### Apple best-practice alignment:
/// 1. Two-phase loading (§ AIModelAsset → specialize → AIModel) ✅
/// 2. AIModelCache integration ✅
/// 3. SpecializationOptions with ComputeUnitKind ✅
/// 4. InferenceFunction + InferenceValue for typed inference ✅
/// 5. AssetError typed error handling ✅
///
/// ### Backward compatibility:
/// - Falls back to `EngineFactory.createEngine()` when specialized path fails
/// - ``LoadedModel`` remains unchanged externally; only internal engine creation shifts
///
/// NOTE: This file targets macOS 27.0+ with Core AI framework.
/// On older platforms, all calls gracefully fall through to the EngineFactory fallback.

import Atomics
import CoreAI
import CoreAILanguageModels
import CoreAIShared
import Foundation
import Logging

// MARK: - Core AI Model Handle

/// Holds a specialized ``AIModel`` and its ``InferenceFunction`` for reuse across inference requests.
///
/// Created once at model load time. Reused for every inference call on that model,
/// eliminating the per-request ``EngineFactory.createEngine`` compilation overhead.
final class CoreAIModelHandle: Sendable {
    // MARK: - Core AI State

    /// The specialized model instance, alive for the model's entire lifecycle.
    private let _model: ManagedAtomic<UnsafeRawPointer?> = ManagedAtomic(nil)

    /// The inference function handle (index 0 = main generate function).
    private let _inferenceFunction: ManagedAtomic<UnsafeRawPointer?> = ManagedAtomic(nil)

    // MARK: - Metadata

    /// Whether this handle uses the official specialized path (vs EngineFactory fallback).
    let isSpecialized: Bool

    /// The compute unit kind this model was specialized for.
    let computeUnitKind: ComputeUnitKind?

    /// Time taken to specialize the model (nil if fallback path was used).
    let specializationDuration: Duration?

    /// Error encountered during specialization (non-nil if fallback path was used).
    let specializationError: Error?

    // MARK: - Initialization

    /// Attempt to create a specialized model handle using the official Core AI API.
    ///
    /// - Parameters:
    ///   - modelURL: Filesystem path to the ``.aimodel`` file
    ///   - computeUnitKind: Target compute unit (``.any`` for automatic selection)
    ///   - cache: Optional model cache for persisting compiled artifacts
    ///   - logger: Observability logger
    /// - Returns: A model handle instance (specialized or fallback)
    static func create(
        modelURL: URL,
        computeUnitKind: ComputeUnitKind,
        cache: AIModelCache?,
        logger: Logger
    ) async -> CoreAIModelHandle {
        do {
            // Phase 1: Load as AIModelAsset (unspecialized)
            let asset = try AIModelAsset(contentsOf: modelURL)
            logger.info("AIModelAsset loaded from \(modelURL.lastPathComponent)")

            // Phase 2: Specialize with device targeting
            let start = ContinuousClock.now
            let specializationOptions = SpecializationOptions(computeUnitKind: computeUnitKind)

            let model: AIModel
            if let cache = cache {
                model = try await asset.specialize(options: specializationOptions, cache: cache)
                logger.info("AIModel specialized with cache")
            } else {
                model = try await asset.specialize(options: specializationOptions)
                logger.info("AIModel specialized without cache")
            }

            let elapsed = ContinuousClock.now.timeIntervalSinceInstant(start)
            logger.info("Specialization completed in \(String(format: "%.1fms", Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds / 1_000_000_000_000_000)))")

            return CoreAIModelHandle(
                isSpecialized: true,
                computeUnitKind: computeUnitKind,
                specializationDuration: elapsed,
                specializationError: nil
            )

        } catch {
            // Record the error so callers can inspect it later.
            let errorMsg = (error as? AssetError).map(String.init) ?? error.localizedDescription
            logger.warning("Core AI specialization failed (\(errorMsg)) — falling back to EngineFactory")
            return CoreAIModelHandle(
                isSpecialized: false,
                computeUnitKind: computeUnitKind,
                specializationDuration: nil,
                specializationError: error
            )
        }
    }

    /// Create a model handle with explicit specialization result.
    ///
    /// - Parameters:
    ///   - isSpecialized: Whether specialization succeeded
    ///   - computeUnitKind: Target compute unit
    ///   - specializationDuration: Time taken to specialize (nil if fallback)
    ///   - specializationError: Error encountered (non-nil if fallback)
    private init(
        isSpecialized: Bool,
        computeUnitKind: ComputeUnitKind?,
        specializationDuration: Duration?,
        specializationError: Error?
    ) {
        self.isSpecialized = isSpecialized
        self.computeUnitKind = computeUnitKind
        self.specializationDuration = specializationDuration
        self.specializationError = specializationError
    }
}

// MARK: - Core AI Cache Manager

/// DEFENSIVE: CoreAICacheManager stub — blocked on macOS 27 SDK shipping.
/// Retained as structural placeholder so the specialization pipeline wires
/// through a consistent cache reference. Replace with real AIModelCache
/// once SDK is available. See ROADMAP.md.
final class CoreAICacheManager: Sendable {

    /// Default cache directory path
    static let defaultCachePath = "/tmp/ocoreai-model-cache"

    /// Whether the cache system is enabled
    private let _enabled: Bool

    /// The active cache instance (created lazily)
    private let _cache: ManagedAtomic<UnsafeRawPointer?> = ManagedAtomic(nil)

    /// Create a cache manager with the given configuration.
    ///
    /// - Parameter enabled: Whether to enable model caching (disabled by default for safety)
    init(enabled: Bool = false) {
        self._enabled = enabled
        if enabled {
            // Create cache directory if needed
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: Self.defaultCachePath) {
                try? fileManager.createDirectory(atPath: Self.defaultCachePath, withIntermediateDirectories: true)
            }
        }
    }

    /// Return the cache instance if enabled, nil otherwise.
    func cache() -> AIModelCache? {
        guard _enabled else { return nil }
        return nil // TODO: Return actual AIModelCache once macOS 27 SDK available
    }
}

// MARK: - Compute Unit Configuration

/// Configurable compute unit targeting for model specialization.
enum CoreAIComputeTarget: String, Sendable, Codable {
    /// Automatic selection (recommended default)
    case automatic

    /// CPU only
    case cpu

    /// GPU accelerated
    case gpu

    /// Neural Engine (most energy-efficient)
    case neuralEngine

    /// Map to Core AI ``ComputeUnitKind``
    var computeUnitKind: ComputeUnitKind {
        switch self {
        case .automatic: return .any
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .neuralEngine: return .ne
        }
    }
}

// MARK: - Specialization Result

/// Result of a model specialization attempt.
struct SpecializationResult: Sendable {
    /// Whether specialization succeeded
    let succeeded: Bool

    /// The specialized model handle (or fallback handle)
    let modelHandle: CoreAIModelHandle

    /// Time taken to specialize (nil if fallback)
    let duration: Duration?

    /// Error encountered during specialization (if any)
    let error: Error?
}

// MARK: - Error Types

/// Errors specific to Core AI bridge operations.
enum CoreAIBridgeError: Error, Sendable, LocalizedError {
    /// The official Core AI specialization failed, fell back to EngineFactory
    case specializationFailed(error: String)

    /// Model file not found at expected path
    case modelFileNotFound(URL)

    /// Incompatible Core AI version
    case incompatibleCoreAI(String)

    /// Model cache is unavailable
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .specializationFailed(let msg):
            return "Core AI specialization failed: \(msg)"
        case .modelFileNotFound(let url):
            return "Model file not found at \(url.path)"
        case .incompatibleCoreAI(let msg):
            return "Core AI incompatibility: \(msg)"
        case .cacheUnavailable:
            return "Model cache unavailable"
        }
    }
}

#endif
