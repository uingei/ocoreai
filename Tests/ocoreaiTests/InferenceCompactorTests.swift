// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InferenceCompactorTests.swift — Unit tests for InferenceCompactor

import Testing

@testable import ocoreai

@Suite("InferenceCompactor")
struct InferenceCompactorTests {

    /// Build N alternating user/assistant messages with controlled content.
    private func makeHistory(count: Int, text: String = "hello world, this is a test message ")
        -> [Message]
    {
        (0 ..< count).map { i in
            Message(
                role: i % 2 == 0 ? "user" : "assistant",
                content: .text(text + String(repeating: "\(i % 10)", count: 20)))
        }
    }

    /// Read a message's text content (nil when absent/non-text).
    private func text(_ message: Message?) -> String? {
        guard let message, case .text(let value)? = message.content else { return nil }
        return value
    }

    @Test("Below threshold - no compaction")
    func belowThreshold() async {
        let messages = makeHistory(count: 5)
        // 5 short messages ≈ 250 tokens; window 32k → threshold 28k → far below
        let result = await InferenceCompactor.compact(
            messages, contextWindowTokens: 32_768
        ) { _ -> String in
            "should not be called"
        }
        #expect(result == nil)
    }

    @Test("Above threshold - compacted with summary prefix + verbatim tail")
    func aboveThreshold() async {
        // Big messages to blow past threshold of a tiny window
        let big = String(repeating: "content line ", count: 50)
        let messages = makeHistory(count: 20, text: big)
        let result = await InferenceCompactor.compact(
            messages, contextWindowTokens: 2000
        ) { _ in
            "DECISION: keep the tail, summarize the rest."
        }
        #expect(result != nil)
        let compacted = result!
        // Compact is strictly shorter
        #expect(compacted.count < messages.count)
        // Head is the summary, marked, in user role
        #expect(compacted.first?.role == "user")
        #expect(
            text(compacted.first) == InferenceCompactor.summaryPrefix
                + "DECISION: keep the tail, summarize the rest.")
        // Tail ends with the original newest messages, verbatim
        #expect(text(compacted.last) == text(messages.last))
        #expect(compacted.last?.role == messages.last?.role)
    }

    @Test("System message preserved at front")
    func systemPreserved() async {
        let big = String(repeating: "payload ", count: 60)
        var messages: [Message] = [
            Message(role: "system", content: .text("you are a helpful agent"))
        ]
        messages.append(contentsOf: makeHistory(count: 16, text: big))
        let result = await InferenceCompactor.compact(
            messages, contextWindowTokens: 1500
        ) { _ in
            "summary here"
        }
        #expect(result != nil)
        #expect(result!.first?.role == "system")
        #expect(text(result!.first) == "you are a helpful agent")
    }

    @Test("Summarization failure - non-fatal, original preserved")
    func failureNonFatal() async {
        let big = String(repeating: "x ", count: 80)
        let messages = makeHistory(count: 12, text: big)
        struct Boom: Error, CustomStringConvertible {
            var description: String { "simulated summarizer failure" }
        }
        let result = await InferenceCompactor.compact(
            messages, contextWindowTokens: 400
        ) { _ -> String in
            throw Boom()
        }
        #expect(result == nil)
    }

    @Test("Empty summary - treated as skip")
    func emptySummary() async {
        let big = String(repeating: "y ", count: 80)
        let messages = makeHistory(count: 12, text: big)
        let result = await InferenceCompactor.compact(
            messages, contextWindowTokens: 400
        ) { _ in "" }
        #expect(result == nil)
    }

    @Test("Unknown context window (0) - skipped")
    func zeroWindow() async {
        let messages = makeHistory(count: 12)
        let result = await InferenceCompactor.compact(messages, contextWindowTokens: 0) {
            _ -> String in "never"
        }
        #expect(result == nil)
    }

    @Test("Short histories never compacted (not enough to split)")
    func shortHistory() async {
        let big = String(repeating: "z ", count: 200)
        let messages = makeHistory(count: 3, text: big)
        // 3 non-system messages = not more than 3 → split returns nil
        let result = await InferenceCompactor.compact(messages, contextWindowTokens: 100) {
            _ -> String in "never"
        }
        #expect(result == nil)
    }

    @Test("Tool call groups are never torn apart")
    func toolGroupIntact() async {
        let big = String(repeating: "t ", count: 100)
        // Build: old user messages, an assistant(tool-call) + its tool
        // response, then newer messages. Force the split boundary at the
        // tool group.
        let toolCall = ToolCall(
            id: "call_1", type: "function", function: .init(name: "clock", arguments: "{}"))
        var messages: [Message] = [
            Message(role: "user", content: .text(big + " q1")),
            Message(role: "user", content: .text(big + " q2")),
            Message(role: "user", content: .text(big + " q3")),
            Message(role: "assistant", content: nil, toolCalls: [toolCall]),
            Message(role: "tool", content: .text("result payload"), toolCallID: "call_1"),
        ]
        messages.append(contentsOf: makeHistory(count: 4, text: big))

        let split = InferenceCompactor.computeSplit(
            messages: messages, estimatedTailBudgetTokens: 30)
        #expect(split != nil)
        guard let s = split else { return }
        // Invariant: an assistant message with toolCalls may end oldSummary
        // only with its tool response following it; otherwise the group was
        // slid into tail by the repair loop.
        let dangling = s.oldSummary.enumerated().contains { i, msg in
            msg.role == "assistant" && (msg.toolCalls?.isEmpty == false)
                && i + 1 == s.oldSummary.count
        }
        #expect(dangling == false, "assistant tool-call group must never be split by the boundary")
        // Tail must always contain the tool message when the call is in tail
        let callInTail = s.recentTail.contains {
            $0.role == "assistant" && ($0.toolCalls?.isEmpty == false)
        }
        if callInTail {
            #expect(s.recentTail.contains { $0.role == "tool" && $0.toolCallID == "call_1" })
        }
    }

    @Test("estimateTokens basic sanity")
    func estimate() {
        #expect(InferenceCompactor.estimateTokens("abcd") == 1)
        #expect(InferenceCompactor.estimateTokens("") == 1)
        #expect(InferenceCompactor.estimateTokens(String(repeating: "a", count: 40)) == 10)
        let msgs = [Message(role: "user", content: "abcd")]
        #expect(InferenceCompactor.estimateTokens(msgs) >= 1)
    }
}
