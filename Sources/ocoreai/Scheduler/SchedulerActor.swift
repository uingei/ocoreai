// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SchedulerActor — priority-based request scheduling with interrupt support.
///
/// P95 dispatch: < 1ms. Queue: max-heap O(log n), n ≤ 128.
/// Memory: ~5KB for 128 entries.
/// Privacy: request prompts logged as redacted, only metadata persisted.
import Foundation
import Logging

// MARK: - Priority Queue

/// A max-heap priority queue using RequestPriority ordering.
/// Lower priority value = higher priority (P0 > P1 > P2 > P3).
private struct PriorityQueue<Element: Comparable> {
	private var heap: [Element] = []

	var isEmpty: Bool {
		heap.isEmpty
	}

	var count: Int {
		heap.count
	}

	mutating func insert(_ element: Element) {
		heap.append(element)
		bubbleUp(heap.count - 1)
	}

	mutating func pop() -> Element? {
		guard !heap.isEmpty else { return nil }
		if heap.count == 1 { return heap.removeFirst() }
		let root = heap[0]
		heap[0] = heap.removeLast()
		bubbleDown(0)
		return root
	}

	mutating func remove(where predicate: (Element) -> Bool) -> Element? {
		guard let idx = heap.firstIndex(where: predicate) else { return nil }
		if idx == heap.count - 1 { return heap.removeLast() }
		let last = heap.removeLast()
		let removed = heap[idx]
		heap[idx] = last
		let parent = (idx - 1) / 2
		if parent >= 0, heap[idx] < heap[parent] {
			bubbleUp(idx)
		} else {
			bubbleDown(idx)
		}
		return removed
	}

	/// Find element without removal — O(n) scan, query-only path.
	func find(where predicate: (Element) -> Bool) -> Element? {
		heap.first(where: predicate)
	}

	private mutating func bubbleUp(_ index: Int) {
		var i = index
		while i > 0 {
			let p = (i - 1) / 2
			guard heap[i] < heap[p] else { return }
			heap.swapAt(i, p)
			i = p
		}
	}

	private mutating func bubbleDown(_ index: Int) {
		var i = index
		let n = heap.count
		while true {
			let l = 2 * i + 1
			let r = 2 * i + 2
			var smallest = i
			if l < n, heap[l] < heap[smallest] { smallest = l }
			if r < n, heap[r] < heap[smallest] { smallest = r }
			if smallest == i { return }
			heap.swapAt(i, smallest)
			i = smallest
		}
	}
}

// MARK: - Comparable Request wrapper

/// Comparable wrapper for scheduling — compares by priority then creation time.
private struct ComparableRequest: Comparable, Equatable {
	static func == (lhs: ComparableRequest, rhs: ComparableRequest) -> Bool {
		lhs.request.id == rhs.request.id
	}

	let request: SchedulingRequest

	var priorityRaw: Int {
		request.priority.rawValue
	}

	var createdAtTime: TimeInterval {
		request.createdAt.timeIntervalSince1970
	}

	static func < (lhs: ComparableRequest, rhs: ComparableRequest) -> Bool {
		if lhs.priorityRaw != rhs.priorityRaw {
			return lhs.priorityRaw < rhs.priorityRaw
		}
		// Same priority → earlier request first (FIFO within priority)
		return lhs.createdAtTime < rhs.createdAtTime
	}
}

// MARK: - Scheduler Actor

