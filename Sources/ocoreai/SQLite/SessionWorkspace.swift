// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SessionWorkspace — per-session working-directory seam (session ↔ workspace isolation).
///
/// Baseline: codex Agent axis (references/codex, HEAD) — a session is bound to an
/// isolated working tree:
///   - `core/worktree/src/lib.rs` `WorktreeManager::create` — `worktree add
///     --detach` at the resolved HEAD sha; root allocated outside the source repo.
///   - `core/worktree/src/git.rs:98-135` `default_worktree_base` — resolve the
///     cached default branch: remote-HEAD first, then `main`, then `master`
///     (origin-tracking refs before local). **No fetch** — the cached default only.
///   - TUI `worktree_startup.rs` — a blank session is bound in the new worktree; on
///     startup failure **retain the checkout and report its path** for manual
///     `git worktree remove`.
///
/// ocoreai seam: `currentDirectory()` is the top level of the same chain the
/// existing keyless consumers already read — `MessageBuilder` (system-prompt
/// `working_directory` + AGENTS.md discovery), `ExecTools.effectiveCwd`,
/// `FileTools.resolve` — falling back to the configured global directory
/// (`WorkspaceContext.configuredDirectory()`). That is what actually lands in the
/// session's `exec_command` / file tools, so the isolation is behavioral, not just
/// a prompt line.
///
/// Concurrency (Swift 6, tools-version 6.2, `.swiftLanguageMode(.v6)`):
/// the active directory is held by a `final class` singleton behind an `NSLock`
/// (`@unchecked Sendable`) — the `SessionProc` (`ExecSessions.swift`) /
/// `StreamOutputFilter` idiom — so a captured `@Sendable` closure touching the
/// git worker queue and the UI both see lock-bounded access to shared state.
import Foundation

enum SessionWorkspace {
    // MARK: - Active session directory (atomic, lock-guarded singleton)

    /// `@unchecked Sendable`: every mutable touch (`_directory`) is
    /// `NSLock`-bounded and the instance outlives the process — the same
    /// idiom as `StreamOutputFilter` / `SessionProc` (`ExecSessions.swift`).
    private final class ActiveDirectory: @unchecked Sendable {
        static let shared = ActiveDirectory()
        private let lock = NSLock()
        private var _directory: String?

