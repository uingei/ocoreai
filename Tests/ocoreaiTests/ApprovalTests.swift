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

    @Test("approvedForSession caches per tool; other tools still ask")
    func session() async {
        let b = ApprovalBroker(policy: .interactive)
        let t1 = Task {
            await b.request(toolName: "write_file", arguments: "{}", reason: "r")
        }
        guard let row = await waitForRow(b) else {
            #expect(false, "approval row never published")
            return
        }
        #expect(await b.resolve(id: row.id, decision: .approvedForSession) == true)
        #expect(await t1.value == .approvedForSession)

        // 同工具：缓存命中，无 pending
        #expect(await b.request(toolName: "write_file", arguments: "{}", reason: "r") == .approved)
        #expect(await b.snapshot().count == 0)

        // 异工具：仍挂起（缓存按工具粒度）
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
