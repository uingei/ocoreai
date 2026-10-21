// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! SessionTranscriptTests.swift — one conversation owns one session row, and a row costs its
//! own message.
//!
//! ### The defects this locks (measured live 10-21, this host)
//! Three `/v1/chat/completions` turns sent with the same `session_id` produced **three**
//! `sessions` rows (ids 1936/1937/1938, `message_count=2` each), because the persist hop
//! reused a row only when the key parsed as `Int64` and otherwise created one — and nothing on
//! the HTTP surface ever hands a client an integer to reuse. The conversation the engine keeps
//! in its session pool had no counterpart in session memory: `/sessions`,
//! `/sessions/:id/memory`, `/sessions/search` and the GUI session list saw one snapshot per
//! request.
//!
//! The same hop divided the turn's whole prompt over the user rows
//! (`tokensPerMsg = promptTokens / userMsgCount`), so a 34-character message was stored with
//! `token_count: 705` — that turn's entire rendered prompt, including this server's own system
//! prompt and chat template. And because every user message in the re-sent history was inserted
//! again each turn, the session total that `SessionCompressor` compares against
//! `tokenThreshold` to prune charged the same history once per turn.

import Foundation
import Testing

@testable import ocoreai

private func entry(_ role: String, _ text: String) -> TranscriptEntry {
    TranscriptEntry(role: role, content: text)
}

@Suite("SessionTranscript — what one turn adds to a stored conversation")
struct SessionTranscriptRulesTests {

    @Test("first turn — nothing stored, so the whole transcript is new")
    static func firstTurnIsAllNew() {
        #expect(
            SessionTranscript.newEntries(existing: [], incoming: [entry("user", "hi")])
                == [entry("user", "hi")])
    }

    @Test("ordinary turn — only the tail, several turns deep")
    static func ordinaryTurnAddsTheTail() {
        #expect(
            SessionTranscript.newEntries(
                existing: [entry("user", "U1")],
                incoming: [entry("user", "U1"), entry("user", "U2")]) == [entry("user", "U2")])
        #expect(
            SessionTranscript.newEntries(
                existing: [entry("user", "U1"), entry("tool", "T1"), entry("user", "U2")],
                incoming: [
                    entry("user", "U1"), entry("tool", "T1"), entry("user", "U2"),
                    entry("user", "U3"),
                ]) == [entry("user", "U3")])
    }

    @Test("re-sent identical transcript adds nothing (replay is idempotent)")
    static func replayAddsNothing() {
        let t = [entry("user", "U1"), entry("user", "U2")]
        #expect(SessionTranscript.newEntries(existing: t, incoming: t) == [])
    }

    @Test("a rewind adds nothing — the stored rows already reach further than the client")
    static func rewindAddsNothing() {
        #expect(
            SessionTranscript.newEntries(
                existing: [entry("user", "U1"), entry("user", "U2"), entry("user", "U3")],
                incoming: [entry("user", "U1")]) == [])
    }

    @Test("reworded history appends from the divergence, not from the start")
    static func divergenceAppendsItsTail() {
        #expect(
            SessionTranscript.newEntries(
                existing: [entry("user", "U1"), entry("user", "U2")],
                incoming: [entry("user", "U1"), entry("user", "U2 reworded")])
                == [entry("user", "U2 reworded")])
    }

    /// The trap one level down: the stored rows interleave assistant replies while the client
    /// list (as persisted) does not. Filtering only one side stops the overlap at the first
    /// reply and re-stores every earlier turn — the same defect, smaller.
    @Test("both sides are filtered to one shape, so the overlap sees the whole head")
    static func shapeFilteringAgreesOnBothSides() throws {
        let client = SessionTranscript.client([
            Message(role: "system", content: "instructions"),
            Message(role: "user", content: "U1"),
            Message(role: "assistant", content: "A1"),
            Message(role: "user", content: "U2"),
        ])
        #expect(client == [entry("user", "U1"), entry("user", "U2")])

        let stored = SessionTranscript.stored([
            MessageModel(
                id: 1, sessionId: 7, role: "user", content: "U1",
                createdAt: Date(timeIntervalSince1970: 1), tokenCount: 5,
                toolCalls: nil, reasoning: nil, embedVector: nil),
            MessageModel(
                id: 2, sessionId: 7, role: "assistant", content: "A1",
                createdAt: Date(timeIntervalSince1970: 2), tokenCount: 3,
                toolCalls: nil, reasoning: nil, embedVector: nil),
            MessageModel(
                id: 3, sessionId: 7, role: "user", content: "U2",
                createdAt: Date(timeIntervalSince1970: 3), tokenCount: 5,
                toolCalls: nil, reasoning: nil, embedVector: nil),
        ])
        #expect(stored == [entry("user", "U1"), entry("user", "U2")])
        #expect(SessionTranscript.newEntries(existing: stored, incoming: client) == [])
    }

    @Test("persisted roles are exactly what the client said")
    static func persistedRoles() {
        #expect(SessionTranscript.persists(role: "user"))
        #expect(SessionTranscript.persists(role: "tool"))
        #expect(!SessionTranscript.persists(role: "system"))
        #expect(!SessionTranscript.persists(role: "assistant"))
        #expect(!SessionTranscript.persists(role: "developer"))
    }
}

