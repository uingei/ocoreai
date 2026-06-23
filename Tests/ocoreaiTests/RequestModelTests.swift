// RequestModelTests.swift — ChatCompletionRequest decoding & defaults
//
// Validates JSON deserialization, default values, and edge cases
// without requiring CoreAI runtime.

#if canImport(Testing)
import Testing
import Foundation
@testable import ocoreai

@Suite("Request Models")
struct RequestModelTests {
    // MARK: — Basic Decoding

    @Test("minimal request decodes with defaults")
    func testMinimalRequest() throws {
        let json = """
        {"model":"my-model","messages":[{"role":"user","content":"hello"}]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)

        #expect(req.model == "my-model")
        #expect(req.temperature == 0.7)
        #expect(req.topP == nil)
        #expect(req.topK == nil)
        #expect(req.maxTokens == nil)
        #expect(req.stream == false)
        #expect(req.stop == nil)
        #expect(req.frequencyPenalty == 0)
        #expect(req.presencePenalty == 0)
        #expect(req.sessionID == nil)
        #expect(req.system == nil)
    }

    @Test("full request decodes all fields")
    func testFullRequest() throws {
        let json = """
        {
            "model": "gpt-mock",
            "messages": [
                {"role": "user", "content": "run tool test"}
            ],
            "temperature": 0.1,
            "top_p": 0.9,
            "top_k": 50,
            "max_tokens": 256,
            "stream": true,
            "stop": ["\\n\\n"],
            "frequency_penalty": 0.5,
            "presence_penalty": 0.3,
            "session_id": "sess-123",
            "system": "You are helpful"
        }
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)

        #expect(req.model == "gpt-mock")
        #expect(req.temperature == 0.1)
        #expect(req.topP == 0.9)
        #expect(req.topK == 50)
        #expect(req.maxTokens == 256)
        #expect(req.stream == true)
        #expect(req.stop?.count == 1)
        #expect(req.frequencyPenalty == 0.5)
        #expect(req.presencePenalty == 0.3)
        #expect(req.sessionID == "sess-123")
        #expect(req.system == "You are helpful")
    }

    // MARK: — Default Overrides

    @Test("missing model defaults to 'default'")
    func testDefaultModel() throws {
        let json = """
        {"messages\":[{"role":"user","content":"hi"}]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.model == "default")
    }

    @Test("messages array decodes role/content correctly")
    func testMessageDecoding() throws {
        let json = """
        {
            "messages": [
                {"role": "system", "content": "be nice"},
                {"role": "user", "content": "hello"},
                {"role": "assistant", "content": "hi there"}
            ]
        }
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.count == 3)
        #expect(req.messages[0].role == "system")
        #expect(req.messages[1].role == "user")
        #expect(req.messages[2].role == "assistant")
    }

    // MARK: — Tool Calling

    @Test("tool definitions decode correctly")
    func testToolDecoding() throws {
        let json = """
        {
            "messages": [{"role":"user","content":"get weather"}],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "description": "Get current weather",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "location": {"type": "string"}
                            },
                            "required": ["location"]
                        }
                    }
                }
            ]
        }
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.tools?.count == 1)
        #expect(req.tools?[0].function.name == "get_weather")
    }

    // MARK: — Failure Cases

    @Test("empty messages array decodes but is semantically invalid")
    func testEmptyMessagesDecodes() throws {
        let json = """
        {"messages": []}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.isEmpty)
        // Semantic validation (non-empty messages) happens in handler, not decoder
    }
}

#endif
