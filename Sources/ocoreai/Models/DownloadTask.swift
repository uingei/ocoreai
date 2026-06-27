// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DownloadTask.swift — 独立下载任务状态机
///
/// 参考 omlx DownloadsScreenVM + ms_downloader.py 设计：
/// - 每个下载任务有唯一 ID、明确的生命周期状态机
/// - 支持 pending → downloading → completed/failed/cancelled
/// - 支持进度追踪（文件级 + 字节级）
/// - 与 EnginePool 加载链路完全解耦
///
/// 状态机转换图：
///   pending ──→ downloading ──→ completed
///     │            │              │
///     │            ├─→ failed    │
///     └──→ cancelled           └── (terminal)
///
/// Key design decisions:
/// 1. DownloadTask 是 @Sendable struct — 不可变快照，状态变更产生新实例
/// 2. DownloadTaskManager 是 actor — 集中管理任务队列、并发限制、去重
/// 3. ProgressBroadcaster 替代 OcoreaiDownloadProgress 单例 — 支持多订阅者 @Observable

import Foundation
import Observation

// MARK: - Download State

/// Download task state — mirrors omlx DownloadTaskState enum
enum DownloadTaskState: String, Codable, Sendable {
    /// Queued, waiting for available slot
    case pending
    /// Actively downloading files
    case downloading
    /// Download finished successfully
    case completed
    /// Download failed with error
    case failed
    /// User cancelled the download
    case cancelled
    
    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
    
    var icon: String {
        switch self {
        case .pending: return "hourglass"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }
}

// MARK: - Hub Source extensions for DownloadTask compatibility

extension HubSource {
    var cacheName: String {
        switch self {
        case .huggingFace: return "huggingface"
        case .modelScope: return "modelscope"
        }
    }
    var modelPrefix: String {
        switch self {
        case .huggingFace: return "hf:"
        case .modelScope: return "mscope:"
        }
    }
    
    /// Convert to MLXModelLoader.HubProvider (mlx trait only)
    #if mlx
    func toHubProvider() -> MLXModelLoader.HubProvider {
        switch self {
        case .huggingFace: return .huggingFace
        case .modelScope: return .modelScope
        }
    }
    #endif
}

// MARK: - Progress

/// Progress snapshot for a single download task
struct DownloadProgress: Codable, Sendable {
    /// Overall fraction 0.0–1.0
    let fractionCompleted: Double
    /// Percentage 0–100
    var percentage: Int {
        Int(fractionCompleted * 100)
    }
    /// Files completed so far
    let completedFiles: Int
    /// Total files to download
    let totalFiles: Int
    /// Bytes transferred so far
    let bytesTransferred: Int64
    /// Total bytes to download
    let totalBytes: Int64
    /// Estimated seconds remaining (nil if unknown)
    let etaSeconds: Int64?
    /// Current file being downloaded
    let currentFile: String?
    
    var bytesTransferredFormatted: String {
        formatByteCount(bytesTransferred)
    }
    
    var totalBytesFormatted: String {
        formatByteCount(totalBytes)
    }
    
    var etaFormatted: String? {
        guard let seconds = etaSeconds, seconds > 0 else { return nil }
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        }
    }
    
    static var idle: DownloadProgress {
        DownloadProgress(
            fractionCompleted: 0,
            completedFiles: 0,
            totalFiles: 0,
            bytesTransferred: 0,
            totalBytes: 0,
            etaSeconds: nil,
            currentFile: nil
        )
    }
    
    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Download Task

/// Immutable snapshot of a download task.
/// State changes produce new instances (actor emits updated copies).
///
/// Mirrors omlx's DownloadTask model with added fields for progress granularity.
struct DownloadTask: Identifiable, Sendable {
    let id: String
    /// Repository ID (e.g. "Qwen/Qwen2.5-7B-Instruct")
    let repoId: String
    /// Hub source provider
    let source: HubSource
    /// Git revision/branch (nil = default)
    let revision: String?
    /// Task state in the lifecycle FSM
    var state: DownloadTaskState
    /// Human-readable error message (for failed/cancelled)
    var errorMessage: String?
    /// Current progress snapshot
    var progress: DownloadProgress
    /// Local cache directory path (set after download completes)
    var cacheDir: String?
    /// Creation timestamp
    let createdAt: Date
    /// Last state change timestamp
    var updatedAt: Date
    /// Estimated total size in bytes (from API pre-check)
    var estimatedTotalBytes: Int64?
    /// Model parameter count string (from enrichment, e.g. "7B")
    var paramCount: String?
    
