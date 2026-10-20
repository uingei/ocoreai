// KV cache inspection endpoint — GET /v1/models/:model/kv-cache
//
// Surfaces the model's planned KV/SSM cache topology and capacity disposition
// by consuming upstream `ModelContainer.cacheStatus(parameters:)`
// (mlx-swift-lm c6446cf). Parameter construction mirrors the inference path:
// per-model sampling defaults + the model's live kvCacheQuantization.
//
// Upstream types are `Sendable, Hashable` only (no Codable), and
// `KVCacheLayerStatus.init` is package-visible — so the wire surface is a
// local struct with an explicit, exhaustive mapping below.

import Foundation
import MLXLMCommon

// MARK: - Wire

/// JSON wire view of upstream ``KVCacheStatus``.
struct KVCacheStatusResponse: Encodable {
    let phase: String
    let requestSource: String?
    let layerCount: Int
    let layers: [KVCacheLayerWire]
    let processedTokenCount: Int?
    let capacityDisposition: String
    let capacityAppliedLayerCount: Int
    let capacityUnappliedLayerCount: Int
    let requestedStrategy: String?
    let requestedCapacity: KVCapacityWire?
    let compressedLayerCount: Int
    let pendingLayerCount: Int
    let skippedLayerCount: Int
    let isHybrid: Bool
    let attentionMaxSizes: [Int?]

    struct KVCacheLayerWire: Encodable {
        let path: [Int]
        let kind: String
        let isAttention: Bool
        let attentionMaxSize: Int?
        let rotatingMaxSize: Int?
        let rotatingKeep: Int?
        let compositeKinds: [String]?
        let capacitySource: String?
        let state: String
        let resolvedStrategy: String?
        let reason: String?
    }

    struct KVCapacityWire: Encodable {
        let maxTokens: Int
        let preservedPrefixTokens: Int
    }

    /// What the engine has *measured* about KV prefix reuse on this model, from
    /// upstream's own `cachedPromptTokenCount` on completed turns. `not_observed`
    /// before any warm turn completes — never a guessed "supported".
    let prefixReuse: PrefixReuseObservation

    /// What the engine has *measured* about this checkpoint's own chat template: whether it
    /// declares tools itself, which decides whether this server writes a second copy.
    /// `injected_unmeasured` when this process never probed it — never a claimed capability.
    let toolProse: ToolProseObservation

    /// Which reuse rule turned a warm session away, counted per refusal, plus how many cold
    /// turns arrived while another session for the same model already held part of their feed
    /// (ReuseRefusalLedger.swift). Counted where the pool already decided — it publishes the
    /// cost of the rules, never a claim that loosening them would save anything.
    let reuseRefusals: ReuseRefusalObservation

    init(
        status: KVCacheStatus,
        prefixReuse: PrefixReuseObservation = .notObserved,
        toolProse: ToolProseObservation = ToolProseMode.injectedUnmeasured.observation,
        reuseRefusals: ReuseRefusalObservation = .empty
    ) {
        self.prefixReuse = prefixReuse
        self.toolProse = toolProse
        self.reuseRefusals = reuseRefusals
        let layers = status.layers.map { KVCacheLayerWire(layer: $0) }
        let requestedCapacity = status.requestedConfiguration?.capacity.map {
            KVCapacityWire(
                maxTokens: $0.maxTokens,
                preservedPrefixTokens: $0.preservedPrefixTokens)
        }
        phase = status.phase == .planned ? "planned" : "realized"
        requestSource = status.requestSource.map {
            $0 == .legacy ? "legacy" : "typed"
        }
        layerCount = status.layers.count
        self.layers = layers
        processedTokenCount = status.processedTokenCount
        capacityDisposition = Self.disposition(status.capacityDisposition)
        capacityAppliedLayerCount = status.capacityAppliedLayerCount
        capacityUnappliedLayerCount = status.capacityUnappliedLayerCount
        requestedStrategy = status.requestedStrategy?.rawValue
        self.requestedCapacity = requestedCapacity
        compressedLayerCount = status.compressedLayerCount
        pendingLayerCount = status.pendingLayerCount
        skippedLayerCount = status.skippedLayerCount
        isHybrid = status.isHybrid
        attentionMaxSizes = status.attentionMaxSizes
    }
}

// MARK: - Layer mapping (exhaustive — upstream renames fail compilation here)

private func kvLayerAttributes(_ kind: CacheLayerKind)
    -> (
        kind: String,
        rotatingMaxSize: Int?,
        rotatingKeep: Int?,
        compositeKinds: [String]?
    )
{
    switch kind {
    case .attention:
        return ("attention", nil, nil, nil)
    case .rotatingAttention(let maxSize, let keep):
        return ("rotating_attention", maxSize, keep, nil)
    case .stateSpace:
        return ("state_space", nil, nil, nil)
    case .composite(let children):
        return ("composite", nil, nil, children.map(kvLayerKindName))
    }
}

