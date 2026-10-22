// Gates `MLXSessionPool.rewindHistoryEnd` — the rule that decides whether a diverged
// conversation's resident KV cache may be rewound onto the conversation that arrived
// (via upstream `ChatSession.fork(history:)`, ChatSession.swift:1652) instead of being
// discarded and re-prefilled.
//
// Why this needs a gate of its own: `canReusePooledSession` answers "may this turn be
// answered from the cache as it stands?" and must keep answering no for a diverged
// conversation (SessionIsolationTests.forkRefused pins that). This rule answers a
// different question — "may the cache be rewound first?" — and the two must never
// contradict: an offer made where the session is also reusable-as-is would credit a cache
// with turns it never held. Live proof that the rewind actually happens and actually
// reuses lives in probe 27; this file pins the decision table so a loosened guard fails
// here, in a second, rather than shipping a leak-shaped shortcut.

import Foundation
import Testing

@testable import ocoreai

@Suite("rewindHistoryEnd — offered only where reuse was refused, and never on a fork")
struct SessionRewindOnDivergenceTests {

    private func end(
        cached: Int,
        common: Int,
        incoming: Int?,
        instructionsMatch: Bool = true,
        carriesMedia: Bool = false,
        laneCanSpend: Bool = true
    ) -> Int? {
        MLXSessionPool.rewindHistoryEnd(
            cachedMessageCount: cached,
            commonPrefixCount: common,
            incomingMessageCount: incoming,
            instructionsMatch: instructionsMatch,
            carriesMedia: carriesMedia,
            laneCanSpend: laneCanSpend)
    }