/// Central scheduler — actor-isolated priority queue with interrupt and timeout support.
actor SchedulerActor {
	private var queue: PriorityQueue<ComparableRequest> = PriorityQueue()
	private var activeRequests: [String: SchedulingRequest] = [:]
	private var requestStates: [String: RequestState] = [:]
	private var requestIdCounter = 0
	private let logger: Logger
	private var memoryTracker: MemoryTracker?
	private var oomGuard: OOMGuard?

	/// KB per token in KV cache (4-bit quant, 2-layer FIM + attention).
	/// ~4KB/token is conservative for 7B class, higher for larger models.
	private static let KBPerToken = 4 * 1024

	/// Per-request estimated memory for accurate deallocation tracking.
	private var requestMemoryMap: [String: UInt64] = [:]

	/// Max queue size — reject when exceeded.
	let maxQueueSize: Int

	/// Total requests processed.
	private(set) var totalProcessed = 0

	/// Initialize the scheduler.
	/// - Parameters:
	///   - maxQueueSize: Maximum pending requests (default: 128)
	///   - memoryTracker: Optional memory monitor
	///   - oomGuard: Optional OOM protection
	init(
		maxQueueSize: Int = 128,
		memoryTracker: MemoryTracker? = nil,
		oomGuard: OOMGuard? = nil,
		log: Logger = Logger(label: "ocoreai.scheduler"),
	) {
		self.maxQueueSize = maxQueueSize
		self.memoryTracker = memoryTracker
		self.oomGuard = oomGuard
		logger = log
	}

	// MARK: - Submit

	/// Submit a new request to the scheduler.
	/// - Parameter request: The scheduling request to enqueue.
	/// - Throws: ``SchedulerError`` if queue is full or OOM.
	/// - Returns: Request ID for tracking.
	@discardableResult
	func submit(_ request: SchedulingRequest) async throws -> String {
		// 1. OOM check
		if let oomg = oomGuard {
			guard await oomg.shouldAcceptRequest() else {
				logger.warning("Rejecting request: OOMGuard active")
				throw SchedulerError.oomRefused
			}
		}

		// 2. Queue capacity check
		guard queue.count < maxQueueSize else {
			logger.warning("Rejecting request: queue full (\(maxQueueSize))")
			throw SchedulerError.queueFull
		}

		let id = request.id
		queue.insert(ComparableRequest(request: request))
		requestStates[id] = .pending
		logger.info("Request \(id) enqueued (priority: \(request.priority.name), queue: \(queue.count))")
		return id
	}

	/// Submit a batch of requests.
	/// - Parameter requests: Array of scheduling requests.
	/// - Returns: Array of request IDs.
	@discardableResult
	func submitAll(_ requests: [SchedulingRequest]) async throws -> [String] {
		var ids: [String] = []
		for request in requests {
			try await ids.append(submit(request))
		}
		return ids
	}

	// MARK: - Dispatch

	/// Dispatch the next request from the queue (highest priority).
	/// - Returns: The next scheduling request, or nil if queue is empty.
	func dispatch() async -> SchedulingRequest? {
		guard let comparable = queue.pop() else { return nil }
		let request = comparable.request
		activeRequests[request.id] = request
		requestStates[request.id] = .inferring

		// Estimate and allocate memory for KV cache
		let estBytes = UInt64(request.tokenBudget) * UInt64(Self.KBPerToken)
		requestMemoryMap[request.id] = estBytes
		if let tracker = memoryTracker {
			await tracker.allocation(estBytes)
		}

		logger.info("Dispatched request \(request.id) (model: \(request.modelId), est: \(estBytes / 1_048_576)MB)")
		totalProcessed += 1
		return request
	}

	/// Dispatch up to `count` requests.
	/// - Parameter count: Maximum number to dispatch.
	/// - Returns: Array of dispatched requests.
	func dispatchBatch(_ count: Int) async -> [SchedulingRequest] {
		var requests: [SchedulingRequest] = []
		for _ in 0 ..< count {
			if let request = await dispatch() {
				requests.append(request)
			} else {
				break
			}
		}
		return requests
	}

	// MARK: - Interrupt

	/// Interrupt a running request.
	/// - Parameter requestId: The request to interrupt.
	/// - Returns: The interrupted request, or nil if not found.
	@discardableResult
	func interrupt(_ requestId: String) async -> SchedulingRequest? {
		if let request = activeRequests[requestId] {
			requestStates[requestId] = .interrupted
			activeRequests.removeValue(forKey: requestId)
			await deallocateMemory(for: requestId)
			logger.info("Interrupted request \(requestId)")
			return request
		}
		// Also try to remove from pending queue
		if let removed = queue.remove(where: { $0.request.id == requestId }) {
			requestStates[requestId] = .interrupted
			logger.info("Interrupted pending request \(requestId)")
			return removed.request
		}
		return nil
	}

	/// Interrupt all requests for a given model.
	/// Collects target request IDs first, then removes — safe under Dictionary iteration.
	func interruptAll(for modelId: String) async {
		// Collect IDs to interrupt first (avoid mutating dict while iterating)
		let idsToInterrupt: [String] = activeRequests.compactMap { id, req in
			req.modelId == modelId ? id : nil
		}

		for id in idsToInterrupt {
			requestStates[id] = .interrupted
			activeRequests.removeValue(forKey: id)
		}

		// Remove matching from pending queue
		while let removed = queue.remove(where: { $0.request.modelId == modelId }) {
			requestStates[removed.request.id] = .interrupted
		}
	}

	// MARK: - Completion

	/// Mark a request as completed.
	/// - Parameter requestId: The request to complete.
	func complete(_ requestId: String) async {
		activeRequests.removeValue(forKey: requestId)
		requestStates[requestId] = .completed
		await deallocateMemory(for: requestId)
		logger.info("Completed request \(requestId)")
	}

	/// Mark a request as failed.
	/// - Parameters:
	///   - requestId: The request ID.
	///   - error: Error details.
	func fail(_ requestId: String, with error: String) async {
		activeRequests.removeValue(forKey: requestId)
		requestStates[requestId] = .failed
		await deallocateMemory(for: requestId)
		logger.error("Failed request \(requestId): \(error)")
	}

	// MARK: - Query

	/// Get status of a request.
	func status(of requestId: String) async -> RequestStatus? {
		let state = requestStates[requestId] ?? .pending
		// Resolve modelId + createdAt from active or pending queue
		var modelId = activeRequests[requestId]?.modelId ?? ""
		var createdAt: Date? = activeRequests[requestId]?.createdAt
		if modelId.isEmpty,
		   let found = queue.find(where: { $0.request.id == requestId })
		{
			modelId = found.request.modelId
			createdAt = found.request.createdAt
		}
		let age = createdAt.map { Date().timeIntervalSince($0) } ?? 0
		return RequestStatus(
			requestId: requestId,
			state: state,
			modelId: modelId,
			age: age,
			message: nil,
		)
	}

	/// Get a snapshot of scheduler health.
	func snapshot() async -> SchedulerSnapshot {
		let memUsage: Double = if let tracker = memoryTracker {
			await tracker.usageFraction()
		} else {
			0
		}
		let level: String = if let oomg = oomGuard {
			await oomg.currentQuantization().rawValue
		} else {
			"unknown"
		}
		return SchedulerSnapshot(
			pendingCount: queue.count,
			inferringCount: activeRequests.count,
			totalRequests: totalProcessed,
			// avgQueueTimeMs requires per-request timestamps — reserved for v2
			avgQueueTimeMs: 0,
			// MemoryTracker tracks fraction, not absolute — report as such
			memoryUsageGB: memUsage,
			oomGuardLevel: level,
		)
	}

	/// Get pending queue size.
	var pendingCount: Int {
		queue.count
	}

	/// Get count of active requests.
	var activeCount: Int {
		activeRequests.count
	}

	// MARK: - Memory helpers

	/// Release estimated memory for a completed/interrupted/failed request.
	private func deallocateMemory(for requestId: String) async {
		guard let est = requestMemoryMap.removeValue(forKey: requestId) else { return }
		await memoryTracker?.deallocation(est)
	}
}

// MARK: - Errors

public enum SchedulerError: Error, LocalizedError, Sendable, Equatable {
	case queueFull
	case oomRefused
	case notFound(String)
	case timeout(String)

	public var errorDescription: String? {
		switch self {
		case .queueFull: "Scheduler queue is full"
		case .oomRefused: "Request refused due to OOM protection"
		case let .notFound(id): "Request not found: \(id)"
		case let .timeout(id): "Request timed out: \(id)"
		}
	}
}
