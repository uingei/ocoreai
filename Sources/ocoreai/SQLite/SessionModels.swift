// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SessionModels.swift — ORM data models for session persistence
///
/// Maps to SQLite tables: sessions, messages, session_summaries.

import Foundation

// MARK: - Session

struct SessionModel: Codable, Sendable {
    let id: Int64
    let modelId: String
    let createdAt: Date
    let updatedAt: Date
    var messageCount: Int
    var tokenCount: Int
    var summary: String?
    let ttlDays: Int

    enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", updatedAt = "updated_at"
        case messageCount = "message_count", tokenCount = "token_count"
        case summary, ttlDays = "ttl_days"
        case modelId = "model_id"
    }

    var expired: Bool {
        createdAt.addingTimeInterval(Double(ttlDays) * 86400) < Date()
    }
}

// MARK: - Message

struct MessageModel: Codable, Sendable {
    let id: Int64
    let sessionId: Int64
    let role: String  // "user", "assistant", "system", "tool"
    let content: String
    let createdAt: Date
    var tokenCount: Int
    var toolCalls: [ToolCallRecord]?
    var embedVector: Data?

    enum CodingKeys: String, CodingKey {
        case id, sessionId = "session_id", role, content
        case createdAt = "created_at", tokenCount = "token_count"
        case toolCalls = "tool_calls", embedVector = "embed_vector"
    }

    /// Serialize tool calls from SQLite JSON blob.
    static func deserializeToolCalls(_ json: String?) -> [ToolCallRecord]? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ToolCallRecord].self, from: data)
    }

    /// Serialize tool calls to JSON blob for SQLite.
    func serializeToolCalls() -> String? {
        guard let calls = toolCalls else { return nil }
        let data = try? JSONEncoder().encode(calls)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Tool Call Record

struct ToolCallRecord: Codable, Sendable {
    let callId: String
    let toolName: String
    let arguments: [String: String]
    let resultSummary: String?
    let durationMs: Double?

    enum CodingKeys: String, CodingKey {
        case callId = "call_id", toolName = "tool_name"
        case arguments, resultSummary = "result_summary", durationMs = "duration_ms"
    }
}

// MARK: - Session Summary

struct SessionSummary: Codable, Sendable {
    let sessionId: Int64
    let summary: String
    let compressedMessageCount: Int
    let compressedAt: Date
    let originalTokenEstimate: Int
    let compressedTokenEstimate: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", summary
        case compressedMessageCount = "compressed_message_count"
        case compressedAt = "compressed_at"
        case originalTokenEstimate = "original_token_estimate"
        case compressedTokenEstimate = "compressed_token_estimate"
    }
}

// MARK: - FTS Search Result

struct FTSSearchResult: Codable, Sendable {
    let messageIds: [Int64]
    let snippet: String
    let score: Double
    let sessionId: Int64
}

// MARK: - TTL Expiry Task

struct ExpiryTask: Codable, Sendable {
    let sessionIds: [Int64]
    let totalMessages: Int
    let scheduledAt: Date
}

// MARK: - Compression Trigger

struct CompressionEvent: Codable, Sendable {
    let sessionId: Int64
    let tokenCount: Int
    let threshold: Int
    let triggeredAt: Date
}