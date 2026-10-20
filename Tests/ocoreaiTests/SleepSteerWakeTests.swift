// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `sleep` 的唤醒契约 — 谁能结束这场等待、会话键走哪条路、真时钟下的节拍是多少。
///
/// 上游参照: codex #55644(`305db3808c`, `sleep.rs` + turn-state injection)。它修的是
/// 「注入排在 wait **开始之前**」那一格 —— 此前只等 activity 订阅上的**变化**, 于是
/// 已经排进 turn_state 的注入打不断自己招来的等待。ocoreai 形状更简单:
/// `SteerQueue.pendingCount(sessionKey:)` 读的是**当前深度**而非变更通知, 所以那一格
/// 天然覆盖; 代价是按节拍轮询(AGENTS.md 并发条: 轮询循环只睡一个间隔, 绝不睡到 deadline)。
///
/// 四个方向各有钉, 缺一个就是半条契约:
///   正向  排在前面的转向必须打断等待(含 codex 那一格: 入队发生在等待开始之前)。
///   反向  已被 drain 走的转向不得再叫醒任何人(codex 把 items 连标志一起清零)。
///   隔离  别的会话的转向不得叫醒本会话的等待(同 `SessionIsolationTests` 那类泄漏)。
///   缺席  没有会话键(MCP `tools/call` / GUI 主动读盘 / 单测)⇒ 睡满全程并报
///          `Sleep completed.`, 不宣称打断(不变量 2: 表面不超出引擎交付)。
///
/// 外加一条静态门(`EngineToolLanesCarryConversationKey`): 引擎两条投喂路必须把会话键交给
/// `ToolRegistry.call`。键一断, 工具描述里那句「ends early when new input arrives」当场
/// 变成空头承诺, 而运行时没有任何东西会变红 —— 那正是这类接线唯一不自证的点。
///
/// 时钟纪律: 只有 `SystemSleepBackend` 那几条碰真时钟, 且上界宽松(秒级 vs 30 s 请求时长),
/// 所以 CI 快机上不慢、慢机上不误报; 时长与报告形态本身在 `ClockToolsTests`(全离线)。

import Foundation
import Testing

@testable import ocoreai

/// 每个用例自带唯一会话键 + `defer` 清理: `SleepWake.session` 读的是 `SteerQueue.shared`,
/// 而 Swift Testing 会用线程跑并行用例 —— 共享单例上残留的转向会让下一个用例读到脏深度。
private func isolatedKey(_ tag: String) -> String {
    let key = "sleep-steer-wake-tests/\(tag)"
    SteerQueue.shared.discard(sessionKey: key)
    return key
}

private func elapsedMs(_ start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
}

// MARK: - 谁能结束等待(键的可见性)

@Suite("SleepWake — whose input may end this wait")
struct SleepWakeScopingTests {

    @Test("正向: 入队先于等待 ⇒ 深度可读(codex #55644 那一格)")
    func steerQueuedBeforeWaitIsVisible() {
        let key = isolatedKey("queued-before")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        #expect(SteerQueue.shared.enqueue(sessionKey: key, text: "stop waiting") == true)
        #expect(SleepWake.session(key)() == true)
    }

    @Test("反向: 已 drain 走的转向不得再叫醒任何人")
    func drainedSteerCannotWake() {
        let key = isolatedKey("drained")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        SteerQueue.shared.enqueue(sessionKey: key, text: "already delivered")
        #expect(SleepWake.session(key)() == true)
        // 引擎的投喂点就是这个 drain —— 投完即归零, 下一场等待不该被同一条叫醒。
        #expect(SteerQueue.shared.drain(sessionKey: key).map(\.text) == ["already delivered"])
        #expect(SleepWake.session(key)() == false)
    }

