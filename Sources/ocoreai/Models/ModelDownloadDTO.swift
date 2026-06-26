// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelDownloadDTO.swift â€” DTO types for model download API
///
/// Request/response types for ``POST /v1/models/download`` endpoint.

import Foundation

// MARK: - Request

struct DownloadModelRequest: Codable {
	let model: String
	let provider: String?
	let revision: String?
	let useLatest: Bool

	var effectiveProvider: String {
		provider ?? "hf"
	}

	init(model: String, provider: String? = nil, revision: String? = nil, useLatest: Bool = false) {
		self.model = model
		self.provider = provider
		self.revision = revision
		self.useLatest = useLatest
	}

	func validate() throws {
		guard !model.isEmpty else {
			throw AppError.invalidRequest("Model identifier must not be empty")
		}
		let p = effectiveProvider
		guard p == "hf" || p == "mscope" else {
			throw AppError.invalidRequest("Provider must be hf or mscope, got \(p)")
		}
	}
}

// MARK: - SSE Event

struct DownloadSSEEvent: Codable {
	let downloadId: String
	let eventType: String // "progress" | "completed" | "error"
	let percentage: Int?
	let totalBytes: Int64?
	let transferredBytes: Int64?
	let cacheDir: String?
	let errorMessage: String?
	let etaSeconds: Int64?

	static func progress(_ downloadId: String, percentage: Int, totalBytes: Int64, transferredBytes: Int64, eta: Int64?) -> DownloadSSEEvent {
		DownloadSSEEvent(downloadId: downloadId, eventType: "progress", percentage: percentage,
		                 totalBytes: totalBytes, transferredBytes: transferredBytes,
		                 cacheDir: nil, errorMessage: nil, etaSeconds: eta)
	}

	static func completed(_ downloadId: String, cacheDir: String) -> DownloadSSEEvent {
		DownloadSSEEvent(downloadId: downloadId, eventType: "completed", percentage: 100,
		                 totalBytes: nil, transferredBytes: nil, cacheDir: cacheDir,
		                 errorMessage: nil, etaSeconds: nil)
	}

	static func error(_ downloadId: String, message: String) -> DownloadSSEEvent {
		DownloadSSEEvent(downloadId: downloadId, eventType: "error", percentage: nil,
		                 totalBytes: nil, transferredBytes: nil, cacheDir: nil,
		                 errorMessage: message, etaSeconds: nil)
	}
}

// MARK: - Status Response

struct DownloadStatusResponse: Codable {
	let downloadId: String
	let status: String // "downloading" | "completed" | "error" | "not_found"
	let percentage: Int?
	let cacheDir: String?
	let errorMessage: String?
}
