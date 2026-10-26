// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `scripts/version.sh` decides the version every artifact carries
/// (`CFBundleShortVersionString`, the DMG filename, the e2e staleness check), so a wrong value is
/// a wrong-looking release rather than a crash. Three rungs, three exact values:
/// `OCOREAI_VERSION` wins, a tag resolves to its number, and a tagless tree resolves `0.0.0`.
///
/// The third rung is the one that was silently broken: `git describe` exits non-zero with no tags,
/// but `$(git describe … | tr -d v || echo 0.0.0)` reports the status of `tr`, so the `|| echo`
/// never ran and VERSION became "". Every tag was withdrawn on 10-26, which made that path the
/// only path, and the suite below keeps it from ever being prose again.

import Foundation
import Testing

@testable import ocoreai

@Suite("Build version — one ladder, and a tagless tree resolves 0.0.0 rather than empty")
struct BuildVersionResolutionTests {

    private enum VersionTestFailure: Error {
        case missingRoot
        case shell(command: String, status: Int32, stderr: String)
    }

    private func repoRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/",
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
        {
            root.deleteLastPathComponent()
        }
        if root.path == "/" {
            throw VersionTestFailure.missingRoot
        }
        return root
    }

    private func scriptPath() throws -> String {
        try repoRoot().appendingPathComponent("scripts/version.sh").path
    }

    /// Runs a shell line with a merged environment: `Process.environment` replaces the whole
    /// block, and a stripped PATH would fail the test for the wrong reason.
    private func shell(_ line: String, cwd: URL, override: String?) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", line]
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        if let override {
            env["OCOREAI_VERSION"] = override
        } else {
            env.removeValue(forKey: "OCOREAI_VERSION")
        }
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw VersionTestFailure.shell(
                command: line,
                status: p.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A throwaway repo with one empty commit: "no tag" is a permanent property of this
    /// directory, not a property of the day the suite runs.
    private func scratchRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try shell(
            "git init -q -b main && git -c user.email=t@t.local -c user.name=t commit -q "
                + "--allow-empty -m init",
            cwd: dir, override: nil)
        return dir
    }

    /// Premise check: the script exists and holds real logic, so "no output" below cannot be
    /// mistaken for a passing ladder.
    @Test func helperExistsAndIsNotAStub() throws {
        let url = try repoRoot().appendingPathComponent("scripts/version.sh")
        let bytes = try Data(contentsOf: url).count
        #expect(bytes > 200, "scripts/version.sh is \(bytes) bytes — the ladder was gutted")
    }

    /// CI's rung: the tag name exported by the workflow outranks anything git can derive.
    @Test func explicitOverrideWins() throws {
        let out = try shell("bash \(scriptPath())", cwd: repoRoot(), override: "9.9.9")
        #expect(out == "9.9.9")
    }

    /// The rung that broke: with no tag the ladder must land on `0.0.0`, and the pre-fix
    /// expression is asserted to produce the empty string it produced — the premise, pinned.
    @Test func taglessTreeResolvesZeroAndTheOldFormResolvedEmpty() throws {
        let dir = try scratchRepo()
        let fixed = try shell("bash \(scriptPath())", cwd: dir, override: nil)
        #expect(fixed == "0.0.0", "a tagless tree resolved \(fixed.debugDescription)")

        let broken = try shell(
            "printf '[%s]' \"$(git describe --tags --abbrev=0 2>/dev/null | tr -d 'v' "
                + "|| echo 0.0.0)\"",
            cwd: dir, override: nil)
        #expect(broken == "[]", "the old form stopped reproducing the defect: \(broken)")
    }

    /// The normal rung, asserted in a repo this suite owns so creating a real tag cannot
    /// retire the assertion.
    @Test func tagResolvesItsNumber() throws {
        let dir = try scratchRepo()
        _ = try shell("git tag v1.2.3", cwd: dir, override: nil)
        let out = try shell("bash \(scriptPath())", cwd: dir, override: nil)
        #expect(out == "1.2.3", "tagged tree resolved \(out.debugDescription)")
    }
}
