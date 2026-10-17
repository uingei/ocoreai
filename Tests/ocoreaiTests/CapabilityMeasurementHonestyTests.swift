// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CapabilityMeasurementHonestyTests — the matrix may state tier truth; only measurement
/// may state delivery.
///
/// Two defects this suite keeps dead:
///
///  1. `screenshot_capture: available=true`, read by a client as "this box captures
///     screens", while the *same server* reported `screenStatus: blocked` on
///     `/v1/multimodal/status`. Measured 10-15: permission authorized with a display
///     enumerated, and ScreenCaptureKit still refused to start a stream. The row now names
///     where the measurement lives, and degrades from the record on the wire.
///  2. a discovery surface silent about video *input*. `video_generation` describes output;
///     `/v1/models` gained the per-model measured row in round 14, and `video_input` here
///     closes the server-wide half (AGENTS.md invariant 2 runs in both directions).
///
/// Assertions are exact-value. Where the suite scans source, it floors its own hit count,
/// so a regex that stopped matching fails instead of passing vacuously.
import Foundation
import Testing

@testable import ocoreai

@Suite("CapabilityMeasurement honesty")
struct CapabilityMeasurementHonestyTests {

    private enum RepoScanError: Error {
        case repoRootNotFound(String)
    }

    private static func row(
        _ lines: [RuntimeCapability.Line], _ name: String
    ) throws -> RuntimeCapability.Line {
        try #require(lines.first { $0.name == name }, "no \(name) row in \(lines.map(\.name))")
    }

    // MARK: - The overlay never invents a claim

