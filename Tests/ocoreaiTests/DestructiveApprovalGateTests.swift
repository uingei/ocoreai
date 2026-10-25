// One home for "is this call dangerous": what the tool declared at registration.
//
// Before this, the approval surface was a hand-copied name list in `App.swift` while the
// truth lived in `ToolEntry.isDestructive` (17 declarations against a 7-name matcher), so
// `edit_lines`, `write_clipboard`, `open_url`, the app-lifecycle pair and all six
// desktop-control tools ran unasked under the default `.interactive` policy — with
// `write_file` next to them asking. These tests gate the derivation itself: no hook names
// any of these tools, so a matcher list is no longer part of what they assert.
import Testing

@testable import ocoreai

private func waitForRow(_ b: ApprovalBroker) async -> PendingApproval? {
    for _ in 0 ..< 400 {
        let rows = await b.snapshot()
        if let first = rows.first { return first }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return nil
}

/// The pinned headless coercion string (`ApprovalTests.headlessAskReason`, `ToolRegistry`).
private let headlessAskReason =
    "denied: interactive approval is not available on this (headless) channel"

private func destructiveEntry(_ name: String) -> ToolEntry {
    ToolEntry(
        name: name, toolset: "test", schema: ToolSchema(),
        handler: { _ in "ran" }, isDestructive: true)
}

private func inertEntry(_ name: String) -> ToolEntry {
    ToolEntry(
        name: name, toolset: "test", schema: ToolSchema(),
        handler: { _ in "ran" })
}

/// Every name `bootstrapBuiltInTools` declares with `isDestructive: true`. Written out as
/// the contract it is: a new mutating tool that forgets the flag, or a gate that starts
/// consulting a list instead of the declaration, lands here.
private let declaredDestructiveBuiltIns: Set<String> = [
    "activate_app", "click", "drag", "edit_file", "edit_lines", "exec_command", "exec_poll",
    "exec_shell", "key_press", "move_mouse", "open_app", "open_url", "scroll", "type_text",
    "write_clipboard", "write_file", "write_stdin",
]

@Suite("Destructive approval comes from the declaration, not a name list")
struct DestructiveApprovalGateTests {

    @Test("a declared-destructive tool parks the user with no hook naming it")
    func declarationAsksWithoutAnyHook() async throws {
        let broker = ApprovalBroker(policy: .interactive)
        let registry = ToolRegistry(approvalBroker: broker)  // hooks: [] — nothing names it
        try await registry.register(destructiveEntry("synthetic_write"))

        let caller = Task {
            try await registry.securityPrecheck(toolName: "synthetic_write", arguments: "{}")
        }
        guard let row = await waitForRow(broker) else {
            #expect(Bool(false), "a destructive call published no approval row")
            caller.cancel()
            return
        }
        #expect(row.toolName == "synthetic_write")
        #expect(row.reason == "destructive tool call")
        #expect(await broker.resolve(id: row.id, decision: .denied(reason: "user said no")) == true)
        do {
            try await caller.value
            #expect(Bool(false), "expected ToolError.denied after the user declined")
        } catch let ToolError.denied(reason) {
            #expect(reason == "user said no", "got: \(reason)")
        }
    }

    @Test("headless + interactive denies a declared-destructive call fail-closed")
    func headlessDeniesDeclaredDestructive() async throws {
        let broker = ApprovalBroker(policy: .interactive)
        let registry = ToolRegistry(approvalBroker: broker)
        try await registry.register(destructiveEntry("synthetic_write"))
        do {
            try await registry.securityPrecheck(
                toolName: "synthetic_write", arguments: "{}", headless: true)
            #expect(Bool(false), "expected fail-closed denial on a headless destructive call")
        } catch let ToolError.denied(reason) {
            #expect(reason == headlessAskReason, "got: \(reason)")
        }
        #expect(await broker.snapshot().isEmpty, "headless must not park an unanswerable ask")
    }

    @Test("`edit_lines` — the tool the 7-name matcher left open — is gated")
    func editLinesIsGated() async throws {
        let broker = ApprovalBroker(policy: .interactive)
        let registry = ToolRegistry(approvalBroker: broker)
        await bootstrapBuiltInTools(registry: registry)
        do {
            try await registry.securityPrecheck(
                toolName: "edit_lines", arguments: "{\"path\":\"x\"}", headless: true)
            #expect(Bool(false), "edit_lines ran without approval")
        } catch let ToolError.denied(reason) {
            #expect(reason == headlessAskReason, "got: \(reason)")
        }
    }

    @Test("auto policy and non-destructive declarations still run ungated")
    func ungatedPathsStayOpen() async throws {
        let auto = ApprovalBroker(policy: .auto)
        let registry = ToolRegistry(approvalBroker: auto)
        try await registry.register(destructiveEntry("synthetic_write"))
        try await registry.register(inertEntry("synthetic_read"))
        try await registry.securityPrecheck(
            toolName: "synthetic_write", arguments: "{}", headless: true)
        try await registry.securityPrecheck(toolName: "synthetic_read", arguments: "{}")
        #expect(await auto.snapshot().isEmpty, "auto/readonly must not park a row")
    }

    @Test("the enforced set equals the built-ins' declarations, exactly")
    func enforcedSetEqualsDeclarations() async throws {
        let registry = ToolRegistry(approvalBroker: ApprovalBroker(policy: .interactive))
        await bootstrapBuiltInTools(registry: registry)
        let registered = Set(await registry.listTools())
        // `edit_lines` registers without a permission probe, so the scan has a floor that
        // cannot go vacuous if a permission-gated tool is skipped on some host.
        #expect(registered.contains("edit_lines"), "built-in bootstrap registered nothing")
        var enforced: Set<String> = []
        for name in registered where await registry.isDestructive(name) {
            enforced.insert(name)
        }
        let expected = declaredDestructiveBuiltIns.intersection(registered)
        let onlyGated = enforced.subtracting(expected)
        let undeclared = expected.subtracting(enforced)
        #expect(onlyGated.isEmpty, "gated but undeclared: \(onlyGated.sorted())")
        #expect(undeclared.isEmpty, "declared but ungated: \(undeclared.sorted())")
        #expect(enforced.count >= 17, "scan floor: only \(enforced.count) names gated")
    }
}
