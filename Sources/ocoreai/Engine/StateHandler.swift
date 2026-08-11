// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — aligned with coreai-models StateHandler.swift
// + StateHandler+NDArray.swift + StateHandler+Run.swift
//
// State management abstraction: each ``SyncStateHandler`` owns allocation,
// growth, and reset of model state tensors (KV cache + persistent states).
//
// Aligned with upstream handlers from coreai-models HEAD a5ece33.

#if canImport(CoreAI)
import CoreAI
import Foundation

// MARK: - SyncStateHandler Protocol

/// Protocol for synchronous state handlers (NDArray-based).
///
/// Each handler owns its tensors, manages capacity (growth strategy),
/// and exposes ``bind(into:)`` for CoreAI inference. This abstracts
/// growing KV caches vs fixed-shape persistent states (recurrent/conv).
///
/// Aligned with upstream ``SyncStateHandler`` from coreai-models.
@available(macOS 27.0, iOS 27.0, *)
protocol SyncStateHandler: Sendable {
    /// Current KV cache capacity in tokens.
    var currentCapacity: Int { get }

    /// State tensor names from the model descriptor.
    var stateNames: [String] { get }

    /// Ensure at least `capacity` tokens fit. Returns true if growth occurred.
    func ensureCapacity(forContextLength capacity: Int) throws -> Bool

    /// Reset state on full reset (to 0).
    func reset()

    /// Bind state tensors into views for CoreAI inference.
    func bind(into views: inout InferenceFunction.MutableViews)
}

// MARK: - FixedNDArrayState

/// Fixed-shape persistent state (recurrent/conv layers). Grows never; resets recreate.
///
/// Used by hybrid models (2–4 states: KV cache pair + optional persistent states).
///
/// Aligned with upstream ``FixedNDArrayState`` from coreai-models.
@available(macOS 27.0, iOS 27.0, *)
struct FixedNDArrayState: SyncStateHandler, Sendable {
    let currentCapacity: Int = 0
    let stateNames: [String]
    private let states: [NDArray]

    init(stateNames: [String], states: [NDArray]) {
        self.stateNames = stateNames
        self.states = states
    }

    func ensureCapacity(forContextLength: Int) throws -> Bool { false }

    func reset() {}  // Persistent states are model-level, not session-level

    func bind(into views: inout InferenceFunction.MutableViews) {
        for (i, state) in states.enumerated() {
            var mutableState = state
            let view = _overrideLifetime(mutableState.mutableRawView(), borrowing: Void())
            views.insert(view, for: stateNames[i])
        }
    }
}

// MARK: - GrowingNDArrayState

/// KV cache that starts small and grows 2× on demand up to ``maxCapacity``.
///
/// Each growth event copies existing data to the new buffer (O(capacity)).
/// Amortized cost is O(log₂ N) since sizes double. Growth stalls ~20ms.
///
/// Aligned with upstream ``GrowingNDArrayState`` from coreai-models.
@available(macOS 27.0, iOS 27.0, *)
class GrowingNDArrayState: SyncStateHandler, @unchecked Sendable {
    /// Current capacity in tokens.
    var currentCapacity: Int

    /// State tensor names (always key + value).
    let stateNames: [String]

    /// Maximum tokens after which growth stops.
    private let maxCapacity: Int

    /// Key cache tensor — grows as needed.
    private var keyCache: NDArray

    /// Value cache tensor — grows as needed.
    private var valueCache: NDArray

    /// Descriptors for state (contain shape + dtype info).
    private let keyDescriptor: NDArrayDescriptor
    private let valueDescriptor: NDArrayDescriptor

    init(
        keyDescriptor: NDArrayDescriptor,
        valueDescriptor: NDArrayDescriptor,
        keyStateName: String,
        valueStateName: String,
        initialValue: Int,
        maxCapacity: Int
    ) throws {
        self.keyDescriptor = keyDescriptor
        self.valueDescriptor = valueDescriptor
        self.stateNames = [keyStateName, valueStateName]
        self.maxCapacity = maxCapacity
        self.currentCapacity = initialValue

        let keyShape = keyDescriptor.resolvingDynamicDimensions([1, 1, 1, initialValue])
        let valueShape = valueDescriptor.resolvingDynamicDimensions([1, 1, 1, initialValue])

        self.keyCache = NDArray(descriptor: keyShape)
        self.valueCache = NDArray(descriptor: valueShape)
    }

