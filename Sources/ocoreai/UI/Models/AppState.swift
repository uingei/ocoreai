// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Reactive global state — coordinates metrics polling, UI navigation, and theme updates.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking,
/// no @Published needed. Observers auto-track mutations.

import Foundation
import Observation

@Observable
@MainActor
final class AppState: Observable {
    static let shared = AppState()

    var isConnected: Bool = false
    var currentMetrics: MetricsSnapshot = .empty
    var selectedTab: AppTab = .dashboard
    /// ScenePhase gate — true when app is active, false in background
    var isForeground: Bool = true

    /// Undo slot — set by any ViewModel before a destructive op, cleared after undo
    var undoAction: (@MainActor () -> Void)? = nil

    /// Whether undo is available (for menu item enabling)
    var hasUndo: Bool { undoAction != nil }

    /// Execute undo and clear the slot
    func performUndo() {
        undoAction?()
        undoAction = nil
    }

    private let engine = OcoreaiEngine.shared
    private var metricsTask: Task<Void, Never>?
    
    /// Read live metrics from EnginePool + MetricsRegistry (Fast Path, no HTTP)
    /// Combines engine summary with Prometheus-style metrics for full observability.
    private func pollMetrics() async -> MetricsSnapshot {
        let (pool, registry) = (
            OcoreaiEngine.shared.activeEnginePool,
            OcoreaiEngine.shared.activeMetrics
        )
        
        // Fast path: get engine summary for core state
        let summary: EngineSummary
        if let pool {
            summary = await pool.engineSummary()
        } else {
            return .empty
        }
        
        // Parse metrics registry for detailed telemetry
        if let registry, let parsed = MetricsSnapshot.parse(from: await registry.export()) {
            return MetricsSnapshot(
                timestamp: .now,
                tokensPerSecond: parsed.tokensPerSecond,
                ttftMs: parsed.ttftMs,
                ttfbMs: parsed.ttfbMs,
                gpuMemoryUsage: parsed.gpuMemoryUsage,
                kvCacheBytes: parsed.kvCacheBytes,
                kvCacheEvictions: parsed.kvCacheEvictions,
                activeSessions: parsed.activeSessions,
                loadedModels: parsed.loadedModels,
                inferenceDurationMs: parsed.inferenceDurationMs,
                inferenceCount: parsed.inferenceCount,
                rateLimitRejections: parsed.rateLimitRejections
            )
        }
        
        // Fallback: engine summary only
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
        
        /// Fast Path: poll EnginePool directly (no HTTP, zero serialization)
        /// ScenePhase-gated: 1s in foreground, 10s in background.
        metricsTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    // isConnected is based on engineReady, not loadedModels —
                    // EnginePool starts empty (lazy model loading), so loadedModels == 0
                    // does NOT mean the engine is down.
                    self.isConnected = OcoreaiEngine.shared.engineReady
                }
                let snap = await self.pollMetrics()
                await MainActor.run {
                    self.currentMetrics = snap
                }
                // ScenePhase gating: slow down in background
                let sleepNs: UInt64 = await MainActor.run { self.isForeground } ? 1_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
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