@Suite("SessionCompressor.resolveSession — one key, one row, across turns and restarts")
struct SessionIdentitySQLiteTests {

    private func compressor(at path: String) async throws -> SessionCompressor {
        let store = SQLiteStore(path: path)
        try await store.open()
        return SessionCompressor(store: store, fts: FTS5Search(store: store))
    }

    private func uniqueDB(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sess_identity_\(label)_\(UUID().uuidString).sqlite").path
    }

    /// The fix, measured where it lands: three turns on one key is one session row containing
    /// the whole conversation, not three two-row snapshots.
    @Test("three turns on one key produce one session row with all four messages")
    func threeTurnsOneRow() async throws {
        let path = uniqueDB("three_turns")
        let c = try await compressor(at: path)
        let model = "mlx-community/test-model"

        var first: Int64 = 0
        for (userText, reply) in [("U1", "A1"), ("U2", "A2"), ("U3", "A3")] {
            let sid = try await c.resolveSession(externalKey: "CONV-1", modelId: model)
            if first == 0 { first = sid }
            #expect(sid == first, "turn for \(userText) landed on a different session row")
            try await c.addMessage(
                sessionId: sid, role: "user", content: userText, tokenCount: 6)
            try await c.addMessage(
                sessionId: sid, role: "assistant", content: reply, tokenCount: 2)
        }

        let rows = try await c.hotWindow(first)
        #expect(rows.count == 6, "expected 6 rows on one session, got \(rows.count)")
        let session = try #require(await c.getSession(first))
        #expect(session.messageCount == 6)
        // (6 + 2) x 3: each row carries its own size and the session total is their sum —
        // no share of a turn prompt anywhere in it.
        #expect(session.tokenCount == 24)

        let listed = try await c.listSessions(modelId: model, limit: 100)
        #expect(listed.count == 1, "one conversation listed as \(listed.count) sessions")
    }

    @Test("distinct keys are distinct rows, and the same key on another model is another row")
    func keysPartitionRows() async throws {
        let path = uniqueDB("keys")
        let c = try await compressor(at: path)
        let a = try await c.resolveSession(externalKey: "K-A", modelId: "m1")
        let b = try await c.resolveSession(externalKey: "K-B", modelId: "m1")
        let aOtherModel = try await c.resolveSession(externalKey: "K-A", modelId: "m2")
        #expect(a != b)
        #expect(a != aOtherModel, "one client key across two models must not merge two transcripts")
        #expect(
            try await c.resolveSession(externalKey: "K-A", modelId: "m1") == a,
            "re-resolution must be stable")
    }

    /// A numeric key naming an existing row keeps meaning that row — that behaviour predates
    /// this fix and clients may already rely on it. A numeric key naming *nothing* used to
    /// write `messages` rows against a missing parent; now it owns a real row instead.
    @Test("numeric keys: an existing row is reused, a missing one is created rather than orphaned")
    func numericKeysStayHonest() async throws {
        let path = uniqueDB("numeric")
        let c = try await compressor(at: path)
        let made = try await c.createSession(modelId: "m1")
        #expect(
            try await c.resolveSession(externalKey: "\(made)", modelId: "m1") == made,
            "a numeric key naming a real row is that row")

        let orphanCandidate: Int64 = 9_999_999
        let resolved = try await c.resolveSession(externalKey: "\(orphanCandidate)", modelId: "m1")
        #expect(
            resolved != orphanCandidate,
            "a key naming a non-existent row must not be used as a parent")
        #expect(
            try await c.getSession(resolved) != nil,
            "the transcript has to land on a row that exists")
    }

    @Test("identity survives a restart — the key resolves to the same row after reopening")
    func identitySurvivesRestart() async throws {
        let path = uniqueDB("restart")
        let store1 = SQLiteStore(path: path)
        try await store1.open()
        let c1 = SessionCompressor(store: store1, fts: FTS5Search(store: store1))
        let first = try await c1.resolveSession(externalKey: "CONV-R", modelId: "m1")
        try await c1.addMessage(sessionId: first, role: "user", content: "U1", tokenCount: 7)
        await store1.close()

        let store2 = SQLiteStore(path: path)
        try await store2.open()
        let c2 = SessionCompressor(store: store2, fts: FTS5Search(store: store2))
        let again = try await c2.resolveSession(externalKey: "CONV-R", modelId: "m1")
        #expect(again == first, "a restart split the conversation into a second session row")

        // And the next turn appends to it rather than starting over.
        try await c2.addMessage(sessionId: again, role: "user", content: "U2", tokenCount: 9)
        let rows = try await c2.transcriptAscending(again, limit: 8)
        #expect(rows.map(\.content) == ["U1", "U2"])
        let session = try #require(await c2.getSession(again))
        #expect(session.tokenCount == 16, "the reopened session's total restarted at zero")
        await store2.close()
    }

    @Test("transcriptAscending answers oldest-first, which is what the overlap rule needs")
    func transcriptIsOldestFirst() async throws {
        let path = uniqueDB("ascending")
        let c = try await compressor(at: path)
        let sid = try await c.resolveSession(externalKey: "CONV-A", modelId: "m1")
        for text in ["U1", "U2", "U3"] {
            _ = try await c.addMessage(sessionId: sid, role: "user", content: text, tokenCount: 3)
        }
        let rows = try await c.transcriptAscending(sid, limit: 8)
        #expect(rows.map(\.content) == ["U1", "U2", "U3"])
    }

    /// `limit` counts *conversation* rows, not raw rows. An unfiltered reader answers short
    /// on a deep conversation (half its rows are replies), and the overlap rule reads that
    /// short head as "these turns are new" — duplicating history again, which is the exact
    /// defect identity was fixed for.
    @Test("12 turns deep, the reader still sees the whole head so only U13 is new")
    func deepConversationSeesTheWholeHead() async throws {
        let path = uniqueDB("deep")
        let c = try await compressor(at: path)
        let sid = try await c.resolveSession(externalKey: "CONV-DEEP", modelId: "m1")
        for index in 1 ... 12 {
            _ = try await c.addMessage(
                sessionId: sid, role: "user", content: "U\(index)", tokenCount: 4)
            _ = try await c.addMessage(
                sessionId: sid, role: "assistant", content: "A\(index)", tokenCount: 3)
        }

        let incoming: [TranscriptEntry] = (1 ... 13).map { entry("user", "U\($0)") }
        let stored = SessionTranscript.stored(
            try await c.transcriptAscending(sid, limit: incoming.count))
        #expect(
            stored.count == 12,
            """
            the reader shorted the head — asked for \(incoming.count) conversation rows, \
            got \(stored.count); the rest would be stored a second time
            """)
        #expect(
            SessionTranscript.newEntries(existing: stored, incoming: incoming)
                == [entry("user", "U13")])
    }
}

