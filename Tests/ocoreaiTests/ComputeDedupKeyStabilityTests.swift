// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ComputeDedupKeyStabilityTests.swift — dedup_key 跨进程稳定性 + upsert 真合并
///
/// MemoryEventModel.computeDedupKey 此前 = raw.hashValue.description —
/// Swift String.hashValue **进程间随机化**（HashDoS 防护种子），两次 swift 进程
/// 同一输入实测不同(5574914235216148489 vs 6832846833449623354)。dedup_key 是唯一索引/
/// ON CONFLICT 去重依据 → **进程重启后同一条记忆每次生成新 key，永不命中 upsert**，
/// 重复行无限堆积 + max(confidence) 合并语义失效。
///
/// 修复后 = FNV-1a 64 确定性哈希。本测试钉死两件事：
///   1. 跨进程稳定（两次独立计算 byte-identical）
///   2. 同 (context,cause,entities) 两次 MemoryEvent → 同一 dedupKey → storeMemoryEvent
///      走 ON CONFLICT 分支真正合并为 1 行（confidence 取 max），而非插 2 行
import Foundation
import Testing

@testable import ocoreai

@Suite("dedup_key 跨进程稳定 + upsert 真合并")
struct ComputeDedupKeyStabilityTests {
    /// FNV-1a 64 — 与 MemoryEventModel stableHash64 实现同源（跨进程稳定判据）。
    /// 若上游改实现，此函数同步改，否则测试失效。
    private func fnv1a64(_ input: String) -> UInt64 {
        var hash: UInt64 = 0xcbf_29ce_4842_2325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private func testPath() -> String {
        FileManager.default
            .temporaryDirectory
            .appendingPathComponent("ocoreai_dedup_\(UUID().uuidString.prefix(8)).sqlite")
            .path
    }

    @Test("同一 (context,cause,entities) 两次 init → 同一 dedupKey（确定性）")
    func sameInputDifferentInitCallsDeterministic() {
        let a = MemoryEvent(
            sessionId: 1, context: "debugging", entities: ["session"],
            cause: "recall 主路径必炸", process: "修 3 处", result: "全绿",
            memoryType: .pattern,
        )
        let b = MemoryEvent(
            sessionId: 1, context: "debugging", entities: ["session"],
            cause: "recall 主路径必炸", process: "fix 3", result: "all green",
            memoryType: .pattern,
        )
        #expect(
            a.dedupKey == b.dedupKey,
            "FNV-1a 确定性: 同输入两次 init 必须同 key — 当前 a=\(a.dedupKey) b=\(b.dedupKey)")
    }

    @Test("dedupKey 与 FNV-1a 64 同输入同输出（可复现锚点）")
    func fnvDeterministicMatchesReference() {
        let ctx = "debugging"
        let cause = "recall 主路径必炸"
        let entities: [String] = ["session"]
        let raw = "\(ctx)|\(cause)|\(entities.sorted().joined(separator: ","))"
        let expected = "dedup-\(fnv1a64(raw))"
        let a = MemoryEvent(
            sessionId: 1, context: ctx, entities: entities,
            cause: cause, process: "p", result: "r", memoryType: .fact,
        )
        #expect(
            a.dedupKey == expected,
            "FNV-1a 64 锚点: computed \(a.dedupKey) != expected \(expected)")
    }

    @Test("不同 context → 不同 dedupKey（去重键不串）")
    func differentContextProducesDifferentKey() {
        let a = MemoryEvent(
            sessionId: 1, context: "debugging", entities: [], cause: "c",
            process: "p", result: "r", memoryType: .fact,
        )
        let b = MemoryEvent(
            sessionId: 1, context: "debugging-other", entities: [], cause: "c",
            process: "p", result: "r", memoryType: .fact,
        )
        #expect(a.dedupKey != b.dedupKey)
    }

    @Test("storeMemoryEvent upsert 真合并：同 key 二次写 confidence max，仅 1 行")
    func upsertConsolidatesRatherThanDuplicates() async throws {
        let path = testPath()
        let store = SQLiteStore(path: path)
        try await store.open()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // 满足 memory_events.session_id FOREIGN KEY
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await store.execute(
            sql:
                "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
            parameters: ["model", now, now, 0, 0],
        )
        let sid = try await store.scalarQuery(
            sql: "SELECT id FROM sessions ORDER BY id DESC LIMIT 1")
        let sidInt = sid?.asInt64 ?? 1

        let e1 = MemoryEvent(
            sessionId: sidInt, context: "prefers dark mode", entities: [],
            cause: "ui setup", process: "asked", result: "set to dark",
            memoryType: .preference, confidence: 0.30,
        )
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        try await compressor.storeMemoryEvent(e1)

        // 同 (context,cause,entities) 再写 — 期望同 key 命中 upsert 分支
        let e2 = MemoryEvent(
            sessionId: sidInt, context: "prefers dark mode", entities: [],
            cause: "ui setup", process: "asked again", result: "still dark",
            memoryType: .preference, confidence: 0.90,
        )
        #expect(e2.dedupKey == e1.dedupKey, "dedupKey 必须一致")
        try await compressor.storeMemoryEvent(e2)

        let rows = try await store.query(
            "SELECT COUNT(*) AS n, MAX(confidence) AS m FROM memory_events WHERE dedup_key = '\(e1.dedupKey)'"
        )
        guard let row = rows.first else {
            #expect(false, "row 未找到")
            return
        }
        let n = row["n"]?.asInt64 ?? -1
        let m = row["m"]?.asDouble ?? -1
        #expect(n == 1, "upsert 应合并为 1 行, 实际 n=\(n) — 旧 hashValue 实现下会是 2")
        #expect(m == 0.90, "confidence 应取 max(0.30, 0.90) = 0.90, 实际 m=\(m)")
        await store.close()
    }
}
