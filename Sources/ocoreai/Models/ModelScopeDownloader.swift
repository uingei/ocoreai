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
// - Retry: exponential backoff with jitter on transient network errors
// - Stall detection: aborts if no bytes received within stall timeout
// - Endpoint: configurable via MODELSCOPE_ENDPOINT env var (mirror/proxy support)
//
// All API paths, parameters, and response structures are derived from the
// ModelScope Python SDK (modelscope v1.x) — this is an SDK-alignment port.

#if mlx

	import Foundation
	import MLXLMCommon

	/// Retryable HTTP error codes — these are transient and worth retrying.
	/// 408/429/5xx are retryable; 400/401/403/404 are NOT.
	nonisolated func isRetryable(statusCode: Int) -> Bool {
		switch statusCode {
		case 408, 429, 502, 503, 504: return true
		default: return (500 ..< 600).contains(statusCode)
		}
	}

	/// Standard exponential backoff with full jitter.
	/// Max 3 retries → delays: ~1s, ~2s, ~4s (with jitter).
	nonisolated func retryDelay(attempt: Int, maxDelay: TimeInterval = 10.0) -> TimeInterval {
		let base: TimeInterval = min(Double(1 << attempt) * 2, maxDelay)
		let jitter = Double.random(in: 0 ... 1)
		return base * (0.5 + jitter * 0.5)  // 50%-100% of base
	}

