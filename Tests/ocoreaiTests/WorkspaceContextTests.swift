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

    @Test("a non-candidate name in the workspace reaches no prompt")
    func nonCandidateNameIsNotDiscovered() throws {
        // `scripts/eval/run.sh` runs an `OCOREAI_EVAL_DOCS_INERT=1` arm that drops a corpus into the
        // workspace under a name discovery ignores, so the board can separate *injection* from mere
        // *presence*. That arm means nothing unless the candidate list is closed, so the two names are
        // pinned here: a future `AGENTS.*` candidate goes red instead of quietly scoring a stray file
        // as if the agent had read instructions.
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        try "inert bytes".write(
            to: root.appendingPathComponent("AGENTS.inert.md"), atomically: true,
            encoding: .utf8)

        #expect(WorkspaceContext.candidateFilenames == ["AGENTS.override.md", "AGENTS.md"])
        #expect(WorkspaceContext.instructionFiles(cwd: root.path).isEmpty)
        #expect(!WorkspaceContext.buildSection(cwd: root.path).contains("inert bytes"))
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

    // MARK: - What the budget disclosure owes (the cut used to be silent)

    @Test("a truncated doc is disclosed to the model with exact bytes")
    func truncationIsDisclosed() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try String(repeating: "x", count: 4096).write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let (section, measured) = WorkspaceContext.assemble(cwd: root.path, maxBytes: 100)
        let doc = try #require(measured.docs.first, "the doc left the measurement")
        #expect(doc.state == "truncated")
        #expect(doc.bytesTotal == 4096)
        #expect(doc.bytesInjected == 100)
        #expect(measured.docCount == 1)
        #expect(measured.truncatedDocs == 1)
        #expect(measured.droppedDocs == 0)
        #expect(measured.injectedBytes == 100)
        // The notice is model-visible, names the doc, and states the exact delta — not
        // "some instructions were shortened".
        #expect(
            section.contains(
                "Workspace instruction budget 100 bytes: truncated "
                    + "\(root.standardizedFileURL.path)/AGENTS.md from 4096 to 100 bytes"))
    }

    @Test("a doc past the budget is named as dropped, never silently skipped")
    func droppedDocIsNamed() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try String(repeating: "a", count: 200).write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "inner rule".write(
            to: inner.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let (section, measured) = WorkspaceContext.assemble(cwd: inner.path, maxBytes: 200)
        #expect(measured.docCount == 2)
        #expect(measured.injectedBytes == 200)
        #expect(measured.truncatedDocs == 0)
        #expect(measured.droppedDocs == 1)
        let dropped = try #require(measured.docs.last, "the inner doc left the measurement")
        #expect(
            (dropped.state, dropped.label, dropped.bytesTotal)
                == ("dropped", "<root>/inner/AGENTS.md", 10))
        #expect(!section.contains("inner rule"))
        #expect(
            section.contains(
                "dropped \(inner.standardizedFileURL.path)/AGENTS.md (10 bytes)"))
    }

    @Test("whole docs produce no notice (a false alarm trains a reader to ignore it)")
    func wholeDocsProduceNoNotice() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "answer plainly".write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let section = WorkspaceContext.buildSection(cwd: root.path)
        let measured = WorkspaceContext.instructionBudget(cwd: root.path)
        #expect(measured.docCount == 1)
        #expect(measured.docs.first?.state == "whole")
        #expect(WorkspaceContext.noticeLine(for: measured) == nil)
        #expect(!section.contains("instruction budget"))
    }

    @Test("the encoded row keeps every byte figure and publishes no absolute path")
    func wireRowKeepsBytesRedactsPaths() throws {
        let root = Self.makeSandbox()
        defer { Self.cleanup(root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try String(repeating: "b", count: 512).write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "gone".write(
            to: inner.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let measured = WorkspaceContext.instructionBudget(cwd: inner.path, maxBytes: 300)
        let payload = try JSONEncoder().encode(measured)
        let json = String(decoding: payload, as: UTF8.self)
        // Field names are the contract a client reads (camelCase, per `/v1/capabilities`).
        for key in [
            "maxBytes", "injectedBytes", "docCount", "truncatedDocs", "droppedDocs", "label",
            "bytesTotal", "bytesInjected", "state",
        ] {
            #expect(json.contains("\"\(key)\":"), "wire field \(key) left the payload: \(json)")
        }
        // Read back what a client's parser sees (the encoder escapes `/`), so these are
        // exact-value assertions on the row rather than on an escaped string. The row is
        // parsed, not decoded: `InstructionDoc` is write-only, and a decoded copy would
        // need a `path` field this surface refuses to publish.
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any],
            "payload is not a JSON object: \(json)")
        #expect(object["maxBytes"] as? Int == 300)
        #expect(object["injectedBytes"] as? Int == 300)
        #expect(object["docCount"] as? Int == 2)
        #expect(object["truncatedDocs"] as? Int == 1)
        #expect(object["droppedDocs"] as? Int == 1)
        let rows = try #require(object["docs"] as? [[String: Any]], "docs is not an array")
        #expect(rows.count == 2)
        #expect(
            rows.map { $0["label"] as? String }
                == ["<root>/AGENTS.md", "<root>/inner/AGENTS.md"])
        #expect(rows.map { $0["state"] as? String } == ["truncated", "dropped"])
        #expect(rows.map { $0["bytesTotal"] as? Int } == [512, 4])
        #expect(rows.map { $0["bytesInjected"] as? Int } == [300, 0])
        // `/v1/capabilities` is public: an absolute path here would be somebody's home
        // directory, so `path` never reaches the wire (escaped or not).
        #expect(rows.allSatisfy { $0["path"] == nil })
        #expect(!json.contains("\"path\""))
        #expect(!json.contains(root.path))
        #expect(!json.contains(root.path.replacingOccurrences(of: "/", with: "\\/")))
        #expect(!json.contains(inner.path.replacingOccurrences(of: "/", with: "\\/")))
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
        let file = dir.appendingPathComponent("afile")  // codespell:ignore
        FileManager.default.createFile(atPath: file.path, contents: Data())
        store.set(file.path, forKey: key)
        #expect(WorkspaceContext.configuredDirectory(defaults: store) == nil)

        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
