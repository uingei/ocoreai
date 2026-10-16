/// PrefixReuseLedgerTests.swift — pin the prefix-reuse state machine and its wire shape.
///
/// Why a gate here: `GET /v1/models/:model/kv-cache` now publishes `prefixReuse`, a
/// capability statement a client can read. AGENTS.md invariant 2 says such a statement must
/// be measured and must degrade honestly when nothing has been measured. Both halves need a
/// gate: that reuse is reported only when upstream reported cached tokens, and that an
/// unobserved model says `not_observed` rather than `supported`.

import Foundation
import Testing

@testable import ocoreai

@Suite("PrefixReuseLedger — measured, never inferred")
struct PrefixReuseLedgerTests {

    @Test(
        "status is decided by the counters, exactly",
        arguments: [
            (warm: 0, reused: 0, expected: "not_observed"),
            (warm: 1, reused: 0, expected: "no_reuse_observed"),
            (warm: 7, reused: 0, expected: "no_reuse_observed"),
            (warm: 1, reused: 1, expected: "reuse_observed"),
            (warm: 7, reused: 3, expected: "reuse_observed"),
        ])
    func statusTable(warm: Int, reused: Int, expected: String) {
        #expect(PrefixReuseObservation.status(warmTurns: warm, turnsWithReuse: reused) == expected)
    }

    @Test("a cold turn is not evidence about reuse")
    func coldTurnsStayUnobserved() {
        var ledger = PrefixReuseLedger()
        for _ in 0 ..< 3 {
            ledger.record(modelId: "m", warm: false, prefilled: 708, cached: 0, promptSeconds: 0.15)
        }
        #expect(ledger.observation(modelId: "m") == PrefixReuseObservation.notObserved)
    }

    @Test("first warm turn with zero cached tokens reports no reuse, with exact counters")
    func firstWarmTurnNoReuse() {
        var ledger = PrefixReuseLedger()
        ledger.record(modelId: "m", warm: true, prefilled: 730, cached: 0, promptSeconds: 0.1273)
        let observed = ledger.observation(modelId: "m")
        #expect(observed.status == "no_reuse_observed")
        #expect(observed.warmTurns == 1)
        #expect(observed.turnsWithReuse == 0)
        #expect(observed.lastPrefilled == 730)
        #expect(observed.lastCached == 0)
        #expect(observed.lastPromptMs == 127)
    }

    @Test("reuse becomes observable the moment upstream reports cached tokens")
    func reuseObservedExactlyOnce() {
        var ledger = PrefixReuseLedger()
        ledger.record(modelId: "m", warm: true, prefilled: 730, cached: 0, promptSeconds: 0.127)
        ledger.record(modelId: "m", warm: true, prefilled: 749, cached: 710, promptSeconds: 0.031)
        let observed = ledger.observation(modelId: "m")
        #expect(observed.status == "reuse_observed")
        #expect(observed.warmTurns == 2)
        #expect(observed.turnsWithReuse == 1)
        #expect(observed.lastPrefilled == 749)
        #expect(observed.lastCached == 710)
        #expect(observed.lastPromptMs == 31)
    }

    @Test("models never contaminate each other")
    func perModelIsolation() {
        var ledger = PrefixReuseLedger()
        ledger.record(modelId: "chat", warm: true, prefilled: 100, cached: 80, promptSeconds: 0.01)
        ledger.record(modelId: "other", warm: true, prefilled: 100, cached: 0, promptSeconds: 0.01)
        #expect(ledger.observation(modelId: "chat").status == "reuse_observed")
        #expect(ledger.observation(modelId: "other").status == "no_reuse_observed")
        #expect(ledger.observation(modelId: "never-used") == PrefixReuseObservation.notObserved)
    }

    @Test("forgetting a model removes claims made under its old cache topology")
    func forgetResetsToUnobserved() {
        var ledger = PrefixReuseLedger()
        ledger.record(modelId: "m", warm: true, prefilled: 100, cached: 40, promptSeconds: 0.02)
        #expect(ledger.observation(modelId: "m").status == "reuse_observed")
        ledger.forget(modelId: "m")
        #expect(ledger.observation(modelId: "m") == PrefixReuseObservation.notObserved)
    }

