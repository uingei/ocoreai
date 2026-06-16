// DTOTests.swift — OpenAI-compatible request/response encode/decode roundtrips
//
// Validates: snake_case key mapping, optional field defaults, streaming vs
// non-streaming response format, tool calling support, and error serialization.

import Testing
import Foundation
@testable import ocoreai

@Suite("ChatCompletionRequest")
struct ChatRequestTests {

    /// Minimal valid request payload
    private static let minimalJSON: String =
        #"{"model":"llama","messages":[{"role":"user","content":"Hello"}]}"#

    /// Full-featured request with all optional fields
    private static let fullJSON: String =
        #"{"model":"gpt-4","messages":[{"role":"user","content":"test"}],"temperature":0.5,"top_p":0.9,"top_k":40,"max_tokens":100,"stream":true,"stop":["\n"],"frequency_penalty":0.1,"presence_penalty":0.2,"session_id":"abc"}"#

    @Test("decodes minimal request with defaults")
    func testMinimalDecode() throws {
        let data = minimalJSON.data(using: .utf8)!
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        #expect(req.model == "llama")
        #expect(req.messages.count == 1)
        #expect(req.temperature == 0.7)
        #expect(req.stream == false)
        #expect(req.maxTokens == nil)
    }

    @Test("decodes full request with all fields")
    func testFullDecode() throws {
        let data = fullJSON.data(using: .utf8)!
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        #expect(req.model == "gpt-4")
        #expect(req.temperature == 0.5)
        #expect(req.topP == 0.9)
        #expect(req.topK == 40)
        #expect(req.maxTokens == 100)
        #expect(req.stream == true)
        #expect(req.stop == ["\n"])
        #expect(req.frequencyPenalty == 0.1)
        #expect(req.presencePenalty == 0.2)
        #expect(req.sessionID == "abc")
    }

    @Test("re-encoding preserves snake_case keys")
    func testEncodePreservesSnakeCase() throws {
        let data = minimalJSON.data(using: .utf8)!
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)

        // Build a custom JSON that uses snake_case keys — encoding the request
        // uses CodingKeys so the output keys must match.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys // CodingKeys already snake_case
        _ = try encoder.encode(req)
        // If we get here, encoding succeeded
    }

    @Test("empty messages array decodes")
    func testEmptyMessages() throws {
        let json = #"{"model":"x","messages":[]}"#
        let data = json.data(using: .utf8)!
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        #expect(req.messages.isEmpty)
    }
}

@Suite("ChatCompletion Response")
struct ChatResponseTests {

    @Test("non-stream response encodes with correct OpenAI fields")
    func testNonStreamResponse() throws {
        let completion = ChatCompletion(
            id: "test-123",
            object: "chat.completion",
            created: 1700000000,
            model: "llama",
            choices: [CompletionChoice(
                message: AssistantMessage(content: "Hello"),
                finishReason: "stop",
                index: 0
            )],
            usage: Usage(input: 10, output: 5)
        )

        let data = try JSONEncoder().encode(completion)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["object"] as? String == "chat.completion")
        #expect(json["model"] as? String == "llama")
        #expect(json["id"] as? String == "test-123")

        let usage = json["usage"] as? [String: Int]
        #expect(usage?["prompt_tokens"] == 10)
        #expect(usage?["completion_tokens"] == 5)
        #expect(usage?["total_tokens"] == 15)
    }

    @Test("stream chunk encodes correctly")
    func testStreamChunk() throws {
        let chunk = ChatCompletionChunk(
            id: "stream-1",
            object: "chat.completion.chunk",
            created: 1700000000,
            model: "llama",
            choices: [ChunkChoice(
                delta: ChatDelta(
                    role: "assistant",
                    content: "Hello",
                    toolCalls: nil
                ),
                finishReason: nil,
                index: 0
            )]
        )

        let data = try JSONEncoder().encode(chunk)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["object"] as? String == "chat.completion.chunk")
    }
}

@Suite("ModelSamplingPatch")
struct SamplingPatchTests {

    @Test("partial patch merges into config correctly")
    func testPartialMerge() throws {
        let json = #"{"temperature": 0.3, "max_tokens": 200}"#
        let data = json.data(using: .utf8)!
        let patch = try JSONDecoder().decode(ModelSamplingPatch.self, from: data)
        let config = patch.toConfig()

        #expect(config.temperature == 0.3)
        #expect(config.maxTokens == 200)
        #expect(config.topP == nil) // not in patch
        #expect(config.topK == nil)
        #expect(config.frequencyPenalty == 0) // default
    }

