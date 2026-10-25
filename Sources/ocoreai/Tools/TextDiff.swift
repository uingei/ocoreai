// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Line diff for the change-review UI (Bionic-parity inline diffs).
///
/// A minimal, dependency-free LCS line diff: turns `edit_file`
/// old/new strings (and created/deleted files) into line-level
/// additions/removals the SwiftUI layer renders as +/- rows.
/// Capped on purpose — a review surface for model edits, not git.
public struct FileDiff: Codable, Hashable, Sendable {
    public enum Line: Codable, Hashable, Sendable {
        case context(String)
        case added(String)
        case removed(String)
        /// Elided unchanged run (localized at render time).
        case elided(Int)

        public var text: String {
            switch self {
            case .context(let t): return t
            case .added(let t): return t
            case .removed(let t): return t
            case .elided(let n): return "… \(n)"
            }
        }
    }

    public let path: String
    public let lines: [Line]
    public let addedCount: Int
    public let removedCount: Int

    public init(path: String, lines: [Line], addedCount: Int, removedCount: Int) {
        self.path = path
        self.lines = lines
        self.addedCount = addedCount
        self.removedCount = removedCount
    }

    /// New-file creation: everything is added, there is no old side.
    public static func created(path: String, content: String) -> FileDiff {
        let lines =
            content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Line.added(String($0)) }
        return FileDiff(path: path, lines: lines, addedCount: lines.count, removedCount: 0)
    }

    /// File deletion: everything is removed.
    public static func deleted(path: String, content: String) -> FileDiff {
        let lines =
            content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Line.removed(String($0)) }
        return FileDiff(path: path, lines: lines, addedCount: 0, removedCount: lines.count)
    }

    /// LCS diff with size guards: quadratic time/memory, so bail out to a
    /// whole-file replace view past the limit rather than hanging the UI.
    public static func between(
        path: String, old: String, new: String, maxLines: Int = 4000
    ) -> FileDiff {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !a.isEmpty || !b.isEmpty else {
            return FileDiff(path: path, lines: [], addedCount: 0, removedCount: 0)
        }
        if a.count > maxLines || b.count > maxLines {
            // Coarse fallback: show it all as remove+add with honest counts.
            var lines: [Line] = a.map { Line.removed($0) }
            lines += b.map { Line.added($0) }
            return FileDiff(path: path, lines: lines, addedCount: b.count, removedCount: a.count)
        }
        let full = lcs(a, b)
        let added = full.reduce(0) { if case .added = $1 { $0 + 1 } else { $0 } }
        let removed = full.reduce(0) { if case .removed = $1 { $0 + 1 } else { $0 } }
        // Collapse long unchanged middles: keep `context` lines around changes.
        let collapsed = collapse(full, context: 3)
        return FileDiff(
            path: path, lines: collapsed, addedCount: added, removedCount: removed)
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] =
                    a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append(.context(a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(.removed(a[i]))
                i += 1
            } else {
                out.append(.added(b[j]))
                j += 1
            }
        }
        while i < n {
            out.append(.removed(a[i]))
            i += 1
        }
        while j < m {
            out.append(.added(b[j]))
            j += 1
        }
        return out
    }

    /// Keep ±`context` unchanged lines around every change; elide the rest.
    private static func collapse(_ lines: [Line], context: Int) -> [Line] {
        var keep = Array(repeating: false, count: lines.count)
        for (idx, line) in lines.enumerated() {
            if case .context = line { continue }
            let lo = max(0, idx - context)
            let hi = min(lines.count - 1, idx + context)
            for k in lo ... hi { keep[k] = true }
        }
        var out: [Line] = []
        var skipping = 0
        for (idx, line) in lines.enumerated() {
            if keep[idx] {
                if skipping > 0 {
                    out.append(.elided(skipping))
                    skipping = 0
                }
                out.append(line)
            } else {
                skipping += 1
            }
        }
        if skipping > 0 {
            out.append(.elided(skipping))
        }
        return out
    }
}
