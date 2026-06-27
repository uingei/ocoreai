// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatHandlerTests.swift — Request/response model validation for chat completions.
///
/// Coverage (DTO layer — inference requires GPU which CI lacks):
/// - ChatCompletionRequest decoding: minimal, full params, sampling, session, system, tool calls
/// - Message / AssistantMessage / ToolCall roundtrip
/// - Usage encoding: snake_case keys (prompt_tokens, completion_tokens, total_tokens)
/// - ChatCompletion response encoding
/// - CountTokens request/response encoding
/// - AnthropicMessageRequest decoding: system, stream, tools, content blocks
/// - ModelSamplingPatch partial/full overrides

import Foundation
import Testing
@testable import ocoreai

// MARK: - OpenAI Chat Completion Request

@Suite("ChatCompletionRequest decoding")
struct ChatRequestTests {
    
    @Test("minimal valid request")
    func minimalRequest() throws {
        let json = #"{"model":"llama3-8b","messages":[{"role":"user","content":"Hello"}]}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.model == "llama3-8b")
        #expect(req.messages.count == 1)
        #expect(req.temperature == 0.7)
        #expect(!req.stream)
    }
    
    @Test("model defaults to 'default' when omitted")
    func modelDefault() throws {
        let json = #"{"messages":[{"role":"user","content":"Hi"}]}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.model == "default")
    }
    
    @Test("all sampling parameters decoded with snake_case keys")
    func fullSamplingParams() throws {
        let json = """
        {"model":"llama3-8b","messages":[{"role":"user","content":"test"}],
         "temperature":0.1,"top_p":0.9,"top_k":50,"max_tokens":256,
         "frequency_penalty":0.5,"presence_penalty":0.3,
         "stop":["END","\\n\\n"],"stream":true}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.temperature == 0.1)
        #expect(req.topP == 0.9)
        #expect(req.topK == 50)
        #expect(req.maxTokens == 256)
        #expect(req.frequencyPenalty == 0.5)
        #expect(req.presencePenalty == 0.3)
        #expect(req.stop == ["END", "\n\n"])
        #expect(req.stream == true)
    }
    
    @Test("session_id preserved from request")
    func sessionIDDecoded() throws {
        let json = #"{"model":"llama3-8b","messages":[{"role":"user","content":"hello"}],"session_id":"abc-123"}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.sessionID == "abc-123")
    }
    
    @Test("system prompt from request body")
    func systemPromptDecoded() throws {
        let json = #"{"model":"llama3-8b","messages":[{"role":"user","content":"hi"}],"system":"You are helpful."}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.system == "You are helpful.")
    }
    
    @Test("multi-turn: system + user + assistant")
    func multiTurnMessages() throws {
        let json = """
        {"model":"llama3-8b","messages":[
          {"role":"system","content":"Be concise."},
          {"role":"user","content":"What is 2+2?"},
          {"role":"assistant","content":"4"}
        ]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.count == 3)
        #expect(req.messages[0].role == "system")
        #expect(req.messages[1].role == "user")
        #expect(req.messages[2].role == "assistant")
    }
    
    @Test("assistant message with single tool call")
    func toolCallDecoded() throws {
        let json = """
        {"model":"llama3-8b","messages":[
          {"role":"user","content":"Search docs"},
          {"role":"assistant","content":null,"toolCalls":[
            {"id":"call_1","type":"function","function":{"name":"search","arguments":"{\\"q\\":\\"docs\\"}"}}
          ]}
        ]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.count == 2)
        #expect(req.messages[1].toolCalls?.count == 1)
        #expect(req.messages[1].toolCalls?[0].id == "call_1")
        #expect(req.messages[1].toolCalls?[0].function.name == "search")
    }
    
    @Test("tool role message with toolCallID")
    func toolRoleMessage() throws {
        let json = #"{"model":"llama3-8b","messages":[{"role":"tool","content":"Result: foo","toolCallID":"call_1"}]}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages[0].role == "tool")
        #expect(req.messages[0].toolCallID == "call_1")
    }
    
    @Test("multiple parallel tool calls")
    func parallelToolCalls() throws {
        let json = """
        {"model":"llama3-8b","messages":[
          {"role":"user","content":"Do both"},
          {"role":"assistant","content":null,"toolCalls":[
            {"id":"call_1","type":"function","function":{"name":"search","arguments":"{}"}},
            {"id":"call_2","type":"function","function":{"name":"calc","arguments":"{\\"expr\\":\\"2+2\\"}"}}
          ]}
        ]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages[1].toolCalls?.count == 2)
    }
    
    @Test("parallel_tool_calls flag parsed")
    func parallelToolCallsFlag() throws {
        let json = #"{"model":"llama3-8b","messages":[{"role":"user","content":"test"}],"parallel_tool_calls":false}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json.data(using: .utf8)!)
        #expect(req.parallelToolCalls == false)
    }
    
    @Test("Message(role:content:) constructor")
    func messageConstructor() throws {
        let msg = Message(role: "user", content: "Hello world")
        #expect(msg.role == "user")
        #expect(msg.name == nil)
        #expect(msg.toolCalls == nil)
        #expect(msg.toolCallID == nil)
    }
}

// MARK: - OpenAI Response Models

@Suite("ChatCompletion response encoding")
struct ChatResponseTests {
    
