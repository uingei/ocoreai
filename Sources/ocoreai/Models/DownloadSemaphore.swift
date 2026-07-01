// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// DownloadSemaphore.swift — Global download concurrency limiter.
//
// Shared between UI path (ModelManager) and API path (SSE modelDownloadHandler).
// Prevents both:
//   1. Too many parallel downloads saturating disk I/O and network bandwidth
//   2. Duplicate downloads of the same model from different callers simultaneously
//
// Deliberately NOT an Actor — Swift 6 `defer` cannot `await`, so releasing in
// a `defer` block on `throw`/`return` would require fire-and-forget `Task`
// (race condition risk). Uses NSLock for synchronous, safe state mutation.

import Foundation

/// Rate-limits download operations across both UI and API paths.
///
/// `@unchecked Sendable` — all mutable state (`_inFlight`, `_activeDownloads`)
/// is protected by `_lock`. No concurrent access is possible without the lock.
final class DownloadSemaphore: @unchecked Sendable {
	static let shared = DownloadSemaphore()

	// MARK: - State (protected by _lock)

	private let _lock = NSLock()
	private var _inFlight = 0
	private var _activeDownloads: Set<String> = []
	private let maxConcurrent: Int

	private init(maxConcurrent: Int = 2) {
		self.maxConcurrent = maxConcurrent
	}

	// MARK: - Public API (synchronous, safe for use in `defer`)

	/// Result of a try-acquire attempt.
	enum Result: Sendable {
		case ok /// Slot acquired — caller must call `release(for:)` when done
		case duplicate /// Same model already downloading
		case busy /// All slots full
	}

	/// Try to acquire a download slot. Thread-safe, non-blocking, synchronous.
	/// Safe to call from any isolation context (MainActor, task, defer, etc.)
	func tryAcquire(for modelId: String) -> Result {
		_lock.lock()
		defer { _lock.unlock() }

		if _activeDownloads.contains(modelId) {
			return .duplicate
		}
		if _inFlight >= maxConcurrent {
			return .busy
		}
		_inFlight += 1
		_activeDownloads.insert(modelId)
		return .ok
	}

	/// Release a download slot after completion (success or failure).
	/// Safe to call from `defer` — synchronous, no async needed.
	func release(for modelId: String) {
		_lock.lock()
		defer { _lock.unlock() }

		_activeDownloads.remove(modelId)
		_inFlight = Swift.max(0, _inFlight - 1)
	}

	/// Convenience: acquire-or-wait. Polls `tryAcquire` with short sleeps until
	/// a slot opens or the task is cancelled.
	///
	/// Returns `true` if this caller should proceed to download (caller must
	/// call `release(for:)`). Returns `false` if the model is already being
	/// downloaded by another caller.
	func acquireOrWait(for modelId: String) async -> Bool {
		while true {
			switch tryAcquire(for: modelId) {
			case .ok:
				return true
			case .duplicate:
				return false
			case .busy:
				try? await Task.sleep(for: .milliseconds(250))
			}
		}
	}
}
