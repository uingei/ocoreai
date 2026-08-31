// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AuditPersistenceSQLiteTests.swift — Verify 段 P0：audit_traces 持久化面
///
/// 覆盖（精确值断言，零 count>N）：
/// 1. persist → 重开实例 → 全字段恢复（2026-08-31, Verify 段 P0 闭合）
/// 2. retentionDays 真消费：过窗 purge / 窗内保留
/// 3. INSERT OR IGNORE 幂等（同 id 重复落盘 = 1 行）
/// 4. clear → durable 面清空
/// 5. unbound → recentPersisted 返回 []（fast path 不炸）
/// 6. merge 纯函数：dedupe 精确（inMemory 优先）+ limit 精确 + 顺序精确

import Foundation
import Testing

@testable import ocoreai

@Suite("AuditTrail — SQLite persistence (Verify 段 P0, 2026-08-31)")
@MainActor
final class AuditPersistenceSQLiteTests {
    private func uniqueDB() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("audit_sql_\(UUID().uuidString).sqlite").path
    }

    @Test("persistThenReopenRestoresExactFields")
    func persistThenReopenRestoresExactFields() async throws {
        let path = uniqueDB()
        let store1 = SQLiteStore(path: path)
        try await store1.open()

        let trail = AuditTrail(maxEntries: 100, retentionDays: 30, serviceName: "test")
        await trail.attach(store: store1)
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "write_file",
            toolset: "core",
            arguments: ["path": "/tmp/x", "content": "hello"],
        )
        await trail.completeToken(token, status: .success, result: "wrote 5 bytes")
        try await Task.sleep(nanoseconds: 80_000_000)

        let persisted = await trail.recentPersisted(limit: 10)
        #expect(persisted.count == 1)
        #expect(persisted[0].id == token.id)
        #expect(persisted[0].caller == "agent")
        #expect(persisted[0].toolName == "write_file")
        #expect(persisted[0].toolset == "core")
        #expect(persisted[0].arguments == ["path": "/tmp/x", "content": "hello"])
        #expect(persisted[0].status == .success)
        #expect(persisted[0].resultSummary == "wrote 5 bytes")
        #expect(persisted[0].traceID == token.traceID)
        #expect(persisted[0].durationMs >= 0)
        #expect(persisted[0].durationMs.isFinite)
        await store1.close()

        // 重开实例 = 重启模拟；纯持久化读面恢复（不依赖内存环）
        let store2 = SQLiteStore(path: path)
        try await store2.open()
        let trail2 = AuditTrail(maxEntries: 100, retentionDays: 30, serviceName: "test")
        await trail2.attach(store: store2)
        let recovered = await trail2.recentPersisted(limit: 10)
        #expect(recovered.count == 1)
        #expect(recovered[0].id == token.id)
        #expect(recovered[0].arguments == ["path": "/tmp/x", "content": "hello"])
        #expect(recovered[0].status == .success)
        await store2.close()
    }

    @Test("retentionDaysPurgesExpiredAndKeepsCurrent")
    func retentionDaysPurgesExpiredAndKeepsCurrent() async throws {
        let now = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 UTC
        let store = SQLiteStore(path: uniqueDB())
        try await store.open()

        let expired = AuditEntry(
            id: "aud-exp-1",
            timestamp: now.addingTimeInterval(-31 * 86_400),  // 31 天前（> 30 天窗）
            caller: "agent",
            toolName: "write_file",
            toolset: "core",
            arguments: ["k": "v"],
            status: .success,
            resultSummary: "old",
            durationMs: 12.0,
            traceID: "tr-exp",
        )
        let fresh = AuditEntry(
            id: "aud-fresh-1",
            timestamp: now.addingTimeInterval(-1 * 86_400),  // 1 天前
            caller: "agent",
            toolName: "read_file",
            toolset: "core",
            arguments: ["k": "v"],
            status: .success,
            resultSummary: "new",
            durationMs: 3.0,
            traceID: "tr-fresh",
        )
        try await AuditTrail.persistEntry(store: store, entry: expired, retentionDays: 30, now: now)
        #expect(try await AuditTrail.readRecent(store: store, limit: 10).isEmpty)
        // 过窗行在下次 persist 时被清除 → 落新行后表内仅 1 行（retentionDays 真消费）
        try await AuditTrail.persistEntry(store: store, entry: fresh, retentionDays: 30, now: now)
        let rows = try await AuditTrail.readRecent(store: store, limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].id == "aud-fresh-1")
        #expect(rows[0].toolName == "read_file")
        await store.close()
    }

    @Test("duplicateIDPersistsExactlyOneRow")
    func duplicateIDPersistsExactlyOneRow() async throws {
        let store = SQLiteStore(path: uniqueDB())
        try await store.open()
        let entry = AuditEntry(
            id: "aud-dup-1",
            timestamp: Date(timeIntervalSince1970: 1_767_225_600),
            caller: "agent",
            toolName: "exec_command",
            toolset: "core",
            arguments: ["cmd": "ls"],
            status: .error,
            resultSummary: "dup",
            durationMs: 5.0,
            traceID: "tr-dup",
        )
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        try await AuditTrail.persistEntry(store: store, entry: entry, retentionDays: 30, now: now)
        try await AuditTrail.persistEntry(store: store, entry: entry, retentionDays: 30, now: now)
        let rows = try await AuditTrail.readRecent(store: store, limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].id == "aud-dup-1")
        await store.close()
    }

    @Test("clearWipesDurableFace")
    func clearWipesDurableFace() async throws {
        let store = SQLiteStore(path: uniqueDB())
        try await store.open()
        let entry = AuditEntry(
            id: "aud-clear-1",
            timestamp: Date(timeIntervalSince1970: 1_767_225_600),
            caller: "agent",
            toolName: "write_file",
            toolset: "core",
            arguments: [:],
            status: .success,
            resultSummary: "x",
            durationMs: 1.0,
            traceID: "tr-clear",
        )
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        try await AuditTrail.persistEntry(store: store, entry: entry, retentionDays: 30, now: now)
        #expect(try await AuditTrail.readRecent(store: store, limit: 10).count == 1)
        await AuditTrail.clearStore(store: store)
        #expect(try await AuditTrail.readRecent(store: store, limit: 10).isEmpty)
        await store.close()
    }

    @Test("unboundTrailYieldsEmptyPersistentFace")
    func unboundTrailYieldsEmptyPersistentFace() async {
        let trail = AuditTrail(maxEntries: 100, retentionDays: 30, serviceName: "test")
        // 未 attach → fast path：内存环照常，durable 读面 = []（不炸）
        let token = await trail.beginCall(
            caller: "agent", toolName: "t", toolset: "s", arguments: [:])
        await trail.completeToken(token, status: .success, result: "ok")
        let inMem = await trail.recent(limit: 10)
        #expect(inMem.count == 1)
        let persisted = await trail.recentPersisted(limit: 10)
        #expect(persisted.isEmpty)
    }
}