    @Test("Usage encodes with OpenAI snake_case keys")
    func usageEncoding() throws {
        let usage = Usage(input: 10, output: 25)
        #expect(usage.total == 35)
        let data = try JSONEncoder().encode(usage)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("prompt_tokens"))
        #expect(json.contains("completion_tokens"))
        #expect(json.contains("total_tokens"))
    }
    
    @Test("ChatCompletion encodes all fields")
    func responseEncoding() throws {
        let response = ChatCompletion(
            id: "chatcmpl-123",
            created: 1718000000,
            model: "llama3-8b",
            choices: [
                CompletionChoice(
                    message: AssistantMessage(content: "Hello!"),
                    finishReason: "stop"
                )
            ],
            usage: Usage(input: 5, output: 10)
        )
        let data = try JSONEncoder().encode(response)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("chatcmpl-123"))
        #expect(json.contains("llama3-8b"))
        #expect(json.contains("stop"))
    }
    
    @Test("AssistantMessage with tool calls encodes")
    func assistantMessageWithToolCalls() throws {
        let tc = ToolCall(id: "call_x", function: ToolCallFunction(name: "search", arguments: "{}"))
        let msg = AssistantMessage(content: "Searching...", toolCalls: [tc])
        #expect(msg.content == "Searching...")
        #expect(msg.toolCalls?.count == 1)
        let data = try JSONEncoder().encode(msg)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("toolCalls"))
        #expect(json.contains("call_x"))
    }
}

// MARK: - Count Tokens

@Suite("CountTokens request/response")
struct CountTokensTests {
    
    @Test("CountTokensRequest decodes")
    func countTokensRequest() throws {
        let json = #"{"model":"test","prompt":"Hello world"}"#
        let req = try JSONDecoder().decode(CountTokensRequest.self, from: json.data(using: .utf8)!)
        #expect(req.model == "test")
        #expect(req.prompt == "Hello world")
    }
    
    @Test("CountTokensResponse encodes tokenCount as prompt_tokens")
    func countTokensResponse() throws {
        let resp = CountTokensResponse(model: "test", tokenCount: 42)
        let data = try JSONEncoder().encode(resp)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("prompt_tokens"))
        #expect(json.contains("42"))
    }
}

// MARK: - Anthropic Message Request

@Suite("AnthropicMessageRequest decoding")
struct AnthropicMessageRequestTests {
    
    @Test("minimal valid Anthropic request")
    func minimal() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"Hello"}],"max_tokens":100,"stream":false}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.model == "claude-3-haiku")
        #expect(req.messages.count == 1)
        #expect(req.maxTokens == 100)
        #expect(!req.stream)
    }
    
    @Test("system prompt as top-level field")
    func systemPrompt() throws {
        let json = """
        {"model":"claude-3-haiku","system":"You are helpful.",
         "messages":[{"role":"user","content":"Hi"}],"max_tokens":50,"stream":false}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.system == "You are helpful.")
    }
    
    @Test("streaming enabled")
    func stream() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"Hi"}],
         "max_tokens":50,"stream":true}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.stream == true)
    }
    
    @Test("tools array parsed")
    func tools() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"Search"}],
         "max_tokens":50,"stream":false,
         "tools":[{"name":"search","description":"Search docs",
                   "input_schema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}}]}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.tools?.count == 1)
    }
    
    @Test("text content decodes as string variant")
    func textContent() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"plain text"}],
         "max_tokens":50,"stream":false}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.messages.count == 1)
    }
    
    @Test("stop_sequences parsed with snake_case key")
    func stopSequences() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"Hi"}],
         "max_tokens":50,"stop_sequences":["END","STOP"],"stream":false}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.stopSequences == ["END", "STOP"])
    }
    
    @Test("temperature and top_p parsed")
    func samplingParams() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"Hi"}],
         "max_tokens":50,"temperature":0.5,"top_p":0.9,"stream":false}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.temperature == 0.5)
        #expect(req.topP == 0.9)
    }
    
    @Test("thinking config optional")
    func thinkingConfig() throws {
        let json = """
        {"model":"claude-3-haiku","messages":[{"role":"user","content":"Hi"}],
         "max_tokens":50,"thinking":{"type":"enabled","budget_tokens":1024},"stream":false}
        """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: json.data(using: .utf8)!)
        #expect(req.thinking != nil)
    }
}

// MARK: - ModelSampling config

@Suite("ModelSamplingPatch")
struct SamplingPatchTests {
    
    @Test("partial temperature-only override")
    func partial() throws {
        let json = #"{"temperature":0.3}"#
        let patch = try JSONDecoder().decode(ModelSamplingPatch.self, from: json.data(using: .utf8)!)
        #expect(patch.temperature == 0.3)
        #expect(patch.topP == nil)
    }
    
    @Test("all fields override")
    func full() throws {
        let json = """
        {"temperature":0.1,"top_p":0.9,"max_tokens":128,
         "frequency_penalty":0.2,"presence_penalty":0.1}
        """
        let patch = try JSONDecoder().decode(ModelSamplingPatch.self, from: json.data(using: .utf8)!)
        #expect(patch.temperature == 0.1)
        #expect(patch.topP == 0.9)
        #expect(patch.maxTokens == 128)
    }
}

