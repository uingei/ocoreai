// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FTS5Search.swift — Full-text search over session messages
///
/// Uses SQLite FTS5 virtual table for fast keyword search across all sessions.
/// Supports relevance scoring, snippet generation, and session filtering.

import Foundation

/// FTS5 full-text search operations — actor-isolated via SQLiteStore.
actor FTS5Search {
    private let store: SQLiteStore

    /// Create FTS5 query accessor.
    init(store: SQLiteStore) {
        self.store = store
    }

    /// Search message content using FTS5 query syntax.
    /// - Parameters:
    ///   - query: FTS5 search query (full-text match)
    ///   - sessionId: Optional session ID filter
    ///   - limit: Maximum results (default 50)
    /// - Returns: Array of search results with relevance scores
    func search(_ query: String, sessionId: Int64? = nil, limit: Int = 50) async throws -> [FTSSearchResult] {
        let whereClause: String
        let params: [AnyHashable]

        if let sid = sessionId {
            whereClause = "WHERE session_id = ? AND content MATCH ?"
            params = [sid, query]
        } else {
            whereClause = "WHERE content MATCH ?"
            params = [query]
        }

        let sql = """
        SELECT m.id, m.session_id, m.content, m.role, m.created_at,
               fts.rank AS score
        FROM messages_fts fts
        JOIN messages m ON fts.rowid = m.id
        \(whereClause)
        ORDER BY fts.rank ASC
        LIMIT ?
        """

        do {
            let rows = try await store.query(sql, parameters: params + [limit])
            return rows.map { row -> FTSSearchResult in
                let id = row["id"]?.asInt64 ?? 0
                let sessId = row["session_id"]?.asInt64 ?? 0
                let content = row["content"]?.asString ?? ""
                let score = row["score"]?.asDouble ?? 0.0
                return FTSSearchResult(
                    messageIds: [id],
                    snippet: String(content.prefix(200)),
                    score: score,
                    sessionId: sessId
                )
            }
        } catch let sqliteErr as SQLiteError {
            throw sqliteErr
        } catch {
            throw SQLiteError.queryFailed(detail: error.localizedDescription)
        }
    }

    /// Search recent messages within a session using time range.
    /// - Parameters:
    ///   - sessionId: Session ID to search in
    ///   - after: Only messages after this date
    ///   - before: Only messages before this date
    ///   - limit: Maximum results
    /// - Returns: Message contents for the time range
    func searchByTime(
        sessionId: Int64,
        after: Date,
        before: Date,
        limit: Int = 100
    ) async throws -> [MessageModel] {
        let sql = """
        SELECT id, session_id, role, content, created_at, token_count, tool_calls
        FROM messages
        WHERE session_id = ?
          AND created_at >= ?
          AND created_at <= ?
        ORDER BY created_at ASC
        LIMIT ?
        """

        let params: [AnyHashable] = [
            sessionId,
            Int64(after.timeIntervalSince1970 * 1_000_000),
            Int64(before.timeIntervalSince1970 * 1_000_000),
            limit,
        ]

        do {
            let rows = try await store.query(sql, parameters: params)
            return rows.compactMap { MessageModel(from: $0) }
        } catch let sqliteErr as SQLiteError {
            throw sqliteErr
        } catch {
            throw SQLiteError.queryFailed(detail: error.localizedDescription)
        }
    }

    /// Full-text search with session ID and FTS5 query.
    func searchByContent(
        sessionId: Int64,
        query: String,
        limit: Int = 50
    ) async throws -> [MessageModel] {
        let sql = """
        SELECT m.id, m.session_id, m.role, m.content, m.created_at,
               m.token_count, m.tool_calls, fts.rank
        FROM messages_fts fts
        JOIN messages m ON fts.rowid = m.id
        WHERE m.session_id = ? AND fts.content MATCH ?
        ORDER BY fts.rank ASC
        LIMIT ?
        """

        do {
            let rows = try await store.query(sql, parameters: [sessionId, query, limit])
            return rows.compactMap { MessageModel(from: $0) }
        } catch let sqliteErr as SQLiteError {
            throw sqliteErr
        } catch {
            throw SQLiteError.queryFailed(detail: error.localizedDescription)
        }
    }

    /// Count messages containing the search term.
    func countMatches(_ query: String, sessionId: Int64? = nil) async throws -> Int {
        let whereClause: String
        let params: [AnyHashable]

        if let sid = sessionId {
            whereClause = "WHERE session_id = ? AND content MATCH ?"
            params = [sid, query]
        } else {
            whereClause = "WHERE content MATCH ?"
            params = [query]
        }

        let sql = "SELECT COUNT(*) FROM messages_fts fts \(whereClause)"

        do {
            guard let count = try await store.scalarQuery(sql: sql, parameters: params)?.asInt64 else {
                return 0
            }
            return Int(count)
        } catch let sqliteErr as SQLiteError {
            throw sqliteErr
        } catch {
            throw SQLiteError.queryFailed(detail: error.localizedDescription)
        }
    }

    /// Rebuild FTS5 index from messages table (for data integrity).
    func rebuildIndex() async throws {
        do {
            // FTS5 internal command to rebuild
            try await store.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
        } catch let sqliteErr as SQLiteError {
            throw sqliteErr
        } catch {
            throw SQLiteError.schemaMigrationFailed(detail: error.localizedDescription)
        }
    }

    /// Delete FTS entries older than retention period.
    func purgeOldEntries(olderThan days: Int) async throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let timestamp = Int64(cutoff.timeIntervalSince1970 * 1_000_000)

        _ = try await store.execute(sql: """
            DELETE FROM messages
            WHERE created_at < ?
        """, parameters: [timestamp])
    }
}

// MARK: - MessageModel Extension

extension MessageModel {
    /// Initialize from a SQLite row dictionary.
    init?(from row: [String: SendableValue]) {
        guard
            let id = row["id"]?.asInt64,
            let sessionId = row["session_id"]?.asInt64,
            let role = row["role"]?.asString,
            let content = row["content"]?.asString,
            let createdAtTs = row["created_at"]?.asInt64
        else { return nil }

        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.createdAt = Date(timeIntervalSince1970: Double(createdAtTs) / 1_000_000)
        self.tokenCount = Self.getInt(row, "token_count") ?? 0
        self.toolCalls = Self.deserializeToolCalls(row["tool_calls"]?.asString)
        self.embedVector = row["embed_vector"]?.asData
    }
    
    private static func getInt(_ row: [String: SendableValue], _ key: String) -> Int? {
        guard let sv = row[key] else { return nil }
        switch sv {
        case .integer(let v): return Int(exactly: v)
        case .float(let v): return Int(exactly: v.rounded())
        case .text(let t): return Int(t)
        case .blob, .null: return nil
        }
    }
}