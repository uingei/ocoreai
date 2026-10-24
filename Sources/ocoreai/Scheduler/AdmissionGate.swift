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

    /// Bytes per KV token this decision reserved at, and whether that price was measured off
    /// a real cache or is the unknown-model fallback. A reservation number without its basis is
    /// the kind of figure a later reader has to re-derive — AGENTS.md invariant 2 says a number
    /// carries its source, so the decision states it.
    public let kvBytesPerToken: UInt64
    /// `measured` | `fallback`.
    public let pricingBasis: String

    /// A decision priced off the model's own resident caches (`KVCachePriceLedger`).
    public static let measuredBasis = "measured"
    /// A decision priced at the floor this model has never been measured against.
    public static let unpricedBasis = "fallback"

    public init(
        admitted: Bool,
        reason: String? = nil,
        estimatedCostMB: Double,
        recommendedChannel: ComputeChannel? = nil,
        kvBytesPerToken: UInt64,
        pricingBasis: String
    ) {
        self.admitted = admitted
        self.reason = reason
        self.estimatedCostMB = estimatedCostMB
        self.recommendedChannel = recommendedChannel
        self.kvBytesPerToken = kvBytesPerToken
        self.pricingBasis = pricingBasis
    }

    /// Admitted without a new reservation — the request already holds one.
    /// Price and basis are required, not defaulted: a result that could be built without stating
    /// its basis is one that would quietly call the fallback a measurement for a model priced 10×
    /// higher.
    public static func ok(
        kvBytesPerToken: UInt64,
        pricingBasis: String
    ) -> AdmissionResult {
        .init(
            admitted: true,
            estimatedCostMB: 0,
            kvBytesPerToken: kvBytesPerToken,
            pricingBasis: pricingBasis)
    }

    public static func rejected(
        _ reason: String,
        costMB: Double = 0,
        kvBytesPerToken: UInt64,
        pricingBasis: String
    ) -> AdmissionResult {
        .init(
            admitted: false,
            reason: reason,
            estimatedCostMB: costMB,
            kvBytesPerToken: kvBytesPerToken,
            pricingBasis: pricingBasis)
    }
}

