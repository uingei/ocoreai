// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ReuseRefusalLedger.swift — which rule turned a warm session away, counted per model.
//!
//! ### Why this exists
//! The pool already *decides* reuse refusal with named rules: ``SnapshotRefusal`` for the disk
//! path (six cases, pinned by `SessionIsolationTests`), and the same two premises inline at
//! the in-memory site (`SessionPool.swift`'s `canReusePooledSession` check). What it did with
//! the verdict was write one `logger.info` line per refusal and forget it. So the two open
//! decisions in this area have no numbers attached to them:
//!
//! 1. **Refresh vs refuse** — whether a session whose instructions changed should be updated
//!    in place (upstream codex #53872 tracks identity and instructions separately and appends
//!    a message instead of losing the prefix) or keep being refused. Probe 19 priced one
//!    instruction change at a full re-prefill (`prompt=1438 cached=0`); what it could not
//!    price was *how often* that happens.
//! 2. **Cross-conversation prefix reuse** — the pool keys sessions by
//!    `(modelId, conversationId)` (`SessionPool.swift` `poolKey`), so two conversations that
//!    open with the same instructions and the same first messages never share a prefix.
//!    codex #55587 (`ab6095dde0`) decouples the prompt-cache key from the session id for
//!    exactly this reason, though its axis is provider-side caching, not local KV. Whether
//!    loosening the key would save anything here depends on how often a *live* session for the
//!    same model already holds a prefix of the arriving conversation — a number nobody has.
//!
//! This ledger is that number. It changes no decision: every count here is taken at the site
//! where the existing rule already said no (AGENTS.md invariant 1 — an owner question gets an
//! instrument, not a guess), and `make audit` Class-J will not let the suites named below go
//! stale.
//!
//! ### What this deliberately is NOT
//! `crossConversationTurns` is an **opportunity** count, not a capability claim (invariant 2).
//! It says a resident session's transcript shared a prefix with this turn's feed under the same
//! instructions; it does *not* say those two conversations ever shared a prefix, because
//! sessions are still keyed by `conversationId` and no cross-conversation sharing exists.
//! (Divergence *within* one conversation is a different case and is no longer hypothetical:
//! a rewound turn reuses from the common prefix, measured 10-21 at 718 of 758 prompt tokens
//! on gemma-4-e2b-it-4bit, gate = probe 27. `historyDiverged` counts only refusals that
//! stayed refusals — an offer made is not recorded as a refusal, so a rewound turn cannot
//! inflate the opportunity count either.)
//! Before any turn has been refused the answer is an empty set, never a predicted `would_save`.

import Foundation

// MARK: - Reasons

/// Why a warm session or snapshot was not handed back. One name per refusal, in the same
/// precedence the disk path already applies (`reuseDecision` reports
/// ``SnapshotRefusal/instructionsChanged`` ahead of ``SnapshotRefusal/notAPrefix``, and the
/// in-memory path names both — here the first mismatch wins, and it wins in one place).
enum ReuseRefusalReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// The instruction set differs from the one the cache was built under: its tokens encode
    /// text this request never sent.
    case instructionsChanged
    /// The cache holds turns this feed does not (an edited resend, a fork, a foreign
    /// conversation that arrived under the same key).
    case historyDiverged
    /// A media turn on either side: a vision encoder attends an image beside a cached prefix
    /// differently than cold (upstream `ChatSession.swift:707-715`), so the pixels are not
    /// reconcilable from the manifest.
    case mediaTurn
    /// The ledger claims the cache already covers this turn's *entire* feed, and the feed's
    /// newest message is one that still needs an answer (a user/tool turn). A cache is only
    /// ever written after a completed answer, so a cache holding that message has already
    /// answered it — the answer is in the cache's past, not ahead of the prefix. Handing it
    /// back would feed the session nothing, and a session fed nothing emits end-of-turn
    /// immediately (measured 10-22: the same prompt asked twice answered `200 + 1 token +
    /// finish_reason=stop`, and once both halves of a concurrent identical pair did it).
    ///
    /// A feed whose newest message is from the assistant is a different request — "continue
    /// this draft" — and a cache holding exactly that transcript is the right answer to it,
    /// so that shape stays reusable (`SessionIsolationTests` pins both sides).
    case cacheCoversWholeFeed
    /// The cache was built for another model — its KV encodes other embeddings.
    case modelMismatch
    /// No sidecar, unreadable, or written by a build whose hashes came from the per-process
    /// seed: nothing states where the cache came from.
    case unusableManifest
    /// The snapshot was written under a different KV-cache plan than this build asks for, so
    /// its rows cannot be realized against today's generation parameters.
    case rewindReserveChanged

    /// The in-memory rule's verdict as a name, with `nil` meaning reusable.
    ///
    /// Same premises, same order as ``SnapshotRefusal``: identity first, then divergence —
    /// so the two paths cannot grow two spellings of one refusal.
    static func decide(
        instructionsMatch: Bool,
        cachedMessageCount: Int,
        commonPrefixCount: Int,
        incomingMessageCount: Int,
        newestIncomingFromAssistant: Bool
    ) -> ReuseRefusalReason? {
        if !instructionsMatch { return .instructionsChanged }
        if commonPrefixCount < cachedMessageCount { return .historyDiverged }
        if commonPrefixCount >= incomingMessageCount && !newestIncomingFromAssistant {
            return .cacheCoversWholeFeed
        }
        return nil
    }
}

