// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AnthropicBlockHonestyTests.swift — every content block a spec-legal client can send is
/// either carried into the prompt or refused by name. Nothing in between.
///
/// Why the stakes (AGENTS.md § Wire DTOs + invariant 2, measured 10-15 by
/// `scripts/probes/07-anthropic-blocks.sh`): `AnthropicContentBlock.type` used to be
/// `enum BlockType { case text, toolUse }`. A block of any other spec-legal type failed to
/// decode; array decoding is all-or-nothing, so ``AnthropicContent``'s fallback replaced the
/// entire message with empty text. Live consequence: `[{"type":"text",…},{"type":"image",…}]`
/// reached the model as an empty turn — HTTP 200, `usage.input_tokens` 10 against 22 for the
/// same instruction as a plain string, answer "Please provide the input you would like me to
/// process." — and `tool_result`, the shape Anthropic's SDK requires to continue a tool
/// loop, took the same path. The client could not tell any of that from success.
///
/// Every test here is offline: decoding and mapping need no engine, no model, no network.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

private func message(_ json: String) throws -> AnthropicMessage {
    try JSONDecoder().decode(AnthropicMessage.self, from: Data(json.utf8))
}

private func request(_ json: String) throws -> AnthropicMessageRequest {
    try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
}

/// The single engine turn these mapping tests describe.
///
/// One Anthropic message can now become several engine turns (N `tool_result` blocks are
/// N `role:"tool"` turns, because that channel carries one `tool_call_id` per turn), so a
/// test that reasons about "the" converted message has to say it expected exactly one —
/// otherwise a mapping that split the turn would still pass its text assertions and the
/// test would stop meaning what it claims (AGENTS.md: a check asserts its own premises).
extension AnthropicMessage {
    fileprivate func toInternalMessage() throws -> Message {
        let turns = try toInternalMessages()
        let roles = turns.map(\.role).joined(separator: ", ")
        try #require(
            turns.count == 1,
            "this fixture is a single engine turn, got \(turns.count): \(roles)")
        return turns[0]
    }
}

/// Text of an internal message, however it is shaped.
private func textOf(_ message: Message) -> String {
    switch message.content {
    case .some(.text(let s)): return s
    case .some(.parts(let parts)): return parts.compactMap(\.text).joined(separator: "\n")
    case .none: return ""
    }
}

private func imageURLs(of message: Message) -> [String] {
    guard case .some(.parts(let parts)) = message.content else { return [] }
    return parts.compactMap { $0.imageUrl?.url }
}

/// The refusal an unsupported block must produce: 400, naming the block type.
private func expectRefusal(_ result: Result<Message, Error>, containing fragment: String) {
    switch result {
    case .success(let message):
        Issue.record(
            "expected a refusal naming '\(fragment)', got a delivered turn: '\(textOf(message))'")
    case .failure(let error):
        let appError = error as? AppError
        #expect(
            appError?.status == .badRequest,
            "must be a 400 (the client's shape), got \(appError?.status.code ?? -1)")
        let described = appError?.description ?? String(describing: error)
        #expect(
            described.contains(fragment),
            "the refusal must name the shape the client can drop: \(described)")
    }
}

@Suite("Anthropic content blocks — honoured or refused, never blanking")
struct AnthropicBlockHonestyTests {