    @Test("隔离: 别的会话的转向叫醒不了本会话的等待")
    func otherSessionSteerDoesNotWake() {
        let mine = isolatedKey("isolation-mine")
        let theirs = isolatedKey("isolation-theirs")
        defer {
            SteerQueue.shared.discard(sessionKey: mine)
            SteerQueue.shared.discard(sessionKey: theirs)
        }
        SteerQueue.shared.enqueue(sessionKey: theirs, text: "for another conversation")
        #expect(SleepWake.session(mine)() == false)
        #expect(SleepWake.session(theirs)() == true)
    }

    @Test("缺席: 无会话键 ⇒ never, 且队里有待投的转向也不算数")
    func absentConversationNeverWakes() {
        let stray = isolatedKey("stray")
        defer { SteerQueue.shared.discard(sessionKey: stray) }
        SteerQueue.shared.enqueue(sessionKey: stray, text: "belongs to someone else")
        // 没有键就没有「本会话的输入」这件事: 报打断 = 宣称一次实际没发生的中断。
        #expect(SleepWake.never() == false)
        #expect(ToolInvocationContext.conversationKey == nil)
        #expect(SleepWake.forCurrentInvocation()() == false)
    }

    @Test("键只由 ToolInvocationContext 决定: 有键即读该会话深度")
    func keySelectsWhichSessionIsWatched() {
        let key = isolatedKey("task-local-key")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        SteerQueue.shared.enqueue(sessionKey: key, text: "turn up")
        let woke = ToolInvocationContext.$conversationKey.withValue(key) {
            SleepWake.forCurrentInvocation()()
        }
        #expect(woke == true)
        // withValue 退出即复原: 泄漏一个键 = 之后所有等待都盯着别人的会话。
        #expect(ToolInvocationContext.conversationKey == nil)
    }
}

// MARK: - 会话键的唯一设值点(chokepoint)

@Suite("ToolInvocationContext — published at the one dispatch chokepoint")
struct ToolInvocationContextTests {

    /// 报出自己看到什么的探针工具(键 + 是否真的落在 handler 作用域内)。
    private static func probeEntry() -> ToolEntry {
        ToolEntry(
            name: "ctx_probe",
            toolset: "test",
            schema: ToolSchema(),
            handler: { _ in ToolInvocationContext.conversationKey ?? "<nil>" }
        )
    }

    @Test("call(conversationKey:) 在 handler 期间发布键, 返回即复原")
    func keyPublishedForHandlerDuration() async throws {
        let registry = ToolRegistry()
        try await registry.register(Self.probeEntry())
        let key = "ctx-probe-conversation"
        let seen = try await registry.call(
            "ctx_probe", arguments: "{}", conversationKey: key)
        #expect(seen == key)
        #expect(ToolInvocationContext.conversationKey == nil)
    }

    @Test("不带键的入口(MCP / GUI 主动读盘)看得见 nil, 不残留上一个会话的键")
    func keyAbsentStaysNil() async throws {
        let registry = ToolRegistry()
        try await registry.register(Self.probeEntry())
        #expect(try await registry.call("ctx_probe", arguments: "{}") == "<nil>")
        // 同一 registry 先带键再不带: 后一次必须看见缺席, 否则键会跨调用泄漏。
        _ = try await registry.call("ctx_probe", arguments: "{}", conversationKey: "earlier")
        #expect(try await registry.call("ctx_probe", arguments: "{}") == "<nil>")
    }

    @Test("键随子任务传播(handler 跳进 Task / actor 仍答得出同一会话)")
    func keyPropagatesIntoChildTask() async throws {
        let registry = ToolRegistry()
        try await registry.register(
            ToolEntry(
                name: "ctx_child_probe",
                toolset: "test",
                schema: ToolSchema(),
                handler: { _ in
                    await Task { ToolInvocationContext.conversationKey ?? "<nil>" }.value
                }
            ))
        let seen = try await registry.call(
            "ctx_child_probe", arguments: "{}", conversationKey: "parent-conversation")
        #expect(seen == "parent-conversation")
    }
}

// MARK: - 真时钟: 节拍与两向终局

@Suite("SystemSleepBackend — real-clock cadence")
struct SystemSleepBackendTests {

