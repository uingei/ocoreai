// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// App lifecycle live — 真实 NSWorkspace 面上三工具的端到端语义验证:
//   1. list_apps 真值: 头行 # apps + 至少一行 active(Finder 恒在 → 名单非空的可靠锚)
//   2. activate_app(Finder): 恒在的 running app, 幂等激活, 必得到 frontmost 确认
//   3. open_app(Finder): 已运行分支 → 「already running … activated」(不重复拉起)
//   4. 诚实失败: 不存在的 bundle id → app_open_failed(不假装成功)
//
// 与 InspectUIClientLiveTests 同范式: struct 裸名 + @Test 方法, 不启动新 app
// (全部走「已运行」分支 = 零新增进程)。
import AppKit
import Testing

#if os(macOS)
@testable import ocoreai

struct AppLifecycleLiveTests {
    private static let finderBundle = "com.apple.finder"

    @Test("list_apps: 真实运行面 — 头行 + active 标记 + filter 语义")
    func liveListApps() async {
        let all = await AppLifecycleDriver.listApps(limit: 50, filter: nil)
        #expect(all.hasPrefix("# apps"))
        #expect(all.contains("active"), "至少一行 app 在前台(active 标记)")

        // filter: TextEdit 的 id/名都含 "edit" → 必然命中 Finder? 不, 用恒在的 Finder
        let finder = await AppLifecycleDriver.listApps(limit: 50, filter: "Finder")
        #expect(finder.contains("com.apple.finder"), "Finder 恒运行, 名单必含其 bundle id")

        // 不存在的过滤词 → 空表(只有头行)
        let none = await AppLifecycleDriver.listApps(limit: 50, filter: "zz_not_a_real_app_zz")
        let rows = none.split(separator: "\n").dropFirst().count
        #expect(rows == 0, "无命中过滤 → 0 数据行: \(none)")
    }

    @Test("activate_app(Finder): 已运行 → 接受 + 前台状态在收敛窗口内落地")
    func liveActivateRunning() async {
        let id = AppLifecycleLiveTests.finderBundle
        let out = await AppLifecycleDriver.activateApp(id)
        #expect(out.contains("→ frontmost"), "got: \(out)")
        // 真实语义: activate 被接受后, 前台状态收敛(实测 ~28ms); 给 2s 收敛窗口轮询,
        // 不裸查瞬间(那是 OS 状态机竞态, 不是工具语义)。
        var settled = false
        for _ in 0 ..< 40 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id {
                settled = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            settled,
            "frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
    }

    @Test("open_app(Finder): 已运行分支幂等 — 不重复拉起, 报 already running")
    func liveOpenRunningIsIdempotent() async {
        let id = AppLifecycleLiveTests.finderBundle
        let countFinder = {
            NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }.count
        }
        let before = countFinder()
        let out = await AppLifecycleDriver.openApp(id)
        #expect(out.contains("already running"), "got: \(out)")
        // 幂等铁证: 前后进程数不变(不重复拉起)
        let after = countFinder()
        #expect(before == 1 && after == 1)
    }

    @Test("open_app(不存在): 诚实 app_open_failed, 不假装成功")
    func liveOpenUnknownHonest() async {
        let out = await AppLifecycleDriver.openApp("com.ocoreai.definitely.not.registered.app.9999")
        #expect(out.hasPrefix("app_open_failed"), "got: \(out)")
    }

    @Test("activate_app(未运行): 诚实报未运行, 不拉起")
    func liveActivateUnrunningHonest() async {
        let out = await AppLifecycleDriver.activateApp(
            "com.ocoreai.definitely.not.registered.app.9999")
        #expect(out.hasPrefix("app_activate_failed"), "got: \(out)")
        #expect(out.contains("Use open_app"), "未运行应指路 open_app: \(out)")
    }
}
#endif
