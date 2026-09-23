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
/// Classification of a model state's lifecycle behavior.
enum StateKind: String, Codable, Sendable {
    case kvCache = "kv_cache"
    case slidingCache = "sliding_cache"
    case fixed
}

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

    /// Index of the dynamic (sequence-length) axis — the negative axis in the
    /// descriptor's shape. This is the axis that `resolvingDynamicDimensions`
    /// expands, and the axis along which `copyStateCache` preserves data on
    /// growth. Derived from the descriptor (upstream `sequenceDimIndex`)
    /// rather than hardcoded, so it is correct for any rank/axis layout.
    private let sequenceDimIndex: Int

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
        self.sequenceDimIndex =
            keyDescriptor.shape.firstIndex(where: { $0 < 0 })
            ?? (keyDescriptor.shape.count - 1)

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
        var newKeyCache = NDArray(descriptor: keyShape)
        _ = newKeyCache.mutableRawView()
        copyStateCache(from: keyCache, to: &newKeyCache, sequenceDim: sequenceDimIndex)
        keyCache = newKeyCache

        // Resize value cache
        let valueShape = valueDescriptor.resolvingDynamicDimensions([1, 1, 1, newCapacity])
        var newValueCache = NDArray(descriptor: valueShape)
        _ = newValueCache.mutableRawView()
        copyStateCache(from: valueCache, to: &newValueCache, sequenceDim: sequenceDimIndex)
        valueCache = newValueCache

        currentCapacity = newCapacity
        return true
    }

    func reset() {
        zeroFillNDArray(&keyCache)
        zeroFillNDArray(&valueCache)
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
    /// Classify model states by name heuristic (mirrors upstream classifyStates).
    static func classifyStates(
        descriptor: InferenceFunctionDescriptor,
        stateKinds: [String: StateKind]? = nil,
        verbose: Bool = false
    ) -> [(name: String, kind: StateKind)] {
        let names = descriptor.stateNames
        if let kinds = stateKinds {
            return names.map { name in
                (name, kinds[name] ?? inferKind(name: name, descriptor: descriptor))
            }
        }
        if names.count == 2 {
            return names.map { ($0, StateKind.kvCache) }
        }
        return names.map { name in (name, inferKind(name: name, descriptor: descriptor)) }
    }

    private static func inferKind(
        name: String,
        descriptor: InferenceFunctionDescriptor
    ) -> StateKind {
        let lower = name.lowercased()
        if lower.contains("kv") || lower.contains("cache_key") || lower.contains("cache_value") {
            return .kvCache
        }
        if lower.contains("sliding") || lower.contains("window") {
            return .slidingCache
        }
        if lower.contains("recurrent") || lower.contains("conv") || lower.contains("memory") {
            return .fixed
        }
        // Heuristic: check if shape has a dynamic dim
        if case .ndArray(let desc) = descriptor.stateDescriptor(of: name) {
            for dim in desc.shape {
                if dim < 0 { return .kvCache }
            }
            return .fixed
        }
        return .fixed
    }

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

/// Run a step with combined states but no output binding — for functions whose
/// descriptor declares no outputs (the `prefill` graph). Mirrors `runWithStates`
/// minus the output views.
@available(macOS 27.0, iOS 27.0, *)
func runWithStatesNoOutputs(
    function: InferenceFunction,
    inputs: [String: NDArray],
    primary: any SyncStateHandler,
    secondary: FixedNDArrayState?
) async throws {
    var states = InferenceFunction.MutableViews()
    primary.bind(into: &states)
    secondary?.bind(into: &states)

    _ = try await function.run(
        inputs: inputs,
        states: states,
        outputViews: InferenceFunction.MutableViews()
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
    case invalidState(String)

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
        case .invalidState(let msg):
            return "KV cache invalid state: \(msg)"
        }
    }
}

// MARK: - Shared Utilities

