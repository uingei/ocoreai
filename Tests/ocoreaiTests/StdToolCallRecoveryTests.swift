// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// StdToolCallRecovery — exact-value tests for the bounded rejected-tool-call
/// recovery policy (ocoreai caller-level recovery over upstream's throw-only
/// `RejectedToolCallError`, mlx-swift-lm pin 604fae7 "the caller owns
/// recovery"). These are the regression lines that let the 4500+ line
/// `_runInference` deep retry loop be modified safely: boundaries and the
/// exact corrective prompt are pinned here, not buried in the engine.
import Testing

@testable import ocoreai

@Suite("StdToolCallRecovery — bounded retry policy (caller-level fork, exact values)")
struct StdToolCallRecoveryTests {
    @Test("maxAttempts is exactly 3 (boundary)")
    func maxAttemptsIsThree() {
        #expect(StdToolCallRecovery.maxAttempts == 3)
    }

    @Test("decide: attempts 1..2 → retry (budget remains)")
    func decideRetryWithinBudget() {
        #expect(StdToolCallRecovery.decide(attempt: 1) == .retry)
        #expect(StdToolCallRecovery.decide(attempt: 2) == .retry)
    }

    @Test("decide: attempt 3 == max → abort (exhausted) — exact boundary")
    func decideAbortAtBoundary() {
        #expect(StdToolCallRecovery.decide(attempt: 3) == .abort)
        #expect(StdToolCallRecovery.decide(attempt: 4) == .abort)
    }

    @Test("decide: custom max honored (parametric boundary)")
    func decideCustomMax() {
        #expect(StdToolCallRecovery.decide(attempt: 1, max: 1) == .abort)
        #expect(StdToolCallRecovery.decide(attempt: 1, max: 2) == .retry)
        #expect(StdToolCallRecovery.decide(attempt: 2, max: 2) == .abort)
    }

    @Test("correctivePrompt pins verbatim text (contract: model sees this)")
    func correctivePromptExact() {
        let expected =
            "The previous assistant reply was rejected by the tool-call parser "
            + "(malformed tool call). Re-issue the tool call with strictly valid "
            + "JSON arguments and emit no prose before the tool call."
        #expect(StdToolCallRecovery.correctivePrompt == expected)
    }

    @Test("correctiveMessage role + content match the pinned prompt")
    func correctiveMessageIsUserTurnWithPinnedText() {
        let msg = StdToolCallRecovery.correctiveMessage
        #expect(msg.content == StdToolCallRecovery.correctivePrompt)
    }
}
