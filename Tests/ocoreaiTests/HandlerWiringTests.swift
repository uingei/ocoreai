// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// 通电测试 — 真跑 handler 闭包(entry(store:injected).handler，非纯函数)。
///
/// 此前 CheckTools/GetPlan 的全部单测都在测**纯函数**(render/filterAndSort/
/// reduce)。handler 闭包那条 handler→真值源的接缝——JSON→Args 解码 + 读
/// `PlanTaskStore.current` / `AuditTrail` + 跨 actor await —— **从没被真跑过**：
/// 纯函数全绿也测不到"解码失败/读错源/await 丢值"。本文件把两个 client 的
/// `entry(store:injected)` 真 handler round-trip，断言 seam→源→render 通路端到端正确。
import Foundation
import Testing

@testable import ocoreai

@Suite("Handler wiring — 真跑 handler 闭包(seam 注入 → handler 解码/读源 → render)")
struct HandlerWiringTests {

    // MARK: - get_plan handler 闭包通电(seam → PlanTaskStore.current → PlanRead.render)

    /// 注入快照 store → handler 输出 == 精确渲染串(证明 seam 正确传递到 current → render)。
    @Test("get_plan: injected snapshot → handler renders exact text")
    func getPlanHandlerInjected() async throws {
        let store = PlanTaskStore()
        await MainActor.run {
            store.current = PlanSnapshot(
                items: [
                    .init(step: "init repo", status: "completed"),
                    .init(step: "fix channel gating", status: "in_progress"),
                    .init(step: "add tests", status: "pending"),
                ],
                explanation: "fix the perception axis",
                updatedAt: 1_788_415_211
            )
        }
        let out = try await GetPlanClient.entry(store: store).handler("{}")
        #expect(
            out == """
                plan — 3 steps: 1 completed, 1 in_progress, 1 pending
                note: fix the perception axis
                1. [x] init repo (completed)
                2. [>] fix channel gating (in_progress)
                3. [ ] add tests (pending)
                updated: 2026-09-03 06:00:11 UTC
                """)
    }

    /// 注入空 store (current = nil) → handler 走缺席通路(报告"未记录 plan"，不静默丢)。
    @Test("get_plan: empty store (nil current) → honest absence text")
    func getPlanHandlerAbsent() async throws {
        let store = PlanTaskStore()  // current = nil 默认
        let out = try await GetPlanClient.entry(store: store).handler("{}")
        #expect(out == "no plan recorded in this session — call update_plan to create one")
    }

    // MARK: - check_tools handler 闭包通电(seam → AuditTrail → render)

    /// seed 1 success + 1 error → handler 报精确四态计数 + 明细(经 AuditTrail 真 actor)。
    @Test("check_tools: seeded trail → handler reports exact counts + detail lines")
    func checkToolsHandlerSeeded() async throws {
        let trail = AuditTrail()
        let okTok = await trail.beginCall(
            caller: "test", toolName: "exec", toolset: "shell",
            arguments: ["cmd": "ls"])
        await trail.completeToken(okTok, status: .success, result: "ok output")
        let badTok = await trail.beginCall(
            caller: "test", toolName: "web_fetch", toolset: "web",
            arguments: ["url": "x"])
        await trail.completeToken(badTok, status: .error, result: "fetch failed")

        let out = try await CheckToolsClient.entry(store: trail).handler("{}")
        #expect(out.contains("execution(s)"))
        #expect(out.contains("success 1, error 1, cancelled 0, timeout 0"))
        #expect(out.contains("exec: success"))
        #expect(out.contains("web_fetch: error"))
        #expect(out.contains("age "))
    }

    /// filter 通路通电: status=error 只报 error 条目(经 handler 闭包的真 JSON 解码 + 过滤路径)。
    @Test("check_tools: status=error filter → only error entry, success excluded")
    func checkToolsHandlerFilter() async throws {
        let trail = AuditTrail()
        let okTok = await trail.beginCall(
            caller: "t", toolName: "exec", toolset: "shell", arguments: [:])
        await trail.completeToken(okTok, status: .success, result: "ok")
        let badTok = await trail.beginCall(
            caller: "t", toolName: "web_fetch", toolset: "web", arguments: [:])
        await trail.completeToken(badTok, status: .error, result: "boom")

        let out = try await CheckToolsClient.entry(store: trail).handler(#"{"status":"error"}"#)
        #expect(out.contains("success 0, error 1"))
        #expect(out.contains("web_fetch: error"))
        #expect(!out.contains("exec: success"))
    }

    /// 空 trail(0 条目) → handler 走缺席通路(诚实报"无执行记录")。
    @Test("check_tools: empty trail → honest absence")
    func checkToolsHandlerAbsent() async throws {
        let trail = AuditTrail()  // 0 entries; backing nil → recentPersisted=[]
        let out = try await CheckToolsClient.entry(store: trail).handler("{}")
        #expect(out.contains("no tool executions in the last"))
        #expect(out.contains("nothing to verify yet"))
    }
}
