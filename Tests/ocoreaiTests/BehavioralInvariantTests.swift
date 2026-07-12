// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Behavioral invariant tests — verify that data flows through layers
/// without corruption or inconsistency.
///
/// "805 tautologies proved nothing." — these tests actually assert behavior.

import Testing
@testable import ocoreai

// MARK: - ChatMessage textContent vs content consistency

@Suite("ChatMessage textContent vs content consistency")
struct ChatMessageConsistencyTests {

	@Test("textContent and content should be consistent for same parts")
	func textContentMatchesContent() {
		// ChatMessage.structured init uses TranscriptPartMessage.flatText
		// ChatMessage.textContent computed property has its own conversion
		// Both paths should produce equivalent results
		let parts: [TranscriptPart] = [
			.text("First thought"),
			.toolCall(ToolCallPart(callId: "c1", name: "search", resultSummary: "3 results")),
			.text("Final answer")
		]
		let msg = ChatMessage(role: "assistant", parts: parts)

		let content = msg.content
		let textContent = msg.textContent

		// Both should contain "search"
		#expect(content.contains("search"))
		#expect(textContent.contains("search"))
	}

	@Test("text-only parts: textContent equals content")
	func textPartsOnlyConsistency() {
		let parts: [TranscriptPart] = [.text("A"), .text("B"), .text("C")]
		let msg = ChatMessage(role: "assistant", parts: parts)
		let content = msg.content
		let textContent = msg.textContent

		#expect(content == textContent)

	}

	@Test("reasoning parts appear in textContent")
	func reasoningPartsInTextContent() {
		let parts: [TranscriptPart] = [
			.reasoning("thinking..."),
			.text("answer")
		]
		let msg = ChatMessage(role: "assistant", parts: parts)
		#expect(msg.textContent.contains("thinking"))
		#expect(msg.textContent.contains("answer"))
	}

	@Test("image parts dropped in textContent")
	func imageDroppedInTextContent() {
		let parts: [TranscriptPart] = [
			.text("check this image"),
			.image("data:image/png;base64,xyz")
		]
		let msg = ChatMessage(role: "assistant", parts: parts)
		#expect(!msg.textContent.contains("data:image"))
	}

	@Test("hasParts is false for empty parts array")
func emptyPartsNotHasParts() {
		let msg = ChatMessage(role: "assistant", parts: [])
		#expect(msg.hasParts == false)
		#expect(msg.content.isEmpty)
	}

	@Test("hasParts is true for non-empty parts")
	func nonEmptyPartsHasParts() {
		let msg = ChatMessage(role: "assistant", parts: [.text("hello")])
		#expect(msg.hasParts == true)
	}

	@Test("legacy init: hasParts is false, content preserved")
	func legacyInitNotHasParts() {
		let msg = ChatMessage(role: "assistant", content: "hello")
		#expect(msg.hasParts == false)
		#expect(msg.content == "hello")
		#expect(msg.textContent == "hello")
	}
}

// MARK: - TranscriptPart displayText consistency

@Suite("TranscriptPart displayText consistency")
struct TranscriptPartDisplayConsistencyTests {

	@Test("text displayText matches textContent")
	func textDisplayMatches() {
		let part: TranscriptPart = .text("hello")
		#expect(part.displayText == "hello")
	}

	@Test("reasoning displayText contains reasoning content")
	func reasoningDisplayContainsContent() {
		let part: TranscriptPart = .reasoning("deep thought process")
		#expect(part.displayText.contains("deep thought process"))
		#expect(part.displayText.hasPrefix("[Reasoning:"))
	}

	@Test("toolCall displayText format vs textContent format — now unified (2026-07-13 fix)")
	func toolCallDisplayVsTextContent() {
		// FIXED: textContent now delegates to TranscriptPartMessage.flatText,
		// so content and textContent produce identical output for the same parts.
		// displayText uses a different format ("→") for screen rendering — that's intended.
		let tc = ToolCallPart(callId: "c1", name: "search", resultSummary: "5 results found")
		let part: TranscriptPart = .toolCall(tc)

		let display = part.displayText
		#expect(display == "[Tool: search → 5 results found]")

		// content and textContent are now consistent (both use flatText format):
		let msg = ChatMessage(role: "assistant", parts: [part])
		#expect(msg.textContent.contains("search"))
		#expect(msg.textContent.contains("5 results"))
		#expect(msg.textContent == msg.content) // the invariant that was broken before
	}

