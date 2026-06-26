// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HuggingFaceSearchClient.swift — Browse and search models on HuggingFace Hub
///
/// Thin wrapper around swift-huggingface's HubClient.listModels().
/// Download is handled by #hubDownloader() native macro (MLXHuggingFace).

import Foundation
import HuggingFace

// MARK: - Search DTOs

/// Model entry from HuggingFace Hub search results.
struct HFHubModel: Identifiable, Hashable {
	/// Full repo ID (e.g. "mlx-community/Llama-3.1-8B-Instruct-4bit")
	let id: String
	/// Short display name (last path component)
	let displayName: String
	/// Tags on the model (e.g. "mlx", "generation", "text-generation")
	let tags: [String]
	/// Number of likes/stars
	let likes: Int
	/// Pipeline tag (e.g. "text-generation")
	let pipelineTag: String?
	/// Last modified date string
	let lastModified: String?
	/// Monthly downloads count
	let downloads: Int?
	/// Size in bytes (approximate)
	let sizeBytes: Int64?

	/// Whether this model appears to be MLX-compatible (has "mlx" tag)
	var isMLXCompatible: Bool {
		tags.contains { $0.lowercased() == "mlx" }
	}

	/// Human-readable size string
	var sizeString: String {
		guard let bytes = sizeBytes, bytes > 0 else { return "" }
		let gigabytes = Double(bytes) / 1_073_741_824.0
		return String(format: "%.1f GB", gigabytes)
	}

	var nameComponents: (org: String, model: String) {
		let parts = id.components(separatedBy: "/")
		if parts.count >= 2 {
			return (parts[0], parts[1])
		}
		return ("", id)
	}

	/// Parse from HubClient Model type
	static func fromSDKModel(_ m: Model) -> HFHubModel {
		let id = m.id.description
		let tags = m.tags ?? []
		return HFHubModel(
			id: id,
			displayName: id.components(separatedBy: "/").last ?? id,
			tags: tags,
			likes: m.likes ?? 0,
			pipelineTag: m.pipelineTag,
			lastModified: m.lastModified.map { ISO8601DateFormatter().string(from: $0) },
			downloads: m.downloads,
			sizeBytes: m.usedStorage.map(Int64.init),
		)
	}
}

/// Search filters for narrowing results.
struct HFSearchFilters {
	/// Only MLX-compatible models
	var mlxOnly: Bool = true
	/// Only generation models (text-generation, etc.)
	var generationOnly: Bool = true
}

// MARK: - Search Client

/// Client for browsing/searching HuggingFace Hub.
///
/// Wraps swift-huggingface's HubClient.listModels() with MLX-specific
/// defaults (mlx filter, text-generation pipeline, sort by downloads).
actor HuggingFaceSearchClient {
	private let hubClient: HubClient

	/// Create with auto-detected token (HF_TOKEN env var, ~/.huggingface/token, etc.)
	init() {
		hubClient = .default
	}

	/// Search models by query string.
	///
	/// - Parameters:
	///   - query: Search keyword (empty string = no text filter)
	///   - filters: Tag-based filtering
	///   - limit: Max results (1-1000, HF default is 30)
	///   - sort: Sort field ("likes", "downloads", "lastModified", "trending")
	/// - Returns: Array of matching models
	func search(
		query: String = "",
		filters: HFSearchFilters = HFSearchFilters(),
		limit: Int = 50,
		sort: String = "downloads",
	) async throws -> [HFHubModel] {
		let clampedLimit = min(max(limit, 1), 1000)
		var filterTag: String? = nil
		if filters.mlxOnly {
			filterTag = filterTag.map { "\($0),mlx" } ?? "mlx"
		}
		if filters.generationOnly {
			filterTag = filterTag.map { "\($0),text-generation" } ?? "text-generation"
		}

		// Expand fields we care about for a rich UI
		let expandFields: [Extensible<HubClient.ModelExpandField>] = [
			.known(.downloads), .known(.likes), .known(.tags), .known(.pipelineTag),
			.known(.lastModified), .known(.cardData), .known(.safetensors),
		]

		do {
			let response: PaginatedResponse<Model> = try await hubClient.listModels(
				search: query.isEmpty ? nil : query,
				filter: filterTag,
				sort: sort,
				limit: clampedLimit,
				full: true,
				expand: ExtensibleCommaSeparatedList(expandFields),
			)
			return response.items.map { HFHubModel.fromSDKModel($0) }
		} catch {
			throw HFSearchError.fromSDKError(error)
		}
	}

	/// Trending MLX models (curated subset sorted by trending score).
	func trendingMLX(limit: Int = 30) async throws -> [HFHubModel] {
		try await search(
			query: "",
			filters: HFSearchFilters(mlxOnly: true, generationOnly: true),
			limit: limit,
			sort: "trending",
		)
	}

	/// Get detailed info for a single model (including safetensors index for size estimation).
	func modelInfo(repoId: String) async throws -> [String: Any] {
		guard let repo = Repo.ID(rawValue: repoId) else {
			throw HFSearchError.badQuery
		}
		do {
			let model = try await hubClient.getModel(repo, full: true)
			return try Model.toDictionary(model)
		} catch {
			throw HFSearchError.fromSDKError(error)
		}
	}
}

// MARK: - Dictionary conversion helper

extension Model {
	/// Convert Model to AnyHashable dictionary for backward compat with existing callers.
	static func toDictionary(_ m: Model) throws -> [String: Any] {
		var dict: [String: Any] = [:]
		dict["id"] = m.id.description
		if let author = m.author { dict["author"] = author }
		if let sha = m.sha { dict["sha"] = sha }
		if let lastModified = m.lastModified {
			dict["lastModified"] = ISO8601DateFormatter().string(from: lastModified)
		}
		if let downloads = m.downloads { dict["downloads"] = downloads }
		if let likes = m.likes { dict["likes"] = likes }
		if let tags = m.tags { dict["tags"] = tags }
		if let pipelineTag = m.pipelineTag { dict["pipeline_tag"] = pipelineTag }
		if let cardData = m.cardData { dict["cardData"] = cardData as Any }
		if let config = m.config { dict["config"] = config as Any }
		if let trendingScore = m.trendingScore { dict["trendingScore"] = trendingScore }
		if let usedStorage = m.usedStorage { dict["usedStorage"] = usedStorage }
		return dict
	}
}

// MARK: - Errors

enum HFSearchError: Error, LocalizedError {
	case invalidResponse
	case invalidJSON
	case badQuery
	case unauthorized
	case rateLimited
	case notFound
	case unknown(status: String)

	var errorDescription: String? {
		switch self {
		case .invalidResponse: "Invalid response from HuggingFace Hub"
		case .invalidJSON: "Failed to parse HuggingFace response"
		case .badQuery: "Invalid search query"
		case .unauthorized: "Authentication required — check HF token"
		case .rateLimited: "Rate limited by HuggingFace Hub — please wait"
		case .notFound: "Model not found on HuggingFace Hub"
		case let .unknown(s): "HuggingFace API error: \(s)"
		}
	}

	/// Map swift-huggingface error types to our error enum.
	static func fromSDKError(_ error: Error) -> HFSearchError {
		let message = (error as CustomStringConvertible).description.lowercased()
		if message.contains("401") || message.contains("unauthorized") {
			return .unauthorized
		}
		if message.contains("429") || message.contains("rate") {
			return .rateLimited
		}
		if message.contains("404") || message.contains("not found") {
			return .notFound
		}
		if message.contains("400") || message.contains("bad request") {
			return .badQuery
		}
		return .unknown(status: message)
	}
}
