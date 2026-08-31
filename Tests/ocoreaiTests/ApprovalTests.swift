// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ApprovalTests.swift — 审批参照形状（codex 基准，语义对齐非逐行抄）。
///
/// 参照锚点：
/// - `protocol.rs:924 AskForApproval`（两档 `.interactive`/`.never`）
/// - `protocol.rs:3877 ReviewDecision`（`.approved`/`.approvedForSession`/`.denied`）
/// - `tui/text_formatting.rs:89 truncate_text`（snippet 截断逐字语义）
import Foundation
import Testing

@testable import ocoreai

// MARK: - snippet

@Suite("ApprovalCore.snippet — codex truncate_text parity")
struct ApprovalSnippetTests {
    @Test("short text unchanged")
    func short() {
        #expect(ApprovalCore.snippet("abc") == "abc")
        #expect(ApprovalCore.snippet("") == "")
    }

    @Test("exactly max (80) graphemes unchanged")
    func exactlyMax() {
        let t = String(repeating: "a", count: 80)
        #expect(ApprovalCore.snippet(t) == t)
    }

    @Test("81 graphemes → first 77 + '...'")
    func overMax() {
        #expect(
            ApprovalCore.snippet(String(repeating: "a", count: 81))
                == String(repeating: "a", count: 77) + "...")
    }

    @Test("200 graphemes → first 77 + '...'")
    func muchLonger() {
        #expect(
            ApprovalCore.snippet(String(repeating: "b", count: 200))
                == String(repeating: "b", count: 77) + "...")
    }

    @Test("grapheme-aware (emoji cluster = 1 grapheme)")
    func grapheme() {
        let out = Array(ApprovalCore.snippet(String(repeating: "\u{1F600}", count: 81)))
        #expect(out.count == 80)
        #expect(out.suffix(3) == Array("..."))
    }
}

// MARK: - broker 决策矩阵

@Suite("ApprovalBroker — decision matrix")
struct ApprovalBrokerTests {
    /// 轮询 pending 行（Task 并发启动存在窗口期，deadline 内必须出现）。
    private func waitForRow(_ b: ApprovalBroker) async -> PendingApproval? {
        for _ in 0 ..< 400 {
            if let row = await b.snapshot().first {
                return row
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }

    @Test("never policy → denied(auto-denied), no pending")
    func never() async {
        let b = ApprovalBroker(policy: .never)
        #expect(
            await b.request(toolName: "write_file", arguments: "{}", reason: "r")
                == .denied(reason: "auto-denied"))
        #expect(await b.snapshot().count == 0)
    }

    @Test("interactive → pending row with exact fields; approve → approved")
    func approve() async {
        let b = ApprovalBroker(policy: .interactive)
        let t = Task {
            await b.request(
                toolName: "write_file", arguments: "{\"path\":\"/tmp/x\"}", reason: "destructive")
        }
        guard let row = await waitForRow(b) else {
            #expect(false, "approval row never published")
            return
        }
        #expect(row.toolName == "write_file")
        #expect(row.snippet == "{\"path\":\"/tmp/x\"}")
        #expect(row.reason == "destructive")
        #expect(await b.resolve(id: row.id, decision: .approved) == true)
        #expect(await t.value == .approved)
        #expect(await b.snapshot().count == 0)
    }

    /// 会话放行按 **action 身份（工具+载荷）** 缓存（codex `UnifiedExecApprovalKey`）：
    /// 同工具同载荷 → 命中；同工具异载荷 / 异工具 → 必须再问（fail-safe 方向）。
    @Test(
        "approvedForSession caches per action (tool+arguments); same tool different payload still asks"
    )
    func session() async {
        let b = ApprovalBroker(policy: .interactive)
        let t1 = Task {
            await b.request(toolName: "write_file", arguments: "{\"path\":\"/tmp/x\"}", reason: "r")
        }
        guard let row = await waitForRow(b) else {
            #expect(false, "approval row never published")
            return
        }
        #expect(await b.resolve(id: row.id, decision: .approvedForSession) == true)
        #expect(await t1.value == .approvedForSession)

        // 同 action（工具+载荷逐字节同源）：缓存命中，无 pending
        #expect(
            await b.request(toolName: "write_file", arguments: "{\"path\":\"/tmp/x\"}", reason: "r")
                == .approved)
        #expect(await b.snapshot().count == 0)

        // 同工具异载荷：缓存键含载荷 → 不得命中，必须再问（对齐 codex：
        // 放行「这条命令」≠ 放行「该工具所有命令」）
        let t2a = Task {
            await b.request(
                toolName: "write_file", arguments: "{\"path\":\"/etc/passwd\"}", reason: "r")
        }
        guard let row2a = await waitForRow(b) else {
            #expect(false, "different-payload row never published")
            return
        }
        #expect(await b.resolve(id: row2a.id, decision: .approved) == true)
        #expect(await t2a.value == .approved)

        // 异工具：仍挂起
        let t2 = Task {
            await b.request(toolName: "delete_file", arguments: "{}", reason: "r")
        }
        guard let row2 = await waitForRow(b) else {
            #expect(false, "second approval row never published")
            return
        }
        #expect(row2.toolName == "delete_file")
        #expect(await b.resolve(id: row2.id, decision: .approved) == true)
        #expect(await t2.value == .approved)
    }

