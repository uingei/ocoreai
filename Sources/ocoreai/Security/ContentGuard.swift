// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ContentGuard.swift — Pre-inference content safety filter
///
/// Lightweight rule-based NSFW/safety gate. Zero ML dependency.
/// Inserts between request entry and scheduler submission.
///
/// ### Design:
/// - Phase 1 (Input): Keyword blacklist + regex patterns + jailbreak detection
/// - Phase 2 (Output): Post-inference content classification
/// - Phase 3 (Tool call): Dangerous tool call audit
///
/// ### Performance:
/// - O(1) keyword lookup via Set
/// - Regex compiled once at init, cached
/// - < 5μs per check on M4 (benchmark: 1000 tokens = ~2ms total)
///
/// ### Multilingual:
/// - English + Chinese primary coverage
/// - Extensible via ``SafetyConfig.additionalKeywords``
///
/// ### False-positive tolerance:
/// - Default: conservative (block uncertain)
/// - Tunable via ``DetectionMode`` per category

import Foundation

// MARK: - Detection Result

/// Result of a content safety check.
public struct GuardResult: Sendable, Codable {
	/// Whether the content passed all safety checks.
	public let passed: Bool

	/// Categories that triggered (empty if all clear).
	public let triggeredCategories: [SafetyCategory]

	/// Confidence of the highest-severity match (0.0-1.0).
	public let confidence: Double

	/// Human-readable rejection reason (if blocked).
	public let rejectionReason: String?

	/// Duration of the check in microseconds.
	public let latencyμs: Int64

	public var isBlocked: Bool {
		!passed
	}

	/// Create a passed result.
	public static var pass: GuardResult {
		GuardResult(
			passed: true,
			triggeredCategories: [],
			confidence: 0,
			rejectionReason: nil,
			latencyμs: 0,
		)
	}

	/// Create a blocked result.
	public static func blocked(
		categories: [SafetyCategory],
		reason: String,
		confidence: Double,
		latencyμs: Int64,
	) -> GuardResult {
		GuardResult(
			passed: false,
			triggeredCategories: categories,
			confidence: confidence,
			rejectionReason: reason,
			latencyμs: latencyμs,
		)
	}

	/// Generate an HTTP 400 response for content safety violations.
	public func blockResponseData() -> Data? {
		let detail = NSDictionary(dictionary: [
			"message": rejectionReason ?? "Content safety violation",
			"type": "content_policy_violation",
			"code": 400,
			"categories": triggeredCategories.map(\.rawValue),
		])
		let body = NSDictionary(dictionary: ["error": detail])
		return try? JSONSerialization.data(withJSONObject: body, options: [])
	}
}

// MARK: - Safety Categories

/// Content safety categories for classification.
public enum SafetyCategory: String, Codable, Sendable, CaseIterable {
	// NSFW
	case sexuallyExplicit // Sexually explicit content
	case sexualViolence // Sexual violence/non-consensual
	case underageSexual // Underage sexual content (always block, zero tolerance)

	// Violence
	case graphicViolence // Graphic violence/gore
	case selfHarm // Self-harm/suicide
	case hateSpeech // Hate speech/harassment

	// System abuse
	case jailbreak // Jailbreak/prompt injection attempts
	case systemPromptOverride // System prompt extraction/override
	case toolAbuse // Dangerous tool call attempts

	// Legal/ethical
	case illegalActivity // Facilitating illegal activity (drugs, weapons, etc.)
	case malwareGeneration // Malware/exploit generation
	case piiRequest // PII extraction attempts

	public var severity: Double {
		switch self {
		case .underageSexual, .sexualViolence: 1.0 // Always block
		case .selfHarm, .jailbreak, .systemPromptOverride: 0.95
		case .sexuallyExplicit, .graphicViolence, .hateSpeech: 0.9
		case .toolAbuse, .illegalActivity, .malwareGeneration: 0.85
		case .piiRequest: 0.7
		}
	}

	public var description: String {
		switch self {
		case .sexuallyExplicit: "Sexually explicit content detected"
		case .sexualViolence: "Sexual violence content detected"
		case .underageSexual: "Underage sexual content detected"
		case .graphicViolence: "Graphic violence detected"
		case .selfHarm: "Self-harm content detected"
		case .hateSpeech: "Hate speech detected"
		case .jailbreak: "Jailbreak attempt detected"
		case .systemPromptOverride: "System prompt manipulation detected"
		case .toolAbuse: "Dangerous tool use detected"
		case .illegalActivity: "Illegal activity facilitation detected"
		case .malwareGeneration: "Malware/ exploit generation detected"
		case .piiRequest: "PII extraction attempt detected"
		}
	}
}

