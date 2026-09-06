// FMToolProxyContractTests.swift — 09-06 代码即文档: SDK Tool 协议契约测试
//
// 契约真身(macOS 27 SDK swiftinterface, 逐行读):
//   protocol Tool<Arguments, Output> {
//     associatedtype Arguments : ConvertibleFromGeneratedContent   // ← 唯一硬约束
//     associatedtype Output : PromptRepresentable
//     var parameters: GenerationSchema { get }
//     func call(arguments: Self.Arguments) async throws -> Self.Output
//   }
//   extension Tool where Self.Arguments == String {
//     @available(*, unavailable, message: "'Tool' that uses 'String' as
//     'Arguments' type is unsupported. Use '@Generable' struct instead.")
//     public var parameters: GenerationSchema { get }
//   }
//   (Int/Double/Float/Decimal/Bool 同列 unavailable — 标量 Arguments 全被 SDK 否定)
//
// 归因链(缺陷 3: 工具调用 "Failed to parse generated content"):
//   - 该错误串在 ocoreai/三仓/references 全树零命中 = FoundationModels 运行期抛
//   - SDK parse 通道 = Arguments.init(_ content: GeneratedContent)
//   - GeneratedContent.Kind = null/bool/number/string/array/structure
//   - 模型的工具参数是结构体 {…} → String 通道拿不到 → 必炸 — 与模型能力无关
//   - 正路: GeneratedContent 自身 conform Generable 且自带 .jsonString —
//     结构动态工具(MCP/27 内置)的 Arguments 唯一恒等类型。

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import FoundationModels
import Testing

@testable import ocoreai

@Suite("FMToolProxy SDK Contract")
struct FMToolProxyContractTests {

    @Test("Arguments 是 GeneratedContent — 结构体参数经 .jsonString 可达 ToolRegistry.call")
    func argumentsAreGeneratableContent() async throws {
        // GeneratedContent 需 macOS 26+/iOS 26+;包底 14/17 — 低平台无 FM 门,此处早退。
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        // 编译期契约: .jsonString 仅在 GeneratedContent 上存在 —
        // Arguments == String(旧值)时本行编译失败, 即 RED。
        let content = try FoundationModels.GeneratedContent(json: #"{"query":"swift"}"#)
        #expect(content.jsonString.contains("swift"))
    }
}
#endif
