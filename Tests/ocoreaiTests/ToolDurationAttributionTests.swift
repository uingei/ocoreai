// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ToolDurationAttributionTests.swift — the tool card's duration is the tool's window.
//!
//! Read 11-22 (the open row's shape, confirmed at the sites): the dispatch clock opened before
//! `securityPrecheck`, and the precheck awaits the human at the approval broker — so a slow
//! approval answer rendered as a slow tool, a number the transcript chip names for the tool.
//! Codex #57207 attributes the approval wait apart. The registry now reports the post-decision
//! instant from the one place the decision is awaited, and the durations a user can read size
//! from it; this suite gates that report contract — when it fires, and that both lanes use it.

import Foundation
import Testing

@testable import ocoreai

private final class InstantBox: @unchecked Sendable {
    var started: ContinuousClock.Instant?
}

private func waitForRow(_ b: ApprovalBroker) async -> PendingApproval? {
    for _ in 0 ..< 400 {
        let rows = await b.snapshot()
        if let first = rows.first { return first }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return nil
}

private func durationRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    return root
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

private func destructiveRegistry() async throws -> (ToolRegistry, ApprovalBroker) {
    let broker = ApprovalBroker(policy: .interactive)
    let registry = ToolRegistry(approvalBroker: broker)
    try await registry.register(
        ToolEntry(
            name: "synthetic_write", toolset: "test", schema: ToolSchema(),
            handler: { _ in "ran" }, isDestructive: true))
    return (registry, broker)
}

@Suite("Tool duration is the execution window, not the human's answer time")
struct ToolDurationAttributionTests {

    @Test("the reported execution start lands after the decision, not at the ask")
    static func executionStartFollowsTheDecision() async throws {
        let (registry, broker) = try await destructiveRegistry()
        let box = InstantBox()
        let callStart = ContinuousClock.now
        let caller = Task {
            try await registry.call(
                "synthetic_write", arguments: "{}",
                onExecutionStart: { box.started = $0 })
        }
        guard let row = await waitForRow(broker) else {
            caller.cancel()
            throw InvocationFailure.noApprovalRow
        }
        // The human takes 150 ms; the window must open after the answer. The assertion below is
        // an Instant ordering, not a bound — this sleep only makes ask and decision separable.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await broker.resolve(id: row.id, decision: .approved) == true)
        let decision = ContinuousClock.now
        #expect(try await caller.value == "ran")

        let started = try #require(box.started, "call never reported the execution window")
        let wholeWindow = callStart.duration(to: started).components.seconds
        #expect(
            decision <= started,
            "window opened before the answer; the card would bill \(wholeWindow)s of thinking to the tool"
        )
        #expect(
            callStart < started,
            "the reported instant is the dispatch window itself, not a post-approval one")
    }

    @Test("a denied call reports no execution window — nothing executed")
    static func denialReportsNoWindow() async throws {
        let (registry, broker) = try await destructiveRegistry()
        let box = InstantBox()
        let caller = Task {
            try await registry.call(
                "synthetic_write", arguments: "{}",
                onExecutionStart: { box.started = $0 })
        }
        guard let row = await waitForRow(broker) else {
            caller.cancel()
            throw InvocationFailure.noApprovalRow
        }
        #expect(
            await broker.resolve(id: row.id, decision: .denied(reason: "user said no")) == true)
        do {
            _ = try await caller.value
            #expect(Bool(false), "expected ToolError.denied after the user declined")
        } catch is ToolError {}
        #expect(
            box.started == nil,
            "a call that never executed reported an execution-window start")
    }

    /// The lanes' subtraction is a pass-through of the reported instant; without this floor a
    /// dropped reader would re-bill the human silently, because the registry-side contract
    /// above would still hold. The one home for this scan — a second count in a second suite
    /// is what made two gates disagree on 11-22.
    @Test("both dispatch lanes open their card duration from the reported instant")
    static func lanesReadTheReportedInstant() throws {
        let url = durationRoot().appendingPathComponent(
            "Sources/ocoreai/Engine/EngineInference.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(
            src.count > 100_000, "\(url.path) read looks truncated — the scan cannot be trusted")
        // "xecStart" matches both spellings (`execStart`, `mtpExecStart`) and nothing else.
        let reads = occurrences(of: "xecStart.instant ?? ", in: src)
        #expect(
            reads == 2,
            "std and MTP lanes must each read the reported instant, got \(reads)")
        // Floors the needle's own premise: the boxes exist, so the count above matched readers.
        #expect(
            occurrences(of: "ExecStartBox()", in: src) == 2,
            "the lanes stop holding execution-start boxes — this scan matched nothing")
    }

    enum InvocationFailure: Error { case noApprovalRow }
}
