// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SSEHelpers.swift — Shared SSE yield utilities
///
/// Eliminates the repeat pattern: JSONEncoder().encode → String → Data → ByteBuffer → yield
/// that appeared 5+ times across ChatHandler and AnthropicMessagesHandler.

import Foundation
import HTTPTypes
import Hummingbird

// MARK: - SSE Yield Helpers

/// Encode and yield an SSE chunk with an ``Encodable`` payload.
///
/// Wraps the JSON in `data: ...` prefix and double newline per SSE spec.
/// Returns `false` if encoding failed silently.
///
/// - Parameters:
///   - value: Any Encodable chat chunk DTO
///   - continuation: The async stream continuation to yield to
@Sendable
func yieldSSE(
	_ value: some Encodable,
	to continuation: AsyncStream<ByteBuffer>.Continuation,
) -> Bool {
	guard let jsonData = try? JSONEncoder().encode(value) else { return false }
	let jsonStr = String(decoding: jsonData, as: UTF8.self)
	let payload = "data: \(jsonStr)\n\n"
	guard let data = payload.data(using: .utf8) else { return false }
	continuation.yield(ByteBuffer(data: data))
	return true
}

/// Yield a raw text SSE event (for `[done]` marker, plain error strings, etc.)
///
/// - Parameters:
///   - text: Raw text to emit
///   - continuation: The async stream continuation to yield to
@Sendable
func yieldSSERaw(
	_ text: String,
	to continuation: AsyncStream<ByteBuffer>.Continuation,
) {
	if let data = "data: \(text)\n\n".data(using: .utf8) {
		continuation.yield(ByteBuffer(data: data))
	}
}

// MARK: - SSE Headers

/// Standard SSE response headers applied to streaming endpoints.
var SSEHeaders: HTTPFields {
	var h: HTTPFields = [:]
	h[.contentType] = "text/event-stream"
	h[.cacheControl] = "no-cache"
	if let connectionName = HTTPField.Name("Connection") {
		h[connectionName] = "keep-alive"
	}
	if let accelName = HTTPField.Name("X-Accel-Buffering") {
		h[accelName] = "no"
	}
	return h
}
