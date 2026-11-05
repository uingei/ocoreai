// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// The dashboard renders numbers it did not measure: it parses the Prometheus text the engine
/// exports. That parse is a claim of its own, and the TTFB half of it was wrong in two ways at once.
///
/// ① It divided `ocoreai_ttfb_seconds_sum` by `ocoreai_inference_duration_seconds_count` — every
/// turn that ran — while the numerator counts only the turns that had a first byte. Measured live
/// 11-05 on a server holding one non-streaming and two streaming turns: sum 1.345411, TTFB samples
/// 4, inference observations 3, so the dashboard printed **448 ms** for the honest 336 ms mean the
/// server itself published on `/v1/stats` (`avgTTFBSeconds`). Those two errors ran in opposite
/// directions only while the doubled producer was still live: with the producer fixed, this
/// denominator prints 224 ms for the same 336 ms truth, which is why both landed in one round.
/// ② It computed that quotient on the line where the sum appeared, so it silently fell through to
/// the `ttft_ms` fallback whenever the exporter printed the TTFB histogram before the inference one
/// — the value depended on the order of two unrelated blocks in `Metrics.swift`.
///
/// Both are pinned here at exact values, with the mixed workload that shows ① and a hand-written
/// export that shows ②.

import Foundation
import Testing

@testable import ocoreai

@Suite("Dashboard metrics honesty")
struct DashboardMetricsHonestyTests {

    @Test("TTFB divides by the turns that had a first byte, not by every turn that ran")
    func ttfbDividesByItsOwnSampleCount() async {
        let metrics = MetricsRegistry()
        // Two streamed turns (first bytes at 100 ms and 300 ms) plus one turn that never streamed,
        // which enters the inference histogram and no TTFB sample.
        await metrics.observeInferenceDuration(
            ms: 500, inputTokens: 10, outputTokens: 5, ttfbMs: "100", modelId: "m")
        await metrics.observeInferenceDuration(
            ms: 700, inputTokens: 10, outputTokens: 7, ttfbMs: "300", modelId: "m")
        await metrics.observeInferenceDuration(
            ms: 900, inputTokens: 10, outputTokens: 9, ttfbMs: "0", modelId: "m")
        let text = await metrics.export()
        guard let snapshot = MetricsSnapshot.parse(from: text) else {
            Issue.record("the parse answered nothing for the exporter's own output:\n\(text)")
            return
        }
        // (100 + 300) / 2, not (100 + 300) / 3.
        let relevant = text.split(separator: "\n")
            .filter { $0.contains("ttfb") || $0.contains("inference_duration") }
            .joined(separator: "\n")
        #expect(
            snapshot.ttfbMs == 200.0,
            """
            expected 200 ms over two first-byte samples; the wrong denominator reads 133.33 \
            (every turn that ran):
            \(relevant)
            """)
        #expect(
            snapshot.inferenceCount == 3,
            "the turn count the dashboard prints must still be every turn that ran")
    }

    @Test("the value does not depend on which histogram the exporter printed first")
    func parseIsOrderIndependent() throws {
        // The TTFB block placed BEFORE the inference block — a legal export the exporter does not
        // emit today, and the shape that made the inline quotient fall through to `ttft_ms`.
        let ttfbFirst = """
            ocoreai_ttft_ms 42
            ocoreai_ttfb_seconds_sum 0.400000
            ocoreai_ttfb_seconds_count 2
            ocoreai_inference_duration_seconds_sum 2.100000
            ocoreai_inference_duration_seconds_count 3
            """
        guard let snapshot = MetricsSnapshot.parse(from: ttfbFirst) else {
            Issue.record("the parse answered nothing")
            return
        }
        #expect(
            snapshot.ttfbMs == 200.0,
            "an exporter reorder silently substituted the TTFT gauge (42) for the TTFB mean (200)")
        #expect(snapshot.inferenceCount == 3)
    }

    @Test("a server that has never streamed falls back to the TTFT gauge, not to a 0")
    func freshExportFallsBackToTtft() throws {
        let onlyTtft = """
            ocoreai_ttft_ms 42
            ocoreai_ttfb_seconds_sum 0.000000
            ocoreai_ttfb_seconds_count 0
            ocoreai_inference_duration_seconds_count 1
            """
        let snapshot = try #require(MetricsSnapshot.parse(from: onlyTtft))
        #expect(
            snapshot.ttfbMs == 42.0,
            "no first-byte sample yet, so the gauge it falls back to must be named by the value")
    }
}
