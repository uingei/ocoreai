// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// verify namespace — Verify 段的 agent 自查询面（审计 trace 的**第一个非 UI 消费者**）:
///
///   check_tools   报告审计窗口内工具执行结果 — success/error/cancelled/timeout 计数
///                 + 逐条明细（工具名/状态/时长/结果摘要 160 字符硬截断）。
///
/// 定位: 六段环 Verify 段此前零消费者——`AuditTrail` 写入完整（ToolRegistry 每次
/// 执行 beginCall/completeToken 双写内存环+SQLite audit_traces, commit 7676ac5
/// 落盘 durable），但全库唯一读方 = UI 展示（SystemViewModel.loadAudit, UI 面非
/// agent 面）。模型无法回答"我刚才那批工具调用，哪些失败、为什么"——只有自身
/// 可不信的复述。本工具把既有审计真值源暴露给 agent，闭合
/// 写入→落盘→查询→消费 四段。
///
/// 真值源 = OcoreaiEngine.shared.activeAuditTrail —— 与 UI 读面同一 actor 实例:
/// 内存环（recent）∪ SQLite 持久面（recentPersisted, commit 7676ac5），按 id
/// 去重（AuditTrail.merge 先例, in-memory 优先）。窗口默认 300s（clamp 5...3600）。
/// 只读, 对审计环与 SQLite 零副作用。
/// 缺席 = 诚实报 "no tool executions"（不伪造在场, observe_state 同一纪律）。
import Foundation

// MARK: - 纯计算(离线可测, 不触 AuditTrail / OcoreaiEngine)

enum AuditVerify {
    /// 结果摘要截断上限（160 字符 ≈ ~40 token — N 条明细 × 40 仍在注入预算内;
    /// 完整结果 UI 面仍可从 audit_traces 查）。
    static let maxResultChars = 160
    /// 默认窗口 300s ≈ "本轮任务"常用跨度; clamp 5...3600（防无限全量扫）。
    static let windowRange: ClosedRange<Int> = 5 ... 3600
    static let defaultWindowSeconds = 300
    static let defaultLimit = 20
    static let maxLimit = 200

