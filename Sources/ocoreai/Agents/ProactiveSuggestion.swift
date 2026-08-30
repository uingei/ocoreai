// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// ProactiveSuggestion — 自主回路切片 1：感知到"值得注意的变化"→ 提案（不执行）
///
/// 第一性定位：AGI 闭环 `感知 → 推理 → 行动` 里，ocoreai 当前停在"被动应答"
/// （每步等人驱动）。本切片补**感知→提案**的第一段桥梁，且契约刻意保守：
///
///   - **只提案、永不自动执行**——Accept 仅把草稿填入输入框，发送权留在用户手里。
///   - **确定性决策**（纯函数，可精确值测试），不用 LLM 判断"要不要提醒"。
///   - **触发面 = 已开启的 perception 通道**——用户没开 filesystem 通道就不会有建议，
///     即"开通道 = 允许被提醒"是既有显式同意，权限零新增。
///
/// 后续切片（任务触发，不预建）：屏幕/网络等更多信号源 → 决策规则集 → "执行建议"（走
/// 既有 ApprovalBroker 审批门）。本切片只覆盖 filesystem "新文件到达" 一个信号。

import Foundation

// MARK: - Suggestion model

/// 一条待呈递的主动建议（UI 展示 + 可选草稿）。
public struct ProactiveSuggestion: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// 触发信号来源（切片 1 恒为 "filesystem"，保留扩展位）。
    public let source: String
    /// 触发实体（文件名）。
    public let fileName: String
    /// 建议文案模板 key（StringKey raw value）+ 格式化实参。
    public let detailKey: String
    public let detailArgs: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        source: String,
        fileName: String,
        detailKey: String,
        detailArgs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.fileName = fileName
        self.detailKey = detailKey
        self.detailArgs = detailArgs
        self.createdAt = createdAt
    }
}

// MARK: - Pure decision function (tested seam)

/// 纯决策：文件事件批 → 至多 1 条建议。
///
/// 规则（确定性，逐条对应测试）：
///  1. 空批 → 无建议。
///  2. 仅 `modified`/`deleted` → 无建议（"我自己的改动"不构成"值得注意的到达"，避免噪声）。
///  3. 仅 `created` 参与决策，取**时间戳最新**一条（同批多文件不刷屏）。
///  4. 隐藏文件（`.` 前缀）→ 无建议（系统噪声）。
public enum ProactiveAdvisor {
    public struct Evaluation: Equatable, Sendable {
        public let shouldSuggest: Bool
        public let fileName: String?
        public init(shouldSuggest: Bool, fileName: String?) {
            self.shouldSuggest = shouldSuggest
            self.fileName = fileName
        }
    }

    public static let detailKeyForNewFile = "Proactive.Draft"

    public static func evaluate(events: [FileChangeEvent]) -> Evaluation {
        guard !events.isEmpty else {
            return Evaluation(shouldSuggest: false, fileName: nil)
        }
        let created =
            events
            .filter { $0.eventType == .created && !$0.path.hasPrefix(".") }
            .sorted { $0.timestamp > $1.timestamp }
        guard let latest = created.first else {
            return Evaluation(shouldSuggest: false, fileName: nil)
        }
        return Evaluation(shouldSuggest: true, fileName: latest.path)
    }
}

// MARK: - Store (UI ↔ sensor 的桥，无层倒置)

/// 至多 1 条待呈递建议。传感器写入、UI 消费；不引用 UI 类型。
@MainActor
@Observable
public final class ProactiveSuggestionStore: Sendable {
    public static let shared = ProactiveSuggestionStore()

    private(set) public var current: ProactiveSuggestion?

    /// 建议呈递 5 分钟后过期（读取/呈递时清场）——避免陈旧通知滞留。
    public static let ttl: TimeInterval = 300

    private init() {}

    /// 传感器侧：新文件到达 → 记一条建议。
    /// 同名文件重复到达 → 刷新时间戳（不新增、不重置 id）。
    public func present(fileName: String) {
        if let existing = current,
            existing.fileName == fileName,
            Self.isFresh(existing)
        {
            current = ProactiveSuggestion(
                id: existing.id,
                source: existing.source,
                fileName: fileName,
                detailKey: existing.detailKey,
                detailArgs: existing.detailArgs,
                createdAt: Date()
            )
            return
        }
        current = ProactiveSuggestion(
            source: "filesystem",
            fileName: fileName,
            detailKey: ProactiveAdvisor.detailKeyForNewFile,
            detailArgs: [fileName]
        )
    }

    /// UI 侧：用户点"忽略"。
    public func dismiss() {
        current = nil
    }

    /// UI 侧：用户点"查看" → 返回要填入输入框的草稿（**发送权在用户**）。
    /// 读取即校验过期；过期返回 "not-applicable" 哨兵 + 清场。
    @discardableResult
    public func accept() -> String {
        guard let s = current else { return ProactiveSuggestionStore.notApplicable }
        guard Self.isFresh(s) else {
            current = nil
            return ProactiveSuggestionStore.notApplicable
        }
        return Self.draftText(for: s)
    }

    // MARK: - Helpers

    static let notApplicable = "__proactive_not_applicable__"

    internal static func isFresh(_ s: ProactiveSuggestion) -> Bool {
        Date().timeIntervalSince(s.createdAt) < ttl
    }

    internal static func draftText(for s: ProactiveSuggestion) -> String {
        let key = StringKey(rawValue: s.detailKey) ?? .proactiveDraft
        // 模板占位 = 文件名（按 locale 解析，支持 % 格式化）。
        return String(format: key.l, s.detailArgs.first ?? s.fileName)
    }
}
