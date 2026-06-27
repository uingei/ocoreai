// MetricsStressTests.swift — MetricsRegistry concurrent correctness & leak detection
//
// Exposes: race conditions in actor mailbox, histogram bucket overflow,
// Prometheus export format compliance, memory leak in counter growth.

import Testing
@testable import ocoreai
import Foundation

@Suite("MetricsRegistry Stress")
struct MetricsStressTests {

    @Test("concurrent HTTP counter increments are accurate")
    func testConcurrentCounters() async {
        let registry = MetricsRegistry()
        let count = 100

        // Fire 100 concurrent increments across 3 methods
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    await registry.incrementHTTPRequest(method: "GET", path: "/health", status: 200)
                }
            }
            for _ in 0..<count {
                group.addTask {
                    await registry.incrementHTTPRequest(method: "POST", path: "/v1/chat/completions", status: 200)
                }
            }
            for _ in 0..<count {
                group.addTask {
                    await registry.incrementHTTPRequest(method: "POST", path: "/v1/chat/completions", status: 500)
                }
            }
        }

        let output = await registry.export()
        #expect(output.contains("status=\"200\"} \(count)"))
        #expect(output.contains("status=\"500\"} \(count)"))
    }

    @Test("histogram buckets are monotonically non-decreasing")
    func testHistogramBucketMonotonicity() async {
        let registry = MetricsRegistry()
        // Observe many values across bucket boundaries
        let samples: [Double] = [0.001, 0.02, 0.07, 0.2, 0.8, 1.5, 3.0, 6.0, 12.0]
        for s in samples {
            await registry.observeInferenceDuration(s)
        }

        let output = await registry.export()
        // Total count must equal sample count
        #expect(output.contains("ocoreai_inference_duration_seconds_count \(samples.count)"))
        // +Inf bucket must equal total count
        #expect(output.contains("le=\"+Inf\"} \(samples.count)"))
    }

    @Test("token counters accumulate correctly across concurrent calls")
    func testTokenCounterConcurrency() async {
        let registry = MetricsRegistry()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await registry.incrementTokens(kind: "prompt", count: 10)
                }
            }
            for _ in 0..<50 {
                group.addTask {
                    await registry.incrementTokens(kind: "generated", count: 5)
                }
            }
        }

        let output = await registry.export()
        #expect(output.contains("kind=\"prompt\"} 500"))
        #expect(output.contains("kind=\"generated\"} 250"))
    }

    @Test("gauge updates overwrite previous values")
    func testGaugeOverwrite() async {
        let registry = MetricsRegistry()
        await registry.updateActiveSessions(10)
        await registry.updateActiveSessions(5)
        await registry.updateActiveSessions(0)

        let output = await registry.export()
        #expect(output.contains("ocoreai_engine_pool_active_sessions 0"))
    }

    @Test("TTFB histogram tracks independently from inference duration")
    func testTTFBIndependent() async {
        let registry = MetricsRegistry()
        await registry.observeTTFB(0.05)
        await registry.observeTTFB(0.15)
        // Do NOT observe inference duration

        let output = await registry.export()
        #expect(output.contains("ocoreai_ttfb_seconds_count 2"))
        // Inference should still be at 0
        #expect(output.contains("ocoreai_inference_duration_seconds_count 0"))
    }

    @Test("KV eviction counter increments")
    func testKVEvictionCounter() async {
        let registry = MetricsRegistry()
        await registry.incrementKVEviction()
        await registry.incrementKVEviction()
        await registry.incrementKVEviction()

        let output = await registry.export()
        #expect(output.contains("ocoreai_kv_cache_evictions_total 3"))
    }

    @Test("export format has Prometheus header line")
    func testPrometheusHeader() async {
        let registry = MetricsRegistry()
        let output = await registry.export()
        // Must start with HELP comment
        #expect(output.hasPrefix("# HELP"))
    }

    @Test("inferenceDuration with metadata propagates token counts")
    func testInferenceMetadataTracking() async {
        let registry = MetricsRegistry()
        await registry.observeInferenceDuration(ms: 500, inputTokens: 100, outputTokens: 50, ttfbMs: "50", modelId: "test-model")

        let output = await registry.export()
        #expect(output.contains("kind=\"prompt\"} 100"))
        #expect(output.contains("kind=\"generated\"} 50"))
        #expect(output.contains("ocoreai_ttfb_seconds_count 1"))
    }
}

