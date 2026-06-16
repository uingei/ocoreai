// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelDownloadHandler.swift â€” SSE handler for ``POST /v1/models/download``
///
/// Streams download progress as SSE events:
/// - "progress" with percentage, bytes, eta
/// - "completed" with cache path
/// - "error" with error message

#if mlx

import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// Handle POST /v1/models/download
func modelDownloadHandler(
    request: DownloadModelRequest,
    hfToken: String?,
    msToken: String?,
    logger: Logger
) async throws -> Response {
    try request.validate()

    let provider = request.effectiveProvider
    let downloadId = "\(provider):\(request.model)"

    // SSE headers
    var responseHeaders: HTTPFields = [:]
    responseHeaders[.contentType] = "text/event-stream"
    responseHeaders[.cacheControl] = "no-cache"
    responseHeaders[.connection] = "keep-alive"
    responseHeaders[HTTPField.Name("X-Accel-Buffering")!] = "no"

    return Response(
        status: .ok,
        headers: responseHeaders,
        body: .init { writer in
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.sortedKeys]

            func emit(_ event: DownloadSSEEvent) async throws {
                let data = try jsonEncoder.encode(event)
                guard let json = String(data: data, encoding: .utf8) else { return }
                let line = "data: \(json)\n\n"
                guard let lineData = line.data(using: .utf8) else { return }
                try await writer.write(.init(data: lineData))
            }

            let start = ContinuousClock.now
            do {
                do {
                    let cacheDir = try await doDownload(
                        downloadId: downloadId,
                        modelId: request.model,
                        provider: provider,
                        revision: request.revision,
                        useLatest: request.useLatest,
                        hfToken: hfToken,
                        msToken: msToken,
                        logger: logger,
                        emit: emit
                    )
                    try await emit(.completed(downloadId, cacheDir: cacheDir))
                } catch {
                    try await emit(.error(downloadId, message: error.localizedDescription))
                    throw error
                }
            } catch {
                // Client disconnected early
                logger.warning(
                    "Download SSE stream closed early",
                    metadata: [
                        "model": .string(request.model),
                        "downloadId": .string(downloadId),
                    ])
            }
        }
    )
}

/// Actually run the download, emitting SSE progress events.
private func doDownload(
    downloadId: String,
    modelId: String,
    provider: String,
    revision: String?,
    useLatest: Bool,
    hfToken: String?,
    msToken: String?,
    logger: Logger,
    emit: @escaping (DownloadSSEEvent) async throws -> Void
) async throws -> String {
    switch provider {
    case "hf": return try await downloadFromHF(
        downloadId: downloadId, modelId: modelId, revision: revision,
        useLatest: useLatest, hfToken: hfToken, logger: logger, emit: emit)
    case "mscope": return try await downloadFromMscope(
        downloadId: downloadId, modelId: modelId, revision: revision,
        useLatest: useLatest, msToken: msToken, logger: logger, emit: emit)
    default: throw AppError.invalidRequest("Unknown provider: \(provider)")
    }
}

// MARK: - HF Download

private func downloadFromHF(
    downloadId: String,
    modelId: String,
    revision: String?,
    useLatest: Bool,
    hfToken: String?,
    logger: Logger,
    emit: @escaping (DownloadSSEEvent) async throws -> Void
) async throws -> String {
    let downloader = HuggingFaceDownloader(token: hfToken)
    logger.info("Downloading from HuggingFace", metadata: ["model": .string(modelId)])

    let result: URL
    result = try await downloader.download(
        id: modelId,
        revision: revision,
        useLatest: useLatest,
        progressHandler: { progress in
            Task {
                let pct = Int(progress.fractionCompleted * 100)
                let eta = progress.estimatedTimeRemaining ?? 0
                try? await emit(.progress(
                    downloadId,
                    percentage: min(pct, 99),
                    totalBytes: progress.totalUnitCount,
                    transferredBytes: progress.completedUnitCount,
                    eta: Int64(eta)
                ))
            }
        }
    )
    return result.path(percentEncoded: false)
}

// MARK: - ModelScope Download

private func downloadFromMscope(
    downloadId: String,
    modelId: String,
    revision: String?,
    useLatest: Bool,
    msToken: String?,
    logger: Logger,
    emit: @escaping (DownloadSSEEvent) async throws -> Void
) async throws -> String {
    let downloader = ModelScopeDownloader(token: msToken)
    logger.info("Downloading from ModelScope", metadata: ["model": .string(modelId)])

    let result: URL
    result = try await downloader.download(
        id: modelId,
        revision: revision,
        useLatest: useLatest,
        progressHandler: { progress in
            Task {
                let pct = Int(progress.fractionCompleted * 100)
                let eta = progress.estimatedTimeRemaining ?? 0
                try? await emit(.progress(
                    downloadId,
                    percentage: min(pct, 99),
                    totalBytes: progress.totalUnitCount,
                    transferredBytes: progress.completedUnitCount,
                    eta: Int64(eta)
                ))
            }
        }
    )
    return result.path(percentEncoded: false)
}

#endif // mlx

