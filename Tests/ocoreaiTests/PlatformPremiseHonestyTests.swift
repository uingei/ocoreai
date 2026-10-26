// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! PlatformPremiseHonestyTests — an OS premise is declared conditionally or not at all.
//!
//! Three ways a suite hid "this OS cannot run it", all measured in this repo on 10-26:
//! `Issue.record("requires macOS 27")` (a red that is the platform talking, so one failure is two
//! verdicts), `print`ing a SKIP (invisible in the run summary, so untested work reads as tested),
//! and `.disabled("requires macOS 27 runtime")` — which never revives when the runner moves to
//! macOS 27, leaving a claim with no gate behind it. Every one of those is gone from `Tests/`, and
//! this scan keeps them gone. The repo root is found by searching rather than by fixed parent hops,
//! and the scan floors its own hit count so a regex that stopped matching cannot pass vacuously
//! (§ Testing Quality).
import Foundation
import Testing

@testable import ocoreai

@Suite("platform premises — skip, never fake")
struct PlatformPremiseHonestyTests {

    private enum ScanError: Error { case rootNotFound }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let here = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: here.path),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw ScanError.rootNotFound
    }

    /// Comment lines quote `.disabled(...)` in prose, and a scan that counted prose would name files
    /// that carry no disabled test at all.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let t = line.trimmingCharacters(in: CharacterSet.whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("*")
            }
            .joined(separator: "\n")
    }

    /// The scanner names the pattern in code, so it is the one file allowed to contain it; the
    /// exemption is asserted by name so a second one cannot hide inside the rule's own home.
    private static let scanner = "Tests/ocoreaiTests/PlatformPremiseHonestyTests.swift"

    @Test("no test in Tests/ is permanently disabled")
    func noTestIsPermanentlyDisabled() throws {
        let root = try Self.repoRoot()
        let tests = root.appendingPathComponent("Tests")
        guard let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        else { throw ScanError.rootNotFound }

        var files = 0
        var exemptions = 0
        var offenders: [String] = []
        var conditional = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = Self.codeOnly(text)
            if code.contains(".disabled(") {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if relative == Self.scanner { exemptions += 1 } else { offenders.append(relative) }
            }
            conditional += code.components(separatedBy: ".enabled(if:").count - 1
        }

        #expect(
            exemptions == 1,
            "only the scanner may name the pattern (measured \(exemptions)) — an accidental match here would make the scan blind, not clean")
        // Floors first: without them "no offenders" is also true when the scan sees nothing.
        #expect(files >= 300, "the scan walked Tests/ (floor 300, measured \(files))")
        #expect(
            conditional >= 20,
            "the conditional idiom is still visible to the scan (floor 20, measured \(conditional))")
        #expect(
            offenders.isEmpty,
            "a disabled test is a claim with no gate — declare its premise with `.enabled(if:)`: \(offenders.joined(separator: ", "))"
        )
    }

    @Test("the premise tracks the running OS, not the SDK that compiled it")
    func premiseMatchesTheRunningOS() {
        // An independent computation of the same fact: a predicate hardened to `true` (or to the
        // build's SDK, which is how these suites get compiled in on a macOS 26 host in the first
        // place) fails here instead of skipping the wrong way forever.
        let running = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #expect(
            PlatformPremise.hasMacOS27 == running,
            "hasMacOS27 said \(PlatformPremise.hasMacOS27) on OS \(ProcessInfo.processInfo.operatingSystemVersion)")
    }
}