    @Test("deny → exact reason propagates, no cache, next call still asks")
    func deny() async {
        let b = ApprovalBroker(policy: .interactive)
        let t1 = Task {
            await b.request(toolName: "write_file", arguments: "{}", reason: "r")
        }
        guard let row = await waitForRow(b) else {
            #expect(false, "approval row never published")
            return
        }
        #expect(await b.resolve(id: row.id, decision: .denied(reason: "user said no")) == true)
        #expect(await t1.value == .denied(reason: "user said no"))

        let t2 = Task {
            await b.request(toolName: "write_file", arguments: "{}", reason: "r")
        }
        guard let row2 = await waitForRow(b) else {
            #expect(false, "retry approval row never published")
            return
        }
        #expect(row2.id != row.id)
        #expect(await b.resolve(id: row2.id, decision: .approved) == true)
        #expect(await t2.value == .approved)
    }

    @Test("resolve unknown id → false")
    func unknown() async {
        let b = ApprovalBroker(policy: .interactive)
        #expect(await b.resolve(id: UUID(), decision: .approved) == false)
        #expect(await b.snapshot().count == 0)
    }
}

// MARK: - registry 集成（生产 chokepoint）

@Suite("ToolRegistry .ask — broker routing")
struct ApprovalRegistryTests {
    private func makeRegistry(broker: ApprovalBroker?) -> ToolRegistry {
        ToolRegistry(
            hooks: [
                Hook.pre(matcher: ToolMatcher("write_file,delete_file,execute_code")) { _ in
                    .ask(reason: "confirm destructive op")
                }
            ],
            approvalBroker: broker
        )
    }

    private func entry(_ name: String) -> ToolEntry {
        ToolEntry(
            name: name,
            toolset: "files",
            schema: ToolSchema(),
            handler: { _ in "RAN:" + name },
            isDestructive: true
        )
    }

    @Test("no broker → .ask stays a hard deny (regression contract)")
    func noBroker() async {
        let r = makeRegistry(broker: nil)
        try? await r.register(entry("write_file"))
        do {
            _ = try await r.call("write_file", arguments: "{}")
            #expect(false, "expected ToolError.denied")
        } catch let e as ToolError {
            guard case .denied(let reason) = e else {
                #expect(false, "wrong error case: \(e)")
                return
            }
            #expect(reason == "confirm destructive op")
        } catch {
            #expect(false, "unexpected error")
        }
    }

    @Test("broker .never → denied(auto-denied)")
    func never() async {
        let b = ApprovalBroker(policy: .never)
        let r = makeRegistry(broker: b)
        try? await r.register(entry("write_file"))
        do {
            _ = try await r.call("write_file", arguments: "{}")
            #expect(false, "expected ToolError.denied")
        } catch let e as ToolError {
            guard case .denied(let reason) = e else {
                #expect(false, "wrong error case: \(e)")
                return
            }
            #expect(reason == "auto-denied")
        } catch {
            #expect(false, "unexpected error")
        }
        #expect(await b.snapshot().count == 0)
    }

