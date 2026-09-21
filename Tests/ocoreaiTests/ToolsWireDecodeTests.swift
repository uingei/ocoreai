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

    @Test("tool_choice:\"none\" -> effectiveTools is nil even with tools[] declared")
    func toolChoiceNoneRemovesSurface() throws {
        let body = #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"none"}
            """#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        #expect(req.tools?.count == 1, "declared tools[] still decoded (client data preserved)")
        #expect(
            effectiveTools(from: req) == nil,
            "tool_choice:\"none\" must remove the tool surface (engine: zero tools)")
    }

    @Test("tool_choice:\"auto\"/absent -> effectiveTools unchanged")
    func toolChoiceAutoKeepsSurface() throws {
        let bodyAuto = #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":"auto"}
            """#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: bodyAuto.data(using: .utf8)!)
        #expect(effectiveTools(from: req)?.count == 1)

        let bodyNo = #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#
        let reqNone = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: bodyNo.data(using: .utf8)!)
        #expect(effectiveTools(from: reqNone) == nil)
    }

    @Test("tool_choice:\"none\" + responseFormat json_schema -> grammar still constrained")
    func toolChoiceNoneKeepsJsonSchemaGuided() throws {
        let body = #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":"none","response_format":{"type":"json_object"}}
            """#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        #expect(effectiveTools(from: req) == nil, "tool surface removed")
        let schema = buildGrammarSchema(
            from: effectiveTools(from: req),
            responseFormat: req.responseFormat)
        #expect(
            schema != nil,
            "the json_schema guided path is independent of the tool surface")
    }

    @Test("tool_choice object form {\"type\":\"function\",\"name\":\"x\"} decodes — NOT a 400")
    func toolChoiceObjectPinDecodes() throws {
        let body =
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":{"type":"function","name":"get_weather"}}"#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        // Normalized form: pin prefix + name (distinct from the bare-string namespace).
        #expect(req.toolChoice == "function:get_weather")
        #expect(req.tools?.count == 1)
    }

    @Test("object form with a tool literally named 'none' is NOT the string 'none'")
    func toolChoiceObjectNamedNoneNoCollusion() throws {
        let body =
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"none","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":{"type":"function","name":"none"}}"#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        #expect(req.toolChoice == "function:none")
        #expect(
            effectiveTools(from: req)?.count == 1,
            "object form is a PIN, not 'none' — surface must stay")
    }

    @Test("object form + tools[] — pin expressed as whitelist [name] (existing P0-3 mechanism)")
    func toolChoiceObjectPinsSurface() throws {
        let body =
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":{"type":"function","name":"get_weather"}}"#
        let req = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: body.data(using: .utf8)!)
        // The pin must NOT remove the surface (only "none" does).
        #expect(effectiveTools(from: req)?.count == 1)
    }

    @Test(
        "object form with unknown type rejects cleanly (400 on a real decode error, not silent nil)"
    )
    func toolChoiceObjectUnknownTypeThrows() {
        let body =
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"bogus","name":"x"}}"#
        #expect(
            (try? JSONDecoder().decode(ChatCompletionRequest.self, from: body.data(using: .utf8)!))
                == nil,
            "unsupported tool_choice type must throw, not decode silently")
    }

    @Test("object form without name rejects cleanly")
    func toolChoiceObjectMissingNameThrows() {
        let body =
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function"}}"#
        #expect(
            (try? JSONDecoder().decode(ChatCompletionRequest.self, from: body.data(using: .utf8)!))
                == nil,
            "tool_choice:{type:function} without name must throw")
    }
}
