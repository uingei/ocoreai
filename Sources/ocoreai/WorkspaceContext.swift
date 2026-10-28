// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// WorkspaceContext — working-directory + project-instruction (AGENTS.md) discovery.
///
/// Baseline: codex `core/src/agents_md.rs` (references/codex, HEAD):
/// - `project_root_markers` default `[".git"]`, walk up from cwd; no marker →
///   only the cwd itself is considered (agents_md.rs:1-16, `agents_md_paths`).
/// - Collect `AGENTS.override.md` / `AGENTS.md` from the project root DOWN to
///     the cwd (inclusive), concatenating in that order (root first).
/// - Per level the override file wins; we read at most one doc per level.
/// - `project_doc_max_bytes` default 32 * 1024, truncating the last doc that
///   exceeds the remaining budget (config_toml.rs:73, agents_md.rs:138-154).
/// - Discovered docs are model-visible instructions (agents_md.rs L74-76).
///
/// ocoreai alignment: the same discovery/order/budget semantics as a pure,
/// sendable value layer under `UserDefaults.standard` key
/// `settings.agent.workspaceDirectory` (written by the Settings UI, read by
/// the server) — no actor seam, callable from nonisolated injection sites.

import Foundation

enum WorkspaceContext {
    /// codex `DEFAULT_PROJECT_DOC_MAX_BYTES` (config/src/config_toml.rs:73).
    static let maxDocBytes = 32 * 1024

    /// codex `default_project_root_markers()` — `.git` (agents_md.rs L14-15).
    static let projectRootMarkers = [".git"]

    /// Per-level candidate filenames, preference order (agents_md.rs:267-281):
    /// `AGENTS.override.md` then `AGENTS.md`.
    static let candidateFilenames = ["AGENTS.override.md", "AGENTS.md"]

    /// Headless anchor: `OCOREAI_WORKSPACE`. A `serve` process has no Settings UI to
    /// write `UserDefaults`, and `SessionWorkspace.setDirectory` is called only from the
    /// UI (`ChatViewModel`, `SessionManager`) — so before this, every relative path a wire
    /// client sent anchored to the *process* cwd, and the model was never told which.
    /// Measured 10-22 (`scripts/eval/`): 5 of 9 task failures were
    /// `edit_file: cannot read (missing or non-UTF8): calc.py` — the natural relative path
    /// a coding prompt produces, resolved somewhere the file was not. Env precedes the
    /// stored setting because a headless operator states it per run.
    static let workspaceEnvironmentKey = "OCOREAI_WORKSPACE"

