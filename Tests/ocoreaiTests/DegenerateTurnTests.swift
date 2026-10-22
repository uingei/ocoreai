import Testing

@testable import ocoreai

/// Pins ``DegenerateTurn.isSuspected`` — the predicate that stops a one-token turn from
/// leaving the process as a silent success.
///
/// The shapes come from live measurement, not invention: 16 sequential turns of one prompt
/// at `max_tokens=200` on `gemma-4-e2b-it-4bit` split bimodally into `tokens=200 /
/// reason=maxTokens` (whole turn 4.7–7.5 s) and `tokens=1 / reason=eos` (whole turn
/// 0.12–0.22 s) (CHANGELOG 10-22(8)). The latency that separated them is whole-turn, not
/// time-to-first-token — see `DegenerateTurn` — and the predicate never read a latency anyway:
/// it keys on token count, reason and budget. If it ever widens or narrows, these cases go red
/// rather than the behaviour drifting behind a doc that describes the old shape.
struct DegenerateTurnTests {

    // MARK: - The two shapes actually measured on a live server

    @Test func measuredCollapseIsFlagged() {
        #expect(
            DegenerateTurn.isSuspected(tokenCount: 1, stopReason: .eos, requestedMaxTokens: 200))
    }

    @Test func measuredHealthyTurnIsNotFlagged() {
        #expect(
            !DegenerateTurn.isSuspected(
                tokenCount: 200, stopReason: .maxTokens, requestedMaxTokens: 200)
        )
    }

    // MARK: - Boundary of "essentially nothing"

    @Test func tokenCeilingIsOne() {
        #expect(DegenerateTurn.tokenCeiling == 1)
    }

    @Test func zeroAndOneTokenEosTurnsAreFlagged() {
        #expect(
            DegenerateTurn.isSuspected(tokenCount: 0, stopReason: .eos, requestedMaxTokens: 200))
        #expect(
            DegenerateTurn.isSuspected(tokenCount: 1, stopReason: .eos, requestedMaxTokens: 200))
    }

    @Test func twoTokenEosTurnIsNotFlagged() {
        #expect(
            !DegenerateTurn.isSuspected(tokenCount: 2, stopReason: .eos, requestedMaxTokens: 200))
    }

    // MARK: - Only end-of-turn qualifies; every other exit is already loud

    @Test func everyNonEosReasonIsExcluded() {
        let loud: [(StopReason, Bool)] = [
            (.maxTokens, false),
            (.stopSequence, false),
            (.cancelled, false),
            (.error, false),
        ]
        for (reason, expected) in loud {
            for tokens in [0, 1] {
                #expect(
                    DegenerateTurn.isSuspected(
                        tokenCount: tokens, stopReason: reason, requestedMaxTokens: 200)
                        == expected,
                    "tokens=\(tokens) reason=\(reason)"
                )
            }
        }
        // A missing reason is not evidence of end-of-turn.
        #expect(
            !DegenerateTurn.isSuspected(tokenCount: 1, stopReason: nil, requestedMaxTokens: 200))
    }

    // MARK: - A caller that asked for one token got what it asked for

    @Test func budgetOfOneIsNeverDegenerate() {
        #expect(
            !DegenerateTurn.isSuspected(tokenCount: 1, stopReason: .eos, requestedMaxTokens: 1))
        #expect(
            !DegenerateTurn.isSuspected(tokenCount: 0, stopReason: .eos, requestedMaxTokens: 1))
    }

    @Test func unsetBudgetCountsAsAskingForMore() {
        // Unset `max_tokens` resolves to the engine default (>1), so a 1-token `.eos`
        // answer under an unset budget is still the collapsed shape.
        #expect(
            DegenerateTurn.isSuspected(tokenCount: 1, stopReason: .eos, requestedMaxTokens: nil))
    }

    // MARK: - Traversal, with its own floor so a broken loop cannot pass vacuously

    @Test func fullTraversalMatchesExplicitVerdicts() throws {
        let reasons: [StopReason?] = [.eos, .maxTokens, .stopSequence, .cancelled, .error, nil]
        let budgets: [Int?] = [nil, 1, 2, 200]
        // Expected verdict per (tokens, reason, budget) as a literal product rule:
        // flag only `tokens <= 1` AND `.eos` AND a budget above one token.
        var checked = 0
        for tokens in 0 ... 3 {
            for reason in reasons {
                for budget in budgets {
                    let expected = tokens <= 1 && reason == .eos && (budget ?? Int.max) > 1
                    #expect(
                        DegenerateTurn.isSuspected(
                            tokenCount: tokens, stopReason: reason, requestedMaxTokens: budget)
                            == expected,
                        "tokens=\(tokens) reason=\(String(describing: reason)) budget=\(String(describing: budget))"
                    )
                    checked += 1
                }
            }
        }
        // 4 token counts x 6 reasons x 4 budgets. Without this floor a change to any loop
        // bound would silently shrink the scan and still report success.
        #expect(checked == 96)
        // And the scan must actually contain positive hits, or the rule matches nothing.
        var hits = 0
        for tokens in 0 ... 3 {
            for budget in budgets where tokens <= 1 && budget != 1 {
                hits += 1
            }
        }
        #expect(hits == 6)  // tokens {0,1} x budgets {nil, 2, 200}
    }
}
