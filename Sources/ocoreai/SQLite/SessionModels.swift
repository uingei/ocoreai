// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SessionModels.swift — ORM data models for session persistence
///
/// Maps to SQLite tables: sessions, messages, session_summaries.

import Foundation

// MARK: - Session

struct SessionModel: Codable {
    let id: Int64
    let modelId: String
    let createdAt: Date
    let updatedAt: Date
    var messageCount: Int
    var tokenCount: Int
    var summary: String?
    let ttlDays: Int
    /// Bound worktree working directory (codex new_worktree), or nil when the
    /// session uses the global configured workspace.
    var workspaceDirectory: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case tokenCount = "token_count"
        case summary
        case ttlDays = "ttl_days"
        case modelId = "model_id"
        case workspaceDirectory = "workspace_directory"
    }

    var expired: Bool {
        createdAt.addingTimeInterval(Double(ttlDays) * 86400) < Date()
    }
}

// MARK: - Message

struct MessageModel: Codable {
    let id: Int64
    let sessionId: Int64
    let role: String  // "user", "assistant", "system", "tool"
    let content: String
    let createdAt: Date
    var tokenCount: Int
    var toolCalls: [ToolCallRecord]?
    /// Reasoning trace (codex `#46711` parity) — persists the assistant's
    /// thinking so a re-opened session shows the SAME reasoning the live
    /// stream rendered. `nil` for pre-migration rows and non-reasoning turns.
    var reasoning: String?
    var embedVector: Data?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case role, content
        case createdAt = "created_at"
        case tokenCount = "token_count"
        case toolCalls = "tool_calls"
        case reasoning
        case embedVector = "embed_vector"
    }

    /// Serialize tool calls from SQLite JSON blob.
    static func deserializeToolCalls(_ json: String?) -> [ToolCallRecord]? {
        guard let json, !json.isEmpty,
            let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([ToolCallRecord].self, from: data)
    }

}

// MARK: - Tool Call Record

struct ToolCallRecord: Codable {
    let callId: String
    let toolName: String
    let arguments: [String: String]
    let resultSummary: String?
    let durationMs: Double?

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case toolName = "tool_name"
        case arguments
        case resultSummary = "result_summary"
        case durationMs = "duration_ms"
    }
}

// MARK: - FTS Search Result

struct FTSSearchResult: Codable {
    let messageIds: [Int64]
    let snippet: String
    let score: Double
    let sessionId: Int64
}

// MARK: - TTL Expiry Task

struct ExpiryTask: Codable {
    let sessionIds: [Int64]
    let totalMessages: Int
    let scheduledAt: Date
}
