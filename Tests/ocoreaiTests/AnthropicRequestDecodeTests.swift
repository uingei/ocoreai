// AnthropicRequestDecodeTests.swift — Regression gate for POST /v1/messages request
// decoding. Anthropic marks `stream` optional (absent = false), so a spec-legal
// client that omits it must still decode. Live probe 10-13 (macOS 26):
// `{"model","max_tokens","messages"}` → HTTP 400 "Coding key `stream` not found."

import Foundation
import Testing

@testable import ocoreai

@Suite("AnthropicMessageRequest decoding — Anthropic optional fields")
struct AnthropicRequestDecodeTests {

    /// Absent `stream` decodes as "not set" and must reach the engine as false.
    @Test("stream omitted decodes and maps to false")
    func streamOmitted() throws {
        let json = """
            {"model":"m","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}
            """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        #expect(req.model == "m")
        #expect(req.maxTokens == 16)
        #expect(req.stream == nil, "absent `stream` must not be a decode error")
        #expect(toChatCompletionRequest(req).stream == false)
    }

    @Test("stream true and false decode as sent")
    func streamExplicit() throws {
        for (flag, expected) in [(true, true), (false, false)] {
            let json =
                "{\"model\":\"m\",\"stream\":\(flag),\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
            let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
            #expect(req.stream == expected)
            #expect(toChatCompletionRequest(req).stream == expected)
        }
    }
}
