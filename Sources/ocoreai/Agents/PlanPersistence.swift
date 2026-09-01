// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PlanPersistence — `update_plan` 任务态 checkpoint + 重启恢复（Recover 环片 1）
///
/// 第一性：会话/记忆已持久化（消息落盘 + memory_events），**唯独任务态（plan）是纯内存**
/// （`PlanStateRecorder` 仅测试面，生产 publish→nil 静默丢弃）。长任务跨重启存活 = AGI
/// 具身"持续性"基线（桌面 app 会话态连续面）。工具行为面零漂移：`update_plan` 输出/事件
/// 仍 codex 原值，本类是事件面的**第二个消费者**（UI 面板此前 0 消费者，一并补齐）。
///
/// 边界（诚实记）：重启恢复的是"展示 + 可见历史"，**不回灌模型**（避免与模型当前
/// plan 认知冲突）；agent 自动续跑 = 后续切片，任务纪律触发式。
import Foundation
import Logging
import Observation

/// 一次 `update_plan` 的任务态快照（JSON 落库单元）。
struct PlanSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let step: String
        let status: String
    }

    let items: [Item]
    let explanation: String?
    let updatedAt: Int64
}

enum PlanPersistenceError: Error {
    case encode
    case decode
}

extension PlanPersistenceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .encode: "plan snapshot JSON encode failed"
        case .decode: "plan snapshot JSON decode failed"
        }
    }
}

/// 事件面第二消费者的注入缝隙 — 在工具 `@Sendable` 执行上下文（跨 actor）调用，
/// 故要求 `async`：消费侧（`@MainActor` store）跨 actor 合法跳转；落盘在消费侧自行
/// `Task` 化。工具面 `await chk?.planUpdated(...)` fire-and-forget 完成等待不阻塞输出。
protocol PlanRecoverySeam: Sendable {
    func planUpdated(explanation: String?, steps: [PlanUpdate.Step]) async
}

/// 任务态存储门面（SQLite-backed，UI 可观察）。
///
/// 双发布面解耦：
/// - `PlanStatePublisher`（内存事件）→ UI 实时刷新 / 测试捕获
/// - SQLite `plans` 表 → 重启恢复；`planUpdated` 同时刷新 `current` 并异步落盘
///
/// 接线（App 启动）：`PlanTaskStore.shared.attach(store:)` 绑定已打开的 DB
/// → `bootstrapBuiltInTools(planRecovery: PlanTaskStore.shared)` 注入工具
/// → 会话激活（ensureSession / 切换会话）后 `await rehydrate(sessionID:)`。
@MainActor
@Observable
final class PlanTaskStore {
    /// 进程级单例（UI 与工具面共享同一任务态）。
    /// 全局唯一实例、主线程创建+主线程消费（工具事件经
    /// `@MainActor` 工具闭包投递、UI 读面在 MainActor）——无跨线程竞争面。
    static let shared = PlanTaskStore()
    /// 当前会话的 plan 快照（任务面板渲染源）。
    var current: PlanSnapshot?
    /// 已激活的会话 id（观测面）。
    private(set) var activeSessionID: Int64?

    @ObservationIgnored private var backing: SQLiteStore?
    @ObservationIgnored private let logger = Logger(label: "ocoreai.plan")

    /// 实例 init（生产 = `shared` 单例；隔离实例供单测使用）。
    /// `nonisolated`：纯存储初始化、无 actor 状态触碰——`static let shared` 的
    /// 非隔离上下文构造合法。
    nonisolated init() {}

    /// App 启动时绑定已打开的 SQLite 连接（绑定前写入/读取被跳过，不静默）。
    func attach(store: SQLiteStore) {
        backing = store
        logger.debug("plan checkpoint store attached")
    }

    // MARK: - `PlanRecoverySeam`（工具事件面消费）

