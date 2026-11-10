// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Every series `GET /metrics` exports must have a producer, and the exporter must read the
/// very object those producers count into.
///
/// Measured before this suite: six recorders sat in `MetricsRegistry` with no producer on the
/// shipping path — `recordAuthFailure`, `recordRateLimitRejection`, `recordModelLoad`,
/// `recordModelLoadFailure`, TTFB, `incrementKVEvictions` — so those series
/// published a flat zero no matter what the process did, and the app container handed the
/// exporter its own private registry. A zero that cannot move is indistinguishable from
/// "nothing went wrong": invariant 2 wearing a Prometheus header.
///
/// The TTFB half of that diagnosis was wrong in the safe direction and cost the opposite error:
/// the streaming lane already handed its timed first byte to `observeInferenceDuration`, which
/// counts it. Adding a second, direct `observeTTFB` there did not create a producer, it doubled
/// one — see `ttfbIsCountedExactlyOncePerFirstByte`, which is where the series' one-home rule lives.
///
/// Each row pins the call at the chokepoint where the event is decided (not near the exporter),
/// and every scan floors its own premises so a regex that stopped matching fails the run. The TTFB
/// row is the shaped exception: its event is a *duration the lane hands over*, so the decision that
/// owns the count is the recorder's `> 0` guard, and the row names that file.

import Foundation
import Testing

@testable import ocoreai

