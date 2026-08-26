// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ExecSessionsTests — session exec surface (exec_shell / write_stdin /
/// exec_poll, `ExecSessionManager`) exact-value gate.
///
/// Additive to the pinned `ExecCommandToolTests` (blocking `exec_command`):
/// - spawn: fast command completes inside the yield window
///   (`completed` + `exit code: 0`)
/// - spawn: long command outlives the window
///   (`completed == false`, `exit code: -1` while alive)
/// - write_stdin interactive: `cat` echoes stdin → round-trip
/// - exec_poll: pure poll returns the same report shape, no stdin touch
/// - kill: SIGTERM → exit code 143, terminated note
/// - clampYieldMs: exact bounds 250 / 30_000 (codex `mod.rs` constants)
/// - truncate: boundary at maxReportChars (parity with ExecTools)
/// - destructive gate: exec_shell `.ask` w/o broker → denied, handler
///   must NOT run (regression contract, mirrors exec_command gate)
/// - bootstrap: the three tools are registered in the shell toolset
///
/// Every test that spawns a live child calls `shutdown()` on the shared
/// manager via `defer` — the suite must leave zero live processes.
import Foundation
import Testing

@testable import ocoreai

// NOTE on test isolation: all suites share `ExecSessionManager.shared`.
// Tests that spawn a LIVE child must kill their specific session id before
// finishing (per-test scope); NONE of them call the global `shutdown()` —
// a global kill racing a parallel suite's live child is exactly the failure
// this suite must not reproduce. Orphaned children at process exit are
// harmless (stdin pipe closes → EOF; `sleep` is reaped when the runner dies,
// and the next run's fresh process never sees them).

// MARK: - Pure helpers (no actor hop)

@Suite("ExecSessionManager — pure helpers (exact values)")
struct ExecSessionsHelperTests {

    @Test("clampYieldMs — below floor → 250, in range → identity, above ceiling → 30_000")
    func clampYieldBounds() {
        #expect(ExecSessionManager.clampYieldMs(1) == 250)
        #expect(ExecSessionManager.clampYieldMs(0) == 250)
        #expect(ExecSessionManager.clampYieldMs(-500) == 250)
        #expect(ExecSessionManager.clampYieldMs(250) == 250)
        #expect(ExecSessionManager.clampYieldMs(10_000) == 10_000)
        #expect(ExecSessionManager.clampYieldMs(30_000) == 30_000)
        #expect(ExecSessionManager.clampYieldMs(60_000) == 30_000)
        #expect(ExecSessionManager.clampYieldMs(10 * 60 * 1000) == 30_000)
    }

    @Test("clamp defaults — floor 250 / ceiling 30_000 / default 10_000 (codex parity)")
    func clampConstants() {
        #expect(ExecSessionManager.clampMinYieldMs == 250)
        #expect(ExecSessionManager.clampMaxYieldMs == 30_000)
        #expect(ExecSessionManager.defaultYieldMs == 10_000)
    }

    @Test("clampEmptyYieldMs — codex empty-poll regime 5_000–300_000 (process_manager.rs:828)")
    func clampEmptyYieldBounds() {
        #expect(ExecSessionManager.clampEmptyYieldMs(1) == 5_000)
        #expect(ExecSessionManager.clampEmptyYieldMs(0) == 5_000)
        #expect(ExecSessionManager.clampEmptyYieldMs(-5_000) == 5_000)
        #expect(ExecSessionManager.clampEmptyYieldMs(250) == 5_000)  // below floor → floor
        #expect(ExecSessionManager.clampEmptyYieldMs(5_000) == 5_000)
        #expect(ExecSessionManager.clampEmptyYieldMs(29_999) == 29_999)
        #expect(ExecSessionManager.clampEmptyYieldMs(30_000) == 30_000)  // in-band, no cap at 30_000
        #expect(ExecSessionManager.clampEmptyYieldMs(300_000) == 300_000)
        #expect(ExecSessionManager.clampEmptyYieldMs(600_000) == 300_000)  // above ceiling → ceil
        #expect(ExecSessionManager.clampEmptyYieldMs(10 * 60 * 1000) == 300_000)
        #expect(ExecSessionManager.emptyYieldMinMs == 5_000)
        #expect(ExecSessionManager.emptyYieldMaxMs == 300_000)
        #expect(ExecSessionManager.emptyYieldDefaultMs == 5_000)
    }

