// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SystemInstructionDeliveryTests.swift — what the caller writes as instructions must reach
/// the one channel generation reads, and must not be counted as a conversation turn.
///
/// Measured 10-20 on this host (`mlx-community/gemma-4-e2b-it-4bit`, temp 0): a request whose
/// `messages[0]` was a ~1000-character `system` message delivered the *same*
/// `usage.prompt_tokens` as the identical request with no system message — differential **0** —
/// while this server's own disclosure line counted the text (`promptTokens=838` against 705).
/// The Anthropic face delivered the same content (+182 `input_tokens`), so the two faces
/// disagreed about the most-used instruction field on the OpenAI wire.
///
/// Why it happened: the engine takes instructions from the *first* `system` message it finds
/// (`EngineInference.swift:1791`) and filters every `system` role out of the feed it renders
/// (mlx-swift-lm's `Chat.Message.Role` has no `developer` case either, `Chat.swift:120-124`),
/// while `buildMessages` inserted this server's own prompt at index 0 and left the client's
/// message in the list at index 1 — counted, never delivered, and `developer` silently
/// re-cast as a user turn.

import Foundation
import Testing

@testable import ocoreai

@Suite("Instruction-role messages — extraction before assembly")
struct SystemInstructionDeliveryTests {

    private func roles(_ messages: [Message]) -> [String] {
        messages.map(\.role)
    }

    @Test("a leading system message becomes instructions, not a turn")
    func leadingSystemIsHoisted() {
        let (text, conversation) = splitInstructionMessages([
            Message(role: "system", content: "Answer tersely."),
            Message(role: "user", content: "Hi"),
        ])
        #expect(text == "Answer tersely.")
        #expect(roles(conversation) == ["user"])
    }

    @Test("no instruction role ⇒ nothing invented, conversation untouched")
    func nothingToHoist() {
        let (text, conversation) = splitInstructionMessages([
            Message(role: "user", content: "Hi"),
            Message(role: "assistant", content: "Hello"),
        ])
        #expect(text == nil)
        #expect(roles(conversation) == ["user", "assistant"])
    }

    @Test("several instruction messages keep the caller's order")
    func multipleInstructionsJoinInOrder() {
        let (text, conversation) = splitInstructionMessages([
            Message(role: "system", content: "First."),
            Message(role: "user", content: "Q"),
            Message(role: "system", content: "Second."),
        ])
        #expect(text == "First.\n\nSecond.")
        #expect(roles(conversation) == ["user"])
    }

    @Test("`developer` is an instruction role, not a user turn")
    func developerRoleIsInstruction() {
        // vllm routes system and developer to the same channel
        // (`entrypoints/openai/responses/harmony.py:128`,
        // `entrypoints/openai/parser/harmony_utils.py:436`); sglang admits both as generic
        // roles (`srt/entrypoints/openai/protocol.py:727-729`). Before this fix the role hit
        // the engine's default branch and arrived as something the *user* said.
        let (text, conversation) = splitInstructionMessages([
            Message(role: "developer", content: "Use metric units."),
            Message(role: "user", content: "How far?"),
        ])
        #expect(text == "Use metric units.")
        #expect(roles(conversation) == ["user"])
    }

    @Test("role matching is case-insensitive, empty instruction text is dropped")
    func casingAndEmpty() {
        #expect(
            splitInstructionMessages([Message(role: "SYSTEM", content: "Shout.")]).instructionText
                == "Shout.")
        let empty = splitInstructionMessages([
            Message(role: "system", content: ""),
            Message(role: "user", content: "Hi"),
        ])
        #expect(empty.instructionText == nil)
        #expect(roles(empty.conversation) == ["user"])
    }

    @Test("tool and function traffic stays in the conversation")
    func toolRolesStayPut() {
        let (text, conversation) = splitInstructionMessages([
            Message(role: "tool", content: .text("{\"temp\": 3}"), toolCallID: "c1"),
            Message(role: "assistant", content: "Calling."),
        ])
        #expect(text == nil)
        #expect(roles(conversation) == ["tool", "assistant"])
    }

    @Test("the instruction role set is exactly system + developer")
    func roleSetIsPinned() {
        #expect(instructionMessageRoles.sorted() == ["developer", "system"])
    }

    // MARK: — the wiring, scanned with its own floor

    private static func source(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    @Test("assembly goes through the split exactly once, and the unfiltered feed is gone")
    func assemblyUsesTheSplit() throws {
        let builder = try Self.source("Sources/ocoreai/Handlers/MessageBuilder.swift")
        // Floors: the file and both the split and its call site exist.
        #expect(builder.contains("func splitInstructionMessages("))
        let calls =
            try NSRegularExpression(pattern: #"splitInstructionMessages\(\s*context\.rawMessages"#)
            .matches(in: builder, range: NSRange(builder.startIndex..., in: builder)).count
        #expect(calls == 1)
        // The defect shape — assembly starting from the unfiltered request list — must not
        // come back; it is what let a client system message sit at index 1 and be dropped.
        let staleFeed =
            try NSRegularExpression(pattern: #"var messages = context\.rawMessages"#)
            .matches(in: builder, range: NSRange(builder.startIndex..., in: builder)).count
        #expect(staleFeed == 0)
    }

    @Test("both faces hand their request messages to the same assembly")
    func bothFacesShareTheAssembly() throws {
        let openAI = try Self.source("Sources/ocoreai/Handlers/ChatHandler.swift")
        let anthropic = try Self.source("Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift")
        #expect(openAI.contains("rawMessages: request.messages"))
        #expect(anthropic.contains("rawMessages: rawMessages"))
        // One home for the phases: neither face composes its own system prompt.
        #expect(openAI.range(of: "func buildMessages(") == nil)
        #expect(anthropic.range(of: "func buildMessages(") == nil)
    }
}
