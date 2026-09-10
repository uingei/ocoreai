// GuidedIncompleteRecoveryTests.swift — 09-10 incompleteOutput 吸收回归门(上游对齐)
//
// 上游 canonical(MLXFoundationModels/MLXLanguageModel.swift L1370/L1704):
//   `catch GuidedGenerationError.incompleteOutput { incomplete = true }`
//   → 保留已流式产出的部分文本, 照常收尾, 不 throw。
// 库真身(GuidedGenerationLoop.swift:466): maxTokens 耗尽语法未终止时
//   `throw GuidedGenerationError.incompleteOutput`(emit 已发生的文本不丢)。
// 库 doc(GuidedGenerationError.swift:27): "Downstream code should catch this
//   case to emit partial results if needed."
//
// ocoreai 修复前: catch 全吞 → `throw error` → HTTP 500, 已采样文本全丢。
// 活体实证: Qwen3.5-4B guided sampled=2792 finalBuf=nil → 500 硬失败。
//
// 铁律「上游已解决 → 必须吸收」: ocoreai 的同型 catch 对齐上游 —
//   incompleteOutput → 保留已产出文本为部分结果(不 500);
//   prematureEOS / 其它错误 → 照抛(上游不吸收, 保留 60460ab 错误面语义)。
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
