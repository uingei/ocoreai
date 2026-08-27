// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// Align `ToolCallParser` (vended from coreai-models) with ocoreai's open tool-call
// id convention: `call_<8 hex>` — matching upstream coreai-models #203 and
// ocoreai's own `ToolCallAccumulator` (Models/OpenAIModels.swift). The parser id
// flows into the streamed `ToolCall` event AND the round-trip result message
// (`EngineInference.swift` `Chat.Message.tool(result, id: toolCall.id)`), so both
// must carry the same shape.
//
// Assertion style: exact values, no `isEmpty`/`count>N` soft checks.

import Foundation
import Testing

@testable import ocoreai

@Suite("ToolCallParser — call id consistency (coreai-models #203)")
struct ToolCallParserIDTests {
    /// One well-formed tool call block, fed across consume() boundaries to prove the
    /// id is produced on the streaming path, not only on flush().
    private func streamingFeed() -> [ToolCallParser.Event] {
        var p = ToolCallParser()  // default \u{8958} / \u{8959} markers
        var out: [ToolCallParser.Event] = []
        let json =
            """
            {"name":"get_weather","arguments":{"city":"Beijing"}}
            """
        out += p.consume("\u{8958}")
        out += p.consume(String(json.prefix(8)))
        out += p.consume(String(json.dropFirst(8)))
        out += p.consume("\u{8959}")
        out += p.flush()  // must be empty — block already closed
        return out
    }

    @Test("tool call id has the call_ prefix and 8-hex body (exact 13 chars)")
    func idFormatExact() {
        var id: String?
        for event in streamingFeed() {
            if case .toolCall(let theID, _, _) = event { id = theID }
        }
        #expect(id != nil)
        #expect(id?.hasPrefix("call_") == true)
        let body = id!.dropFirst("call_".count)
        #expect(body.count == 8)
        #expect(body.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("id shape identical to ToolCallAccumulator convention")
    func matchesAccumulatorConvention() {
        let parserID = streamingFeed().compactMap { event -> String? in
            if case .toolCall(let id, _, _) = event { return id }
            return nil
        }.first!
        // ocoreai's own generator (OpenAIModels.swift:489) produces the same shape:
        // "call_" + 8 lowercase hex. Assert the two generators agree on shape.
        let reference = "call_" + UUID().uuidString.prefix(8).lowercased()
        #expect(parserID.count == reference.count)
        #expect(parserID.prefix(5) == "call_")
        #expect(reference.count == 13)
    }

    @Test("multiple calls in one block get distinct well-formed ids")
    func multipleCallsDistinctIDs() {
        var p = ToolCallParser()
        var events = p.consume("\u{8958}")
        events += p.consume(
            """
            [{"name":"a","arguments":{"x":1}},{"name":"b","arguments":{}}]
            """)
        events += p.consume("\u{8959}")
        events += p.flush()
        let ids = events.compactMap { event -> String? in
            if case .toolCall(let id, _, _) = event { return id }
            return nil
        }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)  // unique
        #expect(ids.allSatisfy { $0.hasPrefix("call_") && $0.count == 13 })
    }

    @Test("text events are unaffected — id change is id-only")
    func textPassthroughUnchanged() {
        var p = ToolCallParser()
        var out = p.consume(
            "before \u{8958}{\"name\":\"t\",\"arguments\":{\"k\":\"v\"}}\u{8959} after")
        out += p.flush()
        let text = out.compactMap { event -> String? in
            if case .text(let s) = event { return s }
            return nil
        }.joined()
        #expect(text == "before  after")
        let tc = out.compactMap { event -> (id: String, name: String, args: String)? in
            if case .toolCall(let id, let name, let args) = event { return (id, name, args) }
            return nil
        }
        #expect(tc.count == 1)
        #expect(tc[0].id.hasPrefix("call_"))
        #expect(tc[0].name == "t")
        #expect(tc[0].args == #"{"k":"v"}"#)
    }
}