    @Test("truncate — at-limit passes through, over-limit gets exact marker")
    func truncateBoundary() {
        let atLimit = String(repeating: "a", count: ExecSessionManager.maxReportChars)
        #expect(ExecSessionManager.truncate(atLimit) == atLimit)
        let over = String(repeating: "a", count: ExecSessionManager.maxReportChars + 2)
        let out = ExecSessionManager.truncate(over)
        let half = ExecSessionManager.maxReportChars / 2
        #expect(
            out.contains(
                "[TRUNCATED \(over.count) total; showing first \(half) + last \(half) chars]"))
        #expect(out.hasPrefix("a"))
        #expect(out.hasSuffix("a"))
    }

    @Test("expandPath — ~ , ~/x, absolute, relative (parity with ExecTools.expand)")
    func expandPath() {
        let home = NSHomeDirectory()
        #expect(ExecSessionManager.expandPath("~") == home)
        #expect(ExecSessionManager.expandPath("~/x/y") == home + "/x/y")
        #expect(ExecSessionManager.expandPath("/abs/path") == "/abs/path")
        #expect(ExecSessionManager.expandPath("rel/path") == "rel/path")
        #expect(ExecSessionManager.expandPath("~nottilde") == "~nottilde")
    }
}

// MARK: - Spawn (yield + persist)

@Suite("ExecSessionManager — spawn")
struct ExecSessionsSpawnTests {

    @Test("fast command completes inside yield window (exit 0, completed report)")
    func spawnCompletes() async throws {
        let m = ExecSessionManager.shared
        let res = try await m.spawn(command: "echo exec-shell-ok-431", yieldMs: 5000)
        #expect(res.completed)
        #expect(res.report.contains("exec-shell-ok-431"))
        #expect(res.report.contains("exit code: 0"))
        #expect(res.report.contains("end of process output"))
        #expect(res.sessionId >= 1)
    }

    @Test("non-zero exit (7) surfaces in the completed report")
    func spawnExit7() async throws {
        let m = ExecSessionManager.shared
        let res = try await m.spawn(
            command: "echo out-line; echo err-line >&2; exit 7", yieldMs: 5000)
        #expect(res.completed)
        #expect(res.report.contains("out-line"))
        #expect(res.report.contains("--- stderr ---"))
        #expect(res.report.contains("err-line"))
        #expect(res.report.contains("exit code: 7"))
    }

    @Test("back-to-back reaped children finalize on wall clock (runner wedge regression)")
    func spawnExitCascade() async throws {
        // Regression guard for the 2026-08-26 CI hang: the finalize path
        // must read `terminationStatus` of an already-reaped child
        // WITHOUT a second blocking `waitUntilExit()`. On the macOS 26
        // runner that redundant wait wedged the whole 60-min job right
        // at this exact test class. N back-to-back spawn→poll cycles
        // must all land with their EXACT exit codes inside a hard wall
        // clock — a stall now shows up as a bounded local failure
        // (seconds), not an unbounded CI timeout.
        let m = ExecSessionManager.shared
        let t0 = Date()
        for i in 0 ..< 5 {
            let status = 7 + i
            let res = try await m.spawn(command: "exit \(status)", yieldMs: 500)
            #expect(res.completed, "spawn cycle \(i) must complete in-window")
            #expect(res.report.contains("end of process output"))
            #expect(res.report.contains("exit code: \(status)"))
            let poll = try await m.poll(sessionId: res.sessionId, yieldMs: 200)
            #expect(poll.completed)
            #expect(poll.report.contains("exit code: \(status)"), "poll cycle \(i)")
        }
        let dt = Date().timeIntervalSince(t0)
        #expect(dt < 15, "spawn/poll cycles must stay on wall clock, got \(dt)s")
    }

