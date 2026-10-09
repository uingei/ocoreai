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
// - Cache path: `~/.ocoreai/models/{owner}/{model}/`(omlx 平铺,无 /{revision} 三级 —
//   omlx/admin/ms_downloader.py: "Preserve {owner}/{model} layout to match other tools")
// - Download: lists file tree via ModelScope API, filters by glob patterns,
//   then downloads files in parallel with progress tracking
// - Retry: exponential backoff with jitter on transient network errors
// - Stall detection: aborts if no bytes received within stall timeout
// - Endpoint: configurable via MODELSCOPE_ENDPOINT env var (mirror/proxy support)
//
// All API paths, parameters, and response structures are derived from the
// ModelScope Python SDK (modelscope v1.x) — this is an SDK-alignment port.

import Foundation
import Logging
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
/// Max 3 retries → delays: ~1s (attempt 0), ~2s (attempt 1), ~4s (attempt 2).
nonisolated func retryDelay(attempt: Int, maxDelay: TimeInterval = 10.0) -> TimeInterval {
    let base: TimeInterval = min(Double(1 << (attempt + 1)), maxDelay)
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
    init(
        token: String? = nil,
        cacheRoot: URL? = nil,
        endpoint: String? = nil
    ) {
        self.token = token

        // Determine endpoint: explicit param > env var > default
        let resolvedEndpoint: String
        if let e = endpoint, !e.isEmpty {
            resolvedEndpoint = e
        } else {
            resolvedEndpoint =
                ProcessInfo.processInfo.environment["MODELSCOPE_ENDPOINT"]
                ?? ModelStore.modelScopeDefaultBaseURL
        }
        // Strip trailing slash for consistent path appending
        self.baseAPI =
            URL(
                string: resolvedEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    + "/api/v1")
            ?? URL(fileURLWithPath: "/dev/null")

        self.cacheRoot =
            cacheRoot
            ?? {
                // 就绪模型目录(omlx 对齐:下载即落进统一登记簿)。
                // 事实源:ModelStore.root——$OCOREAI_MODELS_DIR > ~/.ocoreai/models
                // (omlx `~/.omlx/models` 同构)。写入布局:`<root>/<ns>/<name>/`
                // 平铺,无 /{revision} 三级(omlx 对齐)。
                ModelStore.ensureLayout()
                return ModelStore.root
            }()
        try? FileManager.default.createDirectory(
            at: self.cacheRoot, withIntermediateDirectories: true,
        )

        // Log if using non-default endpoint
        let endpoint = resolvedEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if endpoint != ModelStore.modelScopeDefaultBaseURL {
            Logger(label: "ModelScopeDownloader").info("Using custom endpoint: \(endpoint)")
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
        // omlx 平铺布局:`cacheRoot/<ns>/<name>/`(revision 不落盘,
        // 对齐 omlx ms_downloader.py target_dir = model_dir / task.repo_id)
        let cacheDir = cacheRoot.appendingPathComponent(id)

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

        // LoRA/Adapter detection — block download if adapter indicators present
        if hasAdapterIndicators(fileInfo) {
            throw DownloaderError.adapterDetected(repoId: id)
        }

        let existingFilenames: Set<String> = Set((try? listLocalFiles(in: cacheDir)) ?? [])

        // Reclaim orphaned temps BEFORE sizing the hole (roadmap line 6):
        // yesterday's crashed downloads free space today's download needs;
        // age gate keeps anything still resumable (< 24h).
        purgeStaleTempFiles(in: cacheRoot)

        // Pre-flight disk guard (roadmap line 6): ModelScope sizes are
        // already in hand from listRepoFiles — block BEFORE bytes flow when
        // the volume can't hold the remainder (minus what's cached). Sizes
        // missing across matched files → allow (existing guards own it).
        let measured =
            matchingFiles.allSatisfy { $0.size != nil }
            ? matchingFiles.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            : nil
        let alreadyCached =
            matchingFiles
            .filter { existingFilenames.contains(String($0.path)) }
            .reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let required = DiskSpaceGuard.requiredBytes(
            remoteTotal: measured, cachedBytes: alreadyCached)
        let free = DiskSpaceGuard.freeBytes(onVolumeHosting: cacheDir)
        guard DiskSpaceGuard.decision(freeBytes: free, requiredBytes: required) else {
            throw DownloaderError.insufficientDiskSpace(
                repoId: id, requiredBytes: required ?? 0, freeBytes: free ?? 0)
        }

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
                // Cancellation is USER intent — never retryable, never a
                // "network error". Without this gate a Stop click sits out
                // the full retryDelay before checkCancellation fires.
                if error is CancellationError { throw error }
                // Only retry on transient errors or network failures (no status code available)
                let retryable: Bool = {
                    if let dErr = error as? DownloaderError {
                        switch dErr {
                        case .apiError(let code, _):
                            return isRetryable(statusCode: code)
                        case .downloadFailed(_, let code):
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

    struct FileInfo: Decodable {
        let path: String
        let size: Int64?
        let type: String  // "file" or "dir"
    }

    /// Adapter detection helper — checks file tree for LoRA/adapter indicators.
    internal func hasAdapterIndicators(_ info: [FileInfo]) -> Bool {
        for file in info {
            let lower = file.path.lowercased()
            if lower.contains("lora") || lower.contains("adapter") {
                return true
            }
            if lower == "adapter_config.json" {
                return true
            }
        }
        return false
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
        guard let components = URLComponents(url: self.baseAPI, resolvingAgainstBaseURL: false)
        else {
            throw DownloaderError.invalidURL("Cannot construct file list URL")
        }
        var urlComponents = components
        urlComponents.path =
            (urlComponents.path as NSString).appendingPathComponent("models") + "/" + repoId
            + "/repo/files"
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
            let filesArray = dataObj["Files"] as? [[String: Any]]
        {
            files = filesArray.compactMap { dict in
                guard let path = dict["Path"] as? String else { return nil }
                var size: Int64?
                if let s = dict["Size"] as? Int64 {
                    size = s
                } else if let s = dict["Size"] as? Int {
                    size = Int64(s)
                }
                let type = dict["Type"] as? String ?? "file"
                return FileInfo(path: path, size: size, type: type)
            }
        } else {
            // Data.Files is null/missing — typically means the repo is gated/private
            // and requires authentication (MODELSCOPE_TOKEN).
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw DownloaderError.gatedRepository(
                repoId: repoId,
                hint:
                    "Data.Files is null in API response — repo may require MODELSCOPE_TOKEN. Response: \(raw.prefix(300))",
            )
        }

        // ModelScope returns "blob" for regular files (not "file")
        return files.filter { $0.type == "blob" || $0.type == "file" }
    }

    /// Download a single file from ModelScope.
    ///
    /// Uses `/api/v1/models/{id}/resolve/{revision}/{path}` which redirects to CDN.
    /// Streams the response into a temp file — never holds the full file in memory.
    ///
    /// **Resume**: deterministic temp + HTTP Range/If-Range continuation —
    /// transient failures keep partial bytes, the next attempt (or process
    /// restart) resumes where it stopped. Identity verified via revision +
    /// ETag/Last-Modified; any doubt restarts fresh (never splices versions).
    /// **Cancellation**: explicit cancel discards partial bytes (user intent:
    /// start over).
    ///
    /// **Stall detection**: aborts if no bytes received within `stallTimeout`.
    /// **Retry**: transient network errors are retried with exponential backoff (up to 3 attempts).
    // MARK: - Resume support (line 2: interrupted downloads survive)
    //
    // First-principles gap this closes: a 40 GB download that drops at 99%
    // used to delete its temp file and restart from zero — the network paid
    // twice and the user waited twice. Now: deterministic temp names (a new
    // process finds yesterday's bytes), partial temp kept across transient
    // failures and cancellations, and HTTP Range continuation with If-Range
    // identity checks so resumed bytes can never silently splice versions.

    /// Deterministic temp path for a repo file — resume across attempts and
    /// process restarts. `.download-` prefix keeps it inside the sweep.
    static func resumeTempURL(for path: String, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent(
            ".download-\(path.replacingOccurrences(of: "/", with: "__"))")
    }

    static func resumeMetaURL(for path: String, in cacheDir: URL) -> URL {
        resumeTempURL(for: path, in: cacheDir).appendingPathExtension("meta")
    }
    /// Sidecar for an already-computed temp URL (sweep path — no re-hash).
    static func resumeMetaURL(alongside tempURL: URL) -> URL {
        tempURL.appendingPathExtension("meta")
    }

    /// Total resumable bytes under `dir`: `.download-*` temps that carry a
    /// `.meta` sidecar (identity known → resume will fire). Temps WITHOUT a
    /// sidecar are invisible here — byte-counting them would promise a
    /// resume the If-Range gate can't honestly make. FS query; call off the
    /// view body (`.task`), the tree is shallow (one repo dir).
    static func resumableBytes(in dir: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let en = fm.enumerator(
                at: dir, includingPropertiesForKeys: [.fileSizeKey],
                errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix(".download-"), !name.hasSuffix(".meta") else { continue }
            guard fm.fileExists(atPath: resumeMetaURL(alongside: url).path) else { continue }
            let size =
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    struct ResumeMeta: Codable, Equatable {
        var revision: String
        var etag: String?
        var lastModified: String?
    }

    /// Can these bytes be resumed? Every unknown/discordant state fails
    /// closed to a fresh download (never splice on doubt):
    /// revision changed, temp larger than manifest size, no temp bytes.
    static func shouldResume(
        tempBytes: Int64,
        expectedSize: Int64?,
        meta: ResumeMeta?,
        currentRevision: String
    ) -> Bool {
        guard tempBytes > 0 else { return false }
        guard let meta, meta.revision == currentRevision else { return false }
        if let expected = expectedSize, tempBytes >= expected { return false }
        return true
    }

    /// A temp at exactly the manifest size with a matching revision is a
    /// COMPLETE file the previous process died before promoting — ship it
    /// without touching the network (the codebase's integrity bar is
    /// manifest-size verification, same as verifyDownloadedFiles applies to
    /// promoted files).
    static func shouldPromoteComplete(
        tempBytes: Int64,
        expectedSize: Int64?,
        meta: ResumeMeta?,
        currentRevision: String
    ) -> Bool {
        guard let expected = expectedSize, tempBytes >= expected else { return false }
        guard let meta, meta.revision == currentRevision else { return false }
        return true
    }

    /// Stream disposition after the response arrives. Range continuation only
    /// on 206 (server honored Range + If-Range); 200 → start fresh (truncate);
    /// 416 with temp already at expected size → the file is COMPLETE server-
    /// side (race: another session finished it) — promote, do not fail;
    /// anything else → failure with its status code.
    enum ResumeDisposition: Equatable {
        case resume
        case fresh
        case complete
        case failed(statusCode: Int)
    }

    /// Temp-retention policy on attempt exit. KEEP on every error —
    /// cancellation included: user intent is "pause", and bytes under an
    /// If-Range/Content-Range guard are a valid resume prefix. Cleanup
    /// authority is the age-gated launch sweep, never the cancel path.
    static func keepTempOnError(_ error: Error) -> Bool {
        true
    }

    static func resumeDisposition(statusCode: Int, tempBytes: Int64, expectedSize: Int64?)
        -> ResumeDisposition
    {
        if statusCode == 206 { return .resume }
        if (200 ... 299).contains(statusCode) { return .fresh }
        if statusCode == 416, let expected = expectedSize, tempBytes >= expected {
            return .complete
        }
        return .failed(statusCode: statusCode)
    }

    /// Parse the start of a `Content-Range` header ("bytes 50-99/659" → 50).
    static func contentRangeStart(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let parts = header.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let pair = parts[1].split(separator: "/").first ?? ""
        let start = pair.split(separator: "-").first ?? ""
        return Int64(start)
    }

    /// Range-aware disposition. ModelScope's CDN answers a honored
    /// `Range: bytes=offset-` with **200 + Content-Range** (not 206) —
    /// status-only logic would truncate a resumable temp and re-download
    /// every byte (resume never works there, proven live 2026-10-09).
    /// A partial-with-200 resumes ONLY when the range starts exactly at
    /// our offset — that byte math is the integrity proof; a missing or
    /// mismatched header means full body: honest truncate-and-restart.
    static func resumeDisposition(
        statusCode: Int,
        contentRange: String?,
        tempBytes: Int64,
        expectedSize: Int64?,
        requestedOffset: Int64
    ) -> ResumeDisposition {
        if statusCode == 206 { return .resume }
        if statusCode == 416, let expected = expectedSize, tempBytes >= expected {
            return .complete
        }
        if (200 ... 299).contains(statusCode) {
            if requestedOffset > 0,
                let start = contentRangeStart(contentRange),
                start == requestedOffset
            {
                return .resume
            }
            return .fresh
        }
        return .failed(statusCode: statusCode)
    }

    /// Age-gated orphan sweep decision: keep resumable temp files, delete
    /// only stale ones (network drops resume; the user's machine stays
    /// clean overnight).
    static func shouldPurgeTemp(age: TimeInterval, staleAfter: TimeInterval = 24 * 3600) -> Bool {
        age > staleAfter
    }

    /// Current byte size of the temp file (0 if absent).
    private func currentTempBytes(_ tempURL: URL) -> Int64 {
        guard
            let attrs = try? FileManager.default.attributesOfItem(
                atPath: tempURL.path(percentEncoded: false))
        else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static let resumeMetaEncoder = JSONEncoder()
    private static let resumeMetaDecoder = JSONDecoder()

    private func loadResumeMeta(at url: URL) -> ResumeMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.resumeMetaDecoder.decode(ResumeMeta.self, from: data)
    }

    private func saveResumeMeta(_ meta: ResumeMeta, at url: URL) {
        guard let data = try? Self.resumeMetaEncoder.encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Remove orphaned `.download-*` temp files older than the stale window
    /// (and their `.meta` sidecars). Fresh temps are RESUMABLE state — the
    /// whole point of keeping them — so only age decides.
    func purgeStaleTempFiles(in directory: URL, staleAfter: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        // NOTE: no .skipsHiddenFiles — every temp we hunt starts with '.'
        // (macOS hides them), and skipping hidden made this sweep a no-op.
        // Safety comes from the name-prefix gate below, never from the flag.
        guard
            let enumerator = fm.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let now = Date()
        var tempURLsToRemove: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix(".download-") || name.hasPrefix(".____temp") else { continue }
            let age: TimeInterval =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate.map { now.timeIntervalSince($0) } ?? 0
            guard Self.shouldPurgeTemp(age: age, staleAfter: staleAfter) else { continue }
            tempURLsToRemove.append(url)
            // identity sidecar follows its temp (string concat on the path,
            // never URL(string:) which nils on incidental characters)
            tempURLsToRemove.append(Self.resumeMetaURL(alongside: url))
        }
        for url in tempURLsToRemove {
            try? fm.removeItem(at: url)
        }
        pruneEmptyDirectories(directory)
    }

    /// Thread-safe byte funnel for one download batch (parallel tasks,
    /// per-file absolute cumulative → one monotone batch bar).
    ///
    /// Each file reports its OWN cumulative temp bytes (flushes ~1MB);
    /// the batch total is the sum of per-file contributions. Per-file max
    /// keeps the bar monotone across retries whose Range was ignored (temp
    /// truncated, report restarts lower — we hold the high-water mark until
    /// the real bytes pass it; completion report = manifest size, exact).
    /// Every accepted flush updates `lastProgressAt` — the batch heartbeat.
    internal final class BatchBytes: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int64
        private let onProgress: @Sendable (Int64, Int64) -> Void
        private var perFile: [String: Int64] = [:]
        private var reportedSnapshot: Int64 = 0
        private(set) var lastProgressAt = ContinuousClock.now

        init(total: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.limit = total
            self.onProgress = onProgress
        }

        /// Report `cumulativeBytes` = bytes on disk for `file` right now
        /// (temp included, absolute not delta — retries compute cleanly).
        func report(file: String, cumulativeBytes: Int64) {
            lock.lock()
            let prev = perFile[file] ?? 0
            guard cumulativeBytes > prev else {
                lock.unlock()
                return  // stale/lowered report (truncated retry): hold mark
            }
            perFile[file] = cumulativeBytes
            settle_locked()
            lock.unlock()
            onProgress(reportedSnapshot, limit)
        }

        /// Authoritative landing at file completion: the REAL size is truth —
        /// overwrite the high-water mark (a temp that over-ran the manifest
        /// must not hold the bar inflated forever) and re-emit exactly.
        func settle(file: String, exactBytes: Int64) {
            lock.lock()
            perFile[file] = exactBytes
            settle_locked()
            lock.unlock()
            onProgress(reportedSnapshot, limit)
        }

        /// Recompute from per-file truths (never delta-on-clamped-total: a
        /// clamped `reported` loses information and deltas drift). Sum is
        /// O(files) — hundreds max, flush cadence ≥1MB — negligible cost,
        /// books always exact. Caller holds lock.
        private func settle_locked() {
            let sum = perFile.values.reduce(Int64(0)) { $0 + $1 }
            reportedSnapshot = min(sum, limit)
            lastProgressAt = ContinuousClock.now
        }
    }

    private func downloadSingleFile(
        path: String,
        to destURL: URL,
        repoId: String,
        revision: String,
        expectedSize: Int64? = nil,
        reportBytes: @escaping @Sendable (Int64) -> Void = { _ in },
    ) async throws {

        /// One attempt: resume from deterministic temp when possible, stream
        /// the remainder, promote on success. Transient failures KEEP temp
        /// (bytes are valid prefixes; If-Range guards identity on resume);
        /// cancellation ALSO KEEPS temp — user intent is "not now", not
        /// "delete 20 GB and start over"; the age-gated launch sweep owns
        /// real cleanup, and byte-level resume (Content-Range verified)
        /// makes the next attempt continue, not restart.
        func attemptDownload() async throws {
            guard let components = URLComponents(url: self.baseAPI, resolvingAgainstBaseURL: false)
            else {
                throw DownloaderError.invalidURL("Cannot construct download URL")
            }
            var urlComponents = components
            urlComponents.path =
                (urlComponents.path as NSString).appendingPathComponent("models") + "/" + repoId
                + "/resolve/" + revision + "/" + path
            guard let url = urlComponents.url else {
                throw DownloaderError.invalidURL("Cannot construct download URL for \(path)")
            }

            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = createHeaders()
            request.timeoutInterval = 120

            let parent = destURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            // Deterministic temp — a later attempt (or a new process) finds
            // these bytes again. UUID temps were the resume-killer.
            let tempURL = Self.resumeTempURL(for: path, in: cacheDirFor(path: path, dest: destURL))
            let metaURL = Self.resumeMetaURL(for: path, in: cacheDirFor(path: path, dest: destURL))
            let fm = FileManager.default

            // Resume offset: temp bytes we already own, gated by identity —
            // revision match + plausible size. Any doubt → offset 0.
            var offset: Int64 = 0
            if let attrs = try? fm.attributesOfItem(atPath: tempURL.path(percentEncoded: false)) {
                let tempBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let meta = loadResumeMeta(at: metaURL)
                if Self.shouldPromoteComplete(
                    tempBytes: tempBytes, expectedSize: expectedSize,
                    meta: meta, currentRevision: revision)
                {
                    // Previous process died AFTER the last byte, BEFORE
                    // promotion. Zero-RTT promote (size == manifest).
                    if fm.fileExists(atPath: destURL.path(percentEncoded: false)) {
                        try fm.removeItem(at: destURL)
                    }
                    try fm.moveItem(at: tempURL, to: destURL)
                    try? fm.removeItem(at: metaURL)
                    return
                }
                if Self.shouldResume(
                    tempBytes: tempBytes, expectedSize: expectedSize,
                    meta: meta, currentRevision: revision)
                {
                    offset = tempBytes
                    request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                    // If-Range: server serves 206 only if our bytes still
                    // match the remote version; otherwise a fresh 200,
                    // which truncates the temp before streaming.
                    if let etag = meta?.etag {
                        request.setValue(etag, forHTTPHeaderField: "If-Range")
                    } else if let lm = meta?.lastModified {
                        request.setValue(lm, forHTTPHeaderField: "If-Range")
                    }
                } else if tempBytes > 0 {
                    // Discordant stale temp — drop it before this attempt.
                    try? fm.removeItem(at: tempURL)
                    try? fm.removeItem(at: metaURL)
                }
            }

            do {
                // bytes(for:) returns (AsyncBytes, URLResponse) in Swift 6 —
                // check response first, then stream body.
                let requestedOffset = offset
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw DownloaderError.downloadFailed(path: path, statusCode: 0)
                }
                let resuming: Bool
                switch Self.resumeDisposition(
                    statusCode: httpResponse.statusCode,
                    contentRange: httpResponse.value(forHTTPHeaderField: "Content-Range"),
                    tempBytes: currentTempBytes(tempURL),
                    expectedSize: expectedSize,
                    requestedOffset: requestedOffset)
                {
                case .resume: resuming = true
                case .fresh: resuming = false
                case .complete:
                    // 416 + temp at manifest size → complete server-side;
                    // promote without streaming.
                    if fm.fileExists(atPath: destURL.path(percentEncoded: false)) {
                        try fm.removeItem(at: destURL)
                    }
                    try fm.moveItem(at: tempURL, to: destURL)
                    try? fm.removeItem(at: metaURL)
                    return
                case .failed(let status):
                    throw DownloaderError.downloadFailed(path: path, statusCode: status)
                }
                if !resuming && offset > 0 {
                    // Server ignored Range (or If-Range mismatch → full body):
                    // our prefix is unverified — truncate and restart.
                    offset = 0
                }

                if offset == 0 {
                    // Fresh download (first byte ever, or fresh 200): create
                    // the temp from scratch. FileHandle(forWritingTo:) needs
                    // the file to exist (Swift 6 API semantics).
                    _ = fm.createFile(
                        atPath: tempURL.path(percentEncoded: false), contents: nil)
                }

                // Stream into file — O(1) memory regardless of file size.
                // Buffered writes: accumulate bytes into a Data buffer, flush at
                // bufferSize (1 MB) to avoid per-byte syscalls. A 10 GB safetensors
                // file with per-byte writes would trigger ~10 billion syscalls.
                let handle = try FileHandle(forWritingTo: tempURL)
                defer { try? handle.close() }
                if offset > 0 { try handle.seekToEndOfFile() }

                // Record identity for the next attempt's If-Range, right after
                // headers arrive (before any byte is appended).
                saveResumeMeta(
                    ResumeMeta(
                        revision: revision,
                        etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                        lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")),
                    at: metaURL)

                // Stall detection: track last byte-arrival time
                // 300s stall timeout (matches omlx convention)
                let stallTimeout: TimeInterval = 300
                var lastActivity = ContinuousClock.now
                var writeBuffer = Data()
                let bufferSize = 1 << 20  // 1 MB flush threshold
                var bufferCount = 0

                for try await byte in bytes {
                    writeBuffer.append(byte)
                    bufferCount &+= 1

                    // Stall check + cancellation every 128 bytes
                    if bufferCount.isMultiple(of: 128) {
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

                    // Flush buffer when full — and surface the byte count
                    // (bar + batch heartbeat ride this ~1MB cadence).
                    if writeBuffer.count >= bufferSize {
                        handle.write(writeBuffer)
                        offset += Int64(writeBuffer.count)
                        writeBuffer = Data()
                        reportBytes(offset)
                    }
                }

                // Write any remaining bytes
                if !writeBuffer.isEmpty {
                    handle.write(writeBuffer)
                    offset += Int64(writeBuffer.count)
                    reportBytes(offset)
                }

                if FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                // Promoted: identity sidecar no longer needed.
                try? FileManager.default.removeItem(at: metaURL)
            } catch {
                // KEEP temp on every exit path — cancellation included.
                // Bytes are a valid prefix under If-Range/Content-Range
                // guard; resume continues from offset next attempt.
                // Cleanup authority: age-gated purgeStaleTempFiles at launch.
                throw error
            }
        }

        try await withRetry(maxAttempts: 3) {
            try await attemptDownload()
        }
    }

    /// Directory holding the temp for a repo file: the cache root, since
    /// temps live beside `destURL`'s parent only within nested repo paths —
    /// determinism demands ONE canonical location per repo file.
    private func cacheDirFor(path: String, dest: URL) -> URL {
        dest.deletingLastPathComponent()
    }

    /// Download files in parallel batches of 4.
    ///
    /// On partial failure: keeps pre-existing files, removes only new downloads
    /// from this session so the user can retry without starting from zero.
    /// On cancellation: cleans up `.download-*` temp files immediately.
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
        var downloadedCount = 0
        var failedPaths: [String] = []
        /// Paths that were actually downloaded (not pre-existing) in this session.
        /// Used for targeted cleanup on partial failure — avoids deleting files
        /// that existed before this download attempt.
        var newlyDownloaded: Set<String> = []

        // Byte funnel: parallel per-file flushes land here (per-file
        // absolute cumulative, temp bytes included). The bar advances on
        // ~1MB flushes instead of file-completion cliffs, resumed bytes
        // count from frame one, and the flush heartbeat retires the old
        // file-completion-only stall pulse — which killed healthy
        // single-file downloads >10 min (batch check only ever beat when
        // a whole file finished).
        let batch = BatchBytes(total: max(totalBytes, 1)) { done, limit in
            let progress = Progress(totalUnitCount: limit)
            progress.completedUnitCount = done
            progressHandler(progress)
        }

        // Overall stall detection: no BYTES (not just no files) for 10 min.
        let stallTimeout: TimeInterval = 600

        // Cancellation: the batch loop throws CancellationError, each
        // downloadSingleFile catch discards its own temp+meta on explicit
        // cancel (one authority — no sweeping cacheDir here, which would
        // delete resumable temps the user just chose to interrupt).
        // Age-gated stale sweep lives at app launch (purgeStaleTempFiles).

        for chunk in files.chunked(into: 4) {
            // Task.isCancelled checkpoint — allow user cancellation to take effect
            if Task.isCancelled { throw CancellationError() }

            // Batch-level stall check
            if batch.lastProgressAt.duration(to: ContinuousClock.now) > .seconds(stallTimeout) {
                throw DownloaderError.downloadBatchStalled(
                    timeout: Int(stallTimeout),
                    downloadedFiles: downloadedCount,
                    totalFiles: total,
                )
            }

            let tasks = chunk.map { fileInfo -> (String, Task<(FileInfo, Bool), Error>) in
                let filePath = fileInfo.path
                return (
                    filePath,
                    Task {
                        // Pre-existing: settle full size instantly (same cliff the
                        // old file-completion accounting had, byte-exact now).
                        if existingFilenames.contains(filePath) {
                            batch.settle(file: filePath, exactBytes: fileInfo.size ?? 0)
                            return (fileInfo, false)
                        }
                        let dest = cacheDir.appendingPathComponent(filePath)
                        // Byte progress (HIG: bar reflects real bytes): per-file
                        // flushes (~1MB) report absolute cumulative — resumed
                        // temp bytes count from the first flush of attempt 2.
                        let reportBytes: @Sendable (Int64) -> Void = { cumulative in
                            batch.report(file: filePath, cumulativeBytes: cumulative)
                        }
                        try await downloadSingleFile(
                            path: filePath,
                            to: dest,
                            repoId: repoId,
                            revision: revision,
                            expectedSize: fileInfo.size,
                            reportBytes: reportBytes,
                        )
                        return (fileInfo, true)
                    }
                )
            }

            for (filePath, task) in tasks {
                do {
                    let (info, isNewlyDownloaded) = try await task.value
                    if isNewlyDownloaded {
                        newlyDownloaded.insert(filePath)
                    }
                    downloadedCount += 1
                    // Authoritative landing (zero-RTT promotions never
                    // flushed; over-run temps land exact here).
                    batch.settle(file: filePath, exactBytes: info.size ?? 0)
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
                let attrs = try FileManager.default.attributesOfItem(
                    atPath: localPath.path(percentEncoded: false))
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

    /// Remove any `.download-*` or `.____temp` files left by cancelled downloads
    /// and prune the resulting empty downward directories.

    /// Recursively prune empty directories after temp-file cleanup.
    private func pruneEmptyDirectories(_ directory: URL) {
        let subs: [URL]
        do {
            subs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter(\.hasDirectoryPath)
        } catch {
            return
        }
        for sub in subs {
            pruneEmptyDirectories(sub)
        }
        // If the directory is now empty, remove it
        do {
            let remaining = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        } catch {
            // Directory gone or unreadable — nothing to do
        }
    }

    /// List all file paths recursively under directory.
    /// Returns RELATIVE paths (relative to `directory`) so they match the
    /// FileInfo.path strings from the ModelScope API.
    private func listLocalFiles(in directory: URL) throws -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var results: [String] = []
        // On macOS 27 Foundation, a directory URL's path(percentEncoded: false)
        // carries a TRAILING SLASH, so a `full.hasPrefix(base + "/")` check
        // would require a double-slash prefix
        // (".../gemma-4-e2b-it-4bit//") and filter EVERY real file out —
        // listLocalFiles returned [] while contentsOfDirectory saw 11 files.
        // That false "nothing downloaded" verdict defeated download()'s
        // fast-path (L121) and force a 3.5 GiB / 421 s full re-download on
        // every cold start of an already-complete model dir. Normalize the
        // base to exactly one directory boundary before comparing.
        var base = directory.path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        let prefix = base + "/"
        for case let url as URL in enumerator {
            let full = url.path(percentEncoded: false)
            if full.hasPrefix(prefix) {
                results.append(String(full.dropFirst(prefix.count)))
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
    case adapterDetected(repoId: String)
    case apiError(statusCode: Int, body: String)
    case downloadFailed(path: String, statusCode: Int)
    case downloadStalled(path: String, timeout: Int)
    case downloadBatchStalled(timeout: Int, downloadedFiles: Int, totalFiles: Int)
    case partialDownload(failed: [String], total: Int, succeeded: Int)
    case corruptedDownload(files: [String], reason: String)
    case insufficientDiskSpace(repoId: String, requiredBytes: Int64, freeBytes: Int64)
    case parseError
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .noFilesMatching(let repo, let patterns):
            "No files in model '\(repo)' matching patterns \(patterns)"
        case .gatedRepository(let repo, let hint):
            "ModelScope repository '\(repo)' is gated/private — \(hint)"
        case .adapterDetected(let repo):
            "Model '\(repo)' appears to be a LoRA/Adapter (not a full model) — adapter download is not supported"
        case .apiError(let code, let body):
            "ModelScope API error (\(code)): \(body)"
        case .downloadFailed(let path, let code):
            "Download failed for '\(path)' (HTTP \(code))"
        case .downloadStalled(let path, let timeout):
            "Download stalled for '\(path)' — no data received for \(timeout)s"
        case .downloadBatchStalled(let timeout, let downloaded, let total):
            "Download batch stalled — no progress for \(timeout)s (\(downloaded)/\(total) files)"
        case .partialDownload(let failed, let total, let succeeded):
            "Partial download: \(total) files total, \(succeeded) succeeded, \(failed.count) failed: \(failed.prefix(3).joined(separator: ", "))"
        case .corruptedDownload(let files, let reason):
            "Corrupted download (\(files.count) file(s)): \(reason). \(files.prefix(5).joined(separator: ", "))"
        case .insufficientDiskSpace(let repo, let required, let free):
            "Not enough disk space for '\(repo)' — needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. Free up space or pick a smaller/quantized model."
        case .parseError:
            "Failed to parse ModelScope API response"
        case .invalidURL(let msg):
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
