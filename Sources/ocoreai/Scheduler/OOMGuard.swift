// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OOMGuard — quantization downgrade chain for GPU memory protection.
///
/// Downgrade chain: 4bit → 8bit → CPU fallback → hard refuse.
/// Each level is logged and emitted as an event for monitoring.
import Foundation
import Logging

/// Quantization levels in the downgrade chain.
public enum QuantizationLevel: String, Sendable, Codable {
    case bits4   /// 4-bit quantization (most aggressive, fastest)
    case bits8   /// 8-bit quantization
    case cpuFallback /// CPU inference (last resort before refusing)
    case refuse  /// Hard refuse — all requests rejected
}

/// OOMGuard event for monitoring
public struct OOMEvent: Sendable, Codable {
    public let timestamp: Date
    public let triggerLevel: MemoryLevel
    public let fromLevel: QuantizationLevel
    public let toLevel: QuantizationLevel
    public let memoryUsedGB: Double
    public let memoryBudgetGB: Double
    
    public init(
        timestamp: Date,
        triggerLevel: MemoryLevel,
        fromLevel: QuantizationLevel,
        toLevel: QuantizationLevel,
        memoryUsedGB: Double,
        memoryBudgetGB: Double
    ) {
        self.timestamp = timestamp
        self.triggerLevel = triggerLevel
        self.fromLevel = fromLevel
        self.toLevel = toLevel
        self.memoryUsedGB = memoryUsedGB
        self.memoryBudgetGB = memoryBudgetGB
    }
}

/// OOMGuard manager — responds to memory pressure by downgrading quantization.
actor OOMGuard {
    private var currentLevel: QuantizationLevel = .bits4
    private let logger: Logger
    private var eventHistory: [OOMEvent] = []
    private let maxHistoryDepth = 50

    /// Budget tracking — updated by MemoryTracker via ``updateUsage(_:budget:)``.
    private var budgetBytes: UInt64 = 0
    private var budgetBytesUsed: UInt64 = 0

    /// Minimum quantization level before CPU fallback.
    var minLevel: QuantizationLevel = .cpuFallback

    /// Maximum allowed requests at current level.
    var maxRequests: [QuantizationLevel: Int] = [
        .bits4: 16,
        .bits8: 8,
        .cpuFallback: 4,
        .refuse: 0
    ]

    /// Initialize OOMGuard.
    public init(log: Logger = Logger(label: "ocoreai.scheduler.oomguard")) {
        self.logger = log
    }

    // MARK: - Budget Sync (called by MemoryTracker)

    /// Update budget and usage from the memory tracker.
    public func updateUsage(_ used: UInt64, budget: UInt64) {
        self.budgetBytesUsed = used
        self.budgetBytes = budget
    }
    
    // MARK: - State
    
    /// Get current quantization level.
    public func currentQuantization() -> QuantizationLevel {
        currentLevel
    }
    
    /// Get recent downgrade events.
    /// - Parameter count: Number of events to return (default: 10).
    public func recentEvents(count: Int = 10) -> [OOMEvent] {
        Array(eventHistory.suffix(count))
    }
    
    // MARK: - Downgrade Chain
    
    /// Called when memory tracker signals a new level.
    /// - Parameter level: Current memory level from tracker.
    public func respond(to level: MemoryLevel) {
        let fromLevel = currentLevel
        switch level {
        case .normal:
            // Recover to 4-bit if we're at a lower level
            if currentLevel == .bits8 || currentLevel == .cpuFallback {
                currentLevel = .bits4
                emitEvent(from: fromLevel, to: .bits4, trigger: level)
            }
        case .warning:
            // Downgrade to 8-bit
            if currentLevel == .bits4 {
                currentLevel = .bits8
                emitEvent(from: fromLevel, to: .bits8, trigger: level)
            }
        case .critical:
            // Force degrade to CPU or 8-bit
            if currentLevel == .bits4 {
                currentLevel = .bits8
                emitEvent(from: fromLevel, to: .bits8, trigger: level)
            } else if currentLevel == .bits8 {
                currentLevel = .cpuFallback
                emitEvent(from: fromLevel, to: .cpuFallback, trigger: level)
            }
        case .oom:
            // Start refusing new requests
            currentLevel = .refuse
            emitEvent(from: fromLevel, to: .refuse, trigger: level)
        }
    }
    
    /// Check if a new request should be accepted.
    /// - Returns: true if the request can be queued.
    public func shouldAcceptRequest() -> Bool {
        currentLevel != .refuse
    }
    
    // MARK: - Manual Override
    
    /// Manually set quantization level (for admin overrides).
    /// - Parameter level: Desired quantization level.
    public func setLevel(_ level: QuantizationLevel) {
        let fromLevel = currentLevel
        currentLevel = level
        emitEvent(from: fromLevel, to: level, trigger: .normal)
        logger.info("OOMGuard override: \(fromLevel.rawValue) → \(level.rawValue)")
    }
    
    // MARK: - Internal
    
    private func emitEvent(from: QuantizationLevel, to: QuantizationLevel, trigger: MemoryLevel) {
        let event = OOMEvent(
            timestamp: Date(),
            triggerLevel: trigger,
            fromLevel: from,
            toLevel: to,
            memoryUsedGB: Double(self.budgetBytesUsed) / 1_073_741_824.0,
            memoryBudgetGB: Double(self.budgetBytes) / 1_073_741_824.0
        )
        eventHistory.append(event)
        if eventHistory.count > maxHistoryDepth {
            eventHistory.removeFirst()
        }
        if to == .refuse {
            logger.critical("OOMGuard: HARD REFUSE — all requests rejected")
        } else {
            logger.info("OOMGuard: \(from.rawValue) → \(to.rawValue) (trigger: \(trigger.rawValue))")
        }
    }
}
