// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// KV cache residency — what a resident cache actually costs, in bytes, measured.
//
// ### Why this exists
// AGENTS.md invariant 2: anything a client can read must be measured. Two surfaces read
// "GPU memory for KV cache": `/metrics` (`ocoreai_kv_cache_gpu_bytes`,
// `ocoreai_gpu_memory_gb`) and the dashboard's GPU tile. Both were fed by
// `EnginePool.engineSummary()`, whose `gpuCacheGB` was the literal `0.0` — so every
// deployment ever run reported a zero-byte KV cache while the same process held hundreds of
// megabytes of it (measured live: model ready, no turn yet, both series 0).
//
// The quantity exists upstream and needs no prefill to price: `ChatSession.cacheStatus()`
// reports `.realized` per-layer `memoryBytes`, which mlx-swift-lm computes as
// `cache.innerState().reduce(0) { $0 + $1.nbytes }` (KVCacheRuntime.swift:210) — allocated
// bytes including room reserved for tokens not yet written, so sliding-window layers, KV
// sharing and the `.turboQuant`/`.affine` strategies are all priced by the code that owns them.
// This file only carries that answer to the surfaces; it derives no geometry of its own.
//
// ### Where the number lives, and why there
// On the pooled session, not in a ledger keyed by session. The pool is the set of caches that
// are resident, and it mutates at ten sites (evict, TTL, unload, reset); a side ledger has to
// be told at every one of them or the total rots upward. A number that travels with the entry
// is freed exactly when the entry is.

import Foundation
import MLXLMCommon

/// One measurement taken off a session that has finished a turn.
struct KVCacheResidency: Sendable, Equatable {
    /// Allocated KV bytes across every layer of this session's cache.
    let residentBytes: Int
    /// Tokens the cache provably holds, upstream's own counter (`nil` → 0).
    let processedTokens: Int

    init(status: KVCacheStatus) {
        self.residentBytes = status.layers.reduce(0) { $0 + $1.memoryBytes }
        self.processedTokens = status.processedTokenCount ?? 0
    }

    /// Bytes per held token — the per-model price the admission gate should reserve at.
    ///
    /// `nil` while nothing measurable is resident: an unmeasured price is not a price of 1 KB.
    var bytesPerToken: Int? {
        processedTokens > 0 ? residentBytes / processedTokens : nil
    }
}

/// Wire shape for `GET /v1/models/:model/kv-cache` as `residency`.
///
/// `status` is derived from the counts below and never set beside them, so the wire cannot
/// claim `measured` on a model whose caches are not in RAM right now.
struct KVCacheResidencyObservation: Encodable, Equatable, Sendable {
    /// `not_observed` | `measured`.
    let status: String
    /// Allocated KV bytes across this model's resident sessions.
    let residentBytes: Int
    /// How many sessions of this model are in the pool holding those bytes.
    let residentSessions: Int
    /// Tokens those caches hold.
    let processedTokens: Int
    /// `residentBytes / processedTokens` over the same set, or `nil` when unmeasured.
    let bytesPerToken: Int?

    static let notObserved = KVCacheResidencyObservation(
        status: "not_observed",
        residentBytes: 0,
        residentSessions: 0,
        processedTokens: 0,
        bytesPerToken: nil)

    static func measured(
        residentBytes: Int,
        residentSessions: Int,
        processedTokens: Int
    ) -> KVCacheResidencyObservation {
        // All three must be positive: bytes without tokens cannot price a token, and tokens
        // without bytes would publish a "measured" cache that occupies nothing.
        guard residentBytes > 0, residentSessions > 0, processedTokens > 0 else {
            return .notObserved
        }
        return KVCacheResidencyObservation(
            status: "measured",
            residentBytes: residentBytes,
            residentSessions: residentSessions,
            processedTokens: processedTokens,
            bytesPerToken: residentBytes / processedTokens)
    }
}

// MARK: - Per-model price

/// The measured price of one KV token for a model, in bytes.
///
/// Deliberately a different store from the session's `residentKVBytes`: bytes are resident
/// *now* and die with the session that holds them, while the price is a property of the
/// weights and stays valid until they are unloaded (a reload may be a different checkpoint,
/// so `forget` sends it back to unpriced rather than trusting it across weights).
///
/// Why the admission gate needs it: `Scheduler/KVCacheBudget.swift` reserves 1024 B/token for
/// every model on every request, a number carried over from a weights heuristic. Measured on
/// the default checkpoint: 10,475 B/token (probe 35) — 10× under-reserved, which is exactly
/// the arithmetic that admits a request the engine then cannot hold.
actor KVCachePriceLedger {
    static let shared = KVCachePriceLedger()

    private var prices: [String: Int] = [:]

    /// Record a price only from a complete measurement.
    func record(modelId: String, residentBytes: Int, processedTokens: Int) {
        guard residentBytes > 0, processedTokens > 0 else { return }
        prices[modelId] = residentBytes / processedTokens
    }

    /// The measured price, or nil when this checkpoint has never been priced.
    func price(modelId: String) -> Int? {
        prices[modelId]
    }

    /// Weights are gone, so the price earned by those weights goes with them.
    func forget(modelId: String) {
        prices[modelId] = nil
    }

    func snapshot() -> [String: Int] {
        prices
    }
}
