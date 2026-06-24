// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Dashboard ViewModel — reads metrics directly from EnginePool + MetricsRegistry (Fast Path, no HTTP).
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
/// omlx pattern: .task{await vm.load()} drives state machine.

import Foundation
import SwiftUI

@Observable
@MainActor
final class DashboardState {
    /// Live metrics snapshot
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

    private var pollingTask: Task<Void, Never>?
    private let engine = OcoreaiEngine.shared

    // MARK: - Screen lifecycle

    /// Start live metrics polling — reads directly from EnginePool + MetricsRegistry
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
        
        pollingTask = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                let (pool, metrics) = await MainActor.run {
                    (self.engine.activeEnginePool, self.engine.activeMetrics)
                }
                guard let pool, let metrics else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                let _ = await pool.engineSummary()
                let promText = await metrics.export()
                let parsed = MetricsSnapshot.parse(from: promText) ?? .empty

                await MainActor.run {
                    self.metricsSnapshot = parsed
                    let snap = parsed

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

                    // KV cache point
                    let kvGB = Double(snap.kvCacheBytes) / 1_073_741_824.0
                    self.kvCacheHistory.append(KVCachePoint(timestamp: Date(), kvCacheGB: kvGB))
                    if self.kvCacheHistory.count > 60 {
                        self.kvCacheHistory.removeFirst()
                    }

                    self.connected = true
                }

                try? await Task.sleep(nanoseconds: AppState.shared.isForeground ? 1_000_000_000 : 10_000_000_000)
            }
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

/// Chart data point for KV cache
struct KVCachePoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let kvCacheGB: Double
}
