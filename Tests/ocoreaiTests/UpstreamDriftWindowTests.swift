// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// UpstreamDriftWindowTests.swift — the fork ledger's window endpoint is measured, not asserted.
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

import Foundation
import Testing

@Suite("upstream-drift: the fork window's endpoint must be the axis, or say so")
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
    }
}
