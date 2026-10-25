// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoopStallTerminationTests — zero new information is counted, bounded, and honest.
///
/// Three defects, all measured in this repo's own transcripts (CHANGELOG `loop-stall`):
///   • a refusal reached no state at all (`recordExecution` counts only calls that reached
///     the handler), so one refusal could be renewed forever — 86 identical ones in a task;
///   • clearing the ladder on ANY successful call let a caller alternate two calls forever
///     without either ladder climbing;
///   • the wall keyed on arguments alone refused a re-read after the file had changed,
///     which both blocks verifying an edit and makes the refusal's own claim ("already in
///     this conversation") untrue.
///
/// `.serialized` because `SessionWorkspace` is a process-global (see `EditMismatchRecoveryTests`).
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("loop stall — zero new information climbs, resets on evidence, and ends", .serialized)
struct LoopStallTerminationTests {

    private func seeded(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_loopstall_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionWorkspace.setDirectory(dir.path)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func freshRegistry() async -> ToolRegistry {
        let registry = ToolRegistry(log: Logger(label: "test.loopstall"))
        await bootstrapBuiltInTools(registry: registry)
        return registry
    }

    /// One run then a refusal is not the point — the point is that the count has a top.
    /// Three runs, six correctable refusals, terminal from the ninth zero-gain event.
    @Test("the same unchanged call climbs to a terminal verdict, exact vector")
    func zeroGainLadderVector() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("loop.py", "print(1)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"loop.py"}"#
        func outcome() async throws -> String {
            do {
                _ = try await registry.call(
                    "read_file", arguments: args, caller: "test", headless: true,
                    conversationKey: "stall.vector")
                return "ran"
            } catch let error as ToolError {
                switch error {
                case .loopDetected: return "detected"
                case .loopStalled: return "stalled"
                default: return "other"
                }
            }
        }

        var ladder: [String] = []
        for _ in 1 ... 12 {
            ladder.append(try await outcome())
        }
        #expect(
            ladder == [
                "ran", "ran", "ran", "detected", "detected", "detected",
                "detected", "detected", "detected", "stalled", "stalled", "stalled",
            ],
            "identical answers climb too, and the wall has a top: \(ladder)")
    }

    @Test("the terminal verdict quotes its evidence and forbids instead of inviting")
    func terminalWordingIsAnEndingNotAnInvitation() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("end.py", "print(1)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"end.py"}"#
        for _ in 1 ... 9 {
            _ = try? await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.wording")
        }
        do {
            _ = try await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.wording")
            Issue.record("the 10th identical read_file must be terminal")
        } catch let ToolError.loopStalled(detail) {
            #expect(detail.contains("will NOT run again"), "it must close the door: \(detail)")
            #expect(
                detail.contains("byte-identical") && detail.contains("refusals"),
                "it must say what the count is made of: \(detail)")
            #expect(
                !detail.contains("vary the arguments"),
                "the retry invitation is what kept the cycle alive: \(detail)")
            #expect(detail.contains("answer the user"), "and still leave a way out: \(detail)")
        }
        let text = EnginePool.toolRecoveryText(for: ToolError.loopStalled("x"))
        #expect(
            text.contains("NOT executed") && text.contains("Do NOT call any tool again"),
            "the model's memory of a stall must be terminal on every face: \(text)")
        #expect(
            !text.contains("retry differently"),
            "the generic recovery branch ends in a retry: \(text)")
    }

    /// The defect this guard exists for: a re-read after a change carries NEW information, so
    /// refusing it stops the model verifying its own edit and makes the refusal untrue.
    @Test("a re-read after the file changed runs and returns the new bytes")
    func freshContentIsNotARepeat() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("page.py", "print(1)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"page.py"}"#
        for _ in 1 ... 3 {
            _ = try? await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.fresh")
        }
        _ = try await registry.call(
            "write_file", arguments: #"{"path":"page.py","content":"print(2222)\n"}"#,
            caller: "test", headless: true, conversationKey: "stall.fresh")
        let after = try await registry.call(
            "read_file", arguments: args, caller: "test", headless: true,
            conversationKey: "stall.fresh")
        #expect(
            after.contains("print(2222)"),
            "the verification path must stay open after an edit: \(after)")
        #expect(
            !after.contains("already in this conversation"),
            "a refusal of changed content would be a false claim: \(after)")
    }

    @Test("a different tool succeeding does not buy a stuck call back")
    func pingPongCannotResetTheLadder() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        // One directory for both files: `seeded` moves the session workspace each call,
        // so the second file is written into the directory the first one chose.
        let dir = try seeded("stuck.py", "print(1)\n").deletingLastPathComponent()
        try "print(2)\n".write(
            to: dir.appendingPathComponent("other.py"), atomically: true, encoding: .utf8)
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let argsA = #"{"path":"stuck.py"}"#
        var last: String = "none"
        for _ in 1 ... 10 {
            do {
                _ = try await registry.call(
                    "read_file", arguments: argsA, caller: "test", headless: true,
                    conversationKey: "stall.pingpong")
                last = "ran"
            } catch ToolError.loopStalled {
                last = "stalled"
            } catch {
                last = "detected"
            }
        }
        #expect(last == "stalled", "A must have climbed to terminal: \(last)")
        _ = try await registry.call(
            "read_file", arguments: #"{"path":"other.py"}"#, caller: "test", headless: true,
            conversationKey: "stall.pingpong")
        do {
            _ = try await registry.call(
                "read_file", arguments: argsA, caller: "test", headless: true,
                conversationKey: "stall.pingpong")
            Issue.record("an unrelated success must not unstuck A — that was the ping-pong")
        } catch ToolError.loopStalled {
            // expected: the ladder is per call, and A earned its verdict
        }
    }

    /// Loop accounting is per turn (codex's unit): the next user message owns a fresh budget.
    @Test("a new turn buys a fresh loop budget")
    func turnTokenScopesTheLadder() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("turn.py", "print(1)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"turn.py"}"#
        for _ in 1 ... 4 {
            _ = try? await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.turn", turnToken: "turn-1")
        }
        let reopened = try await registry.call(
            "read_file", arguments: args, caller: "test", headless: true,
            conversationKey: "stall.turn", turnToken: "turn-2")
        #expect(
            reopened.contains("print(1)"),
            "a later turn must not inherit the previous turn's charges: \(reopened)")
    }

    /// Both lanes and the handlers ask this one question, so "what ends the turn" has one home.
    @Test("only the stall ends the turn — every other verdict stays recoverable")
    func terminalPredicateMatrix() {
        let structurallyFatal = ToolError.executionFailed(
            NSError(domain: "test", code: 1, userInfo: nil))
        #expect(EnginePool.isTerminalStall(ToolError.loopStalled("x")) == true)
        #expect(EnginePool.isTerminalStall(ToolError.loopDetected("x")) == false)
        #expect(EnginePool.isTerminalStall(ToolError.notFound("x")) == false)
        #expect(EnginePool.isTerminalStall(ToolError.invalidParameter("x")) == false)
        #expect(EnginePool.isTerminalStall(ToolError.checkFailed("x")) == false)
        #expect(EnginePool.isTerminalStall(ToolError.denied(reason: "x")) == false)
        #expect(EnginePool.isTerminalStall(ToolError.breakerEngaged("x")) == false)
        #expect(EnginePool.isTerminalStall(structurallyFatal) == false)
    }
}
