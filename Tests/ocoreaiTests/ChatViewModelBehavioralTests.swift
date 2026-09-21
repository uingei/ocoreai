// Copyright © 2026 uingeai.
// Licensed under MIT.
/// ChatViewModelBehavioralTests.swift — Behavioral tests against real production types.
///
/// Strategy: @testable import exposes internal types. No mocks — construct real
/// ChatMessage, TranscriptPart, and verify actual computed properties and filter logic.
///
/// Matches upstream mlx-swift-lm pattern: test real object graphs, not simulations.

import Foundation
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - ChatMessage textContent invariants

@Suite("ChatMessage: textContent computed property behavior")
struct ChatMessageTextContentTests {

    @Test("Legacy message textContent equals content")
    func legacyMessage() {
        let msg = ChatMessage(role: "user", content: "Hello world")
        #expect(msg.textContent == "Hello world")
        #expect(msg.hasParts == false)
    }

    @Test("Structured message textContent joins text parts with spaces")
    func structuredTextJoin() {
        let parts: [TranscriptPart] = [
            .text("First"),
            .text("Second"),
        ]
        let msg = ChatMessage(role: "assistant", parts: parts)
        #expect(msg.textContent == "First Second")
        #expect(msg.hasParts == true)
    }

    @Test("Reasoning parts flattened into textContent")
    func reasoningFlattened() {
        let parts: [TranscriptPart] = [
            .text("Answer:"),
            .reasoning("Let me think"),
        ]
        let msg = ChatMessage(role: "assistant", parts: parts)
        // flatText joins reasoning text without brackets
        #expect(msg.textContent.contains("Answer"))
        #expect(msg.textContent.contains("Let me think"))
    }

    @Test("Image parts excluded from textContent flatText")
    func imagesExcluded() {
        let parts: [TranscriptPart] = [
            .text("Look:"),
            .image("data:image/png;base64,abc"),
            .text("done"),
        ]
        let msg = ChatMessage(role: "user", parts: parts)
        // Image parts return nil in flatText's compactMap
        #expect(msg.textContent == "Look: done")
        #expect(!msg.textContent.contains("[Image]"))
    }

    @Test("ToolCall parts included in textContent with format")
    func toolCallInFlatText() {
        let tc = ToolCallPart(
            callId: "call_1",
            name: "search",
            resultSummary: "results found",
            durationMs: 120
        )
        let parts: [TranscriptPart] = [.toolCall(tc)]
        let msg = ChatMessage(role: "assistant", parts: parts)
        #expect(msg.textContent.contains("[Tool: search"))
        #expect(msg.textContent.contains("results found"))
    }

    @Test("Mixed parts preserve order in textContent")
    func mixedPartsOrder() {
        let parts: [TranscriptPart] = [
            .text("Step 1"),
            .reasoning("think"),
            .text("Step 2"),
        ]
        let msg = ChatMessage(role: "assistant", parts: parts)
        // flatText joins with space: "Step 1 think Step 2"
        #expect(msg.textContent.contains("Step 1"))
        #expect(msg.textContent.contains("think"))
        #expect(msg.textContent.contains("Step 2"))
        // Order: first component appears before reasoning, which appears before second
        let r1 = msg.textContent.range(of: "Step 1")
        let r2 = msg.textContent.range(of: "think")
        let r3 = msg.textContent.range(of: "Step 2")
        #expect(r1 != nil)
        #expect(r2 != nil)
        #expect(r3 != nil)
        #expect(r1!.lowerBound < r2!.lowerBound)
        #expect(r2!.lowerBound < r3!.lowerBound)
    }
}

// MARK: - ChatMessage cleanMessages filter behavior

@Suite("ChatMessage: cleanMessages filter — only drops interrupted assistant messages")
struct CleanMessagesFilterTests {

    @MainActor @Test("Interrupted assistant messages are filtered out")
    func dropsInterruptedAssistant() async {
        let msgs: [ChatMessage] = [
            .init(role: "user", content: "Tell me a story"),
            .init(role: "assistant", content: "Once upon a time", interrupted: true),
            .init(role: "assistant", content: "The end."),
        ]
        let clean = ChatState.shared.cleanMessages(msgs)
        #expect(clean.count == 2)
        #expect(!clean.contains { $0.interrupted })
    }

    @MainActor @Test("User messages with any content survive the filter")
    func preservesUserMessages() async {
        let msgs: [ChatMessage] = [
            .init(role: "user", content: "Continue: Once upon a time"),
            .init(role: "assistant", content: "The princess woke up."),
        ]
        let clean = ChatState.shared.cleanMessages(msgs)
        #expect(clean.count == 2)
        #expect(clean[0].role == "user")
    }

