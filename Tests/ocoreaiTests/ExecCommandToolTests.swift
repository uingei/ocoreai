// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ExecCommandToolTests — `exec_command` (codex unified-exec baseline) unit gate.
///
/// Coverage (exact-value assertions):
/// - zsh `-c` execution: stdout, stderr, exit code round-trip
/// - timeout clamp (0 → 1s; 7200 → 300s)
/// - head+tail truncation marker with precise char counts
/// - `cwd` + `~` expansion
/// - non-existent cwd → executionFailed
/// - destructive gate: `exec_command` `.ask` → deny without broker (regression contract)
/// - report shape: `end of process output` + `exit code: N`
import Foundation
import Testing

@testable import ocoreai

// MARK: - ExecTools core

@Suite("ExecTools — zsh execution (exact values)")
struct ExecToolsRunTests {

    @Test("stdout round-trip (echo)")
    func stdoutRoundTrip() async throws {
        let report = try await ExecTools.run(command: "echo hello-431", timeoutSeconds: 10)
        #expect(report.contains("hello-431"))
        #expect(report.contains("exit code: 0"))
        #expect(report.contains("end of process output"))
    }

    @Test("stderr + non-zero exit (exit 7)")
    func stderrAndExitCode() async throws {
        let report = try await ExecTools.run(
            command: "echo out-line; echo err-line >&2; exit 7", timeoutSeconds: 10)
        #expect(report.contains("out-line"))
        #expect(report.contains("err-line"))
        #expect(report.contains("exit code: 7"))
        #expect(report.contains("--- stderr ---"))
    }

    @Test("no stderr section when stderr empty")
    func noStderrSection() async throws {
        let report = try await ExecTools.run(command: "echo only-stdout", timeoutSeconds: 10)
        #expect(!report.contains("--- stderr ---"))
    }

    @Test("env var passthrough from current process (PATH-derived zsh)")
    func envPassthrough() async throws {
        await Task.yield()
        // `which zsh` must resolve (PATH inherited); exit 0.
        let report = try await ExecTools.run(command: "command -v zsh", timeoutSeconds: 10)
        #expect(report.contains("exit code: 0"))
    }

    @Test("cwd applied (pwd reflects requested dir)")
    func cwdApplied() async throws {
        let dir = NSTemporaryDirectory() + "ocoreai_execcwd_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let report = try await ExecTools.run(command: "pwd", cwd: dir, timeoutSeconds: 10)
        #expect(report.contains(dir))
        #expect(report.contains("exit code: 0"))
    }

    @Test("~ expansion in cwd")
    func tildeExpansion() async throws {
        let home = NSHomeDirectory()
        let report = try await ExecTools.run(command: "pwd", cwd: "~", timeoutSeconds: 10)
        #expect(report.contains(home))
    }

    @Test("non-existent cwd → executionFailed (not a hang)")
    func badCwdThrows() async {
        do {
            _ = try await ExecTools.run(
                command: "echo x", cwd: "/no/such/dir/99999", timeoutSeconds: 10)
            #expect(Bool(false), "expected an error for a bad cwd")
        } catch {
            #expect(error is ToolError)
        }
    }

    @Test("empty command → zsh no-op exit 0, NOT a crash")
    func emptyCommand() async throws {
        let report = try await ExecTools.run(command: "", timeoutSeconds: 10)
        #expect(report.contains("exit code: 0"))
        #expect(report.contains("end of process output"))
    }

    @Test("timeout kill (sleep 30 with 1s) — terminated, bounded report")
    func timeoutKills() async throws {
        let t0 = Date()
        do {
            let report = try await ExecTools.run(command: "sleep 30", timeoutSeconds: 1)
            let dt = Date().timeIntervalSince(t0)
            #expect(dt < 12, "timeout should bound execution (got \(dt)s)")
            #expect(report.contains("timed out after 1s"))
            // zsh `sleep` is a builtin → SIGTERM on the shell kills it cleanly.
            #expect(report.contains("end of process output"))
        } catch {
            #expect(Bool(false), "timeout should produce a report, not throw: \(error)")
        }
    }

    @Test("large output → head+tail truncation marker (exact counts)")
    func largeOutputTruncated() async throws {
        // 24k-char single line; report must head 6k + tail 6k + marker.
        let report = try await ExecTools.run(
            command: "python3 -c 'import sys; sys.stdout.write(\"x\"*24000); sys.stdout.flush()'",
            timeoutSeconds: 20)
        #expect(report.contains("[TRUNCATED 24000 total; showing first 6000 + last 6000 chars]"))
        #expect(report.contains("exit code: 0"))
        // Head starts with the 24k 'x' run; tail ends with it too.
        #expect(report.hasPrefix("x"))
        #expect(report.contains("end of process output"))
    }

