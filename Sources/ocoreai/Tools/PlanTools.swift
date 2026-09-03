// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `update_plan` — codex plan 工具原语(0.160.0 HEAD, #41630 默认启用, 逐行对齐):
///
///   update_plan({explanation?: String, plan: [{step: String, status: enum}]})
///     → 校验通过后输出 `Plan updated`(codex `PLAN_UPDATED_MESSAGE`)
///
/// 基准: codex `codex-rs/core/src/tools/handlers/plan_spec.rs`
/// (ToolSpec: name=`update_plan`, required=`["plan"]`, `explanation` optional,
///  `plan` = array of object `{step: string, status: enum[pending|in_progress|completed]}`,
///  description 含 "At most one step can be in_progress at a time.")
/// + `codex-rs/core/src/tools/handlers/plan.rs`
/// (`PLAN_UPDATED_MESSAGE = "Plan updated"`, output success=true;
///  参数解析失败/状态越界 = `RespondToModel`(可读拒绝, 不发事件))
/// + config `tools.update_plan.enabled` 默认 **false**（codex `#41744`，2026-08-31：
///  default→false，opt-in；#41630 的 default=true 已被上游翻转；API 面显式开启才注册）。
///
/// ocoreai 对齐:
///   - 工具名 / 参数名 / required 面 / 输出文案 = codex 原值;
///   - 事件驱动: 成功路径发 PlanUpdate 事件(`PlanStatePublisher`) — 对齐 codex
///     `send_event(EventMsg::PlanUpdate(args))`; 事件只影响 UI, 不影响工具返回
///     (codex handler 同理: 输出恒 `Plan updated`, 无持久状态);
///   - 「至多 1 个 in_progress」: codex spec description 声明该约束, ocoreai 同声明
///     并在 `validate` 提供可测实现(精确值断言);
///   - Plan-mode 禁用分支: ocoreai 无 ModeKind(无同形状信号)→ 不实现, 与 clock
///     `sleep` 不实现「新输入提前唤醒」同一先例(诚实记边界, 不造状态)。
///
/// 定位: Agent←codex 基准对齐线。多步任务的规划/进度上报原语, 补齐 ocoreai 工具面
/// (此前 0 注册), 与 clock 同属 agent-loop 原语层。
import Foundation

// MARK: - 纯核对(codex plan_spec.rs / plan.rs 语义)

/// 校验失败的拒绝报告(codex `RespondToModel` 可读错误语义)。
struct PlanUpdateError: Error {
    let message: String
}

enum PlanUpdate {
    struct Step: Equatable, Codable, Sendable {
        let step: String
        let status: String
    }

    /// 合法状态集(codex `status`: `enum[pending, in_progress, completed]`)。
    static let allowedStatuses: Set<String> = ["pending", "in_progress", "completed"]

    struct Validated: Equatable, Sendable {
        let explanation: String?
        let steps: [Step]
    }

    /// 纯核对(离线可测, 无 I/O):
    /// - `plan` 空/缺失 → 拒绝(无可上报内容; codex required=`["plan"]`);
    /// - step 缺文本 / 状态越界 → 拒绝(codex 枚举面外 = 非法, 可读拒绝);
    /// - 「至多 1 个 in_progress」按 codex spec description 声明的约束校验。
    static func validate(
        explanation: String?,
        plan: [(step: String?, status: String?)]?
    ) -> Result<Validated, PlanUpdateError> {
        func reject(_ message: String) -> Result<Validated, PlanUpdateError> {
            .failure(PlanUpdateError(message: message))
        }
        guard let items = plan, !items.isEmpty else {
            return reject("update_plan: error: 'plan' must be a non-empty array of {step, status}")
        }
        var inProgress = 0
        var steps: [Step] = []
        for (i, item) in items.enumerated() {
            guard let stepText = item.step, !stepText.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                return reject("update_plan: error: plan[\(i)].step must be a non-empty string")
            }
            guard let status = item.status, allowedStatuses.contains(status) else {
                let got = item.status ?? "missing"
                return reject(
                    "update_plan: error: plan[\(i)].status must be one of "
                        + "pending | in_progress | completed (got \"\(got)\")")
            }
            if status == "in_progress" { inProgress += 1 }
            steps.append(Step(step: stepText, status: status))
        }
        if inProgress > 1 {
            return reject(
                "update_plan: error: at most one step may be in_progress (got \(inProgress))")
        }
        return .success(Validated(explanation: explanation, steps: steps))
    }

    /// 输出文案(codex `PLAN_UPDATED_MESSAGE = "Plan updated"`; 固定, 精确断言锚点)。
    static let planUpdated = "Plan updated"
}