    /// 门自己声明前提: 后面几条「秒级即返回」的断言全靠节拍远小于它们的上界。
    @Test("轮询节拍远小于用例上界(否则下面的宽松界形同虚设)")
    func pollIntervalPremise() {
        #expect(SystemSleepBackend.pollIntervalMs > 0)
        #expect(SystemSleepBackend.pollIntervalMs <= 250)
    }

    @Test("正向: 等待开始前已入队 ⇒ 30 s 的请求几乎立刻结束")
    func steerQueuedBeforeWaitEndsItImmediately() async {
        let key = isolatedKey("real-pre-queued")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        SteerQueue.shared.enqueue(sessionKey: key, text: "already here when the wait began")
        let start = DispatchTime.now()
        let outcome = await SystemSleepBackend().sleep(
            milliseconds: 30_000, wakeCheck: SleepWake.session(key))
        let took = elapsedMs(start)
        #expect(outcome == .interrupted)
        // 睡到 deadline 的写法会在这里停满 30 s(codex #55644 同一形状的错误)。
        #expect(took < 2_000, "took \(took)ms — a pre-queued steer must end the wait at once")
    }

    @Test("正向: 等待途中到达的转向在一个节拍内结束等待")
    func steerArrivingMidWaitEndsItEarly() async {
        let key = isolatedKey("real-mid-arrival")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        let arrival = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            SteerQueue.shared.enqueue(sessionKey: key, text: "arrived mid-wait")
        }
        let start = DispatchTime.now()
        let outcome = await SystemSleepBackend().sleep(
            milliseconds: 30_000, wakeCheck: SleepWake.session(key))
        let took = elapsedMs(start)
        await arrival.value
        #expect(outcome == .interrupted)
        #expect(took < 2_500, "took \(took)ms — mid-wait input must wake the poll loop")
    }

    @Test("无人打断 ⇒ 真睡满全程并报 completed")
    func nothingArrivingSleepsFullDuration() async {
        let key = isolatedKey("real-quiet")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        let start = DispatchTime.now()
        let outcome = await SystemSleepBackend().sleep(
            milliseconds: 300, wakeCheck: SleepWake.session(key))
        let took = elapsedMs(start)
        #expect(outcome == .completed)
        // 允许一档调度余量, 但绝不许把 300 ms 睡成一次即时返回(那是谎报时长)。
        #expect(took >= 200, "took \(took)ms — reported a shorter wait than it spent")
    }

    @Test("先查后睡: 输入已在场时一个节拍都不花(检查挪到睡眠之后就会红)")
    func checkHappensBeforeAnySliceIsSpent() async {
        let key = isolatedKey("real-check-first")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        SteerQueue.shared.enqueue(sessionKey: key, text: "pending before the first slice")
        let start = DispatchTime.now()
        let outcome = await SystemSleepBackend().sleep(
            milliseconds: SystemSleepBackend.pollIntervalMs, wakeCheck: SleepWake.session(key))
        let took = elapsedMs(start)
        #expect(outcome == .interrupted)
        // 请求时长正好等于一个节拍: 先睡后查的写法必然花满 100 ms(上游修的那个形状),
        // 先查后睡则几乎不花时间。红样实测见 CHANGELOG 同日条目。
        #expect(
            took < SystemSleepBackend.pollIntervalMs / 2,
            "took \(took)ms — the wake check ran after a slice was already spent")
    }

    @Test("转向已被投喂 ⇒ 同一场等待睡满全程, 不被陈旧键叫醒")
    func drainedBeforeWaitSleepsFullDuration() async {
        let key = isolatedKey("real-drained-first")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        SteerQueue.shared.enqueue(sessionKey: key, text: "delivered before this wait")
        #expect(SteerQueue.shared.drain(sessionKey: key).count == 1)
        let start = DispatchTime.now()
        let outcome = await SystemSleepBackend().sleep(
            milliseconds: 300, wakeCheck: SleepWake.session(key))
        #expect(outcome == .completed)
        #expect(elapsedMs(start) >= 200)
    }
}

