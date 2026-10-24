// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoopGuardRemedyTests — the identical-call cap has to hand the model a next step.
///
/// Measured on the eval scoreboard: one 21-task run produced 68 identical refusals reading the
/// same file, one per repeat, and the turn ended with the task unmade. The cap is right (a model
/// hammering the same call is stuck); the message was the dead end — the same shape `edit_file`'s
/// `found 0` had before it started quoting the file back.
///
/// `.serialized` because `SessionWorkspace` is a process-global (see `EditMismatchRecoveryTests`).
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("loop guard — a refusal that says what to do, and never echoes a body", .serialized)
struct LoopGuardRemedyTests {

    private func seeded(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_loopguard_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionWorkspace.setDirectory(dir.path)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func freshRegistry() async -> ToolRegistry {
        let registry = ToolRegistry(log: Logger(label: "test.loopguard"))
        await bootstrapBuiltInTools(registry: registry)
        return registry
    }

    @Test("the 4th identical read names the file, the count, and the next step")
    func refusalNamesTheCallAndARemedy() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("sum100.py", "def total(n):\n    return n * (n + 1) // 2\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"sum100.py"}"#
        for _ in 1 ... 3 {
            _ = try await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "loop.read")
        }
        do {
            _ = try await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "loop.read")
            Issue.record("a 4th identical read_file must be refused")
        } catch let ToolError.loopDetected(detail) {
            #expect(detail.contains("path=sum100.py"), "it must name what was repeated: \(detail)")
            #expect(detail.contains("4 times in 60 s"), "and how many: \(detail)")
            #expect(
                detail.contains("edit_lines") && detail.contains("answer the user"),
                "and the move that is not another read: \(detail)")
        }
    }

    @Test("the refusal echoes addressing keys only — a body never rides the wire twice")
    func bodyNeverLeaksIntoTheRefusal() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("x.py", "print(1)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"x.py","content":"SECRET_BODY_do_not_echo"}"#
        for _ in 1 ... 3 {
            _ = try await registry.call(
                "write_file", arguments: args, caller: "test", headless: true,
                conversationKey: "loop.write")
        }
        do {
            _ = try await registry.call(
                "write_file", arguments: args, caller: "test", headless: true,
                conversationKey: "loop.write")
            Issue.record("a 4th identical write_file must be refused")
        } catch let ToolError.loopDetected(detail) {
            #expect(
                !detail.contains("SECRET_BODY"),
                "the refusal is a wire surface: content must not be quoted back: \(detail)")
            #expect(detail.contains("path=x.py"), "the addressing key is enough: \(detail)")
        }
    }

    @Test("varying the arguments clears the cycle — the guard reads identity, not the tool name")
    func differentArgumentsPass() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        // One directory for both files: `seeded` moves the session workspace each call, so a
        // second call would strand the first file outside the anchor.
        let dir = try seeded("a.md", "one\n").deletingLastPathComponent()
        try "two\n".write(
            to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        for _ in 1 ... 3 {
            _ = try await registry.call(
                "read_file", arguments: #"{"path":"a.md"}"#, caller: "test", headless: true,
                conversationKey: "loop.vary")
        }
        let other = try await registry.call(
            "read_file", arguments: #"{"path":"b.md"}"#, caller: "test", headless: true,
            conversationKey: "loop.vary")
        #expect(other.contains("two"), "a different file is not a loop: \(other)")
    }
}
