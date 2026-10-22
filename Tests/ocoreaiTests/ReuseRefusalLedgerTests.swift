// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ReuseRefusalLedgerTests.swift — the refusal vocabulary, and the accounting built on it.
///
/// Why this has a gate at all: the ledger exists to price two owner decisions (refresh vs
/// refuse for a changed instruction set; cross-conversation prefix reuse) that were argued
/// from mechanism alone. A number nobody can regress is worse than no number, so every rule
/// here — which name a refusal gets, that the name agrees with the rule that refused it, and
/// what the wire says — is pinned in this file.
///
/// Nothing here needs Metal, a loaded model, or a live server: the ledger and both pure
/// classifiers are values, which is why these run on the CLT route.

import Foundation
import Testing

@testable import ocoreai

// MARK: - Reason

@Suite("ReuseRefusalReason — one name per refusal")
struct ReuseRefusalReasonTests {

    /// The classifier and the rule must never disagree: if `decide` names a reason while
    /// `canReusePooledSession` says reusable, the wire would report a refusal for a turn that
    /// got a warm session (and the reverse would hide a real one). Traversed exhaustively over
    /// the rule's whole input space, with the scan's own size asserted so a shrunk loop cannot
    /// pass vacuously.
    @Test("decide agrees with canReusePooledSession on every shape, in precedence order")
    func classifierAgreesWithReuseRule() {
        var checked = 0
        var refusals = 0
        var hits = 0
        for cached in 0 ... 3 {
            for common in 0 ... 3 {
                for incoming in 0 ... 4 {
                    for instructionsMatch in [true, false] {
                        for newestFromAssistant in [true, false] {
                            let reason = ReuseRefusalReason.decide(
                                instructionsMatch: instructionsMatch,
                                cachedMessageCount: cached,
                                commonPrefixCount: common,
                                incomingMessageCount: incoming,
                                newestIncomingFromAssistant: newestFromAssistant)
                            let allowed = MLXSessionPool.canReusePooledSession(
                                cachedMessageCount: cached,
                                commonPrefixCount: common,
                                instructionsMatch: instructionsMatch,
                                incomingMessageCount: incoming,
                                newestIncomingFromAssistant: newestFromAssistant)
                            #expect(
                                (reason == nil) == allowed,
                                "cached=\(cached) common=\(common) incoming=\(incoming) instructionsMatch=\(instructionsMatch) newestFromAssistant=\(newestFromAssistant): reason=\(String(describing: reason)) but allowed=\(allowed)"
                            )
                            checked += 1
                            if reason == nil { hits += 1 } else { refusals += 1 }
                        }
                    }
                }
            }
        }
        #expect(checked == 320, "the traversal stopped covering the rule's input space")
        #expect(refusals > 0 && hits > 0, "a one-sided traversal proves nothing about agreement")
    }

    @Test("identity outranks divergence, matching the disk path")
    func identityOutranksDivergence() {
        // Both premises broken: the disk path reports .instructionsChanged ahead of
        // .notAPrefix (SessionPool.swift's reuseDecision), and the ledger must say the same.
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: false, cachedMessageCount: 4, commonPrefixCount: 1,
                incomingMessageCount: 2, newestIncomingFromAssistant: false)
                == .instructionsChanged)
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: true, cachedMessageCount: 4, commonPrefixCount: 1,
                incomingMessageCount: 2, newestIncomingFromAssistant: false)
                == .historyDiverged)
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: true, cachedMessageCount: 3, commonPrefixCount: 3,
                incomingMessageCount: 5, newestIncomingFromAssistant: false) == nil)

    }

    /// The shape that shipped a one-token answer as a success (measured 10-22, probe 30):
    /// ask the same prompt twice, and the ledger left behind by the first turn covers the
    /// second turn's whole feed. Reusing it feeds nothing → the session emits end-of-turn
    /// immediately and the client sees `200 + completion_tokens=1 + finish_reason=stop`.
    @Test("a cache that covers the whole feed is refused — a turn always brings new content")
    func wholeFeedCoverageRefused() {
        // cached [u1, a1], incoming [u1, a1] (a verbatim resend): common 2 == incoming 2.
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: true, cachedMessageCount: 2, commonPrefixCount: 2,
                incomingMessageCount: 2, newestIncomingFromAssistant: false)
                == .cacheCoversWholeFeed)
        // The anon-key shape from the live log: cached [u1], incoming [u1].
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 1, commonPrefixCount: 1, instructionsMatch: true,
                incomingMessageCount: 1, newestIncomingFromAssistant: false)
                == false)
        // A real continuation still reuses: the feed adds a message past the cache.
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: true, cachedMessageCount: 2, commonPrefixCount: 2,
                incomingMessageCount: 3, newestIncomingFromAssistant: false)
                == nil)
        // The other side of the same rule: a feed whose newest message is the assistant's is
        // a continuation request, and a cache holding exactly that transcript is its answer.
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: true, cachedMessageCount: 2, commonPrefixCount: 2,
                incomingMessageCount: 2, newestIncomingFromAssistant: true)
                == nil)
        // Divergence outranks coverage: the caller replaced a turn it never sent.
        #expect(
            ReuseRefusalReason.decide(
                instructionsMatch: true, cachedMessageCount: 4, commonPrefixCount: 2,
                incomingMessageCount: 2, newestIncomingFromAssistant: true)
                == .historyDiverged)
    }

    @Test("every SnapshotRefusal maps to a ledger reason, and together they are one vocabulary")
    func snapshotMappingIsTheSameVocabulary() {
        let refusals: [SnapshotRefusal] = [
            .unusableManifest,
            .modelMismatch(snapshot: "org/a", requested: "org/b"),
            .mediaTurn,
            .instructionsChanged,
            .notAPrefix(cached: 3, commonPrefix: 1),
            .cacheCoversWholeFeed(cached: 3),
            .rewindReserveChanged(snapshot: 0, requested: 1024),
        ]
        let mapped = refusals.map(\.ledgerReason)
        #expect(mapped.count == 7)
        #expect(
            Set(mapped) == Set(ReuseRefusalReason.allCases),
            "the disk path and the wire must name the same set of reasons, not two overlapping ones"
        )
    }
}

