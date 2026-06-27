// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SQLiteStoreTests.swift — SQLite layer integration tests
///
/// Covers: open/close lifecycle, DML execution, scalarQuery, multi-row query,
/// FTS5 full-text search, memory_events six-element CRUD, Actor boundary safety.

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("SQLiteStore Lifecycle")
struct SQLiteStoreTests {
    func testPath() -> String {
        String(FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_test_\(UUID().uuidString.prefix(8)).sqlite").path)
    }

    @Test("open + close 基本生命周期")
    func testOpenClose() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        let val = try await store.scalarQuery(sql: "PRAGMA journal_mode;")
        #expect(val?.asString == "wal")
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("double open is safe")
    func testDoubleOpen() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await store.open()
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("schema 自动创建 — sessions + messages + memory_events + FTS5")
    func testSchemaCreated() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        let tables = try await store.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
        let tableNames = tables.map { row in row["name"]?.asString ?? "" }
        #expect(tableNames.contains("sessions"))
        #expect(tableNames.contains("messages"))
        #expect(tableNames.contains("memory_events"))
        #expect(tableNames.contains("messages_fts"))
        #expect(tableNames.contains("memory_events_fts"))
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }
}

@Suite("SQLiteStore DML")
struct SQLiteStoreDMLTests {
    func testPath() -> String {
        String(FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_test_\(UUID().uuidString.prefix(8)).sqlite").path)
    }

    @Test("execute 插入 + scalarQuery 查询")
    func testInsertAndScalarQuery() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["llama-3.1", Int64(Date().timeIntervalSince1970 * 1_000_000), Int64(Date().timeIntervalSince1970 * 1_000_000), 10, 500]
        )
        let count = try await store.scalarQuery(sql: "SELECT COUNT(*) FROM sessions")
        #expect(count?.asInt64 == 1)
        let maxId = try await store.scalarQuery(sql: "SELECT MAX(id) FROM sessions")
        #expect(maxId?.asInt64 == 1)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("execute 批量插入")
    func testBatchInsert() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model-a", Int64(Date().timeIntervalSince1970 * 1_000_000), Int64(Date().timeIntervalSince1970 * 1_000_000), 0, 0]
        )
        for i in 0..<5 {
            try await store.execute(
                sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
                parameters: [1, i % 2 == 0 ? "user" : "assistant", "Message \(i)", Int64(Date().timeIntervalSince1970 * 1_000_000), 10]
            )
        }
        let count = try await store.scalarQuery(sql: "SELECT COUNT(*) FROM messages WHERE session_id = 1")
        #expect(count?.asInt64 == 5)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("query 多行返回 + SendableValue 类型转换")
    func testQueryRows() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model-x", Int64(1000), Int64(2000), 42, 100]
        )
        let rows = try await store.query(
            "SELECT model_id, message_count, token_count FROM sessions WHERE id = 1"
        )
        #expect(rows.count == 1)
        #expect(rows[0]["model_id"]?.asString == "model-x")
        #expect(rows[0]["message_count"]?.asInt64 == 42)
        #expect(rows[0]["token_count"]?.asInt64 == 100)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("empty query 返回空数组")
    func testEmptyQuery() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        let rows = try await store.query("SELECT * FROM sessions WHERE 1 = 0")
        #expect(rows.isEmpty)
        let scalar = try await store.scalarQuery(sql: "SELECT id FROM sessions LIMIT 0")
        #expect(scalar == nil)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("参数绑定 — Int64/Double/String 类型")
    func testParameterBinding() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["bound-test", Int64(1000), Int64(2000), 10, 250]
        )
        let val = try await store.scalarQuery(sql: "SELECT model_id FROM sessions WHERE created_at > ?", parameters: [Int64(500)])
        #expect(val?.asString == "bound-test")
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("execute 错误处理 — 未连接报 notConnected")
    func testNotConnected() async throws {
        let store = SQLiteStore(path: testPath())
        var caughtError: Error? = nil
        do {
            try await store.execute(sql: "SELECT 1")
        } catch {
            caughtError = error
        }
        #expect(caughtError != nil)
        #expect(String(describing: caughtError!).localizedCaseInsensitiveContains("notConnected"))
    }
}

@Suite("SQLite FTS5")
struct SQLiteFTS5Tests {
    func testPath() -> String {
        String(FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_test_\(UUID().uuidString.prefix(8)).sqlite").path)
    }

    @Test("FTS5 全文搜索 — messages")
    func testFTS5Messages() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", Int64(Date().timeIntervalSince1970 * 1_000_000), Int64(Date().timeIntervalSince1970 * 1_000_000), 0, 0]
        )
        try await store.execute(
            sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: [1, "user", "How to debug a segmentation fault", Int64(1), 10]
        )
        try await store.execute(
            sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: [1, "assistant", "Check with LLDB", Int64(2), 5]
        )
        let results = try await store.query(
            "SELECT rowid, content FROM messages_fts WHERE messages_fts MATCH 'debug' ORDER BY rank"
        )
        #expect(results.count > 0)
        #expect(results[0]["content"]?.asString?.contains("debug") == true)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("FTS5 memory_events 全文搜索")
    func testFTS5MemoryEvents() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", now, now, 0, 0]
        )
        try await store.execute(
            sql: "INSERT INTO memory_events (session_id, timestamp, context, entities, cause, process, result, memory_type, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            parameters: [1, now, "ci-failure", "test", "out of memory during inference", "downgraded quantization to 4bit", "model loaded successfully", "fact", "test-mem-1"]
        )
        let results = try await store.query(
            "SELECT rowid, cause, result FROM memory_events_fts WHERE memory_events_fts MATCH 'inference' ORDER BY rank"
        )
        #expect(results.count > 0)
        #expect(results[0]["cause"]?.asString?.contains("inference") == true)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }
}

