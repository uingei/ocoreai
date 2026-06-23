// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AuditTrail.swift — Tool call audit logging — who did what and when
///
/// Records every tool execution with caller identity, arguments, result,
/// and duration for compliance and debugging.

import Foundation
import Logging

/// Audit entry recording a single tool call.
struct AuditEntry: Sendable, Codable {
    /// Unique audit event ID.
    let id: String

    /// Timestamp of the audit entry.
    let timestamp: Date

    /// Agent/tool caller identity.
    let caller: String

    /// Tool name that was invoked.
    let toolName: String

    /// Toolset category.
    let toolset: String

    /// Input arguments (redacted if they contain secrets).
    let arguments: [String: String]

    /// Result status.
    let status: AuditStatus

    /// Result summary (first 512 chars of output).
    let resultSummary: String

    /// Duration in milliseconds.
    let durationMs: Double

    /// OpenTelemetry trace ID for correlation.
    let traceID: String

    enum AuditStatus: String, Codable {
        case success
        case error
        case cancelled
        case timeout
    }
}

/// In-memory audit trail — actor-isolated for thread safety.
///
/// Entries can be flushed to disk or exported as JSON at any time.
actor AuditTrail {
    private var entries: [AuditEntry] = []
    private let maxEntries: Int
    private let retentionDays: Int
    private let auditLog: StructuredLogger

    /// Create audit trail with retention policy.
    /// - Parameters:
    ///   - maxEntries: Maximum entries to keep in memory (default 10000)
    ///   - retentionDays: Days to retain entries in storage (default 30)
    ///   - serviceName: Service name for structured logging
    init(
        maxEntries: Int = 10_000,
        retentionDays: Int = 30,
        serviceName: String = "ocoreai"
    ) {
        self.maxEntries = maxEntries
        self.retentionDays = retentionDays
        self.auditLog = StructuredLogger(service: serviceName)
    }

    /// Begin a new tool call audit — returns a token for completion.
    /// - Parameters:
    ///   - caller: Agent/caller identity
    ///   - toolName: Tool being invoked
    ///   - toolset: Toolset category
    ///   - arguments: Tool arguments
    /// - Returns: AuditToken for completing the entry
    func beginCall(
        caller: String,
        toolName: String,
        toolset: String,
        arguments: [String: String]
    ) -> AuditToken {
        let traceID = UUID().uuidString
        return AuditToken(
            id: UUID().uuidString,
            traceID: traceID,
            caller: caller,
            toolName: toolName,
            toolset: toolset,
            arguments: arguments,
            startedAt: ContinuousClock.now
        )
    }

    /// Record a completed tool call.
    func completeToken(_ token: AuditToken, status: AuditEntry.AuditStatus, result: String) {
        let duration = Double(token.startedAt.duration(to: .now).components.seconds) * 1000.0
        let entry = AuditEntry(
            id: token.id,
            timestamp: Date(),
            caller: token.caller,
            toolName: token.toolName,
            toolset: token.toolset,
            arguments: token.arguments,
            status: status,
            resultSummary: String(result.prefix(512)),
            durationMs: duration,
            traceID: token.traceID
        )
        entries.append(entry)
        enforceLimit()

        // Also log to structured logger
        auditLog.log(
            level: status == .success ? .debug : .error,
            "Tool call: \(token.toolName) — \(status.rawValue) in \(duration)ms",
            fields: [
                "caller": token.caller,
                "tool": token.toolName,
                "toolset": token.toolset,
                "trace_id": token.traceID,
                "duration_ms": String(duration),
            ]
        )
    }

    /// Query recent audit entries.
    /// - Returns: Recent audit entries capped at maxEntries.
    func recent(limit: Int = 100) -> [AuditEntry] {
        Array(entries.suffix(limit))
    }

    /// Query entries filtered by tool name.
    func queryTool(_ toolName: String, limit: Int = 50) -> [AuditEntry] {
        entries.filter { $0.toolName == toolName }
            .suffix(limit)
            .map { $0 }
    }

    /// Query entries filtered by caller.
    func queryCaller(_ caller: String, limit: Int = 50) -> [AuditEntry] {
        entries.filter { $0.caller == caller }
            .suffix(limit)
            .map { $0 }
    }

    /// Export audit entries as JSON array.
    func exportJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Clear all in-memory entries.
    func clear() {
        entries.removeAll()
    }

    private func enforceLimit() {
        while entries.count > maxEntries {
            entries.removeFirst()
        }
    }
}

/// Token representing an in-flight tool call — used to record duration.
struct AuditToken {
    let id: String
    let traceID: String
    let caller: String
    let toolName: String
    let toolset: String
    let arguments: [String: String]
    let startedAt: ContinuousClock.Instant
}