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

    /// The workspace directory the user configured, or nil when unset/invalid.
    /// Read from the shared `UserDefaults.standard` domain so the Settings UI
    /// (same executable) and the server process see one source of truth.
    static func configuredDirectory(defaults: UserDefaults = .standard) -> String? {
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

    /// Assemble the model-visible workspace section for `cwd`: the working
    /// directory line followed by every discovered project instruction doc
    /// (root → cwd), byte-budgeted to `maxBytes` across all docs (the last
    /// doc fitting the remaining budget is truncated, codex agents_md.rs:148-153).
    /// The `working_directory` line is always present when `cwd` is set — it
    /// tells the model where relative paths and exec_commands land, even when
    /// no AGENTS.md exists. Empty string only for an empty `cwd`.
    static func buildSection(
        cwd: String,
        maxBytes: Int = maxDocBytes,
        fm: FileManager = .default
    ) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let files = instructionFiles(cwd: trimmed, fm: fm)
        var remaining = maxBytes
        var parts: [String] = ["working_directory: \(trimmed)"]
        for path in files where remaining > 0 {
            guard let data = try? fm.contents(atPath: path) else { continue }
            let slice = data.prefix(remaining)
            remaining -= slice.count
            let text = String(decoding: slice, as: UTF8.self)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            parts.append(path + "\n---\n" + text)
        }
        return "# Workspace\n" + parts.joined(separator: "\n\n")
    }
}
