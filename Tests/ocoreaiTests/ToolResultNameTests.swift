// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// ToolResultNameTests — pins the id → name correlation that hands a tool result
// the name the model called (`toolResultNamesByID`, fed to upstream
// `Chat.Message.tool(_:id:name:)`). The rendered-name leg is upstream's
// contract (Chat.swift's generator emits `name` when present); the DTO parse
// half rides here too, since the ladder reads caller-name-first.
import Foundation
import Testing

@testable import ocoreai

struct ToolResultNameTests {

    private func call(_ id: String, _ name: String) -> ToolCall {
        ToolCall(id: id, function: ToolCallFunction(name: name, arguments: "{}"))
    }

    @Test("assistant tool_calls feed the map; other roles contribute nothing")
    func mapFromAssistantCalls() {
        let messages = [
            Message(role: "user", content: "run both"),
            Message(role: "assistant", toolCalls: [call("c1", "read_file"), call("c2", "exec")]),
            Message(role: "tool", content: .text("ok"), toolCallID: "c1"),
            Message(role: "user", content: .text("and a fake"), name: "caller-label"),
        ]
        let map = toolResultNamesByID(in: messages)
        #expect(map == ["c1": "read_file", "c2": "exec"])
    }

    @Test("a later assistant turn extends the map; ids are unique by construction")
    func multiTurnMap() {
        let messages = [
            Message(role: "assistant", toolCalls: [call("a", "first_tool")]),
            Message(role: "assistant", toolCalls: [call("b", "second_tool")]),
        ]
        let map = toolResultNamesByID(in: messages)
        #expect(map["a"] == "first_tool")
        #expect(map["b"] == "second_tool")
    }

    @Test("the DTO parses a tool message's own name — the ladder's first rung exists")
    func dtoNameRoundTrip() throws {
        let json = """
            {"role":"tool","content":"42","tool_call_id":"c9","name":"calc"}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Message.self, from: json)
        #expect(decoded.name == "calc")
        #expect(decoded.toolCallID == "c9")
        // Absent name decodes to nil, not to a guess.
        let bare = try JSONDecoder().decode(
            Message.self,
            from: #"{"role":"tool","content":"x","tool_call_id":"c9"}"#.data(using: .utf8)!)
        #expect(bare.name == nil)
    }
}
