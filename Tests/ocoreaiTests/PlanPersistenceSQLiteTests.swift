import Foundation
import Logging
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SQLite 持久化面 — persist → 重开实例 rehydrate 精确值恢复（重启模拟）
import Testing

@testable import ocoreai

@MainActor
final class PlanPersistenceSQLiteTests {
    private func uniqueDB() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plan_sql_\(UUID().uuidString).sqlite").path
    }

    private struct NoSessionID: Error {}

    private func makeSession(_ s: SQLiteStore) async throws -> Int64 {
        try await s.execute(
            sql:
                "INSERT INTO sessions (model_id, created_at, updated_at) VALUES ('t', 1735689600000, 1735689600000);"
        )
        let v = try await s.scalarQuery(sql: "SELECT last_insert_rowid();")
        guard let id = v?.asInt64 else { throw NoSessionID() }
        return id
    }

    @Test func persistThenRehydrateAcrossInstances() async throws {
        let path = uniqueDB()
        let items: [PlanSnapshot.Item] = [
            .init(step: "sync refs", status: "completed"),
            .init(step: "implement", status: "in_progress"),
        ]

        let store1 = SQLiteStore(path: path)
        try await store1.open()
        let sid = try await makeSession(store1)
        let snap = PlanSnapshot(
            items: items, explanation: "persist roundtrip", updatedAt: 1_735_692_800)
        await PlanTaskStore.persist(
            store: store1, sessionID: sid, snapshot: snap,
            logger: Logger(label: "test"))
        await store1.close()

        let store2 = SQLiteStore(path: path)
        try await store2.open()
        let s2 = PlanTaskStore()
        s2.attach(store: store2)
        await s2.rehydrate(sessionID: sid)
        await store2.close()

        #expect(s2.current?.items == items)
        #expect(s2.current?.explanation == "persist roundtrip")
        #expect(s2.current?.updatedAt == 1_735_692_800)
    }

    @Test func rehydrateEmptyYieldsNil() async throws {
        let store = SQLiteStore(path: uniqueDB())
        try await store.open()
        let sid = try await makeSession(store)
        let s = PlanTaskStore()
        s.attach(store: store)
        s.planUpdated(explanation: "pre", steps: [.init(step: "x", status: "pending")])
        await s.rehydrate(sessionID: sid)
        await store.close()
        #expect(s.current == nil)
        #expect(s.activeSessionID == sid)
    }
}