@Suite("AuditTrail — merge (UI 读面纯函数)")
struct AuditMergeTests {
    @Test("dedupeByIDWithInMemoryPriorityAndExactOrder")
    func dedupeByIDWithInMemoryPriorityAndExactOrder() {
        var old = AuditEntry(
            id: "a",
            timestamp: Date(timeIntervalSince1970: 100),
            caller: "c",
            toolName: "t",
            toolset: "s",
            arguments: [:],
            status: .success,
            resultSummary: "STALE",
            durationMs: 1,
            traceID: "tr",
        )
        let fresh = AuditEntry(
            id: "a",
            timestamp: Date(timeIntervalSince1970: 100),
            caller: "c",
            toolName: "t",
            toolset: "s",
            arguments: [:],
            status: .success,
            resultSummary: "FRESH",
            durationMs: 1,
            traceID: "tr",
        )
        _ = old
        var latest = AuditEntry(
            id: "b",
            timestamp: Date(timeIntervalSince1970: 200),
            caller: "c",
            toolName: "t",
            toolset: "s",
            arguments: [:],
            status: .success,
            resultSummary: "LATEST",
            durationMs: 1,
            traceID: "tr",
        )
        _ = latest
        let merged = AuditTrail.merge(
            inMemory: [fresh],
            persistent: [old, latest],
            limit: 10,
        )
        #expect(merged.count == 2)
        #expect(merged[0].id == "b")
        #expect(merged[1].id == "a")
        #expect(merged[1].resultSummary == "FRESH")  // inMemory 覆盖同 id 旧值
    }

    @Test("limitTrimsToExactCount")
    func limitTrimsToExactCount() {
        func make(_ id: String, _ ts: Double) -> AuditEntry {
            AuditEntry(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                caller: "c",
                toolName: "t",
                toolset: "s",
                arguments: [:],
                status: .success,
                resultSummary: id,
                durationMs: 1,
                traceID: "tr",
            )
        }
        let inMem = (0 ..< 4).map { make("m\($0)", Double(100 + $0)) }
        let pers = (0 ..< 4).map { make("p\($0)", Double(50 + $0)) }
        let merged = AuditTrail.merge(inMemory: inMem, persistent: pers, limit: 5)
        #expect(merged.count == 5)
        #expect(merged[0].id == "m3")  // 最大 ts 在前
        #expect(merged[4].id == "p3")  // 精确截断到第 5 位（第 5 大 ts = p3 的 53）
    }
}
