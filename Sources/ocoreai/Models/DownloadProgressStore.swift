// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DownloadProgressStore — thread-safe snapshot of model download progress.
///
/// Design (root-cause fix, 2026-09-28):
///   The progress store is shared, read-mostly state that the downloader
///   writes from a non-main thread (ModelScope / HF progress callbacks) while
///   the UI reads it from the main thread. It is therefore NOT a main-actor
///   state machine. Making it `@MainActor` previously forced every writer to
///   spawn `Task { @MainActor in ... }` to hop over — and `finish()` spawned a
///   detached reaper Task to defer a 2s "completed flash". That reaper Task
///   captured the (main-actor) `self`, and the Swift concurrency runtime hit a
///   heap invariant ("freed pointer was not the last allocation") while
///   deallocating that closure on the first clean-machine first-launch: a
///   deterministic SIGABRT right after the default model prewarm finished.
///
///   The fix: drop `@MainActor` entirely, guard mutations/reads with an NSLock,
///   make every method synchronous, and remove the reaper Task. Writers now call
///   straight through (no Task spawn), readers get a consistent snapshot under
///   the same lock. No concurrency closure on the hot path → no crash surface,
///   and the state machine is now precisely value-testable.
///
/// Usage:
///   1. UI reads: `OcoreaiDownloadProgress.shared.progress(for:)`
///   2. Downloader calls: `.start(modelId:)` → `.update(_:for:)` / `.updateBytes`
///      → `.finish(modelId:success:)`
///   3. ModelManager gates progress UI on its own `downloadingModelId`, not on
///      this store's completed flag.

import Foundation

/// Human-readable download status for a single model.
struct OcoreaiDownloadProgressState: Sendable {
    /// Progress fraction 0.0–1.0
    var fraction: Double
    /// Number of completed files
    let completedFiles: Int
    /// Total number of files
    let totalFiles: Int
    /// Whether currently active (downloading)
    var active: Bool = true
    /// Whether download completed successfully.
    var completed: Bool = false
    /// Rolling throughput in bytes per second (~5s window). nil until at least
    /// two samples span a meaningful interval. Mirrors upstream MLXDownloadProgress.
    var throughputBytesPerSec: Double?
    /// Bytes downloaded so far. Mirrors upstream MLXDownloadProgress.completedBytes.
    var completedBytes: Int64 = 0
    /// Total bytes. Zero before first progress report.
    var totalBytes: Int64 = 0
    /// When the current download started. nil when inactive.
    var startedAt: Date?

    static let idle = OcoreaiDownloadProgressState(
        fraction: 0, completedFiles: 0, totalFiles: 0, active: false,
    )
}

/// Thread-safe, synchronous download-progress snapshot store.
///
/// NOT `@MainActor`: safe to call from any thread (downloader callbacks,
/// main-thread UI). All public methods are synchronous.
final class OcoreaiDownloadProgress: @unchecked Sendable {
    static let shared = OcoreaiDownloadProgress()

    /// Guards both `_progress` and `_samples`. Held for the full
    /// read-modify-write of each public call so callers observe a
    /// consistent snapshot.
    private let lock = NSLock()

    /// Per-model progress state.
    private var _progress: [String: OcoreaiDownloadProgressState] = [:]

    /// Rolling throughput samples per model (mirrors upstream MLXDownloadProgress).
    private var _samples: [String: [(time: Date, bytes: Int64)]] = [:]

    /// Throughput rolling window width. Short enough that stalls show within
    /// seconds; long enough to smooth out HF chunk arrival jitter.
    private let throughputWindow: TimeInterval = 5.0

    private init() {}

    // MARK: - Snapshot helpers (call with lock NOT held where noted)

    /// Recompute rolling throughput in place. Caller must hold `lock`.
    private func recomputeThroughput(
        modelId: String, into state: inout OcoreaiDownloadProgressState
    ) {
        let samples = _samples[modelId] ?? []
        if let oldest = samples.first, let newest = samples.last, samples.count >= 2 {
            let dt = newest.time.timeIntervalSince(oldest.time)
            if dt > 0.1 {
                let db = newest.bytes - oldest.bytes
                state.throughputBytesPerSec = Double(db) / dt
            }
        }
    }

