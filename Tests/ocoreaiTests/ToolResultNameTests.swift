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

// Selective: a plain `import MLXLMCommon` would shadow the DTO's `Message` and
// `ToolCall` below with upstream's own top-level types of the same name.
import enum MLXLMCommon.Chat

@testable import ocoreai

struct ToolResultNameTests {

    private func call(_ id: String, _ name: String) -> ToolCall {
        ToolCall(id: id, function: ToolCallFunction(name: name, arguments: "{}"))
    }

    /// A `rendered` list built exactly the way the std lane builds it: a pure map
    /// over the wire list, so the pair builder's index pairing is exercised as it
    /// is in the engine.
    private func rendered(as wire: [Message]) -> [Chat.Message] {
        wire.map { msg in
            let text: String
            if case .text(let t)? = msg.content { text = t } else { text = "" }
            let role = Chat.Message.Role(rawValue: msg.role) ?? .user
            return Chat.Message(role: role, content: text)
        }
    }

    private var toolCallHistory: [Message] {
        [
            Message(role: "user", content: "run both"),
            Message(role: "assistant", toolCalls: [call("c1", "read_file"), call("c2", "exec")]),
            Message(role: "tool", content: .text("ok"), toolCallID: "c1"),
            Message(
                role: "tool", content: .text("done"), name: "caller-label", toolCallID: "c2"),
        ]
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

    @Test("the MTP pair builder keeps the metadata the (role, content) snapshot dropped")
    func mtpPairsCarryToolMetadata() {
        let wire = toolCallHistory
        let pairs = mtpMessagePairs(
            from: wire, rendered: rendered(as: wire), names: toolResultNamesByID(in: wire))
        #expect(pairs.count == 4)
        #expect(pairs[0].toolCallID == nil && pairs[0].name == nil && pairs[0].toolCalls == nil)
        // The assistant turn survives with both calls, in order — the template's
        // id→name correlation needs them.
        #expect(pairs[1].toolCalls?.map { $0.function.name } == ["read_file", "exec"])
        // Tool results: the ladder names the one the caller left bare…
        #expect(pairs[2].toolCallID == "c1")
        #expect(pairs[2].name == "read_file")
        // …and a caller-supplied name still wins.
        #expect(pairs[3].toolCallID == "c2")
        #expect(pairs[3].name == "caller-label")
    }

    @Test("rebuild produces the role the std lane renders; a loop-appended pair survives")
    func mtpPairRebuildRoundTrip() {
        let wire = toolCallHistory
        var history = mtpMessagePairs(
            from: wire, rendered: rendered(as: wire), names: toolResultNamesByID(in: wire))
        // What the MTP loop appends for a dispatched call (4237 site's shape).
        history.append(
            MTPMessagePair(
                role: Chat.Message.Role.tool.rawValue, content: "3rd",
                toolCallID: "c3", name: "third_tool"))
        let rebuilt = history.map(\.chatMessage)
        #expect(rebuilt.map { $0.role.rawValue } == ["user", "assistant", "tool", "tool", "tool"])
        #expect(rebuilt[2].content == "ok")
        #expect(rebuilt[4].content == "3rd")
    }
}
