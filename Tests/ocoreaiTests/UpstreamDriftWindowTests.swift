// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// UpstreamDriftWindowTests.swift — the fork ledger's two premises are measured, not asserted:
/// where its window ends, and which files count as mirrors at all.
///
/// `make drift` prints one "未读 N 个" row per forked engine file. Measured 10-31, the axis read
/// GitHub's HEAD (`d3382a5`) while that table measured against the local clone's `origin/HEAD`
/// (`6a6bb0e`), so the newest commit — the one that added 243 lines to
/// `CoreAIStaticShapeEngine.swift` — was reported as "未读 0 个 | 无", and the same report claimed
/// "与轴同一 ref" in parentheses. A premise stated in prose is not a premise (AGENTS.md invariant 1):
/// these tests run the resolver that decides the endpoint, against throwaway repos, with no network.
///
/// Exit codes are the contract: 0 = the table is measuring the axis, 10 = it is measuring the last
/// fetch and must not be read as "nothing pending", 1 = nothing is measurable at all.
///
/// The second premise is older and was quieter: the table enumerated `Engine/CoreAI*.swift` by name,
/// so an upstream commit editing a mirror outside that prefix produced no row and no red. Measured
/// 11-03 against the real mirror set (26 files carry Apple's copyright, the BSD-3 clause and a
/// same-name counterpart upstream; the prefix scan reached 12, one file in both sets), sampled the
/// same day by two commits that edited six such mirrors in one window.

import Foundation
import Testing

@Suite("upstream-drift: the fork window's endpoint and its mirror set are measured, not asserted")
struct UpstreamDriftWindowTests {

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

