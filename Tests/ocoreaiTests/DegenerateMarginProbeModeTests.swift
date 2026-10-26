// Copyright © 2026 uingei.
// Licensed under MIT.
/// The switch that arms the P0 instrument is itself a claim, and until now nothing gated it:
/// `=1` must pay only on collapsed turns, `=all` must widen to every turn (arm E's pairing),
/// and unset must mean off. A typo in the mode string used to be invisible — the probe simply
/// never logged, and `scripts/collapse-discriminators.sh` arm D counted the missing lines as
/// collapsed replays and still printed a verdict.
///
/// Serialized: these read and write one process-wide env var.
import Foundation
import Testing

@testable import ocoreai

@Suite("DegenerateMarginProbe: opt-in modes", .serialized)
struct DegenerateMarginProbeModeTests {

    private func setMode(_ value: String?) {
        if let value {
            setenv("OCOREAI_MARGIN_PROBE", value, 1)
        } else {
            unsetenv("OCOREAI_MARGIN_PROBE")
        }
    }

    @Test("unset means off — a normal run never pays for the probe")
    func unsetIsOff() {
        let lease = ProcessGlobalLease(envKeys: ["OCOREAI_MARGIN_PROBE"])
        defer { lease.release() }
        setMode(nil)
        #expect(!DegenerateMarginProbe.isEnabled)
        #expect(!DegenerateMarginProbe.runsOnEveryTurn)
    }

    @Test("=1 is collapse-only: healthy turns still pay nothing")
    func oneIsCollapseOnly() {
        let lease = ProcessGlobalLease(envKeys: ["OCOREAI_MARGIN_PROBE"])
        defer { lease.release() }
        setMode("1")
        defer { setMode(nil) }
        #expect(DegenerateMarginProbe.isEnabled)
        #expect(!DegenerateMarginProbe.runsOnEveryTurn)
    }

    @Test("=all widens the gate; an unrecognised value arms nothing")
    func allWidensTheGate() {
        let lease = ProcessGlobalLease(envKeys: ["OCOREAI_MARGIN_PROBE"])
        defer { lease.release() }
        setMode("all")
        defer { setMode(nil) }
        #expect(DegenerateMarginProbe.isEnabled)
        #expect(DegenerateMarginProbe.runsOnEveryTurn)
        setMode("yes")
        #expect(!DegenerateMarginProbe.isEnabled, "an unrecognised mode must not arm the probe")
        #expect(!DegenerateMarginProbe.runsOnEveryTurn)
    }
}

/// `toolsCarried` says whether `promptHash` covers schema bytes, so a reader who misses it reads a
/// blind hash as a verdict on tool declarations — the exact misreading this field exists to prevent
/// (probe 32's NOTE claimed exactly that on 10-23, from an instrument carrying zero specs). The
/// value therefore has to be gated where it is published, and the probe that scrapes it has to
/// agree with the format that emits it: two surfaces, one contract, checked in CI rather than at
/// 03:00 by someone wondering why a probe measured nothing.
@Suite("DegenerateMarginProbe: the published line carries toolsCarried")
struct DegenerateMarginProbeReportLineTests {

    /// The scrape pattern used by `scripts/probes/32-prompt-byte-determinism.sh`.
    private static let scrapePattern = "promptHash=[0-9a-f]+ toolsCarried=[0-9]+"

    /// Repo root by searching, never by fixed `deletingLastPathComponent()` hops: a suite that
    /// resolves its own fixture path by counting parents breaks the day the test target moves.
    private func probeScript() -> String? {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(
                "scripts/probes/32-prompt-byte-determinism.sh")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    @Test("a report that carried nothing publishes 0 rather than omitting the field")
    func bareReportPublishesZero() {
        var report = DegenerateMarginProbe.Report()
        report.attempted = true
        report.promptHash = "0123456789abcdef"
        let line = DegenerateMarginProbe.logLine(report, convKey: "margin")
        #expect(report.toolsCarried == 0)
        #expect(line.contains("toolsCarried=0"), "a bare turn must say it carried no schema")
        #expect(
            line.range(of: Self.scrapePattern, options: .regularExpression) != nil,
            "the emitted line must match the pattern the probe scrapes")
    }

    @Test("the carried count reaches the line the probe reads")
    func carriedCountReachesTheLine() {
        var report = DegenerateMarginProbe.Report()
        report.attempted = true
        report.promptHash = "d5a6b0b906c0514a"
        report.toolsCarried = 1
        #expect(DegenerateMarginProbe.logLine(report, convKey: "margin").contains("toolsCarried=1"))
    }

    @Test("the emit format and the probe's scrape pattern have not drifted apart")
    func emitFormatAndProbeAgree() throws {
        guard let script = probeScript() else {
            Issue.record(
                "could not locate scripts/probes/32-prompt-byte-determinism.sh from \(#filePath)")
            return
        }
        // Floor the scan's own premises: a missing file or a rewritten scrape line must fail loudly,
        // not pass because the substring search quietly found nothing to compare.
        #expect(script.contains("32-prompt-byte-determinism"), "found the wrong file")
        #expect(
            script.contains("grep -oE \"\(Self.scrapePattern)\""),
            "the probe no longer scrapes promptHash+toolsCarried in one pass — update both sides together"
        )
    }
}