    @MainActor @Test("System messages are always filtered out")
    func dropsSystemMessages() async {
        let msgs: [ChatMessage] = [
            .init(role: "system", content: "You are helpful."),
            .init(role: "user", content: "Hi"),
        ]
        let clean = ChatState.shared.cleanMessages(msgs)
        #expect(clean.count == 1)
        #expect(clean[0].role == "user")
    }

    @MainActor @Test("Normal assistant messages survive")
    func preservesNormalAssistant() async {
        let msgs: [ChatMessage] = [
            .init(role: "assistant", content: "Here's the answer.")
        ]
        let clean = ChatState.shared.cleanMessages(msgs)
        #expect(clean.count == 1)
    }

    @MainActor @Test("Multiple interrupted assistant messages all dropped")
    func dropsMultipleInterrupted() async {
        let msgs: [ChatMessage] = [
            .init(role: "user", content: "Q1"),
            .init(role: "assistant", content: "A1", interrupted: true),
            .init(role: "user", content: "Q2"),
            .init(role: "assistant", content: "A2", interrupted: true),
            .init(role: "assistant", content: "Final answer."),
        ]
        let clean = ChatState.shared.cleanMessages(msgs)
        // 2 user + 1 clean assistant = 3
        #expect(clean.count == 3)
        #expect(!clean.contains { $0.interrupted })
    }

    @MainActor @Test("Legitimate text ending with ' [Interrupted]' is not filtered")
    func doesntFalsePositiveOnText() async {
        let msgs: [ChatMessage] = [
            .init(role: "user", content: "What does 'interrupted' mean?"),
            .init(role: "assistant", content: "A process that was interrupted"),
        ]
        let clean = ChatState.shared.cleanMessages(msgs)
        // Not marked as interrupted, so it survives
        #expect(clean.count == 2)
    }
}

// MARK: - TranscriptPart displayText behavior

@Suite("TranscriptPart: displayText computed property")
struct TranscriptPartDisplayTextTests {

    @Test("Text part displayText equals content")
    func textPart() {
        let part: TranscriptPart = .text("Hello")
        #expect(part.displayText == "Hello")
        #expect(part.visibleByDefault == true)
    }

    @Test("Reasoning part wrapped in brackets")
    func reasoningPart() {
        let part: TranscriptPart = .reasoning("thinking process")
        #expect(part.displayText == "[Reasoning: thinking process]")
        #expect(part.visibleByDefault == false)
    }

    @Test("ToolCall part shows name and result")
    func toolCallPart() {
        let tc = ToolCallPart(callId: "c1", name: "weather", resultSummary: "Sunny, 14°C")
        let part: TranscriptPart = .toolCall(tc)
        #expect(part.displayText.contains("weather"))
        #expect(part.displayText.contains("Sunny"))
        #expect(part.visibleByDefault == false)
    }

    @Test("ToolCall with nil resultSummary shows ellipsis")
    func toolCallNilSummary() {
        let tc = ToolCallPart(callId: "c1", name: "search", resultSummary: nil)
        let part: TranscriptPart = .toolCall(tc)
        #expect(part.displayText.contains("…"))
    }

    @Test("Image part shows placeholder")
    func imagePart() {
        let part: TranscriptPart = .image("data:image/png;base64,xyz")
        #expect(part.displayText == "[Image]")
        #expect(part.visibleByDefault == true)
    }
}

// MARK: - ChatMessage initialization invariants

@Suite("ChatMessage: initializer behavior")
struct ChatMessageInitTests {

    @Test("Legacy init sets parts to nil")
    func legacyInit() {
        let msg = ChatMessage(role: "user", content: "test", timestamp: .now)
        #expect(msg.parts == nil)
        #expect(msg.content == "test")
        #expect(msg.role == "user")
    }

    @Test("Structured init populates content from flatText")
    func structuredInit() {
        let parts: [TranscriptPart] = [.text("Hello"), .text("World")]
        let msg = ChatMessage(role: "user", parts: parts)
        #expect(msg.parts != nil)
        #expect(msg.content == "Hello World")
        #expect(msg.textContent == "Hello World")
    }

    @Test("Legacy init with image URLs preserves them")
    func imageUrlsPreserved() {
        let urls = ["data:image/png;base64,abc", "data:image/png;base64,def"]
        let msg = ChatMessage(role: "user", content: "look", imageURLs: urls)
        #expect(msg.imageURLs.count == 2)
    }
}

// MARK: - ChatState.displayText — UI/wire parity tests
// The UI live preview and final bubble must strip the fake tool-plan array
// the same way the OpenAI wire does (OutputSanitizer). These tests pin that
// parity to exact-value expectations.

