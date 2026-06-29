// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OOMGuard — quantization downgrade chain for GPU memory protection.
///
/// On Apple Silicon UMA, CPU and GPU share the same physical memory — there is
/// no separate "GPU memory" to fall back to. Switching inference to CPU does NOT
/// free memory; it only makes it slower. Therefore the downgrade chain is:
///   4bit → 8bit → hard refuse
///
/// Each level is logged and emitted as an event for monitoring.
import Foundation
import Logging

/// Quantization levels in the downgrade chain.
///
/// NOTE: No cpuFallback — on Apple Silicon UMA, CPU and GPU share
/// physical RAM. Switching to CPU does not free memory, only adds latency.
public enum QuantizationLevel: String, Sendable, Codable {
	case bits4 /// 4-bit quantization (most aggressive, fastest)
	case bits8 /// 8-bit quantization (lower precision, less memory)
	case refuse /// Hard refuse — all requests rejected
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
		memoryBudgetGB: Double,
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

	/// Minimum quantization level before hard refuse.
	var minLevel: QuantizationLevel = .refuse

	/// Maximum allowed requests at current level.
	var maxRequests: [QuantizationLevel: Int] = [
		.bits4: 16,
		.bits8: 8,
		.refuse: 0,
	]

	/// Initialize OOMGuard.
	init(log: Logger = Logger(label: "ocoreai.scheduler.oomguard")) {
		logger = log
	}

	// MARK: - Budget Sync (called by MemoryTracker)

	/// Update budget and usage from the memory tracker.
	func updateUsage(_ used: UInt64, budget: UInt64) {
		budgetBytesUsed = used
		budgetBytes = budget
	}

	// MARK: - State

	/// Get current quantization level.
	func currentQuantization() -> QuantizationLevel {
		currentLevel
	}

	/// Get recent downgrade events.
	/// - Parameter count: Number of events to return (default: 10).
	func recentEvents(count: Int = 10) -> [OOMEvent] {
		Array(eventHistory.suffix(count))
	}

	// MARK: - Downgrade Chain

	/// Called when memory tracker signals a new level.
	/// - Parameter level: Current memory level from tracker.
	///
	/// UMA-correct downgrade: 4bit → 8bit → refuse.
	/// CPU fallback removed — on UMA it doesn't free memory, only adds latency.
	func respond(to level: MemoryLevel) {
		let fromLevel = currentLevel
		switch level {
		case .normal:
			// Recover to 4-bit if we're at 8-bit
			if currentLevel == .bits8 {
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
			// Force to 8-bit if still at 4-bit
			if currentLevel == .bits4 {
				currentLevel = .bits8
				emitEvent(from: fromLevel, to: .bits8, trigger: level)
			}
		case .oom:
			// Start refusing new requests
			currentLevel = .refuse
			emitEvent(from: fromLevel, to: .refuse, trigger: level)
		}
	}

	/// Check if a new request should be accepted.
	/// - Returns: true if the request can be queued.
	func shouldAcceptRequest() -> Bool {
		currentLevel != .refuse
	}

	// MARK: - Manual Override

	/// Manually set quantization level (for admin overrides).
	/// - Parameter level: Desired quantization level.
	func setLevel(_ level: QuantizationLevel) {
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
			memoryUsedGB: Double(budgetBytesUsed) / 1_073_741_824.0,
			memoryBudgetGB: Double(budgetBytes) / 1_073_741_824.0,
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
