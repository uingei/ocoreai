// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SessionWorkspaceWorktreeTests — codex Agent-axis worktree-session seam gate.
///
/// Baseline: codex `core/worktree/src/git.rs:98-135` (`default_worktree_base`,
/// no fetch) + `core/worktree/src/lib.rs` (`worktree add --detach <sha>`) + TUI
/// `worktree_startup` (retain + report on failure).
///
/// Coverage (exact-value assertions, real git in a temp repo):
/// - active-directory pointer: set/get/clear round-trip
/// - consumer precedence: `ExecTools.effectiveCwd` (explicit cwd > session > global)
/// - happy path: detached worktree created at the resolved default-branch sha,
///   bound to the active session, worktree root carries its own `.git`
/// - negative: not a repository → `notARepository`
/// - negative: repo without a resolvable default branch → `noDefaultBranch`
///
/// All tests share the one process-global `ActiveDirectory` pointer, so the
/// suite is `.serialized` (a `SessionWorkspace.setDirectory` in one test must
/// not race a `clear()` in a concurrent test — swift-testing runs suites in
/// parallel by default, which is what broke the cross-suite precedence test).
import Foundation
import Testing

@testable import ocoreai

// Real git probe for the tests, mirroring the repo's `ModelStoreTests`
// `setenv`/`defer unsetenv` convention. `sh` asserts success; `shOut` returns
// stdout (or throws on failure) — but a *quiet* read (`... --quiet`) that
// fails cleanly returns an empty string instead of throwing, which is exactly
// how `git symbolic-ref --quiet HEAD` signals "detached HEAD".
private enum GitProbe {
    struct GitError: Error, CustomStringConvertible {
        let cmd: String
        let dir: String
        var description: String { "\(cmd) failed in \(dir)" }
    }

    static func sh(_ cmd: String, in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw GitError(cmd: cmd, dir: dir) }
    }

    /// Run `git args` and return trimmed stdout. Throws `GitError` on nonzero
    /// exit, *unless* `allowNonZero` is set (used for `--quiet` probes).
    static func shOut(_ args: [String], in dir: String, allowNonZero: Bool = false) throws -> String
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 && !allowNonZero {
            throw GitError(cmd: "git \(args.joined(separator: " "))", dir: dir)
        }
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite("SessionWorkspace — pointer + consumer precedence", .serialized)
struct SessionWorkspacePointerTests {

    @Test("set → get round-trip, clear → nil")
    func pointerRoundTrip() {
        defer { SessionWorkspace.clear() }
        SessionWorkspace.setDirectory("/tmp/probe-ws-1")
        #expect(SessionWorkspace.currentDirectory() == "/tmp/probe-ws-1")
        SessionWorkspace.setDirectory("/tmp/probe-ws-2")
        #expect(SessionWorkspace.currentDirectory() == "/tmp/probe-ws-2")
        SessionWorkspace.clear()
        #expect(SessionWorkspace.currentDirectory() == nil)
    }

    @Test("effectiveCwd: explicit cwd wins over the session pointer")
    func explicitCwdWins() {
        defer { SessionWorkspace.clear() }
        SessionWorkspace.setDirectory("/tmp/session-dir")
        #expect(ExecTools.effectiveCwd("/tmp/explicit") == "/tmp/explicit")
    }

    @Test("effectiveCwd: session pointer above the global workspace")
    func sessionPointerAboveGlobal() {
        defer {
            SessionWorkspace.clear()
            UserDefaults.standard.set(nil, forKey: WorkspaceContext.settingsKey)
        }
        // `configuredDirectory()` validates the path exists on disk (an invalid
        // global must not become the process cwd) — so the fixture is real.
        let globalWS = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ws-global-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(
            atPath: globalWS, withIntermediateDirectories: true)
        let saved = UserDefaults.standard.string(forKey: WorkspaceContext.settingsKey)
        UserDefaults.standard.set(globalWS, forKey: WorkspaceContext.settingsKey)
        SessionWorkspace.setDirectory("/tmp/session-dir")
        #expect(ExecTools.effectiveCwd(nil) == "/tmp/session-dir")
        SessionWorkspace.clear()
        #expect(ExecTools.effectiveCwd(nil) == globalWS)
        // restore the saved global exactly
        if let saved {
            UserDefaults.standard.set(saved, forKey: WorkspaceContext.settingsKey)
        } else {
            UserDefaults.standard.set(nil, forKey: WorkspaceContext.settingsKey)
        }
        try? FileManager.default.removeItem(atPath: globalWS)
    }
}

