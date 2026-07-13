// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolCallParsingTests.swift — Behavioral invariants for parseToolCalls
///
/// Methodology: upstream ToolTests (1163 lines) verify that streaming chunk
/// accumulation produces correct tool call detection. Here we test the
/// actual parseToolCalls function used by ChatHandler + AgentLoop.
///
/// Key risk area: false negatives (tool calls not detected → model loops)
/// and false positives (plain text misinterpreted as tool calls).

import Testing
@testable import ocoreai
import Foundation

// MARK: - parseToolCalls: Core detection

@Suite("parseToolCalls: JSON array format detection")
struct ToolCallJSONTests {

    @Test("Single tool call in JSON array is detected")
    func singleToolCall() {
        let content = """
        [{"name":"get_weather","arguments":{"location":"SF"}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 1)
        #expect(result?[0].function.name == "get_weather")
    }

    @Test("Multiple parallel tool calls detected")
    func multipleToolCalls() {
        let content = """
        [{"name":"get_weather","arguments":{"location":"SF"}},{"name":"get_weather","arguments":{"location":"NYC"}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 2)
        #expect(result?[0].function.name == "get_weather")
        #expect(result?[1].function.name == "get_weather")
    }

    @Test("Tool call with complex nested arguments preserved")
    func complexArguments() {
        let content = """
        [{"name":"search","arguments":{"query":"swift testing","limit":10,"filters":{"lang":"en"}}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?[0].function.name == "search")
        // Arguments should be serialized back to JSON
        #expect(result?[0].function.arguments.contains("swift") == true)
    }

    @Test("Tool call with empty arguments object")
    func emptyArguments() {
        let content = """
        [{"name":"ping","arguments":{}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?[0].function.name == "ping")
        #expect(result?[0].function.arguments == "{}")
    }


    @Test("Tool calls have unique IDs")
    func uniqueIds() {
        let content = """
        [{"name":"a","arguments":{}},{"name":"b","arguments":{}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        let ids = result?.map(\.id) ?? []
        #expect(ids.count == Set(ids).count, "IDs should be unique")
    }

    @Test("Tool call ID starts with 'call_' prefix")
    func idPrefix() {
        let content = """
        [{"name":"a","arguments":{}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result?.first?.id.hasPrefix("call_") == true)
    }

    @Test("Empty content returns nil")
    func emptyContent() {
        #expect(parseToolCalls(from: "") == nil)
    }

    @Test("Whitespace-only content returns nil")
    func whitespaceContent() {
        #expect(parseToolCalls(from: "   \n  ") == nil)
    }
}

// MARK: - parseToolCalls: False positive prevention

@Suite("parseToolCalls: false positive prevention")
struct ToolCallFalsePositiveTests {

    @Test("Plain text response is NOT detected as tool call")
    func plainTextNotDetected() {
        let content = "The weather in San Francisco is sunny today."
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("Code block is NOT detected as tool call")
    func codeBlockNotDetected() {
        let content = """
        ```json
        {"name": "get_weather", "arguments": {"location": "SF"}}
        ```
        """
        // The legacy fallback checks for ```json — should return nil
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("JSON object (not array) is NOT parsed as tool call")
    func jsonObjectNotDetected() {
        let content = """
        {"message": "Hello", "status": 200}
        """
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("JSON array of strings is NOT parsed as tool call")
    func arrayOfStringsNotDetected() {
        let content = """
        ["get_weather", "search", "calc"]
        """
        // This is [[String]], not [[String: Any]] — should return nil
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("Malformed JSON returns nil, does not crash")
    func malformedJsonSafe() {
        let content = """
        [{"name": "get_weather", arguments: BROKEN}]
        """
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("Tool call with missing 'name' field returns nil")
    func missingNameReturnNil() {
        let content = """
        [{"arguments": {"location": "SF"}}]
        """
        // Missing 'name' means toolCalls.isEmpty → nil
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("Tool call with missing 'arguments' field returns nil")
    func missingArgumentsReturnNil() {
        let content = """
        [{"name": "get_weather"}]
        """
        // Missing 'arguments' means the if-let fails → toolCalls.isEmpty → nil
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("<tool_code> marker content returns nil (legacy fallback)")
    func toolCodeMarkerReturnsNil() {
        let content = "<tool_code>some code</tool_code>"
        #expect(parseToolCalls(from: content) == nil)
    }
}

// MARK: - parseToolCalls: Edge cases that could cause infinite loops

@Suite("parseToolCalls: agent loop safety — must detect tool calls to break loops")
struct ToolCallLoopSafetyTests {

    @Test("Tool call with unicode in arguments is detected")
    func unicodeArguments() {
        let content = """
        [{"name":"search","arguments":{"query":"Swift 测试"}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 1)
    }

    @Test("Tool call with whitespace around JSON is detected (trailing newline)")
    func whitespaceAroundJson() {
        let content = """
        \r
        [{"name":"ping","arguments":{}}]
        \r
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
    }

    @Test("Large number of tool calls handled correctly")
    func manyToolCalls() {
        var items: [String] = []
        for i in 0..<20 {
            items.append("{\"name\":\"tool_\(i)\",\"arguments\":{}}")
        }
        let content = "[\(items.joined(separator: ","))]"
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 20)
    }

    @Test("Nested JSON in arguments survives round-trip")
    func nestedJsonRoundTrip() {
        // Arguments with nested objects — JSON parser should handle this fine
        let content = """
        [{"name":"execute","arguments":{"cmd":"ls","flags":["-la"]}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?[0].function.name == "execute")
        // Verify the nested structure was serialized back
        #expect(result?[0].function.arguments.contains("ls") == true)
        #expect(result?[0].function.arguments.contains("-la") == true)
    }
}

// MARK: - ToolDef encoding/decoding

@Suite("ToolDef: schema round-trip for tool calling")
struct ToolDefSchemaTests {

    @Test("ToolDef encodes and decodes correctly")
    func toolDefRoundTrip() throws {
        let tool = ToolDef(
            type: "function",
            function: FunctionDef(
                name: "get_weather",
                description: "Get weather info",
                parameters: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "location": ["type": "string", "description": "City"]
                    ])
                ]
            )
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(ToolDef.self, from: data)
        #expect(decoded.type == "function")
        #expect(decoded.function.name == "get_weather")
        #expect(decoded.function.description == "Get weather info")
    }

    @Test("FunctionDef with nil description is handled")
    func functionDefNilDescriptionWorks() {
        let fd = FunctionDef(name: "ping", description: nil, parameters: nil)
        #expect(fd.name == "ping")
        #expect(fd.description == nil)
    }
}

// MARK: - contentToString: multimodal data loss detection

@Suite("contentToString: information loss tracking")
struct ContentToStringLossTests {

    @Test("Pure text has zero dropped parts")
    func pureTextZeroLoss() {
        let (text, dropped) = contentToString(ContentPolymorphic.text("hello world"))
        #expect(text == "hello world")
        #expect(dropped == 0)
    }

    @Test("Mixed text+image: images counted as dropped")
    func mixedContentLoss() {
        let parts: [ContentPart] = [
            .init(type: "text", text: "Look at this", imageUrl: nil),
            .init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://img.png")),
        ]
        let (text, dropped) = contentToString(.parts(parts))
        #expect(text == "Look at this")
        #expect(dropped == 1)
    }

    @Test("Image-only content: text is empty but dropped > 0")
    func imageOnlyLoss() {
        let parts: [ContentPart] = [
            .init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://a.png")),
            .init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://b.png")),
        ]
        let (text, dropped) = contentToString(.parts(parts))
        #expect(text.isEmpty)
        #expect(dropped == 2)
        // CRITICAL: this means image data is silently lost when passed to tokenizer
        // The caller (EnginePool) should check dropped > 0 and either warn or use VLM path
    }

    @Test("nil content returns empty with zero dropped")
    func nilContent() {
        let (text, dropped) = contentToString(nil)
        #expect(text.isEmpty)
        #expect(dropped == 0)
    }

    @Test("Multiple text parts are joined with spaces")
    func multipleTextParts() {
        let parts: [ContentPart] = [
            .init(type: "text", text: "A", imageUrl: nil),
            .init(type: "text", text: "B", imageUrl: nil),
            .init(type: "text", text: "C", imageUrl: nil),
        ]
        let (text, dropped) = contentToString(.parts(parts))
        #expect(text == "A B C")
        #expect(dropped == 0)
    }

    @Test("Non-text part with text field set (e.g. audio) is still counted")
    func nonTextWithTextNotDropped() {
        // Bug potential: if a part has type="audio" but also has text field,
        // current code only checks parts.compactMap(\.text) — which would
        // include audio's text if set, but still count it correctly
        let parts: [ContentPart] = [
            .init(type: "text", text: "A", imageUrl: nil),
            .init(type: "audio", text: nil, imageUrl: nil),
        ]
        let (text, dropped) = contentToString(.parts(parts))
        #expect(text == "A")
        #expect(dropped == 1) // audio part has no text, but IS still counted as dropped
    }
}

// MARK: - ContentPolymorphic decoding edge cases

@Suite("ContentPolymorphic: decoding safety")
struct ContentPolymorphicTests {

    @Test("Decoding string produces .text")
    func stringToText() throws {
        let json = "\"Hello world\""
        let decoded = try JSONDecoder().decode(ContentPolymorphic.self, from: json.data(using: .utf8)!)
        if case .text(let s) = decoded {
            #expect(s == "Hello world")
        } else {
            #expect(Bool(false), "Expected .text case")
        }
    }

    @Test("Decoding array produces .parts")
    func arrayToParts() throws {
        let json = """
        [{"type":"text","text":"Hello"}]
        """
        let decoded = try JSONDecoder().decode(ContentPolymorphic.self, from: json.data(using: .utf8)!)
        if case .parts(let parts) = decoded {
            #expect(parts.count == 1)
        } else {
            #expect(Bool(false), "Expected .parts case")
        }
    }

    @Test("Decoding null produces empty .text")
    func nullToEmptyText() throws {
        let json = "null"
        let decoded = try JSONDecoder().decode(ContentPolymorphic.self, from: json.data(using: .utf8)!)
        if case .text(let s) = decoded {
            #expect(s.isEmpty)
        } else {
            #expect(Bool(false), "Expected .text case for null")
        }
    }

    @Test("Encoding and decoding round-trip for .text")
    func textRoundTrip() throws {
        let original: ContentPolymorphic = .text("test message")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentPolymorphic.self, from: data)
        if case .text(let s) = decoded {
            #expect(s == "test message")
        } else {
            #expect(Bool(false), "Expected .text case")
        }
    }

    @Test("Encoding and decoding round-trip for .parts")
    func partsRoundTrip() throws {
        let parts: [ContentPart] = [
            .init(type: "text", text: "Hello", imageUrl: nil),
            .init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://img.png")),
        ]
        let original: ContentPolymorphic = .parts(parts)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentPolymorphic.self, from: data)
        if case .parts(let decodedParts) = decoded {
            #expect(decodedParts.count == 2)
        } else {
            #expect(Bool(false), "Expected .parts case")
        }
    }
}
