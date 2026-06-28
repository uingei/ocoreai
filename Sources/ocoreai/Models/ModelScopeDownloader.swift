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
	actor ModelScopeDownloader: Downloader {
		// MARK: - Configuration

		private let token: String?
		private let baseAPI: URL
		private let cacheRoot: URL
		private let fileCountLimit: Int = 200 // Cap file-list pagination

		/// Create a ModelScope Downloader.
		///
		/// - Parameters:
		///   - token: Optional ModelScope API token (for private repos). Usually not needed.
		///   - cacheRoot: Override cache directory (default: `~/.cache/ocoreai/modelscope/`)
		init(token: String? = nil, cacheRoot: URL? = nil) {
			self.token = token
			baseAPI = URL(string: "https://www.modelscope.cn/api/v1")! // compile-time constant — always valid
			self.cacheRoot = cacheRoot ?? {
				let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
				return urls.first?.appendingPathComponent("ocoreai/modelscope")
					?? URL(fileURLWithPath: "/tmp/ocoreai-modelscope-cache")
			}()
			// Create cache root if it doesn't exist
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
			// 1. Compute local cache directory
			let cacheDir = cacheRoot
				.appendingPathComponent(id)
				.appendingPathComponent(revision ?? "main")

			// 2. Check cache — if files matching all patterns exist and !useLatest, return early
			if !useLatest, let existingFiles = try? listLocalFiles(in: cacheDir),
			   let _ = firstMissingPattern(patterns, in: existingFiles)
			{
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
			let fileInfo = try await listRepoFiles(repoId: id, revision: revision ?? "main")

			// 4. Filter files matching patterns
			let matchingFiles = fileInfo.filter { fileInfo in
				patterns.contains { matchesGlob(fileInfo.path, $0) }
			}

			guard !matchingFiles.isEmpty else {
				throw DownloaderError.noFilesMatching(repoId: id, patterns: patterns)
			}

			// 5. Determine which files already exist in cache (skip re-download)
			let existingFilenames: Set<String> = Set((try? listLocalFiles(in: cacheDir)) ?? [])

			// 6. Download missing files in parallel groups
			try await downloadFiles(
				matchingFiles,
				to: cacheDir,
				repoId: id,
				revision: revision ?? "main",
				existingFilenames: existingFilenames,
				progressHandler: progressHandler,
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
		/// Uses `/api/v1/models/{owner}/{name}` detail endpoint which includes
		/// `ModelInfos.files` array with file metadata. This replaced `/repos/.../tree`
		/// which was deprecated (421 Misdirected Request).
		private func listRepoFiles(repoId: String, revision _: String) async throws -> [FileInfo] {
			let endpoint = baseAPI
				.appendingPathComponent("/models")
				.appendingPathComponent(repoId)

			var request = URLRequest(url: endpoint)
			request.allHTTPHeaderFields = createHeaders()

			let (data, response) = try await URLSession.shared.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse,
			      (200 ... 299).contains(httpResponse.statusCode)
			else {
				throw DownloaderError.apiError(
					statusCode: (response as? HTTPURLResponse)?.statusCode ?? 400,
					body: String(data: data, encoding: .utf8) ?? "",
				)
			}

			// Parse ModelScope v2 API response.
			// Structure: Data.ModelInfos.safetensor.files[].name / .size / .sha256
			var files: [FileInfo] = []
			if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			   let dataObj = json["Data"] as? [String: Any],
			   let modelInfos = dataObj["ModelInfos"] as? [String: Any],
			   let safetensor = modelInfos["safetensor"] as? [String: Any],
			   let filesArray = safetensor["files"] as? [[String: Any]] {
				files = filesArray.compactMap { dict in
					guard let name = dict["name"] as? String else { return nil }
					let size = dict["size"] as? Int64
					return FileInfo(path: name, size: size, type: "file")
				}
			}
		
			// ModelScope detail API only returns safetensor weights, not tokenizer/config files.
			// Probe resolve endpoint for essential tokenizer files — if they exist, add them.
			// MLX requires tokenizer.json for AutoTokenizer.from(modelFolder:)
			let tokenizerCandidates: [String] = [
				"tokenizer.json",
				"tokenizer_config.json",
				"vocab.json",
				"merges.txt",
				"tokenizer.model",
				"special_tokens_map.json",
			]
			let existingPaths = Set(files.map(\.path))
		
			for candidate in tokenizerCandidates {
				if !existingPaths.contains(candidate) {
					if await resolveExists(path: candidate, repoId: repoId) {
						files.append(FileInfo(path: candidate, size: nil, type: "file"))
					}
				}
			}
		
			return files
			}

			/// Probe whether a file exists via the resolve endpoint (HEAD-like GET with status check).
			private func resolveExists(path: String, repoId: String) async -> Bool {
				let endpoint = baseAPI
					.appendingPathComponent("/models")
					.appendingPathComponent(repoId)
					.appendingPathComponent("resolve")
					.appendingPathComponent("main")
					.appendingPathComponent(path)

				do {
					var request = URLRequest(url: endpoint)
					request.allHTTPHeaderFields = createHeaders()
					request.timeoutInterval = 5
					let (_, response) = try await URLSession.shared.data(for: request)
					let status = (response as? HTTPURLResponse)?.statusCode ?? 0
					return status == 200 || status == 302
				} catch {
					return false
				}
			}

		/// Download a single file from ModelScope.
		///
		/// Uses `/api/v1/models/{id}/resolve/{revision}/{path}` which redirects to actual CDN.
		/// Replaced `/repos/.../resolve/...` which returned 421 Misdirected Request.
		private func downloadSingleFile(
			path: String,
			to destURL: URL,
			repoId: String,
			revision: String,
			progressHandler _: (@Sendable (Int, Int) -> Void)? = nil, // (bytes, total)
		) async throws {
			let endpoint = baseAPI
				.appendingPathComponent("/models")
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
				let (tempDownloadURL, response) = try await URLSession.shared.download(from: endpoint)

				guard let httpResponse = response as? HTTPURLResponse,
				      (200 ... 299).contains(httpResponse.statusCode)
				else {
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
			progressHandler: @Sendable @escaping (Progress) -> Void,
		) async throws {
			let total = files.count
			var downloaded = 0

			for chunk in files.chunked(into: 4) {
				let tasks = chunk.map { fileInfo -> (String, Task<Bool, Error>) in
					let filePath = String(fileInfo.path)
					return (filePath, Task {
						// Skip if already cached
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
						// Log but continue — other files may still download
						downloadFailedPath = filePath
					}
				}
			}
		}

		// MARK: - Helpers

		private func listLocalFiles(in directory: URL) throws -> [String] {
			let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			return contents.map(\.lastPathComponent)
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
		case invalidURL(String)

		var errorDescription: String? {
			switch self {
			case let .noFilesMatching(repo, patterns):
				"No files in model '\(repo)' matching patterns \(patterns)"
			case let .apiError(code, body):
				"ModelScope API error (\(code)): \(body)"
			case let .downloadFailed(path, code):
				"Download failed for '\(path)' (HTTP \(code))"
			case .parseError:
				"Failed to parse ModelScope API response"
			case let .invalidURL(url):
				"Invalid URL: \(url)"
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