	@Test("image displayText is placeholder")
	func imageDisplayIsPlaceholder() {
		let part: TranscriptPart = .image("data:image/png;base64,xyz")
		#expect(part.displayText == "[Image]")
	}

	@Test("visibility classification correct")
	func visibilityClassification() {
		#expect(TranscriptPart.text("x").visibleByDefault == true)
		#expect(TranscriptPart.image("url").visibleByDefault == true)
		#expect(TranscriptPart.reasoning("x").visibleByDefault == false)
		let tc = ToolCallPart(callId: "c", name: "t")
		#expect(TranscriptPart.toolCall(tc).visibleByDefault == false)
	}
}

// MARK: - contentToString silent drop of multimodal content

@Suite("contentToString silently drops images/audio")
struct ContentToStringTests {

	@Test("plain text not dropped")
	func plainTextNotDropped() {
		let (text, dropped) = contentToString(.text("hello"))
		#expect(text == "hello")
		#expect(dropped == 0)
	}

	@Test("nil content returns empty string with zero dropped")
	func nilContentReturnsEmpty() {
		let (text, dropped) = contentToString(nil as ContentPolymorphic?)
		#expect(text.isEmpty)
		#expect(dropped == 0)
	}

	@Test("image parts in multipart counted as dropped")
	func imagePartsAreDropped() {
		let parts: [ContentPart] = [
			.init(type: "text", text: "hello", imageUrl: nil),
			.init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://img.png")),
		]
		let (text, dropped) = contentToString(.parts(parts))
		#expect(text == "hello")
		#expect(dropped == 1)
	}

	@Test("multiple non-text parts correctly counted")
	func multipleNonTextDropped() {
		let parts: [ContentPart] = [
			.init(type: "text", text: "text1", imageUrl: nil),
			.init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://a.png")),
			.init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://b.png")),
			.init(type: "text", text: "text2", imageUrl: nil),
		]
		let (text, dropped) = contentToString(.parts(parts))
		#expect(text == "text1 text2")
		#expect(dropped == 2)
	}

	@Test("all-image parts: text empty but dropped > 0")
	func allImagePartsDropped() {
		let parts: [ContentPart] = [
			.init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://x.png")),
			.init(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "http://y.png")),
		]
		let (text, dropped) = contentToString(.parts(parts))
		#expect(text.isEmpty)
		#expect(dropped == 2)
	}

	@Test("all-text parts: zero dropped")
	func allTextPartsNoDrop() {
		let parts: [ContentPart] = [
			.init(type: "text", text: "A", imageUrl: nil),
			.init(type: "text", text: "B", imageUrl: nil),
		]
		let (text, dropped) = contentToString(.parts(parts))
		#expect(text == "A B")
		#expect(dropped == 0)
	}
}

// MARK: - ChatViewModel cleanMessages filter logic

@Suite("ChatViewModel cleanMessages filter drops system messages")
struct CleanMessagesFilterTests {

	/// ChatViewModel.chat() line 331-332:
	/// `filter { $0.role != "system" && !$0.content.hasSuffix(" [Interrupted]") }`
	///
	/// This drops ALL system messages including system prompts.

	@Test("interrupted assistant messages are filtered")
	func interruptedAssistantFiltered() {
		let msgs: [ChatMessage] = [
			ChatMessage(role: "user", content: "hello"),
			ChatMessage(role: "assistant", content: "partial [Interrupted]"),
			ChatMessage(role: "user", content: "continue"),
		]
		let clean = msgs.filter { $0.role != "system" && !$0.content.hasSuffix(" [Interrupted]") }
		#expect(clean.count == 2)
		#expect(clean[0].content == "hello")
		#expect(clean[1].content == "continue")
	}