    @Test("live child outlives yield window → not completed, exit placeholder -1")
    func spawnStillAlive() async throws {
        let m = ExecSessionManager.shared
        let t0 = Date()
        let res = try await m.spawn(command: "sleep 30", yieldMs: 400)
        #expect(!res.completed)
        #expect(res.report.contains("exit code: -1"))
        #expect(res.report.contains("end of process output"))
        // 400ms yield must NOT block the actor executor for seconds.
        #expect(Date().timeIntervalSince(t0) < 15)
        let id = res.sessionId
        // The session is pollable after the yield window.
        #expect(await m.contains(id))
        let poll = try await m.poll(sessionId: id, yieldMs: 300)
        #expect(!poll.completed)
        #expect(poll.report.contains("exit code: -1"))
        // Per-test cleanup: kill OUR session only (never the global
        // shutdown — other suites may own live children in parallel).
        let note = try await m.kill(sessionId: id)
        #expect(note.contains("terminated"))
        let after = try await m.poll(sessionId: id, yieldMs: 300)
        #expect(after.completed)
    }

    @Test("empty command → zsh no-op exit 0 (NOT a crash)")
    func spawnEmptyCommand() async throws {
        let m = ExecSessionManager.shared
        let res = try await m.spawn(command: "", yieldMs: 3000)
        #expect(res.completed)
        #expect(res.report.contains("exit code: 0"))
    }
}

// MARK: - Interactive (write_stdin / exec_poll)

@Suite("ExecSessionManager — interactive (write_stdin / exec_poll)")
struct ExecSessionsInteractiveTests {

    @Test("write_stdin round-trip — `cat` echoes stdin bytes to stdout")
    func stdinRoundTrip() async throws {
        let m = ExecSessionManager.shared
        let spawn = try await m.spawn(command: "cat", yieldMs: 3000)
        #expect(!spawn.completed, "cat must stay alive waiting on stdin")
        #expect(spawn.report.contains("exit code: -1"))

        let id = spawn.sessionId
        let w = try await m.writeStdin(sessionId: id, data: "ping-431", yieldMs: 4000)
        // cat flushes line-buffered; 'ping-431' without newline still
        // reaches the write() → visible in the delta.
        #expect(w.report.contains("ping-431"))
        #expect(!w.completed)

        // exec_poll (no stdin write) on a `cat` that hasn't EOF: no new
        // bytes, still alive, same report shape.
        let p = try await m.poll(sessionId: id, yieldMs: 500)
        #expect(!p.completed)
        #expect(p.report.contains("end of process output"))

        // Kill (SIGTERM) to end the session: signal-status semantics give
        // "exit code: 15" (see ExecSessionsKillTests.killLive).
        _ = try await m.kill(sessionId: id)
        let after = try? await m.poll(sessionId: id, yieldMs: 500)
        #expect(after?.completed == true)
        #expect(after?.report.contains("exit code: 15") == true)
    }

    @Test("write_stdin on unknown session → ToolError")
    func stdinUnknownSession() async {
        let m = ExecSessionManager.shared
        #expect(
            (try? await m.writeStdin(sessionId: 999_999, data: "x", yieldMs: 500)) == nil,
            "expected an error for an unknown session")
    }

    @Test("poll on unknown session → ToolError")
    func pollUnknownSession() async {
        let m = ExecSessionManager.shared
        #expect((try? await m.poll(sessionId: 888_888, yieldMs: 500)) == nil)
    }
}

// MARK: - Kill

@Suite("ExecSessionManager — kill")
struct ExecSessionsKillTests {

