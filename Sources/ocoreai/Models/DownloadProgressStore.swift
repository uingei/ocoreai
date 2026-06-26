// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DownloadProgressStore — @Observable bridge for model download progress.
///
/// Usage:
///   1. UI observes: `OcoreaiDownloadProgress.shared`
///   2. Downloader calls: `.start(modelId:)` → `.update(progress:)` → `.finish()`
///   3. UI binds to: `.progress(for:)`, `.isDownloading(:_)`

import Foundation
import Observation

/// Human-readable download status for a single model.
struct OcoreaiDownloadProgressState {
	/// Progress fraction 0.0–1.0
	var fraction: Double
	/// Number of completed files
	let completedFiles: Int
	/// Total number of files
	let totalFiles: Int
	/// Whether currently active
	var active: Bool = true

	static let idle = OcoreaiDownloadProgressState(
		fraction: 0, completedFiles: 0, totalFiles: 0, active: false,
	)
}

@Observable
@MainActor
final class OcoreaiDownloadProgress {
	static let shared = OcoreaiDownloadProgress()

	/// Per-model progress state.
	private var _progress: [String: OcoreaiDownloadProgressState] = [:]

	private init() {}

	/// Start tracking a download for the given model ID.
	func start(modelId: String) {
		_progress[modelId] = OcoreaiDownloadProgressState(
			fraction: 0, completedFiles: 0, totalFiles: 0, active: true,
		)
	}

	/// Update progress from a Swift `Progress` instance.
	func update(_ progress: Foundation.Progress, for modelId: String) {
		let total: Int64 = progress.totalUnitCount
		let completed: Int64 = progress.completedUnitCount
		let fraction = total > 0 ? Double(completed) / Double(total) : 0

		_progress[modelId] = OcoreaiDownloadProgressState(
			fraction: fraction,
			completedFiles: Int(completed),
			totalFiles: Int(total),
			active: true,
		)
	}

	/// Mark a download as complete (or failed).
	func finish(modelId: String, success: Bool = true) {
		if success {
			var state = _progress[modelId] ?? .idle
			state.fraction = 1.0
			state.active = false
			_progress[modelId] = state
		} else {
			_progress.removeValue(forKey: modelId)
		}
	}

	/// Clear all state (e.g. when sheet dismisses).
	func clear() {
		_progress.removeAll()
	}

	/// Get current progress for a model, or nil if not downloading.
	func progress(for modelId: String) -> OcoreaiDownloadProgressState? {
		_progress[modelId]
	}

	/// Is this model currently downloading?
	func isDownloading(_ modelId: String) -> Bool {
		(_progress[modelId]?.active ?? false)
	}
}