@Suite("ChatState: displayText strips fake tool-plan arrays")
struct ChatStateDisplayTextTests {
    @Test("Fake tool-plan array is removed, surrounding prose kept")
    func toolArrayStripped() {
        // gemma-4e2b style: prose + fake top-level tool plan + prose
        let raw =
            "Running the tool now.\n[{ \"name\": \"exec_command\", \"arguments\": \"command: ls -la\" }]\nDone: 4 files."
        let out = ChatState.displayText(from: raw)
        #expect(out == "Running the tool now.\n\nDone: 4 files.")
        #expect(!out.contains("exec_command"))
        #expect(!out.contains("{"))
    }

    @Test("Legitimate JSON array without name is NOT stripped")
    func legitArrayKept() {
        // isToolCallArray requires at least one {name} entry
        let raw = "Result: [1, 2, 3] and [{ \"value\": 42 }]"
        #expect(ChatState.displayText(from: raw) == raw)
    }

    @Test("Unsettled/incomplete tool array survives incremental view (no partial strip)")
    func incompleteArraySurvives() {
        // While streaming: array not yet closed — must NOT be spliced
        let raw = "Planning: [{ \"name\": \"exec_command\", \"argumen"
        #expect(ChatState.displayText(from: raw) == raw)
    }

    @Test("Multiple tool-plan arrays all stripped")
    func multipleArraysStripped() {
        let raw = "a [{ \"name\": \"t1\", \"arguments\": \"x\" }] mid [{ \"name\": \"t2\" }] end"
        let out = ChatState.displayText(from: raw)
        #expect(!out.contains("t1") && !out.contains("t2"))
        #expect(out.contains("a  mid  end") || out.contains("amidend"))
    }

    // Real thinking family in the strip path is ` think/think` (verified by
    // hexdump of ChatViewModel source). Tags assembled from code points —
    // transport-safe, same pattern as OutputSanitizer.
    @Test("Complete thinking block + tool array both stripped (exact)")
    func thinkingAndToolArrayExact() {
        let lt = Character(UnicodeScalar(0x3C))
        let gt = Character(UnicodeScalar(0x3E))
        let open = String([lt]) + "think" + String([gt])
        let close = String([lt]) + "/think" + String([gt])
        let arr = "[{ \"name\": \"t\", \"arguments\": \"a\" }]"
        let raw = "Before" + open + "inner" + close + "After" + arr
        #expect(ChatState.displayText(from: raw) == "BeforeAfter")
    }

    @Test("Trailing unclosed think tag cuts the tail (live-preview semantics)")
    func unclosedThinkCutsTail() {
        let lt = Character(UnicodeScalar(0x3C))
        let gt = Character(UnicodeScalar(0x3E))
        let open = String([lt]) + "think" + String([gt])
        #expect(ChatState.displayText(from: "AB" + open + "partial") == "AB")
    }

    // MARK: - family convergence parity (UI delegates to OutputSanitizer)

    private static let lt = Character(UnicodeScalar(0x3C))
    private static let gt = Character(UnicodeScalar(0x3E))
    private static let pip = Character(UnicodeScalar(0x7C))
    private static let sla = Character(UnicodeScalar(0x2F))
    private static var gemmaOpen: String {
        String([lt, pip]) + "channel" + String([gt])
    }
    private static var gemmaClose: String {
        String([lt]) + "channel" + String([pip, gt])
    }
    private static var q3Open: String {
        String([lt, pip]) + "begin_of_thought" + String([pip, gt])
    }
    private static var q3End: String {
        String([lt, pip]) + "end_of_thought" + String([pip, gt])
    }
    private static var q3Eot: String {
        String([lt, pip]) + "eot_id" + String([gt])
    }
    private static var tOpen: String { String([lt]) + "think" + String([gt]) }
    private static var tClose: String { String([lt, sla]) + "think" + String([gt]) }
    private static var thOpen: String { String([lt]) + "thinking" + String([gt]) }
    private static var thClose: String {
        String([lt, sla]) + "thinking" + String([gt])
    }

    @Test("gemma span is stripped by the UI now (previously leaked into bubbles)")
    func gemmaSpanStrippedInUI() {
        let raw = "Pre" + Self.gemmaOpen + "inner thought" + Self.gemmaClose + "After"
        let out = ChatState.displayText(from: raw)
        #expect(out == "PreAfter")
        #expect(out == OutputSanitizer.strip(raw))
    }

    @Test("thinking/thinking pair still stripped (no regression on the old UI family)")
    func thinkingPairStripped() {
        let raw = "A" + Self.thOpen + "reasoning here" + Self.thClose + "B"
        let out = ChatState.displayText(from: raw)
        #expect(out == "AB")
        #expect(out == OutputSanitizer.strip(raw))
    }

