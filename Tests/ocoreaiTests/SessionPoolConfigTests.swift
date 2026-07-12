// Copyright © 2026 uingei@163.com.
// SessionPoolConfigTests.swift — Config defaults, poolKey format, stats math
//
// Coverage: SessionPoolConfig struct validation and hit-rate formula verification.
//
// Rationale: SessionPoolConfig is pure data — no hardware needed.
// The MLXSessionPool actor is #if mlx gated and requires GPU, so we test
// the config struct and derived formulas directly without actors.

import Testing
import Foundation
@testable import ocoreai
@testable import ocoreaiTestUtilities

// Helper: replicates the poolKey format from MLXSessionPool
private func makePoolKey(modelId: String, conversationId convId: String) -> String {
    "\(modelId):\(convId)"
}

// Helper: computes hit rate the same way SessionPool.stats() does
// Formula: hitCount / (hitCount + missCount) * 100
private func computeHitRate(hitCount: Int, missCount: Int) -> Double {
    let total = hitCount + missCount
    return total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
}

@Suite("SessionPoolConfig — defaults and validation")
struct SessionPoolConfigTests {
    // Tags: testTags.scope.unit, testTags.domain.inference

    @Test("Default config has expected values")
    func defaults() {
        let config = SessionPoolConfig.default
        #expect(config.enabled == true)
        #expect(config.sessionTTLSeconds == 600)
        #expect(config.maxSessions == 16)
        #expect(config.metricsLogInterval == 100)
        #expect(config.persistCache == true)
        #expect(config.cacheDirectory == nil)
    }

    @Test("Custom config overrides all fields")
    func customValues() {
        let dir = URL(fileURLWithPath: "/tmp/ocoreai/kvcache")
        var config = SessionPoolConfig()
        config.enabled = false
        config.sessionTTLSeconds = 300
        config.maxSessions = 8
        config.metricsLogInterval = 50
        config.persistCache = false
        config.cacheDirectory = dir

        #expect(config.enabled == false)
        #expect(config.sessionTTLSeconds == 300)
        #expect(config.maxSessions == 8)
        #expect(config.metricsLogInterval == 50)
        #expect(config.persistCache == false)
        #expect(config.cacheDirectory?.absoluteString == dir.absoluteString)
    }

    @Test("poolKey format is modelId:convId")
    func poolKeyFormat() {
        let key = makePoolKey(modelId: "llama-3.1", conversationId: "conv-abc")
        #expect(key == "llama-3.1:conv-abc")
        #expect(key.contains(":"))
        #expect(key.split(separator: ":").count == 2)
    }

    @Test("Stats hit rate: hit=3, miss=7 → 30%")
    func hitRate30Pct() {
        let rate = computeHitRate(hitCount: 3, missCount: 7)
        #expect(rate == 30.0)
    }

    @Test("Stats hit rate: hit=0, miss=10 → 0%")
    func hitRate0Pct() {
        let rate = computeHitRate(hitCount: 0, missCount: 10)
        #expect(rate == 0.0)
    }

    @Test("Stats hit rate: hit=5, miss=0 → 100%")
    func hitRate100Pct() {
        let rate = computeHitRate(hitCount: 5, missCount: 0)
        #expect(rate == 100.0)
    }
}