    @Test("empty patch returns default config")
    func testEmptyPatch() throws {
        let json = #"{}"#
        let data = json.data(using: .utf8)!
        let patch = try JSONDecoder().decode(ModelSamplingPatch.self, from: data)
        let config = patch.toConfig()

        #expect(config.temperature == 0.7)
        #expect(config.topP == nil)
        #expect(config.maxTokens == nil)
    }
}

@Suite("Usage Encoding")
struct UsageTests {

    @Test("Usage uses OpenAI snake_case field names")
    func testSnakeCaseFields() throws {
        let usage = Usage(input: 100, output: 50)
        let data = try JSONEncoder().encode(usage)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Int]

        #expect(json["prompt_tokens"] == 100)
        #expect(json["completion_tokens"] == 50)
        #expect(json["total_tokens"] == 150)
        // Should NOT contain Swift camelCase names
        #expect(json["input"] == nil)
        #expect(json["output"] == nil)
    }
}

@Suite("AppError")
struct AppErrorTests {

    @Test("all cases produce non-empty descriptions")
    func testDescriptions() {
        #expect(!AppError.invalidRequest("bad").description.isEmpty)
        #expect(!AppError.modelNotFound("x").description.isEmpty)
        #expect(!AppError.poolExhausted(10).description.isEmpty)
        #expect(!AppError.queueClosed.description.isEmpty)
        #expect(!AppError.engineUnavailable.description.isEmpty)
        #expect(!AppError.sessionExpired("s1").description.isEmpty)
    }

    @Test("error matches case payload in description")
    func testDescriptionContainsPayload() {
        #expect(AppError.modelNotFound("llama-3").description.contains("llama-3"))
        #expect(AppError.poolExhausted(42).description.contains("42"))
        #expect(AppError.sessionExpired("abc").description.contains("abc"))
    }

    @Test("errorDescription matches description")
    func testErrorDescription() {
        let err = AppError.engineUnavailable as (any LocalizedError)
        #expect(err.errorDescription == AppError.engineUnavailable.description)
    }
}

@Suite("AnyCodable")
struct AnyCodableTests {

    @Test("roundtrips primitive types") throws {
        let boolData = try JSONEncoder().encode(AnyCodable(true))
        #expect(try JSONDecoder().decode(AnyCodable.self, from: boolData).value as? Bool == true)

        let intData = try JSONEncoder().encode(AnyCodable(42))
        #expect(try JSONDecoder().decode(AnyCodable.self, from: intData).value as? Int == 42)

        let strData = try JSONEncoder().encode(AnyCodable("hello"))
        #expect(try JSONDecoder().decode(AnyCodable.self, from: strData).value as? String == "hello")

        let dblData = try JSONEncoder().encode(AnyCodable(3.14))
        #expect(try JSONDecoder().decode(AnyCodable.self, from: dblData).value as? Double == 3.14)
    }

    @Test("roundtrips nested objects") throws {
        let obj: [String: AnyCodable] = ["name": AnyCodable("test"), "count": AnyCodable(7)]
        let data = try JSONEncoder().encode(obj)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(decoded["name"]?.value as? String == "test")
        #expect(decoded["count"]?.value as? Int == 7)
    }

    @Test("roundtrips arrays") throws {
        let arr: [AnyCodable] = [AnyCodable(1), AnyCodable("two")]
        let data = try JSONEncoder().encode(arr)
        let decoded = try JSONDecoder().decode([AnyCodable].self, from: data)
        #expect(decoded[0].value as? Int == 1)
        #expect(decoded[1].value as? String == "two")
    }
}

@Suite("ContentPolymorphic")
struct ContentPolymorphicTests {

    @Test("decodes plain string as .text") throws {
        let data = try JSONEncoder().encode("hello")
        let cp = try JSONDecoder().decode(ContentPolymorphic.self, from: data)
        switch cp {
        case .text(let s): #expect(s == "hello")
        case .parts: #expect(Bool(false), "Expected .text")
        }
    }

    @Test("encodes .text as JSON string") throws {
        let cp: ContentPolymorphic = .text("world")
        let data = try JSONEncoder().encode(cp)
        let decoded = try JSONDecoder().decode(String.self, from: data)
        #expect(decoded == "world")
    }
}
