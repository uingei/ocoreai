// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ProbeHarnessHygieneTests.swift — the harness that validates every behavioural claim must
//! itself be correct, in ways that are asserted rather than remembered.
//!
//! Two defects measured 10-17, both invisible to every probe:
//!   1. `probe_resolve_binary` promised "newest existing binary" in a comment and delivered
//!      "first existing". SwiftPM 6.4 emits `<scratch>/out/Products/<config>/ocoreai`, so
//!      `.build-clt/debug/ocoreai` no longer exists and the loop fell through to a
//!      five-day-old `.build/debug/ocoreai` built from mlx-swift-lm 7eb77efa while the pin
//!      said 6e338e5df — a run whose every number would describe code this repo does not
//!      ship. It also derived the dependency checkout by a fixed `dirname/../` hop, so the
//!      pin premise printed "not verifiable" instead of holding.
//!   2. `05-hearing.sh` installed its own `trap 'rm -f "$AIFF"' EXIT INT TERM`, which
//!      replaced `_lib.sh`'s `probes_cleanup` (bash keeps one handler per signal). Its
//!      server was never TERM'd, `SingleInstanceLock`'s flock stayed held, and 06/07/08
//!      each spent the full 240 s ready timeout reporting "Metal unavailable or model load
//!      stuck" — a leaked process misdiagnosed three times.
//!
//! The scan floors below are what keep these from becoming folklore: if the patterns stop
//! matching, the suite fails instead of passing vacuously (AGENTS.md invariant 1).

import Foundation
import Testing

@testable import ocoreai

@Suite("Probe harness hygiene — binary resolution and exit traps")
struct ProbeHarnessHygieneTests {

    private struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    /// Repo root found by walking until the harness itself is present — finding the file is
    /// the proof of the root (fixed hop counts have broken scan tests here before).
    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("scripts/probes/_lib.sh").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/scripts/probes/_lib.sh")
    }

    private static func probeScripts(root: URL) throws -> [URL] {
        let dir = root.appendingPathComponent("scripts/probes")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return names.filter { $0.hasSuffix(".sh") && $0 != "_lib.sh" }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    @Test("no probe script replaces the cleanup trap with its own EXIT handler")
    static func probesDoNotOverrideCleanupTrap() throws {
        let root = try repoRoot()
        let scripts = try probeScripts(root: root)
        // Floor: if this ever finds almost nothing, the scan is broken, not the probes.
        #expect(scripts.count >= 8, "only \(scripts.count) probe scripts found — scan vacuous")

        let bareTrap = try NSRegularExpression(pattern: #"^\s*trap\s+["'].*\b(EXIT|INT|TERM)\b"#)
        var offenders: [String] = []
        for url in scripts {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("#") == false {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                if bareTrap.firstMatch(in: String(line), range: range) != nil {
                    offenders.append(
                        "\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            probe script(s) install their own signal trap, which silently replaces \
            _lib.sh's probes_cleanup and leaks the engine server (single-instance flock \
            held -> every later probe times out at boot). Use probe_atexit instead: \
            \(offenders.joined(separator: "; "))
            """)
    }

    @Test("resolution covers the SwiftPM 6.4 product layout and breaks ties on mtime")
    static func resolutionCoversCurrentLayout() throws {
        let lib = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/probes/_lib.sh"),
            encoding: .utf8)
        #expect(
            lib.contains(".build-clt/out/Products/Debug/ocoreai"),
            "candidate list lacks the SwiftPM 6.4 product path — resolution will pick a stale tree")
        #expect(
            lib.contains("stat -f %m"),
            "candidates are no longer compared by mtime — the 'newest wins' half of the rule is gone"
        )
        #expect(
            lib.contains("probe_scratch_for_binary"),
            "scratch path must be derived by walking to the scratch root, not by fixed hops")
    }

    /// Runs a function from `_lib.sh` against a synthetic root in a throwaway dir.
    private static func harness(_ root: URL, _ body: String) throws -> String {
        let lib = try repoRoot().appendingPathComponent("scripts/probes/_lib.sh").path
        let script = """
            set -uo pipefail
            source "\(lib)"
            PROBE_REPO_ROOT="\(root.path)"
            \(body)
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()  // probe_note chatter is not part of these contracts
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    private static func makeScratch(root: URL, relative: String) throws -> URL {
        let bin = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.path, contents: Data([0x23]))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return bin
    }

    @Test("scratch derives from the layout, not from a fixed hop count")
    static func scratchFollowsLayout() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-harness-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let swiftPM64 = try makeScratch(
            root: tmp, relative: ".build-clt/out/Products/Debug/ocoreai")
        let swiftPM61 = try makeScratch(root: tmp, relative: ".build/debug/ocoreai")

        let a = try harness(tmp, "probe_scratch_for_binary \"\(swiftPM64.path)\"")
        #expect(
            a == tmp.appendingPathComponent(".build-clt").path,
            "SwiftPM 6.4 layout must resolve to the scratch root, got \(a)")
        let b = try harness(tmp, "probe_scratch_for_binary \"\(swiftPM61.path)\"")
        #expect(
            b == tmp.appendingPathComponent(".build").path,
            "older layout must still resolve, got \(b)")
    }

    /// A one-commit git repo standing in for a SwiftPM dependency checkout.
    private static func makeCheckout(at dir: URL) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("Package.swift").path,
            contents: Data("// stub\n".utf8))

        @discardableResult
        func git(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", dir.path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        _ = git(["init", "-q"])
        _ = git(["add", "-A"])
        _ = git([
            "-c", "user.email=probe@test.local", "-c", "user.name=probe", "commit", "-qm", "stub",
        ])
        let head = git(["rev-parse", "HEAD"])
        #expect(head.count >= 7, "could not create a synthetic git checkout at \(dir.path)")
        return head
    }

    @Test("a clean checkout at the pin beats a newer binary from an unverifiable tree")
    static func pinnedTreeBeatsNewerUnverifiable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-harness-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let pinned = try makeScratch(root: tmp, relative: ".build-clt/out/Products/Debug/ocoreai")
        let newer = try makeScratch(root: tmp, relative: ".build/debug/ocoreai")
        // The older binary's tree is clean and at the pin; the newer one has nothing to
        // verify against. Newest-first — the behaviour this fix replaced — picks the second.
        let head = try makeCheckout(
            at: tmp.appendingPathComponent(".build-clt/checkouts/mlx-swift-lm"))
        FileManager.default.createFile(
            atPath: tmp.appendingPathComponent("Package.swift").path,
            contents: Data(
                (".package(url: \"https://github.com/ml-explore/mlx-swift-lm.git\", "
                    + "revision: \"\(head)\")\n").utf8))

        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: pinned.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let pinnedScore = try harness(tmp, "probe_dependency_score \"\(pinned.path)\"")
        #expect(pinnedScore == "2", "clean checkout at the pin must score 2, got \(pinnedScore)")
        let newerScore = try harness(tmp, "probe_dependency_score \"\(newer.path)\"")
        #expect(newerScore == "1", "no checkout must score 1 (unverifiable), got \(newerScore)")

        let chosen = try harness(tmp, "probe_resolve_binary 2>/dev/null")
        #expect(
            chosen == pinned.path,
            """
            resolution must prefer the build whose dependency tree is verifiable, even when it \
            is older (the newer, unverifiable candidate is \(newer.path)); got \(chosen)
            """)
    }
}
