// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TTSFilterConfigTests.swift — Tests for TTS output filtering config validation

import Testing
import Foundation
@testable import ocoreai

@Suite("TTSFilterConfig")
struct TTSFilterConfigTests {
    @Test("defaults are valid")
    func defaults() {
        let config = TTSFilterConfig()
        #expect(config.enabled == true)
        #expect(config.minContentLength == 10)
        #expect(config.speechRate == 1.0)
        #expect(config.maxUtteranceDuration == 30)
        #expect(config.progressiveMode == false)
        #expect(config.progressiveDebounceMs == 200)
    }

    @Test("validate clamps speechRate to 0.5-2.0")
    func validateSpeechRate() {
        var config = TTSFilterConfig()
        config.speechRate = 0.0
        config.validate()
        #expect(config.speechRate == 0.5)

        config.speechRate = 5.0
        config.validate()
        #expect(config.speechRate == 2.0)
    }

    @Test("validate clamps minContentLength to 0-1000")
    func validateMinContentLength() {
        var config = TTSFilterConfig()
        config.minContentLength = -10
        config.validate()
        #expect(config.minContentLength == 0)

        config.minContentLength = 9999
        config.validate()
        #expect(config.minContentLength == 1000)
    }

    @Test("validate clamps maxUtteranceDuration to 1-120")
    func validateMaxUtteranceDuration() {
        var config = TTSFilterConfig()
        config.maxUtteranceDuration = 0
        config.validate()
        #expect(config.maxUtteranceDuration == 1)

        config.maxUtteranceDuration = 300
        config.validate()
        #expect(config.maxUtteranceDuration == 120)
    }

    @Test("default blockPatterns covers expected categories")
    func blockPatternsCover() {
        let patterns = TTSFilterConfig.default.blockPatterns
        #expect(patterns.count >= 4)
        // Code blocks, thinking tags, tool calls, pure JSON all present
        var hasCodeBlock: Bool = false, hasThinking = false, hasToolCall = false, hasJSON = false
        for p in patterns {
            if p.hasPrefix("^```") { hasCodeBlock = true }
            if p.contains("thinking") { hasThinking = true }
            if p == "tool_call" { hasToolCall = true }
            if p.hasPrefix("^\\{") { hasJSON = true }
        }
        #expect(hasCodeBlock)
        #expect(hasThinking)
        #expect(hasToolCall)
        #expect(hasJSON)
    }
}
