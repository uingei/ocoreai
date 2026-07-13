// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SecurityModuleTests.swift — Pure logic in the Security module
///
/// Coverage:
/// - RuntimeSafetyConfig: config conversion, mode resolution
/// - SafetyConfig: defaults, validation (non-negotiable categories)
/// - LogLevel: OTel severity values
/// - LogEntry: Codable round-trip
/// - StructuredLogger: child logger field merging

import Testing
import Foundation
import ocoreaiTestUtilities
@testable import ocoreai

// MARK: - RuntimeSafetyConfig

@Suite("RuntimeSafetyConfig")
struct RuntimeSafetyConfigTests {

    @Test("enabled flag passed through")
    func enabledFlag() {
        let safety = SafetyConfig(enabled: true)
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(runtime.enabled)
    }

    @Test("minMatchesRequired passed through")
    func minMatchesRequired() {
        let safety = SafetyConfig(minMatchesRequired: 3)
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(runtime.minMatchesRequired == 3)
    }

    @Test("logRedaction passed through")
    func logRedaction() {
        let safety = SafetyConfig(logRedaction: false)
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(!runtime.logRedaction)
    }

    @Test("categoryModes converts valid raw values")
    func categoryModesConversion() {
        let safety = SafetyConfig(
            categoryModes: ["jailbreak": "disabled", "hateSpeech": "strict"]
        )
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(runtime.mode(for: .jailbreak) == .disabled)
        #expect(runtime.mode(for: .hateSpeech) == .strict)
    }

    @Test("invalid category mode falls back to default")
    func invalidModeFallsBackToDefault() {
        let safety = SafetyConfig(
            categoryModes: ["jailbreak": "nonExistentMode"]
        )
        let runtime = RuntimeSafetyConfig(from: safety)
        // "nonExistentMode" won't match any DetectionMode raw value,
        // so mode(for:) falls through to DetectionMode.defaultFor
        #expect(runtime.mode(for: .jailbreak) == .strict)
    }

    @Test("invalid category string in modes is silently skipped")
    func invalidCategorySkipped() {
        let safety = SafetyConfig(
            categoryModes: ["notARealCategory": "strict"]
        )
        let runtime = RuntimeSafetyConfig(from: safety)
        // The bad key is dropped; defaultFor kicks in
        #expect(runtime.mode(for: .jailbreak) == .strict)
    }

    @Test("additionalKeywords converts valid category strings")
    func additionalKeywordsConversion() {
        let safety = SafetyConfig(
            additionalKeywords: ["hateSpeech": ["customBad"]]
        )
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(runtime.additionalKeywords[.hateSpeech]?.contains("customBad") == true)
    }

    @Test("additionalKeywords invalid category dropped")
    func additionalKeywordsInvalidCategoryDropped() {
        let safety = SafetyConfig(
            additionalKeywords: ["notARealCategory": ["word"]]
        )
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(runtime.additionalKeywords.isEmpty)
    }

    @Test("mode(for:) returns default when no override set")
    func modeReturnsDefaultWhenNoOverride() {
        let safety = SafetyConfig()
        let runtime = RuntimeSafetyConfig(from: safety)
        #expect(runtime.mode(for: .jailbreak) == DetectionMode.defaultFor(.jailbreak))
        #expect(runtime.mode(for: .piiRequest) == DetectionMode.defaultFor(.piiRequest))
    }

    @Test("keywords preserve original case — not lowercased")
    func keywordsCasePreserved() {
        let safety = SafetyConfig(
            additionalKeywords: ["hateSpeech": ["ABC"]]
        )
        let runtime = RuntimeSafetyConfig(from: safety)
        let words = runtime.additionalKeywords[.hateSpeech]
        // RuntimeSafetyConfig passes words through without lowercasing
        #expect(words?.contains("ABC") == true)
        #expect(words?.contains("abc") == false)
    }
}

// MARK: - SafetyConfig

@Suite("SafetyConfig")
struct SafetyConfigTests {

    @Test("Default config has safety enabled")
    func defaultEnabled() {
        #expect(SafetyConfig.default.enabled)
        #expect(SafetyConfig.default.minMatchesRequired == 1)
        #expect(SafetyConfig.default.logRedaction)
    }

    @Test("minMatchesRequired clamped to [1, 5]")
    func minMatchesClamped() {
        let low = SafetyConfig(minMatchesRequired: 0)
        #expect(low.minMatchesRequired == 1)

        let high = SafetyConfig(minMatchesRequired: 100)
        #expect(high.minMatchesRequired == 5)

        let mid = SafetyConfig(minMatchesRequired: 3)
        #expect(mid.minMatchesRequired == 3)
    }

    @Test("validate() passes for valid config")
    func validatePasses() throws {
        let config = SafetyConfig(
            categoryModes: ["hateSpeech": "strict"]
        )
        try config.validate()
    }

    @Test("validate() rejects disabling underageSexual")
    func validateRejectsUnderageSexualDisabled() throws {
        let config = SafetyConfig(
            categoryModes: ["underageSexual": "disabled"]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate() rejects disabling sexualViolence")
    func validateRejectsSexualViolenceDisabled() throws {
        let config = SafetyConfig(
            categoryModes: ["sexualViolence": "disabled"]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate() rejects disabling selfHarm")
    func validateRejectsSelfHarmDisabled() throws {
        let config = SafetyConfig(
            categoryModes: ["selfHarm": "disabled"]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate() allows moderate mode on non-negotiable if set")
    func validateAllowsModerate() throws {
        // selfHarm can't be set to "disabled" but moderate is fine
        let config = SafetyConfig(
            categoryModes: ["selfHarm": "moderate"]
        )
        try config.validate()
    }
}


