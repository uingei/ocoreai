// GuidedIncompleteRecoveryTests.swift — 契约: incompleteOutput 吸收为部分文本
//
// 对齐上游: MLXFoundationModels/MLXLanguageModel.swift L1370/L1704
//   `catch .incompleteOutput { incomplete = true }` → 保留已流式产出, 不 throw。
//
// 契约面(本测试钉住):
//   .incompleteOutput   → absorb, 不 throw (否则客户端 500, 部分文本全丢)
//   .prematureEOS 照抛, 无关错误 照抛 — 上游不吸收这两类
//   sink.incompleteOutput 标记: 吸收路径置位, 非吸收路径保持 false
//   sink.finalBuffer:   吸收路径写入部分文本, 非吸收路径保持 nil
import Foundation
import MLXGuidedGeneration
import Testing

@testable import ocoreai

@Suite("Guided incompleteOutput → 吸收为部分结果(上游 MLXFoundationModels 对齐)")
struct GuidedIncompleteRecoveryTests {

    private static let partialToolCall: String =
        "{\"name\": \"read_file\", \"arguments\": {\"path\": "

    /// incompleteOutput + 已有部分文本 → 部分文本保留 + incomplete 标记(不再 500)
    @Test func incompleteOutputPreservesPartialText() {
        let sink = GuidedGenerationDiagnosticSink()
        let recovered = absorbGuidedGenerationPartialOutput(
            error: GuidedGenerationError.incompleteOutput,
            sink: sink,
            accumulatedText: Self.partialToolCall)
        #expect(recovered, "incompleteOutput 必须被吸收, 不得 rethrow(否则客户端 500)")
        #expect(sink.finalBuffer == Self.partialToolCall, "部分文本必须保留供下游解析")
        #expect(sink.incompleteOutput == true, "incomplete 标记必须置位(UI/结构化解析据此降级)")
    }

    /// prematureEOS 不在上游吸收清单内(上游只 catch incompleteOutput) → 照抛
    @Test func prematureEOSStillThrows() {
        let sink = GuidedGenerationDiagnosticSink()
        let recovered = absorbGuidedGenerationPartialOutput(
            error: GuidedGenerationError.prematureEOS,
            sink: sink,
            accumulatedText: Self.partialToolCall)
        #expect(!recovered, "prematureEOS 必须照抛 — 上游不吸收(只 catch incompleteOutput)")
        #expect(sink.incompleteOutput == false, "非吸收路径不得改 sink 标记")
        #expect(sink.finalBuffer == nil, "非吸收路径不得写入部分文本")
    }

    /// 无关错误(OOM/cancel 等) → 照抛, 保留 60460ab 错误面语义
    struct UnrelatedError: LocalizedError {
        public var errorDescription: String? { "simulated unrelated failure" }
    }

    @Test func unrelatedErrorStillThrows() {
        let sink = GuidedGenerationDiagnosticSink()
        let recovered = absorbGuidedGenerationPartialOutput(
            error: UnrelatedError(),
            sink: sink,
            accumulatedText: Self.partialToolCall)
        #expect(!recovered, "非 GuidedGenerationError 必须照抛")
        #expect(sink.incompleteOutput == false)
    }
}
