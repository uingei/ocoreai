// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoopStallTerminationTests — a refusal that cannot change the outcome must reach an end.
///
/// Measured on the eval scoreboard: one task issued 86 identical `read_file` refusals and never
/// stopped. `recordExecution` only counts attempts that REACHED the handler, so a preflight
/// refusal advanced no state and the same `loopDetected` was renewable without limit; the
/// remedy text it carried ("vary the arguments") is the instruction to try again.
///
/// The ladder therefore has a top: two correctable refusals, then a terminal verdict that
/// forbids the call for the turn, and one pure predicate that both lanes ask before stopping.
///
/// `.serialized` because `SessionWorkspace` is a process-global (see `EditMismatchRecoveryTests`).
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("loop stall — refusals escalate, and the escalation has a top", .serialized)
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

    /// Three attempts run, five are refused as correctable, the sixth refusal is terminal.
    /// Exact values, because the whole point is that the count is bounded — and because the
    /// five correctable tiers are what lets a model that would escape do so (see the
    /// threshold's note: at two tiers an escaping task got cut instead).
    @Test("the same call is refused twice as correctable, then terminated")
    func refusalLadderReachesTerminal() async throws {
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
                    conversationKey: "stall.ladder")
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
        for _ in 1 ... 11 {
            ladder.append(try await outcome())
        }
        #expect(
            ladder == [
                "ran", "ran", "ran", "detected", "detected", "detected",
                "detected", "detected", "stalled", "stalled", "stalled",
            ],
            "the wall must have a top: \(ladder)")
    }

    @Test("the terminal verdict forbids the call instead of inviting another attempt")
    func terminalWordingIsAnEndingNotAnInvitation() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("end.py", "print(1)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"end.py"}"#
        for _ in 1 ... 8 {
            _ = try? await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.wording")
        }
        do {
            _ = try await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.wording")
            Issue.record("the 9th identical read_file must be terminal")
        } catch let ToolError.loopStalled(detail) {
            #expect(detail.contains("will NOT run again"), "it must close the door: \(detail)")
            #expect(
                !detail.contains("vary the arguments"),
                "the retry invitation is what kept the cycle alive: \(detail)")
            #expect(
                detail.contains("answer the user"),
                "and still leave a way out: \(detail)")
        }
        let text = EnginePool.toolRecoveryText(for: ToolError.loopStalled("x"))
        #expect(
            text.contains("NOT executed") && text.contains("Do NOT call any tool again"),
            "the model's memory of a stall must be terminal on every face: \(text)")
        #expect(
            !text.contains("retry differently"),
            "the generic recovery branch ends in a retry: \(text)")
    }

    @Test("a call that runs buys the ladder back")
    func successClearsStrikes() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("a.py", "print(1)\n")
        _ = try seeded("b.py", "print(2)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let argsA = #"{"path":"a.py"}"#
        for _ in 1 ... 8 {
            _ = try? await registry.call(
                "read_file", arguments: argsA, caller: "test", headless: true,
                conversationKey: "stall.reset")
        }
        // A call that actually ran is the proof the cycle broke — strikes go to zero, so the
        // next refusal of the old call is correctable again rather than terminal.
        _ = try await registry.call(
            "read_file", arguments: #"{"path":"b.py"}"#, caller: "test", headless: true,
            conversationKey: "stall.reset")
        do {
            _ = try await registry.call(
                "read_file", arguments: argsA, caller: "test", headless: true,
                conversationKey: "stall.reset")
            Issue.record("a.py is past the identical-call cap and must still be refused")
        } catch ToolError.loopDetected {
            // expected: the run reset the strikes, so this is refusal #1 again
        } catch let error as ToolError {
            Issue.record("a call that ran must not leave the ladder at its top: \(error)")
        }
    }

    @Test("a stall does not lock tools that were never stuck")
    func otherCallsStayOpen() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("stuck.py", "print(1)\n")
        _ = try seeded("useful.py", "print(2)\n")
        defer { SessionWorkspace.clear() }

        let registry = await freshRegistry()
        let args = #"{"path":"stuck.py"}"#
        for _ in 1 ... 9 {
            _ = try? await registry.call(
                "read_file", arguments: args, caller: "test", headless: true,
                conversationKey: "stall.scope")
        }
        let other = try await registry.call(
            "read_file", arguments: #"{"path":"useful.py"}"#, caller: "test", headless: true,
            conversationKey: "stall.scope")
        #expect(other.contains("print(2)"), "the stuck call is the problem, not the toolset")
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