/// ModelScope Hub API client conforming to mlx-swift-lm ``Downloader`` protocol.
actor ModelScopeDownloader: Downloader {
	// MARK: - Configuration

	private let token: String?
	/// ModelScope API base — configurable via MODELSCOPE_ENDPOINT env var
	/// or passed via init. Falls back to `https://www.modelscope.cn/api/v1`.
	private let baseAPI: URL
	private let cacheRoot: URL

	/// Create a ModelScope Downloader.
	/// - Parameters:
	///   - token: Optional ModelScope access token
	///   - cacheRoot: Cache directory root
	///   - endpoint: Base URL for ModelScope API (without /api/v1 suffix).
	///              Defaults to env MODELSCOPE_ENDPOINT or `https://www.modelscope.cn`.
	init(token: String? = nil,
	     cacheRoot: URL? = nil,
	     endpoint: String? = nil) {
		self.token = token

		// Determine endpoint: explicit param > env var > default
		let resolvedEndpoint: String
		if let e = endpoint, !e.isEmpty {
			resolvedEndpoint = e
		} else {
			resolvedEndpoint = ProcessInfo.processInfo.environment["MODELSCOPE_ENDPOINT"]
				?? "https://www.modelscope.cn"
		}
		// Strip trailing slash for consistent path appending
	self.baseAPI = URL(string: resolvedEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		+ "/api/v1")
			?? URL(fileURLWithPath: "/dev/null")

		self.cacheRoot = cacheRoot ?? {
			let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
			return urls.first?.appendingPathComponent("ocoreai/modelscope")
				?? URL(fileURLWithPath: "/tmp/ocoreai-modelscope-cache")
		}()
		try? FileManager.default.createDirectory(
			at: self.cacheRoot, withIntermediateDirectories: true,
		)

		// Log if using non-default endpoint
		let endpoint = resolvedEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		if endpoint != "https://www.modelscope.cn" {
			print("[ModelScopeDownloader] Using custom endpoint: \(endpoint)")
		}
	}

	// MARK: - Downloader Conformance

	func download(
		id: String,
		revision: String? = nil,
		matching patterns: [String] = ["*.safetensors", "*.json", "*.jinja"],
		useLatest: Bool = false,
		progressHandler: @Sendable @escaping (Progress) -> Void = { _ in },
	) async throws -> URL {
	/* ModelScope 默认 revision 是 master，不是 main。
	   实测：Revision=main 返回 Code=200 但 Files=null，
	   导致代码误判为 gated → 退到 HuggingFace。
	   模型详情 API 返回 Revision 字段确认为 "master"。 */
		let rev = revision ?? "master"
		let cacheDir = cacheRoot
			.appendingPathComponent(id)
			.appendingPathComponent(rev)

		if !useLatest, let existingFiles = try? listLocalFiles(in: cacheDir),
		   firstMissingPattern(patterns, in: existingFiles) == nil
		{
			return cacheDir
		}

		let fileInfo = try await withRetry(maxAttempts: 3) {
			try await self.listRepoFiles(repoId: id, revision: rev)
		}

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

	// MARK: - Retry Helper

	/// Execute an async operation with exponential backoff retry on transient HTTP errors.
	/// Max `maxAttempts` attempts total. Jitter prevents thundering herd on CDN.
	@discardableResult
	private func withRetry<R>(
		maxAttempts: Int,
		_ operation: @escaping () async throws -> R
	) async throws -> R {
		var lastError: Error?
		for attempt in 0 ..< maxAttempts {
			do {
				return try await operation()
			} catch {
				// Only retry on transient errors or network failures (no status code available)
				let retryable: Bool = {
					if let dErr = error as? DownloaderError {
						switch dErr {
						case let .apiError(code, _):
							return isRetryable(statusCode: code)
						case let .downloadFailed(_, code):
							return isRetryable(statusCode: code)
						default:
							return false
						}
					}
					// Network errors (NSURLError) — retry
					return true
				}()

				guard retryable else { throw error }

				lastError = error
				if attempt < maxAttempts - 1 {
					let delay = retryDelay(attempt: attempt)
					try await Task.sleep(for: .seconds(delay))
					// Check cancellation during wait
					try Task.checkCancellation()
				}
			}
		}
		throw lastError ?? DownloaderError.apiError(statusCode: -1, body: "Retry exhausted")
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
		guard let components = URLComponents(url: self.baseAPI, resolvingAgainstBaseURL: false) else {
			throw DownloaderError.invalidURL("Cannot construct file list URL")
		}
		var urlComponents = components
		urlComponents.path = (urlComponents.path as NSString).appendingPathComponent("models") + "/" + repoId + "/repo/files"
		urlComponents.queryItems = [
			URLQueryItem(name: "Revision", value: revision),
			URLQueryItem(name: "Recursive", value: "true"),
		]
		guard let url = urlComponents.url else {
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

		// ModelScope returns "blob" for regular files (not "file")
		return files.filter { $0.type == "blob" || $0.type == "file" }
	}

	/// Download a single file from ModelScope.
	///
	/// Uses `/api/v1/models/{id}/resolve/{revision}/{path}` which redirects to CDN.
	/// Streams the response into a temp file — never holds the full file in memory.
	/// Supports task cancellation — caller can cancel and the download cleans up partial files.
	///
	/// **Stall detection**: aborts if no bytes received within `stallTimeout`.
	/// **Retry**: transient network errors are retried with exponential backoff (up to 3 attempts).
	private func downloadSingleFile(
		path: String,
		to destURL: URL,
		repoId: String,
		revision: String,
	) async throws {

		/// Download a single attempt (no retry). Cleans up on failure.
		func attemptDownload() async throws {
			guard let components = URLComponents(url: self.baseAPI, resolvingAgainstBaseURL: false) else {
				throw DownloaderError.invalidURL("Cannot construct download URL")
			}
			var urlComponents = components
			urlComponents.path = (urlComponents.path as NSString).appendingPathComponent("models") + "/" + repoId + "/resolve/" + revision + "/" + path
			guard let url = urlComponents.url else {
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

				// FileHandle(forWritingTo:) requires the file to already exist
				// (Swift 6 API change — does not create the file implicitly).
				try FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)

				// Stream into file — O(1) memory regardless of file size.
				let handle = try FileHandle(forWritingTo: tempURL)
				defer { try? handle.close() }

				// Stall detection: track last byte-arrival time
				// 300s stall timeout (matches omlx convention)
				let stallTimeout: TimeInterval = 300
				var lastActivity = ContinuousClock.now
				var byteCount = 0

				for try await byte in bytes {
					// Stall check every 128 bytes (~128 B)
					byteCount &+= 1
					if byteCount.isMultiple(of: 128) {
						try Task.checkCancellation()
						let elapsed = lastActivity.duration(to: ContinuousClock.now)
						if elapsed > .seconds(stallTimeout) {
							throw DownloaderError.downloadStalled(
								path: path,
								timeout: Int(stallTimeout),
							)
						}
					}
					lastActivity = ContinuousClock.now
					try handle.write(contentsOf: [byte])
				}

				// Verify stall didn't happen at the tail
				let finalElapsed = lastActivity.duration(to: ContinuousClock.now)
				if finalElapsed > .seconds(stallTimeout) {
					throw DownloaderError.downloadStalled(
						path: path,
						timeout: Int(stallTimeout),
					)
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

		try await withRetry(maxAttempts: 3) {
			try await attemptDownload()
		}
	}

	/// Download files in parallel batches of 4.
	///
	/// On partial failure: keeps pre-existing files, removes only new downloads
	/// from this session so the user can retry without starting from zero.
	/// On cancellation: skips cleanup — user can retry without re-downloading good files.
	///
	/// After download: verifies every file's size matches the remote manifest.
	/// Files with size mismatch are treated as corrupted and removed.
	private func downloadFiles(
		_ files: [FileInfo],
		to cacheDir: URL,
		repoId: String,
		revision: String,
		existingFilenames: Set<String>,
		progressHandler: @Sendable @escaping (Progress) -> Void,
	) async throws {
		let totalBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
		let total = files.count
		var downloadedBytes: Int64 = 0
		var downloadedCount = 0
		var failedPaths: [String] = []
		/// Paths that were actually downloaded (not pre-existing) in this session.
		/// Used for targeted cleanup on partial failure — avoids deleting files
		/// that existed before this download attempt.
		var newlyDownloaded: Set<String> = []

		// Overall stall detection for the entire batch
		let stallTimeout: TimeInterval = 600  // 10 min for full batch
		var lastProgress = ContinuousClock.now

		for chunk in files.chunked(into: 4) {
			// Task.isCancelled checkpoint — allow user cancellation to take effect
			if Task.isCancelled { throw CancellationError() }

			// Batch-level stall check
			if lastProgress.duration(to: ContinuousClock.now) > .seconds(stallTimeout) {
				throw DownloaderError.downloadBatchStalled(
					timeout: Int(stallTimeout),
					downloadedFiles: downloadedCount,
					totalFiles: total,
				)
			}

			let tasks = chunk.map { fileInfo -> (String, Task<(FileInfo, Bool), Error>) in
				let filePath = String(fileInfo.path)
				return (filePath, Task {
					if existingFilenames.contains(filePath) {
						return (fileInfo, true)
					}
					let dest = cacheDir.appendingPathComponent(filePath)
					try await downloadSingleFile(
						path: filePath,
						to: dest,
						repoId: repoId,
						revision: revision,
					)
					return (fileInfo, true)
				})
			}

			for (filePath, task) in tasks {
				do {
					let (info, _) = try await task.value
					newlyDownloaded.insert(filePath)
					downloadedCount += 1
					let fileBytes = info.size ?? 0
					downloadedBytes += fileBytes
					// Byte-level progress — smooth ETA and percentage
					let progress = Progress(totalUnitCount: max(totalBytes, 1))
					progress.completedUnitCount = Int64(downloadedBytes)
					progressHandler(progress)
					lastProgress = ContinuousClock.now
				} catch {
					failedPaths.append(filePath)
				}
			}
		}

		if !failedPaths.isEmpty {
			/// Clean up only the files we downloaded in this session.
			/// Pre-existing files are kept (user may want to retry).
			for path in newlyDownloaded {
				try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(path))
			}
			throw DownloaderError.partialDownload(
				failed: failedPaths,
				total: total,
				succeeded: downloadedCount,
			)
		}

		/// Post-download integrity check: verify local files match remote manifest sizes.
		/// Corrupted/incomplete files are removed so the next download attempt is clean.
		let corrupted = verifyDownloadedFiles(files, cacheDir: cacheDir)
		if !corrupted.isEmpty {
			// Remove only the corrupted files — next download attempt re-downloads them.
			for path in corrupted {
				try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(path))
			}
			throw DownloaderError.corruptedDownload(
				files: corrupted,
				reason: "Local file size does not match remote manifest",
			)
		}
	}

	/// Verify that locally downloaded files match their remote manifest sizes.
	/// Returns the list of corrupted file paths (empty if all OK).
	private func verifyDownloadedFiles(
		_ files: [FileInfo],
		cacheDir: URL,
	) -> [String] {
		var corrupted: [String] = []

		for fileInfo in files {
			let localPath = cacheDir.appendingPathComponent(fileInfo.path)
			guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false))
			else {
				corrupted.append(fileInfo.path)
				continue
			}

			// If remote manifest has a size, verify local file matches
			guard let expectedSize = fileInfo.size, expectedSize > 0 else { continue }

			do {
				let attrs = try FileManager.default.attributesOfItem(atPath: localPath.path(percentEncoded: false))
				let localSize = attrs[.size] as? Int64 ?? 0

				// Tolerance: allow up to 1 byte difference (edge case for streaming)
				if abs(localSize - expectedSize) > 1 {
					corrupted.append(fileInfo.path)
				}
			} catch {
				// If we can't stat the file, treat it as corrupted
				corrupted.append(fileInfo.path)
			}
		}

		return corrupted
	}

	// MARK: - Helpers

	/// List all file paths recursively under directory.
	/// Returns RELATIVE paths (relative to `directory`) so they match the
	/// FileInfo.path strings from the ModelScope API.
	private func listLocalFiles(in directory: URL) throws -> [String] {
		guard let enumerator = FileManager.default.enumerator(
			at: directory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else { return [] }
		var results: [String] = []
		let base = directory.path(percentEncoded: false)
		for case let url as URL in enumerator {
			let full = url.path(percentEncoded: false)
			if full.hasPrefix(base + "/") {
				let relative = String(full.dropFirst(base.count + 1))
				results.append(relative)
			}
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
	case downloadStalled(path: String, timeout: Int)
	case downloadBatchStalled(timeout: Int, downloadedFiles: Int, totalFiles: Int)
	case partialDownload(failed: [String], total: Int, succeeded: Int)
	case corruptedDownload(files: [String], reason: String)
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
		case let .downloadStalled(path, timeout):
			"Download stalled for '\(path)' — no data received for \(timeout)s"
		case let .downloadBatchStalled(timeout, downloaded, total):
			"Download batch stalled — no progress for \(timeout)s (\(downloaded)/\(total) files)"
		case let .partialDownload(failed, total, succeeded):
			"Partial download: \(total) files total, \(succeeded) succeeded, \(failed.count) failed: \(failed.prefix(3).joined(separator: ", "))"
		case let .corruptedDownload(files, reason):
			"Corrupted download (\(files.count) file(s)): \(reason). \(files.prefix(5).joined(separator: ", "))"
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
