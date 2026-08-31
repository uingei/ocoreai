// ExternalMCPApprovalGateTests.swift — codex #41094 parity: the external-MCP
// tool path must pass the same security preflight (PreToolUse hooks +
// approval broker) as local tools before any `forwardToolCall` runs.
//
// codex baseline (approvals.rs:505 precedence "1. Hooks 2. user";
// mcp_tool_call.rs:1497): MCP calls are FIRST-CLASS approval objects — a call
// no hook claims still routes through the policy/broker (OnRequest default →
// user decides; policy Never → denied). A broker-less `.ask` NEVER silently
// forwards; it hard-denies (regression protection).
//
// Coverage (exact values, per test-quality bar):
//   1. deny hook (matcher=nil → applies to every tool) → ToolError.denied
//      with the hook's EXACT reason, thrown from `securityGate`.
//   2. ask hook + no broker → ToolError.denied (hook's exact reason).
//   3. no hooks + no broker → ToolError.denied with the ungated EXACT reason
//      (regression contract: never silently forwards to an external server).
//   4. no hooks + interactive broker → row published with the ungated EXACT
//      reason; approve → gate passes; deny → exact reason propagates.
//      (codex `OnRequest` default for unclaimed MCP calls.)
//   5. hook matching only ANOTHER tool → ungated fallback applies (ask →
//      broker), NOT a silent pass.

import Logging
import Testing

@testable import ocoreai

@Suite("External MCP approval gate (codex #41094 parity)")
struct ExternalMCPApprovalGateTests {
    private func makeBridge(
        hooks: [Hook],
        broker: ApprovalBroker?,
    ) -> MCPBridge {
        let registry = ToolRegistry(hooks: hooks, approvalBroker: broker)
        return MCPBridge(
            toolRegistry: registry,
            transport: MCPStdioTransport(),
            endpoints: [],
            log: Logger(label: "test.mcp.gate"),
        )
    }

