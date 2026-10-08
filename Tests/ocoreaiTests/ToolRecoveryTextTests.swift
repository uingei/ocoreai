// ToolRecoveryTextTests.swift — denial honesty wire contract (MLX catch-site)
//
// 钉住 EnginePool.toolRecoveryText 的回灌文案(10-08 实锤:gemma-1.5B 在
// headless fail-closed 拒绝后对空目录谎称"已创建文件")。文案必须:
//   1) 保留 `[tool_error:` 前缀 — wire 契约(FMToolErrorRecoveryTests 钉死
//      FM 路径同型串;MLX 拒绝分支不得另造前缀)
//   2) 拒绝 → 显式否定完成;失败 → 显式"先验证再声称成功"
// reason 为 ToolError.errorDescription 原文(含 "Tool call denied by hook:"
// 等包装前缀,不剥壳 — 剥壳=平行契约)。
// 门控说明: 不能并进 FMToolErrorRecoveryTests — 那个文件整体被
// #if FoundationModelsIntegration 剔除(macOS<27 连符号都不存在)。

import Foundation
import Testing

@testable import ocoreai

@Suite("ToolRecoveryText honesty")
struct ToolRecoveryTextTests {

    @Test("headless denial → explicit NOT-executed wording, [tool_error: prefix")
    func denialWording() {
        let reason = "denied: interactive approval is not available on this (headless) channel"
        let t = EnginePool.toolRecoveryText(for: ToolError.denied(reason: reason))
        #expect(
            t.hasPrefix("[tool_error: Tool call denied by hook: \(reason)]"),
            "denial keeps wire prefix + ToolError's own description verbatim")
        #expect(t.contains("NOT executed"))
        #expect(t.contains("Do NOT claim"))
        #expect(t.contains("nothing exists"))
    }

    @Test("auto-denied policy denial also gets honesty wording")
    func autoDeniedWording() {
        let t = EnginePool.toolRecoveryText(for: ToolError.denied(reason: "auto-denied"))
        #expect(t.hasPrefix("[tool_error: Tool call denied by hook: auto-denied]"))
        #expect(t.contains("NOT executed"))
    }

    @Test("generic failure → FAILED wording with [tool_error: prefix")
    func failureWording() {
        struct E: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let t = EnginePool.toolRecoveryText(for: E())
        #expect(t.hasPrefix("[tool_error: boom]"))
        #expect(t.contains("FAILED"))
    }

    @Test("executionFailed keeps prefix + verify-before-claiming tail")
    func executionFailedWording() {
        struct E: Error, LocalizedError {
            var errorDescription: String? { "path escapes workspace" }
        }
        let t = EnginePool.toolRecoveryText(for: ToolError.executionFailed(E()))
        #expect(t.hasPrefix("[tool_error: Tool execution failed: path escapes workspace]"))
        #expect(t.contains("Verify before claiming success"))
    }

    @Test("denial and failure branches are distinguishable by wording")
    func branchesDistinct() {
        let d = EnginePool.toolRecoveryText(for: ToolError.denied(reason: "r"))
        let f = EnginePool.toolRecoveryText(for: ToolError.invalidParameter("r"))
        #expect(d != f)
        #expect(d.contains("denied") || d.contains("NOT executed"))
        #expect(f.contains("FAILED"))
    }
}