extension SnapshotRefusal {
    /// The ledger name for a disk-path refusal, mapped by `switch` so a new case in
    /// ``SnapshotRefusal`` fails the build instead of being counted as something else.
    var ledgerReason: ReuseRefusalReason {
        switch self {
        case .unusableManifest: return .unusableManifest
        case .modelMismatch: return .modelMismatch
        case .mediaTurn: return .mediaTurn
        case .instructionsChanged: return .instructionsChanged
        case .notAPrefix: return .historyDiverged
        case .cacheCoversWholeFeed: return .cacheCoversWholeFeed
        case .rewindReserveChanged: return .rewindReserveChanged
        }
    }
}

// MARK: - Cross-conversation prefix

/// A resident session that already holds the head of this turn's feed.
struct PrefixOverlap: Equatable, Sendable {
    /// Leading messages the two transcripts agree on.
    let messagesInCommon: Int
    /// Messages in this turn's feed — the denominator a reader needs to judge the overlap.
    let feedMessages: Int
}

/// Pure scan for the opportunity class § Why-this-exists item 2 keys on.
enum CrossConversationPrefix {
    /// A pooled session other than this conversation's, as the scan sees it.
    struct Candidate: Equatable, Sendable {
        let messageHistory: [MessageHistoryKey]
        let instructionsHash: Int
    }

    /// The deepest prefix of `feed` already resident in one of `candidates`, or `nil`.
    ///
    /// Callers pass only candidates for the same model — the pool key carries the model, so a
    /// candidate from another model is not an opportunity but a different model's bytes.
    ///
    /// The premises mirror the rules that already refuse reuse, so the count does not
    /// advertise an opportunity the engine would refuse anyway:
    /// - instructions must match (a session renders the instructions it was created with);
    /// - the overlapped region must carry no media and no tool traffic on either side (the
    ///   persist path refuses to bank a prefix skip on either: `SessionPool.swift:771`).
    static func best(
        feed: [MessageHistoryKey],
        instructionsHash: Int,
        candidates: [Candidate]
    ) -> PrefixOverlap? {
        var bestOverlap = 0
        for candidate in candidates where candidate.instructionsHash == instructionsHash {
            let overlap = MessageHistoryKey.longestCommonPrefixCount(
                history: candidate.messageHistory,
                prefix: feed)
            guard overlap > bestOverlap else { continue }
            let resident = Array(candidate.messageHistory.prefix(overlap))
            let incoming = Array(feed.prefix(overlap))
            if resident.contains(where: { $0.hasMedia || $0.hasToolTraffic })
                || incoming.contains(where: { $0.hasMedia || $0.hasToolTraffic })
            {
                continue
            }
            bestOverlap = overlap
        }
        guard bestOverlap > 0 else { return nil }
        return PrefixOverlap(messagesInCommon: bestOverlap, feedMessages: feed.count)
    }
}

// MARK: - Wire line

/// Per-model refusal accounting, published on `GET /v1/models/:model/kv-cache`.
struct ReuseRefusalObservation: Encodable, Equatable, Sendable {
    /// Refusals since the model was loaded (or since its last `forget`).
    let total: Int
    /// Same total, split by ``ReuseRefusalReason`` raw value; absent keys mean "never".
    let byReason: [String: Int]
    /// Turns that paid a cold prefill while a resident session for the same model already
    /// held part of this feed. An opportunity count — see the file header, not a saving.
    let crossConversationTurns: Int
    /// Deepest such overlap seen, and this-turn feed length at that moment.
    let bestMessagesInCommon: Int?
    let bestFeedMessages: Int?

    static let empty = ReuseRefusalObservation(
        total: 0,
        byReason: [:],
        crossConversationTurns: 0,
        bestMessagesInCommon: nil,
        bestFeedMessages: nil)
}

// MARK: - Ledger

/// One model's counters.
struct ModelReuseRefusals: Equatable, Sendable {
    var byReason: [ReuseRefusalReason: Int] = [:]
    var crossConversationTurns: Int = 0
    var bestMessagesInCommon: Int = 0
    var bestFeedMessages: Int = 0

    var observation: ReuseRefusalObservation {
        var split: [String: Int] = [:]
        for (reason, count) in byReason { split[reason.rawValue] = count }
        return ReuseRefusalObservation(
            total: byReason.values.reduce(0, +),
            byReason: split,
            crossConversationTurns: crossConversationTurns,
            bestMessagesInCommon: bestMessagesInCommon > 0 ? bestMessagesInCommon : nil,
            bestFeedMessages: bestFeedMessages > 0 ? bestFeedMessages : nil)
    }
}

/// Pure per-model accumulator — no actor, no I/O, so the accounting is pinnable without
/// Metal or a loaded model (the same shape as ``PrefixReuseLedger``, for the same reason).
struct ReuseRefusalLedger: Sendable {
    private(set) var entries: [String: ModelReuseRefusals] = [:]

    mutating func record(modelId: String, reason: ReuseRefusalReason) {
        var entry = entries[modelId] ?? ModelReuseRefusals()
        entry.byReason[reason, default: 0] += 1
        entries[modelId] = entry
    }

    mutating func recordOpportunity(modelId: String, overlap: PrefixOverlap) {
        var entry = entries[modelId] ?? ModelReuseRefusals()
        entry.crossConversationTurns += 1
        if overlap.messagesInCommon > entry.bestMessagesInCommon {
            entry.bestMessagesInCommon = overlap.messagesInCommon
            entry.bestFeedMessages = overlap.feedMessages
        }
        entries[modelId] = entry
    }

    func observation(modelId: String) -> ReuseRefusalObservation {
        entries[modelId]?.observation ?? .empty
    }

    /// Drop a model's history: after an unload the counts describe a cache topology that no
    /// longer exists, and a published number that outlives the sessions that earned it is a
    /// claim, not a measurement.
    mutating func forget(modelId: String) {
        entries[modelId] = nil
    }
}