    @Test("nothing measured ⇒ no availability changes, exactly one row added")
    func unmeasuredKeepsTierTruth() throws {
        let base = RuntimeCapability.lines
        let out = RuntimeCapability.measured(.unmeasured)
        #expect(out.count == base.count + 1)
        // Everything the tier matrix says is unchanged, in the same order.
        for (index, tierLine) in base.enumerated() {
            #expect(out[index].name == tierLine.name, "row order moved at \(index)")
            #expect(
                out[index].available == tierLine.available,
                "\(tierLine.name) availability changed unmeasured")
            #expect(out[index].note == tierLine.note, "\(tierLine.name) note rewritten unmeasured")
        }
        let video = try Self.row(out, "video_input")
        #expect(video.available == false, "video_input claimed delivered with no turn behind it")
        #expect(video.note.contains("not_observed"), "negative must be explicit: \(video.note)")
    }

    @Test("video_input is the only name the overlay adds, and never duplicates")
    func noDuplicateNames() {
        let names = RuntimeCapability.measured(.unmeasured).map(\.name)
        #expect(Set(names).count == names.count, "duplicate capability names: \(names)")
        #expect(names.filter { $0 == "video_input" }.count == 1)
    }

    @Test("the overlay never upgrades a row the tier gate turned off")
    func neverUpgrades() throws {
        let out = RuntimeCapability.measured(
            .init(screenshot: .captured, screenshotLatencyMs: 1102))
        for tierLine in RuntimeCapability.lines {
            let measured = try Self.row(out, tierLine.name)
            if !tierLine.available {
                #expect(
                    measured.available == false,
                    "\(tierLine.name) is tier-unavailable here; a measurement of another surface must not switch it on"
                )
            }
        }
    }

    // MARK: - Screen channel: a grant is not a frame

    @Test("every mechanism row names where its delivery is measured")
    func mechanismRowsPointAtMeasurement() {
        // These rows describe a mechanism (a framework link, an OS tier), so a reader can
        // only avoid mistaking them for a delivery promise if the note says where the
        // measurement lives. Floor the match count so renaming the surfaces reds here.
        let mechanismRows = ["local_stt", "tts_speech", "screenshot_capture"]
        var matched = 0
        for name in mechanismRows {
            guard let line = RuntimeCapability.lines.first(where: { $0.name == name }) else {
                continue
            }
            matched += 1
            #expect(
                line.note.contains("/v1/multimodal/status"),
                "\(name) states a mechanism without naming the surface that measures it: \(line.note)"
            )
        }
        #expect(
            matched == mechanismRows.count,
            "scan matched \(matched)/\(mechanismRows.count) — rows renamed?")
    }

    @Test("measured capture failure degrades the row and quotes the framework")
    func measuredFailureDegrades() throws {
        let out = RuntimeCapability.measured(
            .init(screenshot: .failed, screenshotError: "无法开始流播放"))
        let screen = try Self.row(out, "screenshot_capture")
        #expect(screen.available == false, "a measured failure must not stay available")
        #expect(
            screen.note.hasPrefix("Measured on this box: capture failed — 无法开始流播放"),
            "the framework's own words must be quoted, not paraphrased: \(screen.note)")
        // The tier explanation stays attached: the reader still needs to know which half
        // of the answer is hardware and which is measurement.
        #expect(screen.note.contains("tier floor"), "tier context lost: \(screen.note)")
    }

    @Test("no error string ⇒ still a failure, with a plain-language reason")
    func measuredFailureWithoutReason() throws {
        let screen = try Self.row(
            RuntimeCapability.measured(.init(screenshot: .failed)), "screenshot_capture")
        #expect(screen.available == false)
        #expect(
            screen.note.contains("the capture pass produced no frame"),
            "an unexplained refusal is still a refusal: \(screen.note)")
    }

    @Test("a frame earns the claim, with its latency")
    func measuredCaptureEarnsClaim() throws {
        let base = try Self.row(RuntimeCapability.lines, "screenshot_capture")
        let screen = try Self.row(
            RuntimeCapability.measured(
                .init(screenshot: .captured, screenshotLatencyMs: 1102)), "screenshot_capture")
        #expect(
            screen.available == base.available, "a frame cannot switch on a tier-unavailable row")
        #expect(
            screen.note.hasPrefix("Measured on this box: a frame was delivered in 1102 ms"),
            "the claim carries its evidence: \(screen.note)")
    }

    @Test("the verdict is not sticky — the next attempt overwrites it")
    func notSticky() throws {
        let failed = try Self.row(
            RuntimeCapability.measured(.init(screenshot: .failed, screenshotError: "no stream")),
            "screenshot_capture")
        let recovered = try Self.row(
            RuntimeCapability.measured(.init(screenshot: .captured, screenshotLatencyMs: 900)),
            "screenshot_capture")
        #expect(failed.available == false)
        #expect(recovered.available == true, "a fixed capture must be reportable without a restart")
        // The *verdict* clause is what must not go stale. The tier note keeps its
        // historical citation ("measured 10-15 … failed to start"), which is prose about a
        // past box, not this process's claim.
        #expect(
            !recovered.note.hasPrefix("Measured on this box: capture failed"),
            "the previous attempt is still being reported as the verdict: \(recovered.note)")
    }

    // MARK: - Video input: measured, per model and in aggregate

    @Test("aggregate counts models apart from turns and parts")
    func aggregateMath() {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "hf:a", items: 4, promptTokens: 856)
        ledger.record(modelId: "hf:a", items: 1, promptTokens: nil)
        ledger.record(modelId: "hf:b", items: 1, promptTokens: 712)
        let agg = ledger.aggregate()
        #expect(agg == VideoDeliveryAggregate(models: 2, turns: 3, items: 6))
        #expect(!agg.isEmpty)
        // A snapshot is the same ledger the /v1/models route already took.
        #expect(VideoDeliveryLedger.aggregate(ledger.deliveries) == agg)
    }

    @Test("an empty ledger aggregates to the explicit negative, never a claim")
    func aggregateEmpty() {
        let agg = VideoDeliveryLedger().aggregate()
        #expect(agg.isEmpty)
        #expect(agg == VideoDeliveryAggregate(models: 0, turns: 0, items: 0))
    }

    @Test("aggregate wording is exact and says how many models")
    func aggregateWording() {
        let agg = VideoDeliveryAggregate(models: 2, turns: 3, items: 6)
        #expect(
            agg.evidenceLine
                == "delivered across 2 model(s) in 3 completed turn(s), 6 video part(s) on this server"
        )
    }

    @Test("the aggregate sentence is not the per-model sentence, and both are quoted")
    func twoGranularitiesOneSource() throws {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "hf:a", items: 3, promptTokens: 856)
        let perModel = try #require(ledger.evidence(modelId: "hf:a"))
        let aggregate = ledger.aggregate().evidenceLine
        // Both come from the ledger, and each states the fact its surface can support.
        #expect(
            perModel
                == "delivered in 1 completed turn(s), 3 video part(s), last prompt_tokens 856 on this server"
        )
        #expect(
            aggregate
                == "delivered across 1 model(s) in 1 completed turn(s), 3 video part(s) on this server"
        )
        #expect(perModel != aggregate, "one sentence cannot serve two granularities")

        let out = RuntimeCapability.measured(.init(video: ledger.aggregate()))
        let video = try Self.row(out, "video_input")
        #expect(video.available == true)
        #expect(
            video.note.hasPrefix(aggregate),
            "the wire re-words the ledger's sentence: \(video.note)")
        #expect(
            video.note.contains("/v1/models"), "per-model detail must be reachable: \(video.note)")
    }

    @Test("an unload drops the aggregate with the weights")
    func forgetDropsAggregate() throws {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "hf:a", items: 2)
        ledger.forget(modelId: "hf:a")
        #expect(ledger.aggregate().isEmpty)
        let video = try Self.row(
            RuntimeCapability.measured(.init(video: ledger.aggregate())), "video_input")
        #expect(video.available == false, "the server kept claiming video after the model left")
    }

    // MARK: - Labels, and the router that has to use all of this

    @Test("every published row has a display label")
    func labelsCoverOverlayRow() {
        let labels = RuntimeCapability.measured(.unmeasured).map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty && !$0.contains("_") }, "labels: \(labels)")
        #expect(Set(labels).count == labels.count, "duplicate labels: \(labels)")
        #expect(labels.contains("Video input"))
    }

    @Test("the capabilities route reads the records instead of the bare tier matrix")
    func routerIsWired() throws {
        let router = try Self.repoFile(
            "Sources/ocoreai/Router/ChatCompletionsRouter.swift")
        #expect(router.count > 50_000, "router read looks truncated (\(router.count) chars)")
        #expect(
            router.contains("RuntimeCapability.measured("),
            "/v1/capabilities publishes the tier matrix without the measured overlay")
        // One snapshot backs both surfaces; two reads of two ledgers would be two truths.
        #expect(
            router.components(separatedBy: "enginePool.videoDeliverySnapshot()").count - 1 >= 2,
            "videoDeliverySnapshot() must be read by both /v1/models and /v1/capabilities")
        #expect(
            router.contains("ScreenDeliveryRecord.outcome"),
            "the screen row is overlaid from the record that capture writes")
    }

    private static func repoFile(_ relative: String) throws -> String {
        let repo = try Self.repoRoot()
        let url = URL(fileURLWithPath: repo).appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Find the repo by searching, never by fixed parent hops (a fixed hop lands in `Tests/`
    /// and turns a broken scan into an ENOENT that reads as a pass).
    private static func repoRoot() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                return url.path
            }
        }
        throw RepoScanError.repoRootNotFound(#filePath)
    }
}
