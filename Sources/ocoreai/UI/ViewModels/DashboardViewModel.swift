// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Dashboard ViewModel — wraps MetricsBridge + health check in screen lifecycle.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
/// omlx pattern: .task{await vm.load()} drives state machine.

import Foundation
import SwiftUI

@MainActor
final class DashboardState: Observable {
    /// Live metrics from bridge
    var metricsSnapshot = MetricsSnapshot.empty
    /// Token throughput history for chart
    var tokenHistory: [MetricsPoint] = []
    /// GPU memory history for chart
    var memoryHistory: [MemoryPoint] = []
    /// KV Cache history for chart
    var kvCacheHistory: [KVCachePoint] = []
    /// Connection state
    var connected: Bool = false
    var isLive: Bool { connected }

    private var bridge: MetricsBridge?
    private var syncTask: Task<Void, Never>?

    init() {}

    // MARK: - Screen lifecycle

    /// Start live metrics polling — omlx .task{ pattern
    func startPolling() async {
        bridge = MetricsBridge()
        bridge?.startPolling(interval: 1.0)

        // Periodically snapshot from bridge into our observable state
        syncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let bridge = self.bridge else { break }
                await MainActor.run {
                    self.metricsSnapshot = bridge.metricsSnapshot
                    let snap = bridge.metricsSnapshot

                    // Track token history (keep last 60 points)
                    self.tokenHistory.append(
                        MetricsPoint(
                            timestamp: Date(),
                            tokensPerSecond: snap.tokensPerSecond
                        )
                    )
                    if self.tokenHistory.count > 60 {
                        self.tokenHistory.removeFirst()
                    }

                    // Track GPU memory history
                    self.memoryHistory.append(
                        MemoryPoint(
                            timestamp: Date(),
                            gpuMemoryUsage: snap.gpuMemoryUsage,
                            kvCacheGB: Double(snap.kvCacheBytes) / 1_073_741_824.0
                        )
                    )
                    if self.memoryHistory.count > 60 {
                        self.memoryHistory.removeFirst()
                    }

                    self.connected = true
                }
            }
        }
    }

    func stopPolling() {
        bridge?.stopPolling()
        bridge = nil
        syncTask?.cancel()
        syncTask = nil
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

/// Chart data point for KV cache
struct KVCachePoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let kvCacheGB: Double
}
