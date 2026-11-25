// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// RepoSourceScan. One home for reading a repo source file from a test, walked up from #filePath.
// Scan-based gates share it so a moved test directory breaks one helper, not every scanner's hop
// count (AGENTS.md: a scan finds its root by searching, not by fixed path hops).

import Foundation

enum RepoSourceScan {

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    /// Reads `relative` from the repo root, which is found by walking up until it exists.
    static func source(_ relative: String, from testFile: String = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: testFile).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    static func count(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).count
    }
}