    @Test("every spec-legal block type decodes — the closed enum is what blanked the array")
    func allBlockTypesDecode() throws {
        let blocks = """
            [{"type":"text","text":"hi"},
             {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},
             {"type":"tool_result","tool_use_id":"toolu_1","content":"42"},
             {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SG"}},
             {"type":"document","source":{"type":"text","media_type":"text/plain","data":"body"}},
             {"type":"search_result","content":[{"type":"text","text":"future shape"}]}]
            """
        let decoded = try message("{\"role\":\"user\",\"content\":\(blocks)}")
        guard case .some(.blocks(let parsed)) = decoded.content else {
            Issue.record("an array must decode as .blocks")
            return
        }
        #expect(parsed.count == 6)
        #expect(
            parsed.map(\.type) == [
                "text", "image", "tool_result", "tool_use", "document", "search_result",
            ])
        // The payload each shape carries is still reachable after decoding.
        #expect(parsed[1].source?.mediaURL == "data:image/png;base64,AAAA")
        #expect(parsed[2].toolUseId == "toolu_1")
        #expect(parsed[2].content?.text == "42")
        #expect(parsed[3].name == "get_weather")
    }

    @Test("text blocks join in the order the client wrote them")
    func textBlocksJoinInOrder() throws {
        let converted = try message(
            """
            {"role":"user","content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}
            """
        ).toInternalMessage()
        #expect(textOf(converted) == "one\ntwo")
        #expect(imageURLs(of: converted).isEmpty)
    }

    @Test("an image block reaches the engine as the same inline form /v1/chat/completions uses")
    func imageBecomesInlinePart() throws {
        let converted = try message(
            """
            {"role":"user","content":[
              {"type":"text","text":"what colour is this?"},
              {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}
            """
        ).toInternalMessage()
        guard case .some(.parts(let parts)) = converted.content else {
            Issue.record("a message with media must stay multi-part")
            return
        }
        #expect(parts.count == 2)
        #expect(parts[0].text == "what colour is this?")
        #expect(parts[1].imageUrl?.url == "data:image/png;base64,AAAA")
        #expect(converted.hasMediaPart)
    }

    @Test("source.url images pass the URL through instead of vanishing")
    func imageURLSourcePassesThrough() throws {
        let converted = try message(
            """
            {"role":"user","content":[
              {"type":"image","source":{"type":"url","url":"https://example.invalid/a.png"}}]}
            """
        ).toInternalMessage()
        #expect(imageURLs(of: converted) == ["https://example.invalid/a.png"])
    }

    @Test("an image block with no source is refused by name, not answered blind")
    func imageWithoutSourceRefused() {
        let result = Result {
            try message(#"{"role":"user","content":[{"type":"image"}]}"#).toInternalMessage()
        }
        expectRefusal(result, containing: "image")
    }

    /// A `tool_result` reaches the model on the engine's tool channel: its own
    /// `role:"tool"` turn with the `tool_call_id` it answers, not prose inside the user turn.
    /// (The prose it used to be is quoted below — the answer stayed correct on this
    /// checkpoint even so, which is why no probe caught it: the deviation is structural.)
    @Test(
        "tool_result reaches the prompt as a tool turn carrying its call id",
        arguments: [
            (
                "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"The value is 42.\"}",
                "The value is 42."
            ),
            (
                "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\",\"content\":[{\"type\":\"text\",\"text\":\"sunny, 30C\"}]}",
                "sunny, 30C"
            ),
        ] as [(String, String)])
    func toolResultDelivers(blockJSON: String, expected: String) throws {
        let turns = try message(
            "{\"role\":\"user\",\"content\":[\(blockJSON),{\"type\":\"text\",\"text\":\"so what is the weather?\"}]}"
        ).toInternalMessages()
        // Result first, commentary after: a tool turn has to sit where the template expects
        // a result, and `[user, tool]` renders as a result with no call before it.
        #expect(turns.map(\.role) == ["tool", "user"])
        #expect(turns[0].toolCallID != nil, "a result without its call id is not a result")
        #expect(textOf(turns[0]) == expected)
        #expect(textOf(turns[1]) == "so what is the weather?")
    }

    @Test("the tool turn carries the id the client used, so the pair still lines up")
    func toolResultKeepsCallId() throws {
        let turns = try message(
            #"""
            {"role":"user","content":[
              {"type":"tool_result","tool_use_id":"toolu_77","content":"ok"},
              {"type":"tool_result","tool_use_id":"toolu_78","content":"also ok"}]}
            """#
        ).toInternalMessages()
        #expect(turns.map(\.role) == ["tool", "tool"])
        #expect(turns.map(\.toolCallID) == ["toolu_77", "toolu_78"])
        #expect(turns.map { textOf($0) } == ["ok", "also ok"])
    }

    @Test("an empty tool_result says it was empty instead of contributing silence")
    func emptyToolResultIsExplicit() throws {
        let turns = try message(
            #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":""}]}"#
        ).toInternalMessages()
        #expect(turns.count == 1)
        #expect(textOf(turns[0]) == "no output")
        #expect(turns[0].toolCallID == "t1")
    }

    /// `is_error:true` means the call FAILED. The engine's tool turn has no error bit
    /// (`Chat.Message.tool(_:id:)` takes content and id), so the flag travels as text —
    /// the alternative is a model told, in effect, that the call succeeded.
    @Test("a failed tool_result says it failed")
    func failedToolResultIsMarked() throws {
        let turns = try message(
            """
            {"role":"user","content":[
              {"type":"tool_result","tool_use_id":"t9","content":"permission denied","is_error":true}]}
            """
        ).toInternalMessages()
        #expect(turns.count == 1)
        let text = textOf(turns[0])
        #expect(text.contains("permission denied"), "the failure detail belongs in the prompt")
        #expect(text.lowercased().contains("error"), "a failure must read as a failure: \(text)")
    }

    /// A result with no `tool_use_id` cannot be paired with a call, so it stays text —
    /// text is the fallback medium, not the primary one. Content the client sent is never
    /// dropped on the way to the prompt because its id was missing.
    @Test("a tool_result with no id falls back to text instead of vanishing")
    func unpairedToolResultFallsBackToText() throws {
        let turns = try message(
            #"{"role":"user","content":[{"type":"tool_result","content":"42"}]}"#
        ).toInternalMessages()
        #expect(turns.count == 1)
        #expect(turns[0].role == "user", "no id, no tool channel")
        let text = textOf(turns[0])
        #expect(text.contains("[tool_result]"), "the tag says what this text is: \(text)")
        #expect(text.contains("42"))
    }

    /// The assistant's own `tool_use` block becomes the structured call the engine matches
    /// generated calls against — the same shape `/v1/chat/completions` hands over as
    /// `assistant.tool_calls`, and what `EngineInference` renders through the chat
    /// template's tool channel (`Chat.Message.assistant(_:toolCalls:)`).
    ///
    /// Structured history does not make the engine run anything: it dispatches the calls it
    /// parses out of *generation*, never out of the messages it was handed. That premise is
    /// what the old test asserted by requiring `toolCalls == nil`, and it is now gated
    /// behaviourally instead — probe 13 §7 continues a loop and requires the turn to answer
    /// with the supplied result (`17C`), stop at `end_turn`, and emit no new call.
    @Test("a prior tool_use becomes the structured call the engine keys on")
    func toolUseBecomesStructuredCall() throws {
        let turns = try message(
            """
            {"role":"assistant","content":[
              {"type":"text","text":"checking"},
              {"type":"tool_use","id":"toolu_9","name":"get_weather","input":{"city":"Singapore"}}]}
            """
        ).toInternalMessages()
        #expect(turns.count == 1)
        let converted = turns[0]
        #expect(converted.role == "assistant")
        #expect(textOf(converted) == "checking")
        let calls = converted.toolCalls ?? []
        #expect(calls.count == 1, "the call must be structured, not prose")
        #expect(calls[0].id == "toolu_9")
        #expect(calls[0].function.name == "get_weather")
        #expect(
            calls[0].function.arguments.contains("Singapore"),
            "the arguments belong to the call: \(calls[0].function.arguments)")
    }

    /// An assistant call with no id would be unanswerable on the tool channel (the result
    /// pairs by id), so it gets one rather than a dangling call.
    @Test("a tool_use with no id still becomes a call, with an id generated")
    func toolUseWithoutIdStillStructures() throws {
        let turns = try message(
            #"""
            {"role":"assistant","content":[{"type":"tool_use","name":"get_weather","input":{}}]}
            """#
        ).toInternalMessages()
        let calls = turns[0].toolCalls ?? []
        #expect(calls.count == 1)
        #expect(calls[0].id.isEmpty == false, "a call needs an id so a result can answer it")
        #expect(calls[0].function.arguments == "{}", "no arguments is an empty object, not nil")
    }

    /// `tool_use` in a user turn is not a call the assistant made. It stays tagged text:
    /// structuring it would put words in the assistant's mouth on the tool channel.
    @Test("tool_use outside an assistant turn stays tagged text")
    func misplacedToolUseStaysText() throws {
        let turns = try message(
            #"""
            {"role":"user","content":[{"type":"tool_use","id":"x1","name":"get_weather","input":{"city":"Rome"}}]}
            """#
        ).toInternalMessages()
        #expect(turns.count == 1)
        #expect(turns[0].toolCalls == nil)
        #expect(textOf(turns[0]).contains("[tool_call · get_weather · x1]"))
    }

    @Test("thinking is disclosed as omitted, not silently erased from the turn")
    func thinkingIsDisclosed() throws {
        let converted = try message(
            """
            {"role":"assistant","content":[
              {"type":"thinking","thinking":"…","signature":"sig"},
              {"type":"text","text":"the answer is 42"}]}
            """
        ).toInternalMessage()
        let text = textOf(converted)
        #expect(text.contains("[prior thinking omitted by this server]"))
        #expect(text.contains("the answer is 42"))
    }

    @Test("a document block is refused by name rather than dropped from the prompt")
    func documentRefusedByName() {
        let result = Result {
            try message(
                """
                {"role":"user","content":[
                  {"type":"text","text":"summarise the attachment"},
                  {"type":"document","source":{"type":"text","media_type":"text/plain","data":"…"}}]}
                """
            ).toInternalMessage()
        }
        expectRefusal(result, containing: "document")
    }

    @Test("an unknown future block is refused by name — and cannot blank the text beside it")
    func unknownBlockRefusedByName() {
        let result = Result {
            try message(
                """
                {"role":"user","content":[
                  {"type":"text","text":"answer me"},
                  {"type":"search_result","content":[{"type":"text","text":"invented next year"}]}]}
                """
            ).toInternalMessage()
        }
        expectRefusal(result, containing: "search_result")
    }

    @Test("a user array that carries nothing readable is a 400, not an empty prompt")
    func emptyUserArrayRefused() {
        expectRefusal(
            Result { try message(#"{"role":"user","content":[]}"#).toInternalMessage() },
            containing: "nothing")
    }

    @Test("an assistant turn may still carry no text (a tool call with no prose stays legal)")
    func emptyAssistantTurnIsNotAnError() throws {
        let converted = try message(#"{"role":"assistant","content":[]}"#).toInternalMessage()
        #expect(converted.content == nil)
    }

    @Test("plainText reads the same content the prompt will carry")
    func plainTextMatchesPromptContent() throws {
        let withResult = try message(
            #"{"role":"user","content":[{"type":"text","text":"and then?"},{"type":"tool_result","tool_use_id":"t","content":"done"}]}"#
        )
        #expect(
            withResult.plainText == "and then?\n[tool_result · t] done",
            "the guard must see the tool output too: \(withResult.plainText)")
    }

    @Test("the system field still flattens text blocks (regression for the string-typed enum)")
    func systemBlocksStillFlatten() throws {
        let req = try request(
            """
            {"model":"m","max_tokens":8,
             "system":[{"type":"text","text":"be terse"},{"type":"text","text":"in English"}],
             "messages":[{"role":"user","content":"hi"}]}
            """
        )
        #expect(req.system?.text == "be terse\nin English")
    }

    @Test("both mappers agree: the /v1/messages path and the internal request see one prompt")
    func mappersAgree() throws {
        let req = try request(
            """
            {"model":"m","max_tokens":8,"messages":[
              {"role":"user","content":[
                {"type":"text","text":"look at this"},
                {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]}
            """
        )
        let viaRequest = try toChatCompletionRequest(req).messages
        let viaMessages = [try req.messages[0].toInternalMessage()]
        #expect(viaRequest.count == viaMessages.count)
        #expect(imageURLs(of: viaRequest[0]) == imageURLs(of: viaMessages[0]))
        #expect(textOf(viaRequest[0]) == textOf(viaMessages[0]))
    }

    @Test("a request holding only unsupported blocks fails at the request boundary")
    func requestBoundaryRefusesToo() {
        let json = """
            {"model":"m","max_tokens":8,"messages":[
              {"role":"user","content":[
                {"type":"document","source":{"type":"text","media_type":"text/plain","data":"x"}}]}]}
            """
        let result = Result { try toChatCompletionRequest(request(json)) }
        switch result {
        case .success:
            Issue.record("an unsupported block must stop the request, not be counted or run")
        case .failure(let error):
            #expect((error as? AppError)?.status == .badRequest)
            #expect(
                (error as? AppError)?.description.contains("document") == true,
                "the refusal must name the block: \((error as? AppError)?.description ?? "-")")
        }
    }

}
