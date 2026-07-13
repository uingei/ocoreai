// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolCallAccumulator behavioral tests — chunk-by-chunk injection aligned
/// with upstream mlx-swift-lm ToolCallProcessor pattern.
///
/// Mirrors `ToolTests.swift`:
///   - processChunk("{\"" → "\"name\"") 逐 chunk 注入
///   - processChunk 中途 malformed JSON 不 crash
///   - processEOS finalize → 解析完整 buffer
///   - null arguments → "{}"
///   - Truncated JSON mid-token split across chunks

import Testing
import Foundation
@testable import ocoreai

// MARK: - Chunk-by-chunk injection (upstream ToolTests pattern)

@Suite("ToolCallAccumulator: chunk-by-chunk injection")
struct AccChunkByChunk {

	@Test("Single chunk with complete JSON tool call array parses on EOS")
	func singleChunkComplete() async {
		var acc = ToolCallAccumulator()
		let full = #" [{"name":"get_weather","arguments":{"city":"Paris"}}] "#
		acc.processChunk(full)
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
		#expect(result[0].function.name == "get_weather")
		#expect(result[0].function.arguments.contains("city"))
		#expect(result[0].function.arguments.contains("Paris"))
	}

	@Test("Three chunks: opening brcket → payload → closing bracket")
	func threeChunkSplit() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(" [")
		acc.processChunk("{\"name\":\"search\",\"arguments\":{\"q\":\"test\"}}")
		acc.processChunk("] ")
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
		#expect(result[0].function.name == "search")
	}

	@Test("Buffer accumulates incrementally across chunks")
	func bufferGrowsIncrementally() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(" [")
		#expect(acc.buffer == " [")
		acc.processChunk("{\"name\":\"calc\"")
		#expect(acc.buffer.contains("calc"))
		#expect(acc.buffer.count > 2)
	}

	@Test("Empty chunks accumulated without affecting result")
	func emptyChunksNoOp() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("")
		acc.processChunk(" [")
		acc.processChunk("")
		acc.processChunk("{\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hi\\\"}\"}")
		acc.processChunk("")
		acc.processChunk("] ")
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
		#expect(result[0].function.name == "echo")
	}

	@Test("Whitespace-only leading/trailing chunks trimmed on EOS")
	func whitespaceTrimming() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("  \n\t  ")
		acc.processChunk(#"[{"name":"ping","arguments":{}}]"#)
		acc.processChunk("  \n  ")
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
	}
}

// MARK: - Malformed recovery (upstream ToolTests pattern)

@Suite("ToolCallAccumulator: malformed intermediate recovery")
struct AccMalformed {

	@Test("Malformed intermediate text does not block EOS — returns nil without crash")
	func malformedThenValid() async {
		var acc = ToolCallAccumulator()
		// First chunk: plain text prefix
		acc.processChunk("Let me check that for you. ")
		// Second chunk: valid array appended — combined buffer is not valid JSON
		acc.processChunk(#"[{"name":"search","arguments":{"q":"doc"}}]"#)
		// Combined: "Let me check... [{"name"...}]" — not valid JSON array → nil
		let result = acc.processEOS()
		#expect(result == nil)
	}

	@Test("Pure plain text returns nil on EOS without crash")
	func plainTextNoCrash() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("Hello, how can I help you today?")
		let result = acc.processEOS()
		#expect(result == nil)
	}

	@Test("Buffer reset after processEOS — second round starts fresh")
	func bufferResetAfterEOS() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(#"[{"name":"a","arguments":{}}]"#)
		_ = acc.processEOS()
		#expect(acc.buffer == "")
		// Second round — empty buffer
		_ = acc.processEOS()
	}

	@Test("Multiple EOS calls on empty buffer — all nil")
	func multipleEOS() async {
		var acc = ToolCallAccumulator()
		#expect(acc.processEOS() == nil)
		#expect(acc.processEOS() == nil)
		#expect(acc.processEOS() == nil)
	}
}

// MARK: - Null arguments (upstream stringifiedEmptyArguments pattern)

