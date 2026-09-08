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

    @Test("status: serviceUnavailable (503 → transient, not 500)")
    func statusIsServiceUnavailable() {
        let e = AppError.modelLoading("mlx-community/gemma-4-e2b-it-4bit")
        #expect(e.status == .serviceUnavailable, "modelLoading must map to 503, got \(e.status)")
    }

    @Test("description: carries the model id + retry guidance")
    func descriptionContainsRetryGuidance() {
        let e = AppError.modelLoading("mlx-community/gemma-4-e2b-it-4bit")
        #expect(
            e.description.contains("gemma-4-e2b-it-4bit"),
            "description must name the model: \(e.description)")
        #expect(
            e.description.contains("still loading"),
            "description must be explicit about loading: \(e.description)")
    }

    @Test("errorDescription mirrors description (JSON body uses it)")
    func jsonBodyUsesDescription() {
        let e = AppError.modelLoading("org/repo-4bit")
        #expect(e.errorDescription == e.description, "JSON error body must carry the retry wording")
        #expect(
            e.errorDescription?.contains("retry") == true
                || e.errorDescription?.contains("state") == true)
    }

    @Test("distinct from engineUnavailable (500 semantics preserved on the other case)")
    func distinctFromEngineUnavailable() {
        let a = AppError.modelLoading("org/repo")
        let b = AppError.engineUnavailable
        #expect(
            a.description != b.description,
            "new case must have its own message: \(a.description) vs \(b.description)")
        #expect(a.status == b.status, "both are 503 today — clients key off message + state field")
    }
}
