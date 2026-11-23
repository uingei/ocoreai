// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! MTPToolLoopHistoryTests.swift. The MTP tool loop must enter the calling assistant
//! turn into the history before any result answers it (upstream ChatSession.swift:1959).
//! Missing it, the next iteration's template renders orphan tool blocks and the loop
//! conditions on a history that erased its own actions. The class the 11-16 std-lane
//! flattening fix convicted; this suite is the MTP lane's gate for the same shape.

import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

@Suite("MTP tool boundary — call, then result, paired by id")
struct MTPToolLoopHistoryTests {

    private func toolCall(_ id: String, _ name: String) -> MLXLMCommon.ToolCall {
        MLXLMCommon.ToolCall(function: .init(name: name, arguments: [:]), id: id)
    }

    private var userTurn: MTPMessagePair {
        MTPMessagePair(role: Chat.Message.Role.user.rawValue, content: "hi")
    }

    @Test("the boundary turn carries the iteration's answer text and every call id, in order")
    func boundaryTurnShape() {
        let updated = mtpToolBoundaryHistory(
            pairs: [userTurn],
            answerText: "looking now",
            toolCalls: [toolCall("c1", "read_file"), toolCall("c2", "grep")])
        #expect(updated.count == 2)
        let turn = updated[1]
        #expect(turn.role == Chat.Message.Role.assistant.rawValue)
        #expect(turn.content == "looking now")
        #expect(turn.toolCalls?.compactMap { $0.id } == ["c1", "c2"])
        #expect(turn.chatMessage.role == .assistant)
    }

    @Test("call turn then result: the history is sound and the orphan is nil")
    func soundHistory() {
        var pairs = mtpToolBoundaryHistory(
            pairs: [userTurn],
            answerText: "",
            toolCalls: [toolCall("c1", "read_file")])
        pairs.append(
            MTPMessagePair(
                role: Chat.Message.Role.tool.rawValue, content: "contents",
                toolCallID: "c1", name: "read_file"))
        #expect(mtpHistoryOrphan(pairs) == nil)
    }

    @Test("a result without its calling turn is caught by its exact orphan id")
    func preFixShapeIsCaught() {
        var pairs: [MTPMessagePair] = [userTurn]
        pairs.append(
            MTPMessagePair(
                role: Chat.Message.Role.tool.rawValue, content: "contents",
                toolCallID: "c1", name: "read_file"))
        #expect(mtpHistoryOrphan(pairs) == "c1")
    }

    @Test("a result carrying no id can answer nothing and reports <nil>")
    func nilIdIsOrphan() {
        var pairs = mtpToolBoundaryHistory(
            pairs: [userTurn],
            answerText: "",
            toolCalls: [toolCall("c1", "read_file")])
        pairs.append(
            MTPMessagePair(role: Chat.Message.Role.tool.rawValue, content: "contents"))
        #expect(mtpHistoryOrphan(pairs) == "<nil>")
    }
}
