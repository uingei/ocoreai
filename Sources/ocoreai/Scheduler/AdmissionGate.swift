// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Pre-fill Admission Gate — per-request memory budget admission control.
///
/// Before any dispatch, the gate estimates the memory cost of the request
/// and checks if sufficient headroom exists. This prevents OOM mid-generation
/// by refusing large requests when budget is tight.
///
/// On Apple Silicon UMA, memory pressure is system-wide — CPU/GPU share RAM.
/// The gate uses MemoryTracker (which polls host_statistics64) as the source
/// of truth for current usage, and tracks per-request reservations on top.
///
/// Features:
/// - Per-request memory cost estimation (input + output tokens)
/// - Budget synced with MemoryTracker (single source of truth)
/// - Jitter protection: burst-limits concurrent admissions
/// - Abort margin: reserves extra headroom for emergency abort
import Foundation
import Logging

/// Result of an admission check.
///
/// In addition to admit/reject, includes a `recommendedChannel` from the
/// `HardwareRouter` so the dispatcher knows which compute accelerator
/// (GPU/ANE/CPU) should handle this request.
public struct AdmissionResult: Sendable, Codable {
	public let admitted: Bool
	public let reason: String?
	public let estimatedCostMB: Double

	/// Recommended compute channel from HardwareRouter (nil when router unavailable).
	/// The dispatcher should respect this — e.g. .ane means the request was admitted
	/// but should be routed to CoreAI/ANE rather than MLX/GPU.
	public let recommendedChannel: ComputeChannel?

