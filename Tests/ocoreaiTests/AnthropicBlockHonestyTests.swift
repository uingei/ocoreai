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

    @Test(
        "tool_result content reaches the prompt, as a string or as blocks",
        arguments: [
            (
                "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"The value is 42.\"}",
                "[tool_result · toolu_1] The value is 42."
            ),
            (
                "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\",\"content\":[{\"type\":\"text\",\"text\":\"sunny, 30C\"}]}",
                "[tool_result · toolu_2] sunny, 30C"
            ),
        ] as [(String, String)])
    func toolResultDelivers(blockJSON: String, expected: String) throws {
        let converted = try message(
            "{\"role\":\"user\",\"content\":[\(blockJSON),{\"type\":\"text\",\"text\":\"so what is the weather?\"}]}"
        ).toInternalMessage()
        #expect(textOf(converted) == expected + "\nso what is the weather?")
    }

    @Test("an empty tool_result says it was empty instead of contributing silence")
    func emptyToolResultIsExplicit() throws {
        let converted = try message(
            #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":""}]}"#
        ).toInternalMessage()
        #expect(textOf(converted) == "[tool_result · t1] no output")
    }

    @Test("a prior tool_use becomes tagged text — never a live call the engine would re-dispatch")
    func toolUseRendersAsText() throws {
        let converted = try message(
            """
            {"role":"assistant","content":[
              {"type":"text","text":"checking"},
              {"type":"tool_use","id":"toolu_9","name":"get_weather","input":{"city":"Singapore"}}]}
            """
        ).toInternalMessage()
        let text = textOf(converted)
        #expect(text.contains("checking"))
        #expect(text.contains("[tool_call · get_weather · toolu_9]"))
        #expect(text.contains("Singapore"), "the arguments belong in the prompt: \(text)")
        // Fabricating dispatchable tool calls would make the engine re-run finished work.
        #expect(converted.toolCalls == nil)
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
