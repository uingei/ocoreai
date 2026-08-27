// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Approval.swift — 审批参照形状（codex 基准，语义对齐非逐行抄）。
///
/// 上游锚点：
/// - `codex-rs/protocol/src/protocol.rs:924` `AskForApproval`
///   （on-request / untrusted / granular / never）
///   → ocoreai 只取两档：`.interactive`（≈ on-request：高危才问）与
///   `.never`（≈ never：不问、直接硬拒）。
/// `untrusted` / `granular` 依赖 codex 的 subprocess 沙箱与细粒度策略面，
/// ocoreai 无此执行面，按「不自己造」不取。
/// - `codex-rs/protocol/src/protocol.rs:3877` `ReviewDecision`
///   （Approved / ApprovedForSession / Denied{rejection} / Abort）
///   → ocoreai：`.approved` / `.approvedForSession` / `.denied(reason:)`。
/// `Abort` 为会话级用户操作（UI Escape 承担），不属于 broker 决策；
/// execpolicy 持久规则为后续任务，不预建。
/// - `codex-rs/tui/src/history_cell/approvals.rs`
///   （pending 呈现：工具名 + snippet；decision 三档按钮）→ ChatView banner（UI 层）
/// - `codex-rs/core/src/tools/sandboxing.rs:43`
///   （session 缓存语义："future requests touching any subset can also skip
///   prompting"）与 `with_cached_approval`（`ApprovedForSession` 按 key 缓存）
///   → `ApprovalBroker.sessionApprovedByTool`。
/// - `codex-rs/tui/src/text_formatting.rs:89` `truncate_text`
///   （>max graphemes → 截 max-3 + "..."）→ `ApprovalCore.snippet` 逐字同构。
///
/// 调用链（chokepoint 单点）：
///   `ToolRegistry.call` PreToolUse `.ask(verdict)`
///     → `ApprovalBroker.request`（策略判定 / 缓存命中 / pending 挂起）
///       → UI（`ApprovalBanner`）resolve → 同 call 续跑或 `ToolError.denied`。
/// 无 broker 注入时 `.ask` 保持硬拒（现状，回归保护见 ToolHookTests）。
import Foundation

// MARK: - 策略（codex AskForApproval 两档）

/// Pre-tool 审批策略。对齐 codex `AskForApproval`（`protocol.rs:924`）+
/// 沙箱允许面（ocoreai 无沙箱权限边，故并入策略轴）：
/// - `.interactive` ≈ codex on-request：高危才问（默认）
/// - `.auto` ≈ codex 沙箱允许面（如 workspace-write）：不问、直接放行
/// - `.never` ≈ codex Never：不问、直接拒绝（理由回传模型供其换路）
/// codex `untrusted`/`granular` 依赖 subprocess 沙箱与细粒度规则面，ocoreai 无此执行面，不构造。
public enum ApprovalPolicy: String, Sendable, Equatable, CaseIterable, Codable {
    case interactive
    case auto
    case never
}

// MARK: - 决策（codex ReviewDecision 语义）

/// 用户对单个高危调用的裁决。对齐 codex `ReviewDecision`（`protocol.rs:3877`）：
/// `Approved` / `ApprovedForSession` / `Denied{rejection}`。
public enum ApprovalDecision: Sendable, Equatable {
    /// 本次放行
    case approved
    /// 本会话内同工具自动放行（codex ApprovedForSession，缓存语义见
    /// `sandboxing.rs` 注释与 `with_cached_approval`）
    case approvedForSession
    /// 拒绝；reason 原样进入 `ToolError.denied`，回传模型供其换路
    case denied(reason: String)
}

// MARK: - Pending 行（codex approvals.rs 呈现面 DTO）

/// 一条挂起中的审批请求（UI 展示 + resolve 用）。
public struct PendingApproval: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let arguments: String
    public let snippet: String
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        toolName: String,
        arguments: String,
        snippet: String,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.snippet = snippet
        self.reason = reason
        self.createdAt = createdAt
    }
}

// MARK: - broker（actor：跨 await 的挂起/唤醒）