private func metricsRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func readSource(_ relative: String) throws -> String {
    let url = metricsRoot().appendingPathComponent(relative)
    return try String(contentsOf: url, encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

/// One exported series, the call that must produce it, the file that owns that decision, and
/// the exact line a fresh registry must export for it.
private struct Producer: Sendable {
    let series: String
    let call: String
    let file: String
    let zeroLine: String
}

private let producers: [Producer] = [
    Producer(
        series: "ocoreai_auth_failures_total",
        call: "recordAuthFailure()",
        file: "Sources/ocoreai/Middleware/AuthMiddleware.swift",
        zeroLine: "ocoreai_auth_failures_total 0"
    ),
    Producer(
        series: "ocoreai_rate_limit_rejections_total",
        call: "recordRateLimitRejection()",
        file: "Sources/ocoreai/Middleware/RateLimitMiddleware.swift",
        zeroLine: "ocoreai_rate_limit_rejections_total 0"
    ),
    Producer(
        series: "ocoreai_model_loads_total",
        call: "recordModelLoad()",
        file: "Sources/ocoreai/Engine/EnginePool.swift",
        zeroLine: "ocoreai_model_loads_total 0"
    ),
    Producer(
        series: "ocoreai_model_load_failures_total",
        call: "recordModelLoadFailure()",
        file: "Sources/ocoreai/Engine/EnginePool.swift",
        zeroLine: "ocoreai_model_load_failures_total 0"
    ),
    Producer(
        series: "ocoreai_ttfb_seconds",
        call: "observeTTFB(ttfbSeconds / 1000.0)",
        file: "Sources/ocoreai/Metrics/Metrics.swift",
        zeroLine: "ocoreai_ttfb_seconds_count 0"
    ),
    Producer(
        series: "ocoreai_kv_cache_evictions_total",
        call: "incrementKVEvictions(",
        file: "Sources/ocoreai/Engine/SessionPool.swift",
        zeroLine: "ocoreai_kv_cache_evictions_total 0"
    ),
]

@Suite("Metric producers")
struct MetricProducerWiringTests {

    @Test("the scan floors its own premises, and every name in the header reaches the exporter")
    fileprivate func scanFloorsItsOwnPremises() async throws {
        #expect(
            producers.count == 6,
            "this suite exists to hold six producers; a shorter list is a vacuous pass")
        let metrics = try readSource("Sources/ocoreai/Metrics/Metrics.swift")
        let header = String(
            metrics.prefix(upTo: metrics.range(of: "\nimport ")?.lowerBound ?? metrics.endIndex))
        guard let re = try? NSRegularExpression(pattern: "`(ocoreai_[a-z0-9_]+)`") else {
            Issue.record("the header-name regex stopped compiling")
            return
        }
        let headerRange = NSRange(header.startIndex ..< header.endIndex, in: header)
        var named: [String] = []
        for match in re.matches(in: header, range: headerRange) {
            guard let range = Range(match.range(at: 1), in: header) else { continue }
            named.append(String(header[range]))
        }
        #expect(
            named.count >= 12,
            "the exported-series header stopped enumerating (\(named.count) names)")
        let output = await MetricsRegistry().export()
        for name in named {
            // Prometheus puts a label set or a suffix between the name and its value: a
            // labeled counter exports `name{k="v"} N`, a histogram `name_count N`. A name in
            // the doc header that matches none of these shapes is documented but not exported.
            #expect(
                output.contains("\(name) ") || output.contains("\(name){")
                    || output.contains("\(name)_count "),
                "\(name) is documented as exposed but never exported"
            )
        }
    }

    @Test("each exported series has its producer at the chokepoint", arguments: producers)
    fileprivate func producerExistsAtChokepoint(_ producer: Producer) throws {
        let text = try readSource(producer.file)
        #expect(
            text.contains(producer.call),
            "\(producer.series) can never move: no \(producer.call) in \(producer.file)"
        )
    }

    /// Membership is derived from the registry's own `func` declarations, not from the list above.
    /// The enumerated rows pin *where* each known series is produced; they can never see a seventh
    /// recorder added without a producer, and that is the exact defect this suite was built on —
    /// a series that exports a flat zero no matter what the process does. The scan fails it at
    /// add time instead of at the next manual audit. A recorder named outside the three verbs is
    /// the known hole in the derivation; the doc-header scan above is its backstop.
    @Test("every recorder the registry declares is called by someone")
    func noDeclaredRecorderIsDead() async throws {
        let metrics = try readSource("Sources/ocoreai/Metrics/Metrics.swift")
        guard
            let re = try? NSRegularExpression(
                pattern: "func ((?:record|observe|increment)[A-Z][A-Za-z0-9]*)\\(")
        else {
            Issue.record("the recorder-derivation regex stopped compiling")
            return
        }
        var recorders: Set<String> = []
        let full = NSRange(metrics.startIndex ..< metrics.endIndex, in: metrics)
        for match in re.matches(in: metrics, range: full) {
            guard let range = Range(match.range(at: 1), in: metrics) else { continue }
            recorders.insert(String(metrics[range]))
        }
        #expect(
            recorders.count >= 8,
            """
            the derivation found \(recorders.count) recorders — the registry changed shape, \
            re-read it before trusting a pass
            """)

        let sourcesRoot = metricsRoot().appendingPathComponent("Sources").path
        let walk = (try? FileManager.default.subpathsOfDirectory(atPath: sourcesRoot)) ?? []
        let files = walk.filter { $0.hasSuffix(".swift") }.map { "Sources/" + $0 }
        #expect(
            files.count >= 200,
            "the Sources walk found only \(files.count) files — a stopped scan would pass vacuously"
        )
        var deadRecorders: [String] = []
        for recorder in recorders {
            var hits = 0
            for file in files {
                guard let text = try? readSource(file) else { continue }
                hits += occurrences(of: "\(recorder)(", in: text)
            }
            // One occurrence is the declaration alone; a recorder nobody calls exports a zero
            // that can never move.
            if hits < 2 { deadRecorders.append(recorder) }
        }
        #expect(
            deadRecorders.isEmpty,
            "recorders with no call site (their series export a permanent zero): \(deadRecorders)")
    }

    @Test(
        "a fresh registry exports each series at zero, with the header name spelled alike",
        arguments: producers
    )
    fileprivate func exportCarriesEveryName(_ producer: Producer) async {
        let output = await MetricsRegistry().export()
        #expect(output.contains(producer.zeroLine), "export missing \(producer.zeroLine)")
    }

    @Test("the exporter reads the registry the producers count into")
    func oneRegistryForProducerAndExporter() throws {
        let metrics = try readSource("Sources/ocoreai/Metrics/Metrics.swift")
        #expect(metrics.contains("static let shared = MetricsRegistry()"))
        let app = try readSource("Sources/ocoreai/App.swift")
        #expect(
            app.contains("metrics = MetricsRegistry.shared"),
            "App must publish the shared registry; a private instance orphans every series counted elsewhere"
        )
    }

    /// The sample has exactly one home. The 10-25 round that added a direct `observeTTFB` beside
    /// the streaming duration call believed the series had no producer; it had one, in the recorder
    /// the very next statement hands the value to — so every streamed turn entered the histogram
    /// twice. Measured live before this fix: one streaming turn moved `/v1/stats`
    /// `ttfbSampleCount` 0 → 2 and `ocoreai_ttfb_seconds_count` 2 → 4 while `totalRequests` moved
    /// by one. The average hid it (numerator and denominator both doubled); only the counts lied.
    @Test("one first byte is one TTFB sample, and no first byte is none")
    func ttfbIsCountedExactlyOncePerFirstByte() async throws {
        let lane = try readSource("Sources/ocoreai/Handlers/ChatHandler.swift")
        // The lane times the first byte (only it knows whether one exists) and hands the value
        // down; it must not also count it. The recorder below skips a zero, which is how a turn
        // that emitted nothing stays out of the latency curve.
        #expect(
            occurrences(of: "observeTTFB(", in: lane) == 0,
            """
            the streaming lane records TTFB by handing `ttfbMs` to observeInferenceDuration; \
            a direct call beside it counts every streamed turn twice
            """)
        guard let guardRange = lane.range(of: "if let ttfbTimeVal = ttfbTime {") else {
            Issue.record(
                "the first-byte guard is gone — the lane no longer decides whether a first byte exists"
            )
            return
        }
        #expect(
            lane[guardRange.lowerBound...].contains("await metrics.observeInferenceDuration("),
            "the streaming lane no longer hands its timed first byte to the duration recorder")

        // One sample per call, at exact exported values: the zero the guard produces enters nothing,
        // the real value enters once.
        let registry = MetricsRegistry()
        await registry.observeInferenceDuration(
            ms: 900, inputTokens: 40, outputTokens: 12, ttfbMs: "0.0", modelId: "m")
        let afterSilent = await registry.export()
        let silentLines = afterSilent.split(separator: "\n").filter { $0.contains("ttfb") }
            .joined(separator: "\n")
        #expect(
            afterSilent.contains("ocoreai_ttfb_seconds_count 0"),
            "a turn with no first byte entered the latency curve:\n\(silentLines)")
        await registry.observeInferenceDuration(
            ms: 900, inputTokens: 40, outputTokens: 12, ttfbMs: "250.0", modelId: "m")
        let text = await registry.export()
        let ttfbLines = text.split(separator: "\n").filter { $0.contains("ttfb") }.joined(
            separator: "\n")
        #expect(
            text.contains("ocoreai_ttfb_seconds_count 1"),
            "one real first byte must be exactly one sample:\n\(ttfbLines)")
        #expect(
            text.contains("ocoreai_ttfb_seconds_sum 0.250000"),
            "the sum must carry the value once:\n\(ttfbLines)")
    }

    @Test("teardown is not eviction: one home for the KV counter, three counted paths")
    func teardownDoesNotCountAsEviction() throws {
        let text = try readSource("Sources/ocoreai/Engine/SessionPool.swift")
        // The metric call has exactly one home; a second one is where a rule starts to drift.
        #expect(occurrences(of: "incrementKVEvictions(", in: text) == 1)
        // Its funnel is called by the three paths that discard caches while the model stays
        // loaded (pressure flush, TTL sweep, LRU) — not by `clear()` / `clear(modelId:)`.
        #expect(occurrences(of: "noteKVCacheEvictions(", in: text) == 4)
    }
}