    @discardableResult
    private static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runEndpoint(clone: URL, axis: String) throws -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/upstream-drift.sh", "window-endpoint", clone.path, axis]
        p.currentDirectoryURL = try repoRoot()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `up` with two commits, cloned into `clone`; returns the shas of both commits *in up's order*.
    private static func makePair() throws -> (clone: URL, known: String, newer: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-window-\(UUID().uuidString.prefix(8))")
        let up = base.appendingPathComponent("up")
        let clone = base.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: up, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main", "."], in: up)
        try git(["config", "user.email", "t@t"], in: up)
        try git(["config", "user.name", "t"], in: up)
        try "engine\n".write(
            to: up.appendingPathComponent("Engine.swift"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: up)
        try git(["commit", "-qm", "c1"], in: up)
        let known = try git(["rev-parse", "HEAD"], in: up)
        try git(["clone", "-q", up.path, clone.path], in: base)
        try "engine\nmore\n".write(
            to: up.appendingPathComponent("Engine.swift"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "c2"], in: up)
        let newer = try git(["rev-parse", "HEAD"], in: up)
        return (clone, known, newer)
    }

    @Test("an axis ref the clone already holds is used as-is — axis and table share one scale")
    func axisRefWins() throws {
        let (clone, known, _) = try Self.makePair()
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let r = try Self.runEndpoint(clone: clone, axis: known)
        #expect(r.code == 0, "endpoint must be usable when the object is present: \(r.out)")
        #expect(r.out.contains("src=axis"), "must name the channel it measured: \(r.out)")
        let shortKnown = try Self.git(["rev-parse", "--short", known], in: clone)
        #expect(r.out.contains(shortKnown), "endpoint must be the axis sha, got: \(r.out)")
    }

    @Test("a clone behind the axis is a red verdict, not an empty window")
    func laggingCloneIsNamedNotSilent() throws {
        let (clone, _, newer) = try Self.makePair()
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let r = try Self.runEndpoint(clone: clone, axis: newer)
        // This is the face that lied on 10-31: the table printed "未读 0 个 | 无" here.
        #expect(
            r.code == 10, "a window that cannot see the axis must exit 10, got \(r.code): \(r.out)")
        #expect(r.out.contains("LAGGING"), "the report must name the lag: \(r.out)")
        #expect(
            r.out.contains(String(newer.prefix(9))), "and name the axis ref it missed: \(r.out)")
    }

    @Test("no axis ref means the clone is the only truth, and that is said out loud")
    func cloneOnlyIsStated() throws {
        let (clone, known, _) = try Self.makePair()
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let r = try Self.runEndpoint(clone: clone, axis: "")
        #expect(r.code == 0, "with no axis the clone is what the axis reads too: \(r.out)")
        #expect(r.out.contains("src=clone"), "the channel is still printed: \(r.out)")
        #expect(!r.out.contains("LAGGING"), "no axis cannot be a lag against it: \(r.out)")
        #expect(r.out.contains(known.prefix(7)))
    }

    @Test("an unmeasurable clone says so and exits 1")
    func noRemoteRefIsNotClean() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-noref-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.git(["init", "-q", "-b", "main", "."], in: dir)
        let r = try Self.runEndpoint(clone: dir, axis: "")
        #expect(r.code == 1, "no remote ref is not a green window: \(r.out)")
        #expect(r.out.contains("src=none"))
    }

    @Test("the ledger consumes the ladder — the seam is not a second truth")
    func ledgerUsesTheResolver() throws {
        let script = try String(
            contentsOf: try Self.repoRoot().appendingPathComponent("scripts/upstream-drift.sh"),
            encoding: .utf8)
        // The bug was two resolvers; a seam nobody calls is how they come back.
        #expect(
            script.contains("res=\"$(window_endpoint \"$d\" \"$axis\")\""),
            "the fork ledger no longer resolves its window endpoint through the ladder")
        #expect(
            script.contains("axis_head \"$name\" \"$repo\""),
            "the axis grew its own HEAD resolution again — two resolvers is the defect this suite owns"
        )
        // One enumeration, or the table and the seam start telling different stories about who is a
        // mirror — the same two-resolvers shape, one floor up.
        #expect(
            script.contains("fork_ledger_py \"$d\" \"$upref\" \"$(pwd)/Sources/ocoreai\" table"),
            "the printed table no longer runs the enumeration the census seam tests")
    }

    // MARK: - Who counts as a mirror: the enumeration's own premise

    private static func runCensus(clone: URL, ref: String, ours: URL) throws -> (
        code: Int32, out: String
    ) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [
            "scripts/upstream-drift.sh", "fork-census", clone.path, ref, ours.path, "census",
        ]
        p.currentDirectoryURL = try repoRoot()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Upstream with one commit touching `TokenizerInfo.swift`, cloned; an `ours` tree holding a
    /// BSD-3 mirror in a directory the `Engine/CoreAI*` prefix never entered, one `CoreAI*` file that
    /// names its origin and carries a baseline, and one file of ours that claims nothing.
    private static func makeMirrorPair() throws -> (clone: URL, ours: URL, ref: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-census-\(UUID().uuidString.prefix(8))")
        let up = base.appendingPathComponent("up")
        let clone = base.appendingPathComponent("clone")
        try Self.write(
            "// upstream\n", to: up.appendingPathComponent("swift/Sources/Up/TokenizerInfo.swift"))
        try Self.write(
            "// upstream\n", to: up.appendingPathComponent("swift/Sources/Up/EngineThing.swift"))
        try git(["init", "-q", "-b", "main", "."], in: up)
        try git(["config", "user.email", "t@t"], in: up)
        try git(["config", "user.name", "t"], in: up)
        try git(["add", "-A"], in: up)
        try git(["commit", "-qm", "c1"], in: up)
        let ref = try git(["rev-parse", "--short", "HEAD"], in: up)
        try git(["clone", "-q", up.path, clone.path], in: base)
        let ours = base.appendingPathComponent("ours")
        try Self.write(
            """
            // Copyright 2026 Apple Inc.
            // Use of this source code is governed by a BSD-3-clause license.

            import Foundation

            """,
            to: ours.appendingPathComponent("GuidedGeneration/TokenizerInfo.swift"))
        try Self.write(
            """
            // Copyright © 2026 uingei@163.com.
            // Provenance: coreai-models — swift/Sources/Up/EngineThing.swift
            //   Absorbed: #7 \(ref)

            import Foundation

            """,
            to: ours.appendingPathComponent("Engine/CoreAIMechanism.swift"))
        try Self.write(
            "// Copyright © 2026 uingei@163.com.\n// Licensed under MIT.\nimport Foundation\n",
            to: ours.appendingPathComponent("Engine/OurOwnInvention.swift"))
        return (clone, ours, ref)
    }

    @Test(
        "a BSD-3 mirror outside Engine/CoreAI* is enumerated — the class #374 and #402 edited 11-03"
    )
    func mirrorOutsideThePrefixIsEnumerated() throws {
        let (clone, ours, ref) = try Self.makeMirrorPair()
        defer { try? FileManager.default.removeItem(at: ours.deletingLastPathComponent()) }
        let r = try Self.runCensus(clone: clone, ref: ref, ours: ours)
        #expect(r.code == 0, "the census runs on a synthetic pair: \(r.out)")
        // The face that passed vacuously: #374 edited five GuidedGeneration/ mirrors and #402 edited
        // Engine/InstrumentsProfiler.swift; neither name matched Engine/CoreAI*.swift, so the table
        // printed "未读 0 个" for everything it could see and nothing about these.
        #expect(
            r.out.contains("#nobase GuidedGeneration/TokenizerInfo.swift"),
            "a BSD-3 mirror in a subdirectory must reach the table: \(r.out)")
        #expect(
            r.out.contains("#row window Engine/CoreAIMechanism.swift"),
            "a header that names its origin gets a measurable window: \(r.out)")
        #expect(
            !r.out.contains("OurOwnInvention"),
            "a file claiming no origin is not a mirror: \(r.out)")
        #expect(r.out.contains("#cand 2"), "the candidate count is the scan's premise: \(r.out)")
    }

    @Test("the fork-licence population in our own tree is floored, not trusted")
    func forkLicencePopulationIsFloored() throws {
        let root = try Self.repoRoot().appendingPathComponent("Sources/ocoreai")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw CocoaError(.fileReadNoSuchFile) }
        var count = 0
        for case let url as URL in en where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let head = text.components(separatedBy: "\n").prefix(45).joined(separator: "\n")
            if head.contains("Apple Inc."), head.contains("BSD-3-clause") { count += 1 }
        }
        // Measured 11-03: 40 files carry Apple's copyright plus the BSD-3 clause in their first 45
        // lines, and 26 of those also have an exact-name counterpart in coreai-models. The ledger's
        // name-prefix scan reached 12. If this number falls off its floor, files stopped being forks
        // (fine, delete the floor with them) or the headers lost the licence line (a licence problem).
        #expect(
            count >= 34, "fork-licence headers in Sources/ocoreai: \(count) (floor 34, measured 40)"
        )
    }
}
