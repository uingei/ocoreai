// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `get_context_remaining` 工具 — 精确值测试(全离线, store 注入, 不触 ChatHandler/EnginePool).
///
/// 基准: codex `core/src/tools/handlers/get_context_remaining.rs` +
/// `session/context_window.rs`(tokens_remaining) +
/// `context/token_budget_context.rs:170-172`(render 逐字, 0.150.1 HEAD).
///
/// 覆盖:
///   ContextRemaining.tokensRemaining — nil→nil / used<limit / used==limit / used>limit(clamp 0)
///   ContextRemaining.report         — codex render 字符串逐字断言(known + unknown)
///   GetContextRemainingClient.runForTool — store 注入(known/unknown/未设置)离线精确值
///   GetContextRemainingClient.toolEntry  — 名称/命名空间注册面

import Foundation
import Testing

@testable import ocoreai

// MARK: - 纯计算: tokensRemaining(codex `tokens_remaining` 逐字)

@Suite("context_remaining compute")
struct ContextRemainingComputeTests {

    @Test
    func usedBelowLimitIsExact() {
        // codex: limit.map(|l| l.saturating_sub(used).max(0)) — 直接算术域.
        #expect(ContextRemaining.tokensRemaining(limit: 8192, used: 4096) == 4096)
    }

    @Test
    func usedEqualsLimitClampsToZero() {
        #expect(ContextRemaining.tokensRemaining(limit: 4096, used: 4096) == 0)
    }

    @Test
    func usedExceedsLimitClampsToZero() {
        // used 超窗(prompt 已超 cap 的 400 前窗口, 或压缩失败残留)→ 0, 不产生负数.
        #expect(ContextRemaining.tokensRemaining(limit: 4096, used: 8192) == 0)
    }

    @Test
    func nilLimitIsNilBudget() {
        // codex: limit = None(模型未配窗口)→ tokens_left = None → unknown 路径.
        #expect(ContextRemaining.tokensRemaining(limit: nil, used: 0) == nil)
        #expect(ContextRemaining.tokensRemaining(limit: nil, used: 10_000) == nil)
    }

    @Test
    func firstAndLastTokensExact() {
        #expect(ContextRemaining.tokensRemaining(limit: 16_384, used: 0) == 16_384)
        #expect(ContextRemaining.tokensRemaining(limit: 16_384, used: 16_383) == 1)
    }
}

// MARK: - 报告: codex render 逐字(token_budget_context.rs:170-172)

@Suite("context_remaining report format")
struct ContextRemainingReportTests {

    @Test
    func knownBudgetRenderIsExact() {
        #expect(
            ContextRemaining.report(4096)
                == "You have 4096 tokens left in this context window.")
    }

    @Test
    func zeroBudgetRenderIsExact() {
        #expect(
            ContextRemaining.report(0)
                == "You have 0 tokens left in this context window.")
    }

    @Test
    func unknownBudgetRenderIsExact() {
        #expect(
            ContextRemaining.report(nil)
                == "You have unknown tokens left in this context window.")
    }
}

// MARK: - client 面: store 注入(离线, 不触生产 store)

@Suite("get_context_remaining client")
struct GetContextRemainingClientTests {

    /// 每用例独立 store 实例 — 不碰 `ContextStatusStore.shared`(避免并发测试间串值).
    private func seeded(used: Int, limit: Int?) async -> ContextStatusStore {
        let store = ContextStatusStore()
        await store.set(usedTokens: used, windowLimit: limit)
        return store
    }

    @Test
    func knownContextReportsExactRemaining() async {
        let store = await seeded(used: 4096, limit: 8192)
        let out = await GetContextRemainingClient.runForTool(store: store)
        #expect(
            out
                == "You have 4096 tokens left in this context window.")
    }

    @Test
    func exceededUsageReportsZeroNotNegative() async {
        let store = await seeded(used: 8192, limit: 4096)
        let out = await GetContextRemainingClient.runForTool(store: store)
        #expect(
            out
                == "You have 0 tokens left in this context window.")
    }

    @Test
    func nilLimitReportsUnknownVerbatim() async {
        let store = await seeded(used: 128, limit: nil)
        let out = await GetContextRemainingClient.runForTool(store: store)
        #expect(
            out
                == "You have unknown tokens left in this context window.")
    }

    @Test
    func noContextRecordedReportsUnknown() async {
        // turn 入口未写入(新进程首调用/非 session 路径)→ 诚实 unknown, 非编造 0.
        let store = ContextStatusStore()
        let out = await GetContextRemainingClient.runForTool(store: store)
        #expect(
            out
                == "You have unknown tokens left in this context window.")
    }

    @Test
    func toolEntryRegistersContextNamespace() {
        let e = GetContextRemainingClient.toolEntry()
        #expect(e.name == "get_context_remaining")
        #expect(e.toolset == "context")
    }
}
