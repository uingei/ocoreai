// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ComplexityAnalyzer tests — keyword classification, scoring, band mapping,
/// session tracking, and composite score verification.
///
/// Coverage: classifyTaskType keyword matching, scoreLength/scoreHistory
/// sigmoid curves, composite weightings, ComplexityBand thresholds,
/// session/global baseline tracking, TaskType enum round-trip.

import Testing
import Foundation
@testable import ocoreai

@Suite("ComplexityAnalyzer — Keyword Classification")
struct ComplexityAnalyzerKeywordTests {

	// MARK: Task type detection

	@Test("Code detection: function keyword → .code")
	func testCodeKeyword() async {
		let analyzer = ComplexityAnalyzer()
		_ = await analyzer.analyze(input: "def hello(): pass", messageCount: 1, sessionId: "s1")
		let type = await analyzer.getTaskType(for: "def hello(): pass")
		#expect(type == .code)
	}

	@Test("Code detection: error trace → .code")
	func testTracebackKeyword() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "Traceback (most recent call last): ...")
		#expect(type == .code)
	}

	@Test("Code detection: code fence → .code")
	func testCodeFence() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "```python\nprint(42)\n```")
		#expect(type == .code)
	}

	@Test("Code detection: refactor keyword → .code")
	func testRefactorKeyword() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "refactor this module")
		#expect(type == .code)
	}

	@Test("Math detection: calculate → .math")
	func testMathCalculate() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "calculate the probability of X")
		#expect(type == .math)
	}

	@Test("Math detection: theorem → .math")
	func testMathTheorem() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "prove this theorem by induction")
		#expect(type == .math)
	}

	@Test("JSON detection: structured output → .json")
	func testJsonStructured() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "Return as structured JSON")
		#expect(type == .json)
	}

	@Test("Comparison detection: vs → .comparison")
	func testComparisonVs() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "Swift vs Python performance comparison")
		#expect(type == .comparison)
	}

	@Test("Analysis detection: explain → .analysis")
	func testAnalysisExplain() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "explain how async works")
		#expect(type == .analysis)
	}

	@Test("Analysis detection: multi-line input (>5 lines) → .analysis")
	func testAnalysisMultiline() async {
		let analyzer = ComplexityAnalyzer()
		let multiline = (0..<10).map { "line \($0)" }.joined(separator: "\n")
		let type = await analyzer.getTaskType(for: multiline)
		#expect(type == .analysis)
	}

	@Test("Factual detection: what is → .factual")
	func testFactualWhatIs() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "what is a neural network")
		#expect(type == .factual)
	}

	@Test("Casual detection: hello → .casual")
	func testCasualHello() async {
		let analyzer = ComplexityAnalyzer()
		let type = await analyzer.getTaskType(for: "Hello there!")
		#expect(type == .casual)
	}

	@Test("Priority: code keyword wins over analysis keyword")
	func testCodeWinsOverAnalysis() async {
		let analyzer = ComplexityAnalyzer()
		// Contains both "analyze" and "function" → code should win (checked first)
		let type = await analyzer.getTaskType(for: "Analyze this function for bugs")
		#expect(type == .code)
	}

	@Test("Priority: code keyword wins over comparison keyword")
	func testCodeWinsOverComparison() async {
		let analyzer = ComplexityAnalyzer()
		// "def" detected before "compare"
		let type = await analyzer.getTaskType(for: "def compare(a, b): return a > b")
		#expect(type == .code)
	}
}

@Suite("ComplexityAnalyzer — Scoring Dimensions")
struct ComplexityAnalyzerScoringTests {