    @Test("broker approve → handler runs, exact result")
    func approveRuns() async throws {
        let b = ApprovalBroker(policy: .interactive)
        let r = makeRegistry(broker: b)
        try await r.register(entry("write_file"))
        let t = Task { try await r.call("write_file", arguments: "{}") }
        for _ in 0 ..< 400 {
            if let row = await b.snapshot().first {
                #expect(await b.resolve(id: row.id, decision: .approved) == true)
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(try await t.value == "RAN:write_file")
    }

    @Test("broker deny → rejected, user reason verbatim")
    func denyRejects() async {
        let b = ApprovalBroker(policy: .interactive)
        let r = makeRegistry(broker: b)
        try? await r.register(entry("write_file"))
        let t = Task { try await r.call("write_file", arguments: "{}") }
        for _ in 0 ..< 400 {
            if let row = await b.snapshot().first {
                #expect(await b.resolve(id: row.id, decision: .denied(reason: "not now")) == true)
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        do {
            _ = try await t.value
            #expect(false, "expected ToolError.denied")
        } catch let e as ToolError {
            guard case .denied(let reason) = e else {
                #expect(false, "wrong error case: \(e)")
                return
            }
            #expect(reason == "not now")
        } catch {
            #expect(false, "unexpected error")
        }
    }

    @Test("session approval → second same-tool call runs without pending")
    func sessionSecond() async throws {
        let b = ApprovalBroker(policy: .interactive)
        let r = makeRegistry(broker: b)
        try await r.register(entry("write_file"))
        let t1 = Task { try await r.call("write_file", arguments: "{}") }
        for _ in 0 ..< 400 {
            if let row = await b.snapshot().first {
                #expect(await b.resolve(id: row.id, decision: .approvedForSession) == true)
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(try await t1.value == "RAN:write_file")
        #expect(try await r.call("write_file", arguments: "{}") == "RAN:write_file")
        #expect(await b.snapshot().count == 0)
    }

    @Test("non-matching tool → allow path, broker untouched")
    func allowPath() async throws {
        let b = ApprovalBroker(policy: .interactive)
        let r = makeRegistry(broker: b)
        let read = ToolEntry(
            name: "read_file",
            toolset: "files",
            schema: ToolSchema(),
            handler: { _ in "read-ok" },
            isDestructive: false
        )
        try await r.register(read)
        #expect(try await r.call("read_file", arguments: "{}") == "read-ok")
        #expect(await b.snapshot().count == 0)
    }
}

// MARK: - codex #41159 review-surface gate（审截断+送全量 stdin 缺口 fail-closed）

@Suite("#41159 — review-surface completeness gate")
struct ReviewSurfaceGateTests {

    @Test("isReviewable: 80 graphemes yes, 81 no (boundary, exact)")
    func boundary() {
        #expect(ApprovalCore.isReviewable("{}"))
        let atMax = String(repeating: "a", count: ApprovalCore.reviewSurfaceGraphemes)
        #expect(ApprovalCore.isReviewable(atMax))
        #expect(!ApprovalCore.isReviewable(atMax + "b"))
    }

    @Test("denialReason single source: exact text")
    func reasonText() {
        #expect(
            ApprovalCore.denialReason(toolName: "write_stdin")
                == "write_stdin arguments cannot be shown in full on the approval review surface"
                + " (80 grapheme max); split into smaller inputs")
    }

    @Test("oversized → denied BEFORE approval request: exact reason + zero pending")
    func oversizedDeniedNoPending() async {
        let b = ApprovalBroker(policy: .interactive)
        let oversized = String(repeating: "x", count: ApprovalCore.reviewSurfaceGraphemes + 1)
        #expect(
            await b.request(toolName: "write_stdin", arguments: oversized, reason: "stdin")
                == .denied(reason: ApprovalCore.denialReason(toolName: "write_stdin")))
        #expect(await b.snapshot().count == 0)
    }

    @Test("exactly reviewable (80) → still routes to pending, not blocked")
    func atMaxStillAsks() async {
        let b = ApprovalBroker(policy: .interactive)
        let args = String(repeating: "a", count: ApprovalCore.reviewSurfaceGraphemes)
        let t = Task {
            await b.request(toolName: "write_stdin", arguments: args, reason: "stdin")
        }
        for _ in 0 ..< 400 {
            if let row = await b.snapshot().first {
                // 80 必须**能**过门到 pending——断言后裁决清场（不泄漏挂起 continuation）
                #expect(await b.resolve(id: row.id, decision: .denied(reason: "t")) == true)
                _ = await t.value
                #expect(await b.snapshot().count == 0)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(false, "reviewable (80) arguments must reach pending")
    }

    @Test("session approval does NOT cover an unreviewed larger payload")
    func cacheDoesNotCoverUnreviewed() async {
        let b = ApprovalBroker(policy: .interactive)
        // 合法小载荷 → approvedForSession（缓存工具）
        let t1 = Task {
            await b.request(toolName: "write_stdin", arguments: "{}", reason: "stdin")
        }
        // 本 struct 作用域内联轮询（waitForRow 属另一个 struct，private 不可见）
        guard let row = await snapshotRow(b) else {
            #expect(false, "row never published")
            return
        }
        #expect(await b.resolve(id: row.id, decision: .approvedForSession) == true)
        #expect(await t1.value == .approvedForSession)

        // 同一工具的更大载荷：缓存批准不得覆盖「未被完整审查的尾部字节」
        let oversized = String(repeating: "p", count: ApprovalCore.reviewSurfaceGraphemes + 2)
        #expect(
            await b.request(toolName: "write_stdin", arguments: oversized, reason: "stdin")
                == .denied(reason: ApprovalCore.denialReason(toolName: "write_stdin")))
        #expect(await b.snapshot().count == 0)
    }

    private func snapshotRow(_ b: ApprovalBroker) async -> PendingApproval? {
        for _ in 0 ..< 400 {
            let rows = await b.snapshot()
            if let row = rows.first { return row }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }
}
