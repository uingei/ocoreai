// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Reactive global state — coordinates metrics polling, UI navigation, and theme updates.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking,
/// no @Published needed. Observers auto-track mutations.

import Foundation

@MainActor
final class AppState: Observable {
    static let shared = AppState()

    var isConnected: Bool = false
    var currentMetrics: MetricsSnapshot = .empty
    var selectedTab: AppTab = .dashboard
    
    private let engine = OcoreaiEngine.shared
    private var metricsTask: Task<Void, Never>?
    
    /// Read live metrics from EnginePool directly (Fast Path, no HTTP)
    private func pollMetrics() async -> MetricsSnapshot {
        guard let pool = OcoreaiEngine.shared.activeEnginePool else { return .empty }
        let summary = await pool.engineSummary()
        return MetricsSnapshot(
            timestamp: .now,
            tokensPerSecond: 0,
            ttftMs: 0,
            ttfbMs: 0,
            gpuMemoryUsage: summary.gpuCacheGB,
            kvCacheBytes: 0,
            kvCacheEvictions: 0,
            activeSessions: summary.activeSessions,
            loadedModels: summary.loadedModels,
            inferenceDurationMs: 0,
            inferenceCount: 0,
            rateLimitRejections: 0
        )
    }

    /// Called on app launch — start internal server + sync engine state
    func initialize() {
        Task {
            await OcoreaiEngine.shared.start()
        }
        
        // Fast Path: poll EnginePool directly (no HTTP, zero serialization)
        metricsTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let snap = await self.pollMetrics()
                await MainActor.run {
                    self.currentMetrics = snap
                    self.isConnected = snap.loadedModels > 0
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Bind metrics (kept for backward / Dashboard compatibility)
    func bindMetrics() {
        // Already handled by initialize() Fast Path — no-op
    }

    /// Graceful shutdown on app termination
    func shutdown() {
        metricsTask?.cancel()
        metricsTask = nil
        Task.detached {
            await OcoreaiEngine.shared.stop()
        }
    }
}

// MARK: - Tab enum with sidebar grouping

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard, chat, models, settings, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return StringKey.tabDashboard.l
        case .chat:      return StringKey.tabChat.l
        case .models:    return StringKey.tabModels.l
        case .settings:  return StringKey.tabSettings.l
        case .status:    return StringKey.tabStatus.l
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "chart.xyaxis.line"
        case .chat:      return "bubble.right"
        case .models:    return "brain.head.profile"
        case .settings:  return "gear"
        case .status:    return "info.circle"
        }
    }

    // Sidebar section groups (omlx pattern)
    static var serverGroup: [AppTab] { [.dashboard, .chat] }
    static var modelGroup:  [AppTab] { [.models] }
    static var generalGroup: [AppTab] { [.settings, .status] }
}
