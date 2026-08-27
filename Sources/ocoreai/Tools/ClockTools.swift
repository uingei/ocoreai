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
/// 本切片 = 纯时长 sleep(离线可测, 无 OS 门、无并发面)。codex 的「新输入提前唤醒」
/// 依赖 per-turn activity 订阅(`input_queue.subscribe_activity`), ocoreai ChatHandler
/// 无同形状信号 → 记为后续批次, 本工具诚实报告 `Sleep completed.`(未中断),
/// 不宣称提前中断能力。
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
protocol SleepBackend: Sendable {
    nonisolated func sleep(milliseconds: Int) async
}

struct SystemSleepBackend: SleepBackend, @unchecked Sendable {
    // 无共享可变状态(每次 sleep 独立 Task), 故 @unchecked Sendable 安全。
    nonisolated func sleep(milliseconds: Int) async {
        _ = try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)  // CancellationError 吞掉 = 提前终止(codex sleep 语义)
    }
}

/// `curr_time` 纯核对: UTC 固定格式, 无参。格式基准 = codex
/// `current_time.rs` output schema 描述 `"Current UTC time formatted as YYYY-MM-DD HH:MM:SS UTC."`。
enum ClockCurrentTime {
    /// 固定 UTC formatter(process 级唯一, 不 per-call alloc; 10 位秒精确值锚点
    /// `2026-08-27 12:34:56 UTC` 可离线断言)。
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

    /// 报告(codex 原形): `Wall time: {elapsed:.4f} seconds\nSleep completed.`。
    /// 本切片无中断信号 → 恒为 `Sleep completed.`(后续批次接 activity 订阅后
    /// 才有 `Sleep interrupted by new input.` 分支)。
    static func report(elapsedSeconds: Double) -> String {
        "Wall time: \(String(format: "%.4f", elapsedSeconds)) seconds\nSleep completed."
    }

    /// 越界拒绝报告(codex `RespondToModel("duration_ms must be between 1 and 43200000")`)。
    static func outOfRange(raw: Int?) -> String {
        let got = raw.map(String.init) ?? "nil"
        return
            "sleep: error: duration_ms must be between \(minDurationMs) and \(maxDurationMs) (got \(got))"
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
                + "Returns the elapsed wall-clock time. Use to pace retries or wait for an "
                + "external condition whose readiness you can re-check after the pause.",
            schema: ToolSchema(parameters: [
                "duration_ms": ToolParameter(
                    type: .integer,
                    description:
                        "How long to sleep in milliseconds. Must be between 1 and 43200000."
                )
            ])
        ) { args in
            await runForTool(durationMs: args.duration_ms, backend: backend)
        }
    }

    struct Args: Codable, Sendable {
        let duration_ms: Int?
    }

    static func runForTool(
        durationMs: Int?,
        backend: SleepBackend = SystemSleepBackend()
    ) async -> String {
        let built = ClockSleep.build(durationMs)
        guard built.ok else { return ClockSleep.outOfRange(raw: durationMs) }
        let start = DispatchTime.now()
        await backend.sleep(milliseconds: built.durationMs)
        let elapsed =
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        return ClockSleep.report(elapsedSeconds: elapsed)
    }
}
