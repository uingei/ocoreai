// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// context namespace — codex `get_context_remaining`(0.150.1 HEAD, 逐行对齐):
///
///   get_context_remaining   无参, 报告当前上下文窗口剩余 token(codex `tokens_left` 原值)
///
/// 基准(逐字):
///   * `core/src/tools/handlers/get_context_remaining.rs` — handler 取 `base_window_tokens_remaining`。
///   * `core/src/session/context_window.rs` —
///     `tokens_remaining(limit, used) = limit.map(|l| l.saturating_sub(used).max(0))`;
///   * `core/src/context/token_budget_context.rs:170-172` — render 逐字:
///     `You have {n} tokens left in this context window.` /
///     `You have unknown tokens left in this context window.`
///
/// 定位: codex 读 `invocation.session`(per-invocation 当前会话)。ocoreai 工具为全局,
/// 无 `invocation.session` → provider seam 在调用时读「最近活跃会话」的累计用量
/// + 该会话模型的窗口(ocoreai 对 codex `current session` 的最近真值近似)。
/// 无活跃会话 / 无窗口配置 → 走 codex `unknown` 路径(诚实报告, 非伪造值)。
import Foundation

// MARK: - 纯计算(codex 逐字)

enum ContextRemaining {
    /// codex `tokens_remaining(limit, used) = limit.map(|l| l.saturating_sub(used).max(0))`:
    /// limit = nil(无窗口配置)→ nil(unknown);否则 `max(0, limit - used)`(used 可超→clamp 0)。
    static func tokensRemaining(limit: Int?, used: Int) -> Int? {
        guard let limit else { return nil }
        return max(0, limit - used)
    }

    /// 报告(codex `token_budget_context.rs:170-172` 逐字):
    ///   Some(n) → `You have {n} tokens left in this context window.`
    ///   nil     → `You have unknown tokens left in this context window.`
    static func report(_ remaining: Int?) -> String {
        remaining.map { "You have \($0) tokens left in this context window." }
            ?? "You have unknown tokens left in this context window."
    }
}
// MARK: - Active-context provenance(seam 真值边)

/// codex `get_context_remaining` 读 `invocation.session`(当前会话)。
/// ocoreai 工具是全局, 无 per-invocation session 上下文 → 用「当前活跃上下文」
/// seam 承载真值: 由 turn 入口(known session/model/used/limit)写入, 工具读时取得。
/// 真源 = ChatHandler 每轮已算的 `promptTokenCount`(used)
///       + `getSamplingConfig(modelId:).maxContextWindow`(limit)。
struct ActiveContext: Sendable {
    let usedTokens: Int
    let windowLimit: Int?
}
// MARK: - store(seam 边界 + 线程安全)

/// 当前活跃上下文的可变持点 — turn 入口写入, 工具调用时读出。
/// actor 隔离保证跨 actor 访问安全(ocoreai 铁律: 跨 actor 必 await)。
actor ContextStatusStore {
    /// Canonical 唯一实例 — 工具闭包(全局) + ChatHandler(turn 入口) 都引这一份。
    /// 锚到模块全局避免实例穿越(若各自持一份 → 写到的与读到的不是同一对象,真值接不上)。
    nonisolated static let shared = ContextStatusStore()

    private var current: ActiveContext?

    /// turn 入口写入当前活跃上下文(used = 本轮 prompt 占满上下文, limit = 该模型窗口)。
    func set(usedTokens: Int, windowLimit: Int?) {
        self.current = ActiveContext(usedTokens: usedTokens, windowLimit: windowLimit)
    }

    /// 工具调用时读取;无任何活跃上下文时返回 nil(codex `unknown` 路径)。
    func peek() async -> ActiveContext? {
        self.current
    }
}

// MARK: - client(seam + args 绑定)

enum GetContextRemainingClient {

    static let toolName = "get_context_remaining"

    static func toolEntry(store: ContextStatusStore = .shared) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "context",
            argsType: Args.self,
            description:
                "Get the remaining tokens in the current context window. "
                + "Returns a token budget the model can spend before the window "
                + "fills; use to pace how much to produce or whether to "
                + "summarize/trim before continuing.",
            schema: ToolSchema(parameters: [:])
        ) { _ in
            await runForTool(store: store)
        }
    }

    struct Args: Codable, Sendable {}

    /// 离线可测路径: provider seam 已抽成 store, 调用方注入任意 ActiveContext。
    static func runForTool(store: ContextStatusStore) async -> String {
        guard let ctx = await store.peek() else {
            return ContextRemaining.report(nil)
        }
        let remaining = ContextRemaining.tokensRemaining(
            limit: ctx.windowLimit, used: ctx.usedTokens)
        return ContextRemaining.report(remaining)
    }
}
