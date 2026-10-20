// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Clock namespace — codex `clock` namespace 两个原语(0.150.1 HEAD, 逐行对齐):
///
///   curr_time  无参, 返回当前 UTC 时间 `YYYY-MM-DD HH:MM:SS UTC`
///   sleep      `duration_ms` 1..43,200,000(12h) 暂停 agent 循环, 报实际经过秒
///
/// 基准: codex `core/src/tools/handlers/current_time.rs`(NAMESPACE=`"clock"`,
/// TOOL_NAME=`"curr_time"`, output `current_time: "YYYY-MM-DD HH:MM:SS UTC"`)
/// + `core/src/tools/handlers/sleep.rs`(MAX_SLEEP_DURATION_MS=`12*60*60*1000`=43,200,000;
/// report=`Wall time: {wall_time_seconds:.4} seconds\n{Sleep completed.|Sleep interrupted by new input.`)。
///
/// 定位: codex-baseline 通用 agent-loop 原语(时间读取/受控等待), ocoreai 此前 0 注册
/// (info 工具只有 status/version/uptime; ExecSessions 的 `Thread.sleep` 是内部 poll pacing,
/// 非工具面)。ocoreai 工具名 = codex `TOOL_NAME` 原值(`curr_time` / `sleep`), 保持
/// 工具集语义面对齐上游基准(同 `unified_exec` 三工具名、`view_image` 同形对齐先例)。
///
/// 「新输入提前唤醒」已接(10-21, 借自 codex #55644 `305db3808c`): codex 那条修的是
/// 「注入发生在 wait/sleep **开始之前**」——它此前只在 activity 订阅上等**变化**才唤醒,
/// 已经排在 turn_state 里的 injection 反而打不断自己招来的等待。
///
/// ocoreai 形状不同, 且更简单: `SteerQueue.pendingCount(sessionKey:)` 读的是**当前深度**
/// 而非变更通知, 所以「等待开始前就已注入」天然覆盖; 代价是按节拍轮询(见
/// `SystemSleepBackend` —— 每轮只睡一个轮询间隔, 绝不睡到 deadline, AGENTS.md 并发条)。
/// 会话键唯一设值点 = `ToolRegistry.call`(经 `ToolInvocationContext.conversationKey` 传播)。
///
/// 两个方向都由 `SleepSteerWakeTests` 钉住: 排在前面的转向必须打断(正向 = codex 修的那格);
/// 已被 drain 走的转向不得再叫醒任何人(反向 = codex 把 `has_pending_injection` 连 items
/// 一起 `take` 清零)。没有会话键(MCP 入口 / GUI 主动读盘 / 单测)⇒ 睡满全程并报
/// `Sleep completed.`, 不宣称能打断路人会话的转向。
import Foundation

// MARK: - curr_time

/// 时间提供 seam — 唯一的「真实时钟」边界。生产实现读 `Date()`;测试注入固定时间戳,
/// 报告可离线断言(不 touch wall clock)。
protocol ClockTimeProvider: Sendable {
    func now() -> Date
}

struct SystemClockTimeProvider: ClockTimeProvider, @unchecked Sendable {
    // 无共享可变状态(每次 now() 独立读 Date()), 故 @unchecked Sendable 安全。
    nonisolated func now() -> Date { Date() }
}

/// 真实延迟 seam — 唯一的「真等」边界。生产走 `Task.sleep`(不阻塞 actor executor,
/// 对齐 ExecSessions 的 `Thread.sleep` 纪律);测试注入 fake 不真等 —— 12h 上限可安全
/// 触发, 离线断言 duration/报告形态, 不拖慢 CI。
/// 一次有界等待的终局: 睡满了, 还是被本会话的输入提前叫走。
enum SleepOutcome: Equatable, Sendable {
    case completed
    case interrupted
}

protocol SleepBackend: Sendable {
    /// 最多等 `milliseconds`; `wakeCheck` 说本会话有输入在等, 立刻返回 `.interrupted`。
    ///
    /// 第一刀之前先查一次 —— 这正是 codex #55644 修的那一格: 等待开始**之前**排进来的
    /// 输入也必须结束这次等待。
    nonisolated func sleep(
        milliseconds: Int, wakeCheck: @escaping @Sendable () -> Bool
    ) async -> SleepOutcome
}

