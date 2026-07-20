// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HardwareRouter.swift — Runtime hardware-aware compute routing engine
///
/// Replaces compile-time `#if canImport(CoreAI)` / `#if mlx` binary choice with a
/// dynamic routing decision based on:
///
/// | Signal              | Source                             |
/// |---------------------|------------------------------------|
/// | Thermal state       | ProcessInfo.thermalState           |
/// | Memory usage        | Darwin host_statistics64           |
/// | Active CPU count    | ProcessInfo.activeProcessorCount   |
/// | GPU active bytes    | MemoryTracker.gpuActiveBytes       |
///
/// ### Strategy
///
/// - **Normal**: prefer GPU (MLX) — highest flexibility, dynamic graph
/// - **Warming/serious**: shift to ANE (CoreAI) — 10x energy efficiency
/// - **Memory critical**: shift to CPU-only — minimal memory footprint
/// - **GPU saturated (>70% headroom consumed)**: shift to ANE/CPU
///
/// ### Priority Overrides
///
/// `.interrupt` requests bypass ANE specialization latency — only shift
/// to ANE/CPU at `.critical` thermal state (not `.serious`).
import Foundation
import Logging
#if os(macOS) || os(iOS)
	@preconcurrency import Darwin
#endif

// MARK: - Compute Channel

/// Recommended compute accelerator for an inference request.
public enum ComputeChannel: String, Sendable, Codable, CaseIterable {
	case gpu   /// GPU via MLX (Metal) — dynamic graph, best dev experience
	case ane   /// ANE via CoreAI — static graph, 10x energy efficiency
	case cpu   /// CPU fallback — lowest performance, most resilient
}

// MARK: - Routing Policy

/// How aggressively the router responds to adverse conditions.
public enum RoutingPolicy: String, Codable, Sendable, CaseIterable {
	case balanced    // Default: shift at thermal.serious or GPU >70%
	case performance // Stay GPU longer: shift only at thermal.critical or GPU >90%
	case efficiency  // Aggressive: shift at thermal.fair or GPU >60%
}

extension ComputeChannel {
	/// Maps to CoreAI `ComputeTarget.Kind` for specialization.
	#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
		public var computeTargetKind: CoreAIModelLoader.ComputeTarget.Kind {
			switch self {
			case .gpu: .gpu
			case .ane: .neuralEngine
			case .cpu: .cpu
			}
		}
	#endif
}

// MARK: - Thermal Pressure Event

/// Emitted when HardwareRouter's baseline channel recommendation changes.
public struct ThermalPressureEvent: Sendable, Codable, CustomStringConvertible {
	public let from: ComputeChannel
	public let to: ComputeChannel
	public let trigger: String  // "thermal" or "memory"
	public let timestamp: Date

	public var description: String {
		"\(from.rawValue) → \(to.rawValue) (trigger: \(trigger))"
	}
}

// MARK: - Poller (isolates mutable state)

/// Manages baseline channel polling + debounce. Actor isolation makes
/// mutable state safe across concurrent callers.
actor RouterPoller {
	private let logger: Logger
	private let policy: RoutingPolicy
	private let debounceWindowMs: UInt64 = 3_000

	private var baselineChannel: ComputeChannel = .gpu
	private var lastPollTime: UInt64 = 0
	private var callback: (@Sendable (ThermalPressureEvent) async -> Void)?

	init(policy: RoutingPolicy, logger: Logger) {
		self.policy = policy
		self.logger = logger
	}

	/// Set event callback
	func setCallback(_ cb: @escaping @Sendable (ThermalPressureEvent) async -> Void) {
		self.callback = cb
	}

	/// Set a new event callback (convenience)
	public func setThermalCallback(_ callback: @escaping @Sendable (ThermalPressureEvent) async -> Void) {
		self.callback = callback
	}

	/// Start periodic polling on a detached task.
	/// - Parameter interval: Polling interval in seconds (default: 5s)
	/// - Returns: A `Task` handle that can be cancelled.
	public func startPolling(interval: UInt64 = 5) -> Task<Void, Never> {
		Task.detached { [weak self] in
			guard let self else { return }
			do { try await Task.sleep(nanoseconds: interval * 1_000_000_000) } catch { return }
			while !Task.isCancelled {
				await self.pollOnce()
				do { try await Task.sleep(nanoseconds: interval * 1_000_000_000) } catch { return }
			}
		}
	}

	/// Perform a single poll — update baseline, emit events if changed.
	private func pollOnce() async {
		let now = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
		if now - self.lastPollTime < self.debounceWindowMs {
			return
		}

		let thermal = ProcessInfo.processInfo.thermalState
		let memoryPressure = HardwareRouter.globalMemoryPressure()
		// On UMA, system memory fraction IS the GPU fraction (CPU/GPU share RAM).
		// Use the actual memory usage signal so the baseline reflects real pressure,
		// rather than a neutral constant that never triggers GPU-saturation routing.
		let gpuFraction = HardwareRouter.memoryUsageFraction()

		let newChannel = HardwareRouter.route(
			thermal: thermal,
			memoryPressure: memoryPressure,
			gpuFraction: gpuFraction,
			policy: self.policy,
			urgentBypass: false
		)

		let oldChannel = self.baselineChannel
		if newChannel != oldChannel {
			let thermalLevel = HardwareRouter.thermalLevel(thermal)
			let isThermalTrigger = thermalLevel >= self.policy.thermalShiftLevel

			self.baselineChannel = newChannel
			self.lastPollTime = now

			let event = ThermalPressureEvent(
				from: oldChannel,
				to: newChannel,
				trigger: isThermalTrigger ? "thermal" : "memory",
				timestamp: Date()
			)

			self.logger.warning("ThermalPressureEvent: \(event.trigger) — \(event)")
			if let cb = self.callback {
				await cb(event)
			}
		}
	}

	/// Current baseline (for debug)
	var currentBaseline: ComputeChannel {
		self.baselineChannel
	}
}

