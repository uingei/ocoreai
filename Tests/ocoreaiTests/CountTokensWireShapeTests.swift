// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CountTokensWireShapeTests.swift — pin every body shape `POST /v1/count-tokens`
/// accepts, plus the response keys both counting endpoints put on the wire.
///
/// Why a gate here: live 10-14 the endpoint decoded only `{model, prompt}`, so
/// spec-legal OpenAI (`input`) and Anthropic (`messages` + `system`) bodies got
/// `400 Coding key `prompt` not found.` — from the one endpoint whose job is to
/// tell a client how big its request is. Decode-level tests, no GPU and no
/// loaded model: the defect was in the DTO, so the gate lives at the DTO.

import Foundation
import Testing

@testable import ocoreai

@Suite("POST /v1/count-tokens — request body shapes")
struct CountTokensRequestShapeTests {

    private func decode(_ json: String) throws -> CountTokensRequest {
        try JSONDecoder().decode(CountTokensRequest.self, from: Data(json.utf8))
    }

    @Test("prompt (this server's original shape) becomes one user turn")
    func promptShape() throws {
        let req = try decode(#"{"model":"m","prompt":"hello world"}"#)
        #expect(req.model == "m")
        #expect(req.messages.count == 1)
        #expect(req.messages[0].role == "user")
        #expect(req.messages[0].textContent() == "hello world")
        #expect(req.hasTextToCount)
    }

    @Test("input as a string (OpenAI) becomes one user turn")
    func inputString() throws {
        let req = try decode(#"{"model":"m","input":"hello world"}"#)
        #expect(req.messages.count == 1)
        #expect(req.messages[0].role == "user")
        #expect(req.messages[0].textContent() == "hello world")
    }

    @Test("input as [String] joins into one user turn")
    func inputStringArray() throws {
        let req = try decode(#"{"model":"m","input":["alpha","beta"]}"#)
        #expect(req.messages.count == 1)
        #expect(req.messages[0].textContent() == "alpha\nbeta")
    }

    @Test("input as [{role,content}] keeps every turn")
    func inputMessageArray() throws {
        let req = try decode(
            #"{"model":"m","input":[{"role":"system","content":"be terse"},{"role":"user","content":"hi"}]}"#
        )
        #expect(req.messages.count == 2)
        #expect(req.messages.map(\.role) == ["system", "user"])
        #expect(req.messages[1].textContent() == "hi")
    }

    @Test("messages without system decodes as sent")
    func messagesShape() throws {
        let req = try decode(
            #"{"model":"m","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}]}"#
        )
        #expect(req.messages.count == 2)
        #expect(req.messages.map(\.role) == ["user", "assistant"])
    }

    @Test("messages + string system prepends the system turn")
    func messagesWithStringSystem() throws {
        let req = try decode(
            #"{"model":"m","system":"be terse","messages":[{"role":"user","content":"hi"}]}"#
        )
        #expect(req.messages.count == 2)
        #expect(req.messages[0].role == "system")
        #expect(req.messages[0].textContent() == "be terse")
    }

    @Test("messages + text-block system flattens to the system turn")
    func messagesWithBlockSystem() throws {
        let req = try decode(
            """
            {"model":"m","system":[{"type":"text","text":"part one","cache_control":{"type":"ephemeral"}},{"type":"text","text":"part two"}],"messages":[{"role":"user","content":"hi"}]}
            """
        )
        #expect(req.messages.count == 2)
        #expect(req.messages[0].role == "system")
        #expect(req.messages[0].textContent() == "part one\npart two")
    }

    @Test("content parts array keeps its text, ignores the media part")
    func multipartContent() throws {
        let req = try decode(
            #"{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"what is in this image?"},{"type":"image_url","image_url":{"url":"https://x/y.png"}}]}]}"#
        )
        #expect(req.messages.count == 1)
        #expect(req.messages[0].textContent() == "what is in this image?")
        #expect(req.hasTextToCount)
    }

    @Test("messages wins over input and prompt when a body carries several")
    func precedence() throws {
        let req = try decode(
            #"{"model":"m","prompt":"legacy","input":"openai","messages":[{"role":"user","content":"anthropic"}]}"#
        )
        #expect(req.messages.count == 1)
        #expect(req.messages[0].textContent() == "anthropic")
    }

    @Test("nothing to count: no field, empty string, media-only")
    func nothingToCount() throws {
        #expect(try !decode(#"{"model":"m"}"#).hasTextToCount)
        #expect(try !decode(#"{"model":"m","prompt":""}"#).hasTextToCount)
        #expect(try !decode(#"{"model":"m","messages":[]}"#).hasTextToCount)
        #expect(
            try !decode(
                #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://x/y.png"}}]}]}"#
            ).hasTextToCount)
    }

    @Test("`model` is required — no default model is invented for a count")
    func modelRequired() {
        #expect(throws: (any Error).self) {
            try decode(#"{"prompt":"hello"}"#)
        }
    }
}

@Suite("Count-token responses — wire keys")
struct CountTokensResponseWireTests {

    private enum WireShapeFailure: Error {
        case notAnObject
    }

    private static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw WireShapeFailure.notAnObject
        }
        return object
    }

    @Test("OpenAI-style count reports prompt_tokens + tokenizer_backend")
    func openAIShapedResponse() throws {
        let line = try Self.json(
            CountTokensResponse(model: "m", tokenCount: 42, tokenizerBackend: "real"))
        #expect(line["model"] as? String == "m")
        #expect(line["prompt_tokens"] as? Int == 42, "`prompt_tokens` is the pinned key")
        #expect(line["tokenizer_backend"] as? String == "real")
        #expect(line["tokenCount"] == nil, "camelCase must not leak onto the wire")
    }

    @Test("Anthropic-style count reports input_tokens + tokenizer_backend")
    func anthropicShapedResponse() throws {
        let line = try Self.json(
            AnthropicCountTokensResponse(inputTokens: 42, tokenizerBackend: "heuristic"))
        #expect(line["input_tokens"] as? Int == 42)
        #expect(line["tokenizer_backend"] as? String == "heuristic")
        #expect(line["prompt_tokens"] == nil, "the Anthropic endpoint speaks input_tokens")
    }
}
