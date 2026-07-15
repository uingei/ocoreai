// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelDownloadHandler.swift — SSE handler for ``POST /v1/models/download``
///
/// Streams download progress as SSE events:
/// - "progress" with percentage, bytes, eta
/// - "completed" with cache path
/// - "error" with error message


	import Foundation
	import HTTPTypes
	import HuggingFace
	import Hummingbird
	import Logging
	import MLXHuggingFace
	import MLXLLM
	import MLXLMCommon

	// MARK: - Helpers

	private func encodeEvent(_ event: DownloadSSEEvent) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(event)
		guard let json = String(data: data, encoding: .utf8) else {
			return "[]"
		}
		return "data: \(json)\n\n"
	}

	// MARK: - Handler

	/// Handle POST /v1/models/download
	func modelDownloadHandler(
		request: DownloadModelRequest,
		hfToken: String?,
		msToken: String?,
		logger: Logger,
	) async throws -> Response {
		try request.validate()

		let provider = request.effectiveProvider
		let downloadId = "\(provider):\(request.model)"

		let responseHeaders = SSEHeaders

		return Response(
			status: .ok,
			headers: responseHeaders,
			body: .init { writer in
				// AsyncStream channel decouples download producer from SSE writer — avoids
				// capturing non-Sendable `writer` in a Task/Sendable closure.
				let (events, eventCont) = AsyncStream<DownloadSSEEvent>.makeStream(
					bufferingPolicy: .unbounded,
				)

				Task {
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
							emit: { event in eventCont.yield(event) },
						)
						eventCont.yield(.completed(downloadId, cacheDir: cacheDir))
					} catch {
						eventCont.yield(.error(downloadId, message: error.localizedDescription))
					}
					eventCont.finish()
				}

				for await event in events {
					do {
						let line = try encodeEvent(event)
						guard let lineData = line.data(using: .utf8) else { break }
						try await writer.write(.init(data: lineData))
					} catch {
						// Client disconnected or encoding failed — stop streaming
						logger.warning("SSE write failed: \(error)")
						break
					}
				}
			},
		)
	}

	// MARK: - Download Dispatch

	/// Actually run the download, emitting SSE progress events.
	///
	/// Acquires a global download concurrency slot before starting — prevents
	/// API path from bypassing UI path's concurrency limits. Releases the slot
	/// on both success and failure.
	private func doDownload(
		downloadId: String,
		modelId: String,
		provider: String,
		revision: String?,
		useLatest: Bool,
		hfToken: String?,
		msToken: String?,
		logger: Logger,
		emit: @Sendable @escaping (DownloadSSEEvent) -> Void,
	) async throws -> String {
		// Extract bare repoId for semaphore key
		let bareId = modelId

		// Acquire concurrency slot — waits if all slots are busy
		let shouldProceed = await DownloadSemaphore.shared.acquireOrWait(for: bareId)
		guard shouldProceed else {
			throw AppError.invalidRequest("Model \(modelId) is already being downloaded by another request")
		}
		defer {
			// Release slot on all exit paths (return, throw, cancel)
			DownloadSemaphore.shared.release(for: bareId)
		}

		switch provider {
		case "hf": return try await downloadFromHF(
				downloadId: downloadId, modelId: modelId, revision: revision,
				useLatest: useLatest, hfToken: hfToken, logger: logger, emit: emit,
			)
		case "mscope": return try await downloadFromMscope(
				downloadId: downloadId, modelId: modelId, revision: revision,
				useLatest: useLatest, msToken: msToken, logger: logger, emit: emit,
			)
		default: throw AppError.invalidRequest("Unknown provider: \(provider)")
		}
	}

	// MARK: - HF Download

	private func downloadFromHF(
		downloadId: String,
		modelId: String,
		revision: String?,
		useLatest: Bool,
		hfToken _: String?,
		logger: Logger,
		emit: @Sendable @escaping (DownloadSSEEvent) -> Void,
	) async throws -> String {
		// Native MLX path: #hubDownloader() gives built-in cache, resume, progress.
		// Auth is auto-detected by HubClient from HF_TOKEN env var / filesystem —
		// no need to wire token through handler.
		let downloader = #hubDownloader()
		logger.info("Downloading from HuggingFace", metadata: ["model": .string(modelId)])

		let result: URL
		result = try await downloader.download(
			id: modelId,
			revision: revision,
			matching: [],
			useLatest: useLatest,
			progressHandler: { progress in
				let pct = Int(progress.fractionCompleted * 100)
				let eta = progress.estimatedTimeRemaining ?? 0
				emit(.progress(
					downloadId,
					percentage: min(pct, 99),
					totalBytes: progress.totalUnitCount,
					transferredBytes: progress.completedUnitCount,
					eta: Int64(eta),
				))
			},
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
		emit: @Sendable @escaping (DownloadSSEEvent) -> Void,
	) async throws -> String {
		let downloader = ModelScopeDownloader(token: msToken)
		logger.info("Downloading from ModelScope", metadata: ["model": .string(modelId)])

		let result: URL
		result = try await downloader.download(
			id: modelId,
			revision: revision,
			matching: ["*.safetensors", "*.json", "*.jinja"],
			useLatest: useLatest,
			progressHandler: { progress in
				let pct = Int(progress.fractionCompleted * 100)
				let eta = progress.estimatedTimeRemaining ?? 0
				emit(.progress(
					downloadId,
					percentage: min(pct, 99),
					totalBytes: progress.totalUnitCount,
					transferredBytes: progress.completedUnitCount,
					eta: Int64(eta),
				))
			},
		)
		return result.path(percentEncoded: false)
	}

