// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MemoryEventModel.swift — Six-element structured memory events
///
/// Each event captures: 时间(timestamp), 地点(context), 人物(entities),
/// 起因(cause), 经过(process), 结果(result) — forming a causal knowledge record.
///
/// Memory types (方案 B 单层架构):
///  - transient : session-scoped, short-lived
///  - pattern   : recurring behavior, survives session ttl
///  - fact      : verified knowledge, cross-session recall
///  - preference: user preference, long-lived

import Foundation

/// Resolution state of a memory event.
public enum MemoryEventResolution: String, Codable, Sendable {
    case resolved, workaround, unresolved
}

/// Memory type — distinguishes lifetime and recall scope.
/// Single-table design: all memory lives in one table, type drives retention.
public enum MemoryEventType: String, Codable, Sendable {
    case transient, pattern, fact, preference
}

/// Structured memory event — six-element knowledge model.
///
/// Unlike flat message storage, each event encodes the causal chain:
/// what happened (context), who/what was involved (entities),
/// why it happened (cause), how it was handled (process),
/// and the outcome (result).
public struct MemoryEvent: Codable, Sendable {
    /// Event ID
    public var id: Int64 = 0
    /// Which session this event belongs to (nullable after session delete)
    public var sessionId: Int64
    /// 时间 — Unix timestamp in milliseconds
    public var timestamp: Int64
    /// 地点 — the domain/context scope
    public var context: String
    /// 人物 — entities involved (module names, API endpoints, user roles)
    public var entities: [String]
    /// 起因 — root cause / trigger
    public var cause: String
    /// 经过 — process / how it was handled
    public var process: String
    /// 结果 — outcome / conclusion
    public var result: String
    /// Resolution state
    public var resolution: MemoryEventResolution = .unresolved
    /// Memory type — drives retention policy
    public var memoryType: MemoryEventType = .transient
    /// Dedup key — hash of (context+cause+entities) for deduplication
    public var dedupKey: String
    /// Confidence score 0.0–1.0
    public var confidence: Double = 0.8
    /// FTS5 searchable tags
    public var tags: [String]

    /// Create a new event with auto-generated dedup key and timestamp.
    public init(
        sessionId: Int64,
        context: String,
        entities: [String],
        cause: String,
        process: String,
        result: String,
        resolution: MemoryEventResolution = .unresolved,
        memoryType: MemoryEventType = .transient,
        confidence: Double = 0.8,
        tags: [String] = []
    ) {
        self.sessionId = sessionId
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
        self.context = context
        self.entities = entities
        self.cause = cause
        self.process = process
        self.result = result
        self.resolution = resolution
        self.memoryType = memoryType
        self.dedupKey = Self.computeDedupKey(context: context, cause: cause, entities: entities)
        self.confidence = confidence
        self.tags = tags
    }

    /// Create from database row.
    init?(from row: [String: SendableValue]) {
        guard let sid = row["session_id"]?.asInt64,
              let ts = row["timestamp"]?.asInt64,
              let ctx = row["context"]?.asString
        else { return nil }
        self.id = row["id"]?.asInt64 ?? 0
        self.sessionId = sid
        self.timestamp = ts
        self.context = ctx

        if let entitiesArr = row["entities"]?.asString {
            self.entities = (try? JSONDecoder().decode([String].self, from: entitiesArr.data(using: .utf8) ?? Data())) ?? []
        } else {
            self.entities = []
        }

        self.cause = row["cause"]?.asString ?? ""
        self.process = row["process"]?.asString ?? ""
        self.result = row["result"]?.asString ?? ""
        self.resolution = MemoryEventResolution(rawValue: row["resolution"]?.asString ?? "unresolved") ?? .unresolved
        self.memoryType = MemoryEventType(rawValue: row["memory_type"]?.asString ?? "transient") ?? .transient
        self.dedupKey = row["dedup_key"]?.asString ?? ""
        self.confidence = row["confidence"]?.asDouble ?? 0.8

        if let tagsStr = row["tags"]?.asString {
            self.tags = (try? JSONDecoder().decode([String].self, from: tagsStr.data(using: .utf8) ?? Data())) ?? []
        } else {
            self.tags = []
        }
    }

    /// Compute dedup key from context + cause + entities.
    private static func computeDedupKey(context: String, cause: String, entities: [String]) -> String {
        let raw = "\(context)|\(cause)|\(entities.sorted().joined(separator: ","))"
        return raw.hashValue.description
    }

    // Helpers for database encoding
    var entitiesJson: String? {
        (try? String(data: JSONEncoder().encode(entities), encoding: .utf8)).map { $0 as String }
    }

    var tagsJson: String? {
        (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)).map { $0 as String }
    }
}
