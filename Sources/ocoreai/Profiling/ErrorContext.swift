// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ErrorContext.swift — Structured error-capture extensions
///
/// ### Purpose:
/// Provide logging-backed safe-call helpers so that `try?` / empty `catch {}` can be
/// migrated to calls that automatically surface failures to ``StructuredLogger``.
///
/// ### Design:
/// - ``Result/withLog(service:context:level:body:)`` — run a throwing closure and
///   log any error before returning `nil` (same `try?` ergonomics).
/// - ``Logger`` helpers — bridge context strings into swift-log metadata.
/// - ``Optional/mapLogResult(service:context:_:)`` — map-over-optional with error logging.
/// - All closures are `@Sendable` to satisfy Swift 6 strict concurrency under
///   `-warnings-as-errors`.

import Foundation
import Logging

// MARK: - Result Extension with StructuredLogger

extension Result {
    /// Non-throwing variant that *always* returns `Success?` and logs errors.
    ///
    /// Drop-in replacement for `try? body()` that ensures no swallowed error is
    /// completely invisible.
    ///
    /// - Parameters:
    ///   - service: Service name forwarded to ``StructuredLogger/init(service:)``.
    /// Non-throwing variant that *always* returns `Success?` and logs errors.
    ///
    /// Drop-in replacement for `try? body()` that ensures no swallowed error is
    /// completely invisible.
    static func withLog(
        service: String,
        context: String,
        level: LogLevel = .warn,
        body: () throws -> Success
    ) -> Success? {
        do {
            return try body()
        } catch {
            let logger = StructuredLogger(service: service)
            logger.log(
                level: level,
                "[\(context)] \(error.localizedDescription)",
                fields: [
                    "context": context,
                    "error": error.localizedDescription,
                    "errorType": String(describing: type(of: error)),
                ]
            )
            return nil
        }
    }

    /// Async variant: drop-in replacement for `try? await body()`.
    static func withLogAsync(
        service: String,
        context: String,
        level: LogLevel = .warn,
        body: () async throws -> Success
    ) async -> Success? {
        do {
            return try await body()
        } catch {
            let logger = StructuredLogger(service: service)
            logger.log(
                level: level,
                "[\(context)] \(error.localizedDescription)",
                fields: [
                    "context": context,
                    "error": error.localizedDescription,
                    "errorType": String(describing: type(of: error)),
                ]
            )
            return nil
        }
    }
}

// MARK: - SwiftLog Logger helpers

extension Logger {
    /// Emit an ERROR-level log enriched with a context label.
    ///
    /// - Parameters:
    ///   - context: Descriptive label (e.g. "tokenization").
    ///   - failure: The captured `Error`.
    func _errorContext(_ context: String, _ failure: Error) {
        self.error(
            "[\(context)] \(failure.localizedDescription)",
            metadata: [
                "context": Logger.Metadata.Value.string(context),
                "error": Logger.Metadata.Value.string(failure.localizedDescription),
                "errorType": Logger.Metadata.Value.string(String(describing: type(of: failure))),
            ]
        )
    }

    /// Emit a WARNING-level log enriched with a context label.
    ///
    /// - Parameters:
    ///   - context: Descriptive label.
    ///   - failure: The captured `Error`.
    func _warnContext(_ context: String, _ failure: Error) {
        self.warning(
            "[\(context)] \(failure.localizedDescription)",
            metadata: [
                "context": Logger.Metadata.Value.string(context),
                "error": Logger.Metadata.Value.string(failure.localizedDescription),
                "errorType": Logger.Metadata.Value.string(String(describing: type(of: failure))),
            ]
        )
    }
}

// MARK: - Optional mapping with logging

extension Optional {
    /// Map a throwing closure over the wrapped value, logging errors if they occur.
    ///
    /// - Parameters:
    ///   - service: Service name for ``StructuredLogger``.
    ///   - context: Descriptive error context.
    ///   - transform: Throwing transform applied to the unwrapped value.
    /// - Returns: Transformed value on success, `nil` on error (logged) or when
    ///   the original optional was already `nil`.
    func mapLogResult<T>(
        service: String,
        context: String,
        _ transform: (Wrapped) throws -> T
    ) -> T? {
        guard let value = self else { return nil }
        return Result<T, Error>.withLog(service: service, context: context) {
            try transform(value)
        }
    }

    /// Flat-map variant: the transform itself returns an optional.
    func flatMapLogResult<T>(
        service: String,
        context: String,
        _ transform: (Wrapped) throws -> T?
    ) -> T? {
        guard let value = self else { return nil }
        return Result<T?, Error>.withLog(service: service, context: context) {
            try transform(value)
        }
        .flatMap { $0 }
    }
}
