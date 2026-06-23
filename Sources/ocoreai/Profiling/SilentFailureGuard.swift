// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SilentFailureGuard.swift — Compile-time annotation for intentional silence
///
/// ### Purpose:
/// Provide a typed marker so reviewers can distinguish *intentional* silent
/// operations (e.g. best-effort metadata fetch) from *unintentional* swallowed
/// errors that should have been logged.
///
/// ### Design:
/// - Pure value type, no runtime overhead.
/// - Instances are attached to error-context calls as a "reason for silence".
/// - ``StructuredLogger`` (future) can gate on these values to decide whether
///   to emit a log line or suppress it entirely.

import Foundation

// MARK: - Silence Reason

/// A compile-time annotation marker for intentionally silent operations.
///
/// Use alongside ``Result/withLog(service:context:level:body:)`` when a
/// swallowed error is *by design* — this creates a clear audit trail.
///
/// ``StructuredLogger`` can eventually gate on these to suppress or escalate
/// specific categories of silent failure.
enum SilenceReason: Sendable, CustomStringConvertible {
    /// Transient retry — failure is expected and will be retried / logged upstream.
    case transientRetry

    /// Non-critical operation — failure is acceptable (e.g. optional metadata,
    /// best-effort enrichment).
    case nonCritical

    /// Explicit documentation with a developer-provided reason string.
    /// Use this for one-off cases that don't fit the categories above.
    case intentional(String)

    // CustomStringConvertible conformance
    var description: String {
        switch self {
        case .transientRetry:
            return "transient_retry"
        case .nonCritical:
            return "non_critical"
        case .intentional(let msg):
            return "intentional: \(msg)"
        }
    }

    /// OTel-compatible attribute key name for the reason.
    static var attributeKey: String { "silence_reason" }
}

// MARK: - Guarded Result Helpers

extension Result {
    /// Like ``withLog(service:context:level:body:)`` but accepts a
    /// ``SilenceReason`` instead of a log level.
    ///
    /// When the reason is ``SilenceReason/intentional(_:)`` the message is
    /// logged at `.info` (for auditability); all other reasons log at `.debug`
    /// so they are visible but non-alerting.
    ///
    /// - Parameters:
    ///   - service: Service name.
    ///   - context: Descriptive context label.
    ///   - reason: Why this failure is acceptable.
    ///   - body: Throwing closure.
    /// - Returns: Closure result on success, `nil` on error (logged per reason).
    static func guarded(
        service: String,
        context: String,
        reason: SilenceReason,
        body: () throws -> Success
    ) -> Success? {
        let level: LogLevel
        switch reason {
        case .intentional:
            level = .info
        default:
            level = .debug
        }

        var fields = [
            "context": context,
            "error": "",
            "errorType": "",
            SilenceReason.attributeKey: reason.description,
        ]

        do {
            return try body()
        } catch {
            fields["error"] = error.localizedDescription
            fields["errorType"] = String(describing: type(of: error))

            let logger = StructuredLogger(service: service)
            logger.log(
                level: level,
                "[\(context)] (silence_reason=\(reason.description)) \(error.localizedDescription)",
                fields: fields
            )
            return nil
        }
    }
}

// MARK: - Guarded Result Helpers

/// Typed alias for the error-capture result type used by ``SilenceReason`` guards.
typealias GuardedResult<T> = Result<T, Error>
