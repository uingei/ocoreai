// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AppError contract tests — new ``modelLoading`` case must stay distinct
/// from ``engineUnavailable`` so clients can tell transient-retry apart from
/// permanent-fail.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

// MARK: - AppError.modelLoading

@Suite("AppError.modelLoading — new case contract")
struct ModelErrorLoadingTests {

    /// A refusal from a path that owns no clock keeps the sentence it has always had, byte for
    /// byte: appending "(0s elapsed)" to a wait that measured nothing would be the surface
    /// claiming a number the engine never delivered.
    @Test("no measurement → the sentence is unchanged, with no invented numbers")
    func sentenceWithoutMeasurement() {
        #expect(
            AppError.modelLoading("org/repo", nil).description
                == "Model org/repo is still loading — retry when state == \"ready\"",
            "the bare refusal's wording is a client-visible constant")
    }

    @Test("a measurement extends the sentence instead of replacing it")
    func sentenceWithMeasurement() {
        let e = AppError.modelLoading(
            "org/repo",
            ModelLoadProgress(
                elapsedSeconds: 41, downloading: true, bytesDownload: 1_000, bytesTotal: 4_000,
                bytesPerSecond: 100, secondsRemainingEstimate: 30))
        #expect(
            e.description.hasPrefix("Model org/repo is still loading — retry"),
            "the retry guidance must survive the disclosure: \(e.description)")
        // The numbers arrive in the measurement type's own words, so a second publisher
        // cannot word the same wait differently.
        #expect(
            e.description.contains("41s elapsed, 1000 of 4000 B, 100 B/s, ~30s remaining"),
            "the disclosure did not reach the description: \(e.description)")
    }

    @Test("status: serviceUnavailable (503 → transient, not 500)")
    func statusIsServiceUnavailable() {
        let e = AppError.modelLoading("mlx-community/gemma-4-e2b-it-4bit", nil)
        #expect(e.status == .serviceUnavailable, "modelLoading must map to 503, got \(e.status)")
    }

    @Test("description: carries the model id + retry guidance")
    func descriptionContainsRetryGuidance() {
        let e = AppError.modelLoading("mlx-community/gemma-4-e2b-it-4bit", nil)
        #expect(
            e.description.contains("gemma-4-e2b-it-4bit"),
            "description must name the model: \(e.description)")
        #expect(
            e.description.contains("still loading"),
            "description must be explicit about loading: \(e.description)")
    }

    @Test("errorDescription mirrors description (JSON body uses it)")
    func jsonBodyUsesDescription() {
        let e = AppError.modelLoading("org/repo-4bit", nil)
        #expect(e.errorDescription == e.description, "JSON error body must carry the retry wording")
        #expect(
            e.errorDescription?.contains("retry") == true
                || e.errorDescription?.contains("state") == true)
    }

    @Test("distinct from engineUnavailable (500 semantics preserved on the other case)")
    func distinctFromEngineUnavailable() {
        let a = AppError.modelLoading("org/repo", nil)
        let b = AppError.engineUnavailable
        #expect(
            a.description != b.description,
            "new case must have its own message: \(a.description) vs \(b.description)")
        #expect(a.status == b.status, "both are 503 today — clients key off message + state field")
    }
}
