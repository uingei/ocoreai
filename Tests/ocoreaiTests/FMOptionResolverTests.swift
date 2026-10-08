// FMOptionResolverTests.swift — FM 选项决策矩阵钉死（提取自 runInferenceBody 的 verbatim 语义）
//
// 第一性原理: runInferenceBody 的 760 行里, 这四面是纯函数决策——
//   samplingMode / toolCallingMode / contextOptions / guidedSchema。
// 抽到 FMOptionResolver 后必须证明"抽取即等价": 每个分支一个断言,
// 输入→输出的完整矩阵钉死, 任何后续改动若偏离原语义即刻 RED。
//
// 编译面: 与 FMToolProxyContractTests 同 gate — 仅 CI (macos-26 runner +
// Xcode SDK27) 执行; CLT SDK26.5 无 FM v2 符号, 该文件编译为空。

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import FoundationModels
import Logging
import Testing

@testable import ocoreai

private let testLog = Logger(label: "FMOptionResolverTests")

@Suite("FMOptionResolver — decision matrices (extraction parity)")
struct FMOptionResolverTests {

    // MARK: - samplingMode

    @Test("samplingMode: greedy → .greedy")
    func samplingModeGreedy() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                var s = SamplingConfiguration()
        s.mode = .greedy
        #expect(FMOptionResolver.samplingMode(from: s) == .greedy)
    }

    @Test("samplingMode: topK carries k + seed")
    func samplingModeTopK() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                var s = SamplingConfiguration()
        s.mode = .topK(40)
        s.topK = 40
        s.seed = 123
        let m = FMOptionResolver.samplingMode(from: s)
        #expect(m == .random(top: 40, seed: 123))
    }

    @Test("samplingMode: nucleus → probabilityThreshold")
    func samplingModeNucleus() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                var s = SamplingConfiguration()
        s.mode = .nucleus(0.9)
        s.topP = 0.9
        let m = FMOptionResolver.samplingMode(from: s)
        #expect(m == .random(probabilityThreshold: 0.9, seed: nil))
    }

    @Test("samplingMode: nil mode → nil (SDK defaults)")
    func samplingModeDefault() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                let s = SamplingConfiguration()
        #expect(FMOptionResolver.samplingMode(from: s) == nil)
    }

    // MARK: - toolCallingMode

    @Test("toolCallingMode: no tools forces .disallowed even if required")
    func tcModeNoTools() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                #expect(
            FMOptionResolver.toolCallingMode(toolsPresent: false, explicitToolChoice: "required")
                == .disallowed)
    }

    @Test("toolCallingMode: explicit required/disallowed honored, unknown → .allowed")
    func tcModeExplicit() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                #expect(
            FMOptionResolver.toolCallingMode(toolsPresent: true, explicitToolChoice: "required")
                == .required)
        #expect(
            FMOptionResolver.toolCallingMode(toolsPresent: true, explicitToolChoice: "DISALLOWED")
                == .disallowed)
        #expect(
            FMOptionResolver.toolCallingMode(toolsPresent: true, explicitToolChoice: nil)
                == .allowed)
        #expect(
            FMOptionResolver.toolCallingMode(toolsPresent: true, explicitToolChoice: "auto")
                == .allowed)
    }

    // MARK: - contextOptions

    @Test("contextOptions: explicit level honored (case-insensitive)")
    func ctxExplicitLevel() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: "LIGHT", enableReasoning: nil, log: testLog)
                == ContextOptions(reasoningLevel: .light))
        #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: "moderate", enableReasoning: nil, log: testLog)
                == ContextOptions(reasoningLevel: .moderate))
        #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: "deep", enableReasoning: nil, log: testLog)
                == ContextOptions(reasoningLevel: .deep))
    }

    @Test("contextOptions: unknown level + boolean fallback")
    func ctxUnknownLevel() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: "turbo", enableReasoning: true, log: testLog)
                == ContextOptions(reasoningLevel: .deep))
        #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: "turbo", enableReasoning: false, log: testLog)
                == ContextOptions())
    }

    @Test("contextOptions: legacy boolean path → .deep; off → default")
    func ctxLegacyBoolean() {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: nil, enableReasoning: true, log: testLog)
                == ContextOptions(reasoningLevel: .deep))
        #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: nil, enableReasoning: false, log: testLog)
                == ContextOptions())
        #expect(
            FMOptionResolver.contextOptions(
                explicitReasoningLevel: nil, enableReasoning: nil, log: testLog)
                == ContextOptions())
    }

    // MARK: - guidedSchema

    @Test("guidedSchema: valid JSON Schema → GenerationSchema; junk/nil → nil")
    func guidedSchemaResolution() throws {
guard #available(macOS 27.0, iOS 27.0, *) else { return }
                let json =
            #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}"#
        let schema = FMOptionResolver.guidedSchema(from: json)
        #expect(schema != nil)
        // Malformed JSON must degrade to nil (unguided fallback), never throw.
        #expect(FMOptionResolver.guidedSchema(from: "{not json") == nil)
        #expect(FMOptionResolver.guidedSchema(from: nil) == nil)
    }
}
#endif