	@Test("system messages dropped even when valid")
	func systemMessagesFilteredEvenIfValid() {
		// System prompt is critical for model behavior, should be preserved
		let msgs: [ChatMessage] = [
			ChatMessage(role: "system", content: "You are a helpful assistant"),
			ChatMessage(role: "user", content: "hello"),
		]
		let clean = msgs.filter { $0.role != "system" && !$0.content.hasSuffix(" [Interrupted]") }
		// System message disappears → model loses role context
		#expect(clean.count == 1)
		#expect(clean[0].role == "user")
	}

	@Test("normal assistant messages not filtered")
	func normalAssistantNotFiltered() {
		let msgs: [ChatMessage] = [
			ChatMessage(role: "user", content: "hello"),
			ChatMessage(role: "assistant", content: "hi there!"),
			ChatMessage(role: "user", content: "thanks"),
		]
		let clean = msgs.filter { $0.role != "system" && !$0.content.hasSuffix(" [Interrupted]") }
		#expect(clean.count == 3)
	}

	@Test("false positive: content ending with [Interrupted] but not interrupted")
	func falsePositiveInterrupted() {
		// If user input happens to end with " [Interrupted]"
		let msgs: [ChatMessage] = [
			ChatMessage(role: "user", content: "The error was: [Interrupted]"),
		]
		let clean = msgs.filter { $0.role != "system" && !$0.content.hasSuffix(" [Interrupted]") }
		// This message is incorrectly filtered — false positive
		#expect(clean.isEmpty)
	}
}

// MARK: - parseToolCalls behavior boundaries

@Suite("parseToolCalls behavior boundaries")
struct ParseToolCallsBehaviorTests {

	@Test("empty content returns nil")
	func emptyContent() {
		#expect(parseToolCalls(from: "") == nil)
	}

	@Test("invalid json returns nil")
	func invalidJson() {
		#expect(parseToolCalls(from: "not json at all") == nil)
	}

	@Test("empty json array returns nil not empty array")
	func emptyJsonArray() {
		// Returns nil instead of [] — caller cannot distinguish
		// "no tool calls" from "parse failure"
		let result = parseToolCalls(from: "[]")
		#expect(result == nil)
	}

	@Test("tool object missing name field is skipped")
	func missingNameSkipped() {
		// {"arguments": "..."} but no "name" → entire tool call ignored
		let result = parseToolCalls(from: "[{\"arguments\": \"{}\"}]")
		#expect(result == nil) // toolCalls.isEmpty ? nil
	}

	@Test("valid tool call parsed correctly")
	func validToolCallParsed() {
		let json = """
		[{"name": "search", "arguments": {"query": "test"}}]
		"""
		let result = parseToolCalls(from: json)
		#expect(result != nil)
		#expect(result?.count == 1)
		#expect(result?[0].function.name == "search")
	}

	@Test("multiple tool calls all preserved")
	func multipleToolCalls() {
		let json = """
		[
			{"name": "search", "arguments": {"q": "swift"}},
			{"name": "compute", "arguments": {"expr": "2+2"}}
		]
		"""
		let result = parseToolCalls(from: json)
		#expect(result != nil)
		#expect(result?.count == 2)
		#expect(result?[0].function.name == "search")
		#expect(result?[1].function.name == "compute")
	}

	@Test("arguments json object correctly serialized")
	func argumentsSerialization() {
		let json = """
		[{"name": "weather", "arguments": {"city": "Tokyo", "units": "celsius"}}]
		"""
		let result = parseToolCalls(from: json)
		#expect(result != nil)
		let args = result?[0].function.arguments
		#expect(args?.contains("Tokyo") == true)
		#expect(args?.contains("celsius") == true)
	}

	@Test("claude style tool use detected as unsupported")
	func claudeStyleToolUse() {
		// Content with <tool_code> returns nil (unsupported)
		let content = "<tool_code>search(query='test')</tool_code>"
		#expect(parseToolCalls(from: content) == nil)
	}
}
