// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelCache.swift — Model cache directory management
///
/// Manages model storage at Application Support/ocoreai/models/{source}/{id}/{version}/
/// Prunes stale versions, reports disk usage, and handles concurrent access.

import Foundation

/// Model cache manager — handles directory structure, version bookkeeping, and cleanup.
actor ModelCache {
    private let cacheRoot: URL
    private let maxVersionsPerModel: Int
    private var stats: _CacheStats

    /// Default maximum versions retained per model.
    static let defaultMaxVersions = 5

    struct _CacheStats {
        var totalModels: Int = 0
        var totalBytes: Int64 = 0
        var lastPrune: Date?
    }

    /// Create cache manager pointing to the default cache directory.
    init() {
        self.cacheRoot = Self.cacheDirectory()
        self.maxVersionsPerModel = Self.defaultMaxVersions
        self.stats = _CacheStats()
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    /// Create cache manager with custom root.
    init(root: URL) {
        self.cacheRoot = root
        self.maxVersionsPerModel = Self.defaultMaxVersions
        self.stats = _CacheStats()
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Path Resolution

    /// Get the cache root URL — cross-platform (macOS/iOS/iPadOS).
    /// Uses applicationSupportDirectory so iOS sandbox works correctly.
    static func cacheDirectory() -> URL {
        guard let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ocoreai") else {
            fatalError("[ModelCache] applicationSupportDirectory not available")
        }
        return supportDir.appendingPathComponent("models")
    }

    /// Construct path for {source}/{id}/{version}/ .
    func modelPath(source: String, id: String, version: String) -> URL {
        cacheRoot.appendingPathComponent(source)
            .appendingPathComponent(id)
            .appendingPathComponent(version)
    }

    /// Find the latest version of a model in the cache.
    func latestVersion(source: String, id: String) -> String? {
        let modelDir = cacheRoot.appendingPathComponent(source).appendingPathComponent(id)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: nil
        ), !contents.isEmpty else {
            return nil
        }

        var bestVersion: String?
        var bestDate = Date(timeIntervalSince1970: 0)
        for item in contents {
            if let modDate = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if modDate > bestDate {
                    bestDate = modDate
                    bestVersion = item.lastPathComponent
                }
            }
        }
        return bestVersion
    }

    /// Check if a specific model version exists in the cache.
    func hasVersion(source: String, id: String, version: String) -> Bool {
        let versionUrl = modelPath(source: source, id: id, version: version)
        return FileManager.default.fileExists(atPath: versionUrl.path())
    }

    // MARK: - Cache Management

    /// Get total disk usage of the cache directory.
    func totalDiskUsage() async -> Int64 {
        await calculateUsage(at: cacheRoot)
    }

    /// Prune old model versions, keeping the N most recent per model.
    /// - Parameter maxVersions: Maximum versions to keep per model
    /// - Returns: Number of bytes freed
    func prune(maxVersions: Int? = nil) async -> Int64 {
        let limit = maxVersions ?? self.maxVersionsPerModel
        var freedBytes: Int64 = 0

        // Iterate over source directories
        guard let sources = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        for sourceDir in sources where sourceDir.hasDirectoryPath {
            guard let models = try? FileManager.default.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }

            for modelDir in models where modelDir.hasDirectoryPath {
                // Sort by modification date (newest first)
                guard let versionEntries = try? FileManager.default.contentsOfDirectory(
                    at: modelDir,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { continue }

                let dated: [(name: String, date: Date)] = versionEntries.compactMap { url in
                    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
                    guard let modDate = try? url.resourceValues(
                        forKeys: keys
                    ).contentModificationDate else { return nil }
                    return (url.lastPathComponent, modDate)
                }.sorted { $0.date > $1.date }

                let excess = dated.suffix(from: min(limit, dated.count))
                for excessVersion in excess {
                    let versionUrl = modelDir.appendingPathComponent(excessVersion.name)
                    let usage = await calculateUsage(at: versionUrl)
                    try? FileManager.default.removeItem(at: versionUrl)
                    freedBytes += usage
                }
            }
        }

        stats.lastPrune = Date()
        return freedBytes
    }

    /// Remove a specific model entirely (all versions).
    func removeModel(source: String, id: String) throws {
        let modelDir = cacheRoot.appendingPathComponent(source).appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: modelDir.path()) {
            try FileManager.default.removeItem(at: modelDir)
        }
    }

    // MARK: - Stats

    /// Get cache statistics.
    func getStats() -> String {
        "Cache: \(cacheRoot.path()) | Max versions/\(maxVersionsPerModel) | Last prune: \(stats.lastPrune?.description ?? "never")"
    }

    // MARK: - Internal

    private func calculateUsage(at url: URL) async -> Int64 {
        // FileEnumerator.makeIterator is unavailable from async contexts — wrap in sync dispatch
        return DispatchQueue.global(qos: .userInitiated).sync {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 as Int64 }

            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]
                ).totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
            return total
        }
    }
}

extension URL {
    private var hasDirectoryPath: Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
