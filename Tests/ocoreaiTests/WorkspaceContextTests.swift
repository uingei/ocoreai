import Foundation
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// WorkspaceContextTests — workspace + AGENTS.md discovery contract gate.
///
/// Aligned with the codex `core/src/agents_md.rs` baseline (references/codex,
/// HEAD): root discovery (`.git` marker, no-marker → cwd only), root→cwd
/// ordering, per-level `AGENTS.override.md` preference, byte-budget
/// truncation (codex DEFAULT_PROJECT_DOC_MAX_BYTES = 32 * 1024).
import Testing

@testable import ocoreai

@Suite("WorkspaceContext — codex agents_md alignment")
struct WorkspaceContextTests {

    // Unique temp sandbox per test run.
    private static func makeSandbox() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai_wstest_\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Root discovery

    @Test("project root = nearest ancestor with .git")
    func projectRootFindsGitAncestor() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        let marker = root.appendingPathComponent(".git")
        let inner = root.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let found = WorkspaceContext.projectRoot(cwd: inner.path)
        #expect(found == root.standardizedFileURL.path)
    }

    @Test("no .git marker → root is the cwd itself (codex fallback)")
    func projectRootFallsBackToCwd() throws {
        let sandbox = Self.makeSandbox()
        defer { Self.cleanup(sandbox) }
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("plain"), withIntermediateDirectories: true)

        let found = WorkspaceContext.projectRoot(cwd: sandbox.path)
        #expect(found == sandbox.standardizedFileURL.path)
    }

    @Test("root walk never crosses the .git boundary upward")
    func projectRootStopsAtRoot() throws {
        let outer = Self.makeSandbox()
        defer { Self.cleanup(outer) }
        // Outer dir has a different (higher) .git that must NOT be reached:
        let innerRoot = outer.appendingPathComponent("repo")
        let innerCwd = innerRoot.appendingPathComponent("work")
        try FileManager.default.createDirectory(
            at: outer.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: innerRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: innerCwd, withIntermediateDirectories: true)

        let found = WorkspaceContext.projectRoot(cwd: innerCwd.path)
        #expect(found == innerRoot.standardizedFileURL.path)
    }

    // MARK: - AGENTS.md discovery + ordering

    @Test("AGENTS.md at root and cwd — root first, cwd last")
    func instructionFilesRootToCwdOrder() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        let cwd = root.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try "root doc".write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true,
            encoding: .utf8)
        try "leaf doc".write(
            to: cwd.appendingPathComponent("AGENTS.md"), atomically: true,
            encoding: .utf8)

        let files = WorkspaceContext.instructionFiles(cwd: cwd.path)
        #expect(files.count == 2)
        // Exact order: root doc precedes cwd doc.
        #expect(files.first == root.appendingPathComponent("AGENTS.md").standardizedFileURL.path)
        #expect(files.last == cwd.appendingPathComponent("AGENTS.md").standardizedFileURL.path)
    }

    @Test("AGENTS.override.md wins over AGENTS.md at the same level")
    func overrideFilePreferred() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "normal".write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true,
            encoding: .utf8)
        try "override".write(
            to: root.appendingPathComponent("AGENTS.override.md"), atomically: true,
            encoding: .utf8)

        let files = WorkspaceContext.instructionFiles(cwd: root.path)
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix("AGENTS.override.md") == true)
    }

    @Test("empty directory chain → no files (codex Ok(None))")
    func noDocsEmpty() {
        let sandbox = Self.makeSandbox()
        defer { Self.cleanup(sandbox) }
        let files = WorkspaceContext.instructionFiles(cwd: sandbox.path)
        #expect(files.isEmpty)
    }

    // MARK: - buildSection

    @Test("buildSection injects working_directory line + docs")
    func buildSectionComposes() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        try "always answer with TOKEN-42".write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let section = WorkspaceContext.buildSection(cwd: root.path)
        #expect(section.hasPrefix("# Workspace\n"))
        #expect(section.contains("working_directory: \(root.standardizedFileURL.path)"))
        #expect(section.contains("TOKEN-42"))
        // Doc path + content marker present (model-visible, per codex L74-76).
        #expect(section.contains("AGENTS.md"))
    }

    @Test("buildSection empty cwd → empty string (nothing to inject)")
    func buildSectionEmptyCwd() {
        #expect(WorkspaceContext.buildSection(cwd: "") == "")
    }

    @Test("byte budget truncates the last doc (codex max_bytes semantics)")
    func buildSectionTruncatesToBudget() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        // A doc larger than the maxBytes budget must be truncated to it.
        try String(repeating: "x", count: 4096).write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let budget = 100
        let section = WorkspaceContext.buildSection(cwd: root.path, maxBytes: budget)
        // Measure ONLY the doc body (after the first `---`) — the working_directory
        // line and the file path can contain 'x' and must not count against the
        // doc byte budget (counting them over-stated the truncated size).
        let body = section.split(separator: "\n---\n").last.map(String.init) ?? ""
        let xCount = body.filter { $0 == "x" }.count
        // Doc truncated to exactly the budget (4096 > 100, so it hit the cap).
        #expect(xCount == budget)
        #expect(xCount < 4096)
    }

    @Test("configuredDirectory: missing → nil; existing → path (UserDefaults contract)")
    func configuredDirectoryContract() throws {
        let suite = "ws_test_\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let store = UserDefaults(suiteName: suite)!
        let key = WorkspaceContext.settingsKey

        // Unset → nil.
        #expect(WorkspaceContext.configuredDirectory(defaults: store) == nil)

        // Set directory → returned expanded.
        let dir = Self.makeSandbox()
        defer { Self.cleanup(dir) }
        store.set(dir.path, forKey: key)
        #expect(WorkspaceContext.configuredDirectory(defaults: store) == dir.path)

        // Set non-directory → rejected (key absent → configuredDirectory nil).
        store.removeObject(forKey: key)
        let file = dir.appendingPathComponent("afile")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        store.set(file.path, forKey: key)
        #expect(WorkspaceContext.configuredDirectory(defaults: store) == nil)

        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
