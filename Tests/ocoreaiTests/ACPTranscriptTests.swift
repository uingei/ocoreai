import Foundation
import Testing

@testable import ocoreai

/// What an ACP turn leaves in the store. The defect this pins: the direct lane the ACP face
/// rides persisted nothing, so an editor conversation died with the editor process and no
/// `session/load` had anything to replay. The assertions read the rows back through the same
/// actor API the session pages use, against a real SQLite file, never a mock store.
@Suite("ACP 回合落库 — 行、键、cwd、失败位", .serialized)
struct ACPTranscriptTests {

    private func openStore() async throws -> (SQLiteStore, String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_acp_\(UUID().uuidString.prefix(8)).sqlite").path
        let store = SQLiteStore(path: path)
        try await store.open()
        return (store, path)
    }

    private func cleanup(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Oldest-first, every role — the order `getMessages` (newest-first) is reversed into.
    private func rowsOldestFirst(_ compressor: SessionCompressor, _ rowId: Int64) async throws
        -> [MessageModel]
    {
        try await compressor.getMessages(rowId, limit: 100).reversed()
    }

    @Test("one turn writes user+assistant rows on the external key, with cwd bound once per turn")
    func turnLandsOnOneRow() async throws {
        let (store, path) = try await openStore()
        defer { Task { await store.close() } }
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let session = ACPSession(id: "acp-transcript1", cwd: "/tmp/editor-project")

        var record = ACPTurnRecord()
        record.assistantText = "Paris."
        record.reasoningText = "capital of France"
        try await ACPAgent.persistTurn(
            to: compressor, session: session, modelId: "m1", userText: "Capital?", record: record)

        let rowId = try await compressor.resolveSession(
            externalKey: "acp-transcript1", modelId: "m1")
        let row = try #require(await compressor.getSession(rowId))
        #expect(row.workspaceDirectory == "/tmp/editor-project")
        let listed = try await rowsOldestFirst(compressor, rowId)
        #expect(listed.map(\.role) == ["user", "assistant"])
        #expect(listed[0].content == "Capital?")
        #expect(listed[1].content == "Paris.")
        #expect(listed[1].reasoning == "capital of France")
        #expect(listed[1].toolCalls == nil, "no calls seen, nothing recorded")

        // The second turn extends the same row; a second row would be two conversations.
        var second = ACPTurnRecord()
        second.assistantText = "Berlin."
        try await ACPAgent.persistTurn(
            to: compressor, session: session, modelId: "m1", userText: "And Germany?",
            record: second)
        let sameRow = try await compressor.resolveSession(
            externalKey: "acp-transcript1", modelId: "m1")
        #expect(sameRow == rowId, "the key must land on the same row every turn")
        let after = try await rowsOldestFirst(compressor, rowId)
        #expect(after.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(after[2].content == "And Germany?")
    }

    @Test(
        "tool records pair by id; a failed result says failed; a call without a result says nothing"
    )
    func toolCallFailureBitIsRecorded() async throws {
        let (store, path) = try await openStore()
        defer { Task { await store.close() } }
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let session = ACPSession(id: "acp-calls", cwd: "/tmp/p")

        var record = ACPTurnRecord()
        record.assistantText = "done"
        record.noteCall(id: "c1", name: "write_file", arguments: "{\"path\":\"x\"}")
        record.noteResult(id: "c1", summary: "OK", failed: false)
        record.noteCall(id: "c2", name: "exec", arguments: nil)
        record.noteResult(id: "c2", summary: "boom", failed: true)
        record.noteCall(id: "c3", name: "read_file", arguments: "{\"path\":\"y\"}")
        try await ACPAgent.persistTurn(
            to: compressor, session: session, modelId: "m1", userText: "go", record: record)

        let rowId = try await compressor.resolveSession(externalKey: "acp-calls", modelId: "m1")
        let assistant = try #require(
            try await rowsOldestFirst(compressor, rowId).first { $0.role == "assistant" })
        let calls = try #require(assistant.toolCalls)
        #expect(calls.map(\.callId) == ["c1", "c2", "c3"], "call order is the conversation's")
        #expect(
            calls[0].arguments == ["path": "x"], "args ride in the same flat shape the GUI stores")
        #expect(calls[0].resultFailed == false)
        #expect(calls[1].resultFailed == true, "a failed result must not replay as a completion")
        #expect(calls[2].resultFailed == nil, "no result yet is not a completion either")
        #expect(calls[2].resultSummary == nil)
    }

    @Test("a turn that streamed nothing stores only the user's words, never an empty reply")
    func emptyAssistantRowIsNotWritten() async throws {
        let (store, path) = try await openStore()
        defer { Task { await store.close() } }
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let session = ACPSession(id: "acp-empty", cwd: "/tmp/p")
        try await ACPAgent.persistTurn(
            to: compressor, session: session, modelId: "m1", userText: "hello?",
            record: ACPTurnRecord())
        let rowId = try await compressor.resolveSession(externalKey: "acp-empty", modelId: "m1")
        let stored = try await rowsOldestFirst(compressor, rowId)
        #expect(
            stored.map(\.role) == ["user"], "an empty assistant row would replay as a blank bubble")
    }
}
