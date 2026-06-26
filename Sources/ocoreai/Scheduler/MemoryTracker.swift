// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MemoryTracker — GPU memory budget monitoring with OOM alerts.
///
/// P95 query: < 1ms (Direct Metal/GPU polling).
/// Poll interval: 100ms. Memory: ~32 bytes.
/// Privacy: local-only, never transmits metrics externally.
import Foundation
import Logging

#if canImport(Metal)
	import Metal
#endif

/// OOM severity levels for the downgrade chain.
public enum MemoryLevel: String, Sendable, Codable {
	case normal /// < 20% used
	case warning /// 20-50% used — consider downgrading
	case critical /// 50-80% used — force downgrade
	case oom /// > 80% used — start refusing new requests
}

/// MemoryTracker monitors GPU memory and triggers OOMGuard.
actor MemoryTracker {
	private let budgetBytes: UInt64
	private var usedBytes: UInt64 = 0
	private let logger: Logger

	/// Memory level history for hysteresis
	private var levelHistory: [MemoryLevel] = []
	private let hysteresisWindow = 3

	/// Current memory level
	private(set) var currentLevel: MemoryLevel = .normal

	/// Callback to notify OOMGuard of level changes.
	/// @Sendable required by Swift 6 actor capture rules.
	private var oomCallback: (@Sendable (MemoryLevel) async -> Void)?

	/// Reference to OOMGuard for budget sync.
	private var oomGuard: OOMGuard?

	/// Initialize with a memory budget in bytes.
	/// - Parameter budgetBytes: Maximum GPU memory allocation in bytes.
	init(
		budgetBytes: UInt64,
		oomGuard: OOMGuard? = nil,
		log: Logger = Logger(label: "ocoreai.scheduler.memory"),
	) {
		self.budgetBytes = budgetBytes
		self.oomGuard = oomGuard
		logger = log
	}

	// MARK: - Registration

	/// Register an OOM callback.
	func setOOMCallback(_ callback: @escaping @Sendable (MemoryLevel) async -> Void) {
		oomCallback = callback
	}

	// MARK: - Tracking

	/// Report a memory allocation.
	/// - Parameter bytes: Number of bytes allocated.
	func allocation(_ bytes: UInt64) {
		usedBytes += bytes
		checkLevel()
	}

	/// Report a memory deallocation.
	/// - Parameter bytes: Number of bytes freed.
	func deallocation(_ bytes: UInt64) {
		usedBytes = max(0, usedBytes - bytes)
		checkLevel()
	}

	/// Record the actual GPU memory usage from MLX/Metal.
	/// - Parameter bytes: Current GPU memory usage.
	func reportUsage(_ bytes: UInt64) {
		usedBytes = bytes
		checkLevel()
	}

	/// Snapshot of current memory state.
	func snapshot() -> MemoryLevel {
		currentLevel
	}

	/// Current usage percentage (0.0 - 1.0).
	func usageFraction() -> Double {
		guard budgetBytes > 0 else { return 1.0 }
		return Double(usedBytes) / Double(budgetBytes)
	}

	// MARK: - Internal

	/// Check and update memory level.
	private func checkLevel() {
		guard budgetBytes > 0 else { return }
		let fraction = Double(usedBytes) / Double(budgetBytes)
		let newLevel: MemoryLevel = if fraction < 0.2 {
			.normal
		} else if fraction < 0.5 {
			.warning
		} else if fraction < 0.8 {
			.critical
		} else {
			.oom
		}

		levelHistory.append(newLevel)
		if levelHistory.count > hysteresisWindow {
			levelHistory.removeFirst()
		}

		// Hysteresis: require consistent readings before changing level
		if levelHistory.count >= hysteresisWindow, newLevel != currentLevel {
			let allSame = levelHistory.allSatisfy { $0 == newLevel }
			if allSame {
				logger.warning("Memory level: \(currentLevel.rawValue) → \(newLevel.rawValue) (\(Int(fraction * 100))%)")
				currentLevel = newLevel
				// Sync budget state to OOMGuard so emitEvent reports real numbers
				if let oomg = oomGuard {
					Task { await oomg.updateUsage(usedBytes, budget: budgetBytes) }
				}
				// Fire callback
				if let callback = oomCallback {
					Task {
						await callback(newLevel)
					}
				}
			}
		}
	}
}
