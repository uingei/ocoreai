// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MinConfidenceBindingTests.swift — recallPermanentMemory minConfidence SQL bind 精确值测试
///
/// e5ff71e 改了 bind 参数(0.5→?)+ ChatHandler:620 传 0.6,但 Tests/ 0 条 recall 测试。
/// 这里钉死"minConfidence 真的绑进 SQL 并起作用"(不再硬编码 0.5):
///   1. 阈值 0.60 真滤(0.40 滤掉,0.72 在)——证明参数生效、非固定 0.5
///   2. 阈值 0.05 召回所有(0.72/0.40 都在)——证明参数变化真的影响结果
///   3. 阈值边界 confidence >= minConfidence 用 >= 而非 >
///   4. memory_types 过滤(fact/preference 在,pattern 出)
///
/// 注: recall 无 query 路径不碰 FTS,只靠 confidence+memory_type;
///     boostRecalled 会改 confidence(+0.05),所以断言用 context 识别行,
///     不读 confidence 值——避免和 recall 内部副作用冲突。
import Foundation
import Testing

@testable import ocoreai

@Suite("recallPermanentMemory minConfidence SQL bind 真生效")
struct MinConfidenceBindingTests {
    private func testPath() -> String {
        String(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("ocoreai_minconf_\(UUID().uuidString.prefix(8)).sqlite")
                .path)
    }

