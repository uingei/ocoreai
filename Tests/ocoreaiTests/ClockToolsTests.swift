// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `curr_time` + `sleep` 工具 — 精确值测试(全离线, fake clock/backend, 不触 wall clock).
///
/// 覆盖两个 seam:
///   curr_time: `ClockCurrentTime.report`(精确 UTC 格式锚点)
///              + `CurrTimeClient.runForTool` fake provider 注入固定时间戳。
///   sleep:     `ClockSleep.build`(1..43,200,000 边界, nil/0/负/越界拒绝)
///              + `ClockSleep.report`(codex 原形 `Wall time: %.4f seconds\nSleep completed.`)
///              + `ClockSleep.outOfRange`(拒绝报告精确形态)
///              + `SleepClient.runForTool` fake backend 不真等即返回(12h 上限也可触发)。
///
/// 基准: codex `core/src/tools/handlers/current_time.rs` + `sleep.rs`(0.150.1 HEAD 逐行对齐)。

import Foundation
import Testing

@testable import ocoreai

/// 文件级固定时钟 — 注入精确时间戳, report 可离线断言(不 touch wall clock)。
struct FixedClock: ClockTimeProvider {
    let stamp: Date
    nonisolated func now() -> Date { stamp }
}

/// 文件级假 sleep 后端 — 记录被请求的时长, 不真等(12h 上限可安全触发, 不拖慢 CI)。
struct FakeSleepBackend: SleepBackend {
    let requested: RefBox<[Int]>
    init(requested: RefBox<[Int]> = RefBox<[Int]>([])) {
        self.requested = requested
    }
    nonisolated func sleep(milliseconds: Int) async {
        requested.value.append(milliseconds)
    }
}

// MARK: - curr_time: 格式精确值

@Suite("curr_time report format")
struct CurrTimeFormatTests {

    @Test
    func exactUTCFormatAnchor() {
        // 2026-08-27 12:34:56 UTC(时间戳 1787834096, `date -u -j -f` 实证)。
        let stamp = Date(timeIntervalSince1970: 1_787_834_096)
        #expect(ClockCurrentTime.report(date: stamp) == "2026-08-27 12:34:56 UTC")
    }

    @Test
    func yearEndBoundary() {
        // 2026-12-31 23:59:59 UTC(时间戳 1798761599)。
        let stamp = Date(timeIntervalSince1970: 1_798_761_599)
        #expect(ClockCurrentTime.report(date: stamp) == "2026-12-31 23:59:59 UTC")
    }

    @Test
    func epochAnchor() {
        #expect(
            ClockCurrentTime.report(date: Date(timeIntervalSince1970: 0))
                == "1970-01-01 00:00:00 UTC")
    }
}

// MARK: - curr_time: client 面

@Suite("curr_time client")
struct CurrTimeClientTests {

    @Test
    func toolEntryIdentifiesClockNamespace() {
        let e = CurrTimeClient.toolEntry()
        #expect(e.name == "curr_time")
        #expect(e.toolset == "clock")
    }

    @Test
    func runForToolWithFixedProviderIsExact() {
        let out = CurrTimeClient.runForTool(
            provider: FixedClock(stamp: Date(timeIntervalSince1970: 1_787_834_096)))
        #expect(out == "2026-08-27 12:34:56 UTC")
    }
}

// MARK: - sleep: 边界构建(codex `!(1..=43_200_000)`)

@Suite("sleep bounds")
struct SleepBoundsTests {

    @Test
    func validRangeAccepted() {
        #expect(ClockSleep.build(1).ok)
        #expect(ClockSleep.build(1).durationMs == 1)
        #expect(ClockSleep.build(1_000).ok)
        #expect(ClockSleep.build(ClockSleep.maxDurationMs).ok)
        #expect(ClockSleep.build(43_200_000).durationMs == 43_200_000)
    }

    @Test
    func outOfRangeRejected() {
        #expect(!ClockSleep.build(0).ok)
        #expect(!ClockSleep.build(-1).ok)
        #expect(!ClockSleep.build(43_200_001).ok)
        // nil(模型没传)= 拒绝, 不发明默认值(codex required 参数语义)。
        #expect(!ClockSleep.build(nil).ok)
    }
}

// MARK: - sleep: 报告精确值(codex 原形)

@Suite("sleep report format")
struct SleepReportTests {

    @Test
    func exactReportShape() {
        #expect(
            ClockSleep.report(elapsedSeconds: 1.2345)
                == "Wall time: 1.2345 seconds\nSleep completed.")
    }

    @Test
    func zeroElapsed() {
        #expect(
            ClockSleep.report(elapsedSeconds: 0) == "Wall time: 0.0000 seconds\nSleep completed.")
    }

    @Test
    func outOfRangeMessageExact() {
        #expect(
            ClockSleep.outOfRange(raw: 0)
                == "sleep: error: duration_ms must be between 1 and 43200000 (got 0)")
        #expect(
            ClockSleep.outOfRange(raw: 43_200_001)
                == "sleep: error: duration_ms must be between 1 and 43200000 (got 43200001)")
        #expect(
            ClockSleep.outOfRange(raw: nil)
                == "sleep: error: duration_ms must be between 1 and 43200000 (got nil)")
    }
}

// MARK: - sleep: client 面(fake backend, 不真等)

@Suite("sleep client")
struct SleepClientTests {

    @Test
    func toolEntryIdentifiesClockNamespace() {
        let e = SleepClient.toolEntry()
        #expect(e.name == "sleep")
        #expect(e.toolset == "clock")
    }

    @Test
    func runForToolSleepsRequestedMsThenReports() async {
        let req = RefBox<[Int]>([])
        let out = await SleepClient.runForTool(
            durationMs: 120, backend: FakeSleepBackend(requested: req))
        #expect(req.value == [120])
        #expect(out.hasPrefix("Wall time: "))
        #expect(out.hasSuffix("seconds\nSleep completed."))
    }

    @Test
    func maxDurationTriggersFakeBackendWithoutRealWait() async {
        // 12h 上限经 fake backend 离线触发 — 不真等, 断言请求值精确。
        let req = RefBox<[Int]>([])
        let out = await SleepClient.runForTool(
            durationMs: 43_200_000, backend: FakeSleepBackend(requested: req))
        #expect(req.value == [43_200_000])
        #expect(out.contains("Sleep completed."))
    }

    @Test
    func outOfRangeReturnsErrorWithoutSleeping() async {
        let req = RefBox<[Int]>([])
        let backend = FakeSleepBackend(requested: req)
        let out = await SleepClient.runForTool(durationMs: 43_200_001, backend: backend)
        #expect(req.value.isEmpty)
        #expect(out == "sleep: error: duration_ms must be between 1 and 43200000 (got 43200001)")
    }
}
