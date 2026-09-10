// FMToolErrorRecoveryTests.swift — 09-10 行为分叉修复回归门
//
// 缺陷(活体实证 /tmp/ocoreai-e2e-0910.log + /tmp/e2e-coding-result.json):
//   两条路径对"工具 handler 失败"结局相反 —
//   - MLX 路径 (EngineInference.swift L2683-2690): handler 失败 →
//     回灌模型 `"[tool_error: <msg>]"` 自纠重试 (codex 语义, 注释明写)。
//   - FM 路径 (FMToolBridge.swift 旧 L97-99): `try await registry.call` 直接传播
//     → FM SDK 视为致命 → 整轮 500, 零恢复。活体: 4B edit_file 猜错 oldString →
//     client 收到 `Generation failed: ... FMToolProxy(edit_file) ... refusing
//     partial edit`。
//   同一失败、两条路径不同结局 = 行为分叉(最伤用户一类)。
//
// 红线基准(修复): FM 路径镜像 MLX/codex — handler 失败返回
//   `"[tool_error: <localizedDescription>]"` (工具结果错误串), 不 throw,
//   让模型拿得到自纠机会。
//
// 测试 = 精确值 (用户铁律: 精确值 #expect==N, 拒绝 count 弱断言):
//   断言返回串 == "[tool_error: Tool execution failed: <sanitized msg>]"
//   (ToolError.executionFailed 的 errorDescription 逐字拼接, 见 ToolEntry.swift
//   `case .executionFailed: "Tool execution failed: \(error.localizedDescription)"`,
//   且 sanitizeError 会对 < > 做 &lt; / &gt; 转义)。
//
// 门控: 需 FoundationModels SDK (macOS 27) + FMToolProxy 为 @available(27.0)
// 类型。与 FMToolProxyContractTests 同族 — 低平台/无 SDK runner 整文件编译剔除,
// macos-27/xcode-27 runner 实际执行 (Verification Claim Gate, 非 green-by-skip)。

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import Logging
import Testing

@testable import ocoreai

@Suite("FMToolProxy — Tool-Error Recovery (行为分叉回归门)")
struct FMToolErrorRecoveryTests {

    /// 构造一个必失败工具:handler 无条件 throw。
    /// 选 `edit_file` 同型失败(handler 级 `ToolError` / Error)做代表。
    func makeFailingRegistry() async -> ToolRegistry {
        let registry = ToolRegistry(log: Logger(label: "test.fmtoolrecoveryp"))
        // 与 FileTools.edit_file 拒绝路径同型:ToolError.invalidParameter 抛
        // (handler 内部 throw, 非 preflight 拒绝 — preflight 发生在 call() 早期,
        // 这里我们直接让 handler 抛, 走 L382 `catch` → ToolError.executionFailed 包装)。
        let entry = ToolEntry(
            name: "edit_file",
            toolset: "files",
            schema: ToolSchema(
                parameters: [
                    "path": ToolParameter(type: .string),
                    "oldString": ToolParameter(type: .string),
                ]),
            description: "Search-and-replace in one file; requires exact match count",
            handler: { _ in
                // edit_file 真实拒绝串(FileTools.swift L145 "refusing partial edit")
                throw ToolError.invalidParameter(
                    "edit_file: expected exactly 1 occurrence(s) of oldString in /tmp/calc.swift, found 0 — refusing partial edit"
                )
            }
        )
        try? await registry.register(entry)
        return registry
    }

    @Test("FM 路径 handler 失败 → 回灌 [tool_error: …], 不 throw (镜像 MLX/codex)")
    func fmPathSurfacesToolErrorToModel() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let registry = await makeFailingRegistry()
        let logger = Logger(label: "test.fmtoolrecoveryp")

        let specs = await registry.toToolSpecs()
        let tools = FMToolProxy.tools(from: registry, toolSpecs: specs, log: logger)
        #expect(tools.count == 1, "registry 仅 1 工具 → FM 应产 1 proxy")

        guard let proxy = tools.first as? FMToolProxy else {
            Issue.record("FMToolProxy.tools 未解析出 FMToolProxy 实例")
            return
        }

        // 模型生成的参数(structure),经 SDK 解析成 GeneratedContent 传入。
        let content = try FoundationModels.GeneratedContent(
            json: #"{"path":"/tmp/calc.swift","oldString":"x"}"#)

        // 关键断言:不应 throw;应返回工具结果错误串(让模型自纠)。
        let result = try await proxy.call(arguments: content)
        #expect(
            result
                == "[tool_error: Invalid parameter: edit_file: expected exactly 1 occurrence(s) of oldString in /tmp/calc.swift, found 0 — refusing partial edit]",
            "FM 路径应镜像 MLX/codex 的 [tool_error: …] 回灌, 实际 = '\(result)'")
    }

    @Test("FM 路径成功工具 → 正常返回结果(不吞成功路径)")
    func fmPathReturnsSuccessResult() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let registry = ToolRegistry(log: Logger(label: "test.fmtoolrecoveryp"))
        let okEntry = ToolEntry(
            name: "noop_ok",
            toolset: "test",
            schema: ToolSchema(parameters: ["x": ToolParameter(type: .string)]),
            description: "ok tool",
            handler: { _ in "success-payload" }
        )
        try? await registry.register(okEntry)
        let logger = Logger(label: "test.fmtoolrecoveryp")
        let specs = await registry.toToolSpecs()
        let tools = FMToolProxy.tools(from: registry, toolSpecs: specs, log: logger)
        guard let proxy = tools.first as? FMToolProxy else {
            Issue.record("no proxy")
            return
        }
        let content = try FoundationModels.GeneratedContent(json: #"{"x":"1"}"#)
        let result = try await proxy.call(arguments: content)
        #expect(result == "success-payload")
    }
}
#endif
