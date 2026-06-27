// MetricsRegistryTests.swift — Metrics registry correctness
//
// Tests counter increments, histogram observations, and Prometheus export format.

import Testing
@testable import ocoreai

@Suite("MetricsRegistry")
struct MetricsRegistryTests {
    @Test("counter increments correctly")
    func testCounterIncrement() async {
        let registry = MetricsRegistry()
        await registry.incrementHTTPRequest(method: "GET", path: "/health", status: 200)
        await registry.incrementHTTPRequest(method: "POST", path: "/v1/chat/completions", status: 200)
        await registry.incrementHTTPRequest(method: "GET", path: "/health", status: 200)

        let output = await registry.export()
        #expect(output.contains("ocoreai_http_requests_total{method=\"GET\",path=\"/health\",status=\"200\"} 2"))
        #expect(output.contains("ocoreai_http_requests_total{method=\"POST\",path=\"/v1/chat/completions\",status=\"200\"} 1"))
    }

    @Test("histogram buckets accumulate correctly")
    func testHistogramObservation() async {
        let registry = MetricsRegistry()
        await registry.observeInferenceDuration(0.05)
        await registry.observeInferenceDuration(0.3)
        await registry.observeInferenceDuration(5.0)

        let output = await registry.export()
        #expect(output.contains("ocoreai_inference_duration_seconds_bucket"))
        #expect(output.contains("ocoreai_inference_duration_seconds_count 3"))
        #expect(output.contains("ocoreai_inference_duration_seconds_sum"))
    }

    @Test("gauge updates reflect latest value")
    func testGaugeUpdate() async {
        let registry = MetricsRegistry()
        await registry.updateActiveSessions(0)
        await registry.updateActiveSessions(5)
        await registry.updateActiveSessions(3)

        let output = await registry.export()
        #expect(output.contains("ocoreai_engine_pool_active_sessions 3"))

        await registry.updateLoadedModels(2)
        let output2 = await registry.export()
        #expect(output2.contains("ocoreai_engine_pool_loaded_models 2"))
    }

    @Test("prometheus format contains required sections")
    func testExportFormat() async {
        let registry = MetricsRegistry()
        let output = await registry.export()

        #expect(output.contains("# TYPE ocoreai_http_requests_total counter"))
        #expect(output.contains("# TYPE ocoreai_inference_duration_seconds histogram"))
        #expect(output.contains("# TYPE ocoreai_ttfb_seconds histogram"))
        #expect(output.contains("# TYPE ocoreai_engine_pool_active_sessions gauge"))
        #expect(output.contains("ocoreai_build"))
    }
}

