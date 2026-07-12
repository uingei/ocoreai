// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PerRequestMetricsTests.swift — 推理指标追踪的纯函数验证
///
/// PerRequestMetrics is instantiated per-request, never shared — safe to test
/// as a direct unit. Tracks timing, token counts, throughput.
///
/// Tests follow upstream pattern: read actual source before asserting values.
/// Reference: TimingHooks.swift

import Testing
import Foundation
@testable import ocoreai
import ocoreaiTestUtilities

@Suite("PerRequestMetrics — request timing lifecycle")
struct PerRequestMetricsTests {
    
    // MARK: - Defaults
    
    @Test("Fresh instance has zero tokens and no timer")
    func freshDefaults() {
        let m = PerRequestMetrics()
        #expect(m.promptTokenCount == 0)
        #expect(m.generatedTokenCount == 0)
        #expect(m.totalTokenCount == 0)
        #expect(m.tokenizationMs == 0)
        #expect(m.inferenceMs == 0)
        #expect(m.firstTokenMs == 0)
    }
    
    @Test("overallMs before start() returns 0")
    func overallMsBeforeStart() {
        let m = PerRequestMetrics()
        #expect(m.overallMs == 0)
    }
    
    // MARK: - Timing
    
    @Test("start() enables overallMs timer")
    func startEnablesTimer() {
        let m = PerRequestMetrics()
        m.start()
        #expect(m.overallMs >= 0)
    }
    
    @Test("overallMs increases after sleep")
    func overallMsIncreases() async {
        let m = PerRequestMetrics()
        m.start()
        try? await Task.sleep(for: .milliseconds(50))
        let after = m.overallMs
        #expect(after >= 1)
        #expect(after < 5000)  // generous bound for CI jitter
    }
    
    // MARK: - Token counting
    
    @Test("incrementGenerated increases count")
    func incrementWork() {
        let m = PerRequestMetrics()
        m.incrementGenerated()
        #expect(m.generatedTokenCount == 1)
        m.incrementGenerated()
        m.incrementGenerated()
        #expect(m.generatedTokenCount == 3)
    }
    
    @Test("totalTokenCount sums prompt + generated")
    func totalSum() {
        let m = PerRequestMetrics()
        m.promptTokenCount = 10
        m.incrementGenerated()
        m.incrementGenerated()
        #expect(m.totalTokenCount == 12)
    }
    
    // MARK: - Throughput
    
    @Test("promptThroughput is 0 when inferenceMs not set")
    func throughputZeroWhenNoInference() {
        let m = PerRequestMetrics()
        m.promptTokenCount = 10
        #expect(m.promptThroughput == 0)
    }
    
    @Test("generationThroughput is 0 when generatedTokenCount is 0")
    func genThroughputZero() {
        let m = PerRequestMetrics()
        m.inferenceMs = 100
        #expect(m.generationThroughput == 0)
    }
    
    @Test("generationThroughput calculates correctly")
    func genThroughputCalc() {
        let m = PerRequestMetrics()
        m.inferenceMs = 1000  // 1 second
        m.promptTokenCount = 100
        for _ in 0..<50 { m.incrementGenerated() }
        // promptThroughput = 100 / (1000/1000) = 100 tok/s
        #expect(m.promptThroughput == 100)
        // genThroughput = 50 / (1000/1000) = 50 tok/s
        #expect(m.generationThroughput == 50)
    }
    
    // MARK: - Summary
    
    @Test("summary includes model id and token counts")
    func summaryFormat() {
        let m = PerRequestMetrics()
        m.start()
        m.promptTokenCount = 10
        for _ in 0..<5 { m.incrementGenerated() }
        m.inferenceMs = 200
        m.firstTokenMs = 50
        let s = m.summary(modelId: "test-model")
        #expect(s.contains("test-model"))
        #expect(s.contains("prompt=10"))
        #expect(s.contains("gen=5"))
        #expect(s.contains("[metrics]"))
    }
}
