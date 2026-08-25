// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ExecSessions — session (yield + interactive) exec surface, additive to
/// the pinned blocking `exec_command` (`ExecTools.run`, whose 9-test gate in
/// `ExecCommandToolTests.swift` locks the block-then-report contract).
///
/// A coding agent needs long-running / interactive processes (dev servers,
/// REPLs, watch builds) that block-then-report cannot serve. This actor owns
/// a bounded set of live shell sessions driven by three tools:
///
///   - `exec_shell`   → spawn `command` under `zsh -c`, yield ≤ `yieldMs`,
///                      return session id + output delta (or the full report
///                      if the child finished inside the yield window)
///   - `write_stdin`  → write `data` bytes verbatim to the child's stdin
///                      pipe (no implicit newline), then drain up to
///                      `yieldMs` and return the new delta
///   - `exec_poll`    → no stdin write; drain up to `yieldMs`, return the
///                      new delta (a finished session returns its cached
///                      final report)
///
/// Baseline — codex `unified_exec` (references/codex, HEAD):
///   - `clamp_yield_time` (core/src/unified_exec/mod.rs:203):
///     `yield_ms.clamp(MIN_YIELD_TIME_MS=250, MAX_YIELD_TIME_MS=30_000)` —
///     mirrored exactly by `clampYieldMs` (bounds are test-pinned).
///   - `write_stdin` handler (tools/handlers/unified_exec/write_stdin.rs):
///     empty `data` ⇒ pure yield/poll, the pipe is never touched; non-empty
///     ⇒ write then yield — mirrored by `writeStdin` (empty `data` never
///     touches the stdin handle).
///   - `MAX_UNIFIED_EXEC_PROCESSES = 64` → ocoreai `maxLive = 16`
///     (documented deviation: a desktop agent rarely needs 64 concurrent
///     shells; the bound is explicit and enforced).
///   - `UNIFIED_EXEC_OUTPUT_MAX_BYTES = 1_MiB` budget → ocoreai reuses the
///     `ExecTools` report contract (256KB per-stream capture cap /
///     12_000-char head+tail truncation) so both exec surfaces present one
///     shape to the model.
///   - SIGTERM → 2s grace → SIGKILL kill path mirrors `ExecTools.terminateProc`.
///
/// Concurrency (Swift 6, tools-version 6.2, `.swiftLanguageMode(.v6)`):
/// `Process` is non-`Sendable` and cannot cross an isolation boundary.
/// `SessionProc` wraps it behind an `NSLock` (`@unchecked Sendable`) so the
/// reference may be held by actor state and captured by `@Sendable`
/// closures; every `Process` method call is lock-bounded. All child
/// interaction that could block (drain / kill / eviction) runs inside ONE
/// `@Sendable` closure on a background `DispatchQueue` — the proven
/// `ExecTools.runSync` pattern — and only `Sendable` values cross the
/// closure boundary. File capture uses temp files (not pipes) so a killed
/// child can never deadlock the reader (same invariant as `ExecTools`).
import Foundation

#if os(macOS)
import Darwin
#endif

/// Bridge a (possibly blocking) `@Sendable` body onto a background global
/// queue. Same shape as the inlined `DispatchQueue` bridge in the pinned
/// `ExecTools.run`; exists because three call sites (stdin write / kill /
/// eviction) share it.
private func runOnBackground<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                cont.resume(returning: try body())
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Reference wrapper (lock-bounded) over a POSIX `Process` + stdin handle.
/// `Process` is non-`Sendable`; the lock bounds each method call so the
/// reference can safely live in actor state and be captured by `@Sendable`
/// dispatch closures without the reference itself racing.
private final class SessionProc: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var stdinHandle: FileHandle?

    init(process: Process, stdinHandle: FileHandle?) {
        self.proc = process
        self.stdinHandle = stdinHandle
    }

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        try proc?.run()
    }

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return proc?.isRunning ?? false
    }

    func waitUntilExit() {
        lock.lock()
        defer { lock.unlock() }
        proc?.waitUntilExit()
    }

    func terminationStatus() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return proc?.terminationStatus ?? -1
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        proc?.terminate()
    }

    func forceKill() {
        lock.lock()
        defer { lock.unlock() }
        guard let p = proc, p.isRunning else { return }
        #if os(macOS)
        kill(p.processIdentifier, SIGKILL)
        #endif
    }

    @discardableResult
    func writeStdin(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = stdinHandle else { return }
        // `FileHandle.write(contentsOf:)` writes the whole buffer (or
        // throws, e.g. EPIPE when the child closed stdin / has exited).
        try handle.write(contentsOf: data)
    }

    func closeStdin() {
        lock.lock()
        defer { lock.unlock() }
        try? stdinHandle?.close()
        stdinHandle = nil
    }
}

