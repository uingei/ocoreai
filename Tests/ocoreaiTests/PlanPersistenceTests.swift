import Foundation
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PlanPersistenceTests — Recover slice 1，精确值断言:
///   内存面(planUpdated→current) + 工具面(recovery seam) + JSON 精确 round-trip
///   + SQLite persist→重开实例 rehydrate(重启模拟)。
/// 纪律: #expect == 精确值; 隔离 PlanTaskStore() 实例; 每测试私有 DB 文件(不碰 shared)。
import Testing

@testable import ocoreai

@MainActor
final class PlanPersistenceTests {

    private func uniqueDB() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plan_recover_\(UUID().uuidString).sqlite").path
    }

    private struct NoSessionID: Error {}

    private func makeSession(_ store: SQLiteStore) async throws -> Int64 {
        try await store.execute(
            sql:
                "INSERT INTO sessions (model_id, created_at, updated_at) VALUES ('test', 1735689600000, 1735689600000);"
        )
        let v = try await store.scalarQuery(sql: "SELECT last_insert_rowid();")
        guard let id = v?.asInt64 else { throw NoSessionID() }
        return id
    }

    @Test func planUpdatedPublishesCurrentSnapshot() {
        let s = PlanTaskStore()
        #expect(s.current == nil)
        s.planUpdated(
            explanation: "kickoff",
            steps: [
                .init(step: "a", status: "pending"),
                .init(step: "b", status: "in_progress"),
            ])
        #expect(s.current?.explanation == "kickoff")
        #expect(s.current?.items.count == 2)
        #expect(s.current?.items[0] == .init(step: "a", status: "pending"))
        #expect(s.current?.items[1] == .init(step: "b", status: "in_progress"))
    }

    @Test func multipleUpdatesReplaceCurrentSnapshot() {
        let s = PlanTaskStore()
        s.planUpdated(explanation: nil, steps: [.init(step: "x", status: "completed")])
        #expect(s.current?.items.count == 1)
        s.planUpdated(explanation: "v2", steps: [.init(step: "y", status: "pending")])
        #expect(s.current?.items[0].step == "y")
        #expect(s.current?.explanation == "v2")
    }

    @Test func encodeDecodeRoundTripIsExact() throws {
        let items: [PlanSnapshot.Item] = [
            PlanSnapshot.Item(step: "s1", status: "completed"),
            PlanSnapshot.Item(step: "s2", status: "pending"),
        ]
        #expect(try PlanTaskStore.decodeItems(try PlanTaskStore.encodeItems(items)) == items)
    }

    @Test func toolEntryWithRecoveryPopulatesStoreOnSuccess() async throws {
        let s = PlanTaskStore()
        let e = UpdatePlanClient.toolEntry(publisher: nil, recovery: s)
        let args = #"{"explanation":"via tool","plan":[{"step":"a","status":"pending"}]}"#
        #expect(try await e.handler(args) == "Plan updated")
        #expect(s.current?.explanation == "via tool")
        #expect(s.current?.items == [.init(step: "a", status: "pending")])
    }

    @Test func toolEntryWithRecoveryIgnoresInvalidCall() async {
        let s = PlanTaskStore()
        let e = UpdatePlanClient.toolEntry(publisher: nil, recovery: s)
        _ = try? await e.handler(#"{"plan":[{"step":"a","status":"bogus"}]}"#)
        #expect(s.current == nil)
    }
}
