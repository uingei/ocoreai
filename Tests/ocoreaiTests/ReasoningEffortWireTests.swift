// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// reasoning_effort wire + engine-side injection contract (2026-08-23).
//
// Wire-not-brain: ocoreai decodes `reasoning_effort` verbatim and injects
// the raw value into the jinja chat-template context. The model template is
// the single validation authority (Qwen3.8: xhigh/medium/low,
// raise_exception otherwise). ocoreai makes NO local mapping, NO default,
// NO local enum — so these tests assert verbatim pass-through and merge
// semantics, never a canonicalized value.
//
// JSON payloads are built via `[String: Any]` + `JSONSerialization` (same
// discipline as ChatCompletionRequestWireCompletenessTests).

import Foundation
import Testing

@testable import ocoreai

// MARK: - Wire decode (ChatCompletionRequest)

private func decodeRequest(_ extra: [String: Any]) throws -> ChatCompletionRequest {
    var payload: [String: Any] = [
        "model": "m",
        "messages": [["role": "user", "content": "hi"]],
    ]
    for (k, v) in extra { payload[k] = v }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
}

struct ReasoningEffortWireTests {

    /// Every codex-aligned word + Qwen3.8's three accepted values decode
    /// VERBATIM (no local mapping may normalize or translate them — the
    /// model template is the validation authority).
    @Test
    func wireDecodesEffortVerbatim() throws {
        for value in ["xhigh", "medium", "low", "high", "max", "ultra"] {
            let req = try decodeRequest(["reasoning_effort": value])
            #expect(req.reasoningEffort == value, "value \(value) must be verbatim")
        }
    }

    /// Absent field → nil (the model template then applies its own default,
    /// e.g. xhigh for Qwen3.8 — ocoreai must not supply one).
    @Test
    func wireAbsentIsNil() throws {
        let req = try decodeRequest(["reasoning": true])
        #expect(req.reasoningEffort == nil)
    }

    /// Coexistence: reasoningLevel (Apple FM words) and reasoningEffort
    /// (codex words) are independent fields, both decoded.
    @Test
    func wireCoexistsWithReasoningLevel() throws {
        let req = try decodeRequest([
            "reasoning_level": "deep",
            "reasoning_effort": "medium",
        ])
        #expect(req.reasoningLevel == "deep")
        #expect(req.reasoningEffort == "medium")
    }
}

// MARK: - Engine-side context merge (ReasoningEffortWire)

struct ReasoningEffortContextTests {

    @Test
    func mergesIntoExistingThinkingContext() {
        let base: [String: any Sendable] = ["enable_thinking": true]
        let merged = ReasoningEffortWire.context(base, rawValue: "medium")
        #expect(merged != nil, "effort present ⇒ context present")
        #expect(merged?.count == 2)
        #expect(merged?["enable_thinking"] as? Bool == true)
        #expect(merged?["reasoning_effort"] as? String == "medium")
    }

    @Test
    func buildsContextFromNilBase() {
        let merged = ReasoningEffortWire.context(nil, rawValue: "low")
        #expect(merged?.count == 1)
        #expect(merged?["reasoning_effort"] as? String == "low")
    }

    /// nil / empty / whitespace raw + nil base → stays nil (no behavior
    /// change for thinking-off / no-effort traffic — nothing injected,
    /// no empty-dict placeholder).
    @Test
    func nilOrEmptyRawWithNilBaseStaysNil() {
        #expect(ReasoningEffortWire.context(nil, rawValue: nil) == nil)
        #expect(ReasoningEffortWire.context(nil, rawValue: "") == nil)
        #expect(ReasoningEffortWire.context(nil, rawValue: "   \t ") == nil)
    }

    /// nil / empty raw + non-nil base → base passes through unchanged,
    /// key NOT injected.
    @Test
    func preservesBaseWhenRawAbsent() {
        let base: [String: any Sendable] = ["enable_thinking": false]
        let merged = ReasoningEffortWire.context(base, rawValue: nil)
        #expect(merged?.count == 1)
        #expect(merged?["enable_thinking"] as? Bool == false)
        // key must NOT be injected when the value is absent
        #expect(merged?["reasoning_effort"] == nil)

        let mergedEmpty = ReasoningEffortWire.context(base, rawValue: "   ")
        #expect(mergedEmpty?.count == 1)
        #expect(mergedEmpty?["reasoning_effort"] == nil)
    }
}
