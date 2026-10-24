// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Every series `GET /metrics` exports must have a producer, and the exporter must read the
/// very object those producers count into.
///
/// Measured before this suite: six recorders sat in `MetricsRegistry` with zero call sites in
/// `Sources/` — `recordAuthFailure`, `recordRateLimitRejection`, `recordModelLoad`,
/// `recordModelLoadFailure`, `observeTTFB`, `incrementKVEvictions` — so those six series
/// published a flat zero no matter what the process did, and the app container handed the
/// exporter its own private registry. A zero that cannot move is indistinguishable from
/// "nothing went wrong": invariant 2 wearing a Prometheus header.
///
/// Each row pins the call at the chokepoint where the event is decided (not near the exporter),
/// and every scan floors its own premises so a regex that stopped matching fails the run.

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
        call: "metrics.observeTTFB(",
        file: "Sources/ocoreai/Handlers/ChatHandler.swift",
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
        #expect(producers.count == 6, "this suite exists to hold six producers; a shorter list is a vacuous pass")
        let metrics = try readSource("Sources/ocoreai/Metrics/Metrics.swift")
        let header = String(
            metrics.prefix(upTo: metrics.range(of: "\nimport ")?.lowerBound ?? metrics.endIndex))
        guard let re = try? NSRegularExpression(pattern: "`(ocoreai_[a-z0-9_]+)`") else {
            Issue.record("the header-name regex stopped compiling")
            return
        }
        let headerRange = NSRange(header.startIndex..<header.endIndex, in: header)
        var named: [String] = []
        for match in re.matches(in: header, range: headerRange) {
            guard let range = Range(match.range(at: 1), in: header) else { continue }
            named.append(String(header[range]))
        }
        #expect(named.count >= 12, "the exported-series header stopped enumerating (\(named.count) names)")
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

    @Test("a fresh registry exports each series at zero, with the header name spelled alike",
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

    @Test("the TTFB observation sits inside the first-byte guard, before the duration call")
    func ttfbIsObservedOnlyWhenAFirstByteExists() throws {
        let text = try readSource("Sources/ocoreai/Handlers/ChatHandler.swift")
        // Exactly one observation site: the streaming lane. A turn that emitted nothing has no
        // first byte, so the call must sit inside the guard that establishes one.
        #expect(occurrences(of: "observeTTFB(", in: text) == 1)
        guard let guardRange = text.range(of: "if let ttfbTimeVal = ttfbTime {"),
            let callRange = text.range(of: "await metrics.observeTTFB(")
        else {
            Issue.record("the first-byte guard or its TTFB observation is gone")
            return
        }
        let distance = callRange.lowerBound.utf16Offset(in: text)
            - guardRange.lowerBound.utf16Offset(in: text)
        #expect(
            distance > 0 && distance < 900,
            "TTFB observation is not inside the first-byte guard (offset \(distance) from it)"
        )
        // Same path, later: the duration observation must follow this one (the file holds an
        // earlier duration call on the non-streaming lane, so a whole-file search would lie).
        #expect(
            text[callRange.upperBound...].contains("await metrics.observeInferenceDuration("),
            "the streaming lane no longer observes duration after TTFB"
        )
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
