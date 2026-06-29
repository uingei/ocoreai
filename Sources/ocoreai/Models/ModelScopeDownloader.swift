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
//
// All API paths, parameters, and response structures are derived from the
// ModelScope Python SDK (modelscope v1.x) — this is an SDK-alignment port.

#if mlx

	import Foundation
	import MLXLMCommon

/// ModelScope Hub API client conforming to mlx-swift-lm ``Downloader`` protocol.
actor ModelScopeDownloader: Downloader {
	// MARK: - Configuration

	private let token: String?
	private let baseAPI: URL
	private let cacheRoot: URL
	private let fileCountLimit: Int = 200

	/// Create a ModelScope Downloader.
	init(token: String? = nil, cacheRoot: URL? = nil) {
		self.token = token
		baseAPI = URL(string: "https://www.modelscope.cn/api/v1")!
		self.cacheRoot = cacheRoot ?? {
			let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
			return urls.first?.appendingPathComponent("ocoreai/modelscope")
				?? URL(fileURLWithPath: "/tmp/ocoreai-modelscope-cache")
		}()
		try? FileManager.default.createDirectory(
			at: self.cacheRoot, withIntermediateDirectories: true,
		)
	}

	// MARK: - Downloader Conformance

	func download(
		id: String,
		revision: String? = nil,
		matching patterns: [String] = ["*.safetensors", "*.json", "*.jinja"],
		useLatest: Bool = false,
		progressHandler: @Sendable @escaping (Progress) -> Void = { _ in },
	) async throws -> URL {
		let rev = revision ?? "main"
		let cacheDir = cacheRoot
			.appendingPathComponent(id)
			.appendingPathComponent(rev)

		if !useLatest, let existingFiles = try? listLocalFiles(in: cacheDir),
		   firstMissingPattern(patterns, in: existingFiles) == nil
		{
			return cacheDir
		}

		let fileInfo = try await listRepoFiles(repoId: id, revision: rev)

		let matchingFiles = fileInfo.filter { info in
			patterns.contains { matchesGlob(info.path, $0) }
		}

		guard !matchingFiles.isEmpty else {
			throw DownloaderError.noFilesMatching(repoId: id, patterns: patterns)
		}

		let existingFilenames: Set<String> = Set((try? listLocalFiles(in: cacheDir)) ?? [])

		try await downloadFiles(
			matchingFiles,
			to: cacheDir,
			repoId: id,
			revision: rev,
			existingFilenames: existingFilenames,
			progressHandler: progressHandler,
		)

		return cacheDir
	}

	// MARK: - ModelScope API

	private struct FileInfo: Decodable {
		let path: String
		let size: Int64?
		let type: String // "file" or "dir"
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
	/// Uses `/api/v1/models/{id}/repo/files?Recursive=true` — same as Python SDK's
	/// `HubApi.get_model_files()`.
	///
	/// Response: Data.Files[].Path / .Size / .Type
	private func listRepoFiles(repoId: String, revision: String) async throws -> [FileInfo] {
		var components = URLComponents(url: baseAPI, resolvingAgainstBaseURL: false)!
		components.path = (components.path as NSString).appendingPathComponent("models") + "/" + repoId + "/repo/files"
		components.queryItems = [
			URLQueryItem(name: "Revision", value: revision),
			URLQueryItem(name: "Recursive", value: "true"),
		]
		guard let url = components.url else {
			throw DownloaderError.invalidURL("Cannot construct file list URL for \(repoId)")
		}

		var request = URLRequest(url: url)
		request.allHTTPHeaderFields = createHeaders()
		request.timeoutInterval = 30

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse,
		      (200 ... 299).contains(httpResponse.statusCode)
		else {
			throw DownloaderError.apiError(
				statusCode: (response as? HTTPURLResponse)?.statusCode ?? 400,
				body: String(data: data, encoding: .utf8) ?? "",
			)
		}

		var files: [FileInfo] = []
		if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		   let dataObj = json["Data"] as? [String: Any],
		   let filesArray = dataObj["Files"] as? [[String: Any]] {
			files = filesArray.compactMap { dict in
				guard let path = dict["Path"] as? String else { return nil }
				var size: Int64?
				if let s = dict["Size"] as? Int64 { size = s }
				else if let s = dict["Size"] as? Int { size = Int64(s) }
				let type = dict["Type"] as? String ?? "file"
				return FileInfo(path: path, size: size, type: type)
			}
		} else {
			// Data.Files is null/missing — typically means the repo is gated/private
			// and requires authentication (MODELSCOPE_TOKEN).
			let raw = String(data: data, encoding: .utf8) ?? "<binary>"
			throw DownloaderError.gatedRepository(
				repoId: repoId,
				hint: "Data.Files is null in API response — repo may require MODELSCOPE_TOKEN. Response: \(raw.prefix(300))",
			)
		}

		return files.filter { $0.type == "file" }
	}

	/// Download a single file from ModelScope.
	///
	/// Uses `/api/v1/models/{id}/resolve/{revision}/{path}` which redirects to CDN.
	/// Streams the response into a temp file — never holds the full file in memory.
	private func downloadSingleFile(
		path: String,
		to destURL: URL,
		repoId: String,
		revision: String,
	) async throws {
		var components = URLComponents(url: baseAPI, resolvingAgainstBaseURL: false)!
		components.path = (components.path as NSString).appendingPathComponent("models") + "/" + repoId + "/resolve/" + revision + "/" + path
		guard let url = components.url else {
			throw DownloaderError.invalidURL("Cannot construct download URL for \(path)")
		}

		var request = URLRequest(url: url)
		request.allHTTPHeaderFields = createHeaders()
		request.timeoutInterval = 120

		let parent = destURL.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

		let tempURL = parent.appendingPathComponent(".download-\(UUID().uuidString.prefix(8))")
		do {
			// bytes(for:) returns (AsyncBytes, URLResponse) in Swift 6 —
			// check response first, then stream body.
			let (bytes, response) = try await URLSession.shared.bytes(for: request)

			guard let httpResponse = response as? HTTPURLResponse,
			      (200 ... 299).contains(httpResponse.statusCode)
			else {
				let status = (response as? HTTPURLResponse)?.statusCode ?? 0
				throw DownloaderError.downloadFailed(path: path, statusCode: status)
			}

			// Stream into file — O(1) memory regardless of file size.
			let handle = try FileHandle(forWritingTo: tempURL)
			defer { try? handle.close() }
			for try await byte in bytes {
				try handle.write(contentsOf: [byte])
			}

			if FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false)) {
				try FileManager.default.removeItem(at: destURL)
			}
			try FileManager.default.moveItem(at: tempURL, to: destURL)
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
		progressHandler: @Sendable @escaping (Progress) -> Void,
	) async throws {
		let total = files.count
		var downloaded = 0
		var failedPaths: [String] = []

		for chunk in files.chunked(into: 4) {
			let tasks = chunk.map { fileInfo -> (String, Task<Bool, Error>) in
				let filePath = String(fileInfo.path)
				return (filePath, Task {
					if existingFilenames.contains(filePath) {
						return true
					}
					let dest = cacheDir.appendingPathComponent(filePath)
					try await downloadSingleFile(
						path: filePath,
						to: dest,
						repoId: repoId,
						revision: revision,
					)
					return true
				})
			}

			for (filePath, task) in tasks {
				do {
					_ = try await task.value
					downloaded += 1
					let progress = Progress(totalUnitCount: Int64(total))
					progress.completedUnitCount = Int64(downloaded)
					progressHandler(progress)
				} catch {
					failedPaths.append(filePath)
				}
			}
		}

		if !failedPaths.isEmpty {
			throw DownloaderError.partialDownload(
				failed: failedPaths,
				total: total,
				succeeded: downloaded,
			)
		}
	}

	// MARK: - Helpers

	/// List all file paths recursively under directory.
	private func listLocalFiles(in directory: URL) throws -> [String] {
		guard let enumerator = FileManager.default.enumerator(
			at: directory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else { return [] }
		var results: [String] = []
		for case let url as URL in enumerator {
			results.append(url.path(percentEncoded: false))
		}
		return results
	}

	private func firstMissingPattern(_ patterns: [String], in existingFiles: [String]) -> String? {
		for pattern in patterns {
			let hasMatch = existingFiles.contains { matchesGlob($0, pattern) }
			if !hasMatch {
				return pattern
			}
		}
		return nil
	}

	private func matchesGlob(_ filename: String, _ pattern: String) -> Bool {
		if pattern.hasPrefix("*") {
			let ext = pattern.drop { $0 == "*" }
			return filename.hasSuffix(ext)
		}
		return filename == pattern
	}
}

/// Error types for the downloader.
enum DownloaderError: LocalizedError {
	case noFilesMatching(repoId: String, patterns: [String])
	case gatedRepository(repoId: String, hint: String)
	case apiError(statusCode: Int, body: String)
	case downloadFailed(path: String, statusCode: Int)
	case partialDownload(failed: [String], total: Int, succeeded: Int)
	case parseError
	case invalidURL(String)

	var errorDescription: String? {
		switch self {
		case let .noFilesMatching(repo, patterns):
			"No files in model '\(repo)' matching patterns \(patterns)"
		case let .gatedRepository(repo, hint):
			"ModelScope repository '\(repo)' is gated/private — \(hint)"
		case let .apiError(code, body):
			"ModelScope API error (\(code)): \(body)"
		case let .downloadFailed(path, code):
			"Download failed for '\(path)' (HTTP \(code))"
		case let .partialDownload(failed, total, succeeded):
			"Partial download: \(total) files total, \(succeeded) succeeded, \(failed.count) failed: \(failed.prefix(3).joined(separator: ", "))"
		case .parseError:
			"Failed to parse ModelScope API response"
		case let .invalidURL(msg):
			"Invalid URL: \(msg)"
		}
	}
}

extension Array {
	func chunked(into size: Int) -> [[Element]] {
		stride(from: 0, to: count, by: size).map {
			Array(self[$0 ..< Swift.min($0 + size, count)])
		}
	}
}

#endif // mlx