@Suite("Memory Events - Six Element Model")
struct MemoryEventTests {
    func testPath() -> String {
        String(FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_test_\(UUID().uuidString.prefix(8)).sqlite").path)
    }

    /// Bootstrap session for foreign key constraint on memory_events.session_id
    private func bootstrapSession(store: SQLiteStore) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", now, now, 0, 0]
        )
    }

    @Test("memory_event 六要素完整插入")
    func testSixElementInsert() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await bootstrapSession(store: store)
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO memory_events (session_id, timestamp, context, entities, cause, process, result, resolution, memory_type, dedup_key, confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            parameters: [1, now, "deployment", "test", "failed health check", "rolled back to previous image", "service restored", "resolved", "fact", "unique-key-1", 0.95]
        )
        let row = try await store.query("SELECT * FROM memory_events WHERE id = 1")
        #expect(row.count == 1)
        #expect(row[0]["context"]?.asString == "deployment")
        #expect(row[0]["resolution"]?.asString == "resolved")
        #expect(row[0]["memory_type"]?.asString == "fact")
        #expect(row[0]["confidence"]?.asDouble == 0.95)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("memory_event 去重 — dedup_key 唯一索引")
    func testDedupKey() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await bootstrapSession(store: store)
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO memory_events (session_id, timestamp, context, cause, process, result, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?)",
            parameters: [1, now, "ctx1", "cause1", "proc1", "result1", "dup-key"]
        )
        do {
            try await store.execute(
                sql: "INSERT INTO memory_events (session_id, timestamp, context, cause, process, result, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?)",
                parameters: [1, now, "ctx2", "cause2", "proc2", "result2", "dup-key"]
            )
            #expect(Bool(false), "Duplicate dedup_key should have thrown")
        } catch {
            #expect(String(describing: error).localizedCaseInsensitiveContains("UNIQUE"))
        }
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("CHECK 约束 — 非法 resolution 值")
    func testInvalidResolution() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await bootstrapSession(store: store)
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        do {
            try await store.execute(
                sql: "INSERT INTO memory_events (session_id, timestamp, context, cause, process, result, resolution, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                parameters: [1, now, "ctx", "cause", "proc", "result", "invalid-value", "chk-1"]
            )
            #expect(Bool(false), "Invalid resolution should have thrown")
        } catch {
            #expect(String(describing: error).localizedCaseInsensitiveContains("CHECK"))
        }
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("CHECK 约束 — 非法 memory_type")
    func testInvalidMemoryType() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await bootstrapSession(store: store)
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        do {
            try await store.execute(
                sql: "INSERT INTO memory_events (session_id, timestamp, context, cause, process, result, memory_type, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                parameters: [1, now, "ctx", "cause", "proc", "result", "unknown-type", "chk-2"]
            )
            #expect(Bool(false), "Invalid memory_type should have thrown")
        } catch {
            #expect(String(describing: error).localizedCaseInsensitiveContains("CHECK"))
        }
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("session DELETE CASCADE — messages 自动清理")
    func testCascadeDelete() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", now, now, 2, 100]
        )
        try await store.execute(
            sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: [1, "user", "hello", now, 5]
        )
        try await store.execute(
            sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: [1, "assistant", "world", now, 5]
        )
        let before = try await store.scalarQuery(sql: "SELECT COUNT(*) FROM messages")
        #expect(before?.asInt64 == 2)
        try await store.execute(sql: "DELETE FROM sessions WHERE id = 1")
        let after = try await store.scalarQuery(sql: "SELECT COUNT(*) FROM messages")
        #expect(after?.asInt64 == 0)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("session DELETE SET NULL — memory_events 保留")
    func testSetNullOnSessionDelete() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", now, now, 0, 0]
        )
        try await store.execute(
            sql: "INSERT INTO memory_events (session_id, timestamp, context, cause, process, result, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?)",
            parameters: [1, now, "ctx", "cause", "proc", "result", "perm-1"]
        )
        try await store.execute(sql: "DELETE FROM sessions WHERE id = 1")
        let row = try await store.query("SELECT id, session_id FROM memory_events WHERE id = 1")
        #expect(row.count == 1)
        #expect(row[0]["session_id"] == nil)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }

    @Test("memory_events 按 type 查询")
    func testQueryByMemoryType() async throws {
        let store = SQLiteStore(path: testPath())
        try await store.open()
        try await bootstrapSession(store: store)
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        for (i, mtype) in ["fact", "pattern", "transient", "preference"].enumerated() {
            try await store.execute(
                sql: "INSERT INTO memory_events (session_id, timestamp, context, cause, process, result, memory_type, dedup_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                parameters: [1, now + Int64(i * 1000), "ctx", "cause", "proc", "result", mtype, "type-\(i)"]
            )
        }
        let factCount = try await store.scalarQuery(sql: "SELECT COUNT(*) FROM memory_events WHERE memory_type = 'fact'")
        #expect(factCount?.asInt64 == 1)
        let allCount = try await store.scalarQuery(sql: "SELECT COUNT(*) FROM memory_events")
        #expect(allCount?.asInt64 == 4)
        await store.close()
        try? FileManager.default.removeItem(atPath: testPath())
    }
}

