// ExternalMCPApprovalGateTests.swift — codex #41094 parity: the external-MCP
// tool path must pass the same security preflight (PreToolUse hooks +
// approval broker) as local tools before any `forwardToolCall` runs.
//
// Coverage (exact values, per test-quality bar):
//   1. deny hook (matcher=nil → applies to every tool) → ToolError.denied
//      with the hook's EXACT reason, thrown from `securityGate`.
//   2. ask hook + no broker → ToolError.denied (regression contract: never
//      silently forwards to an external server).
//   3. allow (no hooks) → `securityGate` completes without error.
//   4. hook matching only ANOTHER tool → gate passes for the MCP tool
//      (matcher is still honored on the shared path).

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

    @Test("no hooks → gate passes (allow path)")
    func allowPath() async throws {
        let bridge = makeBridge(hooks: [], broker: nil)
        try await bridge.securityGate(forExternalTool: "remote_search", arguments: "{}")
    }

    @Test("hook matching another tool → does not fire on this tool")
    func matcherSkips() async {
        let bridge = makeBridge(
            hooks: [
                Hook.pre(matcher: ToolMatcher("unrelated_tool")) { _ in
                    .deny(reason: "should not fire")
                }
            ],
            broker: nil,
        )
        do {
            _ = try await bridge.securityGate(forExternalTool: "remote_write_file", arguments: "{}")
        } catch {
            #expect(false, "gate should pass, but threw: \(error)")
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
