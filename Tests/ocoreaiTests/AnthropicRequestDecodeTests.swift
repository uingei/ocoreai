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
        #expect(try toChatCompletionRequest(req).stream == false)
    }

    @Test("stream true and false decode as sent")
    func streamExplicit() throws {
        for (flag, expected) in [(true, true), (false, false)] {
            let json =
                "{\"model\":\"m\",\"stream\":\(flag),\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
            let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
            #expect(req.stream == expected)
            #expect(try toChatCompletionRequest(req).stream == expected)
        }
    }

    /// Anthropic `system` is `string | [text block]`; the SDK emits the block
    /// form whenever a system block carries `cache_control`. A `String?` field
    /// rejected it, which 400'd the whole body before the conversation could
    /// reach a server that was ready to serve it.
    @Test("system as a text-block array decodes and flattens")
    func systemAsTextBlocks() throws {
        let json = """
            {"model":"m","max_tokens":16,\
            "system":[{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}},\
            {"type":"text","text":"in English"}],\
            "messages":[{"role":"user","content":"hi"}]}
            """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        #expect(req.system?.text == "be terse\nin English")
        #expect(try toChatCompletionRequest(req).system == "be terse\nin English")
    }

    @Test("system as a plain string keeps working, and absent stays absent")
    func systemAsStringOrAbsent() throws {
        let stringSystem =
            #"{"model":"m","max_tokens":16,"system":"be terse","messages":[{"role":"user","content":"hi"}]}"#
        let req = try JSONDecoder().decode(
            AnthropicMessageRequest.self, from: Data(stringSystem.utf8))
        #expect(req.system?.text == "be terse")
        #expect(try toChatCompletionRequest(req).system == "be terse")

        let absent = #"{"model":"m","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#
        let bare = try JSONDecoder().decode(
            AnthropicMessageRequest.self, from: Data(absent.utf8))
        #expect(bare.system == nil, "absent `system` must not be a decode error")
        #expect(try toChatCompletionRequest(bare).system == nil)
    }

    /// What the Anthropic mapping owns, decided offline: the conversation, with the agent
    /// context left for the shared assembly.
    ///
    /// `/v1/messages` and `/v1/messages/count_tokens` count ONE list — both routes call
    /// `buildAnthropicMessageList`, so a pre-flight cannot budget less than the request it
    /// precedes. That equality is structural (one builder, two callers; the call sites are
    /// pinned by the source scan in `AnthropicToolDeliveryTests`) and measured live by
    /// probe 13 §8, which asserts `count_tokens` equals the same request's own
    /// `usage.input_tokens`.
    ///
    /// `system` is NOT inserted here: it is the caller's system prompt, and the shared
    /// assembly composes it with the agent's own context in codex's precedence order
    /// (user instructions, then workspace/skills/memory) — the same field
    /// `/v1/chat/completions` uses, so both faces give the model the same product context.
    /// `tools[]` is not message text here either: it travels as the structured declaration.
    @Test("the mapping carries the conversation and hands system + tools to the shared assembly")
    func conversationMappingKeepsSystemAndToolsForTheSharedAssembly() throws {
        let json = """
            {"model":"m","max_tokens":16,"system":"be terse",\
            "tools":[{"name":"run_shell","description":"Run a shell command"}],\
            "messages":[{"role":"user","content":"ls"}]}
            """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        let built = try anthropicConversationMessages(request: req)
        #expect(built.map(\.role) == ["user"], "the mapping adds no system turn of its own")
        #expect(built.last?.textContent() == "ls")
        // …and neither declaration is lost on the way to the internal request.
        let internalRequest = try toChatCompletionRequest(req)
        #expect(internalRequest.system == "be terse", "the caller's system prompt is carried")
        #expect(
            internalRequest.tools?.map { $0.function.name } == ["run_shell"],
            "tools reach the engine as specs")
    }
}