// MARK: - Hardware Router

/// Runtime hardware-aware routing engine.
///
/// All mutable polling state lives in ``RouterPoller`` (actor). This class
/// is immutable and therefore trivially ``Sendable``-compatible:
///
/// ```
/// ProcessInfo.thermalState   ─┐
/// host_statistics64          ├──→ query() → ComputeChannel
/// MemoryTracker.gpuActive   ─┘
/// ```
public final class HardwareRouter: Sendable {
	/// Routing policy
	public let policy: RoutingPolicy

	/// Logger for observability
	private let logger: Logger

	/// Background poller for baseline + event emission
	private let poller: RouterPoller

	// MARK: - Init

	public convenience init(
		policy: RoutingPolicy = .balanced,
		logger: Logger = Logger(label: "ocoreai.scheduler.router")
	) {
		self.init(policy: policy, log: logger)
	}

	init(policy: RoutingPolicy, log: Logger) {
		self.policy = policy
		self.logger = log
		self.poller = RouterPoller(policy: policy, logger: log)
		self.logger.info("HardwareRouter initialized (policy: \(policy.rawValue))")
	}

	// MARK: - Callbacks

	/// Register callback for routing change events.
	public func setThermalCallback(_ callback: @escaping @Sendable (ThermalPressureEvent) async -> Void) {
		Task { await self.poller.setThermalCallback(callback) }
	}

	// MARK: - Query

	/// Query the recommended compute channel for an inference request.
	///
	/// - Parameters:
	///   - gpuActiveBytes: Current GPU active memory (from MemoryTracker)
	///   - gpuBudgetBytes: Total GPU memory budget (from MemoryTracker)
	///   - priority: Request priority level (P0=interrupt, P3=background)
	/// - Returns: Recommended channel
	public func query(
		gpuActiveBytes: UInt64,
		gpuBudgetBytes: UInt64,
		priority: RequestPriority = .chat
	) -> ComputeChannel {
		let thermal = ProcessInfo.processInfo.thermalState
		let memoryPressure = Self.globalMemoryPressure()
		let gpuFraction: Double = gpuBudgetBytes > 0
			? Double(gpuActiveBytes) / Double(gpuBudgetBytes)
			: 0.0

		// Interrupt requests bypass ANE (avoid specialization latency)
		let urgentBypass = priority == .interrupt

		return Self.route(
			thermal: thermal,
			memoryPressure: memoryPressure,
			gpuFraction: gpuFraction,
			policy: policy,
			urgentBypass: urgentBypass
		)
	}

	/// Query with full hardware state snapshot (for observability/debugging).
	public func queryWithState(
		gpuActiveBytes: UInt64,
		gpuBudgetBytes: UInt64,
		priority: RequestPriority = .chat
	) -> (channel: ComputeChannel, state: HardwareStateSnapshot) {
		let channel = self.query(
			gpuActiveBytes: gpuActiveBytes,
			gpuBudgetBytes: gpuBudgetBytes,
			priority: priority
		)

		let state = HardwareStateSnapshot(
			thermalState: Self.thermalLevel(ProcessInfo.processInfo.thermalState),
			memoryPressure: Self.globalMemoryPressure(),
			gpuUsageFraction: gpuBudgetBytes > 0
				? Double(gpuActiveBytes) / Double(gpuBudgetBytes)
				: 0.0,
			memoryUsageFraction: Self.memoryUsageFraction(),
			computeCores: ProcessInfo.processInfo.activeProcessorCount,
			totalCores: ProcessInfo.processInfo.processorCount
		)

		return (channel, state)
	}

	// MARK: - Polling