    var displayId: String {
        "\(source.modelPrefix)\(repoId)"
    }
    
    /// Whether this task can be retried
    var isRetryable: Bool {
        state == .failed
    }
    
    /// Whether this task can be cancelled
    var isCancellable: Bool {
        state == .pending || state == .downloading
    }
    
    /// Human-readable state description
    var stateDescription: String {
        switch state {
        case .pending: return "Queued"
        case .downloading: return "Downloading \(progress.percentage)%"
        case .completed: return "Completed"
        case .failed: return "Failed: \(errorMessage ?? "Unknown error")"
        case .cancelled: return "Cancelled"
        }
    }
    
    /// Generate a new task with updated state
    func updating(state: DownloadTaskState, errorMessage: String? = nil, progress: DownloadProgress? = nil, cacheDir: String? = nil) -> DownloadTask {
        var copy = self
        copy.state = state
        copy.errorMessage = errorMessage
        copy.updatedAt = Date()
        if let progress {
            copy.progress = progress
        }
        if let cacheDir {
            copy.cacheDir = cacheDir
        }
        return copy
    }
}

// MARK: - Download Task Manager

/// Central manager for model download tasks.
///
/// Responsibilities:
/// - Task queue with concurrency limit (default: 2 parallel downloads)
/// - Deduplication — same repo+source+revision → reuse existing task
/// - Progress tracking per task
/// - Cache hit detection — returns completed task if model already downloaded
/// - Task cancellation and retry
///
/// Architecture (aligned with omlx ms_downloader.py):
/// - Actor isolation for mutable task state
/// - @Observable ProgressBroadcaster for UI bindings
/// - Async/await download execution with Task cancellation support
actor DownloadTaskManager {
    // MARK: - Configuration
    
    /// Maximum concurrent downloads (omlx default)
    private let maxConcurrent: Int
    /// Logger reference (weak to avoid retain cycles — caller must log directly)
    // MARK: - State
    
    /// Active and recent tasks keyed by task ID
    private var tasks: [String: DownloadTask] = [:]
    /// Download queue — tasks waiting for a slot
    private var queue: [String] = []
    /// Currently running download tasks
    private var runningTasks: [String: Task<Void, Never>] = [:]
    
    // MARK: - Initialization
    
    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }
    
    // MARK: - Task Lifecycle
    
    /// Create or retrieve a download task for a model.
    ///
    /// - Parameters:
    ///   - repoId: Repository identifier (e.g. "Qwen/Qwen2.5-7B-Instruct")  -   source: Hub provider (HF or ModelScope)
    ///   - revision: Optional git revision
    /// - Returns: Task ID (new or existing)
    ///
    /// Deduplication: if a non-terminal task for the same repo+source+revision exists, returns its ID.
    func createIfNeeded(repoId: String, source: HubSource, revision: String? = nil) -> String {
        // Check for existing non-terminal task
        let existing = tasks.first { _, task in
            task.repoId == repoId &&
            task.source == source &&
            task.revision == revision &&
            !task.state.isTerminal
        }
        
        if let existing {
            return existing.key
        }
        
        // Create new task
        let taskId = UUID().uuidString
        let task = DownloadTask(
            id: taskId,
            repoId: repoId,
            source: source,
            revision: revision,
            state: .pending,
            errorMessage: nil,
            progress: .idle,
            cacheDir: nil,
            createdAt: Date(),
            updatedAt: Date(),
            estimatedTotalBytes: nil,
            paramCount: nil
        )
        
        tasks[taskId] = task
        queue.append(taskId)
        
        // Try to start downloads if slots available
        drainQueue()
        
        return taskId
    }
    
