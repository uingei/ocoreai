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

// MARK: - LogLevel

@Suite("LogLevel")
struct LogLevelTests {

    @Test("OTel severity values are monotonically increasing")
    func severityOrdering() {
        #expect(LogLevel.trace.otelSeverity < LogLevel.debug.otelSeverity)
        #expect(LogLevel.debug.otelSeverity < LogLevel.info.otelSeverity)
        #expect(LogLevel.info.otelSeverity < LogLevel.warn.otelSeverity)
        #expect(LogLevel.warn.otelSeverity < LogLevel.error.otelSeverity)
        #expect(LogLevel.error.otelSeverity < LogLevel.fatal.otelSeverity)
    }

    @Test("rawValue matches OTel spec")
    func rawValues() {
        #expect(LogLevel.trace.rawValue == "TRACE")
        #expect(LogLevel.debug.rawValue == "DEBUG")
        #expect(LogLevel.info.rawValue == "INFO")
        #expect(LogLevel.warn.rawValue == "WARN")
        #expect(LogLevel.error.rawValue == "ERROR")
        #expect(LogLevel.fatal.rawValue == "FATAL")
    }

    @Test("severity trace is 1")
    func traceSeverity() {
        #expect(LogLevel.trace.otelSeverity == 1)
    }

    @Test("severity fatal is 21")
    func fatalSeverity() {
        #expect(LogLevel.fatal.otelSeverity == 21)
    }
}

// MARK: - LogEntry

@Suite("LogEntry")
struct LogEntryTests {

    @Test("LogEntry Codable round-trip")
    func roundTrip() throws {
        let entry = LogEntry(
            timestamp: 1_000_000_000,
            observedTimestamp: 1_000_000_001,
            traceID: "abc123",
            spanID: "def456",
            severityText: "INFO",
            severityNumber: 9,
            body: "test message",
            attributes: ["key": "value"],
            serviceName: "ocoreai"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)
        #expect(decoded.timestamp == 1_000_000_000)
        #expect(decoded.body == "test message")
        #expect(decoded.attributes["key"] == "value")
    }

    @Test("LogEntry with empty attributes decodes correctly")
    func emptyAttributesDecodes() throws {
        let entry = LogEntry(
            timestamp: 0,
            observedTimestamp: 0,
            traceID: "",
            spanID: "",
            severityText: "DEBUG",
            severityNumber: 5,
            body: "",
            attributes: [:],
            serviceName: "test"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)
        #expect(decoded.attributes.isEmpty)
        #expect(decoded.severityText == "DEBUG")
    }
}

// MARK: - StructuredLogger (init + child only — internals are private)

@Suite("StructuredLogger")
struct StructuredLoggerTests {

    @Test("StructuredLogger creates with defaults")
    func defaultInit() {
        _ = StructuredLogger()
    }

    @Test("StructuredLogger creates with custom parameters")
    func customInit() {
        _ = StructuredLogger(
            service: "my-service",
            traceID: "trace-id",
            spanID: "span-id",
            customFields: ["env": "test"]
        )
    }

    @Test("StructuredLogger sends a log entry without crashing")
    func logDoesNotCrash() {
        let logger = StructuredLogger()
        // log writes to stderr — we just verify it doesn't crash
        logger.log(level: .info, "test log message", fields: ["test": "true"])
        logger.log(level: .error, "error message", fields: ["code": "42"])
    }

    @Test("convenience log methods compile and do not crash")
    func convenienceMethods() {
        let logger = StructuredLogger()
        logger._trace("trace msg")
        logger._debug("debug msg")
        logger._info("info msg")
        logger._warning("warn msg")
        logger._error("error msg")
        logger._critical("critical msg")
    }

    @Test("child logger returns a StructuredLogger")
    func childReturnsLogger() {
        let parent = StructuredLogger(
            service: "parent",
            traceID: "t",
            spanID: "s",
            customFields: ["env": "test"]
        )
        _ = parent.child(with: ["child": "yes"])
    }

    @Test("child with empty fields still works")
    func childWithEmptyFields() {
        let parent = StructuredLogger()
        _ = parent.child(with: [:])
    }
}