    /// The safety invariant the whole change rests on: a rewind is offered only for a
    /// conversation the pool refused. If this ever fires, the two rules disagree and a
    /// session could be credited with context it never rendered.
    @Test("never contradicts canReusePooledSession, over the whole input space")
    func offerOnlyWhenRefused() {
        var checked = 0
        var offered = 0
        var refused = 0
        for cached in 0 ... 3 {
            for common in 0 ... 3 {
                for incoming in [nil, 0, 1, 2, 3, 4] {
                    for instructionsMatch in [true, false] {
                        for carriesMedia in [true, false] {
                            for laneCanSpend in [true, false] {
                                let rewind = end(
                                    cached: cached, common: common, incoming: incoming,
                                    instructionsMatch: instructionsMatch,
                                    carriesMedia: carriesMedia,
                                    laneCanSpend: laneCanSpend)
                                let reusable = MLXSessionPool.canReusePooledSession(
                                    cachedMessageCount: cached,
                                    commonPrefixCount: common,
                                    instructionsMatch: instructionsMatch,
                                    incomingMessageCount: incoming ?? .max,
                                    newestIncomingFromAssistant: false)
                                #expect(
                                    rewind == nil || !reusable,
                                    "cached=\(cached) common=\(common) incoming=\(String(describing: incoming)): rewind=\(String(describing: rewind)) while canReuse=\(reusable)"
                                )
                                if rewind != nil { offered += 1 }
                                if !reusable { refused += 1 }
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        // Self-asserting scan: a shrunk loop or a rule that stopped matching cannot pass.
        #expect(checked == 768, "the traversal stopped covering the rule's input space")
        #expect(offered > 0, "nothing is ever offered — the rule would be vacuously safe")
        #expect(refused > 0, "no refusal in the space — the pair was never compared")
    }

    @Test("an edited resend is offered at the common prefix")
    func editedResendOfferedAtCommonPrefix() {
        // cached [u1, a1, u2, a2] vs incoming [u1, a1, u2', q] — the probe-27 shape.
        #expect(end(cached: 4, common: 2, incoming: 4) == 2)
        // The turn that only adds a message needs no rewind: it is a plain hit.
        #expect(end(cached: 4, common: 4, incoming: 5) == nil)
    }

    /// The 10-12 cross-talk shape, kept out of the rewind on purpose: the caller re-sent
    /// an already-answered turn and has nothing past the shared prefix, so a fork would
    /// leave this turn no new message and the caller no answer. It keeps the
    /// discard-and-rebuild path, which is what re-answers it today.
    @Test("nothing new past the prefix ⇒ no offer")
    func nothingNewToFeed() {
        #expect(end(cached: 2, common: 1, incoming: 1) == nil)
        #expect(end(cached: 4, common: 2, incoming: 2) == nil)
        // No message list at all (a caller that only asked for a session): unrepairable.
        #expect(end(cached: 4, common: 2, incoming: nil) == nil)
    }

    @Test("identity and media outrank the rewind")
    func premisesGateTheOffer() {
        // The session renders the instructions it was created with.
        #expect(end(cached: 4, common: 2, incoming: 4, instructionsMatch: false) == nil)
        // Placeholder tokens are the same for different pixels, so the shared prefix is
        // not provable and upstream would start cold while the log claimed a rewind.
        #expect(end(cached: 4, common: 2, incoming: 4, carriesMedia: true) == nil)
        // A cache with nothing in it has nothing to rewind.
        #expect(end(cached: 0, common: 0, incoming: 3) == nil)
    }

    /// The probe-27 §5 shape: the conversation diverges and a rewind would be sound, but
    /// this turn generates through GuidedGenerationLoop, which builds its own KV cache and
    /// releases the pooled slot before generating. Offering here would skip the
    /// `reuseRefusals` booking for a refusal the turn did pay, and log a reuse the turn
    /// never spent — measured 10-22: "Session REWOUND … instead of re-prefilling 2", then
    /// `prompt_tokens=753 cached_tokens=0`.
    @Test("a lane that cannot spend the cache gets no offer")
    func bypassingLaneGetsNoOffer() {
        #expect(end(cached: 5, common: 2, incoming: 5, laneCanSpend: false) == nil)
        // The same divergence on the standard lane is offered at the shared prefix.
        #expect(end(cached: 5, common: 2, incoming: 5) == 2)
    }

    /// `EnginePool.bypassesPooledChatSession` is the one statement of which lanes carry
    /// their own cache. Media outranks both (neither lane can carry it, so `ChatSession`
    /// answers), and a grammar pairing the model cannot honour falls through to the
    /// standard path rather than staying a bypass.
    @Test("bypassesPooledChatSession — guided gen and MTP bypass; media and unsafe grammar do not")
    func lanePredicate() {
        func bypasses(
            grammar: Bool = false, grammarSafe: Bool = false, mtp: Bool = false,
            media: Bool = false, messages: Int = 4
        ) -> Bool {
            EnginePool.bypassesPooledChatSession(
                grammarSchemaPresent: grammar,
                constrainedLaneIsSound: grammarSafe,
                mtpDrafterPresent: mtp,
                carriesMedia: media,
                messageCount: messages)
        }
        #expect(bypasses() == false)
        #expect(bypasses(grammar: true, grammarSafe: true) == true)
        #expect(bypasses(grammar: true, grammarSafe: false) == false)
        #expect(bypasses(mtp: true) == true)
        // MTP needs something to draft against.
        #expect(bypasses(mtp: true, messages: 0) == false)
        // Both lanes exclude media ⇒ the standard path owns this turn.
        #expect(bypasses(grammar: true, grammarSafe: true, mtp: true, media: true) == false)
    }

    /// Structure, pinned mechanically: one fork site, one decision home, one reserve
    /// constant, and the reserve actually requested at every exit of the resolver. Both
    /// scans prove they can match (positive control) before asserting a count, so a renamed
    /// API fails as "no fork anywhere" rather than as a clean pass.
    @Test("one fork site, one decision home, reserve requested at every resolver exit")
    func singleHomeForTheFork() throws {
        var url = URL(fileURLWithPath: #filePath)
        var root: URL?
        for _ in 0 ..< 8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                root = url
                break
            }
        }
        guard let root else { throw CocoaError(.fileReadNoSuchFile) }
        func read(_ relative: String) throws -> String {
            try String(
                contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        let poolSource = try read("Sources/ocoreai/Engine/SessionPool.swift")
        let inferenceSource = try read("Sources/ocoreai/Engine/EngineInference.swift")

        // Positive controls first: a scan that cannot match would pass vacuously, and both
        // counts below are equalities.
        #expect(
            poolSource.contains("canReusePooledSession"),
            "the scan lost the file it is supposed to read"
        )
        let forkCalls = inferenceSource.components(separatedBy: ".session.fork(").count - 1
        #expect(forkCalls == 1, "exactly one site may fork a pooled session; found \(forkCalls)")

        let decisionCalls = poolSource.components(separatedBy: "Self.rewindHistoryEnd(").count - 1
        #expect(
            decisionCalls == 1,
            "the rewind decision must have one call site; found \(decisionCalls)"
        )
        // The lane fact: computed once in the engine, declared once at the acquire call,
        // and consulted once by the pool. Three occurrences of one fact in three files is
        // how one of them drifts; these floors say the wiring exists, and the truth table
        // above says what it decides.
        let laneComputed =
            inferenceSource.components(separatedBy: "Self.bypassesPooledChatSession(")
            .count - 1
        #expect(
            laneComputed == 1,
            "the bypass decision must be computed at one home; found \(laneComputed)")
        let lanePassed =
            inferenceSource.components(
                separatedBy: "rewindUsable: !routesAroundChatSession"
            ).count - 1
        #expect(
            lanePassed == 1,
            "acquire must be told whether this turn can spend a rewind; found \(lanePassed)")
        let laneGated = poolSource.components(separatedBy: "laneCanSpend: rewindUsable").count - 1
        #expect(
            laneGated == 1,
            "the offer must be gated on the caller's lane; found \(laneGated)")

        // The reserve is what makes the fork pay, and it is pinned because its absence is
        // invisible to a correctness probe: with the fork applied but no reserve, upstream
        // silently downgrades the rewind to a rebuild — measured 10-21 on
        // gemma-4-e2b-it-4bit, the edited turn answered correctly and reused 0 tokens;
        // with the reserve the same turn reused 718 of 758. A knob that quietly stops
        // being requested costs latency and nothing goes red, so the request itself gets a
        // gate here. One home, three exits from the resolver (quantized, fallback-bits,
        // unquantized), and the size stated where a reader can find it.
        let bridgeSource = try read("Sources/ocoreai/Engine/MLXBridge.swift")
        let reserveSites =
            bridgeSource
            .components(separatedBy: "rewind: makeKVCacheRewind()").count - 1
        #expect(
            reserveSites == 3,
            "every exit of makeKVCacheConfiguration must carry the reserve; found \(reserveSites) of 3"
        )
        #expect(
            bridgeSource.contains("let kvCacheRewindReserveTokens = "),
            "the reserve size must be one named constant, not three literals"
        )
    }

}