@Suite("Persist hop — no apportionment, one resolved row")
struct PersistHopSourceTests {

    /// The apportionment and the per-request `createSession` were the two defects; a rewrite
    /// that reintroduces either (or drops the dedupe read, which would silently store
    /// everything again) goes red here. Floors its own premises: a truncated read and a
    /// vanished call are both failures, not vacuous passes.
    @Test("ChatHandler persists through resolveSession + transcriptAscending, never tokensPerMsg")
    static func persistHopShape() throws {
        let src = try repoFile("Sources/ocoreai/Handlers/ChatHandler.swift")
        #expect(
            src.count > 20_000,
            "ChatHandler.swift read looks truncated — the scan cannot be trusted")
        #expect(
            !codeLines(src).contains { $0.contains("tokensPerMsg") },
            "dividing a turn's prompt over its rows is back — rows must carry their own size")
        #expect(
            src.components(separatedBy: "compressor.resolveSession(").count - 1 == 1,
            "the persist hop must resolve the conversation's one row (exactly once, for both response modes it shares)"
        )
        #expect(
            src.components(separatedBy: "compressor.transcriptAscending(").count - 1 == 1,
            "without the stored transcript the dedupe rule cannot see what is already written")
    }

    /// The roles a conversation contributes are decided once. A second hand-written list on
    /// the SQL side is how the reader and the rule would start comparing different shapes —
    /// and a reader that filters nothing has to guess the margin, which is how a deep
    /// conversation gets a short head.
    @Test("the SQL reader and the in-memory filter share one roles list")
    static func rolesHaveOneHome() throws {
        let reader = try repoFile("Sources/ocoreai/SQLite/SessionCompressor.swift")
        let rule = try repoFile("Sources/ocoreai/SQLite/SessionTranscript.swift")
        #expect(
            codeLines(rule).contains { $0.contains("static let persistedRoles") },
            "the roles a conversation contributes must be declared once, in SessionTranscript")
        #expect(
            codeLines(reader).contains { $0.contains("SessionTranscript.persistedRoles") },
            "transcriptAscending must filter with the shared roles list, not its own")
        #expect(
            !codeLines(reader).contains { $0.contains(#""user", "tool""#) },
            "a second copy of the persisted-roles list is back in the reader")

        let handler = try repoFile("Sources/ocoreai/Handlers/ChatHandler.swift")
        #expect(
            codeLines(handler).contains { $0.contains("limit: incoming.count)") },
            "the persist hop asks for exactly the entries it holds — a guessed margin shortens the head on deep conversations"
        )
    }

    private static func repoFile(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(relative)) {
                return String(decoding: data, as: UTF8.self)
            }
            dir.deleteLastPathComponent()
        }
        throw Missing(relative: relative)
    }

    /// Code lines only. Prose is allowed to *name* a shape a gate forbids — that is how a
    /// doc comment explains what regressed — while code is not allowed to bring it back. Same
    /// rule `make docs-check` applies to its `<!-- claim: … -->` greps.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
            line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
        }
    }

    private struct Missing: Error, CustomStringConvertible {
        let relative: String
        var description: String { "could not find \(relative) walking up from \(#filePath)" }
    }
}
