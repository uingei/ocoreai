// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ExecTools — real shell-command execution for the agent tool surface.
///
/// Closes the coding-agent action loop (product goal: a coding agent must be
/// able to RUN what it edits): the registry's destructive blacklist already
/// reserved `execute_code` (ToolRegistry L40) but no command tool existed —
/// the surface was edit-only.
///
/// Baseline: codex `exec_command` (unified exec,
/// `core/src/unified_exec/process_manager.rs:1308` `ToolName::plain("exec_command")`)
/// — zsh via `core/src/shell.rs`, per-command timeout + cwd, approval on
/// destructive calls. ocoreai keeps the name/shape, drops codex's remote-env /
/// async-watcher planes (out of scope; user mandate: no multi-agent surface).
///
/// Safety invariants (LLM inputs are untrusted):
/// - `timeoutSeconds` clamped to 1…300 — the model cannot self-extend it.
/// - stdout/stderr land in temp FILES (not pipes) → no pipe-full deadlock;
///   the child can be killed at the deadline and `waitUntilExit` still returns.
/// - On-disk capture capped (`maxDiskOutputBytes`) — a runaway writer is
///   terminated, never allowed to fill the disk.
/// - Report truncated to `maxReportChars` head+tail so one call cannot
///   balloon the model context.
/// - Execution runs on a background dispatch queue, never on the
///   cooperative thread pool (a 300 s sleep must not hang the app).
/// - `isDestructive: true` → routes through the ApprovalBroker gate
///   (ToolRegistry.call hook `.ask`) — approval is user-side, not model-side.
import Foundation

#if os(macOS)
import Darwin
#endif

enum ExecTools {
    // Bounds — every resource dimension is explicitly capped.
    static let maxTimeoutSeconds = 300  // hard upper clamp (LLM cannot exceed)
    static let minTimeoutSeconds = 1
    static let defaultTimeoutSeconds = 60
    static let maxDiskOutputBytes = 262_144  // 256KB per-stream capture cap (disk)
    static let maxReportChars = 12_000  // head (6k) + tail (6k) in the report
    static let killGraceSeconds: TimeInterval = 2  // SIGTERM → SIGKILL window
    static let pollInterval: TimeInterval = 0.05

    enum StopReason: String, Sendable {
        case none
        case timeout
        case outputCap
    }

    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let stop: StopReason
        let timeoutSeconds: Int
    }

    /// Report format (exact, testable):
    /// ```
    /// <stdout (truncated if needed)>
    /// --- stderr ---            (only when stderr non-empty)
    /// <stderr (truncated if needed)>
    /// end of process output
    /// exit code: N
    /// timed out after Ns (SIGTERM, then SIGKILL)   (only on timeout)
    /// output exceeded 256KB capture cap; process terminated  (only on cap)
    /// ```
    static func format(_ r: Result) -> String {
        var parts: [String] = []
        let out = truncate(r.stdout)
        if !out.isEmpty { parts.append(out) }
        let err = truncate(r.stderr)
        if !err.isEmpty {
            parts.append("--- stderr ---")
            parts.append(err)
        }
        parts.append("end of process output")
        parts.append("exit code: \(r.exitCode)")
        switch r.stop {
        case .none:
            break
        case .timeout:
            parts.append("timed out after \(r.timeoutSeconds)s (SIGTERM, then SIGKILL)")
        case .outputCap:
            parts.append(
                "output exceeded \(maxDiskOutputBytes) byte capture cap; process terminated")
        }
        return parts.joined(separator: "\n")
    }

    /// Head+tail truncation of an over-long stream.
    static func truncate(_ s: String) -> String {
        if s.count <= maxReportChars { return s }
        let half = maxReportChars / 2
        let head = String(s.prefix(half))
        let tail = String(s.suffix(half))
        return head + "\n[TRUNCATED \(s.count) total; showing first \(half) + last \(half) chars]\n"
            + tail
    }

    /// `~`-expand a path (LLM outputs often use `~/…`).
    static func expand(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst())
        }
        return path
    }

    /// Execute `command` under `/bin/zsh -c` with optional `cwd` + timeout.
    /// - Returns: the formatted report (stdout/stderr/exit code/stop note).
    /// - Throws: start failures as `ToolError`; iOS throws (no POSIX Process).
    static func run(
        command: String,
        cwd: String? = nil,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws -> String {
        #if os(macOS)
        let clamped = min(max(timeoutSeconds, minTimeoutSeconds), maxTimeoutSeconds)
        let result = try await withCheckedThrowingContinuation {
            (
                cont: CheckedContinuation<Result, Error>
            ) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(
                        returning: try runSync(command: command, cwd: cwd, timeoutSeconds: clamped))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return format(result)
        #else
        _ = (command, cwd, timeoutSeconds)
        throw ToolError.checkFailed(
            "exec_command is unavailable on iOS (POSIX Process is macOS-only)")
        #endif
    }

    #if os(macOS)
    private static func runSync(
        command: String,
        cwd: String?,
        timeoutSeconds: Int
    ) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        if let cwd, !cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: expand(cwd))
        }

        // Capture streams to temp files (not pipes): a killed child cannot
        // deadlock us, and `waitUntilExit` is always reachable.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai_exec_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent("out")
        let errURL = dir.appendingPathComponent("err")
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
            let errHandle = FileHandle(forWritingAtPath: errURL.path)
        else {
            throw ToolError.executionFailed(ToolError.checkFailed("cannot open capture files"))
        }
        proc.standardOutput = outHandle
        proc.standardError = errHandle
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            outHandle.closeFile()
            errHandle.closeFile()
            throw ToolError.executionFailed(error)
        }

        var stop: StopReason = .none
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while proc.isRunning {
            let grewPastCap =
                fileBytes(outURL) > maxDiskOutputBytes
                || fileBytes(errURL) > maxDiskOutputBytes
            if grewPastCap && stop == .none {
                stop = .outputCap
            }
            if Date() >= deadline && stop == .none {
                stop = .timeout
            }
            if stop != .none {
                terminateProc(proc)
            } else {
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        proc.waitUntilExit()
        outHandle.closeFile()
        errHandle.closeFile()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return Result(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus,
            stop: stop,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// SIGTERM → grace → SIGKILL ladder (deterministic termination).
    private static func terminateProc(_ proc: Process) {
        let pid = proc.processIdentifier
        proc.terminate()
        let grace = Date().addingTimeInterval(killGraceSeconds)
        while proc.isRunning && Date() < grace {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if proc.isRunning {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private static func fileBytes(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return (attrs[.size] as? Int) ?? 0
    }
    #endif
}
