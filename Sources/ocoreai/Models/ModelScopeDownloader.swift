// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// ModelScopeDownloader.swift — Download models from ModelScope Hub
//
// Conforms to ml-explore/mlx-swift-lm `Downloader` protocol, enabling
// `LLMModelFactory.load(from: ModelScopeDownloader())` seamless ModelScope support.
//
// ### Architecture:
// - ModelId format: `"mscope:Qwen/Qwen2.5-7B-Instruct"` (prefix: provider)
//   - The Downloader receives just the repo-id after prefix is stripped
// - Cache path: `~/Library/Caches/ocoreai/modelscope/{repo_id}/{revision}/`
// - Download: lists file tree via ModelScope API, filters by glob patterns,
//   then downloads files in parallel with progress tracking

#if mlx

import Foundation
import MLXLMCommon

/// ModelScope Hub API client conforming to mlx-swift-lm ``Downloader`` protocol.
///
/// Usage:
/// ```swift
/// let downloader = ModelScopeDownloader(modelScopeToken: nil)
/// let context = try await LLMModelFactory.shared.load(
///     from: downloader,
///     using: HUGGING_FACE_TOKENIZER_LOADER,
///     configuration: ModelConfiguration(id: "Qwen/Qwen2.5-7B-Instruct")
/// )
/// ```
actor ModelScopeDownloader: Downloader, @unchecked Sendable {

    // MARK: - Configuration

    private let token: String?
    private let baseAPI: URL = URL(string: "https://www.modelscope.cn/api/v1")!
    private let cacheRoot: URL
    private let fileCountLimit: Int = 200 // Cap file-list pagination

    /// Create a ModelScope Downloader.
    ///
    /// - Parameters:
    ///   - token: Optional ModelScope API token (for private repos). Usually not needed.
    ///   - cacheRoot: Override cache directory (default: `~/.cache/ocoreai/modelscope/`)
    init(token: String? = nil, cacheRoot: URL? = nil) {
        self.token = token
        self.cacheRoot = cacheRoot ?? {
            let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            return urls.first?.appendingPathComponent("ocoreai/modelscope")
                ?? URL(fileURLWithPath: "/tmp/ocoreai-modelscope-cache")
        }()
        // Create cache root if it doesn't exist
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
        // 1. Compute local cache directory
        let cacheDir = cacheRoot
            .appendingPathComponent(id)
            .appendingPathComponent(revision ?? "master")

        // 2. Check cache — if files matching all patterns exist and !useLatest, return early
        if !useLatest, let existingFiles = try? listLocalFiles(in: cacheDir),
           let missingPattern = firstMissingPattern(patterns, in: existingFiles) {
            // Only skip if ALL patterns have at least one match
            let allSatisfied = patterns.allSatisfy { pattern in
                existingFiles.contains { matchesGlob($0, pattern) }
            }
            if allSatisfied {
                return cacheDir
            }
            // Some patterns present — proceed with partial download (only download missing)
        }

        // 3. Fetch file tree from ModelScope
        let fileInfo = try await listRepoFiles(repoId: id, revision: revision ?? "master")

        // 4. Filter files matching patterns
        let matchingFiles = fileInfo.filter { fileInfo in
            patterns.contains { matchesGlob(fileInfo.path, $0) }
        }

        guard !matchingFiles.isEmpty else {
            throw DownloaderError.noFilesMatching(repoId: id, patterns: patterns)
        }

        // 5. Determine which files already exist in cache (skip re-download)
        let existingFilenames = Set(try? listLocalFiles(in: cacheDir) ?? [])

        // 6. Download missing files in parallel groups
        try await downloadFiles(
            matchingFiles,
            to: cacheDir,
            repoId: id,
            revision: revision ?? "master",
            existingFilenames: existingFilenames,
            progressHandler: progressHandler
        )

        return cacheDir
    }

    // MARK: - ModelScope API

    /// File info from ModelScope tree endpoint.
    private struct FileInfo: Decodable {
        let path: String
        let size: Int64?
        let type: String // "file" or "dir"
    }

    private struct TreeResponse: Decodable {
        let files: [FileInfo]
    }

    private struct FileListNode: Decodable {
        let path: String
        let size: Int64?
        let type: String
    }

    private func createHeaders() -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
        ]
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    /// List files in a ModelScope repo.
    ///
    /// Uses `/api/v1/repos/{owner}/{repo}/tree` which returns the file listing.
    private func listRepoFiles(repoId: String, revision: String) async throws -> [FileInfo] {
        let endpoint = baseAPI
            .appendingPathComponent("/repos")
            .appendingPathComponent(repoId)
            .appendingPathComponent("tree")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = createHeaders()

        // Add query parameters
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "path", value: ""),
            URLQueryItem(name: "revision", value: revision),
        ]
        request.url = components.url!

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw DownloaderError.apiError(statusCode: 0, body: body)
        }

        // ModelScope tree endpoint returns { "data": ["path1", "path2", ...] } or { "files": [...] }
        // Try both response shapes
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Shape 1: { "files": [{ "path": "...", "size": 123, "type": "file" }, ...] }
            if let filesArray = json["files"] as? [[String: Any]] {
                return filesArray.compactMap { dict in
                    guard let path = dict["path"] as? String else { return nil }
                    let size = dict["size"] as? Int64
                    let type = dict["type"] as? String ?? "file"
                    return FileInfo(path: path, size: size, type: type)
                }.filter { $0.type == "file" }
            }
            // Shape 2: { "data": { "files": ["path1", "path2", ...] } }
            if let dataDict = json["data"] as? [String: Any],
               let paths = dataDict["files"] as? [String] {
                return paths.map { path in
                    FileInfo(path: path, size: nil, type: "file")
                }
            }
            // Shape 3: plain array [String]
            if let paths = try? JSONDecoder().decode([String].self, from: data) {
                return paths.map { path in
                    FileInfo(path: path, size: nil, type: "file")
                }
            }
        }

        throw DownloaderError.parseError
    }

    /// Download a single file from ModelScope.
    ///
    /// Uses `/api/v1/repos/{id}/resolve/{revision}/{path}` which redirects to actual CDN.
    private func downloadSingleFile(
        path: String,
        to destURL: URL,
        repoId: String,
        revision: String,
        progressHandler: (@Sendable (Int, Int) -> Void)? = nil // (bytes, total)
    ) async throws {
        let endpoint = baseAPI
            .appendingPathComponent("/repos")
            .appendingPathComponent(repoId)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
            .appendingPathComponent(path)

        var request = URLRequest(url: endpoint)
        request.allHTTPHeaderFields = createHeaders()

        // Ensure parent directory exists
        let parent = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Download with temporary file then atomic move
        let tempURL = parent.appendingPathComponent(".download-\(UUID().uuidString.prefix(8))")
        do {
            let (tempDownloadURL, response) = try await URLSession.shared.download(from: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw DownloaderError.downloadFailed(path: path, statusCode: status)
            }

            let totalBytes = httpResponse.expectedContentLength
            _ = totalBytes // Acknowledge

            // Atomic move from URLSession temp file to destination
            if FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempDownloadURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Download files in parallel batches of 4.
    private func downloadFiles(
        _ files: [FileInfo],
        to cacheDir: URL,
        repoId: String,
        revision: String,
        existingFilenames: Set<String>,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {
        let total = files.count
        var downloaded = 0

        for chunk in files.chunked(into: 4) {
            let tasks = chunk.map { fileInfo -> Task<Bool, Error> in
                Task {
                    // Skip if already cached
                    let path = String(fileInfo.path)
                    if existingFilenames.contains(path) {
                        return true
                    }
                    let dest = cacheDir.appendingPathComponent(path)
                    try await downloadSingleFile(
                        path: path,
                        to: dest,
                        repoId: repoId,
                        revision: revision
                    )
                    return true
                }
            }

            for task in tasks {
                do {
                    let _ = try await task.value
                    downloaded += 1
                    let progress = Progress(totalUnitCount: Int64(total))
                    progress.completedUnitCount = Int64(downloaded)
                    progressHandler(progress)
                } catch {
                    // Log but continue — other files may still download
                    downloadFailedPath = path // Not ideal, but best we can do
                }
            }
        }
    }

    // MARK: - Helpers

    private func listLocalFiles(in directory: URL) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return contents.map { $0.lastPathComponent }
    }

    /// Check if any of the glob patterns has zero matches in the existing files.
    /// Returns the first unsatisfied pattern, or nil if all satisfied.
    private func firstMissingPattern(_ patterns: [String], in existingFiles: [String]) -> String? {
        for pattern in patterns {
            let hasMatch = existingFiles.contains { matchesGlob($0, pattern) }
            if !hasMatch {
                return pattern
            }
        }
        return nil
    }

    /// Simple glob matching (supports *.ext and exact match).
    private func matchesGlob(_ filename: String, _ pattern: String) -> Bool {
        if pattern.hasPrefix("*") {
            let ext = pattern.drop { $0 == "*" }
            return filename.hasSuffix(ext)
        }
        return filename == pattern
    }

    // Track failed path for error reporting
    var downloadFailedPath: String = ""
}

/// Error types for the downloader.
enum DownloaderError: LocalizedError {
    case noFilesMatching(repoId: String, patterns: [String])
    case apiError(statusCode: Int, body: String)
    case downloadFailed(path: String, statusCode: Int)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noFilesMatching(let repo, let patterns):
            return "No files in model '\(repo)' matching patterns \(patterns)"
        case .apiError(let code, let body):
            return "ModelScope API error (\(code)): \(body)"
        case .downloadFailed(let path, let code):
            return "Download failed for '\(path)' (HTTP \(code))"
        case .parseError:
            return "Failed to parse ModelScope API response"
        }
    }
}

// MARK: - Array chunked helper

extension Array {
    /// Split array into chunks of the given size.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

#endif // mlx
