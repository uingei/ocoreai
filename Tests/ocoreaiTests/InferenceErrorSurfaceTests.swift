// InferenceErrorSurfaceTests.swift — top-level catch 错误面: 原错误语义不得被覆盖
//
// 契约 (inferenceTopLevelFailedMessage, 纯函数 Error->String):
//   - 保留原错误的 localizedDescription — 客户端据此区分 grammar 耗尽 / OOM / 超时;
//   - 保留客户端已解析的 "Inference failed: " 前缀。
// 两处 catch (top-level 与 pipelined) 对同一类失败结局必须一致 — 行为分叉红线。

import Foundation
import Testing

@testable import ocoreai

@Suite("InferenceErrorSurface — top-level catch 必须保留原错误语义")
struct InferenceErrorSurfaceTests {

    /// 构造一个本地化错误:`LocalizeError`协议让 `localizedDescription` 精确可控,
    /// 用于对 wire message 全串精确比对。(注意:纯 `Error` 不符合此点 —
    ///  其默认 `localizedDescription` 会拼 type 名, 不可控。)
    struct GuidedLikeError: LocalizedError {
        var errorDescription: String? {
            "The operation couldn't be completed. (MLXGuidedGeneration.GuidedGenerationError error 0.)"
        }
    }

    private static let guidedMsg: String =
        "Inference failed: The operation couldn't be completed."
        + " (MLXGuidedGeneration.GuidedGenerationError error 0.)"

    @Test("语法耗尽错误 — message 逐字保留原错(含 domain 限定名)")
    func guidedGenerationErrorIsPreserved() {
        #expect(inferenceTopLevelFailedMessage(for: GuidedLikeError()) == Self.guidedMsg)
    }

    @Test("不同根因 → 不同 wire 消息(客户端可判别 grammar vs OOM)")
    func distinctCausesProduceDistinctMessages() {
        let grammar = inferenceTopLevelFailedMessage(for: GuidedLikeError())
        let oomMsg = inferenceTopLevelFailedMessage(for: Self.oomError())
        #expect(grammar != oomMsg)
        #expect(grammar == Self.guidedMsg)
    }

    @Test("客户端已解析的前缀 'Inference failed:' 保留")
    func clientParseablePrefixRetained() {
        let msg = inferenceTopLevelFailedMessage(for: GuidedLikeError())
        #expect(msg.hasPrefix("Inference failed: "))
    }

    @Test("standardPathFailed.errorDescription 前缀契约(逐字对齐 CoreAIEngine.swift:52)")
    func errorDescriptionPrefixIsStable() {
        let msg = InferenceError.standardPathFailed("X").errorDescription
        #expect(msg == "Inference failed: X")
    }

    /// OOM 型错误的稳定构造 — 用一个真实 LocalizedError 保证 localizedDescription 精确。
    static func oomError() -> LocalizedError {
        struct E: LocalizedError {
            var errorDescription: String? { "out of memory (wired limit)" }
        }
        return E()
    }
}
