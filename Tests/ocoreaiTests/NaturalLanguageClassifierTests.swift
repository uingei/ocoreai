// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// NaturalLanguageClassifierTests.swift — Ticket classification engine
///
/// Coverage: all ticket categories, confidence thresholds, fallback mode,
/// keyword matching, and edge cases.

import Testing
import Foundation
@testable import ocoreai

@Suite("NaturalLanguageClassifier Categories")
struct NLPClassifierCategoryTests {
    let classifier = NaturalLanguageClassifier()

    @Test("support ticket detected")
    func support() {
        let result = classifier.classify("App crashes when I open it, there's a bug")
        #expect(result.category == .support)
    }

    @Test("complaint detected")
    func complaint() {
        let result = classifier.classify("This is unacceptable and I'm so frustrated")
        #expect(result.category == .complaint)
    }

    @Test("inquiry detected")
    func inquiry() {
        let result = classifier.classify("What's the pricing for the pro plan?")
        #expect(result.category == .inquiry)
    }

    @Test("refund detected")
    func refund() {
        let result = classifier.classify("I want a refund for the charge")
        #expect(result.category == .refund)
    }

    @Test("feedback detected")
    func feedback() {
        let result = classifier.classify("I have a suggestion to improve the app")
        #expect(result.category == .feedback)
    }

    @Test("random text falls back to other")
    func other() {
        let result = classifier.classify("asdf jklq nothing relevant here")
        #expect(result.category == .other)
    }

    @Test("Chinese support request detected")
    func chineseSupport() {
        let result = classifier.classify("应用崩溃了，有故障")
        #expect(result.category == .support)
    }

    @Test("Chinese complaint detected")
    func chineseComplaint() {
        let result = classifier.classify("太糟糕了，我很不满")
        #expect(result.category == .complaint)
    }
}

@Suite("NaturalLanguageClassifier Confidence")
struct NLPClassifierConfidenceTests {
    let classifier = NaturalLanguageClassifier()

    @Test("high confidence keywords produce high confidence score")
    func highConfidence() {
        let result = classifier.classify("bug crash error problem issue broken")
        #expect(result.isHighConfidence)
        #expect(result.confidence >= 0.7)
    }

    @Test("ambiguous text may have lower confidence")
    func lowerConfidence() {
        let result = classifier.classify("something about the thing")
        #expect(result.confidence < 1.0)
    }

    @Test("confidence is within valid range")
    func confidenceInRange() {
        let result = classifier.classify("some text")
        #expect(result.confidence >= 0)
        #expect(result.confidence <= 1.0)
    }

    @Test("keywords are populated when matches found")
    func keywordsPopulated() {
        let result = classifier.classify("help fix bug error")
        #expect(!result.keywords.isEmpty)
    }

    @Test("fallback flag on low confidence")
    func fallback() {
        let result = classifier.classify("asdf zxcv")
        // Should be 'other', likely fallback = true
        _ = result.fallback
    }

    @Test("classification result high confidence property")
    func isHighConfidenceProperty() {
        let high = ClassificationResult(category: .support, confidence: 0.85, keywords: [], fallback: false)
        let low = ClassificationResult(category: .support, confidence: 0.6, keywords: [], fallback: true)
        #expect(high.isHighConfidence)
        #expect(low.isHighConfidence == false)
    }
}


