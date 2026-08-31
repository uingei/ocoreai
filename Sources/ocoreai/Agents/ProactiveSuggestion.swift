// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// ProactiveSuggestion — 自主回路：感知到"值得注意的变化"→ 提案（不执行）
///
/// 第一性定位：AGI 闭环 `感知 → 推理 → 行动` 里，ocoreai 当前停在"被动应答"
/// （每步等人驱动）。本模块补**感知→提案→(用户批准)→可行动指令**的第一段桥梁，
/// 且契约刻意保守：
///
///   - **只提案、永不自动执行**——"查看"仅产出可执行草稿填入输入框，发送权留在用户手里。
///   - **确定性决策**（纯函数，可精确值测试），不用 LLM 判断"要不要提醒"。
///   - **触发面 = 已开启的 perception 通道**——用户没开 filesystem 通道就不会有建议，
///     即"开通道 = 允许被提醒"是既有显式同意，权限零新增。
///   - **观察可行动**（切片 3）：`ProactiveSuggestion` 携带触发文件的**绝对路径**
///     （可寻址目标）；"查看"草稿 = 可执行指令 + 完整路径，LLM 拿到 `read_file` 直接目标，
///     不再靠猜目录。安全边界不变：仍只读、仍不自动发送、仍不越权到别处。
import Foundation

// MARK: - Suggestion model

/// 一条待呈递的主动建议（UI 展示 + 可执行草稿）。
public struct ProactiveSuggestion: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// 触发信号来源（切片 1 恒为 "filesystem"，保留扩展位）。
    public let source: String
    /// 触发文件的**绝对路径**（可寻址目标——草稿/工具可直接引用 `read_file`）。
    public let filePath: String
    /// 建议草稿模板 key（StringKey raw value）。
    public let detailKey: String
    public let createdAt: Date

    /// 文件短名（派生，UI/banner 展示用）。
    public var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }

    public init(
        id: UUID = UUID(),
        source: String,
        filePath: String,
        detailKey: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.filePath = filePath
        self.detailKey = detailKey
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
///  输出 = **绝对路径**（可寻址目标），不输出裸文件名。
public enum ProactiveAdvisor {
    public struct Evaluation: Equatable, Sendable {
        public let shouldSuggest: Bool
        /// 触发文件的**绝对路径**（可寻址目标）；无建议时 nil。
        public let filePath: String?
        public init(shouldSuggest: Bool, filePath: String?) {
            self.shouldSuggest = shouldSuggest
            self.filePath = filePath
        }
    }

    /// 新文件到达建议的草稿模板 key。
    public static let detailKeyForNewFile = "Proactive.Draft"

    public static func evaluate(events: [FileChangeEvent]) -> Evaluation {
        guard !events.isEmpty else {
            return Evaluation(shouldSuggest: false, filePath: nil)
        }
        let created =
            events
            .filter { $0.eventType == .created && !$0.fileName.hasPrefix(".") }
            .sorted { $0.timestamp > $1.timestamp }
        guard let latest = created.first else {
            return Evaluation(shouldSuggest: false, filePath: nil)
        }
        return Evaluation(shouldSuggest: true, filePath: latest.path)
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

    /// 传感器侧：新文件到达 → 记一条建议（携带**绝对路径**）。
    /// 同一路径重复到达 → 刷新时间戳（不新增、不重置 id）。
    public func present(filePath: String) {
        if let existing = current,
            existing.filePath == filePath,
            Self.isFresh(existing)
        {
            current = ProactiveSuggestion(
                id: existing.id,
                source: existing.source,
                filePath: filePath,
                detailKey: existing.detailKey,
                createdAt: Date()
            )
            return
        }
        current = ProactiveSuggestion(
            source: "filesystem",
            filePath: filePath,
            detailKey: ProactiveAdvisor.detailKeyForNewFile
        )
    }

    /// UI 侧：用户点"忽略"。
    public func dismiss() {
        current = nil
    }

    /// UI 侧：用户点"查看" → 返回要填入输入框的可执行草稿（**发送权在用户**）。
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

    /// 由建议生成可执行草稿文案（纯展示面，供 UI/测试直接用；纯函数，非 actor 隔离）。
    public nonisolated static func draftText(for s: ProactiveSuggestion) -> String {
        let key = StringKey(rawValue: s.detailKey) ?? .proactiveDraft
        // 模板实参：%1 = 短名（展示友好），%2 = 绝对路径（可寻址，工具可直接 read_file）。
        return String(format: key.l, s.fileName, s.filePath)
    }
}
