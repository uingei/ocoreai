import Foundation
import Testing
@testable import ocoreai

// Reasoning persistence (codex #46711 parity) — persist → re-open → precise-value round-trip.
//
// Verifies the full chain:
//   1. `addMessage` (new path) → `getMessages` (read path) → `fromMessageModel`
//      (rebuild) all preserve the reasoning text without loss.
//   2. Pre-migration row (column absent) → `reasoning` deserializes as `nil`,
//      `parts` list stays empty (no spurious `.reasoning` part).
//   3. Live-stream order: parts = [reasoning, text, toolCall] in that order.
@MainActor
final class ReasoningPersistenceSQLiteTests {

    private func uniqueDB() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reasoning_sql_\(UUID().uuidString).sqlite").path
    }

    private struct NoSID: Error {}

    private func makeSession(_ s: SQLiteStore) async throws -> Int64 {
        try await s.execute(
            sql:
                "INSERT INTO sessions (model_id, created_at, updated_at) VALUES ('t', 1735689600000, 1735689600000);"
        )
        let v = try await s.scalarQuery(sql: "SELECT last_insert_rowid();")
        guard let id = v?.asInt64 else { throw NoSID() }
        return id
    }

    // ── 1. New DB (migration already ran): round-trip persists reasoning ──

    @Test func freshDBRoundTripPersistsReasoning() async throws {
        let path = uniqueDB()

        let store1 = SQLiteStore(path: path)
        try await store1.open()
        let sid = try await makeSession(store1)
        let c1 = SessionCompressor(store: store1, fts: FTS5Search(store: store1))
        _ = try await c1.addMessage(
            sessionId: sid, role: "assistant",
            content: "323 files, 47 lines",
            tokenCount: 8,
            reasoning: "I need to list .txt files under /tmp/agent_test/ and count total lines. Let me use exec_command."
        )
        await store1.close()

        // Re-open in a fresh instance — same way a restarted app reads the session.
        let store2 = SQLiteStore(path: path)
        try await store2.open()
        let c2 = SessionCompressor(store: store2, fts: FTS5Search(store: store2))
        let msgs = try await c2.getMessages(sid, limit: 10, offset: 0)
        await store2.close()

        #expect(msgs.count == 1)
        let m = msgs[0]
        #expect(m.role == "assistant")
        #expect(m.content == "323 files, 47 lines")
        #expect(m.reasoning ?? "" == "I need to list .txt files under /tmp/agent_test/ and count total lines. Let me use exec_command.")
        #expect(m.reasoning != nil, "reasoning must be non-nil after round-trip")
    }

    // ── 2. New DB with tool_calls + reasoning: parts list order ──

    @Test func freshDBRoundTripPreservesPartOrder() async throws {
        let path = uniqueDB()

        let store1 = SQLiteStore(path: path)
        try await store1.open()
        let sid = try await makeSession(store1)
        let c1 = SessionCompressor(store: store1, fts: FTS5Search(store: store1))
        let rec = ToolCallRecord(
            callId: "tool1", toolName: "exec_command", arguments: ["command": "ls"],
            resultSummary: "2 files", durationMs: 42
        )
        _ = try await c1.addMessage(
            sessionId: sid, role: "assistant",
            content: "Found 2 files.", tokenCount: 5,
            toolCalls: [rec],
            reasoning: "The user asked for a directory scan. I should use exec_command with `ls`."
        )
        await store1.close()

        let store2 = SQLiteStore(path: path)
        try await store2.open()
        let c2 = SessionCompressor(store: store2, fts: FTS5Search(store: store2))
        let msgs = try await c2.getMessages(sid, limit: 10, offset: 0)
        await store2.close()

        #expect(msgs.count == 1)
        let m = msgs[0]

        // Rebuild via the same path that ChatState restore uses.
        let msg = ChatState.shared.fromMessageModel(m)
        let parts = msg.parts ?? []
        #expect(parts.count == 3,
                "parts must be [reasoning, text, toolCall] = 3, got \(parts.count)")
        #expect(parts.first == .reasoning("The user asked for a directory scan. I should use exec_command with `ls`."))
        #expect(parts.count > 1 && parts[1] == .text("Found 2 files."))
        #expect(parts.count == 3 && parts[2] == .toolCall(ToolCallPart(
            callId: "tool1", name: "exec_command", arguments: ["command": "ls"],
            resultSummary: "2 files", durationMs: 42
        )))
    }

    // ── 3. Pre-migration row: reasoning column absent → reasoning = nil, no spurious part ──

    @Test func preMigrationRowYieldsNilReasoningAndNoSpuriousParts() async throws {
        let path = uniqueDB()
        let store = SQLiteStore(path: path)
        try await store.open()
        let sid = try await makeSession(store)
        let c = SessionCompressor(store: store, fts: FTS5Search(store: store))

        // Simulate a row written BEFORE the migration ran.
        let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO messages (session_id, role, content, created_at, token_count, tool_calls) VALUES (?, 'assistant', 'legacy answer', ?, 3, '');",
            parameters: [sid, nowUs]
        )

        let msgs = try await store.query(
            "SELECT id, session_id, role, content, created_at, token_count, tool_calls, reasoning FROM messages WHERE session_id = ?;",
            parameters: [sid])
        await store.close()

        #expect(msgs.count == 1)
        guard let mm = msgs.first.flatMap(MessageModel.init) else {
            #expect(false, "row deserializes to nil")
            return
        }
        #expect(mm.reasoning == nil, "pre-migration row must deserialize reasoning as nil")

        let msg = ChatState.shared.fromMessageModel(mm)
        // No reasoning / toolCalls → no parts rebuild → flat content fallback.
        #expect((msg.parts ?? []).isEmpty,
                "pre-migration row with no toolCalls and no reasoning → flat fallback, no parts")
        #expect(msg.content == "legacy answer")
    }
}