    @Test("Qwen3 legacy end_of_thought closer: thought stripped, outer kept")
    func qwen3LegacyEndStripped() {
        let raw = "A" + Self.q3Open + "deep reasoning" + Self.q3End + "B"
        let out = ChatState.displayText(from: raw)
        #expect(out == "AB")
        #expect(out == OutputSanitizer.strip(raw))
    }

    @Test("Qwen3 legacy eot_id closer: answer AFTER the closer survives (regression lock)")
    func qwen3LegacyEotIdKeepsAnswer() {
        let raw = Self.q3Open + "inner" + Self.q3Eot + "  the answer  "
        let out = ChatState.displayText(from: raw)
        // UI keeps the original edge whitespace (no trim — it is the live
        // preview of growing text; trimming is the wire's `strip` job).
        #expect(out == "  the answer  ")
        #expect(!out.contains("inner"))
        #expect(
            out.trimmingCharacters(in: .whitespacesAndNewlines)
                == OutputSanitizer.strip(raw))
    }

    @Test("closer-only demotion: text before the last think-closer is thinking")
    func closerOnlyDemotion() {
        let raw = "wandering thought" + Self.tClose + "final reply"
        let out = ChatState.displayText(from: raw)
        #expect(out == "final reply")
        #expect(out == OutputSanitizer.strip(raw))
    }

    @Test("UI displayText == wire strip on the full family corpus (exact parity)")
    func fullFamilyParityWithWire() {
        let corpus: [String] = [
            "Pre" + Self.gemmaOpen + "th" + Self.gemmaClose + "After",
            "A" + Self.tOpen + "t" + Self.tClose + "B",
            "A" + Self.thOpen + "t" + Self.thClose + "B",
            "A" + Self.q3Open + "t" + Self.q3End + "B",
            Self.q3Open + "t" + Self.q3Eot + "  ans  ",
            "head" + Self.tClose + "tail",
            Self.gemmaOpen + "never closed",
            "x" + Self.tOpen + "y" + "z",
        ]
        for raw in corpus {
            let display = ChatState.displayText(from: raw)
            // Semantic parity: identical answer content. The UI keeps the
            // original edge whitespace of the growing text; the wire trims.
            #expect(
                display.trimmingCharacters(in: .whitespacesAndNewlines)
                    == OutputSanitizer.strip(raw),
                "UI/wire parity broke for: '\(raw)'")
            // No marker literal may leak into the displayed text.
            let markers = [
                Self.gemmaOpen, Self.gemmaClose, Self.tOpen, Self.tClose,
                Self.thOpen, Self.thClose, Self.q3Open, Self.q3End, Self.q3Eot,
            ]
            for marker in markers {
                #expect(
                    !display.contains(marker),
                    "marker leaked into display: '\(marker)' in '\(display)'")
            }
        }
    }
}

// MARK: - consumerFacingError: known engine strings mapped to localized output

/// Known engine failure modes must be replaced by a localized phrase (locale-
/// independent assertions: the raw technical prefix is gone); unknown strings
/// pass through verbatim so diagnostics are never swallowed.
@Suite("ChatState: consumerFacingError maps raw engine errors")
struct ConsumerFacingErrorTests {

    @Test("Model not loaded is replaced by a localized phrase")
    func modelNotLoaded() {
        let out = ChatState.consumerFacingError("Model not loaded: gemma-4-e2b")
        #expect(!out.hasPrefix("Model not loaded"), "raw technical string leaked: \(out)")
        #expect(!out.isEmpty)
    }

    @Test("MLX model handle not loaded is replaced by a localized phrase")
    func mlxHandleNotLoaded() {
        let out = ChatState.consumerFacingError("MLX model handle not loaded: qwen")
        #expect(!out.hasPrefix("MLX model handle"), "raw technical string leaked: \(out)")
    }

    @Test("Engine busy is replaced by a localized phrase")
    func engineBusy() {
        let out = ChatState.consumerFacingError("Engine busy")
        #expect(!out.hasPrefix("Engine busy"), "raw technical string leaked: \(out)")
    }

    @Test("Detokenization failure is replaced by a localized phrase")
    func detok() {
        let out = ChatState.consumerFacingError("Detokenization failed — inference cannot proceed")
        #expect(!out.contains("Detokenization failed"), "raw technical string leaked: \(out)")
    }

    @Test("Unknown strings pass through verbatim (diagnostics preserved)")
    func unknownPassthrough() {
        let raw = "LanguageModelSession error: unexpected kernel state"
        #expect(ChatState.consumerFacingError(raw) == raw)
    }
}
