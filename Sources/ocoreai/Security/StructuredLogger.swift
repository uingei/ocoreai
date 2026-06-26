// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// StructuredLogger.swift — JSON structured logging with OpenTelemetry compatibility
///
/// Outputs JSON-formatted log entries compatible with OpenTelemetry collectors.
/// Integrates with swift-log but adds structured context and trace correlation.

import Foundation
import Logging

/// Log severity levels matching OpenTelemetry specification.
enum LogLevel: String, Codable {
	case trace = "TRACE"
	case debug = "DEBUG"
	case info = "INFO"
	case warn = "WARN"
	case error = "ERROR"
	case fatal = "FATAL"

	var otelSeverity: Int32 {
		switch self {
		case .trace: 1
		case .debug: 5
		case .info: 9
		case .warn: 13
		case .error: 17
		case .fatal: 21
		}
	}
}

/// Structured logger that outputs JSON log entries.
final class StructuredLogger: Sendable {
	private let service: String
	private let traceID: String
	private let spanID: String
	private let customFields: [String: String]

	/// Create a structured logger.
	/// - Parameters:
	///   - service: Service name (e.g. "ocoreai")
	///   - traceID: Optional OpenTelemetry trace ID
	///   - spanID: Optional OpenTelemetry span ID
	///   - customFields: Additional fields attached to every log entry
	init(
		service: String = "ocoreai",
		traceID: String = "",
		spanID: String = "",
		customFields: [String: String] = [:],
	) {
		self.service = service
		self.traceID = traceID
		self.spanID = spanID
		self.customFields = customFields
	}

	/// Create a child logger with additional context.
	func child(with additionalFields: [String: String] = [:]) -> StructuredLogger {
		var mergedFields = customFields
		for (key, value) in additionalFields {
			mergedFields[key] = value
		}
		return StructuredLogger(
			service: service,
			traceID: traceID,
			spanID: spanID,
			customFields: mergedFields,
		)
	}

	/// Log a structured message.
	/// - Parameters:
	///   - level: Log severity level
	///   - message: Log message
	///   - fields: Additional structured fields
	func log(level: LogLevel, _ message: String, fields: [String: String] = [:]) {
		let entry = makeEntry(level: level, message, fields: fields)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		guard let json = try? encoder.encode(entry),
		      let line = String(data: json, encoding: .utf8) else { return }
		writeLine(line)
	}

	// MARK: - Convenience

	func _trace(_ message: String, fields: [String: String] = [:]) {
		log(level: .trace, message, fields: fields)
	}

	func _debug(_ message: String, fields: [String: String] = [:]) {
		log(level: .debug, message, fields: fields)
	}

	func _info(_ message: String, fields: [String: String] = [:]) {
		log(level: .info, message, fields: fields)
	}

	func _warning(_ message: String, fields: [String: String] = [:]) {
		log(level: .warn, message, fields: fields)
	}

	func _error(_ message: String, fields: [String: String] = [:]) {
		log(level: .error, message, fields: fields)
	}

	func _critical(_ message: String, fields: [String: String] = [:]) {
		log(level: .fatal, message, fields: fields)
	}

	// MARK: - OpenTelemetry

	/// Build a log entry compatible with OpenTelemetry LogData model.
	private func makeEntry(
		level: LogLevel,
		_ message: String,
		fields: [String: String],
	) -> LogEntry {
		var mergedFields = customFields
		for (key, value) in fields {
			mergedFields[key] = value
		}

		return LogEntry(
			timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
			observedTimestamp: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
			traceID: traceID,
			spanID: spanID,
			severityText: level.rawValue,
			severityNumber: level.otelSeverity,
			body: message,
			attributes: mergedFields,
			serviceName: service,
		)
	}

	private func writeLine(_ line: String) {
		// Write to stderr for daemon compatibility; stdout goes to Hummingbird
		fputs(line, stderr)
		fputs("\n", stderr)
	}
}

/// OpenTelemetry-compatible log entry — serializable to JSON.
struct LogEntry: Codable {
	/// Unix nanoseconds since epoch.
	let timestamp: Int64
	let observedTimestamp: Int64

	/// OpenTelemetry trace/span ID (hex strings).
	let traceID: String
	let spanID: String

	/// Severity level string.
	let severityText: String

	/// Severity number per OTel spec.
	let severityNumber: Int32

	/// Log message body.
	let body: String

	/// Structured attribute key-value pairs.
	let attributes: [String: String]

	/// Service name (resource attribute).
	let serviceName: String
}

extension LogEntry {
	/// LogEntry is Codable but needs a custom decoder for the attributes dictionary.
	enum CodingKeys: String, CodingKey {
		case timestamp, observedTimestamp, traceID, spanID
		case severityText, severityNumber, body, attributes, serviceName
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		timestamp = try container.decode(Int64.self, forKey: .timestamp)
		observedTimestamp = try container.decode(Int64.self, forKey: .observedTimestamp)
		traceID = try container.decode(String.self, forKey: .traceID)
		spanID = try container.decode(String.self, forKey: .spanID)
		severityText = try container.decode(String.self, forKey: .severityText)
		severityNumber = try container.decode(Int32.self, forKey: .severityNumber)
		body = try container.decode(String.self, forKey: .body)
		attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
		serviceName = try container.decode(String.self, forKey: .serviceName)
	}
}

// MARK: - Global Logger Shortcut

extension Logger {
	/// Create a Swift-Log Logger that writes to stderr as JSON.
	static let structuredLogger: Logger = .init(label: "com.ocoreai.runtime") { _ in
		StructuredLogHandler()
	}
}

/// Structured log handler bridging swift-log to JSON output.
private final class StructuredLogHandler: LogHandler {
	nonisolated(unsafe) var logLevel: Logger.Level = .info
	nonisolated(unsafe) var metadata: Logger.Metadata = [:]

	subscript(metadataKey key: String) -> Logger.Metadata.Value? {
		get { metadata[key] }
		set { metadata[key] = newValue }
	}

	func log(event: LogEvent) {
		guard event.level.rawValue >= logLevel.rawValue else { return }
		let dict: [String: Any] = [
			"timestamp": Int64(Date().timeIntervalSince1970 * 1_000_000_000),
			"level": event.level.rawValue,
			"message": event.message.description,
			"source": "com.ocoreai.runtime",
		]
		let line: String
		do {
			let data = try JSONSerialization.data(withJSONObject: dict)
			line = String(data: data, encoding: .utf8) ?? ""
		} catch {
			line = ""
		}
		if !line.isEmpty {
			fputs(line, stderr)
			fputs("\n", stderr)
		}
	}
}
