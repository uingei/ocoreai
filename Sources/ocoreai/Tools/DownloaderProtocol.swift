// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DownloaderProtocol.swift — Unified protocol for model download backends
///
/// Defines the common interface both ModelScope and HuggingFace downloaders implement.
/// Enables hot-swappable backends with consistent progress and error reporting.

import Foundation

/// Download progress event pushed to AsyncStream consumers.
struct DownloadProgress: Sendable {
    /// Unique download session identifier
    let id: String

    /// Source name (e.g. "modelscope", "huggingface")
    let source: String

    /// Model identifier being downloaded
    let modelId: String

    /// Bytes downloaded so far
    let downloadedBytes: Int64

    /// Total bytes expected (0 if unknown)
    let totalBytes: Int64

    /// Download speed in bytes per second (moving average)
    let speedBytesPerSec: Double

    /// Progress percentage (0.0 – 100.0)
    let progressPercent: Double

    /// Optional error or status message
    let message: String?

    /// Create a progress event.
    init(
        id: String,
        source: String,
        modelId: String,
        downloadedBytes: Int64,
        totalBytes: Int64,
        speedBytesPerSec: Double,
        progressPercent: Double,
        message: String? = nil
    ) {
        self.id = id
        self.source = source
        self.modelId = modelId
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.progressPercent = progressPercent
        self.message = message
    }
}

/// Supported download sources.
enum DownloadSource: String, Codable, Sendable {
    case modelscope = "modelscope"
    case huggingface = "huggingface"
}

/// Unified model downloader interface.
///
/// Implementations:
/// - ``ModelScopeDownloader`` (default, recommended)
/// - ``HuggingFaceDownloader`` (fallback)
protocol ModelDownloader: Sendable {
    /// Source identifier matching ``DownloadSource``
    var sourceName: String { get }

    /// Download a model from the source.
    /// - Parameters:
    ///   - modelId: Model identifier on the platform
    ///   - version: Optional version/tag (uses latest if nil)
    ///   - token: Authentication token (if required)
    ///   - progressStream: AsyncStream that receives ``DownloadProgress`` updates
    /// - Returns: Local filesystem URL where model files were saved
    /// - Throws: ``DownloadError`` on failure
    func download(
        modelId: String,
        version: String?,
        token: String?,
        progressStream: AsyncStream<DownloadProgress>.Continuation?
    ) async throws -> URL

    /// Check if a model is available and get metadata.
    /// - Parameters:
    ///   - modelId: Model identifier
    ///   - token: Authentication token
    /// - Returns: Model metadata dictionary or nil if unavailable
    func checkAvailability(modelId: String, token: String?) async throws -> [String: AnyHashable]?

    /// List available versions for a model.
    func listVersions(modelId: String, token: String?) async throws -> [String]
}

/// Download-specific errors.
enum DownloadError: Error, Sendable {
    case notFound(modelId: String)
    case networkFailure(detail: String)
    case authenticationRequired
    case corruptedFile(expectedHash: String, actualHash: String)
    case insufficientSpace(requiredMB: Double, availableMB: Double)
    case cancelled
    case timeout(seconds: Int)
    case unknown(detail: String)
}