@Suite("SessionWorkspace — codex worktree creation (real git)", .serialized)
struct SessionWorkspaceWorktreeTests {

    // Per-test isolated worktree base (the service honors the `worktreeRoot`
    // parameter directly — deterministic, no env dependency).
    private func tempBase() -> String {
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ocoreai_wt_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func ensureRepo(_ base: String, _ name: String) throws -> String {
        let root = (base as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: (root as NSString).appendingPathComponent("hello.txt"), contents: Data())
        try GitProbe.sh(
            "git init -q -b main && git config user.email t@t.local && git config user.name t && git add -A && git commit -q -m init",
            in: root)
        return root
    }

    @Test("not a repository → notARepository")
    func notARepo() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let plain = (base as NSString).appendingPathComponent("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        do {
            _ = try await SessionWorkspace.createWorktreeSession(
                repoRoot: plain, worktreeRoot: base)
            #expect(false, "should have thrown notARepository")
        } catch let e as SessionWorkspace.WorktreeError {
            #expect(e.errorDescription?.contains(plain) == true)
        } catch {
            Issue.record("expected notARepository, got \(error)")
        }
    }

    @Test("no resolvable default branch → noDefaultBranch")
    func noDefaultBranch() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let repo = (base as NSString).appendingPathComponent("nobranch")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        // A `feature`-default repo: no remote, no main/master → no resolvable
        // default branch (verified by: `symbolic-ref origin/HEAD` and
        // `rev-parse main|master` both fail on a fresh `feature`-branch clone).
        try GitProbe.sh(
            "git init -q -b feature && git config user.email t@t.local && git config user.name t",
            in: repo)
        FileManager.default.createFile(
            atPath: (repo as NSString).appendingPathComponent("f"), contents: Data())
        try GitProbe.sh("git add -A && git commit -q -m x", in: repo)

        do {
            _ = try await SessionWorkspace.createWorktreeSession(
                repoRoot: repo, worktreeRoot: base)
            #expect(false, "should have thrown noDefaultBranch")
        } catch let e as SessionWorkspace.WorktreeError {
            #expect(e.errorDescription?.contains(repo) == true)
        } catch {
            Issue.record("expected noDefaultBranch, got \(error)")
        }
    }

    @Test("happy path: detached worktree at default-branch sha, bound to session")
    func happyPath() async throws {
        let base = tempBase()
        defer {
            try? FileManager.default.removeItem(atPath: base)
            SessionWorkspace.clear()
        }

        let repo = try ensureRepo(base, "src")
        let created = try await SessionWorkspace.createWorktreeSession(
            repoRoot: repo, worktreeRoot: base)

        // Bound to the active session pointer, then cleared.
        #expect(SessionWorkspace.currentDirectory() == created.root)
        SessionWorkspace.clear()
        #expect(SessionWorkspace.currentDirectory() == nil)

        // The worktree root is its own repo, distinct from the source repo.
        #expect(
            FileManager.default.fileExists(
                atPath: (created.root as NSString).appendingPathComponent(".git")))
        #expect(created.root != repo)

        // HEAD equals the source main commit (detached at resolved base sha).
        let srcSha = try GitProbe.shOut(["rev-parse", "main^{commit}"], in: repo)
        let wtSha = try GitProbe.shOut(["rev-parse", "HEAD"], in: created.root)
        #expect(srcSha == wtSha)

        // Detached: no symbolic HEAD for the worktree (codex `--detach`).
        // `symbolic-ref --quiet HEAD` exits 1 (nonzero) and prints nothing when
        // detached — exactly the "quiet failure = not on a branch" contract.
        let ref = try GitProbe.shOut(
            ["symbolic-ref", "--quiet", "HEAD"], in: created.root,
            allowNonZero: true)
        #expect(ref.isEmpty)

        // Clean up the created tree (it sits under the isolated base).
        try GitProbe.sh("git worktree remove --force \(created.root)", in: repo)
    }
}