    func ensureCapacity(forContextLength capacity: Int) throws -> Bool {
        guard capacity > currentCapacity else { return false }
        let newCapacity = Swift.min(Swift.max(capacity, currentCapacity * 2), maxCapacity)
        guard newCapacity > currentCapacity else { return false }

        // Resize key cache
        let keyShape = keyDescriptor.resolvingDynamicDimensions([1, 1, 1, newCapacity])
        keyCache = NDArray(descriptor: keyShape)

        // Resize value cache
        let valueShape = valueDescriptor.resolvingDynamicDimensions([1, 1, 1, newCapacity])
        valueCache = NDArray(descriptor: valueShape)

        currentCapacity = newCapacity
        return true
    }

    func reset() {
        let shapeTemplate = keyDescriptor.resolvingDynamicDimensions([1, 1, 1, currentCapacity])
        keyCache = NDArray(descriptor: shapeTemplate)
        let valueShape = valueDescriptor.resolvingDynamicDimensions([1, 1, 1, currentCapacity])
        valueCache = NDArray(descriptor: valueShape)
    }

    func bind(into views: inout InferenceFunction.MutableViews) {
        let keyView = _overrideLifetime(keyCache.mutableRawView(), borrowing: Void())
        let valueView = _overrideLifetime(valueCache.mutableRawView(), borrowing: Void())
        views.insert(keyView, for: stateNames[0])
        views.insert(valueView, for: stateNames[1])
    }
}

// MARK: - StaticNDArrayState

/// Fixed-capacity KV cache that never grows.
///
/// Used when ``KVCacheStrategy/.fixedSize`` is set.
///
/// Aligned with upstream ``StaticNDArrayState`` from coreai-models.
@available(macOS 27.0, iOS 27.0, *)
struct StaticNDArrayState: SyncStateHandler, Sendable {
    let currentCapacity: Int
    let stateNames: [String]
    private let keyCache: NDArray
    private let valueCache: NDArray

    init(
        keyDescriptor: NDArrayDescriptor,
        valueDescriptor: NDArrayDescriptor,
        keyStateName: String,
        valueStateName: String,
        capacity: Int
    ) {
        self.currentCapacity = capacity
        self.stateNames = [keyStateName, valueStateName]
        let keyShape = keyDescriptor.resolvingDynamicDimensions([1, 1, 1, capacity])
        let valueShape = valueDescriptor.resolvingDynamicDimensions([1, 1, 1, capacity])
        self.keyCache = NDArray(descriptor: keyShape)
        self.valueCache = NDArray(descriptor: valueShape)
    }

    func ensureCapacity(forContextLength capacity: Int) throws -> Bool {
        guard capacity > currentCapacity else { return false }
        throw KVCacheError.capacityExceeded(needed: capacity, available: currentCapacity)
    }

    func reset() {}  // No-op for static — caller recreates on full reset

    func bind(into views: inout InferenceFunction.MutableViews) {
        var mutableKeyCache = keyCache
        var mutableValueCache = valueCache
        let keyView = _overrideLifetime(mutableKeyCache.mutableRawView(), borrowing: Void())
        let valueView = _overrideLifetime(mutableValueCache.mutableRawView(), borrowing: Void())
        views.insert(keyView, for: stateNames[0])
        views.insert(valueView, for: stateNames[1])
    }
}

// MARK: - StateHandlerFactory

/// Factory that creates appropriate state handlers from a model's function descriptor.
///
/// Inspects state descriptors, detects dynamic dimensions, and selects the matching
/// handler type (growing vs static vs fixed-shape).
///
/// Aligned with upstream ``StateHandlerFactory`` from coreai-models.
@available(macOS 27.0, iOS 27.0, *)
enum StateHandlerFactory {
    /// Creates the KV cache handler and optional persistent state handler.
    ///
    /// - ``kvCache``: The primary state handler (always present).
    /// - ``additionalStates``: Optional fixed-shape persistent states for hybrid models.
    /// - ``hasNonTruncatableStates``: Whether the model has recurrent/conv states that cannot
    ///   be truncated (requires full replay on prefix rewind).
    static func createSyncHandlers(
        descriptor: InferenceFunctionDescriptor,
        maxContextLength: Int,
        options: EngineOptions
    ) throws -> (
        kvCache: any SyncStateHandler,
        additionalStates: FixedNDArrayState?,
        hasNonTruncatableStates: Bool
    ) {
        let stateNames = descriptor.stateNames
        guard stateNames.count >= 2 else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 2 states (KV cache pair), got \(stateNames.count)")
        }

        // First 2 states are always KV cache
        let keyName = stateNames[0]
        let valueName = stateNames[1]