@Suite("ToolCallAccumulator: null/special arguments")
struct AccNullArgs {

	@Test("null arguments serialized as {}")
	func nullArguments() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(#"[{"name":"doit","arguments":null}]"#)
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
		#expect(result[0].function.name == "doit")
		#expect(result[0].function.arguments == "{}")
	}

	@Test("String arguments preserved verbatim")
	func stringArguments() async {
		var acc = ToolCallAccumulator()
		// JSON where "arguments" is a pre-stringified value
		let json = "[{\"name\":\"calc\",\"arguments\":\"{\\\"x\\\":1,\\\"y\\\":2}\"}]"
		acc.processChunk(json)
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result[0].function.arguments == "{\"x\":1,\"y\":2}")
	}

	@Test("Object arguments re-serialized to JSON string")
	func objectArguments() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(#"[{"name":"fetch","arguments":{"url":"https://api.test"}}]"#)
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result[0].function.arguments.contains("url"))
		#expect(result[0].function.arguments.contains("api.test"))
	}

	@Test("Mixed batch: valid + null + valid → null becomes {}")
	func mixedBatch() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(#"[{"name":"a","arguments":{}},{"name":"b","arguments":null},{"name":"c","arguments":{"k":1}}]"#)
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 3)
		#expect(result[0].function.arguments == "{}")
		#expect(result[1].function.arguments == "{}")
		#expect(result[2].function.arguments.contains("k"))
	}
}

// MARK: - Truncated JSON split (upstream mid-token split pattern)

@Suite("ToolCallAccumulator: truncated JSON recovery across boundaries")
struct AccTruncated {

	@Test("JSON split mid-token — accumulator reconstructs on EOS")
	func midTokenSplit() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("[{\"name\":\"get_w")
		acc.processChunk("eather\",\"arguments\":")
		acc.processChunk("{\"city\":\"London\"}}]")
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
		#expect(result[0].function.name == "get_weather")
		#expect(result[0].function.arguments.contains("London"))
	}

	@Test("Character-by-character injection")
	func charByChar() async {
		var acc = ToolCallAccumulator()
		let json = #"[{"name":"echo","arguments":{"msg":"hi"}}]"#
		for char in json {
			acc.processChunk(String(char))
		}
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 1)
		#expect(result[0].function.name == "echo")
		#expect(result[0].function.arguments.contains("msg"))
	}

	@Test("Truncated JSON without closing bracket returns nil on EOS")
	func trulyTruncatedReturnsNil() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("[{\"name\":\"calc\" ")
		let result = acc.processEOS()
		#expect(result == nil)
	}

	@Test("Multiple tool calls split across three chunks")
	func multiToolCallSplit() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("[{\"name\":\"t1\",\"arguments\":{}")
		acc.processChunk("},{\"name\":\"t2")
		acc.processChunk("\",\"arguments\":{\"x\":1}}]")
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(result.count == 2)
		#expect(result[0].function.name == "t1")
		#expect(result[1].function.name == "t2")
	}
}

// MARK: - EOS finalize behavior (upstream ToolTests finalize pattern)

@Suite("ToolCallAccumulator: EOS finalize semantics")
struct AccEOS {

	@Test("EOS on empty buffer returns nil")
	func emptyEOS() async {
		var acc = ToolCallAccumulator()
		let result = acc.processEOS()
		#expect(result == nil)
	}

	@Test("EOS discards whitespace without crashing")
	func trimsWhitespace() async {
		var acc = ToolCallAccumulator()
		acc.processChunk("   \n\t  ")
		acc.processEOS()
		#expect(true)  // No crash = pass
	}

	@Test("Tool call IDs generated with call_ prefix")
	func toolCallIdGenerated() async {
		var acc = ToolCallAccumulator()
		acc.processChunk(#"[{"name":"x","arguments":{}}]"#)
		let result = acc.processEOS()
		#expect(result != nil)
		guard let result = result else { return }
		#expect(!result[0].id.isEmpty)
		#expect(result[0].id.hasPrefix("call_"))
		#expect(result[0].type == "function")
	}
}