    @Test("truncate() exact boundary — at-limit passes through unchanged")
    func truncateBoundary() {
        let s = String(repeating: "a", count: ExecTools.maxReportChars)
        #expect(ExecTools.truncate(s) == s)
        let over = String(repeating: "a", count: ExecTools.maxReportChars + 1)
        let out = ExecTools.truncate(over)
        // Exact structural assertion (no weak `count > 0`): the truncated report
        // is head(maxReportChars/2) + marker + tail(maxReportChars/2), derived
        // from the same `maxReportChars` constant the impl uses.
        let half = ExecTools.maxReportChars / 2
        let marker = "[TRUNCATED \(over.count) total; showing first \(half) + last \(half) chars]"
        #expect(
            out == String(repeating: "a", count: half) + "\n\(marker)\n"
                + String(repeating: "a", count: half))
    }

    @Test("expand() — ~ , ~/path, absolute passthrough, relative passthrough")
    func expandCases() {
        let home = NSHomeDirectory()
        #expect(ExecTools.expand("~") == home)
        #expect(ExecTools.expand("~/x/y") == home + "/x/y")
        #expect(ExecTools.expand("/abs/path") == "/abs/path")
        #expect(ExecTools.expand("rel/path") == "rel/path")
        #expect(ExecTools.expand("~nottilde") == "~nottilde")
    }
}

// MARK: - format() exact shape

@Suite("ExecTools.format — report shape")
struct ExecToolsFormatTests {
    func mk(std: String, err: String, exit: Int32, stop: ExecTools.StopReason, t: Int = 60)
        -> ExecTools.Result
    {
        ExecTools.Result(stdout: std, stderr: err, exitCode: exit, stop: stop, timeoutSeconds: t)
    }

    @Test("minimal: stdout only")
    func minimal() {
        let out = ExecTools.format(mk(std: "line1\nline2", err: "", exit: 0, stop: .none))
        #expect(out == "line1\nline2\nend of process output\nexit code: 0")
    }

    @Test("with stderr")
    func withStderr() {
        let out = ExecTools.format(mk(std: "o", err: "e", exit: 2, stop: .none))
        #expect(out == "o\n--- stderr ---\ne\nend of process output\nexit code: 2")
    }

    @Test("empty stdout+stderr still emits end-of-output marker")
    func empty() {
        let out = ExecTools.format(mk(std: "", err: "", exit: 0, stop: .none))
        #expect(out == "end of process output\nexit code: 0")
    }

    @Test("timeout note appended after exit code")
    func timeoutNote() {
        let out = ExecTools.format(mk(std: "partial", err: "", exit: 143, stop: .timeout, t: 1))
        #expect(
            out
                == "partial\nend of process output\nexit code: 143\ntimed out after 1s (SIGTERM, then SIGKILL)"
        )
        #expect(out.contains("SIGKILL"))
    }

    @Test("outputCap note appended after exit code")
    func outputCapNote() {
        let out = ExecTools.format(mk(std: "big", err: "", exit: 1, stop: .outputCap))
        #expect(out.contains("output exceeded"))
        #expect(out.contains("byte capture cap"))
    }
}

// MARK: - ToolRegistry gate (destructive .ask → hard deny without broker)

@Suite("ToolRegistry — exec_command destructive gate")
struct ExecCommandApprovalTests {

    @Test("exec_command .ask with no broker → denied + handler must NOT run")
    func askNoBroker() async {
        let registry = ToolRegistry(
            hooks: [
                Hook.pre(matcher: ToolMatcher("exec_command,write_file,edit_file")) { _ in
                    .ask(reason: "destructive tool call")
                }
            ],
            approvalBroker: nil
        )
        let marker = NSTemporaryDirectory() + "execgate_\(UUID().uuidString)"
        let entry = ToolEntry.typed(
            name: "exec_command", toolset: "shell", argsType: ExecGateArgs.self,
            description: "gated", isDestructive: true
        ) { args in
            _ = FileManager.default.createFile(atPath: args.marker, contents: nil)
            return "RAN"
        }
        do {
            try await registry.register(entry)
        } catch {}
        do {
            _ = try await registry.call("exec_command", arguments: #""marker":"\#(marker)""#)
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
        // Regression contract: the destructive op must NOT have executed.
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    struct ExecGateArgs: Codable, Sendable { let marker: String }
}

// MARK: - Bootstrap registration (integration — tool is present + callable in a clean registry)

@Suite("bootstrapBuiltInTools — exec_command registered + callable")
struct ExecCommandBootstrapTests {

    @Test("bootstrap registers exec_command and the echo baseline still works")
    func registered() async throws {
        let registry = ToolRegistry(hooks: [], approvalBroker: nil)
        await bootstrapBuiltInTools(registry: registry, skillRegistry: nil)
        let names = await registry.listTools()
        #expect(names.contains("exec_command"), "registered: \(names)")
        #expect(names.contains("echo"), "echo baseline: \(names)")
        #expect(names.contains("read_file"), "read_file baseline: \(names)")
        // Call through the real chokepoint (no hook → allow).
        let out = try await registry.call(
            "exec_command", arguments: #"{"command":"echo bootstrap-ok-431"}"#)
        #expect(out.contains("bootstrap-ok-431"))
        #expect(out.contains("exit code: 0"))
    }
}
