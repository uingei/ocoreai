// FMSessionErrorSurfaceTests.swift — 09-17 catch-site 回归门
//
// 契约(FMToolBridge.swift FMErrorClassifier):
//   LanguageModelSession 抛错 → human/UI 面消息分类。
//   ① contextSizeExceeded 是唯一 bespoke 面 — 精确串, 携真实
//      tokenCount/contextSize, "start a fresh conversation" 导向(镜像
//      非 FM 路径 AppError.contextWindowExhausted)。
//   ② 其余一切 throw(rateLimited/refusal/timeout/unsupported*/非 FM 错)
//      = 原样 localizedDescription, 绝不拿到 bespoke "fresh conversation"。
//
// 缺陷类(被本门钉死): 任何"把非 context 失败也导向 fresh conversation"
//   的回归 = 用户可见失真(限流/拒答被误告知开新会话=误导; 或 context
//   耗尽只回一句无数字的 generic 串=用户空转重试)。两类都靠分类路由错。
//
// 精确值铁律(拒绝 count 弱断言):
//   context 面断言**逐字** == 期望串(带两个真实数字)。
//   路由/negative 面断言"不含 bespoke 短语" + "== localizedDescription"。
//
// 门控: 需 FoundationModels SDK(macOS 27) + 部署 min macOS 14 →
//   每 @Test 内 `guard #available(macOS 27.0, iOS 27.0, *)`, 低平台 runner
//   整测试跳过(green-by-skip 已知; xcode-27/macos-27 实际执行)。
//   与 FMToolErrorRecoveryTests 同族, 同 #if 双层门。

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import Testing

@testable import ocoreai

/// 非 FoundationModels 的普通错误 — 供"分类器不误伤非 FM 抛错"断言构造
/// (String 不 conform Error, 不能直接喂 `message(for: Error)`)。
private struct PlainNonFMError: Error {
    var reason: String
}

@Suite("FMErrorClassifier — LanguageModelSession 错误面分类 (回归门)")
struct FMSessionErrorSurfaceTests {

    @Test("contextSizeExceeded → bespoke 精确串 (真实数字 + fresh-conversation 导向)")
    func contextExhaustionGetsBespokeSurface() throws {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        // contextSize=512, 已用 tokenCount=1024 (超窗 → tokenCount > contextSize)。
        let err = FoundationModels.LanguageModelError.contextSizeExceeded(
            .init(contextSize: 512, tokenCount: 1024, debugDescription: "test")
        )
        let msg = FMErrorClassifier.message(for: err)
        #expect(
            msg
                == "Context window exhausted: 1024 tokens vs context 512 — start a fresh conversation",
            "context 面应为 bespoke 精确串 (tokenCount=1024, contextSize=512), 实际 = '\(msg)'")
    }

    @Test("refusal → 原样 localizedDescription, 绝不拿到 bespoke fresh-conversation 短语")
    func refusalDoesNotGetBespokeSurface() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let err = FoundationModels.LanguageModelError.refusal(
            .init(explanation: "declined by guardrail", debugDescription: "refusal-test")
        )
        let msg = FMErrorClassifier.message(for: err)
        #expect(
            !msg.contains("start a fresh conversation"),
            "refusal 不应被导向 fresh-conversation (误导), 实际 = '\(msg)'")
        #expect(
            msg == err.localizedDescription,
            "非 context 面应原样 localizedDescription, 实际 msg='\(msg)' vs SDK='\(err.localizedDescription)'"
        )
    }

    @Test("rateLimited → 原样 localizedDescription (非 bespoke)")
    func rateLimitedFallsThroughToSDKDescription() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let err = FoundationModels.LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "rate-test")
        )
        let msg = FMErrorClassifier.message(for: err)
        #expect(
            !msg.contains("start a fresh conversation"),
            "rateLimited 不应被导向 fresh-conversation, 实际 = '\(msg)'")
        #expect(
            msg == err.localizedDescription,
            "非 context 面应原样 localizedDescription, 实际 msg='\(msg)' vs SDK='\(err.localizedDescription)'"
        )
    }

    @Test("非 FM 错误 (自定义 Error) → 原样 localizedDescription, 分类器不误伤")
    func nonFmErrorFallsThroughUnchanged() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let err = PlainNonFMError(reason: "a plain non-FM failure")
        let msg = FMErrorClassifier.message(for: err)
        #expect(
            msg == err.localizedDescription,
            "非 FoundationModels 错误应原样回显 localizedDescription, 实际 = '\(msg)'")
        #expect(
            !msg.contains("start a fresh conversation"),
            "非 FM 错误绝不应拿到 bespoke fresh-conversation 短语, 实际 = '\(msg)'")
    }
}
#endif
