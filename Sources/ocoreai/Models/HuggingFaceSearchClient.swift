// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HuggingFaceSearchClient.swift — Browse and search models on HuggingFace Hub
///
/// Calls the HF Hub API (/api/models) to discover MLX-compat models.
/// Download is handled by #hubDownloader() native macro (MLXHuggingFace).

import Foundation

// MARK: - Search DTOs

/// Model entry from HuggingFace Hub search results.
struct HFHubModel: Identifiable, Hashable, Sendable {
    /// Full repo ID (e.g. "mlx-community/Llama-3.1-8B-Instruct-4bit")
    let id: String
    /// Short display name (last path component)
    let displayName: String
    /// Tags on the model (e.g. "mlx", "generation", "text-generation")
    let tags: [String]
    /// Number of likes/stars
    let likes: Int
    /// Whether the model has a pipeline_tag indicating it's a generation model
    let pipelineTag: String?
    /// Last modified date string
    let lastModified: String?
    /// Monthly downloads count (from metrics)
    let downloads: Int?
    /// Size in bytes (approximate, from card data if available)
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

    init(id: String, displayName: String, tags: [String], likes: Int, pipelineTag: String?, lastModified: String?, downloads: Int?, sizeBytes: Int64?) {
        self.id = id
        self.displayName = displayName
        self.tags = tags
        self.likes = likes
        self.pipelineTag = pipelineTag
        self.lastModified = lastModified
        self.downloads = downloads
        self.sizeBytes = sizeBytes
    }

    /// Parse from HuggingFace API JSON
    static func fromAPIResponse(_ dict: [String: Any]) -> HFHubModel? {
        guard let repoId = dict["id"] as? String else { return nil }
        let displayName = dict["_id"] as? String ?? dict["id"] as? String ?? repoId
        let tags = (dict["tags"] as? [String]) ?? []
        let likes = (dict["likes"] as? Int) ?? 0
        let pipelineTag = dict["pipeline_tag"] as? String
        let lastModified = dict["lastModified"] as? String
        let downloadsVal = dict["downloads"] as? Int
        // HF API doesn't consistently provide size — skip for now
        return HFHubModel(
            id: repoId,
            displayName: displayName,
            tags: tags,
            likes: likes,
            pipelineTag: pipelineTag,
            lastModified: lastModified,
            downloads: downloadsVal,
            sizeBytes: nil
        )
    }
}

/// Search filters for narrowing results.
struct HFSearchFilters: Sendable {
    /// Only MLX-compatible models
    var mlxOnly: Bool = true
    /// Only generation models (text-generation, etc.)
    var generationOnly: Bool = true

    /// Convert to HF API query params
    var tags: [String] {
        var result: [String] = []
        if mlxOnly { result.append("mlx") }
        if generationOnly { result.append("text-generation") }
        return result
    }
}

// MARK: - Search Client

/// Client for browsing/searching HuggingFace Hub.
actor HuggingFaceSearchClient {
    private let baseURL: URL
    private let token: String?

    init(token: String? = nil) {
        self.baseURL = URL(string: "https://huggingface.co/api")!
        self.token = token ?? ProcessInfo.processInfo.environment["HF_TOKEN"] ??
                         ProcessInfo.processInfo.environment["HF_API_TOKEN"]
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
        sort: String = "downloads"
    ) async throws -> [HFHubModel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []

        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        // Tag filtering — multiple tags narrows results
        for tag in filters.tags {
            queryItems.append(URLQueryItem(name: "filter", value: tag))
        }
        queryItems.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000))))
        if !sort.isEmpty {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }
        queryItems.append(URLQueryItem(name: "full", value: "true"))

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFSearchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw HFSearchError.invalidJSON
            }
            return json.compactMap { HFHubModel.fromAPIResponse($0) }
        case 400:
            throw HFSearchError.badQuery
        case 401:
            throw HFSearchError.unauthorized
        case 429:
            throw HFSearchError.rateLimited
        default:
            throw HFSearchError.unknown(status: httpResponse.statusCode)
        }
    }

    /// Trending MLX models (curated subset sorted by trending score).
    func trendingMLX(limit: Int = 30) async throws -> [HFHubModel] {
        try await search(
            query: "",
            filters: HFSearchFilters(mlxOnly: true, generationOnly: true),
            limit: limit,
            sort: "trending"
        )
    }

    /// Get detailed info for a single model (including safetensors index for size estimation).
    func modelInfo(repoId: String) async throws -> [String: Any] {
        let url = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent(repoId)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HFSearchError.notFound
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HFSearchError.invalidJSON
        }
        return json
    }

    /// List repo files for size estimation.
    func listFiles(repoId: String) async throws -> [[String: Any]] {
        let url = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent(repoId)
            .appendingPathComponent("tree")
            .appendingPathComponent("main")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HFSearchError.notFound
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HFSearchError.invalidJSON
        }
        return json
    }

    /// Estimate model size by summing safetensors files.
    func estimateSize(repoId: String) async throws -> Int64 {
        let files = try await self.listFiles(repoId: repoId)
        let safetensors = files.filter { file in
            let path = file["path"] as? String ?? ""
            return path.hasSuffix(".safetensors") || path.hasSuffix(".safetensors.index.json")
        }
        return safetensors.reduce(0) { $0 + Int64($1["size"] as? Int ?? 0) }
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
    case unknown(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from HuggingFace Hub"
        case .invalidJSON: return "Failed to parse HuggingFace response"
        case .badQuery: return "Invalid search query"
        case .unauthorized: return "Authentication required — check HF token"
        case .rateLimited: return "Rate limited by HuggingFace Hub — please wait"
        case .notFound: return "Model not found on HuggingFace Hub"
        case .unknown(let s): return "HuggingFace API error: \(s)"
        }
    }
}
