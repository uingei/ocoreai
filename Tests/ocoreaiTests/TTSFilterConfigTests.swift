// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TTSFilterConfigBehavioralTests.swift — TTS filter config validation and
/// block pattern behavioral invariants.
///
/// Focus: config clamping, default values, pattern coverage.
/// Tests real production TTSFilterConfig — same behavior exercised at runtime.

import Testing
@testable import ocoreai

@Suite("TTSFilterConfig — default values")
struct TTSFilterDefaultsTests {
    @Test("enabled defaults to true")
    func enabledDefault() {
        #expect(TTSFilterConfig().enabled == true)
    }

    @Test("minContentLength defaults to 10")
    func minContentLength() {
        #expect(TTSFilterConfig().minContentLength == 10)
    }

    @Test("speechRate defaults to 1.0")
    func speechRate() {
        #expect(TTSFilterConfig().speechRate == 1.0)
    }

    @Test("maxUtteranceDuration defaults to 30")
    func maxUtteranceDuration() {
        #expect(TTSFilterConfig().maxUtteranceDuration == 30.0)
    }

    @Test("progressiveMode defaults to false")
    func progressiveMode() {
        #expect(TTSFilterConfig().progressiveMode == false)
    }

    @Test("progressiveDebounceMs defaults to 200")
    func progressiveDebounceMs() {
        #expect(TTSFilterConfig().progressiveDebounceMs == 200)
    }

    @Test("blockPatterns defaults to 4 patterns")
    func defaultPatternCount() {
        #expect(TTSFilterConfig().blockPatterns.count == 4)
    }
}

@Suite("TTSFilterConfig — validate() clamping")
struct TTSFilterValidationTests {
    @Test("speechRate below minimum clamps to 0.5")
    func speechRateLowerBound() {
        var config = TTSFilterConfig()
        config.speechRate = 0.0
        config.validate()
        #expect(config.speechRate == 0.5)
    }

    @Test("speechRate above maximum clamps to 2.0")
    func speechRateUpperBound() {
        var config = TTSFilterConfig()
        config.speechRate = 5.0
        config.validate()
        #expect(config.speechRate == 2.0)
    }

    @Test("speechRate within bounds is unchanged")
    func speechRateWithinBounds() {
        var config = TTSFilterConfig()
        config.speechRate = 1.5
        config.validate()
        #expect(config.speechRate == 1.5)
    }

    @Test("minContentLength below zero clamps to 0")
    func minContentLengthLower() {
        var config = TTSFilterConfig()
        config.minContentLength = -10
        config.validate()
        #expect(config.minContentLength == 0)
    }

    @Test("minContentLength above 1000 clamps to 1000")
    func minContentLengthUpper() {
        var config = TTSFilterConfig()
        config.minContentLength = 9999
        config.validate()
        #expect(config.minContentLength == 1000)
    }

    @Test("maxUtteranceDuration below 1 clamps to 1")
    func maxDurationLower() {
        var config = TTSFilterConfig()
        config.maxUtteranceDuration = 0
        config.validate()
        #expect(config.maxUtteranceDuration == 1.0)
    }

    @Test("maxUtteranceDuration above 120 clamps to 120")
    func maxDurationUpper() {
        var config = TTSFilterConfig()
        config.maxUtteranceDuration = 300
        config.validate()
        #expect(config.maxUtteranceDuration == 120.0)
    }
}

@Suite("TTSFilterConfig — block pattern coverage")
struct TTSFilterPatternTests {
    @Test("blockPatterns includes code block pattern")
    func hasCodeBlock() {
        let patterns: [String] = TTSFilterConfig().blockPatterns
        #expect(patterns.contains { $0.hasPrefix("^```") })
    }

    @Test("blockPatterns includes thinking tag pattern")
    func hasThinking() {
        let patterns: [String] = TTSFilterConfig().blockPatterns
        #expect(patterns.contains { $0.contains("thinking") })
    }

    @Test("blockPatterns includes tool_call pattern")
    func hasToolCall() {
        let patterns: [String] = TTSFilterConfig().blockPatterns
        #expect(patterns.contains { $0 == "tool_call" })
    }

    @Test("blockPatterns includes JSON pattern")
    func hasJSON() {
        let patterns: [String] = TTSFilterConfig().blockPatterns
        #expect(patterns.contains { $0.hasPrefix("^\\{") })
    }
}