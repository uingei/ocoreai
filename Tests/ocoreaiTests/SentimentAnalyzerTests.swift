// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SentimentAnalyzerTests.swift — Keyword-based sentiment analysis
///
/// Coverage: polarity classification, compound scoring, emoji detection,
/// batch analysis, high-risk flag, and edge cases.

import Testing
import Foundation
@testable import ocoreai

@Suite("SentimentAnalyzer Polarity Classification")
struct SentimentPolarityTests {
    let analyzer = SentimentAnalyzer()

    @Test("positive text classified as positive")
    func positiveText() {
        let result = analyzer.analyze("This is great and I love it, excellent!")
        #expect(result.polarity == .positive || result.polarity == .veryPositive)
        #expect(result.compound > 0)
    }

    @Test("negative text classified as negative")
    func negativeText() {
        let result = analyzer.analyze("This is terrible and awful, worst experience")
        #expect(result.polarity == .negative || result.polarity == .veryNegative)
        #expect(result.compound < 0)
    }

    @Test("neutral text classified as neutral")
    func neutralText() {
        let result = analyzer.analyze("The weather is okay today")
        #expect(result.polarity == .neutral)
        #expect(result.compound >= -0.2)
        #expect(result.compound < 0.2)
    }

    @Test("very negative triggers high risk flag")
    func highRiskFlag() {
        let result = analyzer.analyze("This is the worst, I hate it, terrible garbage useless")
        #expect(result.isHighRisk)
    }

    @Test("positive text is not high risk")
    func notHighRisk() {
        let result = analyzer.analyze("This is great, I love it!")
        #expect(result.isHighRisk == false)
    }
}

@Suite("SentimentAnalyzer Emoji Detection")
struct SentimentEmojiTests {
    let analyzer = SentimentAnalyzer()

    @Test("happy emoji detected")
    func happyEmoji() {
        let result = analyzer.analyze("I am happy 😊")
        #expect(result.emotions.contains("happy"))
    }

    @Test("anger emoji detected")
    func angerEmoji() {
        let result = analyzer.analyze("I am so angry 😡")
        #expect(result.emotions.contains("anger"))
    }

    @Test("Chinese emotion indicator detected")
    func chineseEmotionIndicator() {
        let result = analyzer.analyze("谢谢你的帮助")
        #expect(result.emotions.contains("grateful"))
    }

    @Test("multiple emotions detected")
    func multipleEmotions() {
        let result = analyzer.analyze("😊😢 happy then sad")
        #expect(result.emotions.contains("happy"))
        #expect(result.emotions.contains("sad"))
    }
}

@Suite("SentimentAnalyzer Scoring")
struct SentimentScoringTests {
    let analyzer = SentimentAnalyzer()

    @Test("positive ratio calculated correctly")
    func positiveRatio() {
        let result = analyzer.analyze("good great excellent")
        #expect(result.positiveRatio > 0)
        #expect(result.negativeRatio == 0)
    }

    @Test("negative ratio calculated correctly")
    func negativeRatio() {
        let result = analyzer.analyze("bad terrible awful")
        #expect(result.negativeRatio > 0)
        #expect(result.positiveRatio == 0)
    }

    @Test("mixed text has balanced ratios")
    func mixedRatios() {
        let result = analyzer.analyze("good bad excellent terrible")
        #expect(result.positiveRatio > 0)
        #expect(result.negativeRatio > 0)
    }

    @Test("compound score in valid range [-1, 1]")
    func compoundInRange() {
        let result = analyzer.analyze("some random text")
        #expect(result.compound >= -1.0)
        #expect(result.compound <= 1.0)
    }

    @Test("unicode text (Chinese) analyzed without crash — splits on whitespace so Chinese chars not matched")
    func chineseTextNoCrash() {
        // Analyzer splits on whitespace; Chinese has no spaces so keyword matching won't hit
        // but it must not crash
        let result = analyzer.analyze("这个功能很棒，非常好用")
        #expect(result.polarity == .neutral)
        #expect(result.compound == 0)
    }
}

@Suite("SentimentAnalyzer Batch Analysis")
struct SentimentBatchTests {
    let analyzer = SentimentAnalyzer()

    @Test("batch returns correct count")
    func batchSize() {
        let texts = ["good", "bad", "ok"]
        let results = analyzer.analyze(texts)
        #expect(results.count == 3)
    }

    @Test("batch preserves order")
    func batchOrder() {
        let texts = ["excellent!", "terrible experience"]
        let results = analyzer.analyze(texts)
        #expect(results[0].compound > 0)
        #expect(results[1].compound < 0)
    }

    @Test("empty batch returns empty")
    func emptyBatch() {
        let results = analyzer.analyze([])
        #expect(results.isEmpty)
    }
}
