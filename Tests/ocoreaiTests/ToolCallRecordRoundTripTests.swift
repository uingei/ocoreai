// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolCallRecord SQLite round-trip — GUARANTEE that the GUI tool card's
/// real `resultSummary` + `durationMs` survive session persistence and
/// restore (a re-opened session must show the same tool badges — name,
/// truthful result, measured ms — not the fake "N bytes args" + 0ms).
///
/// Regression guards:
///  1. exact-value preservation through addMessage → getMessages (SQLite
///     encoding/JSON/blob path), success AND failure records;
///  2. a failure record's `resultSummary` must come back byte-identical —
///     it must never be replaced by an "executed"/"N bytes args" look-alike;
///  3. a message with NO tool calls must not gain phantom tool records
///     on restore.

import Foundation
import Testing

@testable import ocoreai

@Suite("ToolCallRecord — real result+duration survive SQLite round-trip", .serialized)
struct ToolCallRecordRoundTripTests {

    private func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_roundtrip_\(UUID().uuidString.prefix(8)).sqlite")
            .path
    }

    private func cleanup(_ p: String) {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + s) }
    }

    @Test("real resultSummary + durationMs round-trip exactly (success + failure)")
    func realValuesSurviveRoundTrip() async throws {
        let p = tempDBPath()
        defer { cleanup(p) }

        let store = SQLiteStore(path: p)
        try await store.open()
        defer { await store.close() }

        let comp = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let sid = try await comp.createSession(modelId: "roundtrip-probe")

        let real = [
            ToolCallRecord(
                callId: "call_real_01",
                toolName: "exec_command",
                arguments: ["command": "find . -name '*.txt' | wc -l"],
                resultSummary: "15",
                durationMs: 126.755
            ),
            ToolCallRecord(
                callId: "call_real_02",
                toolName: "exec_command",
                arguments: ["command": "cat missing.file"],
                resultSummary: "[失败] 需要审批 — headless 通道不可交互",
                durationMs: 0.4
            ),
        ]
        _ = try await comp.addMessage(
            sessionId: sid, role: "assistant",
            content: "audit complete", tokenCount: 42,
            toolCalls: real)

        let restored = try await comp.getMessages(sid, limit: 10, offset: 0)
        let latest = restored.first(where: { $0.role == "assistant" })
        #expect(latest != nil, "assistant message must come back")
        let calls = latest?.toolCalls
        #expect(calls?.count == 2, "both records must survive; got \(String(describing: calls?.count))")

        // exact-value, field-by-field — no floating tolerance:
        #expect(calls?[0].callId == "call_real_01")
        #expect(calls?[0].toolName == "exec_command")
        #expect(calls?[0].arguments["command"] == "find . -name '*.txt' | wc -l")
        #expect(calls?[0].resultSummary == "15")
        #expect(calls?[0].durationMs == 126.755)

        // failure record: the denial text must be byte-identical after the trip —
        // it is the user-visible "what actually happened" and must never be
        // substituted by a generic "executed" / "N bytes args" string.
        #expect(calls?[1].callId == "call_real_02")
        #expect(calls?[1].resultSummary == "[失败] 需要审批 — headless 通道不可交互")
        #expect(calls?[1].durationMs == 0.4)

        // the guard against silent corruption: neither may look like the fallback
        let s0 = calls?[0].resultSummary ?? ""
        let s1 = calls?[1].resultSummary ?? ""
        #expect(!s0.contains("bytes args"), "real summary must not be a fallback: \(s0)")
        #expect(!s1.contains("bytes args"), "denial text must not be a fallback: \(s1)")
        #expect(s0 != "executed")
    }

    @Test("tool-free message round-trips with NO phantom tool records")
    func noPhantomToolRecords() async throws {
        let p = tempDBPath()
        defer { cleanup(p) }

        let store = SQLiteStore(path: p)
        try await store.open()
        defer { await store.close() }

        let comp = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let sid = try await comp.createSession(modelId: "phantom-probe")

        _ = try await comp.addMessage(
            sessionId: sid, role: "assistant",
            content: "hello, no tools here", tokenCount: 3,
            toolCalls: nil)

        let restored = try await comp.getMessages(sid, limit: 10, offset: 0)
        let latest = restored.first(where: { $0.role == "assistant" })
        #expect(latest?.toolCalls == nil, "a text-only message must not gain tool records")
    }
}
