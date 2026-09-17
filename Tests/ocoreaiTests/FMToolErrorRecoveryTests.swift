// FMToolErrorRecoveryTests.swift — 契约: FM 路径 handler 失败镜像 MLX/codex 回灌
//
// 同一失败、两条路径结局必须一致(行为分叉红线):
//   - MLX 路径 (EngineInference catch-site): 回灌 `"[tool_error: <msg>]"` 给模型自纠
//   - FM 路径 (本文件钉住):  `proxy.call` 不 throw, 返回 `"[tool_error: …]"` 同型串
//     (throw 会被 FM SDK 视为致命 → 整轮 500, 零恢复)
// 成功路径不被吞: 正常返回 payload。
//
// 断言精确值: 返回串逐字 == ToolError.executionFailed/invalidParameter 的
// errorDescription 拼接 (sanitizeError 对 <> 转义 &lt; / &gt;)。
//
// 门控: 需 FoundationModels SDK (macOS 27) + FMToolProxy @available(27.0)。
// 低平台/无 SDK runner 整文件编译剔除, macos-27/xcode-27 实际执行 (非 green-by-skip)。

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