private func kvLayerKindName(_ k: CacheLayerKind) -> String {
    switch k {
    case .attention: "attention"
    case .rotatingAttention: "rotating_attention"
    case .stateSpace: "state_space"
    case .composite: "composite"
    }
}

extension KVCacheStatusResponse.KVCacheLayerWire {
    fileprivate init(layer: KVCacheLayerStatus) {
        let attrs = kvLayerAttributes(layer.kind)
        path = layer.path
        kind = attrs.kind
        isAttention = layer.kind.isAttention
        attentionMaxSize = layer.kind.attentionMaxSize
        rotatingMaxSize = attrs.rotatingMaxSize
        rotatingKeep = attrs.rotatingKeep
        compositeKinds = attrs.compositeKinds
        capacitySource = layer.capacitySource.map(Self.capacitySourceName)
        state = Self.stateName(layer.state)
        resolvedStrategy = layer.resolvedStrategy?.rawValue
        reason = layer.reason.map(Self.reasonName)
    }

    fileprivate static func capacitySourceName(
        _ s: KVCacheLayerStatus.CapacitySource
    ) -> String {
        switch s {
        case .unbounded: "unbounded"
        case .modelDefined: "model_defined"
        case .requested: "requested"
        case .implementationDefined: "implementation_defined"
        }
    }

    fileprivate static func stateName(_ s: KVCacheLayerStatus.State) -> String {
        switch s {
        case .active: "active"
        case .pending: "pending"
        case .skipped: "skipped"
        case .notApplicable: "not_applicable"
        }
    }

    fileprivate static func reasonName(_ r: KVCacheLayerStatus.Reason) -> String {
        switch r {
        case .awaitingCompressionStart: "awaiting_compression_start"
        case .boundaryProtection: "boundary_protection"
        case .slidingWindow: "sliding_window"
        case .unsupportedShape: "unsupported_shape"
        case .differentStrategy: "different_strategy"
        case .nonAttentionState: "non_attention_state"
        }
    }
}

extension KVCacheStatusResponse {
    fileprivate static func disposition(_ d: KVCacheStatus.CapacityDisposition) -> String {
        switch d {
        case .notRequested: "not_requested"
        case .fullyApplied: "fully_applied"
        case .partiallyApplied: "partially_applied"
        case .unsupported: "unsupported"
        case .ignored: "ignored"
        }
    }
}

// MARK: - Pure mapping entry (test seam)

/// Pure mapping — upstream ``KVCacheStatus`` → wire encodable.
///
/// `prefixReuse` is carried through unchanged: it is measured by the engine elsewhere,
/// never derived from this plan, so the two sources cannot disagree about a capability.
nonisolated func makeKVCacheStatusResponse(
    _ status: KVCacheStatus,
    prefixReuse: PrefixReuseObservation = .notObserved,
    toolProse: ToolProseObservation = ToolProseMode.injectedUnmeasured.observation,
    reuseRefusals: ReuseRefusalObservation = .empty
) -> KVCacheStatusResponse {
    KVCacheStatusResponse(
        status: status, prefixReuse: prefixReuse, toolProse: toolProse, reuseRefusals: reuseRefusals
    )
}

// MARK: - EnginePool consumption

extension EnginePool {
    /// Planned cache status for one loaded model (no active generation needed).
    ///
    /// Mirrors the inference-side parameter construction so the reported plan
    /// is the plan the engine would actually build: per-model sampling
    /// defaults cascaded into ``SamplingConfiguration``, plus the model's
    /// live KV-quantization config.
    func kvCacheStatus(modelId: String) async throws -> KVCacheStatusResponse {
        guard let loaded = loadedModels[modelId] else {
            throw AppError.modelNotFound(modelId)
        }
        guard let handle = loaded.mlxModelHandle else {
            throw AppError.kvCacheStatusUnsupported
        }

        let modelConfig = getSamplingConfig(modelId: modelId)
        let sampling = SamplingConfiguration().fastPathDefaults(modelConfig)
        let params = makeGenerateParameters(
            from: sampling,
            maxTokens: modelConfig.maxTokens,
            kvCacheQuant: loaded.kvCacheQuantization
        )

        do {
            let status = try await handle.modelContainer.cacheStatus(parameters: params)
            return makeKVCacheStatusResponse(
                status,
                prefixReuse: prefixReuse.observation(modelId: modelId),
                toolProse: await ToolProseLedger.shared.observation(modelId: modelId),
                reuseRefusals: await sessionPool?.reuseRefusalObservation(modelId: modelId)
                    ?? .empty)
        } catch {
            throw AppError.inferenceFailed("KV cache status: \(error)")
        }
    }
}