    @Test("the wire never claims capability for an unobserved model")
    func unobservedWireShape() throws {
        let data = try JSONEncoder().encode(PrefixReuseObservation.notObserved)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"status\":\"not_observed\""))
        #expect(json.contains("\"warmTurns\":0"))
        #expect(json.contains("\"turnsWithReuse\":0"))
        // Optional numbers are OMITTED when nothing was measured (the repo's own rule for
        // ModelObject: absent means unknown, never 0 and never a guess).
        #expect(!json.contains("lastPrefilled"))
        #expect(!json.contains("lastCached"))
        #expect(!json.contains("lastPromptMs"))
        #expect(!json.contains("supported"))
        #expect(!json.contains("reuse_observed"))
    }

    @Test("a model cannot be reported as reusing while its counters say otherwise")
    func statusCannotOutrunCounters() {
        // The only way `status` is produced is from the counters, so a wire line that
        // says reuse happened must show at least one warm turn with cached tokens.
        var ledger = PrefixReuseLedger()
        ledger.record(modelId: "m", warm: true, prefilled: 500, cached: 0, promptSeconds: 0.09)
        let observed = ledger.observation(modelId: "m")
        #expect(observed.status != "reuse_observed")
        #expect(observed.turnsWithReuse == 0)
        #expect(observed.warmTurns >= 1)
    }

    // MARK: - Per-turn statement (PrefixReuseStatement)

    @Test(
        "a turn speaks only when the pool withheld something",
        arguments: [
            (withheld: 0, cached: 0, speaks: false),
            // Cold turn where upstream still reused (e.g. a cache restored from disk):
            // nothing was withheld, so there is no warm-turn promise to account for.
            (withheld: 0, cached: 400, speaks: false),
            (withheld: 1, cached: 0, speaks: true),
            (withheld: 4, cached: 710, speaks: true),
        ])
    func speaksExactlyOnWarmTurns(withheld: Int, cached: Int, speaks: Bool) {
        let statement = PrefixReuseStatement.decide(
            convKey: "conv-1", withheld: withheld, prefilled: 20, cached: cached, promptMs: 987)
        switch statement {
        case .nothing:
            #expect(!speaks, "withheld=\(withheld) cached=\(cached) must stay silent")
        case .reused, .noReuse:
            #expect(speaks, "withheld=\(withheld) cached=\(cached) must write a line")
        }
    }

    @Test("the no-reuse line says exactly what it did, in the form probe 01 parses")
    func noReuseLineExactWording() {
        let statement = PrefixReuseStatement.decide(
            convKey: "m:PROBE-PREFIX-1", withheld: 2, prefilled: 730, cached: 0, promptMs: 107)
        guard case .noReuse(let message) = statement else {
            Issue.record("expected .noReuse, got \(statement)")
            return
        }
        #expect(
            message
                == "Prefix cache reused no tokens for m:PROBE-PREFIX-1: withheld 2 message(s) "
                + "from the feed, upstream prefilled all 730 prompt tokens (cached=0, promptTime=107ms)"
        )
        // scripts/probes/01-prefix-accounting.sh counts these lines with this regex.
        #expect(
            message.range(
                of: #"prefilled all (\d+) prompt tokens \(cached=0, promptTime=(\d+)ms\)"#,
                options: .regularExpression) != nil)
    }

    @Test("the reuse line names the saving and the total, in the form probe 01 parses")
    func reuseLineExactWording() {
        let statement = PrefixReuseStatement.decide(
            convKey: "m:PROBE-PREFIX-1", withheld: 2, prefilled: 20, cached: 710, promptMs: 987)
        guard case .reused(let message) = statement else {
            Issue.record("expected .reused, got \(statement)")
            return
        }
        // The total is what the turn's prompt actually was — paid plus reused, never the
        // paid count alone, or a reader would divide the saving by the wrong denominator.
        #expect(
            message
                == "Prefix cache reused 710 of 730 prompt tokens for m:PROBE-PREFIX-1: "
                + "withheld 2 message(s) from the feed, upstream prefilled 20 "
                + "(cached=710, promptTime=987ms)"
        )
        #expect(
            message.range(
                of: #"Prefix cache reused (\d+) of (\d+) prompt tokens for "#,
                options: .regularExpression) != nil)
    }
}