// MARK: - 线上看到的词(整条路: chokepoint → task local → backend → 报告)

@Suite("sleep tool result — honest outcome wording over the real backend")
struct SleepWireWordingTests {

    @Test("有会话且已注入 ⇒ 报 `Sleep interrupted by new input.` 而非谎称睡满")
    func interruptedWordingAcrossTheWholeSeam() async throws {
        let registry = ToolRegistry()
        try await registry.register(SleepClient.toolEntry())
        let key = isolatedKey("wording-interrupted")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        SteerQueue.shared.enqueue(sessionKey: key, text: "steer before the sleep")
        let start = DispatchTime.now()
        let out = try await registry.call(
            "sleep", arguments: #"{"duration_ms": 30000}"#, conversationKey: key)
        let took = elapsedMs(start)
        #expect(out.contains("Sleep interrupted by new input."), "tool result was: \(out)")
        #expect(!out.contains("Sleep completed."), "tool result was: \(out)")
        #expect(took < 2_000, "took \(took)ms — the promise in the tool description broke")
    }

    @Test("无会话键 ⇒ 同一工具睡满全程并报 `Sleep completed.`, 不臆造中断")
    func completedWordingWithoutConversation() async throws {
        let registry = ToolRegistry()
        try await registry.register(SleepClient.toolEntry())
        let key = isolatedKey("wording-no-key")
        defer { SteerQueue.shared.discard(sessionKey: key) }
        // 队里放着别的会话的转向: 无键的调用不该把它读成自己的中断。
        SteerQueue.shared.enqueue(sessionKey: key, text: "someone else's steer")
        let out = try await registry.call("sleep", arguments: #"{"duration_ms": 250}"#)
        #expect(out.contains("Sleep completed."), "tool result was: \(out)")
        #expect(!out.contains("interrupted"), "tool result was: \(out)")
    }
}

// MARK: - 静态门: 引擎投喂路必须交出会话键

/// 引擎的两条工具投喂路(标准 ChatSession 循环 / MTP 循环)是 `SteerQueue.drain` 的宿主,
/// 也是 sleep 唯一能被打断的地方。这两处一旦不传键, 描述里的唤醒能力当场失效而无人变红。
@Suite("Engine tool lanes hand the conversation key to the registry")
struct EngineToolLanesCarryConversationKey {

    /// 按 `Package.swift` 定位仓库根, 不做固定层数上溯 —— 固定跳数落到树外面,
    /// ENOENT 会被读成通过。
    private func sourcesFile(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 8 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    @Test("两处 registry.call 投喂点都必须带 conversationKey: 参数")
    func engineLanesPassConversationKey() throws {
        let lines = try sourcesFile("Sources/ocoreai/Engine/EngineInference.swift")
            .components(separatedBy: "\n")
        var lanes: [(line: Int, text: String)] = []
        // 两条投喂点写法不同: 标准路是 `registry.call(`, MTP 路是 `toolRegistry?.call(`。
        // 那个 `?` 让「registry.call(」这个子串漏掉后者 —— 一条只数到 1 的扫描会把
        // 「投喂点少了一条」读成「一切正常」, 所以按正则匹配, 并让下面的 count 断言说话。
        let lanePattern = #/[A-Za-z]*[Rr]egistry\??\.call\(/#
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 只数真代码: 注释里那句 "→ registry.call()" 是叙述, 不是投喂点。
            guard !trimmed.hasPrefix("//"), trimmed.firstMatch(of: lanePattern) != nil else {
                continue
            }
            lanes.append((index + 1, trimmed))
        }
        // 扫到自己数命中数: 正则一失配, 0 命中会伪装成「一切正常」。
        #expect(lanes.count == 2, "expected the MLX + MTP lanes, found \(lanes.map(\.line))")
        for lane in lanes {
            let window = lines[lane.line ... min(lane.line + 8, lines.count - 1)].joined()
            #expect(
                window.contains("conversationKey:"),
                "EngineInference.swift:\(lane.line) drops the conversation key")
        }
    }
}