    /// Check if a model is already cached (downloaded).
    ///
    /// Scans tasks for completed downloads matching repoId+source,
    /// then verifies the cache directory actually exists on disk.
    func isModelCached(repoId: String, source: HubSource) -> Bool {
        guard let task = tasks.first(where: {
            $0.value.repoId == repoId &&
            $0.value.source == source &&
            $0.value.state == .completed
        })?.value,
              let cacheDir = task.cacheDir,
              FileManager.default.fileExists(atPath: cacheDir),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: URL(fileURLWithPath: cacheDir), includingPropertiesForKeys: nil
              ),
              !files.isEmpty
        else {
            return false
        }
        // Must have at least one safetensors file to be considered "downloaded"
        return files.contains { $0.pathExtension == "safetensors" }
    }
    
    /// Get current task state snapshot
    func getTask(_ taskId: String) -> DownloadTask? {
        tasks[taskId]
    }
    
    /// Get all tasks (sorted by creation date, newest first)
    func getAllTasks() -> [DownloadTask] {
        Array(tasks.values).sorted(by: { $0.createdAt > $1.createdAt })
    }
    
    /// Get tasks filtered by state
    func getTasks(state: DownloadTaskState?) -> [DownloadTask] {
        let filtered: [DownloadTask]
        if let state {
            filtered = tasks.values.filter { $0.state == state }
        } else {
            filtered = Array(tasks.values)
        }
        return filtered.sorted(by: { $0.createdAt > $1.createdAt })
    }
    
    /// Cancel a pending or downloading task
    func cancel(_ taskId: String) async {
        guard let task = tasks[taskId], task.isCancellable else { return }
        
        // If running, cancel the Task
        if let running = runningTasks.removeValue(forKey: taskId) {
            running.cancel()
        }
        
        // Remove from queue if pending
        queue.removeAll { $0 == taskId }
        
        // Update state
        tasks[taskId] = task.updating(
            state: .cancelled,
            errorMessage: "User cancelled"
        )
    }
    
    /// Retry a failed task
    func retry(_ taskId: String) async -> String? {
        guard let task = tasks[taskId], task.isRetryable else { return nil }
        
        // Create new task with same repoId/source/revision
        let newTaskId = createIfNeeded(
            repoId: task.repoId,
            source: task.source,
            revision: task.revision
        )
        
        return newTaskId
    }
    
    /// Clear completed/cancelled/failed tasks from memory
    func clearTerminalTasks() {
        let activeTasks = tasks.filter { _, task in !task.state.isTerminal }
        tasks = activeTasks
        queue.removeAll { id in activeTasks[id] == nil }
    }
    
    // MARK: - Download Execution
    
    /// Start the actual download for a task.
    ///
    /// This is called by drainQueue() when a slot becomes available.
    /// The caller (ModelRepositoryState or UI) passes a download closure
    /// that returns (cacheDir, success) on completion.
    func startDownload(
        _ taskId: String,
        download: @escaping @Sendable () async throws -> String
    ) {
        guard let task = tasks[taskId],
              task.state == .pending else {
            return
        }
        
        // Update state to downloading
        tasks[taskId] = task.updating(state: .downloading)
        
        // Remove from queue
        queue.removeAll { $0 == taskId }
        
        // Start async download
        let downloadTask = Task { [self] in
            do {
                let cachePath = try await download()
                
                // Check if cancelled during download
                if Task.isCancelled {
                    tasks[taskId]?.state = .cancelled
                    return
                }
                
                // Success
                let updated = tasks[taskId]?.updating(
                    state: .completed,
                    cacheDir: cachePath
                ) ?? task
                tasks[taskId] = updated
            } catch {
                // Failure
                tasks[taskId]?.state = .failed
                tasks[taskId]?.errorMessage = error.localizedDescription
            }
            
            // Free slot and drain queue
            runningTasks.removeValue(forKey: taskId)
            drainQueue()
        }
        
        runningTasks[taskId] = downloadTask
    }
    
    /// Update progress for a download task
    func updateProgress(_ taskId: String, _ progress: DownloadProgress) {
        guard var task = tasks[taskId] else { return }
        task.progress = progress
        task.updatedAt = Date()
        tasks[taskId] = task
    }
    
    /// Update estimated total bytes for a task (from API pre-check)
    func updateEstimatedSize(_ taskId: String, bytes: Int64) {
        guard var task = tasks[taskId] else { return }
        task.estimatedTotalBytes = bytes
        task.updatedAt = Date()
        tasks[taskId] = task
    }
    
    // MARK: - Queue Management
    
    /// Move pending tasks from queue to running if slots available
    private func drainQueue() {
        let runningCount = runningTasks.count
        let availableSlots = maxConcurrent - runningCount
        
        for _ in 0..<max(0, availableSlots) {
            guard !queue.isEmpty else { break }
            // Signal that this task should start — the caller is responsible
            // for invoking startDownload with the actual download closure
            queue.removeFirst()
        }
    }
    
    /// Get number of pending tasks
    var pendingCount: Int {
        tasks.values.filter { $0.state == .pending }.count
    }
    
    /// Get number of actively downloading tasks
    var activeDownloadCount: Int {
        tasks.values.filter { $0.state == .downloading }.count
    }
    
    /// Whether any slots are available
    var hasAvailableSlot: Bool {
        runningTasks.count < maxConcurrent
    }
}

