// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// toolsWireDecodeTests.swift — pins the OpenAI `tools[]` decode contract on
/// ChatCompletionRequest.
///
/// Why it matters: the live tool-call path was observed logging
/// "full route: 31/31 injected, client declared no tools[]" + the FM
/// LanguageModelSession path for a request whose body DID declare
/// tools:[get_weather]. decodeIfPresent returns nil ONLY when the key is
/// absent; a present-but-malformed value THROWS (whole request → 400). So
/// "tools decoded to nil" can only mean the `tools` key was never seen as
/// present. Pin the exact production body and assert tools lands non-nil,
/// so the decode contract is proven (or the gap is exposed) deterministically
/// — not by a live server whose log the harness can muddy.
import Foundation
import Testing

@testable import ocoreai

@Suite("ChatCompletionRequest.tools wire decode")
struct ToolsWireDecodeTests {
    /// The exact production body (single line, valid JSON — the same shape
    /// real OpenAI clients send).
    private let body = #"""
        {"model": "mlx-community/gemma-4-e2b-it-4bit", "max_tokens": 200, "messages": [{"role": "system", "content": "Use the get_weather tool to answer weather questions."}, {"role": "user", "content": "What is the weather in Berlin right now?"}], "tools": [{"type": "function", "function": {"name": "get_weather", "description": "Get current weather for a city", "parameters": {"type": "object", "properties": {"city": {"type": "string", "description": "City name"}}, "required": ["city"]}}}], "tool_choice": "auto"}
        """#

    @Test("tools:[] is NOT dropped -> decodes to 1 ToolDef")
    func toolsDecode() throws {
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        #expect(
            req.tools != nil, "tools[] decoded to nil — the declared whitelist is lost at the wire")
        #expect(req.tools?.count == 1)
        #expect(req.tools?.first?.function.name == "get_weather")
        #expect(
            req.tools?.first?.function.parameters?["name"] != nil
                || req.tools?.first?.function.parameters != nil)
        // The wire body sends `tool_choice` (OpenAI snake_case). It MUST
        // decode, not be silently dropped. This pins the contract so a
        // CodingKey raw-value regression here is caught.
        #expect(
            req.toolChoice == "auto",
            "tool_choice (snake_case) decoded to nil — silently dropped at the wire")
    }

    @Test("tools absent (no key) -> decodes to nil (local-first full surface)")
    func noToolsDecodesNil() throws {
        let body = #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}]}
            """#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        #expect(req.tools == nil)
    }
}
