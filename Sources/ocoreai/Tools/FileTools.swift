// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FileTools — real file operations for the agent tool surface.
///
/// Closes the P0 tool-surface gap (direction-audit-2026-08-18, codex borrow
/// points 2026-08-21): the registry whitelist already reserved read_file /
/// search_files and the destructive blacklist reserved write_file, but none
/// were implemented — the surface was placeholder-only (info/skills_*/echo).
///
/// Apply-before-verify (codex apply-patch discipline): write_file compares
/// the bytes it writes against what it re-reads from disk — a successful
/// write call is corroborated, not assumed.
import Foundation

enum FileTools {
    // Bounds — every traversal is resource-bounded.
    static let maxReadBytes = 2_097_152  // 2MB per read
    static let maxWriteBytes = 1_048_576  // 1MB per write
    static let defaultReadLimit = 2000  // lines
    static let maxSearchFileBytes = 65_536  // per-file content scan cap
    static let maxSearchFiles = 500  // files scanned per content search
    static let maxWalkDepth = 5

    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico",
        "mp4", "mov", "m4a", "mp3", "wav", "flac",
        "zip", "gz", "tar", "7z",
        "pdf", "bin", "dylib", "so", "a", "o", "class", "jar",
        "woff", "woff2", "ttf", "otf",
        "sqlite", "db",
    ]

    // MARK: - read_file

    /// Read a text file as numbered `N|line` text.
    /// - Parameters:
    ///   - path: Absolute, `~`-expanded, or cwd-relative path.
    ///   - offset: 1-based first line (default 1).
    ///   - limit: Max lines (default 2000).
    static func read(path: String, offset: Int? = 1, limit: Int? = defaultReadLimit) throws
        -> String
    {
        let url = resolve(path)
        guard let data = try? Data(contentsOf: url, options: .uncached) else {
            throw ToolError.invalidParameter("read_file: cannot read: \(path)")
        }
        guard data.count <= maxReadBytes else {
            throw ToolError.invalidParameter(
                "read_file: file too large (\(data.count) bytes, max \(maxReadBytes)): \(path)")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("\0") else {
            throw ToolError.invalidParameter("read_file: not a text file: \(path)")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let total = lines.count
        guard total > 0 else { return "read_file: empty file: \(path)" }
        let start = max(1, offset ?? 1)
        guard start <= total else {
            throw ToolError.invalidParameter(
                "read_file: offset \(start) exceeds file length (\(total) lines)")
        }
        let end = min(total, start + max(0, limit ?? defaultReadLimit) - 1)
        var out = ""
        for i in start ... end {
            out += "\(i)|\(lines[i - 1].replacingOccurrences(of: "\r", with: ""))\n"
        }
        if end < total {
            out +=
                "─── total_lines: \(total) (window \(start)–\(end); continue at offset=\(end + 1)) ───"
        } else {
            out += "─── total_lines: \(total) (full) ───"
        }
        return out
    }

    // MARK: - write_file

    /// Write (create or replace) a file, then verify by read-back.
    static func write(path: String, content: String) throws -> String {
        let url = resolve(path)
        let bytes = Data(content.utf8)
        guard bytes.count <= maxWriteBytes else {
            throw ToolError.invalidParameter(
                "write_file: content too large (\(bytes.count) bytes, max \(maxWriteBytes))")
        }
        let existingBytes = (try? Data(contentsOf: url, options: .uncached))?.count
        let parent = url.deletingLastPathComponent()
        if parent != URL(fileURLWithPath: "/") {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw ToolError.invalidParameter("write_file: \(error.localizedDescription)")
        }
        // Apply-before-verify: read-back must byte-match what we wrote.
        guard let back = try? Data(contentsOf: url, options: .uncached), back == bytes else {
            throw ToolError.invalidParameter("write_file: read-back verification failed: \(path)")
        }
        let lineCount = content.components(separatedBy: "\n").count
        let verb = existingBytes.map { "replaced \($0) bytes" } ?? "created"
        return
            "write_file: OK — \(bytes.count) bytes, \(lineCount) lines, \(verb), read-back verified (\(path))"
    }

    // MARK: - edit_file

    /// Search-and-replace within a single file (codex apply-patch discipline:
    /// unique match required by default, replacement verified by read-back).
    /// - Parameters:
    ///   - path: File to edit.
    ///   - oldString: Exact text to find. Must occur exactly `occurrences` times.
    ///   - newString: Replacement text (may be empty to delete).
    ///   - occurrences: Expected count of `oldString` in the file (default 1).
    ///     Any other count throws before writing — no partial edits.
    /// - Returns: Verification summary (match count, bytes before/after).
    static func editFile(
        path: String,
        oldString: String,
        newString: String,
        occurrences: Int? = 1
    ) throws -> String {
        let url = resolve(path)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError.invalidParameter(
                "edit_file: cannot read (missing or non-UTF8): \(path)")
        }
        guard !oldString.isEmpty else {
            throw ToolError.invalidParameter("edit_file: oldString must not be empty")
        }
        guard oldString != newString else {
            throw ToolError.invalidParameter("edit_file: oldString == newString (no-op)")
        }
        let expected = max(1, occurrences ?? 1)
        let count = original.components(separatedBy: oldString).count - 1
        guard count == expected else {
            throw ToolError.invalidParameter(
                "edit_file: expected exactly \(expected) occurrence(s) of oldString in \(path), "
                    + "found \(count) — refusing partial edit")
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        let bytes = updated.data(using: .utf8) ?? Data()
        guard bytes.count <= maxWriteBytes else {
            throw ToolError.invalidParameter(
                "edit_file: result too large (\(bytes.count) bytes, max \(maxWriteBytes))")
        }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw ToolError.invalidParameter(
                "edit_file: write failed: \(error.localizedDescription)")
        }
        guard let readBack = try? Data(contentsOf: url, options: .uncached),
            readBack == bytes
        else {
            throw ToolError.invalidParameter("edit_file: read-back verification failed: \(path)")
        }
        let delta = bytes.count - (original.data(using: .utf8)?.count ?? 0)
        return
            "edit_file: OK — \(count) replacement(s), \(delta >= 0 ? "+" : "")\(delta) bytes, "
            + "read-back verified (\(path))"
    }

    // MARK: - search_files

    /// Find files by filename pattern or search file contents.
    /// - Parameters:
    ///   - path: Directory to search (or single file for a direct name check).
    ///   - pattern: Filename mode — `*` glob on the basename. Content mode — substring.
    ///   - target: "files" (default) or "content".
    ///   - limit: Max results (default 50).
    static func search(
        path: String,
        pattern: String,
        target: String? = "files",
        limit: Int? = 50
    ) throws -> String {
        let url = resolve(path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ToolError.invalidParameter("search_files: path not found: \(path)")
        }
        let maxResults = max(1, limit ?? 50)
        let candidates: [URL] = isDir.boolValue ? listFiles(under: url) : [url]

        if (target ?? "files") == "content" {
            var matches: [String] = []
            var scanned = 0
            for candidate in candidates {
                if matches.count >= maxResults || scanned >= maxSearchFiles { break }
                guard !isBinary(candidate) else { continue }
                scanned += 1
                guard let data = try? Data(contentsOf: candidate, options: .uncached),
                    data.count <= maxSearchFileBytes
                else { continue }
                let text = String(decoding: data, as: UTF8.self)
                guard !text.contains("\0"), text.contains(pattern) else { continue }
                matches.append(candidate.path)
            }
            if matches.isEmpty {
                return
                    "search_files: 0 files containing '\(pattern)' under \(path) (scanned \(scanned))"
            }
            return matches.map { "  \($0)" }.joined(separator: "\n")
                + "\n─── total: \(matches.count) (substring in file content) ───"
        }

        var matches: [String] = []
        for candidate in candidates where matches.count < maxResults {
            if globMatch(candidate.lastPathComponent, pattern) {
                matches.append(candidate.path)
            }
        }
        matches.sort()
        if matches.isEmpty {
            return "search_files: 0 files matching '\(pattern)' under \(path)"
        }
        return matches.map { "  \($0)" }.joined(separator: "\n")
            + "\n─── total: \(matches.count) (filename glob) ───"
    }

    // MARK: - Helpers

    /// Resolve a tool-supplied path: `~` expanded; absolute stays; relative anchors to cwd.
    static func resolve(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded)
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Hidden files and VCS/build dirs are skipped; depth-bounded DFS.
    static func listFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        while let (current, depth) = stack.popLast() {
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: current, includingPropertiesForKeys: nil)
            else { continue }
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                var childIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDir)
                else { continue }
                if childIsDir.boolValue {
                    if depth + 1 <= maxWalkDepth {
                        stack.append((child, depth + 1))
                    }
                } else {
                    out.append(child)
                }
            }
        }
        return out
    }

    /// `*` glob over a basename: leading, trailing, both, or exact.
    static func globMatch(_ name: String, _ pattern: String) -> Bool {
        let lead = pattern.hasPrefix("*")
        let trail = pattern.hasSuffix("*")
        var core = pattern
        if lead { core.removeFirst() }
        if trail && core.hasSuffix("*") { core.removeLast() }
        switch (lead, trail) {
        case (false, false): return name == pattern
        case (true, false): return name.hasSuffix(core)
        case (false, true): return name.hasPrefix(core)
        case (true, true): return name.contains(core)
        }
    }

    static func isBinary(_ url: URL) -> Bool {
        if binaryExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return true }
        return data.prefix(1024).contains(0)
    }
}
