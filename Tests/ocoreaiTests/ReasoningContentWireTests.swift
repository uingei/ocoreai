// Exact-value contract for the shared wire-content fallback (ChatHandler
// .contentWireFallback). Both wire projections (non-stream CompletionChoice
// and stream-end SSE settle) must reduce to this single decision, so the
// matrix is covered once and both surfaces are pinned to it.
//
// Live-verified context (2026-09-12, daemon, Qwen3.5-4B over the FM/SDK
// path, thinking on): the SDK classifies the entire generation into
// Transcript.Entry.reasoning — usage reasoning_tokens>0, zero text on the
// content channel — so consumers reading only `content` must still receive
// the answer via this fallback.

import Testing

@testable import ocoreai

struct ReasoningContentWireTests {

    @Test("text present → text wins verbatim (reasoning ignored)")
    func textPresentWins() {
        #expect(
            contentWireFallback(
                text: "The answer is 225 km.",
                reasoning: "thought process… 225 km.",
                toolCallsPresent: false
            ) == "The answer is 225 km."
        )
    }

    @Test("text empty + reasoning present → reasoning carries the answer")
    func textEmptyFallsBackToReasoning() {
        #expect(
            contentWireFallback(
                text: "",
                reasoning: "Speed is 1.5 km/min, so 225 km.",
                toolCallsPresent: false
            ) == "Speed is 1.5 km/min, so 225 km."
        )
    }

    @Test("text empty + reasoning empty → empty string (nothing invented)")
    func bothEmptyStaysEmpty() {
        #expect(
            contentWireFallback(
                text: "",
                reasoning: "",
                toolCallsPresent: false
            ) == ""
        )
    }

    @Test(
        "tool calls present → content always empty (structured channel authoritative)",
        arguments: [
            ("", "any reasoning"),
            ("text answer", ""),
            ("text answer", "reasoning too"),
        ]
    )
    func toolCallsForceEmpty(text: String, reasoning: String) {
        #expect(
            contentWireFallback(
                text: text,
                reasoning: reasoning,
                toolCallsPresent: true
            ) == ""
        )
    }

    @Test("whitespace-only text counts as empty → fallback triggers")
    func whitespaceTextTriggersFallback() {
        #expect(
            contentWireFallback(
                text: " \n\t",
                reasoning: "fallback answer text",
                toolCallsPresent: false
            ) == "fallback answer text"
        )
    }
}