    func planUpdated(explanation: String?, steps: [PlanUpdate.Step]) {
        let snapshot = PlanSnapshot(
            items: steps.map { PlanSnapshot.Item(step: $0.step, status: $0.status) },
            explanation: explanation,
            updatedAt: Int64(Date().timeIntervalSince1970))
        current = snapshot
        guard let sessionID = activeSessionID else { return }  // 未激活会话 = 不落盘（面板态已生效）
        guard let backing else {
            logger.warning("plan checkpoint skipped: store not attached")
            return
        }
        let logger = self.logger
        Task {
            await Self.persist(
                store: backing, sessionID: sessionID, snapshot: snapshot, logger: logger)
        }
    }

    // MARK: - 重启恢复（Recover 片 1 核心）

    /// 会话激活后 hydrate 该会话最近一次 plan 快照；未写过/读失败 → `current = nil`（非错误）。
    func rehydrate(sessionID: Int64) async {
        activeSessionID = sessionID
        guard let backing else {
            current = nil
            return
        }
        current = await Self.readLatestSnapshot(store: backing, sessionID: sessionID)
    }

    // MARK: - SQLite（actor 隔离；static 纯函数便于离线精确值测试）

    nonisolated static func persist(
        store: SQLiteStore, sessionID: Int64, snapshot: PlanSnapshot, logger: Logger
    ) async {
        do {
            let itemsJSON = try encodeItems(snapshot.items)
            // explanation 可空：nil 走 3 参 SQL（不向绑定面传 nil，绕开 [AnyHashable] 无 optional 语义）
            if let expl = snapshot.explanation {
                try await store.execute(
                    sql: """
                        INSERT INTO plans (session_id, items_json, explanation, updated_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    parameters: [
                        sessionID as AnyHashable, itemsJSON as AnyHashable, expl as AnyHashable,
                        snapshot.updatedAt as AnyHashable,
                    ])
            } else {
                try await store.execute(
                    sql: """
                        INSERT INTO plans (session_id, items_json, updated_at)
                        VALUES (?, ?, ?)
                        """,
                    parameters: [
                        sessionID as AnyHashable, itemsJSON as AnyHashable,
                        snapshot.updatedAt as AnyHashable,
                    ])
            }
        } catch let e as PlanPersistenceError {
            logger.warning("plan checkpoint failed: \(e.localizedDescription)")
        } catch {
            logger.warning("plan checkpoint write failed: \(error.localizedDescription)")
        }
    }

    /// 单会话最近一次快照（updated_at DESC LIMIT 1）。读失败/空库 → nil。
    nonisolated static func readLatestSnapshot(
        store: SQLiteStore, sessionID: Int64
    ) async -> PlanSnapshot? {
        do {
            let rows = try await store.query(
                """
                SELECT items_json, explanation, updated_at
                FROM plans WHERE session_id = ?
                ORDER BY updated_at DESC LIMIT 1
                """,
                parameters: [sessionID])
            guard
                let row = rows.first,
                let itemsRaw = row["items_json"]?.asString,
                let updatedAtV = row["updated_at"]
            else {
                return nil
            }
            let updated: Int64
            switch updatedAtV {
            case .integer(let i): updated = i
            case .float(let d): updated = Int64(d)
            default:
                return nil
            }
            let items = try decodeItems(itemsRaw)
            return PlanSnapshot(
                items: items,
                explanation: row["explanation"]?.asString,
                updatedAt: updated)
        } catch {
            return nil
        }
    }

    // MARK: - JSON 编解码（纯函数，可精确值测试）

    nonisolated static func encodeItems(_ items: [PlanSnapshot.Item]) throws -> String {
        let data = try JSONEncoder().encode(items)
        guard let s = String(data: data, encoding: .utf8) else {
            throw PlanPersistenceError.encode
        }
        return s
    }

    nonisolated static func decodeItems(_ raw: String) throws -> [PlanSnapshot.Item] {
        guard let data = raw.data(using: .utf8) else {
            throw PlanPersistenceError.decode
        }
        return try JSONDecoder().decode([PlanSnapshot.Item].self, from: data)
    }
}

/// `PlanTaskStore` 作为工具事件面第二消费者注入（`planUpdated` 签名一致）。
extension PlanTaskStore: PlanRecoverySeam {}
