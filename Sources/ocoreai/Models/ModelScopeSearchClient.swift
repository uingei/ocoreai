// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelScopeSearchClient.swift — Search and browse models on ModelScope Hub
///
/// Reverse-engineered from the Python SDK (modelscope 1.x):
///   PUT /api/v1/models/          — list/search models by keyword
///   GET /api/v1/models/{owner}/{name} — model detail
///   GET /api/v1/models/{owner}/{name}/repo — file download
///
/// No official Swift SDK exists — this is a thin HTTP client built from
/// the Python SDK behavior as reference.

import Foundation

// MARK: - DTOs

/// Model entry from ModelScope Hub search/list results.
struct MSHubModel: Identifiable, Hashable, Sendable {
    /// Internal numeric ID
    let id: Int
    /// Repo path e.g. "Qwen/Qwen2.5-7B-Instruct"
    let path: String
    /// Short display name
    let displayName: String
    /// Chinese name (if available)
    let chineseName: String?
    /// Downloads count
    let downloads: Int
    /// Stars/likes count
    let stars: Int
    /// Model tasks/tags e.g. ["text-generation", "llm"]
    let tasks: [String]
    /// Frameworks e.g. ["PyTorch", "MindSpore"]
    let frameworks: [String]
    /// Short description
    let description: String?
    /// Model type e.g. ["qwen3_moe"]
    let modelType: [String]
    /// License name
    let license: String?
    /// Storage size string
    let storageSize: String?
    /// Created timestamp (Unix seconds)
    let createdTime: Int?
    /// Whether this model is marked hot/trending
    let isHot: Bool

    var identifier: String { path }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(path)
    }

    static func == (lhs: MSHubModel, rhs: MSHubModel) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path
    }
}

// MARK: - Search Client

/// Lightweight HTTP client for ModelScope model search.
///
/// Uses only Foundation HTTP — no external dependency needed.
final actor ModelScopeSearchClient {

    // MARK: - Configuration

    /// Base URL — follows the same pattern as the Python SDK.
    private let baseURL: String
    private let token: String?

    /// Create the client.
    /// - Parameters:
    ///   - baseURL: API base URL (defaults to ModelScope main site)
    ///   - token: Optional access token for authed operations
    init(
        baseURL: String = "https://modelscope.cn",
        token: String? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Search

    /// Search models by keyword.
    ///
    /// - Parameters:
    ///   - keyword: Search term — matched against model name, owner, description.
    ///             Pass empty string to list all public models.
    ///   - page: Page number (1-based).
    ///   - pageSize: Number of results per page (default 20, max 100).
    /// - Returns: Tuple of (models, totalCount).
    func search(
        keyword: String,
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> (models: [MSHubModel], totalCount: Int) {
        // Python SDK uses PUT for list_models — unusual but real.
        let url = URL(string: "\(baseURL)/api/v1/models/\")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "Path": keyword,
            "PageNumber": page,
            "PageSize": min(pageSize, 100),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MSError.httpError(response)
        }

        return try parseModelList(data)
    }

    // MARK: - Model Detail

    /// Get detailed info for a specific model.
    /// - Parameter modelId: Full model path e.g. "Qwen/Qwen2.5-7B-Instruct"
    func modelDetail(modelId: String) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/api/v1/models/\(modelId)")!
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MSError.httpError(response)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MSError.invalidJSON
        }

        // Python SDK wraps in Code/Data — return Data field
        return json["Data"] as? [String: Any] ?? json
    }

    // MARK: - Parsing

    /// Parse the top-level list response into models.
    private func parseModelList(_ data: Data) throws -> (models: [MSHubModel], totalCount: Int) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MSError.invalidJSON
        }

        // Response shape: { "Code": 200, "Data": { "Models": [...], "TotalCount": N } }
        // or flat: { "Models": [...], "TotalCount": N }
        let dataObj: [String: Any]
        if let nested = json["Data"] as? [String: Any] {
            dataObj = nested
        } else {
            dataObj = json
        }

        guard let modelsRaw = dataObj["Models"] as? [[String: Any]] else {
            throw MSError.missingField("Models")
        }

        let totalCount = dataObj["TotalCount"] as? Int ?? modelsRaw.count

        let models: [MSHubModel] = modelsRaw.compactMap { raw in
            // Path is the primary model identifier in list responses
            let path = raw["Path"] as? String ?? (raw["Name"] as? String ?? "")
            guard !path.isEmpty else { return nil }

            let tasks = (raw["Tasks"] as? [String]) ?? []
            let frameworks = (raw["Frameworks"] as? [String]) ?? []
            let modelType = (raw["ModelType"] as? [String]) ?? []

            return MSHubModel(
                id: raw["Id"] as? Int ?? 0,
                path: path,
                displayName: path.components(separatedBy: "/").last ?? path,
                chineseName: raw["ChineseName"] as? String,
                downloads: raw["Downloads"] as? Int ?? 0,
                stars: (raw["Stars"] as? Int ?? 0) + (raw["Likes"] as? Int ?? 0),
                tasks: tasks,
                frameworks: frameworks,
                description: (raw["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                modelType: modelType,
                license: raw["License"] as? String ?? raw["LicenseName"] as? String,
                storageSize: raw["StorageSize"] as? String,
                createdTime: raw["CreatedTime"] as? Int,
                isHot: (raw["IsHot"] as? Int ?? 0) == 1
            )
        }

        return (models, totalCount)
    }
}

// MARK: - Errors

enum MSError: LocalizedError {
    case httpError(any URLRequest.Response?)
    case invalidJSON
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let resp):
            return "ModelScope API request failed: \(String(describing: resp))"
        case .invalidJSON:
            return "Invalid JSON response from ModelScope"
        case .missingField(let field):
            return "Expected field '\(field)' not found in ModelScope response"
        }
    }
}
