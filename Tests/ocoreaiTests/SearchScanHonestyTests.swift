// Copyright © 2026 uingei.
// Licensed under MIT.
/// SearchScanHonestyTests.swift — `search_files` may not report a scan it did not run.
///
/// A walk that silently skipped an unreadable directory made every negative answer a
/// complete-scan claim. Absorbs the codex #57186 axis (fail closed on unreadable search
/// roots): a blocked root is a refusal naming the OS reason, and a partial walk says so.
///
/// The second face of the same rule, added 11-03: a search that *stopped* — at the result limit —
/// may not label the count it stopped at as a total. The field calls it `truncated`/`total`
/// (deepseek-harness `docs/subsystems/tools.md:623`, codex `message-board/src/types.rs:23-30`,
/// pi `coding-agent/src/core/bash-executor.ts:28-35`); here it is one line of prose, and the prose
/// is what a checkpoint reads before deciding whether to narrow its query.
///
/// The unreadable premise is asserted, not assumed — a host that ignores mode bits would
/// otherwise turn every expectation here into a vacuous pass.
import Foundation
import Testing

@testable import ocoreai

@Suite("search_files reports the scan it actually performed")
struct SearchScanHonestyTests {
    private let fm = FileManager.default
    private var root: URL = URL(fileURLWithPath: "/tmp")

