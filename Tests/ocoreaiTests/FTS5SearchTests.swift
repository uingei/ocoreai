// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FTS5 search surface — the wire behind `GET /sessions/search` (README.md L101
/// advertises it, and its unscoped form is the DEFAULT call).
///
/// Why this suite exists: `messages_fts` and `messages` both expose
/// `session_id`/`content`, so inside the JOIN any unqualified predicate column
/// makes SQLite fail at prepare time with "ambiguous column name". That killed
/// the unscoped branch (`?q=` with no `&session=`) and nothing caught it,
/// because no test had ever called `search()` with `sessionId: nil`.

import Foundation
import Testing

@testable import ocoreai

private func tempDB() -> String {
    (NSTemporaryDirectory() as NSString).appendingPathComponent(
        "fts5-search-test-\(UUID().uuidString).sqlite")
}

/// Two sessions: `alpha` is shared across both, `bridge` belongs to session A,
/// `harbor` to session B. Ids increase with insertion order.
private struct Corpus {
    let store: SQLiteStore
    let fts: FTS5Search
    let compressor: SessionCompressor
    let sessionA: Int64
    let sessionB: Int64
    let msgA: Int64
    let msgB: Int64

    init() async throws {
        let store = SQLiteStore(path: tempDB())
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)

        self.store = store
        self.fts = fts
        self.compressor = compressor
        self.sessionA = try await compressor.createSession(modelId: "test/model")
        self.sessionB = try await compressor.createSession(modelId: "test/model")
        self.msgA = try await compressor.addMessage(
            sessionId: sessionA, role: "user", content: "alpha bridge blueprint", tokenCount: 4)
        self.msgB = try await compressor.addMessage(
            sessionId: sessionB, role: "user", content: "alpha harbor blueprint", tokenCount: 4)
        _ = try await compressor.addMessage(
            sessionId: sessionB, role: "assistant", content: "zephyr unrelated notes", tokenCount: 4
        )
    }

    func close() {
        Task { await store.close() }
    }
}

@Suite("FTS5Search.search — the unscoped branch is the documented default")
struct FTS5UnscopedSearchTests {

    @Test("an unscoped search returns hits from every session")
    func unscopedSpansSessions() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        let hits = try await corpus.fts.search("zephyr")

        #expect(hits.count == 1)
        #expect(hits[0].sessionId == corpus.sessionB)
        #expect(hits[0].snippet.contains("zephyr"))
    }

    @Test("a term shared across sessions returns one hit per message")
    func sharedTermAttributesEachHit() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        let hits = try await corpus.fts.search("alpha")

        #expect(hits.count == 2)
        // Attribution is per message, not per query: every hit names the session
        // and message that actually contain the term.
        #expect(hits.map(\.sessionId) == [corpus.sessionA, corpus.sessionB])
        #expect(hits.map(\.messageIds) == [[corpus.msgA], [corpus.msgB]])
    }

    @Test("an absent term is an empty result, never an error")
    func absentTermIsEmpty() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        #expect(try await corpus.fts.search("glacier").isEmpty)
    }

    @Test("limit caps the result set at exactly that many rows")
    func limitCaps() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        #expect(try await corpus.fts.search("alpha", limit: 1).count == 1)
        #expect(try await corpus.fts.search("alpha", limit: 2).count == 2)
    }

    @Test("snippet is truncated to 200 characters")
    func snippetCappedAt200() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }
        _ = try await corpus.compressor.addMessage(
            sessionId: corpus.sessionA,
            role: "user",
            content: String(repeating: "mangrove ", count: 60),  // 540 characters
            tokenCount: 9)

        let hits = try await corpus.fts.search("mangrove")

        #expect(hits.count == 1)
        #expect(hits[0].snippet.count == 200)
    }
}

@Suite("FTS5Search — scoped filtering actually bites")
struct FTS5ScopedSearchTests {

    @Test("scoping to one session excludes the other session's hit")
    func scopeExcludes() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        let hits = try await corpus.fts.search("alpha", sessionId: corpus.sessionA)

        #expect(hits.count == 1)
        #expect(hits[0].messageIds == [corpus.msgA])
        #expect(hits[0].sessionId == corpus.sessionA)
    }

    @Test("scoping to a session without the term is empty, not the whole corpus")
    func scopeWithNoMatchIsEmpty() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        #expect(try await corpus.fts.search("bridge", sessionId: corpus.sessionB).isEmpty)
    }

    @Test("searchByContent stays inside its session")
    func searchByContentScoped() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        let rows = try await corpus.fts.searchByContent(sessionId: corpus.sessionA, query: "alpha")

        #expect(rows.count == 1)
        #expect(rows[0].sessionId == corpus.sessionA)
        #expect(rows[0].content == "alpha bridge blueprint")
    }

    @Test("countMatches agrees with search in both scopes")
    func countMatchesBothScopes() async throws {
        let corpus = try await Corpus()
        defer { corpus.close() }

        #expect(try await corpus.fts.countMatches("alpha") == 2)
        #expect(try await corpus.fts.countMatches("alpha", sessionId: corpus.sessionA) == 1)
        #expect(try await corpus.fts.countMatches("alpha", sessionId: corpus.sessionB) == 1)
        #expect(try await corpus.fts.countMatches("glacier") == 0)
    }
}
