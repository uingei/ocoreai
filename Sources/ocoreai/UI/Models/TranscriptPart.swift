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
///
/// Mirrors upstream MLXChatExample transcript parts: .text, .reasoning,
/// .toolCall, .image, .video — see MediaPreviewView.swift for reference.
enum TranscriptPart: Codable, Hashable, Sendable {

    /// Plain text content (user input, assistant response body).
    /// Equivalent to Transcript.TextSegment.
    case text(String)

    /// Reasoning/thinking process — displayed in a collapsible section.
    /// Equivalent to Transcript.Reasoning.
    case reasoning(String)

    /// Tool/function call invocation — shown as a badge/chip.
    /// Equivalent to Transcript.ToolCall.
    case toolCall(ToolCallPart)

    /// Context was auto-compacted (oldest turns pruned) to fit the model's
    /// window before this turn. Carries how many messages were removed so the
    /// UI can tell the user their earlier context was pruned.
    /// Codex #42319 "live compaction status" — ocoreai surfaces it as a
    /// per-turn badge instead of a TUI banner (no terminal surface here).
    case compactionNote(removedCount: Int)

    /// Image attachment (input or output).
    /// Equivalent to Transcript.ImageAttachment.
    case image(String)  // base64 data URL

    /// Video attachment (VLM input — Gemma4, Qwen2.5VL).
    /// Mirrors upstream UserInput.Video in MLXChatExample.
    case video(String)  // URL or data URL

    // MARK: - Properties

    /// Plain-text representation for legacy/fallback rendering.
    var displayText: String {
        switch self {
        case .text(let t): return t
        case .reasoning(let r): return "[Reasoning: \(r)]"
        case .toolCall(let tc): return "[Tool: \(tc.name) → \(tc.resultSummary ?? "…")]"
        case .compactionNote(let n):
            return "[\(n) earlier message(s) compacted to fit the context window]"
        case .image: return "[Image]"
        case .video: return "[Video]"
        }
    }

    /// Whether this part is user-visible by default, or hidden/collapsible.
    var visibleByDefault: Bool {
        switch self {
        case .text, .image, .video: return true
        // compactionNote is ALWAYS visible — it is the user's only signal that
        // their context was pruned; hiding it would recreate the invisibility
        // gap this part exists to close.
        case .compactionNote: return true
        case .reasoning, .toolCall: return false
        }
    }
}

/// Structured data for a tool/function call part.
struct ToolCallPart: Codable, Hashable, Sendable {
    /// Unique call identifier
    let callId: String

    /// Tool/function name
    let name: String

    /// Arguments passed to the tool (JSON-serializable)
    let arguments: [String: String]

    /// Brief summary of the result (for inline display)
    let resultSummary: String?

    /// Duration in milliseconds (if available)
    let durationMs: Double?

    init(
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