/// Pre-fill Admission Gate — actor for thread-safe budget reservation.
actor AdmissionGate {
    // MARK: - Configuration

    // The 1KB/token baseline (bits4 q4_0) lives in ``KVCacheBudget``, shared with
    // SchedulerActor — see that file for why the conversion must not trap.

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
        estimatedCost(
            inputTokens: inputTokens,
            maxOutputTokens: maxOutputTokens,
            bytesPerToken: KVCacheBudget.bytesPerToken)
    }

    /// Cost at a specific price per token — the shape the gate decides with once the model has
    /// been priced by a real cache.
    func estimatedCost(
        inputTokens: Int,
        maxOutputTokens: Int,
        bytesPerToken price: UInt64
    ) -> UInt64 {
        // Each term is floored separately: a negative output budget must not buy the request
        // a discount on the tokens it really does need (input) — and must not trap.
        KVCacheBudget.bytes(inputTokens, bytesPerToken: price)
            + KVCacheBudget.bytes(maxOutputTokens, bytesPerToken: price)
    }

    /// Which price this model gets: the one measured off its own caches, else the fallback.
    /// One home for that precedence.
    func effectiveBytesPerToken(modelId: String) async -> (price: UInt64, basis: String) {
        if let measured = await KVCachePriceLedger.shared.price(modelId: modelId), measured > 0 {
            return (UInt64(measured), AdmissionResult.measuredBasis)
        }
        return (KVCacheBudget.bytesPerToken, AdmissionResult.unpricedBasis)
    }

    /// Query available headroom from the budget + our own reservations.
    /// Returns (totalBudget, available, recommendedChannel).
    ///
    /// Headroom = `budget` − **our** reservations (`reservedBytes`), i.e. the
    /// MLX working-set cap minus what *we* have already admitted. On UMA this
    /// is exactly the admission math upstream uses (MLX `WiredMemoryManager`:
    /// "the baseline is used for admission math only"; omlx `SystemStatsSampler`
    /// reports `usedBytes = wired + active + compressed`, explicitly excluding
    /// the reclaimable inactive/file-cache bucket).
    ///
    /// We deliberately do NOT subtract the whole-machine usage
    /// (active + inactive + wired + compressed ≈ the entire system, e.g. ~20 GiB
    /// on a loaded 16 GiB box) from our 8.8 GiB cap — that mixes two unrelated
    /// quantities with two unrelated denominators and rejects *every* request
    /// the moment other apps or the file cache consume more than our cap,
    /// producing the "one chat and it dies" symptom. That is the same
    /// whole-machine-vs-our-budget conflation already fixed as advisory logging
    /// in ``MemoryTracker`` (see `checkSystemLevel` "previously … permanently
    /// stuck at .oom"). System pressure stays advisory: it drives the OOMGuard
    /// downgrade level and the routing channel — it does not gate the per-request
    /// headroom. The real OOM backstop is MLX's own `Memory.cacheLimit`.
    ///
    /// `currentUsage()` is still polled for the advisory level/logging and to
    /// feed the HardwareRouter's channel recommendation.
    private func queryHeadroom(
        priority: RequestPriority = .chat
    ) async -> (totalBudget: UInt64, available: UInt64, channel: ComputeChannel?) {
        guard let tracker = memoryTracker else {
            // No tracker — allow everything (defer to downstream OOMGuard)
            return (0, .max, nil)
        }

        // Advisory: system pressure level + recommended compute channel.
        // (currentUsage() is not part of the headroom math — see doc above.)
        _ = await tracker.currentUsage()
        let gpuActive = await tracker.gpuActiveMemoryBytes()
        let budget = await tracker.getBudget()

        // Ask HardwareRouter to recommend a compute channel (once, cached locally).
        let channel: ComputeChannel? = hardwareRouter.map {
            $0.query(gpuActiveBytes: gpuActive, gpuBudgetBytes: budget, priority: priority)
        }
        if let ch = channel {
            logger.debug("HardwareRouter → \(ch.rawValue)")
        }

        // Available = budget − our own admitted reservations (clamped to ≥0).
        let available = max(budget - reservedBytes, 0)
        return (budget, available, channel)
    }

    /// Check if a new request can be admitted.
    /// - Parameters:
    ///   - requestId: Unique request identifier.
    ///   - inputTokens: Number of input tokens in the prompt.
    ///   - maxOutputTokens: Maximum tokens the model may generate.
    ///   - modelId: Model this request will run on, so the reservation can be priced off that
    ///     model's own caches when it has been measured; `""` (an unrouted request) is unpriced.
    ///   - priority: Request priority (affects hardware routing).
    /// - Returns: AdmissionResult with decision, cost estimate, and recommended channel.
    func check(
        requestId: String,
        inputTokens: Int,
        maxOutputTokens: Int,
        modelId: String = "",
        priority: RequestPriority = .chat
    ) async -> AdmissionResult {
        let (price, basis) = await effectiveBytesPerToken(modelId: modelId)
        let cost = estimatedCost(
            inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, bytesPerToken: price)
        let costMB = Double(cost) / (1024 * 1024)

        // Already reserved for this request — allow continuation
        if reservations[requestId] != nil {
            return .ok(kvBytesPerToken: price, pricingBasis: basis)
        }

        // Jitter protection: too many concurrent pre-fills
        if activePreFills >= maxConcurrentPreFills {
            return .rejected(
                "Jitter: \(activePreFills) pre-fills active (max \(maxConcurrentPreFills))",
                costMB: costMB,
                kvBytesPerToken: price,
                pricingBasis: basis)
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
                kvBytesPerToken: price,
                pricingBasis: basis,
            )
        }

        return AdmissionResult(
            admitted: true,
            estimatedCostMB: costMB,
            recommendedChannel: channel,
            kvBytesPerToken: price,
            pricingBasis: basis)
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
        modelId: String = ""
    ) async -> Bool {
        let (price, basis) = await effectiveBytesPerToken(modelId: modelId)
        let cost = estimatedCost(
            inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, bytesPerToken: price)

        // Reserve
        reservations[requestId] = cost
        reservedBytes += cost
        activePreFills += 1

        // Visible at default log level: what this turn reserved, and on what authority. A
        // reservation priced by a guess has to read differently, in the log, from one priced off
        // the model's own cache — that difference is the point of measuring the price at all.
        let reservedMB = Int(cost / 1_048_576)
        let totalGB = Int(reservedBytes / 1_073_741_824)
        let pricing = "\(basis) \(price) B/token"
        logger.info(
            "Admitted \(requestId): \(reservedMB)MB reserved @ \(pricing) (total: \(totalGB)GB)")
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
        let totalBudget: UInt64 =
            if let tracker = memoryTracker {
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