// MARK: - Progress Broadcaster

/// @Observable bridge for download progress UI bindings.
/// Replaces OcoreaiDownloadProgress singleton with multi-subscriber support.
///
/// Usage:
///   1. UI observes: `OcoreaiDownloadProgress.shared`
///   2. DownloadTask 更新进度时广播 Progress
///   3. UI binds to: `.progress(for:)`, `.isDownloading(:_)`
///
/// Maintains backward compatibility with existing OcoreaiDownloadProgress API.
@Observable
@MainActor
final class ProgressBroadcaster {
    static let shared = ProgressBroadcaster()
    
    /// Per-model download task state — derived from DownloadTaskManager snapshots
    private var _progress: [String: OcoreaiDownloadProgressState] = [:]
    
    /// Full task list snapshot (refreshed from manager)
    var tasks: [DownloadTask] = []
    
    private init() {}
    
    /// Refresh task list snapshot from DownloadTaskManager
    func refresh(from manager: DownloadTaskManager) async {
        tasks = await manager.getAllTasks()
        // Update progress state for each active download
        for task in tasks where task.state == .downloading {
            _progress[task.repoId] = OcoreaiDownloadProgressState(
                fraction: task.progress.fractionCompleted,
                completedFiles: task.progress.completedFiles,
                totalFiles: task.progress.totalFiles,
                active: true
            )
        }
        // Remove completed tasks from active progress
        for key in _progress.keys {
            let isActive = tasks.contains {
                $0.repoId == key && $0.state == .downloading
            }
            if !isActive {
                _progress.removeValue(forKey: key)
            }
        }
    }
    
    /// Update progress state for a model
    func update(_ progress: Foundation.Progress, for modelId: String) {
        let total: Int64 = progress.totalUnitCount
        let completed: Int64 = progress.completedUnitCount
        let fraction = total > 0 ? Double(completed) / Double(total) : 0
        
        _progress[modelId] = OcoreaiDownloadProgressState(
            fraction: fraction,
            completedFiles: Int(completed),
            totalFiles: Int(total),
            active: true
        )
    }
    
    /// Start tracking a download
    func start(modelId: String) {
        _progress[modelId] = OcoreaiDownloadProgressState(
            fraction: 0, completedFiles: 0, totalFiles: 0, active: true,
        )
    }
    
    /// Mark a download as complete
    func finish(modelId: String, success: Bool = true) {
        if success {
            var state = _progress[modelId] ?? .idle
            state.fraction = 1.0
            state.active = false
            _progress[modelId] = state
        } else {
            _progress.removeValue(forKey: modelId)
        }
    }
    
    /// Clear all progress state
    func clear() {
        _progress.removeAll()
    }
    
    /// Get current progress for a model
    func progress(for modelId: String) -> OcoreaiDownloadProgressState? {
        _progress[modelId]
    }
    
    /// Is this model currently downloading?
    func isDownloading(_ modelId: String) -> Bool {
        (_progress[modelId]?.active ?? false)
    }
    
    /// Find the DownloadTask for a repoId
    func task(for repoId: String) -> DownloadTask? {
        tasks.first { $0.repoId == repoId }
    }
}