struct SystemSleepBackend: SleepBackend, @unchecked Sendable {
    // 无共享可变状态(每次 sleep 独立 Task), 故 @unchecked Sendable 安全。
    /// 轮询节拍: 每轮只睡一个间隔, 绝不睡到 deadline(AGENTS.md 并发条 —— 睡到 deadline 的
    /// 轮询循环不管条件何时清掉, 都把等待者按满整个窗口)。100 ms 让转向唤醒人手无感,
    /// 又不至于空转。
    static let pollIntervalMs = 100

    nonisolated func sleep(
        milliseconds: Int, wakeCheck: @escaping @Sendable () -> Bool
    ) async -> SleepOutcome {
        var remaining = milliseconds
        while remaining > 0 {
            if wakeCheck() { return .interrupted }
            let slice = min(remaining, Self.pollIntervalMs)
            _ = try? await Task.sleep(nanoseconds: UInt64(slice) * 1_000_000)
            remaining -= slice
        }
        // 全程已睡满, 此刻再报 interrupted = 宣称一个比实际更短的等待。
        // 最后一刀里才到达的转向照旧经正常 steer 缝进下一轮。
        return .completed
    }
}

/// `curr_time` 纯核对: UTC 固定格式, 无参。格式基准 = codex
/// `current_time.rs` output schema 描述 `"Current UTC time formatted as YYYY-MM-DD HH:MM:SS UTC."`。
enum ClockCurrentTime {
    /// 固定 UTC formatter(process 级唯一, 不 per-call alloc; 10 位秒精确值锚点
    /// `2026-08-27 12:34:56 UTC` 可离线断言).
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 报告形态: `<YYYY-MM-DD HH:MM:SS> UTC`(精确, 离线可断言)。
    static func report(date: Date) -> String { formatter.string(from: date) + " UTC" }
}

// MARK: - sleep

/// `sleep` 纯核对: codex `sleep.rs` `MAX_SLEEP_DURATION_MS` = `12*60*60*1000`。
enum ClockSleep {
    /// 单次最长暂停 = 12h(codex 原值)。
    static let maxDurationMs = 43_200_000
    /// 最短有效值 = 1ms(codex `if !(1..=MAX_SLEEP_DURATION_MS)` 下界)。
    static let minDurationMs = 1

    struct Built: Equatable {
        let durationMs: Int
        let ok: Bool
    }

    /// `nil`(模型没传) → 拒绝(codex `required: vec!["duration_ms"]`, 不可缺);
    /// `0`/负 → 拒绝(codex `!(1..=MAX)` 下界);超 `maxDurationMs` → 拒绝(不静默 clamp,
    /// 诚实报越界, 让模型自决缩短)。
    static func build(_ raw: Int?) -> Built {
        guard let v = raw else { return Built(durationMs: 0, ok: false) }
        guard v >= minDurationMs, v <= maxDurationMs else { return Built(durationMs: v, ok: false) }
        return Built(durationMs: v, ok: true)
    }

    /// 报告(codex `sleep.rs` 原形): `Wall time: {elapsed:.4f} seconds\n{message}`,
    /// message ∈ {`Sleep completed.`, `Sleep interrupted by new input.`}。
    ///
    /// `outcome` 无默认值 —— 这个词必须由 backend 实测出的终局提供。给一个 `.completed`
    /// 默认值 = 让任何忘记传终局的调用方默认宣称「睡满了」, 那是比实际更短的等待(不变量 2)。
    static func report(elapsedSeconds: Double, outcome: SleepOutcome) -> String {
        let message =
            outcome == .interrupted ? "Sleep interrupted by new input." : "Sleep completed."
        return "Wall time: \(String(format: "%.4f", elapsedSeconds)) seconds\n\(message)"
    }

    /// 越界拒绝报告(codex `RespondToModel("duration_ms must be between 1 and 43200000")`)。
    static func outOfRange(raw: Int?) -> String {
        let got = raw.map(String.init) ?? "nil"
        return
            "sleep: error: duration_ms must be between \(minDurationMs) and \(maxDurationMs) (got \(got))"
    }
}

