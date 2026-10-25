// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
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
// Measured 10-14 (scripts/probes/01-prefix-accounting.sh, default gemma model): every warm
// turn reported `cached=0`, the whole prompt re-prefilled. The reason recorded here at the
// time — `canRewind` requiring `cache.isTrimmable` — was read off the wrong rule, and the
// correction is the lesson: a transcript that only *grows* is decided by
// `ExtendCachedPrefixRule`, which never consults trimmability and was bailing on
// `carriesAttentionMask` (Gemma 4's processor paired every text prompt with an all-ones
// mask). Upstream #700 dropped that mask, and the same script on the same model at pin
// 6e338e5 measured 710/730 and 733/749 tokens reused. Trimmability belongs to the
// *divergent* path (`RewindToCommonPrefixRule`), which upstream #622 made rewinds possible
// on for rotating caches via an opt-in reserve this engine does not yet request.
//
// What this file does is unchanged and stays the point: publish whichever answer upstream
// reported, and nothing else.
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

// MARK: - Per-turn statement

/// What one completed turn owes the log about the prefix cache.
///
/// The pool's `Session pool HIT` line says history was withheld; only upstream knows whether
/// the KV cache actually kept the prefix. Both outcomes need saying: a warm turn that quietly
/// paid the whole prefill is the defect this repo already named (invariant 2), and a warm turn
/// that quietly *saved* hundreds of tokens is equally invisible — silence cannot distinguish
/// "nothing happened" from "nobody looked", which is why the live probe counts these lines
/// per turn and demands they add up.
///
/// Pure, so the wording and the silence are both pinnable without Metal or a loaded model.
enum PrefixReuseStatement: Equatable, Sendable {
    /// Upstream kept `cached` prompt tokens and prefilled the remaining `prefilled`.
    case reused(message: String)
    /// Upstream re-prefilled the whole prompt although the pool withheld messages.
    case noReuse(message: String)
    /// Nothing was withheld from the feed, so there is nothing to account for.
    case nothing

    /// Decide from upstream's own numbers — never from a cache kind, and never a guess.
    ///
    /// - Parameters:
    ///   - withheld: messages the pool withheld from this feed (`divergenceIndex`).
    ///   - prefilled: upstream `GenerateCompletionInfo.promptTokenCount` — what this turn paid.
    ///   - cached: upstream `GenerateCompletionInfo.cachedPromptTokenCount` — what it kept.
    ///   - promptMs: upstream `promptTime`, already in whole milliseconds.
    static func decide(
        convKey: String,
        withheld: Int,
        prefilled: Int,
        cached: Int,
        promptMs: Int
    ) -> PrefixReuseStatement {
        guard withheld > 0 else { return .nothing }
        if cached > 0 {
            return .reused(
                message:
                    "Prefix cache reused \(cached) of \(cached + prefilled) prompt tokens for \(convKey): withheld \(withheld) message(s) from the feed, upstream prefilled \(prefilled) (cached=\(cached), promptTime=\(promptMs)ms)"
            )
        }
        return .noReuse(
            message:
                "Prefix cache reused no tokens for \(convKey): withheld \(withheld) message(s) from the feed, upstream prefilled all \(prefilled) prompt tokens (cached=0, promptTime=\(promptMs)ms)"
        )
    }
}
