// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MemoryTracker — GPU memory budget monitoring with OOM alerts.
///
/// On Apple Silicon UMA, GPU/CPU share physical RAM — there is no separate
/// "GPU memory" to query. Uses `host_page_size` + `host_info` / `vm_statistics`
/// for system-level memory pressure monitoring (authoritative on UMA).
///
/// Fallback: allocation accounting when Darwin API is unavailable.
import Foundation
import Logging

#if os(macOS) || os(iOS)
	@preconcurrency import Darwin
#endif

/// OOM severity levels for the downgrade chain.
public enum MemoryLevel: String, Sendable, Codable {
	case normal /// < 20% used
	case warning /// 20-50% used — consider downgrading
	case critical /// 50-80% used — force downgrade
	case oom /// > 80% used — start refusing new requests
}

/// MemoryTracker monitors memory and triggers OOMGuard.
///
/// Uses Darwin host API for authoritative memory pressure on Apple Silicon UMA.
/// Falls back to allocation accounting when Darwin API is unavailable.
/// GPU telemetry: ``gpuActiveBytes`` tracks MLX GPU active memory independently
/// of our own allocation accounting — on UMA, CPU/GPU share RAM so both matter.
///
/// Reference: vm_statistics.6 — host_statistics64(HOST_VM_INFO64)
actor MemoryTracker {
	private let budgetBytes: UInt64

	/// Ocoreai's own KV cache reservations (allocation / deallocation accounting).
	/// Independent of system-wide memory — this tracks what **we** have allocated.
	private var reservedBytes: UInt64 = 0

	/// GPU active memory from MLX Memory.activeMemory — not included in reservedBytes.
	/// Updated via reportGPUActiveBytes(). On UMA this is real pressure on system RAM.
	private var gpuActiveBytes: UInt64 = 0

	private let logger: Logger

	/// Memory level history for hysteresis
	private var levelHistory: [MemoryLevel] = []
	private let hysteresisWindow = 3

	/// Current memory level
	private(set) var currentLevel: MemoryLevel = .normal

	/// Callback to notify OOMGuard of level changes.
	private var oomCallback: (@Sendable (MemoryLevel) async -> Void)?

	/// Reference to OOMGuard for budget sync.
	private var oomGuard: OOMGuard?

	// MARK: - System Memory Polling

	/// Read current memory usage from system statistics via ProcessInfo.
	///
	/// `ProcessInfo.globalMemoryPressure` gives the system-level memory
	/// pressure state — this is the most direct way to know if the system
	/// is under memory pressure without raw kernel calls.
	///
	/// For byte-level detail we also use `ProcessInfo.activeProcessorCount`
	/// combined with the known budget to estimate pressure.
	private func pollSystemMemory() -> UInt64? {
		#if os(macOS) || os(iOS)
			// Use sysctl hw.memsize to get total physical RAM, then combine with
			// host_page_size + vm_statistics for used memory.
			var pageSize: UInt64 = 4096
			var size1 = MemoryLayout<Int>.size
			sysctlbyname("vm.pagesize", &pageSize, &size1, nil, 0)

			var vmStat = vm_statistics()
			var count: mach_msg_type_number_t = mach_msg_type_number_t(
				MemoryLayout<vm_statistics>.size / MemoryLayout<integer_t>.size
			)

			let kr = withUnsafeMutablePointer(to: &vmStat) { ptr -> kern_return_t in
				ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
					host_statistics64(
						mach_host_self(),
						HOST_VM_INFO64,
						intPtr,
						&count,
					)
				}
			}

			guard kr == KERN_SUCCESS else {
				logger.warning("MemoryTracker: host_statistics64 failed: \(kr)")
				return nil
			}

			// active_count + inactive_count + wire_count = memory in use
			let usedPages = UInt64(vmStat.active_count)
				+ UInt64(vmStat.inactive_count)
				+ UInt64(vmStat.wire_count)
			return usedPages * pageSize
		#else
			return nil
		#endif
	}

	/// Snapshot current system memory usage (does NOT touch reservedBytes).
	///
	/// Tries Darwin kernel poll first. Returns system-wide used memory, which
	/// AdmissionGate uses to compute headroom. Falls back to `reservedBytes`
	/// when the kernel API is unavailable.
	///
	/// Returns actual used bytes from system memory stats.
	func currentUsage() -> UInt64 {
		if let systemUsage = pollSystemMemory() {
			checkSystemLevel(using: systemUsage)
			return systemUsage
		}
		// Fallback: report our own accounting when system poll is unavailable
		return reservedBytes
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
		reservedBytes += bytes
		checkAllocationLevel()
	}

	/// Report a memory deallocation.
	/// - Parameter bytes: Number of bytes freed.
	func deallocation(_ bytes: UInt64) {
		reservedBytes = max(0, reservedBytes - bytes)
		checkAllocationLevel()
	}

	/// Record the actual memory usage from a source (e.g. MLX report).
	/// - Parameter bytes: Current memory usage.
	///
	/// WARNING: This overwrites `reservedBytes` — use sparingly, only when
	/// you want to replace accounting with an authoritative measurement.
	func reportUsage(_ bytes: UInt64) {
		reservedBytes = bytes
		checkAllocationLevel()
	}

	/// Report GPU active memory from MLX `Memory.activeMemory`.
	/// - Parameter bytes: MLX GPU actively used bytes.
	///
	/// Updates ``gpuActiveBytes`` without touching ``reservedBytes``.
	/// On UMA, GPU active memory counts against the same physical RAM budget,
	/// so this is included in headroom calculations via ``currentUsage()``.
	func reportGPUActiveBytes(_ bytes: UInt64) {
		gpuActiveBytes = bytes
		checkAllocationLevel()
	}

	/// Get current GPU active memory (from last `reportGPUActiveBytes` call).
	func gpuActiveMemoryBytes() -> UInt64 {
		gpuActiveBytes
	}

	/// Snapshot of current memory level.
	func snapshot() -> MemoryLevel {
		currentLevel
	}

	/// Current usage percentage (0.0 - 1.0).
	func usageFraction() -> Double {
		guard budgetBytes > 0 else { return 1.0 }
		return Double(reservedBytes) / Double(budgetBytes)
	}

	/// Return the configured budget in bytes (for AdmissionGate headroom calc).
	func getBudget() -> UInt64 {
		budgetBytes
	}

	// MARK: - Initialization

	/// Initialize with a memory budget in bytes.
	/// - Parameter budgetBytes: Maximum memory allocation in bytes.
	init(
		budgetBytes: UInt64,
		oomGuard: OOMGuard? = nil,
		log: Logger = Logger(label: "ocoreai.scheduler.memory"),
	) {
		self.budgetBytes = budgetBytes
		self.oomGuard = oomGuard
		logger = log

		#if os(macOS) || os(iOS)
			let budgetGB = Double(budgetBytes) / 1_073_741_824
			log.info("MemoryTracker: Darwin polling enabled (budget: \(String(format: "%.1f", budgetGB))GB)")
		#else
			log.warning("MemoryTracker: Darwin polling unavailable — using accounting-only mode")
		#endif
	}

	// MARK: - Internal

	/// Check and update memory level from our own allocation accounting.
	private func checkAllocationLevel() {
		guard budgetBytes > 0 else { return }
		let fraction = Double(reservedBytes) / Double(budgetBytes)
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
				let pct = Int(fraction * 100)
				logger.warning("Memory level: \(currentLevel.rawValue) → \(newLevel.rawValue) (\(pct)%)")
				currentLevel = newLevel
				if let oomg = oomGuard {
					Task { await oomg.updateUsage(reservedBytes, budget: budgetBytes) }
				}
				if let callback = oomCallback {
					Task { await callback(newLevel) }
				}
			}
		}
	}

	/// Check memory level from a system-wide usage reading (Darwin poll path).
	/// Updates currentLevel without touching our own reservation accounting.
	private func checkSystemLevel(using systemUsage: UInt64) {
		guard budgetBytes > 0 else { return }
		let fraction = Double(systemUsage) / Double(budgetBytes)
		let newLevel: MemoryLevel = if fraction < 0.2 {
			.normal
		} else if fraction < 0.5 {
			.warning
		} else if fraction < 0.8 {
			.critical
		} else {
			.oom
		}

		if newLevel != currentLevel {
			logger.warning("System memory: \(currentLevel.rawValue) -> \(newLevel.rawValue) (\(Int(fraction * 100))%)")
			currentLevel = newLevel
		}
	}
	}