	/// Start periodic thermal/memory polling.
	/// Calls `callback` when baseline channel recommendation changes.
	/// - Parameter interval: Polling interval in seconds (default: 5s)
	public func startPolling(interval: UInt64 = 5) {
		Task { await self.poller.startPolling(interval: interval) }
	}

	// MARK: - Routing Decision (Pure function)

	static func route(
		thermal: ProcessInfo.ThermalState,
		memoryPressure: Int,
		gpuFraction: Double,
		policy: RoutingPolicy,
		urgentBypass: Bool
	) -> ComputeChannel {
		// Tier 1: Memory pressure — force CPU if severe
		let memShiftLevel = policy.memoryShiftLevel
		if memoryPressure >= memShiftLevel {
			return .cpu
		}

		// Tier 2: Thermal — shift to ANE (or CPU if critical + no bypass)
		let thermalShiftLevel = policy.thermalShiftLevel
		let thermalLevel = Self.thermalLevel(thermal)
		if thermalLevel >= thermalShiftLevel {
			if urgentBypass && thermalLevel < 3 {
				// Urgent request, only shift if truly critical
				return .gpu
			}
			return thermalLevel >= 3 ? .cpu : .ane
		}

		// Tier 3: GPU saturation — shift to ANE
		if gpuFraction > policy.gpuWatermark {
			return .ane
		}

		// Default: GPU (healthy conditions)
		return .gpu
	}

	/// Map thermal state to numeric level (0=nominal, 3=critical)
	static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Int {
		switch state {
		case .nominal:  0
		case .fair:     1
		case .serious:  2
		case .critical: 3
		@unknown default: 0
		}
	}

	// MARK: - System Signal Readers

	@inline(__always)
	static func globalMemoryPressure() -> Int {
		// Returns pressure level 0-3 based on system memory usage fraction
		Self.memoryUsageFractionLevel()
	}

	@inline(__always)
	static func memoryUsageFraction() -> Double {
		#if os(macOS) || os(iOS)
			var pageSize: UInt64 = 4096
			var size1 = MemoryLayout<Int>.size
			sysctlbyname("vm.pagesize", &pageSize, &size1, nil, 0)

			var vmStat = vm_statistics()
			var count: mach_msg_type_number_t = mach_msg_type_number_t(
				MemoryLayout<vm_statistics>.size / MemoryLayout<integer_t>.size
			)

			let kr = withUnsafeMutablePointer(to: &vmStat) { ptr in
				ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
					host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
				}
			}

			guard kr == KERN_SUCCESS else { return 0.5 }

			var memSize: UInt64 = 0
			var len = MemoryLayout<UInt64>.size
			sysctlbyname("hw.memsize", &memSize, &len, nil, 0)

			let used = UInt64(vmStat.active_count) + UInt64(vmStat.inactive_count) + UInt64(vmStat.wire_count)
			guard memSize > 0 else { return 0.5 }
			return Double(used * pageSize) / Double(memSize)
		#else
			return 0.5
		#endif
	}

	/// Memory usage fraction mapped to 0-3 pressure level
	private static func memoryUsageFractionLevel() -> Int {
		let f = Self.memoryUsageFraction()
		if f < 0.3 { return 0 }
		if f < 0.5 { return 1 }
		if f < 0.7 { return 2 }
		return 3
	}
}

// MARK: - Policy Thresholds

extension RoutingPolicy {
	var thermalShiftLevel: Int {
		switch self {
		case .efficiency:   1  // shift at .fair
		case .balanced:     2  // shift at .serious
		case .performance:  3  // shift at .critical
		}
	}

	var memoryShiftLevel: Int {
		switch self {
		case .efficiency:   1  // shift at pressure level 1
		case .balanced:     2  // shift at pressure level 2
		case .performance:  3  // shift at pressure level 3
		}
	}

	var gpuWatermark: Double {
		switch self {
		case .efficiency:   0.6
		case .balanced:     0.7
		case .performance:  0.9
		}
	}
}

// MARK: - State Snapshot

/// Frozen snapshot of hardware state for observability.
/// Thermal states stored as Int (0-3) since ProcessInfo.ThermalState is not Codable.
public struct HardwareStateSnapshot: Sendable, Codable, CustomStringConvertible {
	public let thermalState: Int    // 0=nominal, 1=fair, 2=serious, 3=critical
	public let memoryPressure: Int  // 0-3 pressure level derived from memory usage fraction
	public let gpuUsageFraction: Double
	public let memoryUsageFraction: Double
	public let computeCores: Int
	public let totalCores: Int

	public var description: String {
		"Thermal: \(thermalState), Mem: \(String(format: "%.1f%%", memoryUsageFraction * 100)), " +
		"GPU: \(String(format: "%.1f%%", gpuUsageFraction * 100)), " +
		"Cores: \(computeCores)/\(totalCores)"
	}
}
