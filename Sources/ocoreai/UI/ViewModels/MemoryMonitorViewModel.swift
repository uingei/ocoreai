// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MemoryMonitorViewModel.swift — Real-time memory monitoring for SwiftUI

import Foundation
import Observation

/// Real-time memory monitoring bridge for SwiftUI views.
/// Polls MemoryTracker periodically to display GPU/system memory usage.
@Observable
@MainActor
final class MemoryMonitorViewModel {
    /// Current memory usage percentage (0..100)
    var usagePercent: Double = 0
    
    /// Current memory level indicator
    var memoryLevel: String = "normal"
    
    /// Current memory level color
    var levelColor: String = "green"
    
    /// Memory used string (human readable)
    var memoryUsedString: String = ""
    
    /// Memory budget string (human readable)
    var memoryBudgetString: String = ""
    
    /// Raw used bytes
    var usedBytes: UInt64 = 0
    
    /// Raw budget bytes
    var budgetBytes: UInt64 = 0
    
    /// Poll interval in seconds
    private let pollInterval: TimeInterval = 2.0
    
    /// Background polling task
    private var pollTask: Task<Void, Never>?
    
    /// Reference to the engine's memory tracker
    private weak var engine: OcoreaiEngine?
    
    /// Shared singleton
    static let shared = MemoryMonitorViewModel()
    
    private init() {}
    
    /// Start polling memory stats
    func start() {
        stop()
        pollTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                await self.pollAndUpdate()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }
    
    /// Stop polling
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
    
    /// Poll memory tracker and update state (runs on MainActor, safe for @Observable)
    private func pollAndUpdate() async {
        guard let tracker = OcoreaiEngine.shared.activeMemoryTracker else { return }
        let used = await tracker.currentUsage()
        let budget = await tracker.getBudget()
        let level = await tracker.snapshot()
        self.usedBytes = used
        self.budgetBytes = budget
        self.usagePercent = budget > 0 ? Double(used) / Double(budget) * 100 : 0
        self.memoryLevel = level.rawValue
        self.levelColor = level.color
        self.memoryUsedString = Self.humanReadableSize(used)
        self.memoryBudgetString = Self.humanReadableSize(budget)
    }
}

extension MemoryMonitorViewModel {
    private static func humanReadableSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

extension MemoryLevel {
    var color: String {
        switch self {
        case .normal: return "green"
        case .warning: return "yellow"
        case .critical: return "orange"
        case .oom: return "red"
        }
    }
}
