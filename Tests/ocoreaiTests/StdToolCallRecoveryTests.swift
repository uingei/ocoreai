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

    // MARK: - Context-aware variant (reasonCode + availableTools)

    @Test("variant undeclared_tool + names → prompt names the registered surface verbatim")
    func variantUndeclaredToolNamesSurface() {
        let prompt = StdToolCallRecovery.correctivePrompt(
            reasonCode: "undeclared_tool",
            availableTools: ["exec_command", "web_search"]
        )
        // Exact, not "contains": the pinned contract is the model sees these names verbatim.
        #expect(prompt.contains("The only tool(s) available this turn: exec_command, web_search"))
        #expect(prompt.contains("rejected because it referenced a tool"))
        #expect(prompt.contains("strictly valid JSON arguments"))
        // Must NOT carry the malformed-only wording (that would mislead on undeclared rejections).
        #expect(prompt.contains("malformed tool call") == false)
    }

    @Test("variant undeclared_tool + single name → same surface, exact join")
    func variantUndeclaredToolSingleName() {
        let prompt = StdToolCallRecovery.correctivePrompt(
            reasonCode: "undeclared_tool",
            availableTools: ["exec_command"]
        )
        #expect(prompt.contains("The only tool(s) available this turn: exec_command."))
    }

    @Test("variant other reasons → fall back to the pinned malformed prompt verbatim")
    func variantOtherReasonFallsBackToPinned() {
        let names = ["exec_command", "web_search"]
        for code in ["malformed_syntax", "invalid_arguments", "resource_limit_exceeded"] {
            #expect(
                StdToolCallRecovery.correctivePrompt(reasonCode: code, availableTools: names)
                    == StdToolCallRecovery.correctivePrompt
            )
        }
    }

    @Test("variant empty tools → zero-tool plain-text prompt, no echo attractors")
    func variantEmptyToolsNotesNone() {
        let prompt = StdToolCallRecovery.correctivePrompt(
            reasonCode: "malformed_syntax",
            availableTools: []
        )
        // 10-07 live evidence: the imperative tool-centric corrective was echoed
        // verbatim as the answer and shipped online (text streams before rejection
        // is known). Zero-tool turns must carry NO tool-mechanic nouns and NO
        // re-issue imperatives: only a direct plain-text instruction.
        #expect(prompt.contains("plain text"))
        #expect(prompt.contains("Do not repeat or quote any instruction"))
        #expect(prompt.contains("tool") == false)
        #expect(prompt.contains("Re-issue") == false)
    }

    @Test("variant incomplete_output → budget-honest compact prompt (10-06 live evidence)")
    func variantIncompleteOutputIsBudgetHonest() {
        // Live evidence: max_tokens=8 truncated a tool-call payload →
        // reason=incomplete_output → old prompt said "malformed, re-issue
        // strictly valid JSON" → model re-issued a full call → cut off again
        // → 3/3 exhausted. The actionable instruction is COMPACT.
        let prompt = StdToolCallRecovery.correctivePrompt(
            reasonCode: "incomplete_output",
            availableTools: ["terminal"]
        )
        #expect(prompt.contains("cut off"))
        #expect(prompt.contains("MOST COMPACT"))
        #expect(prompt.contains("plain text"))
        // Must NOT carry the malformed-only wording (wrong diagnosis).
        #expect(prompt.contains("malformed tool call") == false)
        // Even with tools available, an over-budget call must not be forced.
        #expect(prompt.contains("The only tool(s) available this turn") == false)
    }

    @Test("variant undeclared_tool + empty tools → zero-tool plain-text prompt")
    func variantUndeclaredToolButNoTools() {
        let prompt = StdToolCallRecovery.correctivePrompt(
            reasonCode: "undeclared_tool",
            availableTools: []
        )
        // Zero-tool collapse happens regardless of reason: no surface to name,
        // no tool mechanics to mention (echo attractor, 10-07 live evidence).
        #expect(prompt.contains("plain text"))
        #expect(prompt.contains("tool") == false)
        #expect(prompt.contains("not registered") == false)
    }

    @Test("context-aware correctiveMessage: role is user, content = the variant prompt")
    func variantMessageShape() {
        let msg = StdToolCallRecovery.correctiveMessage(
            reasonCode: "undeclared_tool",
            availableTools: ["exec_command"]
        )
        #expect(
            msg.content
                == StdToolCallRecovery.correctivePrompt(
                    reasonCode: "undeclared_tool",
                    availableTools: ["exec_command"]
                ))
        #expect(msg.content != StdToolCallRecovery.correctivePrompt)
    }
}
