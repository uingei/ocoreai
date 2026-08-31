// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// ProactiveActionExecutor 切片 4（批准→只读行动）精确值测试。
///
/// 断言刻意 locale-不变（draft / 绝对路径 / failureDetail 哨兵），
/// 不断言 locale 模板词 —— 同一断言 en/zh 都稳。
import Foundation
import Testing

@testable import ocoreai

@Suite("ProactiveActionExecutor — 批准→只读行动")
struct ProactiveActionExecutorTests {
    /// 落一个真临时文本文件，返回其绝对路径。
    private func makeTempFile(_ name: String, body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("ocoreai-proactive-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fileURL = url.appendingPathComponent(name)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    /// 自建 registry，注册一个**真 `read_file`**（handler = 真 `FileTools.read`，走真只读路径），
    /// `hooks:[]` → PreToolUse 必然 `.allow`（无审批悬挂，与 App.swift 同款约束）。
    private func makeRegistry() async throws -> ToolRegistry {
        let registry = ToolRegistry()
        struct ReadFileArgs: Codable {
            let path: String
            let offset: Int?
            let limit: Int?
        }
        let entry = ToolEntry.typed(
            name: "read_file",
            toolset: "files",
            argsType: ReadFileArgs.self
        ) { args in
            try FileTools.read(path: args.path, offset: args.offset, limit: args.limit)
        }
        try await registry.register(entry)
        return registry
    }

    @MainActor
    @Test("批准 + 可注册 read_file → 真观察文本(非失败) + 草稿非哨兵 + 文件短名在观察里")
    func successReadsAndObserves() async throws {
        let path = try makeTempFile("hello.txt", body: "hello observation\nline2")
        let registry = try await makeRegistry()
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: path)
        let suggestion = ProactiveSuggestionStore.shared.current
        #expect(suggestion != nil)
        let executor = ProactiveActionExecutor(registry: registry)
        let obs = await executor.observe(
            suggestion: ProactiveSuggestion(
                source: "filesystem", filePath: path,
                detailKey: ProactiveAdvisor.detailKeyForNewFile))
        #expect(obs.failureDetail == nil, "成功态不得有失败原因: \(String(describing: obs.failureDetail))")
        #expect(!obs.draft.isEmpty)
        #expect(obs.draft != ProactiveSuggestionStore.notApplicable)
        // draft 是真实草稿（非哨兵）→ 含绝对路径（可寻址目标，locale-不变）
        #expect(obs.draft.contains(path), "draft 须含完整绝对路径: \(obs.draft)")
        #expect(obs.text.contains("hello.txt"), "观察文本须含文件短名: \(obs.text)")
        #expect(obs.text.contains(obs.draft), "观察文本须含草稿")
        // 批准已清场
        #expect(ProactiveSuggestionStore.shared.current == nil)
    }

    @MainActor
    @Test("无 registry → 兜底: 仍给非哨兵草稿 + failureDetail 哨兵(不静默)")
    func noRegistryFallsBackToDraft() async {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/mystery.bin")
        let executor = ProactiveActionExecutor(registry: nil)
        let obs = await executor.observe(
            suggestion: ProactiveSuggestion(
                source: "filesystem", filePath: "/tmp/proj/mystery.bin",
                detailKey: ProactiveAdvisor.detailKeyForNewFile))
        #expect(obs.failureDetail == "tool_registry_not_ready")
        #expect(!obs.draft.isEmpty)
        #expect(obs.draft != ProactiveSuggestionStore.notApplicable)
        #expect(obs.text.contains("mystery.bin"), "兜底观察仍须含短名: \(obs.text)")
        #expect(ProactiveSuggestionStore.shared.current == nil)
    }

    @MainActor
    @Test("无建议(空批/已清场) → 空观察草稿 + expired 哨兵(不产生行动)")
    func expiredNoSuggestion() async {
        ProactiveSuggestionStore.shared.dismiss()
        // 不 present 任何建议 → accept() = notApplicable 哨兵
        let executor = ProactiveActionExecutor(registry: nil)
        let obs = await executor.observe(
            suggestion: ProactiveSuggestion(
                source: "filesystem", filePath: "", detailKey: ProactiveAdvisor.detailKeyForNewFile)
        )
        #expect(obs.draft == "")
        #expect(obs.text == "")
        #expect(obs.failureDetail == "expired_or_dismissed")
    }
}

@Suite("ProactiveActionExecutor.jsonEscape — 纯函数精确值")
struct ProactiveJsonEscapeTests {
    @Test("无特殊字符 → 原样")
    func noSpecial() {
        #expect(ProactiveActionExecutor.jsonEscape("/tmp/proj/a.md") == "/tmp/proj/a.md")
        #expect(ProactiveActionExecutor.jsonEscape("plain") == "plain")
    }

    @Test("引号 → 转义(加反斜杠)")
    func quoteEscaped() {
        #expect(ProactiveActionExecutor.jsonEscape("a\"b") == "a\\\"b")
    }

    @Test("反斜杠 → 转义")
    func backslashEscaped() {
        #expect(ProactiveActionExecutor.jsonEscape("a\\b") == "a\\\\b")
    }

    @Test("引号+反斜杠混合")
    func mixed() {
        let src = "a\"\\b"
        #expect(ProactiveActionExecutor.jsonEscape(src) == "a\\\"\\\\b")
    }

    @Test("空 → 空")
    func empty() {
        #expect(ProactiveActionExecutor.jsonEscape("") == "")
    }
}