    /// Poll pending row (Task concurrency has a startup window; must appear
    /// within deadline) — same pattern as ApprovalTests.waitForRow.
    private func waitForRow(_ b: ApprovalBroker) async -> PendingApproval? {
        for _ in 0 ..< 400 {
            if let row = await b.snapshot().first {
                return row
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }

    private func expectDenied(_ error: Error, reason: String) {
        guard let toolError = error as? ToolError, case .denied(let actual) = toolError
        else {
            #expect(false, "expected ToolError.denied, got: \(error)")
            return
        }
        #expect(actual == reason)
    }

    @Test("deny hook → gate throws ToolError.denied with exact reason")
    func denyHook() async {
        let bridge = makeBridge(
            hooks: [Hook.any { _ in .deny(reason: "sensitive: external write") }],
            broker: nil,
        )
        do {
            try await bridge.securityGate(forExternalTool: "remote_write_file", arguments: "{}")
            #expect(false, "expected ToolError.denied")
        } catch {
            expectDenied(error, reason: "sensitive: external write")
        }
    }

    @Test("ask hook + no broker → hard deny (never silently forwards)")
    func askNoBroker() async {
        let bridge = makeBridge(
            hooks: [Hook.any { _ in .ask(reason: "confirm external action") }],
            broker: nil,
        )
        do {
            try await bridge.securityGate(forExternalTool: "remote_exec", arguments: "{}")
            #expect(false, "expected ToolError.denied")
        } catch {
            expectDenied(error, reason: "confirm external action")
        }
    }

    /// The ungated (no-hook) ask reason — must match the production constant
    /// in `ToolRegistry.securityPrecheckExternal` EXACTLY (precise-value bar).
    private let ungatedReason =
        "External MCP tool — operator approval required (no hook claims this call)"

    @Test("no hooks + no broker → hard deny with exact ungated reason (codex Never default)")
    func allowPath() async {
        let bridge = makeBridge(hooks: [], broker: nil)
        do {
            try await bridge.securityGate(forExternalTool: "remote_search", arguments: "…")
            #expect(false, "expected ToolError.denied (ungated, no broker)")
        } catch {
            expectDenied(error, reason: ungatedReason)
        }
    }

    @Test(
        "no hooks + interactive broker → row with exact ungated reason; approve → passes; deny → exact reason"
    )
    func noHookBrokerDecision() async {
        let broker = ApprovalBroker(policy: .interactive)
        let bridge = makeBridge(hooks: [], broker: broker)

        // Approve: gate completes. Row carries the ungated reason (not a hook's).
        let t1 = Task {
            try await bridge.securityGate(forExternalTool: "remote_read_file", arguments: "{}")
        }
        guard let row = await waitForRow(broker) else {
            #expect(false, "approval row never published")
            return
        }
        #expect(row.toolName == "remote_read_file")
        #expect(row.reason == ungatedReason)
        #expect(await broker.resolve(id: row.id, decision: .approved) == true)
        do {
            _ = try await t1.value
        } catch {
            #expect(false, "gate should complete after approval, but threw: \(error)")
        }

        // Deny on a second call: reason comes from the broker decision.
        let t2 = Task {
            try await bridge.securityGate(forExternalTool: "remote_write_file", arguments: "{}")
        }
        guard let row2 = await waitForRow(broker) else {
            #expect(false, "second approval row never published")
            return
        }
        #expect(row2.toolName == "remote_write_file")
        #expect(
            await broker.resolve(id: row2.id, decision: .denied(reason: "operator says no")) == true
        )
        do {
            _ = try await t2.value
            #expect(false, "expected ToolError.denied")
        } catch {
            expectDenied(error, reason: "operator says no")
        }
    }

    @Test("hook matching another tool → ungated ask fires (NOT a silent pass); broker decides")
    func matcherSkips() async {
        let broker = ApprovalBroker(policy: .interactive)
        let bridge = makeBridge(
            hooks: [
                Hook.pre(matcher: ToolMatcher("unrelated_tool")) { _ in
                    .deny(reason: "should not fire")
                }
            ],
            broker: broker,
        )
        // The matcher does NOT claim this tool → ungated fallback = .ask →
        // broker publishes a pending row (does not throw immediately, but does
        // NOT silently pass either). Poll for the row.
        let t = Task {
            try await bridge.securityGate(forExternalTool: "remote_write_file", arguments: "{}")
        }
        Task.detached {
            for _ in 0 ..< 200 {
                if let row = await broker.snapshot().first {
                    #expect(row.toolName == "remote_write_file")
                    #expect(row.reason == ungatedReason)
                    await broker.resolve(id: row.id, decision: .approved)
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        do {
            _ = try await t.value
            #expect(true)  // gate completed after approval — no silent pass, no deny
        } catch {
            #expect(false, "gate should complete after approval, but threw: \(error)")
        }
    }

    @Test("ask hook + interactive broker: approve → gate passes; deny → exact reason")
    func brokerDecision() async {
        let broker = ApprovalBroker(policy: .interactive)
        let bridge = makeBridge(
            hooks: [Hook.any { _ in .ask(reason: "confirm external action") }],
            broker: broker,
        )

        // Approve: gate completes. (Same shape as ApprovalTests.approve.)
        let t1 = Task {
            try await bridge.securityGate(forExternalTool: "remote_exec", arguments: "{}")
        }
        guard let row = await waitForRow(broker) else {
            #expect(false, "approval row never published")
            return
        }
        #expect(row.toolName == "remote_exec")
        #expect(row.reason == "confirm external action")
        #expect(await broker.resolve(id: row.id, decision: .approved) == true)
        do {
            _ = try await t1.value
        } catch {
            #expect(false, "gate should complete after approval, but threw: \(error)")
        }

        // Deny: gate throws with the broker decision reason.
        let t2 = Task {
            try await bridge.securityGate(forExternalTool: "remote_exec2", arguments: "{}")
        }
        guard let row2 = await waitForRow(broker) else {
            #expect(false, "second approval row never published")
            return
        }
        #expect(row2.toolName == "remote_exec2")
        #expect(await broker.resolve(id: row2.id, decision: .denied(reason: "not today")) == true)
        do {
            _ = try await t2.value
            #expect(false, "expected ToolError.denied")
        } catch {
            expectDenied(error, reason: "not today")
        }
    }
}