    /// 插一条 session(满足 memory_events.session_id FOREIGN KEY)+ 一条 memory_event
    private func seedRow(
        store: SQLiteStore, context: String,
        memoryType: String, confidence: Double,
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql:
                "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) "
                + "VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", now, now, 0, 0],
        )
        let sid = try await store.scalarQuery(
            sql: "SELECT id FROM sessions ORDER BY id DESC LIMIT 1")
        try await store.execute(
            sql:
                "INSERT INTO memory_events (session_id, timestamp, context, cause, process, "
                + "result, memory_type, dedup_key, tags, confidence) "
                + "VALUES (?, ?, ?, 'c\(context)', 'p\(context)', 'r\(context)', ?, ?, '[]', ?)",
            parameters: [
                sid?.asInt64 ?? 1, now, context, memoryType,
                "dedup-\(context)-\(UUID().uuidString)",
                confidence,
            ],
        )
    }

    private func makeCompressor(store: SQLiteStore) -> SessionCompressor {
        SessionCompressor(store: store, fts: FTS5Search(store: store))
    }

    @Test("min_confidence=0.60 真滤: 0.40 滤掉, 0.72 在(证明参数生效、非固定 0.5)")
    func testMinConfidenceFilters() async throws {
        let p = testPath()
        let store = SQLiteStore(path: p)
        try await store.open()
        defer { try? FileManager.default.removeItem(atPath: p) }

        try await seedRow(store: store, context: "high", memoryType: "fact", confidence: 0.72)
        try await seedRow(store: store, context: "low", memoryType: "fact", confidence: 0.40)

        let c = makeCompressor(store: store)
        // minConfidence 0.60: 0.72 >= 0.60 in, 0.40 < 0.60 out
        let r = try await c.recallPermanentMemory(minConfidence: 0.60)
        let contexts = Set(r.map(\.context))
        #expect(contexts == ["high"], "0.60 阈值应仅召回 high(0.72)")
        let high = r.first { $0.context == "high" }
        #expect(high?.confidence == 0.72)
        #expect(r.allSatisfy { $0.confidence >= 0.60 })
        #expect(!contexts.contains("low"), "0.40 应在 0.60 阈值下被滤")
        await store.close()
    }

    @Test("min_confidence=0.05 召回所有: 0.72 + 0.40 都在(证明参数变化真的改变结果)")
    func testLowerThresholdRecallsAll() async throws {
        let p = testPath()
        let store = SQLiteStore(path: p)
        try await store.open()
        defer { try? FileManager.default.removeItem(atPath: p) }

        try await seedRow(store: store, context: "high", memoryType: "fact", confidence: 0.72)
        try await seedRow(store: store, context: "low", memoryType: "fact", confidence: 0.40)

        let c = makeCompressor(store: store)
        let r = try await c.recallPermanentMemory(minConfidence: 0.05)
        let contexts = Set(r.map(\.context))
        #expect(contexts == ["high", "low"], "0.05 阈值应召回 high+low")
        #expect(r.count == 2)
        await store.close()
    }

    @Test("threshold edge case: confidence >= minConfidence 用 >= 不是 >")
    func testBoundaryInclusive() async throws {
        let p = testPath()
        let store = SQLiteStore(path: p)
        try await store.open()
        defer { try? FileManager.default.removeItem(atPath: p) }

        try await seedRow(store: store, context: "edge", memoryType: "fact", confidence: 0.62)
        try await seedRow(store: store, context: "below", memoryType: "fact", confidence: 0.40)

        let c = makeCompressor(store: store)
        // minConfidence 0.62: edge(0.62 >= 0.62) in, below(0.40 < 0.62) out
        let r = try await c.recallPermanentMemory(minConfidence: 0.62)
        let contexts = Set(r.map(\.context))
        #expect(contexts == ["edge"], "边界 confidence == minConfidence 应召回")
        #expect(r.first?.confidence == 0.62)
        #expect(!contexts.contains("below"))
        await store.close()
    }

    @Test("memory_types 过滤: fact+preference 在, pattern 出")
    func testMemoryTypeFilter() async throws {
        let p = testPath()
        let store = SQLiteStore(path: p)
        try await store.open()
        defer { try? FileManager.default.removeItem(atPath: p) }

        try await seedRow(store: store, context: "f", memoryType: "fact", confidence: 0.9)
        try await seedRow(store: store, context: "p", memoryType: "preference", confidence: 0.9)
        try await seedRow(store: store, context: "x", memoryType: "pattern", confidence: 0.9)

        let c = makeCompressor(store: store)
        let r = try await c.recallPermanentMemory(
            query: nil,
            memoryTypes: [.fact, .preference],
            minConfidence: 0.5,
            limit: 50
        )
        let contexts = Set(r.map(\.context))
        #expect(contexts == ["f", "p"], "fact+preference 应召回, pattern 被 memory_type 滤")
        await store.close()
    }

    /// 回归: FTS 命中 2 条 → expandByCues 走 "IN (?, ?)" 多占位符路径
    /// (修复前 boostRecalled 生成 "IN (??)" 必炸 near "?": syntax error)
    @Test("query 多行命中 expandByCues 多占位符不炸")
    func testExpandByCuesMultiID() async throws {
        let p = testPath()
        let store = SQLiteStore(path: p)
        try await store.open()
        defer { try? FileManager.default.removeItem(atPath: p) }

        try await store.execute(
            sql:
                "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", Int64(0), Int64(0), 0, 0]
        )
        let now = Int64(1_800_000_000_000)
        func seed(_ context: String, _ cause: String, _ confidence: Double) async throws {
            try await store.execute(
                sql:
                    "INSERT INTO memory_events (session_id, timestamp, context, cause, process, "
                    + "result, memory_type, dedup_key, tags, confidence) "
                    + "VALUES (1, ?, ?, ?, 'retry', 'ok', 'fact', ?, '[]', ?)",
                parameters: [now, context, cause, "dedup-\(cause)", confidence]
            )
        }
        try await seed("gpu-malloc", "oom-one", 0.8)
        try await seed("gpu-malloc", "oom-two", 0.7)

        let c = makeCompressor(store: store)
        let r = try await c.recallPermanentMemory(
            query: "retry", memoryTypes: [.fact], minConfidence: 0.5)
        #expect(
            r.count == 2,
            "两条共享 cue 的事件都应召回（修复前此处 boostRecalled/expandByCues 必炸 near 问号语法错）"
        )
        await store.close()
    }
}