    @Test("kill live child → SIGTERM + termination note + exact signal status")
    func killLive() async throws {
        let m = ExecSessionManager.shared
        let spawn = try await m.spawn(command: "sleep 30", yieldMs: 300)
        #expect(!spawn.completed)
        let id = spawn.sessionId
        let t0 = Date()
        let note = try await m.kill(sessionId: id)
        let dt = Date().timeIntervalSince(t0)
        #expect(note.contains("terminated"))
        #expect(note.contains("SIGTERM"))
        // 2s grace + margin (zsh exits after its child is reaped).
        #expect(dt < 12, "kill should bound within grace+margin, got \(dt)s")
        let after = try await m.poll(sessionId: id, yieldMs: 500)
        #expect(after.completed)
        // POSIX: `terminationStatus()` reports the raw signal number on a
        // signalled death (waitpid semantics); 128+143 is only the SHELL
        // convention. SIGTERM = 15 → "exit code: 15".
        #expect(after.report.contains("exit code: 15"))
    }

    @Test("kill already-finished session → idempotent note, no throw")
    func killFinished() async throws {
        let m = ExecSessionManager.shared
        let spawn = try await m.spawn(command: "echo done-431", yieldMs: 5000)
        #expect(spawn.completed)
        let note = try await m.kill(sessionId: spawn.sessionId)
        #expect(note.contains("already finished"))
        #expect(note.contains("exit code: 0"))
    }

    @Test("kill unknown session → ToolError")
    func killUnknown() async {
        let m = ExecSessionManager.shared
        #expect((try? await m.kill(sessionId: 777_777)) == nil)
    }
}

// MARK: - Destructive gate (parity with exec_command gate contract)

@Suite("ToolRegistry — exec_shell destructive gate")
struct ExecShellApprovalTests {
    struct GateArgs: Codable, Sendable { let marker: String }

    @Test("exec_shell .ask with no broker → denied + handler must NOT run")
    func askNoBroker() async {
        let registry = ToolRegistry(
            hooks: [
                Hook.pre(matcher: ToolMatcher("exec_shell,exec_command")) { _ in
                    .ask(reason: "destructive tool call")
                }
            ],
            approvalBroker: nil
        )
        let marker = NSTemporaryDirectory() + "execshellgate_\(UUID().uuidString)"
        let entry = ToolEntry.typed(
            name: "exec_shell", toolset: "shell", argsType: GateArgs.self,
            description: "gated", isDestructive: true
        ) { args in
            _ = FileManager.default.createFile(atPath: args.marker, contents: nil)
            return "RAN"
        }
        do {
            try await registry.register(entry)
        } catch {}
        do {
            _ = try await registry.call("exec_shell", arguments: #"""marker":"\#(marker)"""#)
            #expect(Bool(false), "expected denied")
        } catch let e as ToolError {
            guard case .denied = e else {
                #expect(Bool(false), "expected ToolError.denied, got \(e)")
                return
            }
        } catch {
            #expect(Bool(false), "expected ToolError.denied, got \(error)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}

// MARK: - Bootstrap registration

@Suite("bootstrapBuiltInTools — exec session surface registered")
struct ExecSessionsBootstrapTests {

    @Test("all three session tools are registered in the shell toolset")
    func registered() async throws {
        let registry = ToolRegistry(hooks: [], approvalBroker: nil)
        await bootstrapBuiltInTools(registry: registry, skillRegistry: nil)
        let names = await registry.listTools()
        #expect(names.contains("exec_command"), "baseline: \(names)")
        for tool in ["exec_shell", "write_stdin", "exec_poll"] {
            #expect(names.contains(tool), "missing \(tool): \(names)")
        }
    }

    @Test("exec_shell call through the real chokepoint (no hook → allow)")
    func callthrough() async throws {
        let registry = ToolRegistry(hooks: [], approvalBroker: nil)
        await bootstrapBuiltInTools(registry: registry, skillRegistry: nil)
        let out = try await registry.call(
            "exec_shell",
            arguments: "{\"command\":\"echo bootstrap-shell-431\",\"yieldMs\":5000}")
        #expect(out.contains("bootstrap-shell-431"))
        #expect(out.contains("exit code: 0"))
        #expect(out.contains("session_id:"))
        // No global shutdown here: that suite may run in parallel with
        // interactive-suite tests that own live children — a global kill
        // would be a cross-test corruption, not a cleanup.
    }
}