        // Extract KV cache descriptors
        guard case .ndArray(let keyDesc) = descriptor.stateDescriptor(of: keyName) else {
            throw InferenceRuntimeError.invalidState("Cannot get descriptor for '\(keyName)'")
        }
        guard case .ndArray(let valueDesc) = descriptor.stateDescriptor(of: valueName) else {
            throw InferenceRuntimeError.invalidState("Cannot get descriptor for '\(valueName)'")
        }

        // Check if KV cache S dimension is dynamic (grows at runtime)
        // Conservative default: treat KV cache as dynamic if strategy is auto or growing
        let isDynamicKV = true

        let resolvedKVCacheSize = options.resolvedKVCacheSize(maxContextLength: maxContextLength)

        let kvHandler: any SyncStateHandler
        switch options.kvCacheStrategy {
        case .auto:
            if isDynamicKV {
                kvHandler = try GrowingNDArrayState(
                    keyDescriptor: keyDesc,
                    valueDescriptor: valueDesc,
                    keyStateName: keyName,
                    valueStateName: valueName,
                    initialValue: resolvedKVCacheSize ?? 256,
                    maxCapacity: maxContextLength
                )
            } else {
                kvHandler = StaticNDArrayState(
                    keyDescriptor: keyDesc,
                    valueDescriptor: valueDesc,
                    keyStateName: keyName,
                    valueStateName: valueName,
                    capacity: maxContextLength
                )
            }
        case .fixedSize:
            kvHandler = StaticNDArrayState(
                keyDescriptor: keyDesc,
                valueDescriptor: valueDesc,
                keyStateName: keyName,
                valueStateName: valueName,
                capacity: resolvedKVCacheSize ?? maxContextLength
            )
        case .growing:
            kvHandler = try GrowingNDArrayState(
                keyDescriptor: keyDesc,
                valueDescriptor: valueDesc,
                keyStateName: keyName,
                valueStateName: valueName,
                initialValue: resolvedKVCacheSize ?? 256,
                maxCapacity: maxContextLength
            )
        case .chunked:
            kvHandler = StaticNDArrayState(
                keyDescriptor: keyDesc,
                valueDescriptor: valueDesc,
                keyStateName: keyName,
                valueStateName: valueName,
                capacity: maxContextLength
            )
        }

        // States beyond KV cache (indices 2+) are persistent/fixed-shape
        // (recurrent, conv, etc.) used by hybrid models
        var additionalStates: FixedNDArrayState? = nil
        var hasNonTruncatable = false

        if stateNames.count > 2 {
            let persistentNames = Array(stateNames[2...])
            var persistentArrays: [NDArray] = []

            for pname in persistentNames {
                guard case .ndArray(let pDesc) = descriptor.stateDescriptor(of: pname) else {
                    throw InferenceRuntimeError.invalidState(
                        "Cannot get persistent state descriptor for '\(pname)'")
                }
                persistentArrays.append(NDArray(descriptor: pDesc))
                hasNonTruncatable = true
            }

            additionalStates = FixedNDArrayState(
                stateNames: persistentNames,
                states: persistentArrays
            )
        }

        return (
            kvCache: kvHandler,
            additionalStates: additionalStates,
            hasNonTruncatableStates: hasNonTruncatable
        )
    }
}

// MARK: - runWithStates

/// Run an inference step with combined primary + secondary states and output.
/// Zero-copy: bind(into:) uses reference-backed storage.
@available(macOS 27.0, iOS 27.0, *)
func runWithStates(
    function: InferenceFunction,
    inputs: [String: NDArray],
    primary: any SyncStateHandler,
    secondary: FixedNDArrayState?,
    outputArray: inout NDArray,
    outputName: String
) async throws {
    var states = InferenceFunction.MutableViews()
    primary.bind(into: &states)
    secondary?.bind(into: &states)

    var outputViews = InferenceFunction.MutableViews()
    outputViews.insert(&outputArray, for: outputName)

    _ = try await function.run(
        inputs: inputs,
        states: states,
        outputViews: outputViews
    )
}

// MARK: - KVCacheError

/// Error type for KV cache capacity and layout issues.
@available(macOS 27.0, iOS 27.0, *)
enum KVCacheError: Error, LocalizedError {
    case allocationFailed(Int)
    case unsupportedStrategy(String)
    case layoutCreationFailed
    case capacityExceeded(needed: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .allocationFailed(let bytes):
            return "Failed to allocate KV cache buffer of \(bytes) bytes"
        case .unsupportedStrategy(let strategy):
            return "Unsupported KV cache strategy: \(strategy)"
        case .layoutCreationFailed:
            return "Failed to create tensor layout from requirements"
        case .capacityExceeded(let needed, let available):
            return
                "KV cache capacity exceeded: need \(needed) tokens but only \(available) available"
        }
    }
}

#endif  // canImport(CoreAI)