/// Copy the already-encoded rows of a smaller KV-state tensor into a freshly
/// allocated larger one (used on growth).
///
/// The KV-cache state is a tensor with a single dynamic (sequence-length) axis
/// `sequenceDim`; every other axis is fixed and identical between the source
/// (old capacity) and the destination (new capacity). Ocoreai's canonical
/// layout is `[B, H, S, D]` / `[L, B, H, S, D]` (see
/// `KVCacheFactory.detectSequenceDim`), where `S` grows and `D` (head_dim) is
/// the fixed trailing axis — but this helper is written for the general case
/// (any fixed axes after `S`) so the exact layout does not matter, only that
/// `sequenceDim` points at the growing axis.
///
/// For each "block" (the product of the axes before `S`) and each old sequence
/// position, the fixed per-position run (the product of the axes after `S`) is
/// copied to the front of the block's new, larger sequence run. This preserves
/// exactly the `oldSeqLen × run` elements that were already encoded, in the
/// same relative order — no more, no less (no out-of-bounds read).
///
/// Scalar-type-aware, mirroring upstream coreai-models `StateHandler+NDArray`
/// (copyCache, #268): 16-bit types (Float16 *and* BFloat16) are copied as raw
/// bytes — both are 16 bits, values move verbatim, and a typed
/// `view(as: Float16.self)` would trap on a BFloat16 array. Float32 uses the
/// typed `Float` view.
///
/// - Parameters:
///   - source: The old (smaller) state tensor.
///   - destination: The new (larger) state tensor to receive the copied rows.
///   - sequenceDim: Index of the dynamic (sequence-length) axis.
@available(macOS 27.0, iOS 27.0, *)
func copyStateCache(from source: NDArray, to destination: inout NDArray, sequenceDim: Int) {
    let srcShape = source.shape
    let dstShape = destination.shape
    guard srcShape.count == dstShape.count,
        srcShape.count > sequenceDim,
        srcShape[sequenceDim] <= dstShape[sequenceDim]
    else { return }

    let numBlocks = srcShape[..<sequenceDim].reduce(1, *)
    let oldSeqLen = srcShape[sequenceDim]
    let newSeqLen = dstShape[sequenceDim]
    let run = srcShape[(sequenceDim + 1)...].reduce(1, *)
    guard numBlocks > 0, oldSeqLen > 0, run > 0, newSeqLen >= oldSeqLen else { return }

    let srcBlockStride = oldSeqLen * run
    let dstBlockStride = newSeqLen * run

    switch source.scalarType {
    case .float16, .bfloat16:
        // Both are 16-bit; reinterpret as raw bytes and copy them verbatim.
        // A typed Float16 view traps on BFloat16 (scalar types must match), so
        // the raw-view path is the only one correct for both (#268).
        source.rawView().withUnsafeBytes { srcRaw, _, _ in
            let src = srcRaw.assumingMemoryBound(to: UInt16.self)
            destination.mutableRawView().withUnsafeMutableBytes { dstRaw, _, _ in
                let dst = dstRaw.assumingMemoryBound(to: UInt16.self)
                for block in 0 ..< numBlocks {
                    let sBase = block * srcBlockStride
                    let dBase = block * dstBlockStride
                    for pos in 0 ..< oldSeqLen {
                        dst.advanced(by: dBase + pos * run)
                            .update(
                                from: src.advanced(by: sBase + pos * run),
                                count: run)
                    }
                }
            }
        }
    case .float32:
        source.view(as: Float.self).withUnsafePointer { src, _, _ in
            destination.mutableView(as: Float.self).withUnsafeMutablePointer { dst, _, _ in
                for block in 0 ..< numBlocks {
                    let sBase = block * srcBlockStride
                    let dBase = block * dstBlockStride
                    for pos in 0 ..< oldSeqLen {
                        dst.advanced(by: dBase + pos * run)
                            .update(
                                from: src.advanced(by: sBase + pos * run),
                                count: run)
                    }
                }
            }
        }
    default:
        // Unsupported scalar type for a KV state — surface rather than silently
        // corrupt the cache (preconditionFailure would trap in production).
        assertionFailure("Unsupported scalar type for state copy: \(source.scalarType)")
        return
    }
}

/// Explicitly zero-fill a state tensor (used on `reset()`).
///
/// Scalar-type-aware: 16-bit types (Float16 *and* BFloat16) zero to an all-zero
/// bit pattern, copied via the raw view to avoid the scalar-type trap that a
/// typed `mutableView(as: Float16.self)` hits on a BFloat16 array. Matches
/// upstream coreai-models `zeroFillNDArray` (#268).
@available(macOS 27.0, iOS 27.0, *)
func zeroFillNDArray(_ array: inout NDArray) {
    let count = array.shape.reduce(1, *)
    switch array.scalarType {
    case .float16, .bfloat16:
        _ = array.mutableRawView().withUnsafeMutableBytes { ptr, _, _ in
            memset(ptr, 0, count * MemoryLayout<UInt16>.stride)
        }
    case .float32:
        _ = array.mutableView(as: Float.self).withUnsafeMutablePointer { ptr, _, _ in
            memset(ptr, 0, count * MemoryLayout<Float>.size)
        }
    default:
        assertionFailure("Unsupported scalar type for state: \(array.scalarType)")
        return
    }
}

#endif  // canImport(CoreAI)
