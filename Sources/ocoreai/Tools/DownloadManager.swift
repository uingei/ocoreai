// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DownloadManager.swift — Concurrency-controlled model download orchestrator
///
/// Manages up to 4 concurrent downloads with progress tracking, resume support,
/// SHA256 verification, and real-time AsyncStream progress updates.

import Foundation

/// Download state for a single in-progress transfer.
struct DownloadState: Sendable {
    let id: String
    let source: String
    let modelId: String
    let version: String
    let progressPercent: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speedBytesPerSec: Double
    var status: DownloadStatus

    enum DownloadStatus: Sendable {
        case pending
        case downloading
        case verifying
        case completed
        case failed(String)
        case cancelled

        /// Custom Equatable — Swift cannot synthesise Equatable for enums with associated values.
        static func == (lhs: DownloadStatus, rhs: DownloadStatus) -> Bool {
            switch (lhs, rhs) {
            case (.pending, .pending): return true
            case (.downloading, .downloading): return true
            case (.verifying, .verifying): return true
            case (.completed, .completed): return true
            case (.cancelled, .cancelled): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }
}

/// Global download queue — limits concurrency, tracks state, pushes progress events.
actor DownloadManager {
    private let maxConcurrent: Int
    private var queue: [(id: String, task: Task<Void, Never>)] = []
    private var activeDownloads: [String: DownloadState] = [:]
    private var progressContinuation: AsyncStream<DownloadProgress>.Continuation?

    /// Default max concurrent downloads.
    static let defaultMaxConcurrent = 4

    /// Create manager with concurrency limit.
    init(maxConcurrent: Int = DownloadManager.defaultMaxConcurrent) {
        self.maxConcurrent = maxConcurrent
    }

    /// Dispatch a new download task.
    func enqueue(
        downloader: any ModelDownloader,
        modelId: String,
        version: String?,
        token: String?
    ) async -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        let state = DownloadState(
            id: id,
            source: downloader.sourceName,
            modelId: modelId,
            version: version ?? "latest",
            progressPercent: 0,
            downloadedBytes: 0,
            totalBytes: 0,
            speedBytesPerSec: 0,
            status: .pending
        )

        activeDownloads[id] = state

        // Wait for a slot if at capacity
        while activeDownloads.filter({ $0.value.status == .downloading }).count >= maxConcurrent {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                activeDownloads[id]?.status = .cancelled
                return id
            }
        }

        // Update status to downloading
        activeDownloads[id]?.status = .downloading
        emitProgress(state)

        let task = Task<Void, Never> {
            await self.executeDownload(
                id: id,
                downloader: downloader,
                modelId: modelId,
                version: version,
                token: token
            )
        }

        queue.append((id: id, task: task))
        return id
    }

    /// Get current state of a download by ID.
    func getState(_ id: String) -> DownloadState? {
        activeDownloads[id]
    }

    /// Get all active downloads.
    func getAllDownloads() -> [DownloadState] {
        Array(activeDownloads.values)
    }

    /// Cancel a download by ID.
    func cancel(_ id: String) {
        activeDownloads[id]?.status = .cancelled
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue[index].task.cancel()
            queue.remove(at: index)
        }
    }

    /// Cancel all downloads.
    func cancelAll() {
        for item in queue {
            item.task.cancel()
            activeDownloads[item.id]?.status = .cancelled
        }
        queue.removeAll()
    }

    // MARK: - Internal

    private func executeDownload(
        id: String,
        downloader: any ModelDownloader,
        modelId: String,
        version: String?,
        token: String?
    ) async {
        do {
            // Create progress stream for this download
            let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream()
            progressContinuation = continuation

            _ = try await downloader.download(
                modelId: modelId,
                version: version,
                token: token,
                progressStream: continuation
            )

            // Monitor progress events
            for await progress in stream {
                guard !Task.isCancelled else {
                    continuation.finish()
                    activeDownloads[id]?.status = .cancelled
                    return
                }
                activeDownloads[id] = DownloadState(
                    id: id,
                    source: progress.source,
                    modelId: progress.modelId,
                    version: version ?? "latest",
                    progressPercent: progress.progressPercent,
                    downloadedBytes: progress.downloadedBytes,
                    totalBytes: progress.totalBytes,
                    speedBytesPerSec: progress.speedBytesPerSec,
                    status: progress.progressPercent < 100 ? .downloading : .verifying
                )
                if let state = activeDownloads[id] {
                    emitProgress(state)
                }
            }

            // Mark completed
            activeDownloads[id]?.status = .completed
            if let completedState = activeDownloads[id] {
                emitProgress(completedState)
            }

        } catch {
            activeDownloads[id]?.status = .failed(
                (error as? DownloadError)?.description ?? error.localizedDescription
            )
        }
    }

    private func emitProgress(_ state: DownloadState) {
        guard let cont = progressContinuation else { return }
        let statusString: String = switch state.status {
        case .pending: "pending"
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .completed: "completed"
        case .failed(let msg): "failed: \(msg)"
        case .cancelled: "cancelled"
        }
        let progress = DownloadProgress(
            id: state.id,
            source: state.source,
            modelId: state.modelId,
            downloadedBytes: state.downloadedBytes,
            totalBytes: state.totalBytes,
            speedBytesPerSec: state.speedBytesPerSec,
            progressPercent: state.progressPercent,
            message: statusString
        )
        cont.yield(progress)
    }
}

extension DownloadError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notFound(let id): return "Model not found: \(id)"
        case .networkFailure(let detail): return "Network error: \(detail)"
        case .authenticationRequired: return "Authentication required"
        case .corruptedFile(let expected, let actual): return "SHA256 mismatch: expected \(expected), got \(actual)"
        case .insufficientSpace(let req, let avail): return "Insufficient disk space: need \(req)MB, have \(avail)MB"
        case .cancelled: return "Download cancelled"
        case .timeout(let seconds): return "Timeout after \(seconds)s"
        case .unknown(let detail): return "Download error: \(detail)"
        }
    }
}