// MARK: - Args(Codable 解码边界)

/// `plan` 元素: `step`/`status` 解码为可选面, 由 `validate` 统一拒绝(可读错误)。
struct PlanStepArg: Codable, Sendable {
    let step: String?
    let status: String?
}

struct UpdatePlanArgs: Codable, Sendable {
    let explanation: String?
    let plan: [PlanStepArg]?
}

// MARK: - 事件交付 seam(对齐 codex `send_event(EventMsg::PlanUpdate)`)

/// Plan 更新事件订阅者 — 生产实现转发 UI(任务面板);测试注入记录器断言精确值。
/// 无订阅者时事件静默丢弃(工具输出仍为 `Plan updated`, 模型侧语义不变;
/// codex 同理: 事件只影响 UI, 不影响工具返回值)。
protocol PlanStatePublisher: Sendable {
    func publish(explanation: String?, steps: [PlanUpdate.Step])
}

final class PlanStateRecorder: PlanStatePublisher, @unchecked Sendable {
    // 内部 NSLock 串行化 append;事件面只有 publish 一个入口, 无数据竞争。
    private let lock = NSLock()
    private var _events: [(explanation: String?, steps: [PlanUpdate.Step])] = []

    func publish(explanation: String?, steps: [PlanUpdate.Step]) {
        lock.lock()
        _events.append((explanation, steps))
        lock.unlock()
    }

    var events: [(explanation: String?, steps: [PlanUpdate.Step])] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
}

// MARK: - Tool 面(注册单元)

enum UpdatePlanClient {
    static let toolName = "update_plan"

    static func toolEntry(
        publisher: PlanStateRecorder? = nil,
        recovery: PlanRecoverySeam? = nil,
    ) -> ToolEntry {
        // publisher 具体类型捕获(闭包 @Sendable 安全);nil = 无事件交付(模型侧语义不变)。
        // recovery = Recover 片 1 第二消费者(任务态 checkpoint + UI 面板);nil = 纯内存事件面
        // (测试面 / opt-in 未开持久化)。两消费者都 fire-and-forget: 工具输出恒 `Plan updated`。
        let rec = publisher
        let chk = recovery
        return ToolEntry.typed(
            name: toolName,
            toolset: "plan",
            argsType: UpdatePlanArgs.self,
            description:
                "Update the task plan — the running checklist of remaining work. "
                + "Provide an optional explanation and a list of plan items, each with "
                + "a step (text) and a status (pending | in_progress | completed). "
                + "At most one step can be in_progress at a time.",
            schema: ToolSchema(parameters: [
                "explanation": ToolParameter(
                    type: .string,
                    description: "Optional explanation for this plan update."
                ),
                "plan": ToolParameter(
                    type: .array,
                    description: "The list of steps",
                    items: ToolParameter(
                        type: .object,
                        description: "A plan step with `step` (text) and `status` "
                            + "(pending | in_progress | completed)",
                        required: ["step", "status"]
                    )
                ),
            ])
        ) { args in
            let plan = args.plan?.map { (step: $0.step, status: $0.status) }
            switch PlanUpdate.validate(explanation: args.explanation, plan: plan) {
            case .failure(let err): return err.message
            case .success(let v):
                rec?.publish(explanation: v.explanation, steps: v.steps)
                await chk?.planUpdated(explanation: v.explanation, steps: v.steps)
                return PlanUpdate.planUpdated
            }
        }
    }
}

// MARK: - 读面 (get_plan — 模型的 durable 任务态读回, Recover 片 1 的 agent 侧闭环)

/// `get_plan` — 读回本会话最近一次 `update_plan` 的 durable 快照（`update_plan` 的模型侧读面）:
///
///   get_plan()  → step × [completed|in_progress|pending] + 计数 + note(explanation?) + updated 时刻
///
/// 定位（Recover 片 1 收口, `PlanPersistence.swift:11` 点名的"后续切片"）: plan 状态
/// durable（`plans` 表, `PlanTaskStore.persist`）+ rehydrate（`PlanTaskStore.rehydrate`,
/// 会话激活后 hydrate）——但两者此前只喂 UI 面板（`PlanCard`）, **模型侧零读面**
/// （grep `get_plan`/`plan_status`/`read_plan` 全库 = 0 命中）: 模型自己的任务态只活在
/// 对话历史里（会被 compaction 剥掉）, 而 durable 副本就在 `PlanTaskStore.shared.current`
/// （与 UI 面板同源的 SSOT）。本工具把该读回暴露给模型——断点续跑时模型可自问
/// "我做到哪步了、哪些 pending", 决策权仍在模型。
///
/// 与 check_tools / observe_state 同一纪律: 只读、零副作用、**不替模型决策**
/// （不自动 resume、不改 plan）; 缺席 = 诚实报「本会话未记录过 plan」, 不伪造在场。
/// 三仓无对位物 = Apple 原生 / 产品自有的 durable 任务态读回（无基准分叉风险）。

