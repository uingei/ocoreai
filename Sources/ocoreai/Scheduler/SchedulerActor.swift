// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SchedulerActor — priority-based request scheduling with interrupt support.
///
/// P95 dispatch: < 1ms. Queue: max-heap O(log n), n ≤ 128.
/// Memory: ~5KB for 128 entries.
/// Privacy: request prompts logged as redacted, only metadata persisted.
///
/// Admission pipeline:
/// 1. OOMGuard.shouldAcceptRequest() — system-wide OOM guard
/// 2. AdmissionGate.check() — per-request headroom estimation
/// 3. dispatch() — pop from priority queue, reserve memory
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

/// Central scheduler — actor-isolated priority queue with interrupt, OOM guard,
/// and admission control. Triple-layer defense:
/// 1. OOMGuard — system-wide quantization downgrade chain
/// 2. AdmissionGate — per-request headroom estimation
/// 3. MemoryTracker — system-level memory pressure monitoring
actor SchedulerActor {
    private var queue: PriorityQueue<ComparableRequest> = PriorityQueue()
    private var activeRequests: [String: SchedulingRequest] = [:]
    private var requestStates: [String: RequestState] = [:]
    /// Terminal states stay queryable for the last `maxTerminalRecords` requests, then a
    /// FIFO evicts the oldest. Without the cap this actor is a leak: one row per request
    /// forever, keyed by a fresh id, in a server whose premise is that it stays up (the
    /// same pit references paid for — hermes-agent `bound the pending-created-topics
    /// cache`, `terminate provider writer threads on soft eviction`).
    private let maxTerminalRecords = 256
    private var terminalOrder: [String] = []
    private let logger: Logger
    private var memoryTracker: MemoryTracker?
    private var oomGuard: OOMGuard?
    private var admissionGate: AdmissionGate?

    // The token→byte baseline lives in ``KVCacheBudget`` — the admission gate used to carry
    // its own copy "aligned by comment", and its `UInt64(tokenCount)` conversion trapped on a
    // negative budget (measured 10-17: `{"max_tokens":-5}` took the process down with a
    // SIGTRAP from `dispatch()`). One home, and a floor that cannot trap.

    /// Per-request estimated memory for accurate deallocation tracking.
    private var requestMemoryMap: [String: UInt64] = [:]

    /// Max queue size — reject when exceeded.
    let maxQueueSize: Int

    /// Total requests processed.
    private(set) var totalProcessed = 0

    /// Total requests rejected at admission gate.
    private(set) var totalRejected = 0

    /// Total requests admitted and dispatched.
    private(set) var totalAdmitted = 0

    /// Initialize the scheduler.
    /// - Parameters:
    ///   - maxQueueSize: Maximum pending requests (default: 128)
    ///   - memoryTracker: System-level memory monitor
    ///   - oomGuard: System-wide OOM downgrade guard
    ///   - admissionGate: Per-request admission control
    init(
        maxQueueSize: Int = 128,
        memoryTracker: MemoryTracker? = nil,
        oomGuard: OOMGuard? = nil,
        admissionGate: AdmissionGate? = nil,
        log: Logger = Logger(label: "ocoreai.scheduler"),
    ) {
        self.maxQueueSize = maxQueueSize
        self.memoryTracker = memoryTracker
        self.oomGuard = oomGuard
        self.admissionGate = admissionGate
        logger = log
    }

    // MARK: - Submit

    /// Submit a new request to the scheduler.
    /// - Parameter request: The scheduling request to enqueue.
    /// - Throws: ``SchedulerError`` if OOM, no admission, or queue full.
    /// - Returns: Request ID for tracking.
    @discardableResult
    func submit(_ request: SchedulingRequest) async throws -> String {
        // 1. OOMGuard check — system-wide OOM protection
        if let oomg = oomGuard {
            guard await oomg.shouldAcceptRequest() else {
                let snap = await oomg.budgetSnapshot()
                logger.warning(
                    "Rejecting request: OOMGuard active (used \(snap.usedGB) GB / budget \(snap.budgetGB) GB)"
                )
                throw SchedulerError.oomRefused(
                    usedGB: Int(snap.usedGB),
                    budgetGB: Int(snap.budgetGB))
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
        logger.info(
            "Request \(id) enqueued (priority: \(request.priority.name), queue: \(queue.count))")
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

    /// Enqueue + admit + reserve + activate **this** request in one step: the returned
    /// request is always the one that was passed in.
    ///
    /// Ownership is by id, and that is the whole point. `dispatch()` hands out "the next
    /// best" request, and a submission is two actor messages (`submit`, then `dispatch`),
    /// so two callers arriving together interleave: the loser popped the winner's request,
    /// 503'd its own, and the stranger it dispatched sat in `activeRequests` with a live
    /// reservation and nobody to run it or release it. A request can only be started by the
    /// call that owns it.
    /// - Throws: ``SchedulerError`` on OOM, full queue, or admission refusal. Ours is then
    ///   removed from the queue and its row dropped, so no orphan survives the refusal.
    @discardableResult
    func submitAndDispatch(_ request: SchedulingRequest) async throws -> SchedulingRequest {
        try await submit(request)
        guard let dispatched = await dispatch(ownedBy: request.id) else {
            _ = queue.remove(where: { $0.request.id == request.id })
            requestStates.removeValue(forKey: request.id)
            throw SchedulerError.admissionRefused
        }
        return dispatched
    }

    // MARK: - Dispatch

    /// Dispatch the next request from the queue (highest priority).
    /// Pre-fills are admitted through the admission gate — if headroom is
    /// insufficient, the request is held and dispatch continues to lower
    /// priority requests. Only when ALL requests are rejected does dispatch
    /// return nil, allowing the caller to wait for memory.
    /// - Returns: The next scheduling request, or nil if queue is empty.
    func dispatch() async -> SchedulingRequest? {
        await dispatch(ownedBy: nil)
    }

    /// Ownership-aware dispatch: with `owner` set, only that id may leave the queue;
    /// every other candidate is put back untouched (its owner's own call will reach it).
    /// `owner == nil` is the standalone drain and keeps the "next best" semantics.
    ///
    /// Anything set aside this pass — rejected for headroom, or held for ownership — is
    /// restored before returning. The old guard for that (`rejected.count >= initialCount`)
    /// was checked at the top of an iteration the loop never reaches again, so a rejected
    /// request left the queue and was never seen again: "wait for memory" never happened.
    func dispatch(ownedBy owner: String?) async -> SchedulingRequest? {
        let initialCount = queue.count
        // Collect rejected requests separately — we must try every request
        // in priority order. A rejected high-priority request must not block
        // lower-priority requests with smaller budgets that could fit.
        var rejected: [ComparableRequest] = []
        var held: [ComparableRequest] = []

        while let comparable = queue.pop() {
            let request = comparable.request
            let requestId = request.id

            // Ownership first: before the gate, before a reservation, before `.inferring`.
            if let owner, request.id != owner {
                held.append(comparable)
                if rejected.count + held.count >= initialCount {
                    restoreSetAside(&rejected, &held)
                    break
                }
                continue
            }

            // What this turn's reservation is priced at, and on whose authority. The gate decides
            // it (measured off the model's own caches, else the floor); the dispatcher consumes
            // that same answer rather than re-deriving a second price for the same request.
            var kvBytesPerToken = KVCacheBudget.bytesPerToken
            var kvPricingBasis = AdmissionResult.unpricedBasis

            // Check admission — does this request fit in available headroom?
            if let gate = admissionGate {
                let result = await gate.check(
                    requestId: requestId,
                    inputTokens: estimateInputTokens(from: request.prompt),
                    maxOutputTokens: request.tokenBudget,
                    modelId: request.modelId,
                )
                if !result.admitted {
                    rejected.append(comparable)
                    totalRejected += 1
                    logger.info(
                        "Admission failed for \(requestId): \(result.reason ?? "budget") — (\(rejected.count)/\(initialCount) rejected this pass)"
                    )
                    // Every candidate this pass was rejected or held: nothing to dispatch,
                    // so all of them wait for memory — checked after the append, which is
                    // the only point where "all" is decidable.
                    if rejected.count + held.count >= initialCount {
                        logger.info(
                            "All queued requests rejected — re-enqueueing \(rejected.count + held.count) to wait for memory"
                        )
                        restoreSetAside(&rejected, &held)
                        break
                    }
                    continue
                }
                kvBytesPerToken = result.kvBytesPerToken
                kvPricingBasis = result.pricingBasis
            }

            // Everything set aside goes back before this one is activated; the queue
            // re-sorts by priority and arrival, so their order survives.
            restoreSetAside(&rejected, &held)

            // Admit — reserve memory for this request
            if let gate = admissionGate {
                await gate.admit(
                    requestId,
                    inputTokens: estimateInputTokens(from: request.prompt),
                    maxOutputTokens: request.tokenBudget,
                    modelId: request.modelId,
                )
                totalAdmitted += 1
            }

            // Mark active
            activeRequests[requestId] = request
            requestStates[requestId] = .inferring

            // Estimate and allocate memory for KV cache — at the price the gate just decided,
            // so the tracker's view of this turn and the gate's reservation are the same number.
            let estBytes = KVCacheBudget.bytes(
                request.tokenBudget, bytesPerToken: kvBytesPerToken)
            requestMemoryMap[requestId] = estBytes
            if let tracker = memoryTracker {
                await tracker.allocation(estBytes)
            }

            let estMB = estBytes / 1_048_576
            let pricing = "\(kvPricingBasis) \(kvBytesPerToken) B/token"
            logger.info(
                "Dispatched request \(requestId) (model: \(request.modelId), est: \(estMB)MB @ \(pricing))"
            )
            totalProcessed += 1
            return request
        }
        // The queue drained without anything being dispatched: whatever was set aside stays
        // queued. Dropping it here is how a caller's request vanished with its row left in
        // `.pending`.
        restoreSetAside(&rejected, &held)
        return nil
    }

    /// Dispatch up to `count` requests.
    /// - Parameter count: Maximum number to dispatch.
    /// - Returns: Array of dispatched requests.
    func dispatchBatch(_ count: Int) async -> [SchedulingRequest] {
        var requests: [SchedulingRequest] = []
        // `0 ..< count` traps when count is negative — a caller bug must not cost the process.
        for _ in 0 ..< Swift.max(0, count) {
            if let request = await dispatch() {
                requests.append(request)
            } else {
                break
            }
        }
        return requests
    }

    private func estimateInputTokens(from prompt: String) -> Int {
        TokenEstimate.promptTokens(prompt)
    }

    /// Put back, in one place, everything a dispatch pass took out of the queue without
    /// dispatching it.
    private func restoreSetAside(
        _ rejected: inout [ComparableRequest], _ held: inout [ComparableRequest]
    ) {
        for item in rejected {
            queue.insert(item)
        }
        for item in held {
            queue.insert(item)
        }
        rejected.removeAll()
        held.removeAll()
    }

    // MARK: - Interrupt

    /// Interrupt a running request.
    /// - Parameter requestId: The request to interrupt.
    /// - Returns: The interrupted request, or nil if not found.
    @discardableResult
    func interrupt(_ requestId: String) async -> SchedulingRequest? {
        // Release admission reservation
        if let gate = admissionGate {
            await gate.release(requestId)
        }

        if let request = activeRequests[requestId] {
            noteTerminal(requestId, .interrupted)
            activeRequests.removeValue(forKey: requestId)
            await deallocateMemory(for: requestId)
            logger.info("Interrupted request \(requestId)")
            return request
        }
        // Also try to remove from pending queue
        if let removed = queue.remove(where: { $0.request.id == requestId }) {
            noteTerminal(requestId, .interrupted)
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
            noteTerminal(id, .interrupted)
            activeRequests.removeValue(forKey: id)
            // Release admission reservation
            if let gate = admissionGate {
                await gate.release(id)
            }
            await deallocateMemory(for: id)
        }

        // Remove matching from pending queue
        while let removed = queue.remove(where: { $0.request.modelId == modelId }) {
            noteTerminal(removed.request.id, .interrupted)
        }
    }

    // MARK: - Completion

    /// Mark a request as completed.
    /// - Parameter requestId: The request to complete.
    func complete(_ requestId: String) async {
        // Release admission reservation
        if let gate = admissionGate {
            await gate.release(requestId)
        }

        activeRequests.removeValue(forKey: requestId)
        noteTerminal(requestId, .completed)
        await deallocateMemory(for: requestId)
        logger.info("Completed request \(requestId)")
    }

    /// Mark a request as failed.
    /// - Parameters:
    ///   - requestId: The request ID.
    ///   - error: Error details.
    func fail(_ requestId: String, with error: String) async {
        // Release admission reservation
        if let gate = admissionGate {
            await gate.release(requestId)
        }

        activeRequests.removeValue(forKey: requestId)
        noteTerminal(requestId, .failed)
        await deallocateMemory(for: requestId)
        logger.error("Failed request \(requestId): \(error)")
    }

    // MARK: - Query

    /// Get status of a request.
    func status(of requestId: String) async -> RequestStatus? {
        // No record ⇒ this id was never submitted, or it finished far enough back to fall
        // out of the terminal window. Answering `.pending` for it would invent a request
        // that does not exist (invariant 2: the surface never claims more than the state).
        guard let state = requestStates[requestId] else { return nil }
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
        // Memory fraction from tracker (0.0 - 1.0)
        let memFraction: Double =
            if let tracker = memoryTracker {
                await tracker.usageFraction()
            } else {
                0
            }
        // OOMGuard quantization level
        let level: String =
            if let oomg = oomGuard {
                await oomg.currentQuantization().rawValue
            } else {
                "unknown"
            }
        // Admission gate state
        var admissionReservedMB: Double = 0
        var admissionBudgetMB: Double = 0
        var admissionActive: Int = 0
        if let gate = admissionGate {
            let state = await gate.state()
            admissionReservedMB = Double(state.reserved) / 1_048_576
            admissionBudgetMB = Double(state.totalBudget) / 1_048_576
            admissionActive = state.active
        }

        return SchedulerSnapshot(
            pendingCount: queue.count,
            inferringCount: activeRequests.count,
            totalRequests: totalProcessed,
            // avgQueueTimeMs requires per-request timestamps — reserved for v2
            avgQueueTimeMs: 0,
            // MemoryTracker reports fraction (0.0-1.0), not GB
            memoryUsageFraction: memFraction,
            oomGuardLevel: level,
            // Admission gate stats if available
            admissionReservedMB: admissionReservedMB,
            admissionBudgetMB: admissionBudgetMB,
            admissionActive: admissionActive,
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

    /// Record a terminal state and keep the terminal record bounded: the id enters the FIFO
    /// once (a repeat terminal does not re-queue it), and the oldest falls out past the cap.
    private func noteTerminal(_ requestId: String, _ state: RequestState) {
        if requestStates[requestId]?.isTerminal != true {
            terminalOrder.append(requestId)
        }
        requestStates[requestId] = state
        while terminalOrder.count > maxTerminalRecords {
            requestStates.removeValue(forKey: terminalOrder.removeFirst())
        }
    }

    /// Release estimated memory for a completed/interrupted/failed request.
    private func deallocateMemory(for requestId: String) async {
        guard let est = requestMemoryMap.removeValue(forKey: requestId) else { return }
        await memoryTracker?.deallocation(est)
    }
}

// MARK: - Errors

public enum SchedulerError: Error, LocalizedError, Sendable, Equatable {
    case queueFull
    case oomRefused(usedGB: Int, budgetGB: Int)
    case admissionRefused
    case notFound(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .queueFull: "Scheduler queue is full"
        case .oomRefused(let used, let budget):
            "Request refused due to OOM protection — memory \(used) GB used of \(budget) GB budget"
        case .admissionRefused: "Request refused — insufficient admission headroom"
        case .notFound(let id): "Request not found: \(id)"
        case .timeout(let id): "Request timed out: \(id)"
        }
    }
}
