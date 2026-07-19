// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Dashboard ViewModel — reads metrics directly from EnginePool + MetricsRegistry (Fast Path, no HTTP).
///
/// @Observable: property-level change tracking.
/// .task{await vm.load()} drives state machine.

import Foundation
import SwiftUI

@Observable
@MainActor
final class DashboardState {
    /// Shared singleton — survives view recreation (tab switch, NavigationSplitView).
    /// @State<DashboardState.shared> is the correct SwiftUI observation pattern,
    /// same as ChatState, ModelManager, MultimodalState.
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
    var isLive: Bool {
        connected
    }

    private var pollingTask: Task<Void, Never>?
    private let engine = OcoreaiEngine.shared

    // MARK: - Screen lifecycle

    /// Consume metrics from AppState (single source of truth).
    /// AppState.metricsTask does the actual polling — we track chart history here.
    /// Fixes: P0-1 (eliminated duplicate polling), P1-1 (no [self] strong capture)
    @MainActor
    func startPolling() async {
        // Wait until engine core is fully initialized — 30s timeout guard
        let deadline = Date().addingTimeInterval(30.0)
        while !OcoreaiEngine.shared.engineReady, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        guard OcoreaiEngine.shared.engineReady else {
            return
        }

        // Weak self + detached: no strong reference retained beyond cancel point
        pollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Read metrics from AppState (single poller) — zero extra I/O
                await MainActor.run {
                    self.consumeMetrics()
                }

                // Use user-configured poll interval in foreground; throttle in background
                let interval = await AppState.shared.isForeground
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