	@Test("Short input → low length score (< 0.3)")
	func testShortInputLowLength() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "hi", messageCount: 0, sessionId: "s1")
		#expect(score.length < 0.3)
	}

	@Test("Long input → higher length score (>= 0.5)")
	func testLongInputHighLength() async {
		let analyzer = ComplexityAnalyzer()
		// ~320 chars ÷ 4 = 80 tokens (sigmoid center)
		let long = String(repeating: "x ", count: 160)
		let score = await analyzer.analyze(input: long, messageCount: 0, sessionId: "s2")
		#expect(score.length >= 0.5)
	}

	@Test("Zero message count → low history score")
	func testZeroMessages() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "hello", messageCount: 0, sessionId: "s3")
		#expect(score.history < 0.5)
	}

	@Test("Many messages → higher history score")
	func testManyMessagesHighHistory() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "hello", messageCount: 50, sessionId: "s4")
		#expect(score.history >= 0.7)
	}

	@Test("Intent score: code → 0.85")
	func testIntentCode() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "def foo(): pass", messageCount: 1, sessionId: "s5")
		// code intent = 0.85
		#expect(score.intent == 0.85)
		#expect(score.taskType == .code)
	}

	@Test("Intent score: casual → 0.15")
	func testIntentCasual() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "hello", messageCount: 1, sessionId: "s6")
		#expect(score.intent == 0.15)
		#expect(score.taskType == .casual)
	}

	@Test("Very long input increases composite score via context boost")
	func testContextLengthBoost() async {
		let analyzer = ComplexityAnalyzer()
		// 3000 chars exceeds 2000 threshold → context boost applies
		// Compare short vs long input with same keyword
		let long = "calculate " + String(repeating: "word ", count: 500)
		let short = "calculate 1 + 1"
		let scoreLong = await analyzer.analyze(input: long, messageCount: 1, sessionId: "s7a")
		let scoreShort = await analyzer.analyze(input: short, messageCount: 1, sessionId: "s7b")
		// Same intent (.math=0.80), same history — long should have higher composite
		#expect(scoreLong.composite > scoreShort.composite)
	}
}

@Suite("ComplexityAnalyzer — Composite & Band Mapping")
struct ComplexityAnalyzerCompositeTests {

	@Test("Simple greeting → .simple band")
	func testSimpleBand() async {
		let analyzer = ComplexityAnalyzer()
		// "hi" = casual intent (0.15), short length, no history
		let score = await analyzer.analyze(input: "hi", messageCount: 0, sessionId: "s8")
		#expect(score.band == .simple)
		#expect(score.composite < 0.34)
	}

	@Test("Code with history → higher composite score")
	func testComplexScoreHigh() async {
		let analyzer = ComplexityAnalyzer()
		// code intent (0.85) + moderate length + history → higher composite
		let score = await analyzer.analyze(
			input: String(repeating: "def func(): ", count: 20) + "pass",
			messageCount: 30,
			sessionId: "s9"
		)
		#expect(score.composite >= 0.5)
		#expect(score.taskType == .code)
	}

	@Test("Medium band: moderate input + history → .medium band")
	func testMediumBand() async {
		let analyzer = ComplexityAnalyzer()
		// "how does X work" hits .factual (0.30), but with length + history → medium
		let score = await analyzer.analyze(
			input: "how does the compiler optimize this: " + String(repeating: "code ", count: 40),
			messageCount: 15,
			sessionId: "s10"
		)
		#expect(score.band == .medium)
		#expect(score.composite >= 0.34)
		#expect(score.composite < 0.67)
	}

	@Test("Composite score clamped to [0, 1]")
	func testCompositeClamped() async {
		let analyzer = ComplexityAnalyzer()
		// Even with max intent + max history + max context, composite <= 1.0
		let long = String(repeating: "word ", count: 500)
		let score = await analyzer.analyze(
			input: "calculate " + long,
			messageCount: 100,
			sessionId: "s11"
		)
		#expect(score.composite >= 0.0)
		#expect(score.composite <= 1.0)
	}

	@Test("Composite is rounded to 3 decimal places")
	func testCompositeRounding() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "test", messageCount: 1, sessionId: "s12")
		let multiplied = (score.composite * 1000).rounded(.towardZero)
		#expect(Double(multiplied) / 1000 == score.composite)
	}
}

@Suite("ComplexityAnalyzer — Session & Baseline Tracking")
struct ComplexityAnalyzerTrackingTests {

	@Test("Global baseline initialized at 0.5")
	func testInitialBaseline() async {
		let analyzer = ComplexityAnalyzer()
		#expect(await analyzer.globalBaseline() == 0.5)
	}

	@Test("Session baseline nil before any analysis")
	func testSessionBaselineNil() async {
		let analyzer = ComplexityAnalyzer()
		#expect(await analyzer.sessionBaseline(sessionId: "unknown") == nil)
	}

	@Test("Session baseline updated after analysis")
	func testSessionBaselineUpdated() async {
		let analyzer = ComplexityAnalyzer()
		_ = await analyzer.analyze(input: "hello", messageCount: 1, sessionId: "s1")
		let baseline = await analyzer.sessionBaseline(sessionId: "s1")
		#expect(baseline != nil)
		#expect((baseline ?? 0) >= 0.0)
		#expect((baseline ?? 1) <= 1.0)
	}