// MARK: - Ledger

@Suite("ReuseRefusalLedger — counting, publishing, forgetting")
struct ReuseRefusalLedgerTests {

    @Test("refusals count per reason and the total is their sum")
    func countingPerReason() {
        var ledger = ReuseRefusalLedger()
        ledger.record(modelId: "org/a", reason: .historyDiverged)
        ledger.record(modelId: "org/a", reason: .historyDiverged)
        ledger.record(modelId: "org/a", reason: .instructionsChanged)
        ledger.record(modelId: "org/b", reason: .mediaTurn)

        let a = ledger.observation(modelId: "org/a")
        #expect(a.total == 3)
        #expect(a.byReason["historyDiverged"] == 2)
        #expect(a.byReason["instructionsChanged"] == 1)
        #expect(a.byReason["mediaTurn"] == nil, "a reason that never fired must not appear")
        #expect(
            a.byReason.values.reduce(0, +) == a.total,
            "the split must always add up to the total it is a split of")
        #expect(ledger.observation(modelId: "org/b").total == 1)
    }

    @Test("an unobserved model reports an empty set, never a prediction")
    func unobservedIsEmpty() {
        let ledger = ReuseRefusalLedger()
        let observation = ledger.observation(modelId: "org/never-used")
        #expect(observation == ReuseRefusalObservation.empty)
        #expect(observation.total == 0)
        #expect(observation.byReason.isEmpty)
        #expect(observation.crossConversationTurns == 0)
        #expect(observation.bestMessagesInCommon == nil)
    }

    @Test("forget drops the tally with the sessions that earned it")
    func forgetResets() {
        var ledger = ReuseRefusalLedger()
        ledger.record(modelId: "org/a", reason: .unusableManifest)
        ledger.recordOpportunity(
            modelId: "org/a", overlap: PrefixOverlap(messagesInCommon: 2, feedMessages: 5))
        ledger.forget(modelId: "org/a")
        #expect(ledger.observation(modelId: "org/a") == ReuseRefusalObservation.empty)
        ledger.record(modelId: "org/b", reason: .modelMismatch)
        #expect(ledger.observation(modelId: "org/b").total == 1, "forget must not reach neighbours")
    }

    @Test("opportunities count per turn and keep the deepest overlap with its feed length")
    func opportunityKeepsTheDeepest() {
        var ledger = ReuseRefusalLedger()
        ledger.recordOpportunity(
            modelId: "org/a", overlap: PrefixOverlap(messagesInCommon: 4, feedMessages: 9))
        ledger.recordOpportunity(
            modelId: "org/a", overlap: PrefixOverlap(messagesInCommon: 1, feedMessages: 2))
        let observation = ledger.observation(modelId: "org/a")
        #expect(observation.crossConversationTurns == 2, "every opportunity turn counts")
        #expect(
            observation.bestMessagesInCommon == 4, "the deepest overlap is the one worth quoting")
        #expect(
            observation.bestFeedMessages == 9, "the denominator belongs with the deepest overlap")
    }
}

// MARK: - Cross-conversation prefix

@Suite("CrossConversationPrefix.best — only a resident prefix under the existing rules counts")
struct CrossConversationPrefixTests {

    private func key(_ hash: Int, media: Bool = false, tool: Bool = false) -> MessageHistoryKey {
        MessageHistoryKey(role: "user", contentHash: hash, hasMedia: media, hasToolTraffic: tool)
    }

