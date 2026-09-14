// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AppError.memoryExhausted contract tests — the new typed OOM-refusal case
/// must stay distinct from ``engineUnavailable`` and carry the actual numbers
/// (used vs budget) + a concrete next step, mirroring the wire path's
/// ``contextWindowExhausted`` precedent and the vllm-metal #756 error bar
/// ("currently 0.15 → increase the budget" instead of a bare "refused").

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

// MARK: - AppError.memoryExhausted

@Suite("AppError.memoryExhausted — OOM refusal error-face contract")
struct MemoryExhaustedErrorTests {

    @Test("status: serviceUnavailable (503 — machine condition, retry after freeing RAM)")
    func statusIsServiceUnavailable() {
        let e = AppError.memoryExhausted(usedGB: 14, budgetGB: 16)
        #expect(e.status == .serviceUnavailable, "memoryExhausted must map to 503, got \(e.status)")
    }

    @Test("description: carries 'currently X of Y' numbers + next step")
    func descriptionCarriesNumbersAndNextStep() {
        let e = AppError.memoryExhausted(usedGB: 14, budgetGB: 16)
        #expect(e.description.contains("14"), "must state the used GB: \(e.description)")
        #expect(e.description.contains("16"), "must state the budget GB: \(e.description)")
        #expect(
            e.description.contains("smaller") || e.description.contains("quantized"),
            "must give a concrete next step: \(e.description)")
    }

    @Test("errorDescription mirrors description (JSON body uses it)")
    func jsonBodyUsesDescription() {
        let e = AppError.memoryExhausted(usedGB: 12, budgetGB: 24)
        #expect(e.errorDescription == e.description, "JSON error body must carry the numbers")
    }

    @Test("distinct from engineUnavailable (out-of-RAM ≠ load failure)")
    func distinctFromEngineUnavailable() {
        let a = AppError.memoryExhausted(usedGB: 14, budgetGB: 16)
        let b = AppError.engineUnavailable
        #expect(
            a.description != b.description,
            "OOM refusal must have its own message: \(a.description) vs \(b.description)")
        #expect(a.status == b.status, "both are 503 — clients key off message + error_code")
    }
}

// MARK: - SchedulerError.oomRefused(usedGB:budgetGB:)

@Suite("SchedulerError.oomRefused — typed OOM refusal")
struct SchedulerOOMRefusedTests {

    @Test("errorDescription carries the used/budget numbers (threadable to AppError)")
    func errorDescriptionCarriesNumbers() {
        let e = SchedulerError.oomRefused(usedGB: 14, budgetGB: 16)
        #expect(e.errorDescription?.contains("14") == true, "got: \(e.errorDescription ?? "nil")")
        #expect(e.errorDescription?.contains("16") == true, "got: \(e.errorDescription ?? "nil")")
    }

    @Test("distinct values stay distinct (equality on associated values)")
    func equalityHonorsAssociatedValues() {
        #expect(
            SchedulerError.oomRefused(usedGB: 14, budgetGB: 16)
                == SchedulerError.oomRefused(usedGB: 14, budgetGB: 16))
        #expect(
            SchedulerError.oomRefused(usedGB: 14, budgetGB: 16)
                != SchedulerError.oomRefused(usedGB: 15, budgetGB: 16))
    }
}
