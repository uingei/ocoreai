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
/// same day by two commits that edited six such mirrors in one window. The exit code is only honest if
/// the verdict table is measured too, so which axes exist is read off `REPOS=` and which of them owe a red
/// is asked through the `axis-owed` seam (codex reports only since the owner's 11-03 ruling, root § Upstream 5).
///
/// The third premise is the code set itself. A contract of three numbers is worth whatever stops a
/// fourth from leaving: `set -e` hands out the *failing command's* number, and `make` hands out its
/// own 2 for every failed recipe, so both layers had to be asked — the script through the
/// `abort-code` seam, the target through `make -n` (11-05: one verdict, exit 10 from the script and
/// exit 2 from `make drift`, read as a broken contract).

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

    @Test(
        "a header's other read-point spelling is read — `Provenance: … @ <sha>` is a baseline too")
    func provenanceAtShaIsABaseline() throws {
        // Measured 11-05: the table said 40 mirrors had "no baseline" while four of them carried
        // `Provenance: aligned with … @ <sha>` in line 5. The ledger knew two spellings, the headers
        // used a third, and the file that proved it costliest also asserted "(0 commits changed
        // … — anchor current)" when upstream had since edited it twice — so the blind spot was not
        // unread files, it was a reader that could not parse being read.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-prov-\(UUID().uuidString.prefix(8))")
        let up = base.appendingPathComponent("up")
        let clone = base.appendingPathComponent("clone")
        try Self.write(
            "// upstream\n", to: up.appendingPathComponent("swift/Sources/Up/Thing.swift"))
        try Self.git(["init", "-q", "-b", "main", "."], in: up)
        try Self.git(["config", "user.email", "t@t"], in: up)
        try Self.git(["config", "user.name", "t"], in: up)
        try Self.git(["add", "-A"], in: up)
        try Self.git(["commit", "-qm", "c1"], in: up)
        let baseline = try Self.git(["rev-parse", "--short", "HEAD"], in: up)
        try Self.git(["clone", "-q", up.path, clone.path], in: base)
        try "line\n".write(
            to: up.appendingPathComponent("swift/Sources/Up/Thing.swift"), atomically: true,
            encoding: .utf8)
        try Self.git(["commit", "-qam", "c2"], in: up)
        let ref = try Self.git(["rev-parse", "--short", "HEAD"], in: up)
        try Self.git(["-C", clone.path, "fetch", "-q", "origin"], in: base)
        let ours = base.appendingPathComponent("ours")
        try Self.write(
            """
            // Copyright 2026 Apple Inc.
            // Use of this source code is governed by a BSD-3-clause license that can
            // be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
            // Provenance: aligned with coreai-models Up/Thing.swift @ \(baseline) (0 commits changed \(baseline)..HEAD — anchor current).

            import Foundation

            """,
            to: ours.appendingPathComponent("Engine/Thing.swift"))
        let r = try Self.runCensus(clone: clone, ref: ref, ours: ours)
        let rowStart = "#row window Engine/Thing.swift 基线 \(baseline)"
        #expect(r.code == 0, "the census runs on the pair: \(r.out)")
        #expect(r.out.contains(rowStart), "the @-sha spelling opens a window: \(r.out)")
        #expect(r.out.contains(rowStart + " 1 "), "with the real unread count: \(r.out)")
        #expect(!r.out.contains("#nobase Engine/Thing.swift"), "and reports no hole: \(r.out)")
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

    // MARK: - Who owes a red: the other half of the exit-code contract

    private static func runAxisOwed(_ name: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/upstream-drift.sh", "axis-owed", name]
        p.currentDirectoryURL = try repoRoot()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - What a failed compare read is allowed to say

    @Test("a compare read that failed is reported as a failed read, not as a rewritten history")
    func rateLimitedReadNamesItself() throws {
        // Measured 11-05: api.github.com sat at 0/60, both compare numbers came back "?", and the
        // loop's last `elif` — which only asks whether base ≠ HEAD — printed "? 非线性分叉" for codex.
        // A reader told "the history is non-linear, review by hand" goes looking for a force-push;
        // the truth was a quota. The verdict's *shape* is untouched (still 1, still human review);
        // only the named cause moved, and the two window faces print exactly what they used to.
        let r = try Self.run(
            [
                "scripts/upstream-drift.sh", "axis-verdict", "codex", "abc123456", "def456789", "?",
                "?", "1",
            ])
        #expect(
            r.out.contains("compare 未读到"), "a read that returned nothing must say so: \(r.out)")
        #expect(!r.out.contains("非线性"), "an exhausted quota is not a branch history: \(r.out)")
        #expect(r.out.contains("AXIS_DRIFT=1"), "and it still owes a human: \(r.out)")
    }

    @Test("a compare that answered 0/0 on a different sha is still the non-linear face")
    func zeroZeroStillNonLinear() throws {
        // The new branch must not swallow the case the old message existed for: the read worked,
        // ahead and behind are both 0, and the shas differ. That is a real divergence and stays red.
        let r = try Self.run(
            [
                "scripts/upstream-drift.sh", "axis-verdict", "codex", "abc123456", "def456789", "0",
                "0", "1",
            ])
        #expect(
            r.out.contains("非线性"), "0/0 across two shas is the divergence face: \(r.out)")
        #expect(!r.out.contains("未读到"), "the read worked, so it may not claim otherwise: \(r.out)")
        #expect(r.out.contains("AXIS_DRIFT=1"))
    }

    @Test("the two window faces kept their words and their codes through the extraction")
    func verdictFacesUnchanged() throws {
        let owed = try Self.run(
            [
                "scripts/upstream-drift.sh", "axis-verdict", "mlx-swift-lm", "abc123456",
                "def456789", "6", "0", "1",
            ])
        #expect(owed.out.contains("+6 commits"), "the count still prints: \(owed.out)")
        #expect(owed.out.contains("新窗口待裁决"), "an owed axis still calls it a window: \(owed.out)")
        #expect(owed.out.contains("AXIS_DRIFT=10"), "and still asks for 10: \(owed.out)")
        let free = try Self.run(
            [
                "scripts/upstream-drift.sh", "axis-verdict", "codex", "abc123456", "def456789", "6",
                "0", "0",
            ])
        #expect(free.out.contains("仅报告"), "a comparator still reports without judging: \(free.out)")
        #expect(free.out.contains("AXIS_DRIFT=0"), "and moves no code: \(free.out)")
        // The seam is evidence only while the loop answers through the same function.
        let script = try String(
            contentsOf: try Self.repoRoot().appendingPathComponent("scripts/upstream-drift.sh"),
            encoding: .utf8)
        #expect(
            script.contains(
                "axis_verdict \"$name\" \"$short\" \"${base:0:9}\" \"$ahead\" \"$behind\" \"$owed\""
            ),
            "the axis loop decides its verdict somewhere else again — the seam tests a path nobody runs"
        )
    }

    // MARK: - How two axes' verdicts merge into one exit code

    @Test(
        "a limitation cannot erase a fact — an owed window outranks an axis that could not be read")
    func owedOutranksIncomplete() throws {
        // Measured 11-05 with the quota at 0/60: `mlx-swift-lm` printed "+6 commits ⚠ 新窗口待裁决"
        // and codex's compare then read as "?", so the second axis wrote 1 over the first axis's 10
        // and the run exited 1 under "检查没跑完". An automation was told nothing had been decided,
        // when one consumed axis had already concluded there is work. 10 is a fact, 1 is the report's
        // own limit; the order they arrive in may not decide which one the reader gets.
        func tally(_ start: String, _ rest: [String]) throws -> String {
            let r = try Self.run(
                ["scripts/upstream-drift.sh", "tally", start] + rest)
            return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try tally("0", ["10", "1"]) == "DRIFT=10", "fact then limit keeps the fact")
        #expect(try tally("0", ["1", "10"]) == "DRIFT=10", "and the other order keeps it too")
        #expect(try tally("0", ["1", "1"]) == "DRIFT=1", "two limits still owe a re-run")
        #expect(try tally("0", ["0", "0"]) == "DRIFT=0", "and nothing printed stays clean")
    }

    @Test("the merge has one home — no axis may fold a verdict into DRIFT by hand again")
    func mergeHasOneHome() throws {
        // The masking was possible from eight places, so fixing the one that fired would leave seven
        // of them free to do it again. The scan floors itself: exactly one indented write is allowed,
        // the one inside `tally_drift`; a second is the rule finding a second home.
        let script = try String(
            contentsOf: try Self.repoRoot().appendingPathComponent("scripts/upstream-drift.sh"),
            encoding: .utf8)
        let writes =
            script
            .split(separator: "\n")
            .filter { $0.range(of: #"^\s+DRIFT=[0-9]"#, options: .regularExpression) != nil }
        #expect(
            writes.count == 1,
            "only tally_drift may write the verdict directly, found \(writes.count): \(writes)")
        #expect(
            writes.first?.contains("DRIFT=10") == true,
            "the one write must be the sticky one inside the merge: \(writes)")
        #expect(
            script.contains("tally_drift \"$AXIS_DRIFT\""),
            "the axis loop folds its verdict somewhere else again — the seam tests a path nobody runs"
        )
    }

    // MARK: - The exit-code contract is executed, not documented

    /// Both streams, because the normalization is reported on stderr and a bare code cannot tell
    /// a trap from a coincidence. Streams are drained before `waitUntilExit`, so a chatty run
    /// cannot fill a pipe and park the test.
    private static func run(
        _ args: [String], exe: String = "/bin/bash"
    ) throws -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = try repoRoot()
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    @Test("an unregistered exit code cannot leave the script — 2/141/127 all arrive as 1")
    func abnormalCodesNormalizeToOne() throws {
        // The script documents 0/1/10 and nothing else, yet `set -e` alone lets a mid-script death
        // out with *the failing command's* number: a python traceback is 2, the SIGPIPE the header
        // records on 10-29 is 141, a missing tool is 127. A reader that was told "1 = a check could
        // not complete" then reads a coincidence as a verdict. The trap is the contract, so it gets
        // asked against a command that really fails, on the same top-level path the check uses.
        for raw in [2, 141, 127] {
            let r = try Self.run(["scripts/upstream-drift.sh", "abort-code", "\(raw)"])
            #expect(r.code == 1, "raw \(raw) left the script as \(r.code): \(r.err)")
            #expect(
                r.err.contains("退出 \(raw)"),
                "the report must name the code it replaced, not silently swap it: \(r.err)")
        }
        // The trap must also stay off the success path: an ERR trap that fires where none belongs
        // would turn a clean window red, which is the expensive direction for an instrument.
        let ok = try Self.run(["scripts/upstream-drift.sh", "abort-code", "0"])
        #expect(ok.code == 0, "a passing seam must still pass: \(ok.err)")
    }

    @Test("`make drift` prints the script's number, because make re-signals every failure as 2")
    func makeDriftCarriesTheScriptNumber() throws {
        // GNU make's own status is 2 for any failed recipe, whatever the recipe returned — measured
        // 11-05, the script exited 10 on a verdict and this target exited 2 on the same one, which
        // is how a reader came to file the contract as broken when it was the layer. The number
        // therefore has one surviving channel through make: stdout. `make -n` asks where it lives
        // without touching the network.
        let expanded = try Self.run(["-c", "make -n drift"])
        #expect(expanded.code == 0, "make -n must expand without running: \(expanded.err)")
        #expect(
            expanded.out.contains("scripts/upstream-drift.sh"),
            """
            the drift target no longer runs the script, so this test has stopped \
            meaning anything: \(expanded.out)
            """
        )
        #expect(
            expanded.out.contains("drift-exit="),
            """
            `make drift` no longer prints the script's exit code — a reader of its \
            status can only ever see make's 2: \(expanded.out)
            """
        )
    }

    // MARK: - A hint that fails to read must not become a verdict

    @Test("a failed window read names itself and keeps the verdict it was printed under")
    func failedHintReadIsNamedNotFatal() throws {
        // Measured 11-05 with the trap in place: a rate-limited `compare` read killed the process
        // mid-report — `window="$(api …)"` under `set -e` — so the exit went 10 → 1, the two axes
        // below never printed, and an automation reading the code saw "a check could not complete"
        // where the truth was "two windows need adjudication". A subject list is the keyword
        // screen's input, a hint; only a failed *verdict* may move the code. The seam points the
        // clone root at an empty directory, so the read fails for real, offline.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/upstream-drift.sh", "window-read"]
        p.currentDirectoryURL = try Self.repoRoot()
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-norefs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        p.environment = [
            "OCOREAI_REFERENCES_DIR": empty.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: outData, as: UTF8.self)
        #expect(
            p.terminationStatus == 0, "a hint read that failed must not decide the exit: \(text)")
        #expect(
            text.contains("窗口列表未读到"),
            "the report must say the list is missing, not print an empty one: \(text)")
        // And a report that continues must not claim an abort happened: the -E variant of the trap
        // printed three of these for reads its own `||` had already swallowed.
        #expect(
            !String(decoding: errData, as: UTF8.self).contains("计划外中止"),
            "a path the script continues past cannot be reported as an abort: \(text)")
        // The seam is only evidence while the loop answers through the same function.
        let script = try String(
            contentsOf: try Self.repoRoot().appendingPathComponent("scripts/upstream-drift.sh"),
            encoding: .utf8)
        #expect(
            script.contains("axis_window \"$name\" \"$repo\" \"$src\" \"$base_full\" \"$head\""),
            "the axis loop prints its window somewhere else again — the seam tests a path nobody runs"
        )
    }

    @Test(
        "an unread window reddens only the axes we consume, and the demotion is the only exception")
    func demotedAxisReportsWhileConsumedAxesStillOweARed() throws {
        let script = try String(
            contentsOf: try Self.repoRoot().appendingPathComponent("scripts/upstream-drift.sh"),
            encoding: .utf8)
        // `REPOS=` is the axis declaration home, so the verdict table is read off it rather than
        // restated here — a second list is how a verdict and an axis drift apart.
        let line = try #require(
            script.split(separator: "\n").first { $0.hasPrefix("REPOS=") },
            "REPOS= no longer declares the axes at top level — the scan stopped matching")
        let axes = line.split(separator: " ").compactMap { token -> String? in
            let raw = token.split(separator: ":").first.map(String.init) ?? ""
            let clean =
                raw
                .replacingOccurrences(of: "REPOS=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
            return clean.isEmpty ? nil : clean
        }
        #expect(axes.count >= 3, "axes read off REPOS: \(axes) (floor 3)")
        var verdicts: [String: String] = [:]
        for axis in axes { verdicts[axis] = try Self.runAxisOwed(axis) }
        #expect(verdicts["codex"] == "report-only", "codex owes a red again: \(verdicts)")
        for axis in axes where axis != "codex" {
            #expect(verdicts[axis] == "owed", "\(axis) stopped owing a red: \(verdicts)")
        }
        // An axis nobody registered defaults to owed: defaulting the other way is how a newly added
        // upstream silently escapes the gate that exists to catch it.
        #expect(try Self.runAxisOwed("not-a-registered-axis") == "owed")
    }
}