        func set(_ directory: String?) {
            lock.lock()
            _directory = directory
            lock.unlock()
        }
        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return _directory
        }
    }

    /// The active session's working directory, or nil (→ global fallback).
    static func currentDirectory() -> String? {
        ActiveDirectory.shared.get()
    }

    /// Set (or clear with nil) the active session's working directory.
    static func setDirectory(_ dir: String?) {
        ActiveDirectory.shared.set(dir)
    }

    /// Clear on conversation reset — a reset chat must not keep a previous
    /// session's worktree as its working directory.
    static func clear() {
        setDirectory(nil)
    }

    // MARK: - codex worktree session creation

    struct WorktreeSession: Sendable {
        let root: String  // absolute worktree root (the session working directory)
        let sourceRoot: String  // the source repository root
        let baseRef: String  // the resolved cached default-branch ref
    }

    enum WorktreeError: Error, LocalizedError {
        case notARepository(String)
        case noDefaultBranch(String)
        case gitFailed(step: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .notARepository(let path):
                return "Not a git repository: \(path)"
            case .noDefaultBranch(let path):
                return "No resolvable default branch (remote HEAD / main / master) at \(path)"
            case .gitFailed(let step, let detail):
                return "git step failed at \(step): \(detail)"
            }
        }
    }

    /// Create a detached worktree from the repo's cached default branch (codex
    /// order, no fetch) and bind the active session to it. Any base is honored:
    /// `worktreeRoot` parameter (deterministic — used by tests), else the
    /// `OCOREAI_WORKTREE_ROOT` env override, else `~/ocoreai-worktrees`. On failure
    /// any partially created checkout is retained and its path is reported (codex
    /// `worktree_startup`), so it can be cleaned with `git worktree remove`.
    static func createWorktreeSession(
        repoRoot: String? = nil,
        worktreeRoot: String? = nil
    ) async throws -> WorktreeSession {
        let result = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<WorktreeSession, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(
                        returning: try Self.run(repoRoot: repoRoot, worktreeRoot: worktreeRoot))
                } catch { cont.resume(throwing: error) }
            }
        }
        setDirectory(result.root)
        return result
    }

    // MARK: - create (background queue; git via Process)

    private static func run(repoRoot: String?, worktreeRoot: String?) throws -> WorktreeSession {
        let start =
            ((repoRoot ?? FileManager.default.currentDirectoryPath)
            as NSString).expandingTildeInPath
        guard let sourceRoot = gitRoot(containing: start) else {
            throw WorktreeError.notARepository(start)
        }
        // codex `default_worktree_base`: cached default, no fetch.
        guard let baseRef = defaultBase(in: sourceRoot) else {
            throw WorktreeError.noDefaultBranch(sourceRoot)
        }
        // codex `lib.rs`: rev-parse the ref to a commit, then `worktree add
        // --detach` — a detached tree so the session does not move a tracked branch.
        let rev = baseRef + "^{commit}"
        guard let sha = gitOut(["rev-parse", "--verify", "--end-of-options", rev], in: sourceRoot)
        else {
            throw WorktreeError.gitFailed(step: "rev-parse", detail: baseRef)
        }
        // Root OUTSIDE the source repo (codex allocates under a managed root) so a
        // session's own file listing / AGENTS.md discovery never sees the sibling.
        // `OCOREAI_WORKTREE_ROOT` overrides the base for tests (defaults to
        // `~/ocoreai-worktrees`).
        let placeBase =
            ((worktreeRoot
            ?? ProcessInfo.processInfo.environment["OCOREAI_WORKTREE_ROOT"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("ocoreai-worktrees"))
            as NSString).expandingTildeInPath
        let repoName = (sourceRoot as NSString).lastPathComponent
        let root = (placeBase as NSString)
            .appendingPathComponent("\(repoName)-\(UUID().uuidString.prefix(6))")
        let parent = (root as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let add = try git(["worktree", "add", "--detach", root, sha], in: sourceRoot)
        if add.exitCode != 0 {
            throw WorktreeError.gitFailed(step: "worktree add", detail: add.stderr)
        }
        return WorktreeSession(root: root, sourceRoot: sourceRoot, baseRef: baseRef)
    }

    // MARK: - git primitives

    /// Nearest ancestor (inclusive) containing `.git` — codex `repository_root`,
    /// `WorkspaceContext.projectRoot` marker parity.
    private static func gitRoot(containing start: String) -> String? {
        var cursor = URL(fileURLWithPath: (start as NSString).expandingTildeInPath)
            .standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                return cursor.path
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || parent.path == "/" { return nil }
            cursor = parent
        }
    }

    /// codex `default_worktree_base` order — first ref that resolves (no fetch):
    /// 1) remote HEAD (`refs/remotes/<origin>/HEAD` symref target),
    /// 2) origin `main`, 3) local `main`, 4) origin `master`, 5) local `master`.
    private static func defaultBase(in dir: String) -> String? {
        let remoteHead = gitOut(
            ["symbolic-ref", "--quiet", "--end-of-options", "refs/remotes/origin/HEAD"], in: dir)
        if let remoteHead, !remoteHead.isEmpty { return remoteHead }
        for cand in [
            "refs/remotes/origin/main", "refs/heads/main",
            "refs/remotes/origin/master", "refs/heads/master",
        ] {
            if gitOut(["rev-parse", "--verify", "--quiet", "--end-of-options", cand], in: dir)
                != nil
            {
                return cand
            }
        }
        return nil
    }

    private static func gitOut(_ args: [String], in dir: String) -> String? {
        let r = try? git(args, in: dir)
        return (r?.exitCode == 0) ? r?.stdout : nil
    }

    /// Run a git command, capturing stdout/stderr to temp files (killed children
    /// cannot deadlock us — `ExecTools.runSync` pattern).
    private static func git(
        _ args: [String], in dir: String
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai_wt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let outURL = tmp.appendingPathComponent("out")
        let errURL = tmp.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
            let errHandle = FileHandle(forWritingAtPath: errURL.path)
        else {
            throw WorktreeError.gitFailed(step: "temp-file", detail: outURL.path)
        }
        proc.standardOutput = outHandle
        proc.standardError = errHandle
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: tmp)
        return (
            proc.terminationStatus, stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