    static func environmentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[workspaceEnvironmentKey], !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
            isDir.boolValue
        else { return nil }
        return expanded
    }

    /// The workspace directory the operator configured, or nil when unset/invalid.
    /// `OCOREAI_WORKSPACE` first (headless serve, CI), then the shared
    /// `UserDefaults.standard` domain the Settings UI writes, so GUI and server still
    /// see one source of truth and a headless run can state one too.
    static func configuredDirectory(defaults: UserDefaults = .standard) -> String? {
        if let env = environmentDirectory() {
            return env
        }
        guard
            let raw = defaults.string(forKey: settingsKey),
            !raw.isEmpty
        else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
            isDir.boolValue
        {
            return expanded
        }
        return nil
    }

    /// Settings persistence key (single source of truth).
    static let settingsKey = "settings.agent.workspaceDirectory"

    /// Project root: nearest ancestor (from cwd, inclusive) containing any
    /// configured root marker; falls back to the cwd itself when unmarked —
    /// mirroring codex's `find_nearest_ancestor_with_markers` policy.
    /// - Parameter cwd: working directory (absolute, `~` expanded by caller).
    /// - Parameter fm: injectable for tests.
    static func projectRoot(
        cwd: String,
        markers: [String] = projectRootMarkers,
        fm: FileManager = .default
    ) -> String {
        let start = (cwd as NSString).expandingTildeInPath
        var cursor = URL(fileURLWithPath: start).standardizedFileURL
        while true {
            for marker in markers {
                if fm.fileExists(atPath: cursor.appendingPathComponent(marker).path) {
                    return cursor.path
                }
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || parent.path == "/" {
                break
            }
            cursor = parent
        }
        return start
    }

    /// Discovered instruction-file paths in concatenation order: project root
    /// down to the cwd (inclusive), at most one doc per level (override
    /// preferred). Empty when nothing is found along the chain.
    static func instructionFiles(
        cwd: String,
        filenames: [String] = candidateFilenames,
        fm: FileManager = .default
    ) -> [String] {
        let start = (cwd as NSString).expandingTildeInPath
        let startURL = URL(fileURLWithPath: start).standardizedFileURL
        let rootURL = URL(fileURLWithPath: projectRoot(cwd: start, fm: fm)).standardizedFileURL

        // Chain cwd → root, then reverse to root → cwd (codex order).
        var chain: [URL] = []
        var cursor = startURL
        while true {
            chain.append(cursor.standardizedFileURL)
            if cursor.standardizedFileURL == rootURL {
                break
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || parent.path == "/" {
                break
            }
            cursor = parent
        }
        chain.reverse()

        var files: [String] = []
        for dir in chain {
            for name in filenames {
                let candidate = dir.appendingPathComponent(name).standardizedFileURL
                var isDir: ObjCBool = false
                // isDirectory is OUT: true ⇒ it's a dir (skip); a regular file has it false.
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue {
                    files.append(candidate.path)
                    break  // one doc per level (override already read)
                }
            }
        }
        return files
    }

    /// One discovered doc's fate under the byte budget — the single measurement behind
    /// BOTH disclosures (the line the model reads and the row `/v1/capabilities`
    /// publishes), because two homes for one verdict is how a surface ends up claiming
    /// more than the injector did (AGENTS.md invariant 2).
    struct InstructionDoc: Encodable, Equatable, Sendable {
        /// Path exactly as the model sees it — every doc is already headed by it.
        let path: String
        /// Wire label: the same path below the project root, that root written as
        /// `<root>`. `/v1/capabilities` is public (it bypasses `AuthMiddleware`), and an
        /// absolute path is somebody's home directory; `<root>/Engine/AGENTS.md` is just
        /// as actionable for a client deciding whether to trust the instructions.
        let label: String
        let bytesTotal: Int
        let bytesInjected: Int
        /// `whole` | `truncated` | `dropped`. The last two used to be silent.
        let state: String

        /// `path` is deliberately not encoded: it is what the notice needs and what a
        /// public endpoint must not publish. A client that needs the absolute path owns
        /// the workspace and already knows it.
        /// So the row is write-only by design: making it `Decodable` would force the
        /// field back onto the wire or push a defaulted empty path into a measured row.
        private enum CodingKeys: String, CodingKey {
            case label
            case bytesTotal
            case bytesInjected
            case state
        }
    }

    /// What the injector spent of the project-instruction budget, measured off the files
    /// it read. The disclosure itself is borrowed, not invented: deepseek-harness states
    /// the cut inside the injected text and pins the wording as a fixture
    /// (`snapshots/session/agent-instructions-budget/`), and codex at least logs it
    /// (`agents_md.rs:157`, `"project doc exceeds remaining budget; truncating"` at `:164`).
    struct InstructionBudget: Encodable, Equatable, Sendable {
        /// The cap honoured for this assembly (`maxDocBytes` unless a caller passed one).
        let maxBytes: Int
        /// Doc bytes injected; the `working_directory` line is not counted, so this is
        /// comparable with `maxBytes` (counting the header overstated the spend).
        let injectedBytes: Int
        let docCount: Int
        let truncatedDocs: Int
        let droppedDocs: Int
        let docs: [InstructionDoc]
    }

    static let emptyBudget = InstructionBudget(
        maxBytes: maxDocBytes, injectedBytes: 0, docCount: 0, truncatedDocs: 0, droppedDocs: 0,
        docs: [])

    /// One pass over the chain, two consumers: the section to inject and the measurement
    /// of what fell off it. Splitting these into two walkers is what let the prompt and
    /// the wire disagree about the same bytes.
    static func assemble(
        cwd: String,
        maxBytes: Int = maxDocBytes,
        fm: FileManager = .default
    ) -> (section: String, budget: InstructionBudget) {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", emptyBudget) }
        let root = projectRoot(cwd: trimmed, fm: fm)
        var remaining = maxBytes
        var docs: [InstructionDoc] = []
        var bodies: [String] = []
        for path in instructionFiles(cwd: trimmed, fm: fm) {
            // Size first: a doc that never fits the budget is named as dropped without
            // paying to read it. A stat failure skips the doc, exactly as the pre-
            // disclosure code skipped an unreadable one — no new state for a case nobody
            // observed.
            guard let total = fileSize(path, fm) else { continue }
            if remaining <= 0 {
                docs.append(
                    InstructionDoc(
                        path: path, label: wireLabel(path: path, root: root),
                        bytesTotal: total, bytesInjected: 0, state: "dropped"))
                continue
            }
            guard let data = fm.contents(atPath: path) else { continue }
            let slice = data.prefix(remaining)
            remaining -= slice.count
            let text = String(decoding: slice, as: UTF8.self)
            docs.append(
                InstructionDoc(
                    path: path, label: wireLabel(path: path, root: root),
                    bytesTotal: data.count, bytesInjected: slice.count,
                    state: slice.count == data.count ? "whole" : "truncated"))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            bodies.append(path + "\n---\n" + text)
        }
        let budget = InstructionBudget(
            maxBytes: maxBytes,
            injectedBytes: docs.reduce(0) { $0 + $1.bytesInjected },
            docCount: docs.count,
            truncatedDocs: docs.filter { $0.state == "truncated" }.count,
            droppedDocs: docs.filter { $0.state == "dropped" }.count,
            docs: docs)
        var parts: [String] = ["working_directory: \(trimmed)"]
        if let notice = noticeLine(for: budget) { parts.append(notice) }
        parts.append(contentsOf: bodies)
        return ("# Workspace\n" + parts.joined(separator: "\n\n"), budget)
    }

    /// Byte size of a discovered doc, or nil when it cannot be measured.
    private static func fileSize(_ path: String, _ fm: FileManager) -> Int? {
        guard let attributes = try? fm.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// `<root>/…` label for the wire; a path outside the project root falls back to its
    /// last component rather than publishing the absolute path.
    private static func wireLabel(path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return (path as NSString).lastPathComponent }
        return "<root>/" + path.dropFirst(prefix.count)
    }

    /// The line the model reads when something fell off — nil when every doc went in
    /// whole, because a notice that fires on nothing trains a reader to ignore it.
    /// Wording follows the deepseek-harness fixture ("…budget 700 bytes: truncated …
    /// from 1900 to 292 bytes"): the cut is stated in the same text it happens to, so a
    /// truncated rule can never read as a complete one.
    static func noticeLine(for budget: InstructionBudget) -> String? {
        let cuts = budget.docs.filter { $0.state != "whole" }
        guard !cuts.isEmpty else { return nil }
        let clauses = cuts.map { doc in
            doc.state == "truncated"
                ? "truncated \(doc.path) from \(doc.bytesTotal) to \(doc.bytesInjected) bytes"
                : "dropped \(doc.path) (\(doc.bytesTotal) bytes)"
        }
        return "Workspace instruction budget \(budget.maxBytes) bytes: "
            + clauses.joined(separator: "; ")
    }

    /// Assemble the model-visible workspace section for `cwd`: the working
    /// directory line, the budget notice when a doc fell off, then every
    /// discovered project instruction doc (root → cwd), byte-budgeted to
    /// `maxBytes` across all docs (the last doc fitting the remaining budget is
    /// truncated, codex agents_md.rs:148-153). The `working_directory` line is
    /// always present when `cwd` is set — it tells the model where relative paths
    /// and exec_commands land, even when no AGENTS.md exists. Empty string only
    /// for an empty `cwd`.
    static func buildSection(
        cwd: String,
        maxBytes: Int = maxDocBytes,
        fm: FileManager = .default
    ) -> String {
        assemble(cwd: cwd, maxBytes: maxBytes, fm: fm).section
    }

    /// The instruction budget for the same chain the prompt is assembled from, for
    /// `/v1/capabilities`: one resolver, so the wire cannot report a cut the prompt hid
    /// nor hide one the prompt announced.
    static func instructionBudget(
        cwd: String,
        maxBytes: Int = maxDocBytes,
        fm: FileManager = .default
    ) -> InstructionBudget {
        assemble(cwd: cwd, maxBytes: maxBytes, fm: fm).budget
    }
}
