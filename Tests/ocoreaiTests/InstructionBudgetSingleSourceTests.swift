// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InstructionBudgetSingleSourceTests.swift — 32 KiB lives in three files; this is what makes it one number.
///
/// The cap is ocoreai policy since 11-03 (owner: codex is no longer an authority), so no checkout outside
/// this repo measures it any more, and the three homes — `WorkspaceContext.maxDocBytes`, B2's
/// `OCOREAI_AGENTS_MAX_CHAIN` in `scripts/agents-md-contract.sh`, the budget sentence at the head of
/// `AGENTS.md` — are hand-copied from one another. Sampled red the same day, in the prose itself: the
/// script's comment cited the constant at `config_toml.rs:77` while `WorkspaceContext`'s header cited it at
/// `:73` — two homes of one decision already disagreeing about where it came from, and nothing went red,
/// because the only cross-check was a sentence. The reader whose action this changes is whoever raises a
/// cap after B2 turns red: the loader and the docs must move together or this suite says so.
///
/// Deliberately reads the files rather than re-declaring the number: asserting `maxDocBytes == 32768`
/// would be a fourth home, and a copy of a constant proves nothing about the copies nobody typed here.

import Foundation
import Testing

@testable import ocoreai

@Suite("instruction budget — the 32 KiB cap has one value and three homes")
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

    /// The digits B2 pins, read off the line that assigns them.
    private static func chainPin(in script: String) -> Int? {
        for line in script.split(separator: "\n") {
            guard let at = line.range(of: "OCOREAI_AGENTS_MAX_CHAIN:=") else { continue }
            return Int(line[at.upperBound...].prefix { $0.isNumber })
        }
        return nil
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

    @Test("the injector, the gate's pin and root's sentence hold the same byte count")
    func threeHomesOneNumber() throws {
        // Each #require is a premise floor: a renamed variable, a reworded head or a refactored
        // assignment must fail here, not silently vacuate the comparison below.
        let pin = try #require(
            Self.chainPin(in: Self.read("scripts/agents-md-contract.sh")),
            "B2 no longer pins OCOREAI_AGENTS_MAX_CHAIN on one line — the scan stopped matching")
        let stated = try #require(
            Self.statedCap(in: Self.read("AGENTS.md")),
            "root's head no longer states the cap as 'at most N KiB'")
        #expect(pin == WorkspaceContext.maxDocBytes)
        #expect(stated == WorkspaceContext.maxDocBytes)
    }
}
