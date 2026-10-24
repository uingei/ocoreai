// AnthropicSSEWireShapeTests.swift — Anthropic SSE event sequence + wire shape.
// Live 10-13: the /v1/messages stream went `message_start → content_block_start →
// content_block_delta → content_block_stop → message_stop`, skipping `message_delta`
// — the only event that carries `stop_reason`, so clients finished with no reason.

import Foundation
import Testing

@testable import ocoreai

private func json(_ event: AnthropicStreamEvent) -> [String: Any] {
    let data = try! JSONEncoder().encode(event)
    return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private func delta(_ event: AnthropicStreamEvent) -> [String: Any] {
    json(event)["delta"] as? [String: Any] ?? [:]
}

@Suite("Anthropic SSE — message_delta carries stop_reason")
struct AnthropicSSEWireShapeTests {

    @Test("message_delta emits type, delta.stop_reason and output_tokens")
    func messageDeltaShape() {
        let e = json(AnthropicStreamEvent.messageDelta(stopReason: "end_turn", outputTokens: 7))
        #expect(e["type"] as? String == "message_delta")
        let d = delta(AnthropicStreamEvent.messageDelta(stopReason: "end_turn", outputTokens: 7))
        #expect(d["type"] as? String == "message_delta")
        #expect(d["stop_reason"] as? String == "end_turn")
        let u = e["usage"] as? [String: Any]
        #expect(u?["output_tokens"] as? Int == 7)
        #expect(
            u?.keys.contains("input_tokens") == false, "message_delta carries output_tokens only")
    }

    /// The delta inside a `content_block_delta` event is discriminated by its own
    /// `type`, and the text member of that union is `text_delta` (sglang
    /// `srt/entrypoints/anthropic/protocol.py:402-426`). This assertion used to pin
    /// `content_block_delta` there — the event name repeated in the discriminator slot —
    /// which is exactly what a pinned-but-wrong gate looks like: it held the deviation in
    /// place and every SDK dispatching on `delta.type` read the turn as having no text.
    @Test("content_block_delta carries a text_delta discriminator")
    func textDeltaShape() {
        let d = delta(AnthropicStreamEvent.textDelta(index: 0, text: "hi"))
        #expect(d["type"] as? String == "text_delta")
        #expect(d["text"] as? String == "hi")
        #expect(d.keys.contains("stop_reason") == false)
        #expect(d.keys.contains("stop_sequence") == false)
        #expect(d.keys.contains("partial_json") == false)
    }

    /// message_stop keeps reporting both counters, and says nothing about a cache it did
    /// not measure.
    @Test("message_stop still reports input and output tokens")
    func messageStopShape() {
        let stop = AnthropicStreamEvent.messageStop(
            totalPromptTokens: 19, cacheRead: nil, outputTokens: 5)
        let u = json(stop)["usage"] as? [String: Any]
        #expect(u?["input_tokens"] as? Int == 19)
        #expect(u?["output_tokens"] as? Int == 5)
        #expect(u?.keys.contains("cache_read_input_tokens") == false)
    }

    /// The OpenAI→Anthropic reason mapping the handler feeds the delta event.
    @Test(arguments: [("stop", "end_turn"), ("length", "max_tokens"), ("tool_calls", "tool_use")])
    func reasonMapping(openAI: String, anthropic: String) {
        #expect(openAIToAnthropicStopReason(openAI) == anthropic)
    }
}
