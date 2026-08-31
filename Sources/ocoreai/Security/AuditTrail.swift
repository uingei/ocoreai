// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AuditTrail.swift — Tool call audit logging — who did what and when
///
/// Records every tool execution with caller identity, arguments, result,
/// and duration for compliance and debugging.
///
/// Durability: in-memory ring buffer (fast path) + optional SQLite backing
/// (`audit_traces` table) bound via `attach(store:)`. Once bound, every
/// completed token is persisted fire-and-forget (copy-first
/// `PlanTaskStore.planUpdated` shape — `Task` async write, never blocks the
/// tool hot path) and `retentionDays` is enforced by the persist path
/// (entries older than it are purged). Unbound = pure in-memory ring
/// buffer (documented, not silent: `SystemViewModel.clearAudit` clears
/// both faces when bound, both read faces merge in the UI).

import Foundation
import Logging

/// Audit entry recording a single tool call.
struct AuditEntry: Codable, Sendable {
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

    enum AuditStatus: String, Codable, Sendable {
        case success
        case error
        case cancelled
        case timeout
    }
}

/// Persistence/serialization failures for the audit trail (copy
/// `PlanPersistenceError` shape — exact-value testable).
enum AuditPersistenceError: Error, Equatable {
    case encode
    case decode
}

extension AuditPersistenceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .encode: "audit entry JSON encode failed"
        case .decode: "audit entry JSON decode failed"
        }
    }
}