    /// Append a throughput sample and prune the rolling window. Caller holds `lock`.
    private func appendSample(modelId: String, bytes: Int64) {
        _samples[modelId, default: []].append((time: Date(), bytes: bytes))
        let cutoff = Date().addingTimeInterval(-throughputWindow)
        _samples[modelId] = _samples[modelId]?.filter { $0.time >= cutoff }
    }

    /// Start tracking a download for the given model ID.
    /// Idempotent: if the model is already downloading, keep the current
    /// progress instead of resetting to zero.
    func start(modelId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard _progress[modelId]?.active != true else { return }
        _progress[modelId] = OcoreaiDownloadProgressState(
            fraction: 0, completedFiles: 0, totalFiles: 0, active: true,
        )
        _samples[modelId] = []
    }

    /// Update progress from a Swift `Progress` instance.
    func update(_ progress: Foundation.Progress, for modelId: String) {
        let total: Int64 = progress.totalUnitCount
        let completed: Int64 = progress.completedUnitCount
        let fraction = total > 0 ? Double(completed) / Double(total) : 0

        lock.lock()
        defer { lock.unlock() }

        var state =
            _progress[modelId]
            ?? OcoreaiDownloadProgressState(
                fraction: 0, completedFiles: 0, totalFiles: 0, active: true,
            )
        if state.startedAt == nil {
            state.startedAt = Date()
            _samples[modelId]?.removeAll()
        }

        var next = OcoreaiDownloadProgressState(
            fraction: fraction,
            completedFiles: Int(completed),
            totalFiles: Int(total),
            active: true,
            throughputBytesPerSec: nil,
            completedBytes: completed,
            totalBytes: total,
            startedAt: state.startedAt
        )
        appendSample(modelId: modelId, bytes: completed)
        recomputeThroughput(modelId: modelId, into: &next)

        _progress[modelId] = next
    }

    /// Update progress with real byte counts (used by HF directory polling).
    /// Unlike `update(_:for:)` which takes a `Progress` with abstract unit
    /// counts, this gives the real disk byte numbers so the UI can show
    /// "4.2 GB / 8.5 GB" and compute honest throughput.
    func updateBytes(completed: Int64, total: Int64, for modelId: String) {
        let fraction = total > 0 ? Double(completed) / Double(total) : 0

        lock.lock()
        defer { lock.unlock() }

        var state =
            _progress[modelId]
            ?? OcoreaiDownloadProgressState(
                fraction: 0, completedFiles: 0, totalFiles: 0, active: true,
            )
        if state.startedAt == nil {
            state.startedAt = Date()
            _samples[modelId]?.removeAll()
        }

        var next = OcoreaiDownloadProgressState(
            fraction: fraction,
            completedFiles: 0,
            totalFiles: 0,
            active: true,
            throughputBytesPerSec: nil,
            completedBytes: completed,
            totalBytes: total,
            startedAt: state.startedAt
        )
        appendSample(modelId: modelId, bytes: completed)
        recomputeThroughput(modelId: modelId, into: &next)

        _progress[modelId] = next
    }

    /// Mark a download complete (or failed) and evict the entry immediately.
    ///
    /// The previous implementation deferred a 2s "completed flash" via a
    /// detached `Task { @MainActor in ... }` reaper, which captured the
    /// main-actor `self` and was the crash source on first-launch. There is no
    /// UI reader of the `completed` flag and no reader of the deferred entry
    /// (ModelManager gates the progress UI on its own `downloadingModelId`),
    /// so immediate eviction is correct and removes the concurrency surface.
    func finish(modelId: String, success: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        _progress.removeValue(forKey: modelId)
        _samples.removeValue(forKey: modelId)
    }

    /// Clear all state (e.g. when sheet dismisses).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _progress.removeAll()
        _samples.removeAll()
    }

    /// Get current progress for a model, or nil if not tracking one.
    func progress(for modelId: String) -> OcoreaiDownloadProgressState? {
        lock.lock()
        defer { lock.unlock() }
        return _progress[modelId]
    }

    /// Is this model currently downloading?
    func isDownloading(_ modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _progress[modelId]?.active ?? false
    }
}