	public init(
		admitted: Bool,
		reason: String? = nil,
		estimatedCostMB: Double,
		recommendedChannel: ComputeChannel? = nil
	) {
		self.admitted = admitted
		self.reason = reason
		self.estimatedCostMB = estimatedCostMB
		self.recommendedChannel = recommendedChannel
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

	/// KB per token in KV cache + activations with 4-bit quantization.
	/// Aligned with SchedulerActor.KBPerToken — 1KB/token for bits4 q4_0.
	private static let KBPerToken = 1024 // 1KB/token (bits4 q4_0)

	/// Abort margin: percentage of remaining budget to always reserve
	/// Production: 0.15. Tuning knob — increase if OOM still occurs, decrease if
	/// admission is too aggressive and rejects valid requests.
	private let abortMarginFraction: Double = 0.15

	/// Maximum concurrent pre-fills (jitter protection)
	private let maxConcurrentPreFills: Int

	// MARK: - State

	/// Currently admitted sessions and their reserved bytes
	private var reservations: [String: UInt64] = [:]

	/// Current total reserved bytes
	private var reservedBytes: UInt64 = 0

	/// Current active pre-fill count (for jitter limiting)
	private var activePreFills: Int = 0

	/// MemoryTracker reference — source of truth for system memory state
	private var memoryTracker: MemoryTracker?

	/// Hardware router — runtime compute channel recommendation
	private var hardwareRouter: HardwareRouter?

	private let logger: Logger

	// MARK: - Init

	init(
		maxConcurrentPreFills: Int = 4,
		memoryTracker: MemoryTracker?,
		hardwareRouter: HardwareRouter? = nil,
		log: Logger = Logger(label: "ocoreai.scheduler.admission"),
	) {
		self.maxConcurrentPreFills = maxConcurrentPreFills
		self.memoryTracker = memoryTracker
		self.hardwareRouter = hardwareRouter
		logger = log
	}

	// MARK: - Budget Update

	/// Link or re-link to a MemoryTracker.
	func setMemoryTracker(_ tracker: MemoryTracker?) {
		memoryTracker = tracker
	}

	/// Link or re-link to a HardwareRouter.
	func setHardwareRouter(_ router: HardwareRouter?) {
		hardwareRouter = router
	}

	// MARK: - Admission

	/// Estimate memory cost for a request (KV cache for input + output tokens).
	/// - Parameters:
	///   - inputTokens: Number of input/prompt tokens.
	///   - maxOutputTokens: Maximum number of generated tokens.
	/// - Returns: Estimated bytes needed.
	func estimatedCost(inputTokens: Int, maxOutputTokens: Int) -> UInt64 {
		let totalTokens = inputTokens + maxOutputTokens
		return UInt64(totalTokens) * UInt64(Self.KBPerToken)
	}

	/// Query available headroom from MemoryTracker + our reservations.
	/// Returns (totalBudget, availableHeadroom, recommendedChannel).
	///
	/// On Apple Silicon UMA, system memory from `pollSystemMemory()` already
	/// includes GPU pressure (CPU/GPU share physical RAM), so we do NOT add
	/// `gpuActiveBytes` again — that would double-count GPU pressure.
	/// We only query gpuActive for the HardwareRouter's channel recommendation.
	///
	/// The `recommendedChannel` from `HardwareRouter` tells us which
	/// compute accelerator should handle the request — this is the bridge
	/// between "can we admit?" and "where should it run?".
	private func queryHeadroom(
		priority: RequestPriority = .chat
	) async -> (totalBudget: UInt64, available: UInt64, channel: ComputeChannel?) {
		guard let tracker = memoryTracker else {
			// No tracker — allow everything (defer to downstream OOMGuard)
			return (0, .max, nil)
		}

		// Query system memory state from tracker
		let systemUsed = await tracker.currentUsage()
		let gpuActive = await tracker.gpuActiveMemoryBytes()
		let budget = await tracker.getBudget()

		// Ask HardwareRouter to recommend a compute channel (once, cached locally)
		let channel: ComputeChannel? = hardwareRouter.map {
			$0.query(gpuActiveBytes: gpuActive, gpuBudgetBytes: budget, priority: priority)
		}

		if let ch = channel {
			logger.debug("HardwareRouter → \(ch.rawValue)")
		}

		// Total pressure: system usage (already includes GPU on UMA) + our reservations.
		// On UMA, gpuActiveBytes is already part of systemUsed — adding it again
		// would double-count GPU pressure and cause legitimate requests to be rejected.
		let used = systemUsed + reservedBytes

		// Available after accounting for reservations
		let available = max(budget - used, 0)
		return (budget, available, channel)
	}

	/// Check if a new request can be admitted.
	/// - Parameters:
	///   - requestId: Unique request identifier.
	///   - inputTokens: Number of input tokens in the prompt.
	///   - maxOutputTokens: Maximum tokens the model may generate.
	///   - priority: Request priority (affects hardware routing).
	/// - Returns: AdmissionResult with decision, cost estimate, and recommended channel.
	func check(
		requestId: String,
		inputTokens: Int,
		maxOutputTokens: Int,
		priority: RequestPriority = .chat
	) async -> AdmissionResult {
		let cost = estimatedCost(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens)
		let costMB = Double(cost) / (1024 * 1024)

		// Already reserved for this request — allow continuation
		if reservations[requestId] != nil {
			return .ok
		}

		// Jitter protection: too many concurrent pre-fills
		if activePreFills >= maxConcurrentPreFills {
			return .rejected("Jitter: \(activePreFills) pre-fills active (max \(maxConcurrentPreFills))", costMB: costMB)
		}

		// Query headroom from system + our reservations + hardware router
		let (_, available, channel) = await queryHeadroom(priority: priority)

		// Calculate effective headroom after abort margin
		let abortMargin = UInt64(Double(available) * abortMarginFraction)
		let effectiveHeadroom = available - abortMargin

		// Check: does the request fit within headroom?
		if cost > effectiveHeadroom {
			let headroomMB = Double(effectiveHeadroom) / (1024 * 1024)
			return .rejected(
				"Budget: need \(String(format: "%.0f", costMB))MB, headroom \(String(format: "%.0f", headroomMB))MB",
				costMB: costMB,
			)
		}

		return AdmissionResult(admitted: true, estimatedCostMB: costMB, recommendedChannel: channel)
	}

	/// Admit a request — reserve its memory cost.
	/// - Parameters:
	///   - requestId: Unique request identifier.
	///   - inputTokens: Number of input tokens.
	///   - maxOutputTokens: Maximum output tokens.
	/// - Returns: true if admission succeeded.
	@discardableResult
	func admit(
		_ requestId: String,
		inputTokens: Int,
		maxOutputTokens: Int,
	) -> Bool {
		let cost = estimatedCost(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens)

		// Reserve
		reservations[requestId] = cost
		reservedBytes += cost
		activePreFills += 1

		logger.debug("Admitted \(requestId): \(Int(cost / 1_048_576))MB reserved (total: \(Int(reservedBytes / 1_073_741_824))GB)")
		return true
	}

	/// Release a request's reservation (normal completion or abort).
	/// - Parameter requestId: Request to release.
	func release(_ requestId: String) {
		if let cost = reservations.removeValue(forKey: requestId) {
			reservedBytes = max(reservedBytes - cost, 0)
			activePreFills = max(0, activePreFills - 1)
			logger.debug("Released \(requestId): freed \(Double(cost) / 1_048_576)MB")
		}
	}

	/// Emergency abort — release all reservations immediately.
	/// Called when OOMGuard signals .oom level.
	func emergencyAbort() {
		let totalFreed = reservedBytes
		reservations.removeAll()
		reservedBytes = 0
		activePreFills = 0
		logger.warning("Emergency abort: freed \(Double(totalFreed) / 1_073_741_824)GB total")
	}

	// MARK: - Inspection

	/// Current admission state for monitoring.
	func state() async -> (reserved: UInt64, totalBudget: UInt64, active: Int, requests: Int) {
		let totalBudget: UInt64 = if let tracker = memoryTracker {
			await tracker.getBudget()
		} else {
			0
		}
		return (
			reserved: reservedBytes,
			totalBudget: totalBudget,
			active: activePreFills,
			requests: reservations.count,
		)
	}
}
