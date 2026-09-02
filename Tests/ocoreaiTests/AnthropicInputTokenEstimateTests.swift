// Copyright © 2026 uingeai.
// Licensed under MIT.
/// AnthropicInputTokenEstimateTests.swift — exact-value lock for the
/// `/v1/messages` input-token fallback heuristic.
///
/// Behavioral invariant: when the tokenizer registry is empty (always the
/// case on the MLX axis — `registerTokenizer` has no production caller),
/// `/v1/messages` must fall back to the CJK-aware byte estimate exactly like
/// Chat/Completions, NOT 500. The heuristic is the shared discipline:
/// bytes/3 when avg bytes/char > 1.5 (CJK-heavy), else bytes/4 (Latin),
/// clamped to ≥ 1; an empty transcript returns 0 (caller 400s).
///
/// `estimatePromptTokensFallback` is a private pure function — testable via
/// @testable without a loaded model or GPU.

import Testing

@testable import ocoreai

@Suite("Anthropic input token fallback heuristic")
struct AnthropicInputTokenEstimateTests {

    @Test("Latin 2 chars → 1 token (avg 1.0 B/char → bytes/4 → floor clamp)")
    func latinFloorClamp() {
        let messages = [Message(role: "user", content: .text("hi"))]
        // 2 bytes / 2 chars → avg 1.0 → /4 → Int(0.5)=0 → max(1,0)=1
        #expect(estimatePromptTokensFallback(messages) == 1)
    }

    @Test("CJK 2 chars → 2 tokens (6 bytes, avg 3.0 → bytes/3 → 6/3)")
    func cjkDivisor() {
        let messages = [Message(role: "user", content: .text("你好"))]
        // 6 bytes / 2 chars → avg 3.0 → /3 → Int(2.0)=2 → max(1,2)=2
        #expect(estimatePromptTokensFallback(messages) == 2)
    }

    @Test("Empty transcript → 0 (caller surfaces 400 invalid-request)")
    func emptyReturnsZero() {
        let messages = [Message(role: "user", content: nil)]
        #expect(estimatePromptTokensFallback(messages) == 0)
    }

    @Test("Mixed transcript → global average picks CJK divisor")
    func mixedGlobalAverage() {
        let messages = [
            Message(role: "system", content: .text("hi")),  // 2 B / 2 C
            Message(role: "user", content: .text("你好")),  // 6 B / 2 C
        ]
        // total 8 B / 4 C → avg 2.0 > 1.5 → /3 → Int(8/3)=2 → max(1,2)=2
        #expect(estimatePromptTokensFallback(messages) == 2)
    }
}
