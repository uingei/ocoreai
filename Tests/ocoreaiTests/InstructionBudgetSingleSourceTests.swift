// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InstructionBudgetSingleSourceTests.swift, 32 KiB lives in two files; this is what makes it one number.
///
/// The cap is ocoreai policy since 11-03 (owner: codex is no longer an authority), so no checkout outside
/// this repo measures it; the two homes, `WorkspaceContext.maxDocBytes` and the budget sentence at the
/// head of `AGENTS.md`. Are hand-copied from one another. Sampled red 11-03 in the prose itself: two
/// comments citing the origin disagreed about the line, and nothing went red because the only cross-check
/// was a sentence. The third home. The docs contract's `OCOREAI_AGENTS_MAX_CHAIN` pin. Retired 11-16
/// with the bespoke docs gates (owner ruling after reading the consumed trees); this suite is now the
/// whole of the cross-check, which is the field shape: a code-grep, not a prose scanner. The reader
/// whose action this changes is whoever raises the cap: the loader and the docs must move together.
///
/// Deliberately reads the files rather than re-declaring the number: asserting `maxDocBytes == 32768`
/// would be a third home, and a copy of a constant proves nothing about the copies nobody typed here.

import Foundation
import Testing

@testable import ocoreai

@Suite("instruction budget — the 32 KiB cap has one value and two homes")
struct InstructionBudgetSingleSourceTests {

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private static func read(_ relative: String) throws -> String {
        try String(
            contentsOf: try repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// The cap root states in prose, converted from the KiB it is written in.
    private static func statedCap(in doc: String) -> Int? {
        for line in doc.split(separator: "\n") {
            guard let at = line.range(of: "at most "), line.contains("KiB") else { continue }
            guard let kib = Int(line[at.upperBound...].prefix { $0.isNumber }) else { continue }
            return kib * 1024
        }
        return nil
    }

    @Test("the injector and root's sentence hold the same byte count")
    func twoHomesOneNumber() throws {
        // #require is a premise floor: a reworded head must fail here, not silently vacuate
        // the comparison below.
        let stated = try #require(
            Self.statedCap(in: Self.read("AGENTS.md")),
            "root's head no longer states the cap as 'at most N KiB'")
        #expect(stated == WorkspaceContext.maxDocBytes)
    }
}
