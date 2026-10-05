// Exact-value contract for the shared wire-content fallback (ChatHandler
// .contentWireFallback). Both wire projections (non-stream CompletionChoice
// and stream-end SSE settle) must reduce to this single decision, so the
// matrix is covered once and both surfaces are pinned to it.
//
// Verified context (daemon, Qwen3.5-4B over the FM/SDK
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

    // MARK: - grammar tool-scaffold leak (live-evidence 10-05, gemma-4-e2b)

    // Guided gen on the tools path constrains pass-1 to the tool-call array;
    // with no calls it emits the structural scaffold `[]` / `[\n\n]` (fast-
    // forward tokens), which streams into the content channel BEFORE pass-2
    // prose. removeToolCallArrays deliberately passes empty arrays through
    // (byte-faithful for prose `arr = []`), so the scaffold must be removed
    // here, scoped to the tools path only.

    @Test("tools path: leading newline scaffold stripped from content")
    func toolsPathStripsLeadingScaffold() {
        #expect(
            contentWireFallback(
                text: "[\n\n]本地优先软件是指那些将主要功能在本地完成的软件。",
                reasoning: "",
                toolCallsPresent: false,
                toolsPath: true
            ) == "本地优先软件是指那些将主要功能在本地完成的软件。"
        )
    }

    @Test("tools path: tight leading scaffold stripped")
    func toolsPathStripsTightScaffold() {
        #expect(
            contentWireFallback(
                text: "[]The answer is 391.",
                reasoning: "",
                toolCallsPresent: false,
                toolsPath: true
            ) == "The answer is 391."
        )
    }

    @Test("tools path: scaffold-only content → empty (fallback to reasoning)")
    func toolsPathScaffoldOnlyFallsBack() {
        #expect(
            contentWireFallback(
                text: "[\n]",
                reasoning: "reasoned answer",
                toolCallsPresent: false,
                toolsPath: true
            ) == "reasoned answer"
        )
    }

    @Test("tools path: mid-prose empty array survives byte-exact")
    func toolsPathKeepsMidProseEmptyArray() {
        #expect(
            contentWireFallback(
                text: "初始化 arr = [] 即可。",
                reasoning: "",
                toolCallsPresent: false,
                toolsPath: true
            ) == "初始化 arr = [] 即可。"
        )
    }

    @Test("non-tools path: leading empty array untouched")
    func nonToolsPathLeavesEmptyArray() {
        #expect(
            contentWireFallback(
                text: "[] 在 Swift 里是空数组字面量。",
                reasoning: "",
                toolCallsPresent: false,
                toolsPath: false
            ) == "[] 在 Swift 里是空数组字面量。"
        )
    }

    @Test("tools path: scaffold with no following prose → empty content")
    func toolsPathScaffoldOnlyNoReasoningIsEmpty() {
        #expect(
            contentWireFallback(
                text: "[\n\n]",
                reasoning: "",
                toolCallsPresent: false,
                toolsPath: true
            ) == ""
        )
    }
}