    private static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer).map { String(cString: $0) } ?? path
    }

    init() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("scanhonesty_\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        // Re-anchor on the OS's canonical path: a walk hands back realpath-shaped paths
        // (/private/var/…), and Foundation's own resolvers strip /private rather than
        // add it, so only realpath puts both sides of an assertion in the same voice.
        root = URL(fileURLWithPath: Self.canonical(base.path))
        try "top-level needle".write(
            to: base.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
    }

    /// Make `dir` unreadable for this process, and hand back whether the OS really refused.
    private func block(_ dir: URL) throws -> Bool {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) == nil
    }

    /// Restore mode bits so the tree stays deletable — `#expect` records, it does not
    /// throw, so every test reaches this line.
    private func unblock(_ dir: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    }

    private func seedLockedSubtree(named name: String) throws -> URL {
        let locked = root.appendingPathComponent(name)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try "buried needle".write(
            to: locked.appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
        return locked
    }

    @Test("an unreadable root is refused with the cause, never rendered as zero matches")
    func blockedRootFailsClosed() throws {
        let blocked = try block(root)
        // Premise: without a real refusal the two faces below prove nothing.
        #expect(blocked, "host did not refuse a 0o000 directory — this suite would pass vacuously")

        for face in ["files", "content"] {
            do {
                _ = try FileTools.search(
                    path: root.path, pattern: face == "files" ? "a*" : "needle", target: face)
                Issue.record("unreadable root returned a result for the \(face) face")
            } catch let error as ToolError {
                guard case .checkFailed(let detail) = error else {
                    Issue.record("expected .checkFailed for the \(face) face, got \(error)")
                    continue
                }
                #expect(
                    detail.hasPrefix("search_files: path not readable: \(root.path) ("),
                    "the refusal must name the path it could not open, got: \(detail)")
                #expect(!detail.contains("0 files"), "a blocked root is not a zero-match scan")
            }
        }
        unblock(root)
    }

    @Test("a skipped sub-tree is disclosed on both the hit and the empty answer")
    func partialScanIsDisclosed() throws {
        let locked = try seedLockedSubtree(named: "locked")
        // Paired flip: the same query on the same tree, one chmod apart.
        let before = try FileTools.search(path: root.path, pattern: "visible*")
        #expect(
            before == "  \(root.appendingPathComponent("visible.txt").path)\n"
                + "─── total: 1 (filename glob) ───")
        #expect(!before.contains("partial scan"))

        let blocked = try block(locked)
        #expect(blocked, "host did not refuse a 0o000 directory — this suite would pass vacuously")

        let after = try FileTools.search(path: root.path, pattern: "visible*")
        #expect(after.hasPrefix("  \(root.appendingPathComponent("visible.txt").path)\n"))
        #expect(after.contains("[partial scan: 1 unreadable dir(s), first: \(locked.path)"))
        #expect(after.hasSuffix("only readable sub-trees were searched]"))

        // The negative answer states its own bound instead of implying an exhaustive search.
        let miss = try FileTools.search(path: root.path, pattern: "hidden*")
        #expect(miss.hasPrefix("search_files: 0 files matching 'hidden*' under \(root.path)"))
        #expect(miss.contains("[partial scan: 1 unreadable dir(s), first: \(locked.path)"))

        let contentMiss = try FileTools.search(
            path: root.path, pattern: "buried", target: "content")
        #expect(
            contentMiss.hasPrefix(
                "search_files: 0 files containing 'buried' under \(root.path) (scanned 1)"))
        #expect(contentMiss.contains("[partial scan: 1 unreadable dir(s)"))
        unblock(locked)
    }

    @Test("a single-file target is not a walk, so it claims no bound it did not hit")
    func singleFileFaceIsUnaffected() throws {
        let file = root.appendingPathComponent("visible.txt")
        let hit = try FileTools.search(path: file.path, pattern: "visible.txt")
        #expect(
            hit == "  \(file.path)\n─── total: 1 (filename glob) ───")
        #expect(!hit.contains("partial scan"))
    }

    // MARK: - The limit is a bound, not a total

    /// Seed `n` files named `hit1…hitN`, all containing `needle`, and return them sorted so an
    /// assertion can name the exact window the tool owes.
    private func seedHits(_ n: Int) throws -> [String] {
        try (1 ... n).map { i in
            let url = root.appendingPathComponent("hit\(i).txt")
            try "needle \(i)".write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }.sorted()
    }

    /// Filename mode costs no I/O to finish counting, so it owes the real total beside the window —
    /// the strongest form of the rule, and the one a client can page against.
    @Test("a capped filename search names the window AND the whole it was cut from")
    func cappedGlobNamesTheWhole() throws {
        let all = try seedHits(5)
        let capped = try FileTools.search(path: root.path, pattern: "hit*", limit: 2)

        #expect(
            capped.contains(
                "\n─── showing 2 of 5 (filename glob; 3 not shown — narrow the path or raise limit) ───"
            ),
            "the capped tally did not state both numbers: \(capped)")
        #expect(
            !capped.contains("total:"),
            "a count the loop stopped at was printed as a total: \(capped)")
        // The window is deterministic (lexicographic), which is what makes the assertion above
        // re-runnable: the third file is a fact about the tree, not about walk order.
        #expect(capped.contains("  \(all[0])\n  \(all[1])\n"))
        #expect(!capped.contains("  \(all[2])"), "the limit leaked a third path")

        // Boundary: a limit that does not bind must still say "total", or this test would pass on
        // a build where the honest word disappeared entirely.
        let exact = try FileTools.search(path: root.path, pattern: "hit*", limit: 5)
        #expect(exact.contains("─── total: 5 (filename glob) ───"), "uncapped lost its total")
        #expect(!exact.contains("showing"))

        // Boundary: limit 1 (the clamp floor) still reports the whole, not a lone "total: 1".
        let one = try FileTools.search(path: root.path, pattern: "hit*", limit: 0)
        #expect(
            one.contains("showing 1 of 5"),
            "limit 0 clamps to 1 and must still name the bound: \(one)")
    }

    /// Content mode cannot know the rest without the I/O the limit exists to avoid, so it says the
    /// total is unknown. Naming a number it never counted is the defect this face had.
    @Test("a capped content search says the rest is unknown, never a number")
    func cappedContentNamesItsOwnIgnorance() throws {
        _ = try seedHits(5)
        let capped = try FileTools.search(
            path: root.path, pattern: "needle", target: "content", limit: 3)

        #expect(
            capped.contains(
                "─── showing 3 (substring in file content; the limit was reached "
                    + "and more may exist — narrow the path or raise limit) ───"),
            "the content tally did not name its bound: \(capped)")
        #expect(!capped.contains("total:"), "a capped content count claimed a total: \(capped)")

        // The uncapped face keeps the honest word, so the assertion above means something. Six,
        // not five: `init` seeds `visible.txt`, which carries the same needle — the count under
        // test is the tree's, not the helper's.
        let whole = try FileTools.search(
            path: root.path, pattern: "needle", target: "content", limit: 50)
        #expect(
            whole.contains("─── total: 6 (substring in file content) ───"),
            "the uncapped content face lost the word it is allowed to use: \(whole)")
    }

    /// A bound without a way out is a dead end; codex's paged read carries `next_offset_chars` for
    /// exactly this reason. Every capped answer must name the knob.
    @Test("every capped answer leaves the caller a move")
    func everyBoundCarriesItsExit() throws {
        _ = try seedHits(5)
        for face in ["files", "content"] {
            let capped = try FileTools.search(
                path: root.path, pattern: face == "files" ? "hit*" : "needle",
                target: face, limit: 1)
            #expect(
                capped.contains("raise limit") && capped.contains("narrow the path"),
                "the \(face) face capped without naming either exit: \(capped)")
        }
    }
}
