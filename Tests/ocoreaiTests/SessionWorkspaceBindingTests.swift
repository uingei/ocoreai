import Foundation
import Testing

@testable import ocoreai

/// Session↔worktree DB 绑定（codex new_worktree 持久化）。
/// 关键事实：`CREATE TABLE sessions` 本身不含 workspace_directory 列。所有库
/// （新/旧）都靠 ensureSchema 里的条件 ALTER（PRAGMA table_info 探测 → ADD COLUMN）
/// 补列；本机 libsqlite3 3.54 拒绝 `ADD COLUMN IF NOT EXISTS`，故必须走探测式迁移。
/// 这里全部用仓内 actor API（SQLiteStore.execute/query）实证，不 mock 存储层。
@Suite("SessionWorkspace DB 绑定 — 迁移 + 精确值往返", .serialized)
struct SessionWorkspaceBindingTests {

    private func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_bind_\(UUID().uuidString.prefix(8)).sqlite")
            .path
    }

    private func cleanup(_ p: String) {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + s) }
    }

    private func sessionsColumns(_ store: SQLiteStore) async throws -> [String] {
        let rows = try await store.query("PRAGMA table_info(sessions);", parameters: nil)
        return rows.compactMap { $0["name"]?.asString }
    }

    @Test("新库 open() 后 sessions 已带 workspace_directory 列（走条件迁移）")
    func newDBHasColumn() async throws {
        let p = tempDBPath()
        defer { cleanup(p) }
        let store = SQLiteStore(path: p)
        try await store.open()
        let cols = try await sessionsColumns(store)
        #expect(cols.contains("workspace_directory"), "缺列, 实际: \(cols)")
        #expect(cols.contains("model_id"), "既有列 model_id 不应丢失")
        #expect(cols.contains("ttl_days"), "既有列 ttl_days 不应丢失")
        await store.close()
    }

    @Test("已有行旧库 → DROP 去列 → reopen: ensureSchema 就地补列, 旧行不丢, 二次不重加")
    func preexistingDBMigrates() async throws {
        let p = tempDBPath()
        defer { cleanup(p) }
        // 第一遍 open：建表 + 条件补列；造一条迁移前形态的旧会话行。
        let s1 = SQLiteStore(path: p)
        try await s1.open()
        let comp = SessionCompressor(store: s1, fts: FTS5Search(store: s1))
        _ = try await comp.createSession(modelId: "legacy")
        // 用 DROP COLUMN 还原"迁移前"形态（3.54 支持；列消失即旧库等价态）
        try await s1.execute(sql: "ALTER TABLE sessions DROP COLUMN workspace_directory;")
        // fixture 核：此刻该列确已不在
        let before = try await sessionsColumns(s1)
        #expect(!before.contains("workspace_directory"), "fixture 未去列: \(before)")
        await s1.close()

        // 第二遍 open：ensureSchema 必须探测到缺列 → ADD COLUMN，且旧行仍在
        let s2 = SQLiteStore(path: p)
        do { try await s2.open() } catch {
            Issue.record("reopen 旧库应成功, got: \(error)")
            return
        }
        let cols = try await sessionsColumns(s2)
        #expect(cols.contains("workspace_directory"), "升级后应补列, 实际: \(cols)")
        #expect(cols.contains("model_id"), "迁移不丢既有列")
        let rows = try await s2.query("SELECT model_id FROM sessions", parameters: nil)
        #expect(
            rows.count == 1 && (rows[0]["model_id"]?.asString == "legacy"),
            "迁移不丢既有行, got \(rows)")

        // 第三遍 open：列已在 → 条件迁移必须幂等（不报 duplicate column）
        let s3 = SQLiteStore(path: p)
        do { try await s3.open() } catch {
            Issue.record("二次 reopen 应幂等成功, got: \(error)")
            return
        }
        await s3.close()
        await s2.close()
    }

    @Test("bind → getSession/listSessions 精确读回；clear → nil 双源核")
    func bindClearRoundTrip() async throws {
        let p = tempDBPath()
        defer { cleanup(p) }
        let store = SQLiteStore(path: p)
        try await store.open()
        let comp = SessionCompressor(store: store, fts: FTS5Search(store: store))

        let sid = try await comp.createSession(modelId: "bind-probe")
        let dir = "/tmp/ws-bind-\(UUID().uuidString.prefix(8))"

        #expect(try await comp.getSession(sid)?.workspaceDirectory == nil, "新会话默认无绑定")

        try await comp.bindWorkspace(dir, for: sid)
        #expect(try await comp.getSession(sid)?.workspaceDirectory == dir, "bind 后精确读回")

        let listed = try await comp.listSessions(limit: 20)
        #expect(listed.first { $0.id == sid }?.workspaceDirectory == dir, "listSessions 同值")

        try await comp.clearWorkspace(for: sid)
        #expect(try await comp.getSession(sid)?.workspaceDirectory == nil, "clear → nil")
        let listed2 = try await comp.listSessions(limit: 20)
        #expect(
            listed2.first { $0.id == sid }?.workspaceDirectory == nil, "clear 后 listSessions nil")
        await store.close()
    }

    /// The bind stamps `updated_at`; a unit mismatch is invisible in the directory round trip
    /// and fatal in the ordering the list page is built on. Sampled red 11-25 against the
    /// nanosecond stamp: the read-back date was year ~52 000 and the bound row led the list.
    @Test("bind 的 updated_at 走微秒：读回近此刻, 且不让绑定行永远霸占 ORDER BY updated_at DESC")
    func bindStampsMicrosecondsLikeEveryOtherWriter() async throws {
        let p = tempDBPath()
        defer { cleanup(p) }
        let store = SQLiteStore(path: p)
        try await store.open()
        let comp = SessionCompressor(store: store, fts: FTS5Search(store: store))

        let bound = try await comp.createSession(modelId: "stamp-probe")
        try await comp.bindWorkspace("/tmp/ws-stamp-\(UUID().uuidString.prefix(8))", for: bound)
        let row = try await comp.getSession(bound)
        let stamp = try #require(row?.updatedAt)
        #expect(
            abs(stamp.timeIntervalSinceNow) < 120,
            "bind 后读回应为此刻附近, got \(stamp) — 单位错了就是年份漂移")

        // A row touched later by ordinary traffic must still win the DESC ordering.
        try await comp.addMessage(sessionId: bound, role: "user", content: "old", tokenCount: 1)
        let later = try await comp.createSession(modelId: "stamp-probe")
        let listed = try await comp.listSessions(limit: 20)
        #expect(
            listed.first?.id == later,
            "新会话应排最前; bound 行霸榜说明 bind 的 stamp 单位又漂了")
        await store.close()
    }
}