	@Test("Global baseline shifts toward recent low-complexity scores")
	func testGlobalBaselineShiftsDown() async {
		let analyzer = ComplexityAnalyzer()
		// Feed many simple inputs — global baseline should drift below 0.5
		for _ in 0..<20 {
			_ = await analyzer.analyze(input: "hi", messageCount: 0, sessionId: "ga")
		}
		let baseline = await analyzer.globalBaseline()
		#expect(baseline < 0.5)
	}

	@Test("Global baseline shifts toward recent high-complexity scores")
	func testGlobalBaselineShiftsUp() async {
		let analyzer = ComplexityAnalyzer()
		// Feed many complex inputs — global baseline should rise above 0.5
		for _ in 0..<20 {
			_ = await analyzer.analyze(input: "def foo(): calculate integral", messageCount: 50, sessionId: "ga")
		}
		let baseline = await analyzer.globalBaseline()
		#expect(baseline > 0.5)
	}

	@Test("Session baseline averaged over last 10 analyses")
	func testSessionBaselineWindow10() async {
		let analyzer = ComplexityAnalyzer()
		for _ in 0..<15 {
			_ = await analyzer.analyze(input: "hello", messageCount: 1, sessionId: "sb")
		}
		// After 15 analyses, baseline is average of last 10
		let baseline1 = await analyzer.sessionBaseline(sessionId: "sb")
		_ = await analyzer.analyze(
			input: "def complex(): calculate integral",
			messageCount: 50,
			sessionId: "sb"
		)
		let baseline2 = await analyzer.sessionBaseline(sessionId: "sb")
		// baseline2 should be higher (one complex score mixed into average)
		#expect((baseline2 ?? 0) > (baseline1 ?? 0))
	}
}

@Suite("ComplexityAnalyzer — Band Boundary Values")
struct ComplexityAnalyzerBoundaryTests {

	@Test("ComplexityBand.for: 0.33 → .simple")
	func testBandSimpleAt33() {
		#expect(ComplexityBand.for(score: 0.33) == .simple)
	}

	@Test("ComplexityBand.for: 0.34 → .medium")
	func testBandMediumAt34() {
		#expect(ComplexityBand.for(score: 0.34) == .medium)
	}

	@Test("ComplexityBand.for: 0.66 → .medium")
	func testBandMediumAt66() {
		#expect(ComplexityBand.for(score: 0.66) == .medium)
	}

	@Test("ComplexityBand.for: 0.67 → .complex")
	func testBandComplexAt67() {
		#expect(ComplexityBand.for(score: 0.67) == .complex)
	}

	@Test("ComplexityBand.for: 0.0 → .simple")
	func testBandSimpleAtZero() {
		#expect(ComplexityBand.for(score: 0.0) == .simple)
	}

	@Test("ComplexityBand.for: 1.0 → .complex")
	func testBandComplexAtOne() {
		#expect(ComplexityBand.for(score: 1.0) == .complex)
	}
}

@Suite("ComplexityAnalyzer — TaskType Enum")
struct ComplexityAnalyzerEnumTests {

	@Test("TaskType rawValue round-trip")
	func testTaskTypeRawValues() {
		#expect(TaskType.code.rawValue == "code")
		#expect(TaskType.math.rawValue == "math")
		#expect(TaskType.json.rawValue == "json")
		#expect(TaskType.comparison.rawValue == "comparison")
		#expect(TaskType.analysis.rawValue == "analysis")
		#expect(TaskType.factual.rawValue == "factual")
		#expect(TaskType.casual.rawValue == "casual")
		#expect(TaskType.general.rawValue == "general")
	}

	@Test("TaskType Codable encode/decode round-trip")
	func testTaskTypeCodable() throws {
		let encoder = JSONEncoder()
		let decoder = JSONDecoder()

		for type in [TaskType.code, TaskType.math, TaskType.json, TaskType.general] {
			let data = try encoder.encode(type)
			let decoded = try decoder.decode(TaskType.self, from: data)
			#expect(decoded.rawValue == type.rawValue)
		}
	}

	@Test("ComplexityScore Sendable struct has all fields")
	func testComplexityScoreFields() async {
		let analyzer = ComplexityAnalyzer()
		let score = await analyzer.analyze(input: "test", messageCount: 1, sessionId: "cs")
		#expect(score.composite >= 0)
		#expect(score.composite <= 1)
		#expect(score.length >= 0)
		#expect(score.length <= 1)
		#expect(score.intent >= 0)
		#expect(score.intent <= 1)
		#expect(score.history >= 0)
		#expect(score.history <= 1)
		#expect(score.band != nil)
		#expect(score.taskType != nil)
	}
}
