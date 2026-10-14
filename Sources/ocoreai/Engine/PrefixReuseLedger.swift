// Prefix reuse accounting — what the KV prefix cache actually saved, per model.
//
// ### Why this exists
// AGENTS.md invariant 2: a capability statement a client can read must be *measured*, and
// must degrade honestly where the backend cannot deliver. Prefix reuse is exactly such a
// capability: `usage.prompt_tokens_details.cached_tokens` is per-response, so a client
// that wants to know "will a long conversation get cheaper as it grows, on THIS model?"
// has to guess from 400 requests. Meanwhile the engine has known the answer since def1964
// and only shouted it into a per-turn log line.
//
// Measured 10-14 (scripts/probes/01-prefix-accounting.sh, default gemma model): every
// warm turn reports `cached=0` with the whole prompt re-prefilled. The upstream reason is
// pinned — `PromptCacheReusePolicy.canRewind` requires `cache.isTrimmable`, and
// `BaseKVCache.isTrimmable` is false for this model's cache kind. So the honest public
// answer today is "no reuse observed", and this file makes that answer readable instead
// of inferred.
//
// ### What this deliberately is NOT
// Not a prediction. ocoreai does not re-derive trimmability from cache kinds here — that
// would be a second source of routing/capability truth maintained by hand, the exact
// anti-pattern this repo keeps naming. The status is *retroactive*: it summarizes what
// upstream reported on completed turns. Before any warm turn completes the answer is
// `not_observed`, never a guess of `supported`.

import Foundation

// MARK: - Wire line

/// Per-model prefix-reuse disposition, published on
/// `GET /v1/models/:model/kv-cache` as `prefixReuse`.
struct PrefixReuseObservation: Encodable, Equatable, Sendable {
    /// `not_observed` | `no_reuse_observed` | `reuse_observed`.
    ///
    /// Derived from the counters below, never set independently — so the wire cannot
    /// advertise a capability the counters do not show.
    let status: String
    /// Completed turns where the session pool withheld messages the pooled session already
    /// held — the only turns where reuse is even possible. Cold turns are excluded: they
    /// report `cached=0` legitimately and must not be misread as a broken cache.
    let warmTurns: Int
    /// How many of those warm turns came back with cached tokens > 0.
    let turnsWithReuse: Int
    /// Last warm turn's numbers, for a client deciding a context budget.
    let lastPrefilled: Int?
    let lastCached: Int?
    let lastPromptMs: Int?

    /// The one place `status` is decided.
    static func status(warmTurns: Int, turnsWithReuse: Int) -> String {
        if warmTurns <= 0 { return "not_observed" }
        return turnsWithReuse > 0 ? "reuse_observed" : "no_reuse_observed"
    }

    /// What a model with no completed turns reports: no claim either way.
    static let notObserved = PrefixReuseObservation(
        status: "not_observed",
        warmTurns: 0,
        turnsWithReuse: 0,
        lastPrefilled: nil,
        lastCached: nil,
        lastPromptMs: nil)
}

// MARK: - Ledger

/// One model's counters.
struct PrefixReuseEntry: Equatable, Sendable {
    var warmTurns: Int = 0
    var turnsWithReuse: Int = 0
    var lastPrefilled: Int?
    var lastCached: Int?
    var lastPromptMs: Int?

    var observation: PrefixReuseObservation {
        PrefixReuseObservation(
            status: PrefixReuseObservation.status(
                warmTurns: warmTurns, turnsWithReuse: turnsWithReuse),
            warmTurns: warmTurns,
            turnsWithReuse: turnsWithReuse,
            lastPrefilled: lastPrefilled,
            lastCached: lastCached,
            lastPromptMs: lastPromptMs)
    }
}

/// Pure per-model accumulator — no actor, no I/O, so the state machine is pinnable
/// without Metal or a loaded model.
struct PrefixReuseLedger: Sendable {
    private(set) var entries: [String: PrefixReuseEntry] = [:]

    /// Record one completed generation.
    ///
    /// - Parameters:
    ///   - warm: true when the pool withheld messages this session already held (reuse was
    ///     possible); false for a cold turn, which is not evidence about reuse.
    ///   - prefilled: upstream `GenerateCompletionInfo.promptTokenCount`.
    ///   - cached: upstream `GenerateCompletionInfo.cachedPromptTokenCount`.
    ///   - promptSeconds: upstream `promptTime`, stored as whole milliseconds.
    mutating func record(
        modelId: String,
        warm: Bool,
        prefilled: Int,
        cached: Int,
        promptSeconds: Double
    ) {
        var entry = entries[modelId] ?? PrefixReuseEntry()
        if warm {
            entry.warmTurns += 1
            if cached > 0 { entry.turnsWithReuse += 1 }
            entry.lastPrefilled = prefilled
            entry.lastCached = cached
            entry.lastPromptMs = Int(promptSeconds * 1000)
        }
        entries[modelId] = entry
    }

    func observation(modelId: String) -> PrefixReuseObservation {
        entries[modelId]?.observation ?? .notObserved
    }

    /// Drop a model's history — called when its session state is invalidated, because
    /// observations made under the old cache topology no longer describe it.
    mutating func forget(modelId: String) {
        entries[modelId] = nil
    }
}
