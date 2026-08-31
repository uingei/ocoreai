// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// FileSystemSensor — monitors watched directories for file changes
///
/// Polls FileManager for file creation/modification in watched paths.
/// Produces PerceptionFrame(.environment) with change summaries.

import Foundation
import os.log

private let fsLogger = Logger(subsystem: "ocoreai", category: "filesystem_sensor")

// MARK: - File System Change Event

public struct FileChangeEvent: Codable, Sendable {
    /// 触发文件的**绝对路径**（字段名 = 真值，可直接喂 `read_file` 等工具）。
    public let path: String
    public let eventType: FileChangeEventType
    public let timestamp: Date

    /// 文件短名（派生，供 UI/建议展示）；不参与编解码。
    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    public enum FileChangeEventType: String, Codable, Sendable {
        case created
        case modified
        case deleted
    }
}

// MARK: - File System Snapshot

public struct FileSystemSnapshot: Codable, Sendable {
    public let timestamp: Date
    public let watchedPaths: Int
    public let recentChanges: [FileChangeEvent]
    public let summaryText: String

    public init(
        timestamp: Date = .init(),
        watchedPaths: Int,
        recentChanges: [FileChangeEvent],
        summaryText: String
    ) {
        self.timestamp = timestamp
        self.watchedPaths = watchedPaths
        self.recentChanges = recentChanges
        self.summaryText = summaryText
    }
}

// MARK: - Sensor

@Observable
@MainActor
final class FileSystemSensor: Sendable {
    static let shared = FileSystemSensor()

    /// Currently watched directory paths
    var watchedPaths: [String] = []

    /// Recent file change events (last 20)
    var recentEvents: [FileChangeEvent] = []

    /// Latest summary snapshot
    var latestSnapshot: FileSystemSnapshot?

    /// Whether monitoring is active
    var isMonitoring: Bool = false

    // MARK: - Internal

    private var _monitorTask: Task<Void, Never>?
    private let _maxEvents = 20

    /// Watch directories for changes
    func start(watching paths: [String]?) {
        guard !isMonitoring else { return }

        let configuredPaths: [String]
        if let userPaths = paths, !userPaths.isEmpty {
            configuredPaths = userPaths
        } else {
            configuredPaths = Self.defaultWatchPaths
        }

        self.watchedPaths = configuredPaths
        isMonitoring = true
        _monitorTask = Task.detached(priority: .utility) {
            await Self.shared.pollLoop()
        }

        fsLogger.info("[FileSystemSensor] monitoring \(configuredPaths.count) paths")
    }

    /// Stop monitoring
    @MainActor
    func stop() {
        _monitorTask?.cancel()
        _monitorTask = nil
        isMonitoring = false
        fsLogger.info("[FileSystemSensor] stopped")
    }

    // MARK: - Polling loop

    private nonisolated static let defaultWatchPaths: [String] = {
        var paths: [String] = []
        #if os(macOS)
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        if FileManager.default.fileExists(atPath: downloads.path) {
            paths.append(downloads.path)
        }
        #endif
        if let projectDir = ProcessInfo.processInfo.environment["OCOREAI_PROJECT_DIR"] {
            paths.append(projectDir)
        }
        return paths
    }()

    private func pollLoop() async {
        while !Task.isCancelled {
            let currentPaths = Self.shared.watchedPaths
            let changes = await Self.shared.detectChanges(in: currentPaths)
            Task { @MainActor in
                Self.shared.apply(changes: changes)
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    // MARK: - Change detection

    private nonisolated func detectChanges(in paths: [String]) async -> [FileChangeEvent] {
        var changes: [FileChangeEvent] = []

        for pathStr in paths {
            let url = URL(fileURLWithPath: pathStr)
            guard FileManager.default.fileExists(atPath: pathStr),
                url.hasDirectoryPath
            else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
                )

                for fileURL in contents {
                    guard
                        let modDate =
                            try? fileURL
                            .resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate
                    else { continue }

                    let age = Date().timeIntervalSince(modDate)
                    guard age > 0, age < 120 else { continue }

                    let eventType: FileChangeEvent.FileChangeEventType
                    let created =
                        try? fileURL
                        .resourceValues(forKeys: [.creationDateKey])
                        .creationDate
                    if let c = created, Date().timeIntervalSince(c) < 120 {
                        eventType = .created
                    } else {
                        eventType = .modified
                    }

                    changes.append(
                        FileChangeEvent(
                            path: fileURL.path,
                            eventType: eventType,
                            timestamp: .init()
                        ))
                }
            } catch {
                fsLogger.warning(
                    "[FileSystemSensor] cannot read \(pathStr): \(error.localizedDescription)")
                continue
            }
        }

        return changes
    }

    // MARK: - State update

    @MainActor
    private func apply(changes: [FileChangeEvent]) {
        var summary: String

        if changes.isEmpty {
            summary = "no recent filesystem changes"
        } else {
            recentEvents.append(contentsOf: changes)
            if recentEvents.count > _maxEvents {
                recentEvents = Array(recentEvents.suffix(_maxEvents))
            }
            let createdCount = recentEvents.filter { $0.eventType == .created }.count
            let modifiedCount = recentEvents.filter { $0.eventType == .modified }.count
            summary =
                "filesystem: \(createdCount) created, \(modifiedCount) modified, watching \(watchedPaths.count) dirs"

            latestSnapshot = FileSystemSnapshot(
                watchedPaths: watchedPaths.count,
                recentChanges: Array(recentEvents.suffix(10)),
                summaryText: summary
            )

            // 自主回路切片 3：新文件到达 → 主动建议（携带**可寻址绝对路径**；只提案、不执行）。
            // 权限面 = 本通道已开启（用户显式同意被感知），零新增权限。
            let evaluation = ProactiveAdvisor.evaluate(events: changes)
            if evaluation.shouldSuggest, let filePath = evaluation.filePath {
                ProactiveSuggestionStore.shared.present(filePath: filePath)
            }

            fsLogger.debug("[FileSystemSensor] \(changes.count) changes detected")
        }
    }

    // MARK: - Context text

    public func contextText() -> String {
        guard let snap = latestSnapshot else {
            return "[filesystem] no data"
        }
        return "[filesystem] \(snap.summaryText)"
    }
}
