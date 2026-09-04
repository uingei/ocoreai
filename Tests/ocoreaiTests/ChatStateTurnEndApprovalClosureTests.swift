// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatStateTurnEndApprovalClosureTests.swift — turn 终结 ⇒ 审批回路闭合。
///
/// 上游对齐 codex `ReviewDecision::Abort → Err(ToolError::Codex(CodexErr::TurnAborted))`
/// （`codex-rs/core/src/tools/approvals.rs:488`）:停止 = turn 终结 ⇒ 挂起审批一律清场。
///
/// ocoreai 此前 cancelInference() 只 cancel 推理流 + 停 TTS,审批回路（broker）
/// 不在停止路径上 → 审批等待时按 Stop 无法解除挂起,用户只能手动 Deny。
/// 本 patch 在 cancelInference() funnel 内接 `clearApprovalSession()`（每行
/// `.denied("session-ended")`）+ 可注入 seam `turnEndApprovalClosureHook`。
///
/// 策略:与 ChatStateTurnEndTTSStopTests 同形 —— @testable + ChatState.shared 真对象,
/// 注入 spy 闭包断言副作用发生,零 broker / avfoundation 依赖,精确值断言。
import Foundation
import Testing

@testable import ocoreai

@Suite("ChatState: turn-end closes the approval circuit")
struct ChatStateTurnEndApprovalClosureTests {

    @MainActor
    @Test("cancelInference fires the approval-closure seam exactly once; second call idempotent")
    func cancelInferenceFiresApprovalClosureOnce() {
        let state = ChatState.shared
        let original = state.turnEndApprovalClosureHook
        var fired = 0
        state.turnEndApprovalClosureHook = { fired += 1 }
        state._cancelledByUI = false
        state.responseText = ""

        state.cancelInference()
        #expect(fired == 1)

        // _cancelledByUI barrier: second call must not re-fire.
        state.cancelInference()
        #expect(fired == 1)

        state.turnEndApprovalClosureHook = original
        state._cancelledByUI = false
    }

    @MainActor @Test("stop() delegates to cancelInference and fires the approval-closure seam")
    func stopFiresApprovalClosure() {
        let state = ChatState.shared
        let original = state.turnEndApprovalClosureHook
        var fired = 0
        state.turnEndApprovalClosureHook = { fired += 1 }
        state._cancelledByUI = false
        state.responseText = ""

        state.stop()
        #expect(fired == 1)

        state.turnEndApprovalClosureHook = original
        state._cancelledByUI = false
    }

    @MainActor @Test("resend path (cancelInference) also closes the approval circuit")
    func resendPathClosesApprovalCircuit() {
        let state = ChatState.shared
        let original = state.turnEndApprovalClosureHook
        var fired = 0
        state.turnEndApprovalClosureHook = { fired += 1 }
        state._cancelledByUI = false
        state.responseText = ""

        // resendFromMessage 首行即 cancelInference()（ChatViewModel:374）——
        // 走同一 funnel,断言 seam 触发一次。
        state.cancelInference()
        #expect(fired == 1)

        state.turnEndApprovalClosureHook = original
        state._cancelledByUI = false
    }
}