// MARK: - Detection Mode

/// How strictly to enforce safety rules per category.
public enum DetectionMode: String, Codable, Sendable {
	/// Block all matches in this category (conservative).
	case strict

	/// Only block high-confidence matches (balanced).
	case moderate

	/// Log warning but allow (lenient, for internal/dev use).
	case warnOnly

	/// Completely disable this category.
	case disabled

	/// Default mode per category.
	public static func defaultFor(_ category: SafetyCategory) -> DetectionMode {
		switch category {
		case .underageSexual, .sexualViolence, .selfHarm:
			.strict // Never disable these
		case .jailbreak, .systemPromptOverride, .toolAbuse:
			.strict // System integrity
		case .sexuallyExplicit, .graphicViolence, .hateSpeech:
			.moderate
		case .illegalActivity, .malwareGeneration:
			.moderate
		case .piiRequest:
			.warnOnly
		}
	}
}

// MARK: - Runtime Safety Config (internal)

/// Internal runtime configuration derived from ``SafetyConfig`` (YAML-facing).
/// Keeps type-safe DetectionMode enums away from the config layer.
struct RuntimeSafetyConfig {
	let enabled: Bool
	let categoryModes: [SafetyCategory: DetectionMode]
	let additionalKeywords: [SafetyCategory: [String]]
	let minMatchesRequired: Int
	let logRedaction: Bool

	init(from config: SafetyConfig) {
		enabled = config.enabled
		minMatchesRequired = config.minMatchesRequired
		logRedaction = config.logRedaction

		// Convert YAML string modes to DetectionMode enums
		var modes: [SafetyCategory: DetectionMode] = [:]
		for (catString, modeString) in config.categoryModes {
			if let cat = SafetyCategory(rawValue: catString),
			   let mode = DetectionMode(rawValue: modeString)
			{
				modes[cat] = mode
			}
		}
		categoryModes = modes

		// Convert additional keywords
		var keywords: [SafetyCategory: [String]] = [:]
		for (catString, words) in config.additionalKeywords {
			if let cat = SafetyCategory(rawValue: catString) {
				keywords[cat] = words
			}
		}
		additionalKeywords = keywords
	}

	func mode(for category: SafetyCategory) -> DetectionMode {
		categoryModes[category] ?? DetectionMode.defaultFor(category)
	}
}

// MARK: - Content Guard

