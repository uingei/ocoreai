// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Anthropic request model tests — verifies Decoder + Scheduler wiring correctness

#if canImport(Testing)
import Testing
import Foundation
import Hummingbird
@testable import ocoreai

@Suite("Anthropic Request Model")
struct AnthropicRequestTests {

    // MARK: - Decoding

    @Test("Minimal valid request decodes")
    func testMinimalRequest() throws {
        let json = """
        {
            "model": "test-model",
            "messages": [{"role": "user", "content": "hello"}],
            "max_tokens": 1024,
        "stream": false
        }
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.model == "test-model")
        #expect(req.messages.count == 1)
        #expect(req.messages[0].role == "user")
    }

    @Test("Block content decodes correctly")
    func testBlockContentDecodes() throws {
        let json = """
        {
            "model": "test-model",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "hello"}]},
                {"role": "assistant", "content": [{"type": "text", "text": "hi back"}]}
            ],
            "max_tokens": 512,
        "stream": false
        }
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.count == 2)
    }

    @Test("Empty messages decodes (validation deferred to handler)")
    func testEmptyMessagesDecodes() throws {
        let json = """
        {
            "model": "test-model",
            "messages": [],
            "max_tokens": 256,
        "stream": false
        }
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.isEmpty)
    }

    @Test("System prompt is optional")
    func testNoSystemPrompt() throws {
        let json = """
        {
            "model": "test-model",
            "messages": [{"role": "user", "content": "test"}],
            "max_tokens": 256,
        "stream": false
        }
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.system == nil)
    }

    @Test("System prompt decodes when present")
    func testWithSystemPrompt() throws {
        let json = """
        {
            "model": "test-model",
            "system": "You are helpful",
            "messages": [{"role": "user", "content": "test"}],
            "max_tokens": 256,
        "stream": false
        }
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.system == "You are helpful")
    }

    // MARK: - Conversion

    @Test("toChatCompletionRequest maps messages correctly")
    func testToChatCompletionRequest() throws {
        let json = """
        {
            "model": "llama-3.1-8b",
            "system": "Be concise",
            "messages": [{"role": "user", "content": "Hello"}],
            "max_tokens": 4096,
        "stream": false
        }
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        let chatReq = toChatCompletionRequest(req)
        #expect(chatReq.model == "llama-3.1-8b")
        #expect(chatReq.messages.count >= 1)
    }
}

#endif
