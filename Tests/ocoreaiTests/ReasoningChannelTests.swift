// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ReasoningChannelTests.swift — two verified defects, exact-value regression tests:
///
/// 1. `AssistantMessage.reasoning_content` — non-streaming responses must carry
///    reasoning on a SEPARATE channel (parity with streaming `ChatDelta` /
///    OpenAI reasoning-models protocol). Nil → key omitted.
/// 2. `AuditTrail` sub-second durationMs — fast (<1s) tool calls previously
///    recorded a flat `0.0ms` because the millisecond conversion dropped the
///    attosecond remainder; now in a measurable range after a controlled sleep.

import Foundation
import Testing

@testable import ocoreai

@Suite("AssistantMessage — reasoning_content channel")
struct AssistantMessageReasoningTests {
    private func encodedJSON(_ msg: AssistantMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    @Test("Reasoning present → reasoning_content exact, content stays the answer")
    func reasoningExact() throws {
        let msg = AssistantMessage(
            content: "1161",
            reasoningContent: "This is a simple multiplication. 97 × 12 = 1164 - 39 = ...",
            toolCalls: nil
        )
        let json = try encodedJSON(msg)
        #expect(json["content"] as? String == "1161")
        #expect(
            json["reasoning_content"] as? String
                == "This is a simple multiplication. 97 × 12 = 1164 - 39 = ...")
        #expect(json["role"] as? String == "assistant")
    }

    @Test("Reasoning nil → reasoning_content key omitted (not null, not empty)")
    func reasoningOmitted() throws {
        let msg = AssistantMessage(content: "hello", toolCalls: nil)
        let json = try encodedJSON(msg)
        #expect(json["content"] as? String == "hello")
        #expect(!json.keys.contains("reasoning_content"))
    }

    @Test("Tool-call responses keep tool_calls and carry reasoning when present")
    func toolCallCoexists() throws {
        let call = ToolCall(
            id: "c1", type: "function", function: .init(name: "exec_command", arguments: "{}"))
        let msg = AssistantMessage(
            content: "",
            reasoningContent: "I should run it first.",
            toolCalls: [call]
        )
        let json = try encodedJSON(msg)
        #expect(json["content"] as? String == "")
        #expect(json["reasoning_content"] as? String == "I should run it first.")
        let tcs = json["tool_calls"] as? [[String: Any]]
        #expect(tcs?.count == 1)
    }
}

@Suite("AuditTrail — sub-second durationMs")
struct AuditTrailSubSecondDurationTests {
    @Test("Fast tool call (<1s) records a non-zero duration in the measured range")
    func subSecondDuration() async throws {
        let trail = AuditTrail(maxEntries: 100, retentionDays: 7, serviceName: "test")
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "timed_fast_tool",
            toolset: "test",
            arguments: [:]
        )
        // Controlled ~60ms of work. Old code (seconds * 1000 only) → 0.0.
        try await Task.sleep(for: .milliseconds(60))
        await trail.completeToken(token, status: .success, result: "done")

        let entries = await trail.recent()
        #expect(entries.count == 1)
        // Exact-range assert: measured wall-clock was >= 60ms, and the
        // sub-second fix means the value must reflect that. Generous upper
        // bound for CI jitter; the lower bound (10ms) is the regression line.
        #expect(entries[0].durationMs > 10.0)
        #expect(entries[0].durationMs < 10_000.0)
    }

    @Test(">1s call keeps integer-second precision correct")
    func wholeSecondDuration() async throws {
        let trail = AuditTrail(maxEntries: 100, retentionDays: 7, serviceName: "test")
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "timed_slow_tool",
            toolset: "test",
            arguments: [:]
        )
        try await Task.sleep(for: .milliseconds(1100))
        await trail.completeToken(token, status: .success, result: "done")

        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].durationMs >= 1050.0)
        #expect(entries[0].durationMs < 10_000.0)
    }
}
