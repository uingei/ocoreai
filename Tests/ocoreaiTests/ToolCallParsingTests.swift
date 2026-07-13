// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolCallParsingTests.swift — L2 behavioral invariants for parseToolCalls
///
/// Methodology: upstream ToolTests (1163 lines) verify chunk accumulation.
/// We verify the actual parseToolCalls function used by ChatHandler + AgentLoop.
///
/// Key risk area: false negatives (tool calls not detected → model loops)
/// and false positives (plain text misinterpreted as tool calls).
///
/// Removed: ToolDef DTO round-trip, ContentPolymorphic decoding, contentToString
/// extraction, ID format checks, whitespace trimming (all DTO-level hygiene).

import Testing
@testable import ocoreai

// MARK: - Helpers

private func jsonToolCalls(_ entries: [[String: Any]]) -> String {
    // Build valid JSON manually to avoid raw-string escaping issues
    var items: [String] = []
    for entry in entries {
        let name = (entry["name"] as! String)
        let args = entry["arguments"] as! String
        items.append("{\"name\":\"\(name)\",\"arguments\":\(args)}")
    }
    return "[\(items.joined(separator: ","))]"
}

// MARK: - L2: Core detection — must detect tool calls to break agent loops

@Suite("parseToolCalls: detection correctness")
struct ToolCallDetectionTests {

    @Test("Single tool call in JSON array is detected")
    func singleToolCall() {
        let content = jsonToolCalls([
            ["name": "get_weather", "arguments": "{\"location\":\"SF\"}"]
        ])
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 1)
        #expect(result?[0].function.name == "get_weather")
    }

    @Test("Multiple parallel tool calls detected")
    func multipleToolCalls() {
        let content = jsonToolCalls([
            ["name": "get_weather", "arguments": "{\"location\":\"SF\"}"],
            ["name": "get_weather", "arguments": "{\"location\":\"NYC\"}"]
        ])
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 2)
    }

    @Test("Tool call with complex nested arguments preserved")
    func complexArguments() {
        let content = jsonToolCalls([
            ["name": "search", "arguments": "{\"query\":\"swift testing\",\"limit\":10}"]
        ])
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?[0].function.name == "search")
        #expect(result?[0].function.arguments.contains("swift") == true)
    }

    @Test("Tool call with unicode in arguments is detected")
    func unicodeArguments() throws {
        let content = try String(data:
            "[{\"name\":\"search\",\"arguments\":{\"query\":\"Swift 测试\"}}]"
            .data(using: .utf8)!, encoding: .utf8)!
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 1)
    }

    @Test("Tool call with whitespace around JSON is detected")
    func whitespaceAroundJson() {
        let payload = jsonToolCalls([
            ["name": "ping", "arguments": "{}"]
        ])
        let content = "\r\n\(payload)\r\n"
        let result = parseToolCalls(from: content)
        #expect(result != nil)
    }

    @Test("Large number of tool calls handled correctly (20 calls)")
    func manyToolCalls() {
        let entries: [[String: Any]] = (0..<20).map { i in
            ["name": "tool_\(i)", "arguments": "{}"]
        }
        let content = jsonToolCalls(entries)
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 20)
    }

    @Test("Arguments passed as dict are re-serialized")
    func dictArguments() throws {
        // Test the code path where arguments is a dict, not a string
        let content = """
        [{"name":"execute","arguments":{"cmd":"ls","flags":["-la","-h"]}}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?.count == 1)
        #expect(result?[0].function.name == "execute")
        let args = result?[0].function.arguments ?? ""
        #expect(args.contains("cmd"))
        #expect(args.contains("ls"))
    }

    @Test("Tool call with empty arguments object parses correctly")
    func emptyArguments() {
        let content = jsonToolCalls([
            ["name": "ping", "arguments": "{}"]
        ])
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?[0].function.name == "ping")
        #expect(result?[0].function.arguments == "{}")
    }

    @Test("Tool call with null arguments defaults to {}")
    func nullArguments() throws {
        let content = """
        [{"name":"ping","arguments":null}]
        """
        let result = parseToolCalls(from: content)
        #expect(result != nil)
        #expect(result?[0].function.arguments == "{}")
    }
}

// MARK: - L2: False negative prevention — missing fields must NOT be detected

@Suite("parseToolCalls: safe rejection of invalid payloads")
struct ToolCallSafeRejectionTests {

    @Test("Plain text returns nil — no crash")
    func plainTextSafe() {
        #expect(parseToolCalls(from: "The weather in SF is sunny today.") == nil)
    }

    @Test("Malformed JSON returns nil — no crash")
    func malformedJsonSafe() {
        #expect(parseToolCalls(from: "[{name: broken}]") == nil)
    }

    @Test("Tool call with missing 'name' field silently skipped → nil")
    func missingNameSkipped() {
        let content = """
        [{"arguments": {"location": "SF"}}]
        """
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("Tool call with missing 'arguments' field silently skipped → nil")
    func missingArgsSkipped() {
        let content = """
        [{"name": "get_weather"}]
        """
        #expect(parseToolCalls(from: content) == nil)
    }

    @Test("JSON array of non-dict items returns nil")
    func arrayStringItemsNil() {
        #expect(parseToolCalls(from: #"""["get_weather", "search"]"""#) == nil)
    }

    @Test("Empty content returns nil")
    func emptyContent() {
        #expect(parseToolCalls(from: "") == nil)
    }

    @Test("Code block with JSON-like tool content NOT misdetected")
    func codeBlockNotDetected() {
        let content = """
        ```json
        {"name": "get_weather", "arguments": {"location": "SF"}}
        ```
        """
        #expect(parseToolCalls(from: content) == nil)
    }
}