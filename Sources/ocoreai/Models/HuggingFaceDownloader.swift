// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// HuggingFaceDownloader.swift — Download models from HuggingFace Hub
//
// Conforms to ml-explore/mlx-swift-lm `Downloader` protocol, enabling
// `LLMModelFactory.load(from: HuggingFaceDownloader())` for MLX inference.
//
// ### Architecture:
// - ModelId format: `"hf:org/model"` (prefix is stripped before passing here)
// - Cache path: `~/Library/Caches/ocoreai/huggingface/{repo_id}/{revision}/`
// - Download: lists repo tree via HuggingFace API, filters by glob, downloads files
//
// Reference: ModelScopeDownloader.swift alongside this file for the same pattern.

#if mlx

import Foundation
import MLXLMCommon

/// HuggingFace Hub API client conforming to mlx-swift-lm ``Downloader`` protocol.
///
/// Usage:
/// ```swift
/// let downloader = HuggingFaceDownloader(token: nil)
/// let context = try await LLMModelFactory.shared.load(
///     from: downloader,
///     using: HUGGING_FACE_TOKENIZER_LOADER,
///     configuration: ModelConfiguration(id: "mlx-community/Qwen3.5-4B-OptiQ-4bit")
/// )
/// ```
actor HuggingFaceDownloader: Downloader {

    // MARK: - Configuration

    private let baseAPI: URL
    private let downloadURL: URL
    private let cacheRoot: URL
    private let fileCountLimit: Int = 500
    private let token: String?

    /// Max concurrent download tasks — prevents 429 rate-limit from HuggingFace API.
    private let maxConcurrentDownloads: Int = 8

    init(token: String? = nil, cacheRoot: URL? = nil) {
        self.token = token ?? ProcessInfo.processInfo.environment["HF_TOKEN"]
        self.baseAPI = URL(string: "https://huggingface.co/api")! // compile-time constant — always valid
        self.downloadURL = URL(string: "https://huggingface.co")! // compile-time constant — always valid
        self.cacheRoot = cacheRoot ?? {
            let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            return urls.first?.appendingPathComponent("ocoreai/huggingface")
                ?? URL(fileURLWithPath: "/tmp/ocoreai-hf-cache")
        }()
        try? FileManager.default.createDirectory(
            at: self.cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Downloader Conformance

    func download(
        id: String,
        revision: String? = nil,
        matching patterns: [String] = ["*.safetensors", "*.json", "*.jinja"],
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let cacheDir = cacheRoot
            .appendingPathComponent(id)
            .appendingPathComponent(revision ?? "main")

        // 1. Check cache
        if !useLatest, let existingFiles = try? listLocalFiles(in: cacheDir) {
            let allSatisfied = patterns.allSatisfy { pattern in
                existingFiles.contains { matchesGlob($0, pattern) }
            }
            if allSatisfied {
                return cacheDir
            }
        }

        // 2. Ensure cache dir exists
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // 3. List repo tree via HuggingFace API
        let repoId = id // repo_id after "hf:" prefix stripped
        let treeURL = baseAPI
            .appendingPathComponent("models")
            .appendingPathComponent(repoId)
            .appendingPathComponent("tree")
            .appendingPathComponent(revision ?? "main")

        let treeFiles = try await fetchRepoTree(url: treeURL)

        // 4. Filter by patterns and compute total bytes
        let filteredFiles = treeFiles.filter { file in
            let path = file["path"] as? String ?? ""
            guard (patterns.first { matchesGlob(path, $0) }) != nil else { return false }
            return (file["type"] as? String) != "directory"
        }

        let totalBytes = filteredFiles.reduce(0) { accumulated, file in
            accumulated + (file["size"] as? Int ?? 0)
        }

        let progress = Progress(totalUnitCount: Int64(totalBytes))

        // 5. Download in batches to limit concurrency (prevent 429 rate-limit)
        // P1-7 fix: bounded concurrency via batched task groups
        let batchSize = maxConcurrentDownloads
        for batchStart in stride(from: 0, to: filteredFiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, filteredFiles.count)
            let batch = Array(filteredFiles[batchStart..<batchEnd])

            try await withThrowingTaskGroup(of: Void.self) { group in
                for file in batch {
                    let path = file["path"] as? String ?? ""
                    group.addTask { [weak self] in
                        guard let self else { return }
                        let downloadPath = cacheDir.appendingPathComponent(path)
                        let parentDir = downloadPath.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(
                            at: parentDir, withIntermediateDirectories: true
                        )

                        let exists = FileManager.default.fileExists(
                            atPath: downloadPath.path(percentEncoded: false)
                        )
                        guard !exists else { return }

                        let fileURL = self.downloadURL
                            .appendingPathComponent("resolve")
                            .appendingPathComponent(revision ?? "main")
                            .appendingPathComponent(path)
                        try await self.downloadFile(from: fileURL, to: downloadPath)
                    }
                }
                try await group.waitForAll()
            }
        }

        // Update progress after all downloads complete
        progress.completedUnitCount = Int64(totalBytes)
        progressHandler(progress)

        return cacheDir
    }

    // MARK: - HuggingFace API

    private func fetchRepoTree(url: URL) async throws -> [[String: Any]] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw HFDownloadError.invalidResponse
        }

        switch httpResp.statusCode {
        case 200:
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json
            }
            throw HFDownloadError.invalidJSON
        case 401:
            throw HFDownloadError.unauthorized
        case 403:
            throw HFDownloadError.privateRepo
        case 404:
            throw HFDownloadError.notFound
        default:
            throw HFDownloadError.unknown(status: httpResp.statusCode)
        }
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Use streaming download instead of loading entire file into memory
        // to avoid OOM with large model files (5-10GB safetensors)
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            throw HFDownloadError.downloadFailed
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Helpers (shared with ModelScopeDownloader patterns)

    private func firstMissingPattern(_ patterns: [String], in files: [String]) -> String? {
        for pattern in patterns where !files.contains(where: { matchesGlob($0, pattern) }) {
            return pattern
        }
        return nil
    }

    private func matchesGlob(_ string: String, _ pattern: String) -> Bool {
        let components = string.components(separatedBy: "/")
        let patternParts = pattern.components(separatedBy: "/")
        guard patternParts.count == components.count else { return false }
        var matched = true
        for (pat, comp) in zip(patternParts, components) where matched {
            if !pat.isEmpty && !pat.contains("*") && !pat.contains("?") {
                matched = (pat == comp)
            }
        }
        return matched
    }

    private func listLocalFiles(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return items.map { $0.path(percentEncoded: false) }
    }
}

// MARK: - Error types

enum HFDownloadError: Error, LocalizedError {
    case invalidResponse
    case invalidJSON
    case unauthorized
    case privateRepo
    case notFound
    case downloadFailed
    case unknown(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid HuggingFace API response"
        case .invalidJSON: return "Failed to parse HuggingFace API JSON"
        case .unauthorized: return "HuggingFace authentication failed — check your token"
        case .privateRepo: return "Repository is not accessible with current credentials"
        case .notFound: return "Model repository not found on HuggingFace Hub"
        case .downloadFailed: return "File download failed"
        case .unknown(let status): return "HuggingFace API error: \(status)"
        }
    }
}

#endif // mlx