/// In-memory audit trail — actor-isolated for thread safety.
actor AuditTrail {
    private var entries: [AuditEntry] = []
    private let maxEntries: Int
    private let retentionDays: Int
    private let auditLog: StructuredLogger
    /// Optional durable backing (Verify 段 P0：审计 trace 跨重启存活).
    /// nil = 纯内存环（绑定前写入不落盘，文档明示，非静默丢失路径）。
    private var backing: SQLiteStore?

    /// Create audit trail with retention policy.
    /// - Parameters:
    ///   - maxEntries: Maximum entries to keep in memory (default 10000)
    ///   - retentionDays: Days to retain **persistent** audit entries —
    ///     consumed by the `audit_traces` persist path (entries older than
    ///     this are purged on each flush). Default 30 = `MetricsConfig`
    ///     声明面同默认值（ConfigStruct.swift L630-638）
    ///   - serviceName: Service name for structured logging
    init(
        maxEntries: Int = 10000,
        retentionDays: Int = 30,
        serviceName: String = "ocoreai",
    ) {
        self.maxEntries = maxEntries
        self.retentionDays = retentionDays
        self.auditLog = StructuredLogger(service: serviceName)
    }

    // MARK: - Persistence binding (Verify P0 — same shape as PlanTaskStore.attach)

    /// Bind the already-open SQLite connection so completed tokens persist
    /// to the `audit_traces` table (重启可恢复的合规面). Wiring:
    /// `OcoreaiEngine.start()`, right after creation (same block as
    /// `PlanTaskStore.shared.attach(store:)`).
    func attach(store s: SQLiteStore) {
        backing = s
        auditLog.log(level: .info, "audit trail persistence attached (audit_traces)", fields: [:])
    }

    /// Read the most recent `limit` entries from the durable
    /// `audit_traces` table (survives restarts). Unbound / empty /
    /// read failure → empty array (not an error). UI 合并面:
    /// `SystemViewModel.loadAudit` via `AuditTrail.merge`.
    func recentPersisted(limit: Int) async -> [AuditEntry] {
        guard let backing else { return [] }
        return await Self.readRecent(store: backing, limit: limit)
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
        arguments: [String: String],
    ) -> AuditToken {
        let traceID = UUID().uuidString
        return AuditToken(
            id: UUID().uuidString,
            traceID: traceID,
            caller: caller,
            toolName: toolName,
            toolset: toolset,
            arguments: arguments,
            startedAt: ContinuousClock.now,
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
            traceID: token.traceID,
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
            ],
        )

        // Verify P0: persist (fire-and-forget — 落盘失败不阻塞工具热路径、
        // 不抛错；copy `PlanTaskStore.planUpdated` Task 异步写形状)
        if let backing {
            let store = backing
            let days = retentionDays
            let logger = auditLog
            Task {
                await Self.persistEntry(
                    store: store,
                    entry: entry,
                    retentionDays: days,
                    log: {
                        msg in
                        logger.log(
                            level: .warn, "audit trail persist failed",
                            fields: ["component": "audit_persist", "detail": msg])
                    },
                )
            }
        }
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

    /// Clear all entries — the in-memory ring AND the durable
    /// `audit_traces` table (the latter no-ops when unbound). Single
    /// semantic: "清空审计" = 全清（UI `SystemViewModel.clearAudit` 唯一调用面）。
    func clear() {
        let store = backing
        entries.removeAll()
        if let store {
            let logger = auditLog
            Task {
                await Self.clearStore(
                    store: store,
                    log: {
                        msg in
                        logger.log(
                            level: .warn, "audit trail persist failed",
                            fields: ["component": "audit_persist", "detail": msg])
                    }
                )
            }
        }
    }

    private func enforceLimit() {
        while entries.count > maxEntries {
            entries.removeFirst()
        }
    }

    // MARK: - SQLite persistence (nonisolated static 纯函数 — 离线精确值可测)

    /// Persist one entry to `audit_traces` (INSERT OR IGNORE = 先写生效、幂等),
    /// then enforce retention: entries older than `retentionDays` are purged
    /// — `retentionDays` 由此从死参转正为真被消费。
    /// - Parameter now: injectable clock for deterministic retention tests.
    nonisolated static func persistEntry(
        store: SQLiteStore,
        entry: AuditEntry,
        retentionDays: Int,
        now: Date = Date(),
        log: @Sendable (String) -> Void = { _ in },
    ) async {
        do {
            let tsMs = Int64(entry.timestamp.timeIntervalSince1970 * 1000)
            let argsJSON = try encodeArguments(entry.arguments)
            try await store.execute(
                sql: """
                    INSERT OR IGNORE INTO audit_traces (
                        id, timestamp_ms, caller, tool_name, toolset,
                        arguments_json, status, result_summary, duration_ms, trace_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                parameters: [
                    entry.id as AnyHashable,
                    tsMs as AnyHashable,
                    entry.caller as AnyHashable,
                    entry.toolName as AnyHashable,
                    entry.toolset as AnyHashable,
                    argsJSON as AnyHashable,
                    entry.status.rawValue as AnyHashable,
                    entry.resultSummary as AnyHashable,
                    entry.durationMs as AnyHashable,
                    entry.traceID as AnyHashable,
                ],
            )
            let cutoffMs =
                Int64(
                    now.timeIntervalSince1970
                        - Double(Int64(retentionDays) * 86_400)
                ) * 1000
            try await store.execute(
                sql: "DELETE FROM audit_traces WHERE timestamp_ms < ?;",
                parameters: [cutoffMs as AnyHashable],
            )
        } catch {
            log("audit persist failed: \\(error.localizedDescription)")
        }
    }

    /// Wipe the durable `audit_traces` table (paired with `AuditTrail.clear`).
    nonisolated static func clearStore(
        store: SQLiteStore,
        log: @Sendable (String) -> Void = { _ in },
    ) async {
        do {
            try await store.execute(sql: "DELETE FROM audit_traces;")
        } catch {
            log("audit clear failed: \(error.localizedDescription)")
        }
    }

    /// Read the most recent `limit` persistent entries (timestamp DESC).
    /// Malformed rows are skipped (durable-read robustness — copy
    /// `SQLiteStore.bind` 对非 Int64 数值按文本绑定的已知行为 → LIMIT 显式 Int64).
    /// Failure → [].
    nonisolated static func readRecent(store: SQLiteStore, limit: Int) async -> [AuditEntry] {
        do {
            let rows = try await store.query(
                """
                SELECT id, timestamp_ms, caller, tool_name, toolset, arguments_json,
                       status, result_summary, duration_ms, trace_id
                FROM audit_traces ORDER BY timestamp_ms DESC LIMIT ?
                """,
                parameters: [Int64(limit) as AnyHashable],
            )
            var out: [AuditEntry] = []
            for row in rows {
                guard
                    let id = row["id"]?.asString,
                    let tsRaw = row["timestamp_ms"],
                    let caller = row["caller"]?.asString,
                    let toolName = row["tool_name"]?.asString,
                    let toolset = row["toolset"]?.asString,
                    let argsRaw = row["arguments_json"]?.asString,
                    let statusRaw = row["status"]?.asString,
                    let summary = row["result_summary"]?.asString,
                    let dur = row["duration_ms"]?.asDouble,
                    let traceID = row["trace_id"]?.asString,
                    let status = AuditEntry.AuditStatus(rawValue: statusRaw)
                else { continue }
                guard let arguments = try? decodeArguments(argsRaw) else { continue }
                let tsMs = tsRaw.asInt64 ?? Int64(tsRaw.asDouble ?? 0)
                out.append(
                    AuditEntry(
                        id: id,
                        timestamp: Date(timeIntervalSince1970: Double(tsMs) / 1000),
                        caller: caller,
                        toolName: toolName,
                        toolset: toolset,
                        arguments: arguments,
                        status: status,
                        resultSummary: summary,
                        durationMs: dur,
                        traceID: traceID,
                    )
                )
            }
            return out
        } catch {
            return []
        }
    }

    /// Merge in-memory + persistent read faces: dedupe by id (in-memory
    /// wins — it is the freshest state), sort timestamp DESC (id as
    /// deterministic tiebreaker), trim to `limit`. Pure function — 精确值
    /// 可测 (UI 读面: `SystemViewModel.loadAudit`).
    nonisolated static func merge(
        inMemory: [AuditEntry],
        persistent: [AuditEntry],
        limit: Int,
    ) -> [AuditEntry] {
        var byID: [String: AuditEntry] = [:]
        for e in persistent { byID[e.id] = e }
        for e in inMemory { byID[e.id] = e }
        let sorted = byID.values.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            return a.id > b.id
        }
        return Array(sorted.prefix(limit))
    }

    /// JSON encode tool arguments (pure — 精确值可测).
    nonisolated static func encodeArguments(_ arguments: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(arguments)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AuditPersistenceError.encode
        }
        return text
    }

    /// JSON decode tool arguments (pure — 精确值可测).
    nonisolated static func decodeArguments(_ raw: String) throws -> [String: String] {
        guard let data = raw.data(using: .utf8) else {
            throw AuditPersistenceError.decode
        }
        return try JSONDecoder().decode([String: String].self, from: data)
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
