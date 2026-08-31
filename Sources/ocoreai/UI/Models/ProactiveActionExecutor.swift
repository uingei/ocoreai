// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProactiveActionExecutor — 自主回路切片 4：批准 = 执行一次**只读观察** + 对话注入。
///
/// 第一性边界：
///   - **只读**：只跑 `read_file`（`ToolRegistry.readOnlyWhitelist` 内），绝不写/exec。
///   - **同走既有手**：经共享 `ToolRegistry.call`（audit + PreToolUse hook + loop），
///     模型用什么手就用什么手；不另起 `FileTools.read` 旁路。
///   - **不发起 LLM**：只产出"观察文本 + 草稿"，由 UI 注入对话上下文 + 填输入框；
///     发送权仍留在用户手里。
///   - **无失败悬挂**：`App.swift` 的 PreToolUse hook 仅挂破坏性工具（write_file /
///     exec_* / execute_code / edit_file）；`read_file` 不在 hook 面 → 必然 `.allow`，无审批悬挂。
///   - **失败不静默**：`read_file` 失败/无 registry → 仍给草稿 + 显式失败提示（UI 可见）。
import Foundation

@MainActor
internal final class ProactiveActionExecutor {
    private let registry: ToolRegistry?

    /// 默认注入共享 engine 的 registry（UI 面）。测试可注入自建的 registry（成功路径 seam）。
    init(registry: ToolRegistry? = OcoreaiEngine.shared.activeToolRegistry) {
        self.registry = registry
    }

    /// 批准（点"查看"）→ 执行一次只读观察 → 返回 (text, draft)。
    /// 同时校验并把 store 清场（banner 随之消失 = 已批准）。
    /// `async`：经共享 `ToolRegistry.call`（actor 隔离）跑 `read_file`。
    public func observe(suggestion: ProactiveSuggestion) async -> ProactiveObservation {
        // 先落定批准（TTL + 清场）；未批准/失效 → 不产生观察。
        let draft = ProactiveSuggestionStore.shared.accept()
        let fileName = suggestion.fileName
        guard draft != ProactiveSuggestionStore.notApplicable else {
            return ProactiveObservation(text: "", draft: "", failureDetail: "expired_or_dismissed")
        }
        guard let registry else {
            return Self.fallback(
                fileName: fileName, draft: draft, failure: "tool_registry_not_ready"
            )
        }
        let args = "{\"path\":\"" + Self.jsonEscape(suggestion.filePath) + "\"}"
        do {
            // 与模型同一只"手"：走 registry 全管线（audit + hook + loop）。
            let result = try await registry.call(
                "read_file", arguments: args, caller: "proactive-advisor")
            let text = String(format: StringKey.proactiveObservation.l, fileName, result, draft)
            return ProactiveObservation(text: text, draft: draft, failureDetail: nil)
        } catch {
            return Self.fallback(
                fileName: fileName, draft: draft, failure: String(describing: error))
        }
    }

    /// 失败兜底：把"无法读取"作为观察 + 仍给草稿供用户手动发送（不静默）。
    nonisolated static func fallback(fileName: String, draft: String, failure: String)
        -> ProactiveObservation
    {
        let text = String(format: StringKey.proactiveReadFailed.l, fileName, failure, draft)
        return ProactiveObservation(text: text, draft: draft, failureDetail: failure)
    }

    /// 最小 JSON string 转义：`"` 与 `\`。
    public nonisolated static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            if ch == "\"" || ch == "\\" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}

public struct ProactiveObservation: Sendable, Equatable {
    /// 对话上下文中显示的观察消息。
    public let text: String
    /// 填入输入框的可执行草稿（**发送权留在用户**）。
    public let draft: String
    /// 失败原因（成功态 nil）。
    public let failureDetail: String?
}
