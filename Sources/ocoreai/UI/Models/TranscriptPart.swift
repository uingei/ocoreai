// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TranscriptPart — semantic building blocks for structured message content.
///
/// Mirrors Apple Foundation Models transcript architecture:
/// - Transcript.TextSegment → .text
/// - Transcript.Reasoning → .reasoning (collapsible thinking process)
/// - Transcript.ToolCall → .toolCall (function invocation visualization)
/// - Transcript.ImageAttachment → .image (VLM input/output)
///
/// Design principle: backward compatible — every Part can produce a plain
/// String via `displayText` for rendering in legacy contexts.

import Foundation

/// Semantic content part inside a structured ChatMessage.
///
/// A message's `.parts` array fully describes its content — replaces the
/// flat `content: String` model for new messages. Legacy messages (from
/// SQLite restore or API) still populate `content` as a convenience.
public enum TranscriptPart: Codable, Hashable, Sendable {
	
	/// Plain text content (user input, assistant response body).
	/// Equivalent to Transcript.TextSegment.
	case text(String)
	
	/// Reasoning/thinking process — displayed in a collapsible section.
	/// Equivalent to Transcript.Reasoning.
	case reasoning(String)
	
	/// Tool/function call invocation — shown as a badge/chip.
	/// Equivalent to Transcript.ToolCall.
	case toolCall(ToolCallPart)
	
	/// Image attachment (input or output).
	/// Equivalent to Transcript.ImageAttachment.
	case image(String) // base64 data URL
	
	// MARK: - Properties
	
	/// Plain-text representation for legacy/fallback rendering.
	public var displayText: String {
		switch self {
		case .text(let t): return t
		case .reasoning(let r): return "[Reasoning: \(r)]"
		case .toolCall(let tc): return "[Tool: \(tc.name) → \(tc.resultSummary ?? "…")]"
		case .image: return "[Image]"
		}
	}
	
	/// Whether this part is user-visible by default, or hidden/collapsible.
	public var visibleByDefault: Bool {
		switch self {
		case .text, .image: return true
		case .reasoning, .toolCall: return false
		}
	}
}

/// Structured data for a tool/function call part.
public struct ToolCallPart: Codable, Hashable, Sendable {
	/// Unique call identifier
	public let callId: String
	
	/// Tool/function name
	public let name: String
	
	/// Arguments passed to the tool (JSON-serializable)
	public let arguments: [String: String]
	
	/// Brief summary of the result (for inline display)
	public let resultSummary: String?
	
	/// Duration in milliseconds (if available)
	public let durationMs: Double?
	
	public init(
		callId: String,
		name: String,
		arguments: [String: String] = [:],
		resultSummary: String? = nil,
		durationMs: Double? = nil
	) {
		self.callId = callId
		self.name = name
		self.arguments = arguments
		self.resultSummary = resultSummary
		self.durationMs = durationMs
	}
}