/// 纯渲染（离线可测; 快照注入, 不触 PlanTaskStore / SQLite / wall clock）。
enum PlanRead {
    /// UTC 时刻字符串（`curr_time` 同纪律: `yyyy-MM-dd HH:mm:ss 'UTC'`, en_US_POSIX + GMT）,
    /// 固定 formatter — 精确断言锚点（本地时区/locale 漂移不污染输出）。
    static func utcTime(_ timestamp: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// 渲染精确形态:
    /// ```
    /// plan — 4 steps: 1 completed, 1 in_progress, 2 pending
    /// note: 修复感知轴            (explanation 非空时)
    /// 1. [x] init repo (completed)
    /// 2. [>] fix channel gating (in_progress)
    /// 3. [ ] add tests (pending)
    /// 4. [ ] docs (pending)
    /// updated: 2026-09-03 06:00:11 UTC
    /// ```
    /// 缺席 (nil) → 诚实一行（含出路指引, 不伪造在场）。
    static func render(_ snapshot: PlanSnapshot?) -> String {
        guard let s = snapshot else {
            return "no plan recorded in this session — call update_plan to create one"
        }
        let done = s.items.filter { $0.status == "completed" }.count
        let doing = s.items.filter { $0.status == "in_progress" }.count
        let pending = s.items.filter { $0.status == "pending" }.count
        var out: [String] = []
        out.append(
            "plan — \(s.items.count) steps: \(done) completed, \(doing) in_progress, \(pending) pending"
        )
        if let note = s.explanation?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty
        {
            out.append("note: \(note)")
        }
        for (i, it) in s.items.enumerated() {
            let tick: String
            switch it.status {
            case "completed": tick = "x"
            case "in_progress": tick = ">"
            case "pending": tick = " "
            default: tick = "?"  // 库内未知状态（非三值）→ 显式标记, 不静默吞
            }
            out.append("\(i + 1). [\(tick)] \(it.step) (\(it.status))")
        }
        out.append("updated: \(utcTime(s.updatedAt))")
        return out.joined(separator: "\n")
    }
}

/// `get_plan` — 零参查询面（真值源 = `PlanTaskStore.shared.current`, 与 UI 面板同源 SSOT）
enum GetPlanClient {
    static let toolName = "get_plan"

    static func toolEntry() -> ToolEntry {
        entry(store: nil)
    }

    /// seam 注入口(离线可测真 handler): nil = 走 PlanTaskStore.shared 全局(生产);
    /// 非 nil = seam 读注入的快照(handler 真跑, 不触 PlanTaskStore/SQLite)。
    static func entry(store: PlanTaskStore?) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "plan",
            argsType: Args.self,
            description:
                "Report the durable task plan of the current session — the latest snapshot "
                + "written by `update_plan` (steps with completed/in_progress/pending, counts, "
                + "note, updated time). Reads the persisted plan (survives conversation "
                + "compaction), not the conversation itself — use to resume a task at its "
                + "exact breakpoint. Read-only, no side effects, no re-planning. "
                + "When no plan has been recorded, reports that honestly.",
            schema: ToolSchema(parameters: [:])
        ) { _ in
            await runForTool(store: store)
        }
    }

    struct Args: Codable, Sendable {}

    /// 生产路径: 读 PlanTaskStore.shared.current（@MainActor, 跨 actor 必 await）。
    /// `store` seam: nil = 走 PlanTaskStore.shared(生产);非 nil = 读注入快照(handler 真跑)。
    static func runForTool(store: PlanTaskStore?) async -> String {
        let snapshot: PlanSnapshot?
        if let store {
            snapshot = await store.current
        } else {
            snapshot = await PlanTaskStore.shared.current
        }
        return PlanRead.render(snapshot)
    }
}
