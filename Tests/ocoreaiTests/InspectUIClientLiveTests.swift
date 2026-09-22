// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// inspect_ui live AX — end-to-end proof that UIInspectDriver.readTree runs
// against a real macOS accessibility tree and annotates elements with
// ` at:(x,y)` frame coordinates (the "看到按钮 → 点中按钮" closed loop).
//
// Skipped cleanly when Accessibility trust is unavailable (headless / CI),
// same idiom as RepetitionPenaltyGPUStateTests (`.enabled(if: ...)` guard).
//
// Complements InspectUIClientPureTests.swift (Pure logic only, no AX).
import AppKit
import Testing

#if os(macOS)
@testable import ocoreai

struct InspectUIClientLiveTests {
    /// 真实 AX 树端到端: 读前台 app 的树, 至少一个元素带帧坐标。
    @Test("readTree: 真实 AX 树元素带 at:(x,y) 帧坐标", .enabled(if: AXIsProcessTrusted()))
    func liveTreeHasFrameCoordinates() async {
        let out = await UIInspectDriver.readTreeAsync(app: nil, depth: 6, nodes: 400, role: nil)
        // 头行必在(权限与目标都 OK 时)
        #expect(out.hasPrefix("# ui-tree pid="))
        // 至少一行带坐标 —— 整条回路(AXValue → 解包 → 中心点)的运行时证明
        #expect(
            out.split(separator: "\n").contains(where: { $0.contains(" at:(") }))
    }

    /// 权限语义: 无信任时诚实 ui_untrusted 前缀(不假装读到)。
    /// 已信任时 → 头行在。两态都不该出现"假的树"。
    @Test("readTree: 信任态二分 — 要么树头, 要么诚实 ui_untrusted")
    func honestTrustDichotomy() async {
        let out = await UIInspectDriver.readTreeAsync(app: nil, depth: 2, nodes: 20, role: nil)
        #expect(out.hasPrefix("# ui-tree pid=") || out.hasPrefix("ui_untrusted"))
    }

    /// 目标解析: 不存在的 bundle id → 诚实 ui_no_app(不误报成树)。
    @Test("readTree: 未知 app 目标 → 诚实 ui_no_app")
    func unknownAppHonest() async {
        let out = await UIInspectDriver.readTreeAsync(
            app: "com.ocoreai.definitely.not.registered.app.9999",
            depth: 2, nodes: 10, role: nil)
        #expect(out.hasPrefix("ui_no_app") || out.hasPrefix("ui_untrusted"))
    }
}
#endif
