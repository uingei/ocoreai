// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// update_plan opt-in 注册门精确值测试 — 对齐 codex `#41744`（默认 false）。
///
/// 两条镜像：不传 / 显式 false → 未注册；显式 true → 注册。
import Testing

@testable import ocoreai

@Suite("update_plan opt-in — 注册门（codex #41744 基线对齐）")
final class UpdatePlanOptInTests {
    @Test("默认（不传参）→ update_plan 未注册，其它内置工具不受影响")
    func defaultPath() async {
        let registry = ToolRegistry()
        await bootstrapBuiltInTools(registry: registry, skillRegistry: nil)
        let names = await registry.listTools()
        #expect(names.contains("echo"), "echo 应注册（回归面）")
        #expect(names.contains("info"), "info 应注册（回归面）")
        #expect(!names.contains("update_plan"), "update_plan 默认不得注册")
    }

    @Test("显式 false → update_plan 未注册")
    func explicitOff() async {
        let registry = ToolRegistry()
        await bootstrapBuiltInTools(
            registry: registry, skillRegistry: nil, updatePlanEnabled: false)
        #expect(!(await registry.listTools()).contains("update_plan"))
    }

    @Test("显式 true → update_plan 注册")
    func explicitOn() async {
        let registry = ToolRegistry()
        await bootstrapBuiltInTools(
            registry: registry, skillRegistry: nil, updatePlanEnabled: true)
        #expect((await registry.listTools()).contains("update_plan"))
    }
}
