// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Reactive global state — coordinates metrics polling, UI navigation, and theme updates.
///
/// @Observable: property-level change tracking,
/// no @Published needed. Observers auto-track mutations.

import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var isConnected: Bool = false
    var currentMetrics: MetricsSnapshot = .empty
    var selectedTab: AppTab = .dashboard
    /// ScenePhase gate — true when app is active, false in background
    var isForeground: Bool = true

    /// P1: Current compute channel baseline from HardwareRouter
    /// Mirrors RouterPoller.baselineChannel so UI knows the live route
    var currentBaselineChannel: ComputeChannel?

    /// P1: Transient toast for channel shift events (auto-dismiss 3s)
    var channelShiftToast: ChannelShiftToast?

    // MARK: - Thermal event bridge

    /// Receive ThermalPressureEvent from HardwareRouter poller.
    /// Called on callback thread (non-MainActor), bridges to @Observable state.
    func onThermalPressureEvent(_ event: ThermalPressureEvent) async {
        await MainActor.run { [self] in
            self.currentBaselineChannel = event.to
            self.channelShiftToast = .init(event: event)
            // X1-fix: thermal/inference channel shift → adjust perception sampling rate
            // so PerceptionEngine doesn't compete with the active accelerator.
            switch event.to {
            case .cpu:
                PerceptionEngine.shared.setPowerProfile(.minimal)
            case .ane:
                PerceptionEngine.shared.setPowerProfile(.reduced)
            case .gpu:
                PerceptionEngine.shared.setPowerProfile(.normal)
            }
        }
        // Auto-dismiss after 3s
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await MainActor.run { [self] in
            self.channelShiftToast = nil
        }
    }

    /// Undo slot — set by any ViewModel before a destructive op, cleared after undo
    var undoAction: (@MainActor () -> Void)?

    /// Whether undo is available (for menu item enabling)
    var hasUndo: Bool {
        undoAction != nil
    }

    /// Execute undo and clear the slot
    func performUndo() {
        undoAction?()
        undoAction = nil
    }

    // MARK: - Agent tool approval (codex ExecApprovalRequest → 裁决)

    /// Pending approval requests — published by `ApprovalBroker` observers,
    /// presented in ChatView banner, cleared on resolve.
    var pendingApprovals: [PendingApproval] = []

    /// 三档裁决（codex ReviewDecision：Approved / ApprovedForSession / Denied）。
    /// broker 缺席（未启动）→ 静默 no-op，banner 下次 snapshot 自然清场。
    func approveOnce(_ row: PendingApproval) {
        Task {
            _ = await OcoreaiEngine.shared.activeApprovalBroker?
                .resolve(id: row.id, decision: .approved)
        }
    }

    func approveForSession(_ row: PendingApproval) {
        Task {
            _ = await OcoreaiEngine.shared.activeApprovalBroker?
                .resolve(id: row.id, decision: .approvedForSession)
        }
    }

    func denyApproval(_ row: PendingApproval) {
        Task {
            _ = await OcoreaiEngine.shared.activeApprovalBroker?
                .resolve(id: row.id, decision: .denied(reason: "denied-by-user"))
        }
    }

    private let engine = OcoreaiEngine.shared
    private var metricsTask: Task<Void, Never>?
    /// Idempotency guard — initialize() is safe to call multiple times
    private var _initialized = false

    /// Read live metrics from EnginePool + MetricsRegistry (Fast Path, no HTTP)
    /// Combines engine summary with Prometheus-style metrics for full observability.
    private func pollMetrics() async -> MetricsSnapshot {
        let (pool, registry) = (
            OcoreaiEngine.shared.activeEnginePool,
            OcoreaiEngine.shared.activeMetrics,
        )

        // Fast path: get engine summary for core state
        let summary: EngineSummary
        if let pool {
            summary = await pool.engineSummary()
        } else {
            return .empty
        }

        // Parse metrics registry for detailed telemetry
        if let registry, let parsed = await MetricsSnapshot.parse(from: registry.export()) {
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
                rateLimitRejections: parsed.rateLimitRejections,
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
            rateLimitRejections: 0,
        )
    }

    /// Called on app launch — start internal server + sync engine state
    /// Idempotent: safe to call multiple times (e.g., repeated onAppear in SwiftUI)
    func initialize() {
        guard !_initialized else { return }
        _initialized = true

        Task {
            await OcoreaiEngine.shared.start()
        }

        /// Fast Path: poll EnginePool directly (no HTTP, zero serialization)
        /// ScenePhase-gated: 1s in foreground, 10s in background.
        metricsTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    // isConnected is based on engineReady, not loadedModels —
                    // EnginePool starts empty (lazy model loading), so loadedModels == 0
                    // does NOT mean the engine is down.
                    self.isConnected = OcoreaiEngine.shared.engineReady
                }
                let snap = await pollMetrics()
                await MainActor.run {
                    self.currentMetrics = snap
                }
                // ScenePhase gating: slow down in background
                let sleepNs: UInt64 =
                    await MainActor.run { self.isForeground } ? 1_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
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

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, chat, models, sessions, skills, system, settings, status

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .dashboard: StringKey.tabDashboard.l
        case .chat: StringKey.tabChat.l
        case .models: StringKey.tabModels.l
        case .settings: StringKey.tabSettings.l
        case .status: StringKey.tabStatus.l
        case .sessions: StringKey.tabSessions.l
        case .skills: StringKey.tabSkills.l
        case .system: StringKey.tabSystem.l
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "chart.xyaxis.line"
        case .chat: "bubble.right"
        case .models: "brain.head.profile"
        case .settings: "gear"
        case .status: "info.circle"
        case .sessions: "text.page"
        case .skills: "wrench.and.screwdriver"
        case .system: "server.rack"
        }
    }

    // Sidebar section groups — HIG compliant: max 2-3 groups, balanced size
    static var serverGroup: [AppTab] {
        [.dashboard, .chat]
    }

    static var workflowGroup: [AppTab] {
        [.models, .sessions]
    }

    static var systemGroup: [AppTab] {
        [.skills, .system, .status, .settings]
    }
}

// MARK: - Channel Shift Toast DTO

/// P1: Transient notification for compute channel shifts.
/// Carries from/to channels + trigger reason so the UI can say
/// "Shifted GPU → ANE (thermal pressure)" instead of a generic toast.
struct ChannelShiftToast: Equatable {
    let from: ComputeChannel
    let to: ComputeChannel
    let trigger: String  // "thermal" or "memory"
    let timestamp: Date

    init(event: ThermalPressureEvent) {
        self.from = event.from
        self.to = event.to
        self.trigger = event.trigger
        self.timestamp = event.timestamp
    }
}