// MARK: - Wake seam(谁能结束这场等待)

/// 「本会话是否已有输入在等」的唯一判断点。
///
/// 只看 `SteerQueue.pendingCount(sessionKey:)` —— 引擎 steer 用的同一个键、同一个字典,
/// 不另立第二套身份(env var / model id / 进程级标志)。被 drain 走的那条 steer 计数即归零,
/// 所以「已经投递给模型的转向」天然不会再叫醒下一场等待(codex #55644 把
/// `has_pending_injection` 连 items 一起 `std::mem::take` 清零, 同一个方向)。
enum SleepWake {

    /// 无会话在场(MCP `tools/call`、GUI 主动读盘、FoundationModels 路、单测)⇒ 没有任何
    /// 输入能结束这场等待: 睡满全程并报 `Sleep completed.`。
    static let never: @Sendable () -> Bool = { false }

    /// 有会话在场: 每轮轮询读**当前深度**。读深度而非订阅变更, 所以 codex #55644 那一格
    /// (输入在等待**开始之前**就排进来)天然覆盖, 不需要额外的 pending 标志。
    static func session(_ sessionKey: String) -> @Sendable () -> Bool {
        return { SteerQueue.shared.pendingCount(sessionKey: sessionKey) > 0 }
    }

    /// 这次调用用哪一种, 只由唯一的会话键来源决定(`ToolInvocationContext.conversationKey`,
    /// 唯一设值点 = `ToolRegistry.call`)。
    static func forCurrentInvocation() -> @Sendable () -> Bool {
        guard let sessionKey = ToolInvocationContext.conversationKey else { return never }
        return session(sessionKey)
    }
}

// MARK: - Clients(seam + args 绑定)

enum CurrTimeClient {

    static let toolName = "curr_time"

    static func toolEntry(provider: ClockTimeProvider = SystemClockTimeProvider()) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "clock",
            argsType: Args.self,
            description:
                "Return the current time in UTC, formatted as `YYYY-MM-DD HH:MM:SS UTC`. "
                + "Use to check the wall clock before scheduling, comparing timestamps, "
                + "or deciding to wait; pairs with `sleep` to pace a turn.",
            schema: ToolSchema(parameters: [:])
        ) { _ in
            ClockCurrentTime.report(date: provider.now())
        }
    }

    struct Args: Codable, Sendable {}

    static func runForTool(provider: ClockTimeProvider = SystemClockTimeProvider()) -> String {
        ClockCurrentTime.report(date: provider.now())
    }
}

enum SleepClient {

    static let toolName = "sleep"

    static func toolEntry(backend: SleepBackend = SystemSleepBackend()) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "clock",
            argsType: Args.self,
            description:
                "Pause execution for `duration_ms` milliseconds (1...43200000, i.e. up to 12 h). "
                + "The wait ends early when new input arrives for this conversation (reported as "
                + "`Sleep interrupted by new input.`); otherwise it sleeps the full duration and "
                + "reports `Sleep completed.`. Both forms give the elapsed wall-clock time. Use "
                + "to pace retries or wait for an external condition whose readiness you can "
                + "re-check after the pause.",
            schema: ToolSchema(parameters: [
                "duration_ms": ToolParameter(
                    type: .integer,
                    description:
                        "How long to sleep in milliseconds. Must be between 1 and 43200000."
                )
            ])
        ) { args in
            await runForTool(
                durationMs: args.duration_ms,
                wakeCheck: SleepWake.forCurrentInvocation(),
                backend: backend
            )
        }
    }

    struct Args: Codable, Sendable {
        let duration_ms: Int?
    }

    static func runForTool(
        durationMs: Int?,
        wakeCheck: @escaping @Sendable () -> Bool,
        backend: SleepBackend = SystemSleepBackend()
    ) async -> String {
        let built = ClockSleep.build(durationMs)
        guard built.ok else { return ClockSleep.outOfRange(raw: durationMs) }
        let start = DispatchTime.now()
        let outcome = await backend.sleep(milliseconds: built.durationMs, wakeCheck: wakeCheck)
        let elapsed =
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        return ClockSleep.report(elapsedSeconds: elapsed, outcome: outcome)
    }
}