    private func candidate(_ keys: [MessageHistoryKey], instructions: Int)
        -> CrossConversationPrefix.Candidate
    {
        CrossConversationPrefix.Candidate(messageHistory: keys, instructionsHash: instructions)
    }

    @Test("the deepest resident prefix wins, and the feed length travels with it")
    func deepestWins() {
        let feed = [key(1), key(2), key(3), key(4)]
        let overlap = CrossConversationPrefix.best(
            feed: feed,
            instructionsHash: 7,
            candidates: [
                candidate([key(1)], instructions: 7),
                candidate([key(1), key(2), key(3)], instructions: 7),
            ])
        #expect(overlap == PrefixOverlap(messagesInCommon: 3, feedMessages: 4))
    }

    @Test("a session built under different instructions is not an opportunity")
    func instructionsMustMatch() {
        // Same reasoning as canReusePooledSession's second premise: a pooled session renders
        // the instructions it was created with, so its prefix is another prompt's prefix.
        let overlap = CrossConversationPrefix.best(
            feed: [key(1), key(2)],
            instructionsHash: 7,
            candidates: [candidate([key(1), key(2)], instructions: 8)])
        #expect(overlap == nil)
    }

    @Test(
        "media or tool traffic inside the shared head disqualifies it; beyond the head it does not")
    func dirtyRegionDisqualifies() {
        // Both sides must agree on the media turn for it to sit *inside* the overlap:
        // MessageHistoryKey compares hasMedia, so a media turn on one side only is already a
        // divergence and would be refused before the region check ever ran.
        let media = CrossConversationPrefix.best(
            feed: [key(1), key(2, media: true)],
            instructionsHash: 7,
            candidates: [candidate([key(1), key(2, media: true)], instructions: 7)])
        #expect(media == nil, "a prefix whose pixels were attended differently is not bankable")

        let tool = CrossConversationPrefix.best(
            feed: [key(1, tool: true), key(2)],
            instructionsHash: 7,
            candidates: [candidate([key(1, tool: true), key(2)], instructions: 7)])
        #expect(tool == nil, "tool control text is not something to bank a prefix skip on")

        // The dirty turn must be *inside* the shared head to disqualify it: here both sides
        // diverge at the media turn, so the overlap stops before it and stays bankable.
        let beyond = CrossConversationPrefix.best(
            feed: [key(1), key(2), key(3, media: true)],
            instructionsHash: 7,
            candidates: [candidate([key(1), key(2)], instructions: 7)])
        #expect(beyond == PrefixOverlap(messagesInCommon: 2, feedMessages: 3))
    }

    @Test("no shared head, empty feed, or a neighbour model's session yields nothing")
    func nothingCountsAsNothing() {
        #expect(
            CrossConversationPrefix.best(
                feed: [key(9)], instructionsHash: 7,
                candidates: [candidate([key(1)], instructions: 7)]) == nil)
        #expect(
            CrossConversationPrefix.best(
                feed: [], instructionsHash: 7,
                candidates: [candidate([key(1)], instructions: 7)]) == nil,
            "an empty feed has no prefix to be resident anywhere")
        #expect(
            CrossConversationPrefix.best(feed: [key(1)], instructionsHash: 7, candidates: []) == nil
        )
    }
}

// MARK: - Wire shape

@Suite("ReuseRefusalObservation — the published shape")
struct ReuseRefusalObservationWireTests {

    @Test("the wire carries the total, the split, and the opportunity fields")
    func jsonShape() throws {
        var ledger = ReuseRefusalLedger()
        ledger.record(modelId: "org/a", reason: .instructionsChanged)
        ledger.recordOpportunity(
            modelId: "org/a", overlap: PrefixOverlap(messagesInCommon: 2, feedMessages: 6))
        let data = try JSONEncoder().encode(ledger.observation(modelId: "org/a"))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["total"] as? Int == 1)
        #expect((object["byReason"] as? [String: Int])?["instructionsChanged"] == 1)
        #expect(object["crossConversationTurns"] as? Int == 1)
        #expect(object["bestMessagesInCommon"] as? Int == 2)
        #expect(object["bestFeedMessages"] as? Int == 6)
    }

    @Test("an empty observation encodes nulls, not zeroes, where nothing was observed")
    func jsonOmitsUnobservedNumbers() throws {
        let data = try JSONEncoder().encode(ReuseRefusalObservation.empty)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Swift's encoder omits an absent Optional rather than writing null, so "we have not
        // seen one" reaches the client as a missing key — which is what keeps it from being
        // misread as a measured zero. Assert the convention, because a client that defaults a
        // missing key to 0 gets the wrong answer either way.
        #expect(object["bestMessagesInCommon"] == nil, "unobserved must be absent, not zero")
        #expect(object["bestFeedMessages"] == nil)
        #expect((object["byReason"] as? [String: Int])?.isEmpty == true)
    }
}