    /// 窗口 + 过滤 + 时间倒序 + limit 截断的**纯**函数（now 注入 → 窗口边界精确
    /// 可测, 不依赖 wall clock）。同时间戳 tiebreak = id 倒序（merge 先例, 确定性）。
    /// tool/status 过滤语义: nil = 不过滤; 非 nil = 精确匹配（status 匹配 rawValue,
    /// 与 schema 文档四态一致: success/error/cancelled/timeout）。
    static func filterAndSort(
        entries: [AuditEntry],
        tool: String?,
        status: String?,
        windowSeconds: Int,
        limit: Int,
        now: Date,
    ) -> [AuditEntry] {
        let cutoff = now.addingTimeInterval(-Double(windowSeconds))
        let filtered = entries.filter { e in
            e.timestamp >= cutoff
                && (tool == nil || e.toolName == tool)
                && (status == nil || e.status.rawValue == status)
        }
        let sorted = filtered.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            return a.id > b.id
        }
        return Array(sorted.prefix(limit))
    }

    /// 160 字符硬截断（边界精确: ≤160 原样, >160 截到 160）。
    static func clip(_ s: String) -> String {
        s.count <= maxResultChars ? s : String(s.prefix(maxResultChars))
    }

    /// 渲染（离线可测; now 注入 = age 精确断言）。
    /// 报告头 = 窗口/limit/四态计数; 明细 = 工具名/状态/时长(整 ms)/age/摘要。
    /// 计数口径 = 窗口∩过滤∩limit 内的条目数（报告头明示, 不伪装全历史计数）。
    static func render(
        entries: [AuditEntry],
        tool: String? = nil,
        status: String? = nil,
        windowSeconds: Int = defaultWindowSeconds,
        limit: Int = defaultLimit,
        now: Date = Date(),
    ) -> String {
        let inWindow = filterAndSort(
            entries: entries, tool: tool, status: status,
            windowSeconds: windowSeconds, limit: limit, now: now)
        guard !inWindow.isEmpty else {
            var why = "nothing to verify yet"
            if tool != nil || status != nil {
                why += " (or the tool/status filter matched nothing)"
            }
            return "[Audit] no tool executions in the last \(windowSeconds)s — " + why + "."
        }
        var c = (success: 0, error: 0, cancelled: 0, timeout: 0)
        for e in inWindow {
            switch e.status {
            case .success: c.success += 1
            case .error: c.error += 1
            case .cancelled: c.cancelled += 1
            case .timeout: c.timeout += 1
            }
        }
        var lines = [
            "[Audit] window \(windowSeconds)s, limit \(limit), \(inWindow.count) execution(s): "
                + "success \(c.success), error \(c.error), cancelled \(c.cancelled), timeout \(c.timeout)"
        ]
        for e in inWindow {
            let age = max(0, Int(now.timeIntervalSince(e.timestamp)))
            let summary = e.resultSummary.isEmpty ? "" : " — \(clip(e.resultSummary))"
            lines.append(
                "- \(e.toolName): \(e.status.rawValue) (\(Int(e.durationMs))ms, age \(age)s)\(summary)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - client(seam 绑定)

enum CheckToolsClient {
    static let toolName = "check_tools"

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "verify",
            argsType: Args.self,
            description:
                "Check recent tool-execution results from the durable audit trail "
                + "(ground truth, not self-report): success/error/cancelled/timeout "
                + "counts plus per-call duration and result summary within a time window. "
                + "Use to verify past tool calls before declaring a task complete. "
                + "Optional `tool` filters to one tool name; `status` to one result status.",
            schema: ToolSchema(parameters: [
                "tool": ToolParameter(
                    type: .string, description: "Optional: filter to one tool name (e.g. \"exec\")."
                ),
                "status": ToolParameter(
                    type: .string,
                    description: "Optional: filter to one status (success/error/cancelled/timeout)."
                ),
                "window_seconds": ToolParameter(
                    type: .integer,
                    description: "Optional window in seconds (default 300, clamped 5...3600)."),
                "limit": ToolParameter(
                    type: .integer, description: "Optional max entries (default 20, max 200)."),
            ])
        ) { args in
            await runForTool(
                tool: args.tool, status: args.status,
                windowSeconds: args.window_seconds, limit: args.limit)
        }
    }

    struct Args: Codable, Sendable {
        let tool: String?
        let status: String?
        let window_seconds: Int?
        let limit: Int?
    }

    /// 生产路径: 读 OcoreaiEngine 审计 actor（跨 actor 边界必 await, 铁律）。
    /// 双读内存环 ∪ SQLite persistent, id 去重（in-memory 优先 = `AuditTrail.merge`
    /// 同一语义, 独立纯函数 reduce 不耦合 actor）。
    static func runForTool(
        tool: String? = nil, status: String? = nil,
        windowSeconds: Int? = nil, limit: Int? = nil,
    ) async -> String {
        let trail: AuditTrail? = await OcoreaiEngine.shared.activeAuditTrail
        guard let trail else {
            return "[Audit] audit trail not attached — no entries to verify on this path."
        }
        let window =
            clampInt(windowSeconds, to: AuditVerify.windowRange)
            ?? AuditVerify.defaultWindowSeconds
        let cap = min(
            clampInt(limit, to: 1 ... AuditVerify.maxLimit) ?? AuditVerify.defaultLimit,
            AuditVerify.maxLimit)
        let inMem = await trail.recent(limit: 5000)
        let persisted = await trail.recentPersisted(limit: 5000)
        let merged = reduce(persistent: persisted, inMem: inMem).values
            .sorted { a, b in
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
                return a.id > b.id
            }
        return AuditVerify.render(
            entries: merged,
            tool: tool, status: status,
            windowSeconds: window, limit: cap,
            now: Date())
    }

    /// 纯去重（id 键, in-memory 优先覆盖 persistent）— 离线可测, 与
    /// `AuditTrail.merge` 同一先例（`AuditTrail.swift:377-391`）。
    static func reduce(persistent: [AuditEntry], inMem: [AuditEntry]) -> [String: AuditEntry] {
        var byID: [String: AuditEntry] = [:]
        for e in persistent { byID[e.id] = e }
        for e in inMem { byID[e.id] = e }
        return byID
    }
}

// MARK: - 本地 clamp（Comparable 泛型扩展避免与 Foundation 未来符号撞名; 纯值, 离线可测）

private func clampInt(_ v: Int?, to range: ClosedRange<Int>) -> Int? {
    guard let v else { return nil }
    return min(max(v, range.lowerBound), range.upperBound)
}
