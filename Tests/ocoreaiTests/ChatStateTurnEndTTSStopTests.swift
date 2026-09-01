// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatStateTurnEndTTSStopTests.swift — turn 终结 ⇒ 停 TTS。
///
/// 上游对齐 openclaw d6afb1109a9 "cancel narration requests when their turn ends"。
/// ocoreai 此前 cancelInference() 只 cancel 推理流、从不 stopSpeak() →
/// 用户 stop / 切会话 / 切模型 / 重置 后,语音层把整段回复念完。
///
/// 策略:与 ChatViewModelBehavioralTests 同形 —— @testable + ChatState.shared 真对象,
/// 注入 spy 闭包断言副作用发生次数,零 AVFoundation 依赖,精确值断言(非 count>N)。
/// 生产默认 hook 绑 AudioIO.shared.stopSpeaking(幂等);测试只换 spy,不改生产路径。
import Foundation
import Testing

@testable import ocoreai

@Suite("ChatState: turn-end stops TTS — cancelInference fires the voice-stop hook")
struct ChatStateTurnEndTTSStopTests {

    @MainActor @Test("cancelInference fires the hook exactly once; second call is idempotent")
    func cancelInferenceFiresOnce() {
        let state = ChatState.shared
        let original = state.turnEndVoiceStopHook
        var fired = 0
        state.turnEndVoiceStopHook = { fired += 1 }
        state._cancelledByUI = false
        state.responseText = ""

        state.cancelInference()
        let afterFirst = fired
        #expect(afterFirst == 1)

        // Idempotent: the _cancelledByUI barrier must not re-fire the hook.
        state.cancelInference()
        #expect(fired == 1)

        state.turnEndVoiceStopHook = original
        state._cancelledByUI = false
    }

    @MainActor @Test("stop() delegates to cancelInference and fires the hook")
    func stopDelegatesToFiresHook() {
        let state = ChatState.shared
        let original = state.turnEndVoiceStopHook
        var fired = 0
        state.turnEndVoiceStopHook = { fired += 1 }
        state._cancelledByUI = false
        state.responseText = ""

        state.stop()
        #expect(fired == 1)

        state.turnEndVoiceStopHook = original
        state._cancelledByUI = false
    }

    @MainActor @Test("stop with a spy already firing from an earlier turn does not double-fire")
    func stopDoesNotDoubleFire() {
        let state = ChatState.shared
        let original = state.turnEndVoiceStopHook
        var fired = 0
        state.turnEndVoiceStopHook = { fired += 1 }
        state._cancelledByUI = false
        state.responseText = ""

        state.cancelInference()
        let afterFirst = fired
        state.stop()
        #expect(afterFirst == 1)
        #expect(fired == 1)

        state.turnEndVoiceStopHook = original
        state._cancelledByUI = false
    }
}