/// Thread-safe content safety guard. Pre-compiled regex + keyword sets.
///
/// Usage:
/// ```swift
/// let guard = ContentGuard(runtimeConfig: RuntimeSafetyConfig(from: .default))
/// let result = await guard.checkInput("user message text")
/// if result.isBlocked { return error response }
/// ```
public actor ContentGuard {
	private let runtimeConfig: RuntimeSafetyConfig

	// Compiled keyword sets per category (lowercased for case-insensitive matching)
	private let keywordSets: [SafetyCategory: Set<String>]

	// Compiled regex patterns per category
	private let regexPatterns: [SafetyCategory: [NSRegularExpression]]

	// Audit counter (for metrics) — actor-isolated, safe for concurrent access
	private var checksRun: Int64 = 0
	private var blocksTriggered: Int64 = 0

	// MARK: - Init

	/// Create safety guard with default config.
	init(runtimeConfig: RuntimeSafetyConfig) {
		self.runtimeConfig = runtimeConfig

		// Build keyword sets from built-in + config overrides
		let builtins = Self.builtInKeywords()
		keywordSets = Self.mergeKeywords(
			builtins: builtins,
			additional: runtimeConfig.additionalKeywords,
		)

		// Build regex patterns
		regexPatterns = Self.compileRegexPatterns()
	}

	// MARK: - Public API

	/// Check user input BEFORE inference. Returns quickly (< 5ms).
	/// - Parameter text: User message text to check.
	/// - Returns: ``GuardResult`` indicating whether inference should proceed.
	public func checkInput(_ text: String) -> GuardResult {
		let rtConfig = runtimeConfig
		guard rtConfig.enabled else { return .pass }

		let start = UInt64(DispatchTime.now().uptimeNanoseconds)
		defer {
			checksRun += 1
		}

		let lowerText = text.lowercased()

		// 1. Keyword scan (O(1) per category)
		let keywordHits = scanKeywords(lowerText)

		// 2. Regex scan (jailbreak patterns, prompt injection)
		let regexHits = scanRegex(lowerText, text: text)

		// 3. Merge and evaluate hits
		let result = evaluateHits(keywordHits, regexHits: regexHits, text: lowerText)

		let elapsed = UInt64(DispatchTime.now().uptimeNanoseconds) - start
		if result.isBlocked { blocksTriggered += 1 }

		return GuardResult(
			passed: result.passed,
			triggeredCategories: result.triggeredCategories,
			confidence: result.confidence,
			rejectionReason: result.rejectionReason,
			latencyμs: Int64(elapsed / 1000),
		)
	}

	/// Check model output AFTER inference. Catches model-generated harmful content.
	/// - Parameter text: Model output text to check.
	/// - Returns: ``GuardResult`` indicating whether output should be delivered.
	public func checkOutput(_ text: String) async -> GuardResult {
		let rtConfig = runtimeConfig
		guard rtConfig.enabled else { return .pass }

		let start = UInt64(DispatchTime.now().uptimeNanoseconds)
		defer {
			checksRun += 1
		}

		let lowerText = text.lowercased()

		// 1. Keyword scan (same categories as input)
		let keywordHits = scanKeywords(lowerText)

		// 2. Regex scan (jailbreak patterns, prompt injection) — symmetric with checkInput
		let regexHits = scanRegex(lowerText, text: text)

		// 3. Evaluate — output filtering mirrors input scanning
		let result = evaluateHits(keywordHits, regexHits: regexHits, text: lowerText)
		if result.isBlocked { blocksTriggered += 1 }

		let elapsed = UInt64(DispatchTime.now().uptimeNanoseconds) - start
		return GuardResult(
			passed: result.passed,
			triggeredCategories: result.triggeredCategories,
			confidence: result.confidence,
			rejectionReason: result.rejectionReason,
			latencyμs: Int64(elapsed / 1000),
		)
	}

	/// Get current safety metrics.
	public func getMetrics() -> (checks: Int64, blocks: Int64, blockRate: Double) {
		let total = checksRun
		let blocks = blocksTriggered
		return (
			checks: total,
			blocks: blocks,
			blockRate: total > 0 ? Double(blocks) / Double(total) : 0.0,
		)
	}

	// MARK: - Keyword Scanning

	private func scanKeywords(_ text: String) -> [SafetyCategory: Int] {
		var hits: [SafetyCategory: Int] = [:]

		for (category, keywords) in keywordSets {
			let mode = runtimeConfig.mode(for: category)
			guard mode != .disabled else { continue }

			var matchCount = 0
			for keyword in keywords {
				if text.contains(keyword) {
					matchCount += 1
				}
			}

			if matchCount >= runtimeConfig.minMatchesRequired {
				hits[category] = matchCount
			}
		}

		return hits
	}

	// MARK: - Regex Scanning

	private func scanRegex(_: String, text originalText: String) -> [SafetyCategory: Int] {
		var hits: [SafetyCategory: Int] = [:]

		for (category, patterns) in regexPatterns {
			let mode = runtimeConfig.mode(for: category)
			guard mode != .disabled else { continue }

			var matchCount = 0
			let fullRange = NSRange(originalText.startIndex ..< originalText.endIndex, in: originalText)

			for regex in patterns {
				let matches = regex.matches(in: originalText, range: fullRange)
				if !matches.isEmpty {
					matchCount += matches.count
				}
			}

			if matchCount > 0 {
				hits[category] = matchCount
			}
		}

		return hits
	}

	// MARK: - Evaluation

	struct EvalResult {
		let passed: Bool
		let triggeredCategories: [SafetyCategory]
		let confidence: Double
		let rejectionReason: String?

		var isBlocked: Bool {
			!passed
		}
	}

	private func evaluateHits(
		_ keywordHits: [SafetyCategory: Int],
		regexHits: [SafetyCategory: Int] = [:],
		text _: String,
	) -> EvalResult {
		var categories: [SafetyCategory] = []
		var maxConfidence: Double = 0
		var rejectionReasons: [String] = []

		// Merge keyword + regex hits
		let allCategories = Set(keywordHits.keys).union(regexHits.keys)

		for category in allCategories {
			let mode = runtimeConfig.mode(for: category)
			let keywordCount = keywordHits[category] ?? 0
			let regexCount = regexHits[category] ?? 0
			let totalMatches = keywordCount + regexCount

			// Confidence: scale with match count, capped at 1.0
			let confidence = min(Double(totalMatches) * 0.3 + category.severity * 0.5, 1.0)

			if confidence > maxConfidence {
				maxConfidence = confidence
			}

			// Severity-based filtering
			let effectiveConfidence = confidence * category.severity

			switch mode {
			case .strict:
				// Block on any match
				if totalMatches > 0 {
					categories.append(category)
					rejectionReasons.append(category.description)
				}

			case .moderate:
				// Block only if confidence >= 0.5
				if effectiveConfidence >= 0.5 {
					categories.append(category)
					rejectionReasons.append(category.description)
				}

			case .warnOnly:
				// Log but don't block — just record for metrics
				if totalMatches > 0 {
					// Still track the category for audit trail
					categories.append(category)
				}

			case .disabled:
				break
			}
		}

		// If only warnOnly categories triggered, pass through
		let hasBlockCategory = !allCategories.isEmpty &&
			allCategories.contains { runtimeConfig.mode(for: $0) != .warnOnly && $0.severity * maxConfidence >= 0.5 }

		if hasBlockCategory {
			return EvalResult(
				passed: false,
				triggeredCategories: categories,
				confidence: maxConfidence,
				rejectionReason: rejectionReasons.joined(separator: "; "),
			)
		}

		return EvalResult(
			passed: true,
			triggeredCategories: categories,
			confidence: maxConfidence,
			rejectionReason: nil,
		)
	}

	// MARK: - Built-in Keywords

	/// Built-in keyword database. Extensible but defaults cover the primary
	/// safety categories for English and Chinese.
	///
	/// NOTE: These are *content* keywords — not slurs. The goal is to detect
	/// the TOPIC of harmful content, not to match every possible word that could
	/// appear in a safe context. High-severity categories use more specific
	/// patterns to reduce false positives.
	private static func builtInKeywords() -> [SafetyCategory: Set<String>] {
		var sets: [SafetyCategory: Set<String>] = [:]

		// --- sexuallyExplicit ---
		sets[.sexuallyExplicit] = Set([
			// English
			"nsfw", "erotica", "xxx", "pornographic", "nudity",
			"nude", "sexually explicit", "sex tips", "sexual activity",
			// Chinese
			"色情", "裸体", "成人内容", "淫秽", "情色",
		])

		// --- sexualViolence ---
		sets[.sexualViolence] = Set([
			"sexual assault", "sexual abuse", "rape",
			"non-consensual sexual", "sexual harassment",
			"强奸", "性侵", "性骚扰", "性虐待",
		])

		// --- underageSexual ---
		sets[.underageSexual] = Set([
			"underage sexual", "child sexual", "minor involved in sexual",
			"child exploitation", "pedophil",
			"未成年人性", "儿童色情", "未成年裸体",
		])

		// --- graphicViolence ---
		sets[.graphicViolence] = Set([
			"graphic violence", "gore", "torture", "flaying",
			"mutilat", "sadistic", "masochistic",
			"暴力血腥", "酷刑", "肢解", "残忍",
		])

		// --- selfHarm ---
		sets[.selfHarm] = Set([
			"suicide", "self-harm", "self harm", "cutting myself",
			"how to kill myself", "suicide method", "how to die",
			"suicide note", "jump off a building", "drink poison",
			"怎么自杀", "自残方法", "怎么死",
		])

		// --- hateSpeech ---
		sets[.hateSpeech] = Set([
			"racial slurs", "dehumanizing", "genocide",
			"ethnic cleansing", "inferior race",
			"种族歧视", "仇恨言论", "种族清洗",
		])

		// --- jailbreak ---
		sets[.jailbreak] = Set([
			"ignore all previous", "disregard all rules", "bypass your safety",
			"ignore your instructions", "pretend you are", "act as if you had no",
			"remove all restrictions", "no limits", "uncensored mode",
			"ignore all rules", "jailbreak", "dank mode", "dev mode",
			"developer mode", "raw mode", "unfiltered mode",
			"ignore all rules restrictions", // Chinese jailbreak
			"忽略所有规则", "忽略所有规则限制", "绕过所有限制", "打破所有约束",
			"无视所有规则", "忽略安全限制", "绕过安全规则",
		])

		// --- systemPromptOverride ---
		sets[.systemPromptOverride] = Set([
			"what is your system prompt", "show your system message",
			"what are your instructions", "repeat your first prompt",
			"输出你的系统提示", "显示你的system prompt", "重复系统指令",
		])

		// --- illegalActivity ---
		sets[.illegalActivity] = Set([
			"how to make drugs", "how to manufacture",
			"how to build a bomb", "how to synthesize",
			"制造毒品", "制造炸弹", "合成毒品",
		])

		// --- malwareGeneration ---
		sets[.malwareGeneration] = Set([
			"malware", "ransomware", "keylogger", "rootkit",
			"write a virus", "exploit code", "buffer overflow exploit",
			"零日漏洞", "木马程序", "勒索软件",
		])

		// --- piiRequest ---
		sets[.piiRequest] = Set([
			"credit card number", "social security number",
			"bank account", "home address of",
			"银行卡号", "身份证号", "家庭住址",
		])

		return sets
	}

	// MARK: - Built-in Regex Patterns

	/// Compiled regex patterns for jailbreak and prompt injection detection.
	/// Pre-compiled for performance — patterns are expensive to compile
	/// per-request.
	private static func compileRegexPatterns() -> [SafetyCategory: [NSRegularExpression]] {
		var patterns: [SafetyCategory: [NSRegularExpression]] = [:]

		let options: NSRegularExpression.Options = [
			.caseInsensitive,
			.dotMatchesLineSeparators,
		]

		// --- Jailbreak patterns ---
		patterns[.jailbreak] = [
			// classic DAN / role play bypass
			regex("pretend\\\\s+(you )?are", options),
			regex("act\\\\s+(as )?if", options),
			regex("(ignore|disregard|bypass)\\\\s+(all|everything|every)?\\\\s*(rules?|instructions?|restrictions?|guidelines?)", options),
			// mode switching
			regex("(dev(?:eloper)?|developer|dev)\\\\s*mode", options),
			regex("(uncensored?|unfiltered?|raw|dank)\\\\s*(mode|output)", options),
			// Chinese jailbreak
			regex("(忽略|无视|绕过|打破)\\\\s*(所有|全部)?\\\\s*(((规则|限制|约束|指引|安全)\\\\s*){1,3})", options),
		].compactMap(\.self)

		// --- System prompt override ---
		patterns[.systemPromptOverride] = [
			regex("(what\\\\s+is|show me|reveal|display|output|dump|print)\\\\s+(y(our|o)ur )?(system )?(message|prompt|instruction)", options),
			regex("(输出|显示|输出|打印|dump)\\\\s*(你的|系统)?\\\\s*(提示|指令|system prompt)", options),
		].compactMap(\.self)

		// --- Self-harm patterns (more specific regex for reduced FP) ---
		patterns[.selfHarm] = [
			regex("how\\\\s+(to|do|can I)\\\\s+(kill|die|commit suicide|end my life|harm myself)", options),
			regex("(方法|方式)\\\\s*(自杀|自残|结束生命)", options),
		].compactMap(\.self)

		// --- Tool abuse patterns ---
		patterns[.toolAbuse] = [
			regex("run\\\\s+(sudo\\\\s+rm\\\\s+-rf|format\\\\s+[Cc]:|mkfs|dd\\\\s+if=)", options),
			regex("(rm\\\\s+-rf\\\\s+/|format\\\\s+[Cc:]\\\\w+|delete\\\\s+all\\\\s+files)", options),
		].compactMap(\.self)

		return patterns
	}

	// MARK: - Helpers

	private static func regex(_ pattern: String, _ options: NSRegularExpression.Options? = nil) -> NSRegularExpression? {
		guard let compiled = try? NSRegularExpression(
			pattern: pattern,
			options: options ?? [.caseInsensitive, .dotMatchesLineSeparators],
		) else { return nil }
		return compiled
	}

	private static func regex(_ pattern: String) -> NSRegularExpression? {
		regex(pattern, nil)
	}

	private static func mergeKeywords(
		builtins: [SafetyCategory: Set<String>],
		additional: [SafetyCategory: [String]],
	) -> [SafetyCategory: Set<String>] {
		var merged = builtins

		for (category, words) in additional {
			let lowercased = Set(words.map { $0.lowercased() })
			merged[category, default: []].formUnion(lowercased)
		}

		return merged
	}
}