/// 审批 broker：策略判定 + session 缓存 + pending 挂起。
///
/// `ApprovalCore.snippet` 为纯函数，可无 actor 直接测试。
public actor ApprovalBroker {
    public private(set) var policy: ApprovalPolicy
    private var pendingByID:
        [UUID: (
            row: PendingApproval,
            continuation: CheckedContinuation<
                ApprovalDecision, Never
            >
        )] = [:]
    private var sessionApproved: Set<String> = []

    /// UI 观察者（pending 发布 / resolved 清场）。@MainActor 隔离由 UI 侧保证。
    private var onPending: (@MainActor (PendingApproval) async -> Void)?
    private var onResolved: (@MainActor (PendingApproval, ApprovalDecision) async -> Void)?

    public init(policy: ApprovalPolicy = .interactive) {
        self.policy = policy
    }

    /// 运行时改策略（Settings 侧）。已在挂起的请求不受影响。
    public func setPolicy(_ new: ApprovalPolicy) {
        policy = new
    }

    public func setOnPending(_ observer: (@MainActor (PendingApproval) async -> Void)?) {
        onPending = observer
    }

    public func setOnResolved(
        _ observer: (@MainActor (PendingApproval, ApprovalDecision) async -> Void)?
    ) {
        onResolved = observer
    }

    /// 发起一次高危审批。
    ///
    /// - `.never`：立即 `.denied(reason: "auto-denied")`，不进 pending。
    /// - `.interactive` + session 缓存命中（同工具已 `approvedForSession`）：
    ///   立即 `.approved`，codex `with_cached_approval` 语义。
    /// - `.interactive` + 未命中：发布 pending 行并挂起，直到 `resolve`。
    public func request(
        toolName: String,
        arguments: String,
        reason: String
    ) async -> ApprovalDecision {
        switch policy {
        case .never:
            return .denied(reason: "auto-denied")
        case .auto:
            // codex 沙箱允许面：不问、放行
            return .approved
        case .interactive:
            // codex #41159：审查面是 `snippet`（80 grapheme）。无法在审查面完整
            // 呈现的 arguments 必须 fail-closed 拒绝——绝不"审截断版、执行全量
            // 载荷"（未审查的尾部字节到达终端）。先于 session 缓存：缓存的批准
            // 不覆盖从未被完整审查过的载荷。
            guard ApprovalCore.isReviewable(arguments) else {
                return .denied(reason: ApprovalCore.denialReason(toolName: toolName))
            }
            if sessionApproved.contains(toolName) {
                return .approved
            }
            let row = PendingApproval(
                toolName: toolName, arguments: arguments,
                snippet: ApprovalCore.snippet(arguments), reason: reason
            )
            // 1) 发布观察者（fire-and-forget，UI 侧 @MainActor 调度）
            if let observer = onPending {
                Task { await observer(row) }
            }
            // 2) 登记并挂起，直到 resolve
            return await withCheckedContinuation {
                (cont: CheckedContinuation<ApprovalDecision, Never>) in
                pendingByID[row.id] = (row, cont)
            }
        }
    }

    /// 挂起行 → UI。返回当前全部 pending（按发布时间序）。
    public func snapshot() -> [PendingApproval] {
        pendingByID.values.map(\.row).sorted { $0.createdAt < $1.createdAt }
    }

    /// UI 裁决。`id` 不存在（已裁决 / 过期）→ `false`。
    @discardableResult
    public func resolve(id: UUID, decision: ApprovalDecision) -> Bool {
        guard let entry = pendingByID.removeValue(forKey: id) else {
            return false
        }
        if decision == .approvedForSession {
            sessionApproved.insert(entry.row.toolName)
        }
        Task { [onResolved] in
            await onResolved?(entry.row, decision)
        }
        entry.1.resume(returning: decision)
        return true
    }

    /// 清场（App 关闭 / 会话重置）。所有挂起 call 收到 `.denied(reason: "session-ended")`。
    public func cancelAll() async {
        let rows = Array(pendingByID.keys)
        for id in rows {
            _ = self.resolve(id: id, decision: .denied(reason: "session-ended"))
        }
    }
}

// MARK: - 纯函数层（无 actor，测试直连）

enum ApprovalCore {
    /// 审查面呈现预算（grapheme）——`snippet` 的单一真源。
    /// codex #41159 把「可审查性」绑定到审查面本身；ocoreai 的审查面 = 审批卡的
    /// snippet 呈现（`ChatView` 审批卡），故预算钉在此处，门与呈现不得各自硬编码。
    static let reviewSurfaceGraphemes = 80

    /// codex `truncate_text`（`tui/src/text_formatting.rs:89`）逐字语义：
    /// ≤ max graphemes → 原文；> max → 前 max-3 graphemes + "..."（总长 ≤ max）。
    /// max < 3 → 前 max graphemes，无省略号（codex 同一分支）。
    static func snippet(_ text: String, maxGraphemes: Int = reviewSurfaceGraphemes) -> String {
        let graphemes = Array(text)
        guard graphemes.count > maxGraphemes else {
            return text
        }
        if maxGraphemes >= 3 {
            return String(graphemes.prefix(maxGraphemes - 3)) + "..."
        }
        return String(graphemes.prefix(maxGraphemes))
    }

    /// codex #41159 "Reject oversized reviewed terminal input" 对齐（语义，非逐行）：
    /// 审查面无法**完整呈现**的动作必须 fail-closed 拒绝——绝不"审截断版、执行全量
    /// 载荷"（未审查的尾部字节不得到达终端）。
    static func isReviewable(_ text: String) -> Bool { snippet(text) == text }

    /// #41159 拒绝文案（单一真源，测试断言锚点）。
    static func denialReason(toolName: String) -> String {
        "\(toolName) arguments cannot be shown in full on the approval review surface"
            + " (\(reviewSurfaceGraphemes) grapheme max); split into smaller inputs"
    }
}
