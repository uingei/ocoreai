// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Pre-fill Admission Gate — per-request memory budget admission control.
///
/// Before any pre-fill, the gate estimates the memory cost of the request
/// and checks if sufficient headroom exists. This prevents OOM mid-generation
/// by refusing large requests when budget is tight.
///
/// Features:
/// - Per-request memory cost estimation (input + output tokens)
/// - Abort margin: reserves extra headroom for emergency abort
/// - Jitter protection: burst-limits concurrent admissions
import Foundation
import Logging

/// Result of an admission check.
public struct AdmissionResult: Sendable, Codable {
    public let admitted: Bool
    public let reason: String?
    public let estimatedCostMB: Double
    
    public init(admitted: Bool, reason: String? = nil, estimatedCostMB: Double) {
        self.admitted = admitted
        self.reason = reason
        self.estimatedCostMB = estimatedCostMB
    }
    
    public static var ok: AdmissionResult {
        .init(admitted: true, estimatedCostMB: 0)
    }
    
    public static func rejected(_ reason: String, costMB: Double = 0) -> AdmissionResult {
        .init(admitted: false, reason: reason, estimatedCostMB: costMB)
    }
}

/// Pre-fill Admission Gate — actor for thread-safe budget reservation.
actor AdmissionGate {
    // MARK: - Configuration
    
    /// Bytes per token (KV cache + activation overhead, FP16 baseline)
    private let bytesPerToken: Int = 2 * 4096 * 2 // 16 KB/token (FP16, hidden dim 4096)
    
    /// Abort margin: percentage of remaining budget to always reserve
    private let abortMarginFraction: Double = 0.15
    
    /// Maximum concurrent pre-fills (jitter protection)
    private let maxConcurrentPreFills: Int
    
    /// Global memory budget in bytes (updated by dynamic enforcer)
    private var budgetBytes: UInt64 = 16 * 1024 * 1024 * 1024 // 16GB fallback
    
    // MARK: - State
    
    /// Currently admitted sessions and their reserved bytes
    private var reservations: [String: UInt64] = [:]
    
    /// Current total reserved bytes
    private var reservedBytes: UInt64 = 0
    
    /// Current active pre-fill count (for jitter limiting)
    private var activePreFills: Int = 0
    
    private let logger: Logger
    
    // MARK: - Init
    
    public init(
        budgetBytes: UInt64,
        maxConcurrentPreFills: Int = 4,
        log: Logger = Logger(label: "ocoreai.scheduler.admission")
    ) {
        self.budgetBytes = budgetBytes
        self.maxConcurrentPreFills = maxConcurrentPreFills
        self.logger = log
    }
    
    // MARK: - Budget Update
    
    /// Update budget from dynamic memory enforcer.
    public func updateBudget(_ bytes: UInt64) {
        self.budgetBytes = bytes
    }
    
    // MARK: - Admission
    
    /// Estimate memory cost for a request (KV cache for input + output tokens).
    /// - Parameters:
    ///   - inputTokens: Number of input/prompt tokens.
    ///   - maxOutputTokens: Maximum number of generated tokens.
    /// - Returns: Estimated bytes needed.
    public func estimatedCost(inputTokens: Int, maxOutputTokens: Int) -> UInt64 {
        let totalTokens = inputTokens + maxOutputTokens
        return UInt64(totalTokens) * UInt64(bytesPerToken)
    }
    
    /// Check if a new request can be admitted.
    /// - Parameters:
    ///   - sessionId: Unique session identifier.
    ///   - inputTokens: Number of input tokens in the prompt.
    ///   - maxOutputTokens: Maximum tokens the model may generate.
    /// - Returns: AdmissionResult with decision and cost estimate.
    public func check(
        sessionId: String,
        inputTokens: Int,
        maxOutputTokens: Int
    ) -> AdmissionResult {
        let cost = estimatedCost(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens)
        let costMB = Double(cost) / (1024 * 1024)
        
        // Already admitted — allow continuation
        if reservations[sessionId] != nil {
            return .ok
        }
        
        // Jitter protection: too many concurrent pre-fills
        if activePreFills >= maxConcurrentPreFills {
            return .rejected("Jitter: \(activePreFills) pre-fills active (max \(maxConcurrentPreFills))", costMB: costMB)
        }
        
        // Calculate available headroom after abort margin
        let available = max(budgetBytes - reservedBytes, 0)
        let abortMargin = UInt64(Double(available) * abortMarginFraction)
        let effectiveHeadroom = available - abortMargin
        
        // Check: does the request fit within headroom?
        if cost > effectiveHeadroom {
            let headroomMB = Double(effectiveHeadroom) / (1024 * 1024)
            return .rejected(
                "Budget: need \(String(format: "%.0f", costMB))MB, headroom \(String(format: "%.0f", headroomMB))MB",
                costMB: costMB
            )
        }
        
        // Already reserved for this session — no second admission
        if reservations[sessionId] != nil {
            return .ok
        }
        
        return AdmissionResult(admitted: true, estimatedCostMB: costMB)
    }
    
    /// Admit a request — reserve its memory cost.
    /// - Parameters:
    ///   - sessionId: Unique session identifier.
    ///   - inputTokens: Number of input tokens.
    ///   - maxOutputTokens: Maximum output tokens.
    /// - Returns: true if admission succeeded.
    /// - Note: Call ``check`` first. This assumes the caller verified admission.
    @discardableResult
    public func admit(
        _ sessionId: String,
        inputTokens: Int,
        maxOutputTokens: Int
    ) -> Bool {
        let cost = estimatedCost(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens)
        
        // Double-check headroom (defense in depth)
        let available = max(budgetBytes - reservedBytes, 0)
        guard cost <= available else {
            logger.warning("Admission failed for \(sessionId): cost \(cost) > available \(available)")
            return false
        }
        
        // Reserve
        reservations[sessionId] = cost
        reservedBytes += cost
        activePreFills += 1
        
        logger.debug("Admitted \(sessionId): \(Int(cost / 1_048_576))MB reserved (total: \(Int(reservedBytes / 1_073_741_824)) / \(Int(budgetBytes / 1_073_741_824))GB)")
        return true
    }
    
    /// Release a session's reservation (normal completion or abort).
    /// - Parameter sessionId: Session to release.
    public func release(_ sessionId: String) {
        if let cost = reservations.removeValue(forKey: sessionId) {
            reservedBytes = max(reservedBytes - cost, 0)
            activePreFills = max(0, activePreFills - 1)
            logger.debug("Released \(sessionId): freed \(Double(cost) / 1_048_576)MB")
        }
    }
    
    /// Emergency abort — release all reservations immediately.
    /// Called when OOMGuard signals .oom level.
    public func emergencyAbort() {
        let totalFreed = reservedBytes
        reservations.removeAll()
        reservedBytes = 0
        activePreFills = 0
        logger.warning("Emergency abort: freed \(Double(totalFreed) / 1_073_741_824)GB total")
    }
    
    // MARK: - Inspection
    
    /// Current admission state for monitoring.
    public func state() -> (reserved: UInt64, budget: UInt64, active: Int, sessions: Int) {
        (
            reserved: reservedBytes,
            budget: budgetBytes,
            active: activePreFills,
            sessions: reservations.count
        )
    }
}