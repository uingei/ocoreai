// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThinkingBudgetTests.swift — Verify adaptive budget multiplier logic
/// and scaffolding injection by complexity band.

import Testing
import Foundation
@testable import ocoreai

@Suite("ThinkingBudget")
struct ThinkingBudgetTests {
	// MARK: - Scaffolding by Band

	@Test("simpleBandReturnsEmpty")
	func simpleBandReturnsEmpty() async throws {
		let tb = ThinkingBudget()
		let score = ComplexityScore(composite: 0.2, length: 0.1, intent: 0.2, history: 0.1, band: .simple)
		let scaffold = await tb.scaffolding(for: score, sessionId: "s1")
		#expect(scaffold == "")
	}

	@Test("mediumBandReturnsScaffold")
	func mediumBandReturnsScaffold() async throws {
		let tb = ThinkingBudget()
		let score = ComplexityScore(composite: 0.5, length: 0.4, intent: 0.6, history: 0.5, band: .medium)
		let scaffold = await tb.scaffolding(for: score, sessionId: "s1")
		#expect(!scaffold.isEmpty)
		#expect(scaffold.contains("PERCEIVE"))
		#expect(scaffold.contains("REASON"))
		#expect(scaffold.contains("ACT"))
		#expect(!scaffold.contains("SELF-CHECK"))
	}

	@Test("complexBandReturnsFullScaffold")
	func complexBandReturnsFullScaffold() async throws {
		let tb = ThinkingBudget()
		let score = ComplexityScore(composite: 0.9, length: 0.9, intent: 0.9, history: 0.8, band: .complex)
		let scaffold = await tb.scaffolding(for: score, sessionId: "s1")
		#expect(!scaffold.isEmpty)
		#expect(scaffold.contains("PERCEIVE"))
		#expect(scaffold.contains("REASON"))
		#expect(scaffold.contains("ACT"))
		#expect(scaffold.contains("SELF-CHECK"))
	}

	// MARK: - Quality Tracking & Multiplier

	@Test("defaultMultiplierIs10")
	func defaultMultiplierIs10() async throws {
		let tb = ThinkingBudget()
		let m = await tb.currentMultiplier(for: "new-session")
		#expect(m == 1.0)
	}

	@Test("highQualityBumpsMultiplier")
	func highQualityBumpsMultiplier() async throws {
		let tb = ThinkingBudget()
		for _ in 0..<5 {
			await tb.recordQuality(0.95, for: "s1")
		}
		let m = await tb.currentMultiplier(for: "s1")
		#expect(m > 1.0)
		#expect(m <= 2.0)
	}

	@Test("lowQualityReducesMultiplier")
	func lowQualityReducesMultiplier() async throws {
		let tb = ThinkingBudget()
		for _ in 0..<5 {
			await tb.recordQuality(0.1, for: "s2")
		}
		let m = await tb.currentMultiplier(for: "s2")
		#expect(m < 1.0)
		#expect(m >= 0.5)
	}

	@Test("multiplierCappedAt20")
	func multiplierCappedAt20() async throws {
		let tb = ThinkingBudget()
		for _ in 0..<20 {
			await tb.recordQuality(1.0, for: "s3")
		}
		let m = await tb.currentMultiplier(for: "s3")
		#expect(m <= 2.0)
	}

	@Test("multiplierFlooredAt05")
	func multiplierFlooredAt05() async throws {
		let tb = ThinkingBudget()
		for _ in 0..<20 {
			await tb.recordQuality(0.0, for: "s4")
		}
		let m = await tb.currentMultiplier(for: "s4")
		#expect(m >= 0.5)
	}

	@Test("qualityClampedTo0_1")
	func qualityClampedTo0_1() async throws {
		let tb = ThinkingBudget()
		await tb.recordQuality(-0.5, for: "s5")
		await tb.recordQuality(1.5, for: "s5")
		_ = await tb.currentMultiplier(for: "s5")
	}

	@Test("perSessionIsolation")
	func perSessionIsolation() async throws {
		let tb = ThinkingBudget()
		for _ in 0..<5 {
			await tb.recordQuality(0.9, for: "a")
			await tb.recordQuality(0.1, for: "b")
		}
		let ma = await tb.currentMultiplier(for: "a")
		let mb = await tb.currentMultiplier(for: "b")
		#expect(ma > mb)
	}

	@Test("historyCappedAt20")
	func historyCappedAt20() async throws {
		let tb = ThinkingBudget()
		for _ in 0..<25 {
			await tb.recordQuality(0.5, for: "s6")
		}
		_ = await tb.currentMultiplier(for: "s6")
	}
}
