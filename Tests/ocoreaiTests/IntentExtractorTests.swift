// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// IntentExtractorTests.swift — Pattern-based intent recognition
///
/// Coverage: action type detection, urgency classification,
/// confidence scoring, target extraction, and edge cases.

import Testing
import Foundation
@testable import ocoreai

@Suite("IntentExtractor Action Detection")
struct IntentActionTests {
    let extractor = IntentExtractor()

    @Test("question detected")
    func question() {
        let intent = extractor.extract(from: "What is the weather today?")
        #expect(intent.action == .askQuestion)
    }

    @Test("perform action detected")
    func performAction() {
        let intent = extractor.extract(from: "Create a new project")
        #expect(intent.action == .performAction)
    }

    @Test("search intent detected")
    func search() {
        let intent = extractor.extract(from: "Search for documentation")
        #expect(intent.action == .searchData)
    }

    @Test("modify intent detected — 'edit' maps to modifyData")
    func modify() {
        let intent = extractor.extract(from: "Edit the file now")
        #expect(intent.action == .modifyData)
    }

    @Test("analysis intent detected")
    func analysis() {
        let intent = extractor.extract(from: "Analyze the report")
        #expect(intent.action == .getAnalysis)
    }

    @Test("config intent detected — 'setting' maps to configure")
    func configure() {
        let intent = extractor.extract(from: "Change setting enable feature")
        #expect(intent.action == .configure)
    }

    @Test("status check intent detected")
    func monitor() {
        let intent = extractor.extract(from: "Check system status")
        #expect(intent.action == .monitor)
    }

    @Test("Chinese question detected")
    func chineseQuestion() {
        let intent = extractor.extract(from: "请问如何配置系统？")
        #expect(intent.action == .askQuestion)
    }

    @Test("Chinese action detected")
    func chineseAction() {
        let intent = extractor.extract(from: "创建一个新的文件")
        #expect(intent.action == .performAction)
    }

    @Test("statement with no clear action defaults to .other")
    func statementDefaultsToOther() {
        // No action verbs, no question mark
        let intent = extractor.extract(from: "Hello world foo bar")
        #expect(intent.action == .other)
    }

    @Test("statement ending with ? defaults to .askQuestion")
    func questionMarkDefaultsToAsk() {
        let intent = extractor.extract(from: "Really?")
        #expect(intent.action == .askQuestion)
    }
}

@Suite("IntentExtractor Urgency Classification")
struct IntentUrgencyTests {
    let extractor = IntentExtractor()

    @Test("urgent keywords detected")
    func urgent() {
        let intent = extractor.extract(from: "Fix this immediately ASAP")
        #expect(intent.urgency == .urgent)
    }

    @Test("high urgency detected")
    func high() {
        let intent = extractor.extract(from: "This is important and critical")
        #expect(intent.urgency == .high)
    }

    @Test("medium is default")
    func medium() {
        let intent = extractor.extract(from: "Check status")
        #expect(intent.urgency == .medium)
    }
}

@Suite("IntentExtractor Confidence and Keywords")
struct IntentConfidenceTests {
    let extractor = IntentExtractor()

    @Test("keywords populated when matches found")
    func keywordsPopulated() {
        let intent = extractor.extract(from: "Search for documentation")
        #expect(!intent.keywords.isEmpty)
    }

    @Test("confidence within valid range [0.1, 1.0]")
    func confidenceInRange() {
        let intent = extractor.extract(from: "Some random text here")
        #expect(intent.confidence >= 0.1)
        #expect(intent.confidence <= 1.0)
    }

    @Test("multiple matches increase keyword count")
    func multipleMatches() {
        let intent = extractor.extract(from: "Find and search the data quickly")
        #expect(intent.keywords.count > 1)
    }

    @Test("target entity extracted from search command")
    func targetExtracted() {
        let intent = extractor.extract(from: "Search for user documentation files")
        #expect(intent.target != nil)
    }
}
