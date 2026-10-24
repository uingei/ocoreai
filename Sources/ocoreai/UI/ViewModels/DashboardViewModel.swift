// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Dashboard ViewModel — reads metrics directly from EnginePool + MetricsRegistry (Fast Path, no HTTP).
///
/// @Observable: property-level change tracking.
/// .task{await vm.load()} drives state machine.

import Foundation
import SwiftUI

/// What the dashboard health bar is allowed to claim, derived from the engine's own
/// lifecycle machine. The bar used to render `engineReady ? "System Online" : "System
/// Loading"`, which called an idle, degraded or breaker-open engine "loading" forever and
/// offered a way out of none of them.
enum DashboardHealth: Equatable, Sendable {
    case online
    case starting
    case stopping
    case degraded
    case stopped
    case failed(failures: Int)

    /// Pure mapping so all six engine states are pinned by a test rather than by a boolean.
    static func derive(
        state: EngineLifecycleState, failures: Int, cause: String?
    ) -> DashboardHealth {
        switch state {
        case .ready: return .online
        case .starting: return .starting
        case .stopping: return .stopping
        case .degraded: return .degraded
        case .idle: return cause == nil ? .stopped : .failed(failures: max(failures, 1))
        case .error: return .failed(failures: max(failures, 1))
        }
    }

    var labelKey: StringKey {
        switch self {
        case .online: return .systemOnline
        case .starting: return .systemLoading
        case .stopping: return .systemStopping
        case .degraded: return .systemDegraded
        case .stopped: return .systemStopped
        case .failed: return .systemFailedFormat
        }
    }

    var label: String {
        switch self {
        case .failed(let failures): String(format: StringKey.systemFailedFormat.l, failures)
        default: labelKey.l
        }
    }

    /// Transient states may wait without an action; every resting state owes one.
    var affordanceLabelKey: StringKey? {
        switch self {
        case .online, .starting, .stopping: nil
        case .degraded: .tabSystem
        case .stopped: .startBackendAction
        case .failed: .retryAction
        }
    }

    /// Whether this tick produced a measurement worth plotting. Stamping a point anyway
    /// would draw throughput through minutes that were never sampled.
    var samplesMetrics: Bool {
        switch self {
        case .online, .degraded: true
        default: false
        }
    }

    /// Stale = "the numbers on screen are old", which is only true when there are numbers
    /// to be old about. A cold launch with nothing measured yet must not wear the badge.
    static func metricsAreStale(health: DashboardHealth, hasValues: Bool) -> Bool {
        !health.samplesMetrics && hasValues
    }
}

@Observable
@MainActor
final class DashboardState {
    /// Shared singleton — survives view recreation (tab switch, NavigationSplitView).
    /// Accessed via @State initial: DashboardState.shared in DashboardView.
    static let shared = DashboardState()
    private init() {}

    /// Live metrics snapshot
    var metricsSnapshot = MetricsSnapshot.empty
    /// Token throughput history for chart
    var tokenHistory: [MetricsPoint] = []
    /// GPU memory history for chart
    var memoryHistory: [MemoryPoint] = []

    /// Connection state
    var connected: Bool = false
    /// Time the engine first became ready — survives view recreation, tab switches, etc.
    /// Used by DashboardView for the uptime display; `nil` before first engine boot.
    private(set) var launchTime: Date?
    var isLive: Bool {
        connected
    }

    /// The engine's own lifecycle, read at display time — see ``DashboardHealth``.
    var health: DashboardHealth {
        DashboardHealth.derive(
            state: OcoreaiEngine.shared.lifecycleState,
            failures: OcoreaiEngine.shared.startupFailureCount,
            cause: OcoreaiEngine.shared.lastStartupFailure)
    }

    /// True when numbers on screen came from an earlier, live poll rather than this tick.
    var metricsAreStale: Bool {
        DashboardHealth.metricsAreStale(health: health, hasValues: metricsSnapshot != .empty)
    }

    private var pollingTask: Task<Void, Never>?
    private let engine = OcoreaiEngine.shared

    // MARK: - Screen lifecycle

    /// Consume metrics from AppState (single source of truth).
    /// AppState.metricsTask does the actual polling — we track chart history here.
    /// Idempotent — safe to call on every DashboardView appearance (.task{} block).
    /// Fixes: P0-1 (eliminated duplicate polling), P1-1 (no [self] strong capture)
    @MainActor
    func startPolling() async {
        // Idempotency guard — prevents duplicate polling on tab switch / view recreation.
        // Also avoids the old task being orphaned (not cancelled but reference lost).
        guard pollingTask == nil else { return }

        // Record launch time on first polling start — persists across view recreation
        // since DashboardState is a singleton. Used by DashboardView for uptime display.
        if launchTime == nil {
            launchTime = .now
        }

        // Wait until engine core is fully initialized — 30s timeout guard
        let deadline = Date().addingTimeInterval(30.0)
        while !OcoreaiEngine.shared.engineReady, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        guard OcoreaiEngine.shared.engineReady else {
            return
        }

        // Poll on MainActor directly — DashboardState is @MainActor,
        // consumeMetrics reads AppState.currentMetrics (same-actor), no detached task needed.
        pollingTask = Task(priority: .utility) {
            while !Task.isCancelled {
                self.consumeMetrics()
                let interval =
                    AppState.shared.isForeground
                    ? SettingsStore.shared.pollIntervalSec
                    : max(SettingsStore.shared.pollIntervalSec, 10)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    /// Pull the latest snapshot from AppState and update chart histories.
    @MainActor
    private func consumeMetrics() {
        let snap = AppState.shared.currentMetrics

        // Connection state: mirror AppState
        self.connected = AppState.shared.isConnected

        // A stopped engine produced no sample this tick: keep the last known values (zeroing
        // them would claim a measured idle) and freeze the charts rather than drawing a flat
        // line through minutes that were never measured. `metricsAreStale` flags the pause.
        guard health.samplesMetrics else { return }

        // Update current snapshot
        self.metricsSnapshot = snap

        // Track token history (keep last 60 points)
        self.tokenHistory.append(
            MetricsPoint(
                timestamp: Date(),
                tokensPerSecond: snap.tokensPerSecond,
            ),
        )
        if self.tokenHistory.count > 60 {
            self.tokenHistory.removeFirst()
        }

        // Track GPU memory history
        self.memoryHistory.append(
            MemoryPoint(
                timestamp: Date(),
                gpuMemoryUsage: snap.gpuMemoryUsage,
                kvCacheGB: Double(snap.kvCacheBytes) / 1_073_741_824.0,
            ),
        )
        if self.memoryHistory.count > 60 {
            self.memoryHistory.removeFirst()
        }

    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}

/// Chart data point for token throughput history
struct MetricsPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let tokensPerSecond: Double
}

/// Chart data point for GPU memory usage
struct MemoryPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let gpuMemoryUsage: Double
    let kvCacheGB: Double
}