actor ExecSessionManager {
    // MARK: - Bounds (codex parity where noted)

    // codex `mod.rs:68-78` constants + `write_stdin.rs:25` serde default —
    // the three yield regimes verbatim (see `clampYieldMs`/`clampEmptyYieldMs`
    // docs for which surface each applies to).
    static let clampMinYieldMs = 250  // codex MIN_YIELD_TIME_MS (mod.rs:68)
    static let clampMaxYieldMs = 30_000  // codex MAX_YIELD_TIME_MS (mod.rs:72)
    static let defaultYieldMs = 10_000  // codex default_exec_yield_time_ms (unified_exec.rs:60)
    static let emptyYieldMinMs = 5_000  // codex MIN_EMPTY_YIELD_TIME_MS (mod.rs:71)
    static let emptyYieldMaxMs = 300_000  // codex DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS (mod.rs:73)
    static let emptyYieldDefaultMs = 5_000  // empty poll default (codex `input.is_empty()` regime)
    static let maxLive = 16  // codex MAX_UNIFIED_EXEC_PROCESSES=64 (documented deviation)
    static let maxDiskOutputBytes = 262_144  // 256KB per-stream cap (mirrors ExecTools)
    static let maxReportChars = 12_000  // head (6k) + tail (6k) (mirrors ExecTools)
    static let killGraceSeconds: TimeInterval = 2  // SIGTERM → SIGKILL window (mirrors ExecTools)

    // MARK: - State

    private struct Session {
        var command: String
        var stdout: String
        var stderr: String
        var completed: Bool
        var exitCode: Int32
        var outOffset: Int64
        var errOffset: Int64
        var dir: URL
        var proc: SessionProc
        var createdAt: Date
    }

    private var sessions: [Int: Session] = [:]
    private var counter: Int = 0

    /// Shared instance — the tool surface (BuiltInTools) and the app
    /// lifecycle address the same manager.
    static let shared = ExecSessionManager()

    // MARK: - Pure helpers (test-pinned, no actor hop)

    /// Non-empty-stdin + spawn regime: `yield_ms.clamp(250, 30_000)` —
    /// codex `clamp_yield_time` (mod.rs:203) + `process_manager.rs:830`
    /// `time_ms.min(MAX_YIELD_TIME_MS)` branch.
    static func clampYieldMs(_ ms: Int) -> Int {
        min(max(ms, clampMinYieldMs), clampMaxYieldMs)
    }

    /// Empty-stdin (poll) regime: `yield_ms.clamp(5_000, 300_000)` —
    /// codex `process_manager.rs:828` `clamp(MIN_EMPTY_YIELD_TIME_MS,
    /// max_write_stdin_yield_time_ms)` branch (empty polls use the
    /// background-timeout bounds; non-empty writes keep the 250/30_000
    /// responsive window so interactive stdin stays snappy).
    static func clampEmptyYieldMs(_ ms: Int) -> Int {
        min(max(ms, emptyYieldMinMs), emptyYieldMaxMs)
    }

    /// Head+tail truncation — identical marker to `ExecTools.truncate`.
    static func truncate(_ s: String) -> String {
        if s.count <= maxReportChars { return s }
        let half = maxReportChars / 2
        let head = String(s.prefix(half))
        let tail = String(s.suffix(half))
        return head + "\n[TRUNCATED \(s.count) total; showing first \(half) + last \(half) chars]\n"
            + tail
    }

    static func expandPath(_ p: String) -> String {
        if p == "~" || p.hasPrefix("~/") {
            return NSHomeDirectory() + String(p.dropFirst())
        }
        return p
    }

    // MARK: - Spawn

    struct SpawnResult: Sendable {
        let sessionId: Int
        let completed: Bool
        let report: String
    }

    /// Spawn `command` under `zsh -c`; yield ≤ `yieldMs`; return the first
    /// output delta (full report if the child finished inside the window).
    @discardableResult
    func spawn(command: String, cwd: String? = nil, yieldMs: Int = defaultYieldMs)
        async throws -> SpawnResult
    {
        #if os(macOS)
        await makeRoom()
        let dir = Self.makeSessionDir()
        let outPath = dir.appendingPathComponent("out").path
        let errPath = dir.appendingPathComponent("err").path
        FileManager.default.createFile(atPath: outPath, contents: nil)
        FileManager.default.createFile(atPath: errPath, contents: nil)

        guard
            let outHandle = FileHandle(forWritingAtPath: outPath),
            let errHandle = FileHandle(forWritingAtPath: errPath)
        else {
            try? FileManager.default.removeItem(at: dir)
            throw ToolError.checkFailed("cannot open exec session capture files")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        if let cwd, !cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: Self.expandPath(cwd))
        }
        let stdinPipe = Pipe()
        proc.standardOutput = outHandle
        proc.standardError = errHandle
        proc.standardInput = stdinPipe
        let owner = SessionProc(process: proc, stdinHandle: stdinPipe.fileHandleForWriting)

        do {
            try owner.run()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            owner.closeStdin()
            throw ToolError.executionFailed(error)
        }

        let (outDelta, errDelta, completed, exitCode) = try await runOnBackground {
            try Self.drainBlocking(
                outPath: outPath, errPath: errPath,
                fromOut: 0, fromErr: 0,
                owner: owner, yieldMs: Self.clampYieldMs(yieldMs))
        }

        counter += 1
        let sessionId = counter
        var session = Session(
            command: command,
            stdout: outDelta, stderr: errDelta,
            completed: completed,
            exitCode: exitCode,
            outOffset: Int64(outDelta.utf8.count),
            errOffset: Int64(errDelta.utf8.count),
            dir: dir,
            proc: owner,
            createdAt: Date()
        )
        if completed {
            session = Self.capAccumulations(session)
            Self.finishSession(session)
        } else {
            session = Self.capAccumulations(session)
        }
        sessions[sessionId] = session
        return SpawnResult(sessionId: sessionId, completed: completed, report: report(for: session))
        #else
        _ = (command, cwd, yieldMs)
        throw ToolError.checkFailed(
            "exec_shell is unavailable on iOS (POSIX Process is macOS-only)")
        #endif
    }

    // MARK: - write_stdin / exec_poll

    struct PollResult: Sendable {
        let completed: Bool
        let report: String
    }

    /// `data`: text to write verbatim to the child's stdin pipe (no
    /// implicit newline). Empty `data` ⇒ pure poll — the pipe is never
    /// touched (codex `write_stdin.rs` empty-write semantics).
    @discardableResult
    /// `yieldMs`: codex regime — non-empty `data` clamps to 250–30_000
    /// (default 250, `default_write_stdin_yield_time_ms`=250 in
    /// `unified_exec.rs:64`); empty `data` clamps to 5_000–300_000
    /// (default 5_000) per `process_manager.rs:828`. `nil` = regime default.
    func writeStdin(sessionId: Int, data: String = "", yieldMs: Int? = nil)
        async throws -> PollResult
    {
        let effectiveYieldMs =
            data.isEmpty
            ? Self.clampEmptyYieldMs(yieldMs ?? Self.emptyYieldDefaultMs)
            : Self.clampYieldMs(yieldMs ?? 250)
        #if os(macOS)
        guard var session = sessions[sessionId] else {
            throw ToolError.checkFailed("unknown exec session \(sessionId)")
        }
        if session.completed {
            return PollResult(completed: true, report: report(for: session))
        }

        let owner = session.proc
        if !data.isEmpty {
            let bytes = Data(data.utf8)
            try await runOnBackground { try owner.writeStdin(bytes) }
        }

        let outPath = session.dir.appendingPathComponent("out").path
        let errPath = session.dir.appendingPathComponent("err").path
        let fromOut = session.outOffset
        let fromErr = session.errOffset
        let (outDelta, errDelta, completed, exitCode) = try await runOnBackground {
            try Self.drainBlocking(
                outPath: outPath, errPath: errPath,
                fromOut: fromOut, fromErr: fromErr,
                owner: owner, yieldMs: effectiveYieldMs)
        }

        session.stdout += outDelta
        session.stderr += errDelta
        session.outOffset += Int64(outDelta.utf8.count)
        session.errOffset += Int64(errDelta.utf8.count)
        if completed {
            session.completed = true
            session.exitCode = exitCode
        }
        session = Self.capAccumulations(session)
        if completed {
            Self.finishSession(session)
        }
        sessions[sessionId] = session
        return PollResult(completed: completed, report: report(for: session))
        #else
        _ = (data, yieldMs)
        throw ToolError.checkFailed(
            "write_stdin is unavailable on iOS (POSIX Process is macOS-only)")
        #endif
    }

    /// Pure poll (no stdin write) — the `exec_poll` tool surface.
    /// `yieldMs`: empty-stdin regime (5_000–300_000, default 5_000, nil = default).
    @discardableResult
    func poll(sessionId: Int, yieldMs: Int? = nil) async throws -> PollResult {
        try await writeStdin(sessionId: sessionId, data: "", yieldMs: yieldMs)
    }

    // MARK: - Lifecycle

    /// SIGTERM → 2s grace → SIGKILL; captures the final partial output.
    @discardableResult
    func kill(sessionId: Int) async throws -> String {
        #if os(macOS)
        guard var session = sessions[sessionId] else {
            throw ToolError.checkFailed("unknown exec session \(sessionId)")
        }
        if session.completed {
            return "session \(sessionId) already finished (exit code: \(session.exitCode))"
        }
        let owner = session.proc
        let outPath = session.dir.appendingPathComponent("out").path
        let errPath = session.dir.appendingPathComponent("err").path
        let fromOut = session.outOffset
        let fromErr = session.errOffset
        let ownerProc = owner
        let dir = session.dir
        let delta = try await runOnBackground { () -> (String, String) in
            ownerProc.terminate()
            let deadline = Date(timeIntervalSinceNow: Self.killGraceSeconds)
            while ownerProc.isRunning() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if ownerProc.isRunning() { ownerProc.forceKill() }
            ownerProc.waitUntilExit()
            let out = Self.readTail(after: fromOut, at: outPath)
            let err = Self.readTail(after: fromErr, at: errPath)
            return (
                String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? ""
            )
        }
        _ = dir
        session.stdout += delta.0
        session.stderr += delta.1
        session.completed = true
        session.exitCode = owner.terminationStatus()
        session = Self.capAccumulations(session)
        Self.finishSession(session)
        sessions[sessionId] = session
        return
            "session \(sessionId) terminated (SIGTERM → SIGKILL after \(Int(Self.killGraceSeconds))s grace)"
        #else
        throw ToolError.checkFailed("kill unavailable on iOS (POSIX Process is macOS-only)")
        #endif
    }

    /// Terminate every live session and drop all state (app shutdown path).
    /// - Returns: the number of sessions terminated.
    @discardableResult
    func shutdown() async -> Int {
        #if os(macOS)
        let liveIDs = sessions.keys.filter { sessions[$0]?.completed == false }
        var killed = 0
        for id in liveIDs {
            if (try? await kill(sessionId: id)) != nil { killed += 1 }
        }
        for session in sessions.values where !session.completed {
            Self.finishSession(session)
        }
        sessions.removeAll()
        return killed
        #else
        return 0
        #endif
    }

    // MARK: - Introspection (tests / UI)

    func activeSessions() -> [(id: Int, command: String, completed: Bool, ageSeconds: Int)] {
        sessions.map { id, s in
            (id, s.command, s.completed, Int(Date().timeIntervalSince(s.createdAt)))
        }.sorted { $0.id < $1.id }
    }

    func contains(_ id: Int) -> Bool { sessions[id] != nil }

    // MARK: - Report shape

    /// One contract for both exec surfaces (mirrors `ExecTools.format`):
    /// ```
    /// <stdout (truncated if needed)>
    /// --- stderr ---             (only when stderr non-empty)
    /// <stderr (truncated if needed)>
    /// end of process output
    /// exit code: N               (N = -1 while still running)
    /// ```
    private func report(for session: Session) -> String {
        var parts: [String] = []
        let out = Self.truncate(session.stdout)
        if !out.isEmpty { parts.append(out) }
        let err = Self.truncate(session.stderr)
        if !err.isEmpty {
            parts.append("--- stderr ---")
            parts.append(err)
        }
        parts.append("end of process output")
        parts.append("exit code: \(session.completed ? session.exitCode : -1)")
        return parts.joined(separator: "\n")
    }

    // MARK: - Capacity / eviction

    /// Codex keeps ≤ `MAX_UNIFIED_EXEC_PROCESSES` live. We first drop
    /// finished sessions, then terminate the OLDEST live one if the map is
    /// still at the cap (the model cannot self-extend the cap).
    private func makeRoom() async {
        sessions = sessions.filter { !$0.value.completed }
        guard sessions.values.count >= Self.maxLive else { return }
        let live = sessions.values.map { ($0.createdAt, $0) }.sorted { $0.0 < $1.0 }
        guard let oldest = live.first else { return }
        let oldestProc = oldest.1.proc
        let oldestDir = oldest.1.dir
        do {
            try await runOnBackground { () -> Void in
                oldestProc.terminate()
                let deadline = Date(timeIntervalSinceNow: Self.killGraceSeconds)
                while oldestProc.isRunning() && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if oldestProc.isRunning() { oldestProc.forceKill() }
                oldestProc.waitUntilExit()
                oldestProc.closeStdin()
            }
        } catch {
            // Eviction best-effort: the spawn that asked for the room
            // proceeds; the next `makeRoom` retries.
        }
        try? FileManager.default.removeItem(at: oldestDir)
        sessions = sessions.filter { $0.value.proc !== oldestProc }
    }

    // MARK: - Shared worker primitives

    private static func makeSessionDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai_sessions_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func finishSession(_ session: Session) {
        try? FileManager.default.removeItem(at: session.dir)
        session.proc.closeStdin()
    }

    private static func capAccumulations(_ session: Session) -> Session {
        var s = session
        if s.stdout.count > maxDiskOutputBytes {
            s.stdout = String(s.stdout.prefix(maxDiskOutputBytes))
        }
        if s.stderr.count > maxDiskOutputBytes {
            s.stderr = String(s.stderr.prefix(maxDiskOutputBytes))
        }
        return s
    }

    /// Drain new bytes from both capture files for ≤ `yieldMs`, then
    /// finalize if the child exited. SYNCHRONOUS — only ever called inside
    /// a `@Sendable` background closure (the pinned `ExecTools.runSync`
    /// pattern), so `Thread.sleep` never touches the actor executor.
    private static func drainBlocking(
        outPath: String, errPath: String,
        fromOut: Int64, fromErr: Int64,
        owner: SessionProc, yieldMs: Int
    ) throws -> (outDelta: String, errDelta: String, completed: Bool, exitCode: Int32) {
        var outAcc = Data()
        var errAcc = Data()
        let deadline = Date().addingTimeInterval(TimeInterval(yieldMs) / 1000)
        while true {
            let newOut = readTail(after: fromOut + Int64(outAcc.count), at: outPath)
            if !newOut.isEmpty { outAcc.append(newOut) }
            let newErr = readTail(after: fromErr + Int64(errAcc.count), at: errPath)
            if !newErr.isEmpty { errAcc.append(newErr) }
            if !owner.isRunning() { break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var exitCode = Int32(-1)
        let completed = !owner.isRunning()
        if completed {
            owner.waitUntilExit()
            exitCode = owner.terminationStatus()
        }
        return (
            outDelta: String(data: outAcc, encoding: .utf8) ?? "",
            errDelta: String(data: errAcc, encoding: .utf8) ?? "",
            completed: completed,
            exitCode: exitCode
        )
    }

    /// New bytes appended after byte offset `after` (capped read of 4MB).
    private static func readTail(after: Int64, at path: String) -> Data {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? Int
        else { return Data() }
        let end = Int64(size)
        guard end > after else { return Data() }
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(after))
            let want = Int(min(end - after, Int64(4 * 1024 * 1024)))
            return want > 0 ? handle.readData(ofLength: want) : Data()
        } catch {
            return Data()
        }
    }
}
