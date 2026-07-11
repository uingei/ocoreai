// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TTSFilterConfig.swift — TTS output content filtering and rate control

import Foundation

/// Configuration for TTS output filtering.
/// Controls which content gets read aloud vs suppressed.
struct TTSFilterConfig: Sendable {
	/// Enable TTS filtering
	var enabled: Bool = true
	
	/// Skip TTS for messages shorter than this character count
	/// (likely system messages, tool outputs)
	var minContentLength: Int = 10
	
	/// Patterns that should never be spoken (regex)
	/// Default: tool call JSON, thinking tags, code blocks
	var blockPatterns: [String] = [
		"^```",                   // code blocks
		"\\[thinking\\]",        // thinking tags
		"tool_call",             // tool call markers
		"^\\{.*\\}$",           // pure JSON
	]
	
	/// Maximum TTS duration per utterance (seconds)
	var maxUtteranceDuration: TimeInterval = 30
	
	/// TTS speech rate (0.5..2.0, default 1.0)
	var speechRate: Float = 1.0
	
	/// Whether to speak streaming tokens progressively
	var progressiveMode: Bool = false
	
	/// Debounce interval for streaming TTS (ms)
	var progressiveDebounceMs: Int = 200
	
	/// Validate and sanitize config
	mutating func validate() {
		speechRate = max(0.5, min(2.0, speechRate))
		minContentLength = max(0, min(1000, minContentLength))
		maxUtteranceDuration = max(1, min(120, maxUtteranceDuration))
	}
	
	static let `default` = TTSFilterConfig()
}
