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
    case gpu
    /// GPU via MLX (Metal) — dynamic graph, best dev experience
    case ane
    /// ANE via CoreAI — static graph, 10x energy efficiency
    case cpu/// CPU fallback — lowest performance, most resilient
}

// MARK: - Routing Policy

/// How aggressively the router responds to adverse conditions.
public enum RoutingPolicy: String, Codable, Sendable, CaseIterable {
    case balanced  // Default: shift at thermal.serious or GPU >70%
    case performance  // Stay GPU longer: shift only at thermal.critical or GPU >90%
    case efficiency  // Aggressive: shift at thermal.fair or GPU >60%
}

extension ComputeChannel {
    /// Maps to CoreAI `ComputeTarget.Kind` for specialization.
    #if canImport(CoreAI)
    @available(macOS 27.0, iOS 27.0, *)
    public var computeTargetKind: ComputeTarget.Kind {
        switch self {
        case .gpu: .gpu
        case .ane: .neuralEngine
        case .cpu: .cpu
        }
    }
    #endif

    // MARK: - UI Badge helpers

    /// SF Symbol name for the badge.
    public var badgeIcon: String {
        switch self {
        case .gpu: "bolt.fill"
        case .ane: "brain.fill"
        case .cpu: "cpu"
        }
    }

    /// Human-readable label for the badge.
    public var badgeLabel: String {
        switch self {
        case .gpu: "GPU"
        case .ane: "ANE"
        case .cpu: "CPU"
        }
    }
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
    public func setThermalCallback(
        _ callback: @escaping @Sendable (ThermalPressureEvent) async -> Void
    ) {
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

            // Advisory only: this is a machine-level transition. What it costs is
            // decided by the consumer, which corroborates against its own
            // footprint (EnginePool) — the reading can come entirely from other
            // processes' wired GPU pages.
            self.logger.warning(
                "Pressure watch (\(event.trigger)): lane advisory \(event.from.rawValue) → \(event.to.rawValue) (degradation gated on corroborated footprint)"
            )
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
    public func setThermalCallback(
        _ callback: @escaping @Sendable (ThermalPressureEvent) async -> Void
    ) {
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
        let gpuFraction: Double =
            gpuBudgetBytes > 0
            ? Double(gpuActiveBytes) / Double(gpuBudgetBytes)
            : 0.0

        // Interrupt requests bypass ANE (avoid specialization latency)
        let urgentBypass = priority == .interrupt

        // Corroborate machine-wide pressure against our own footprint before
        // degrading the request (see pressureIsOurs).
        let ours = Self.pressureIsOurs(
            gpuFraction: gpuFraction,
            reclaimableBytes: Self.reclaimableMemoryBytes(),
            memSizeBytes: Self.physicalMemoryBytes()
        )

        return Self.route(
            thermal: thermal,
            memoryPressure: memoryPressure,
            gpuFraction: gpuFraction,
            policy: policy,
            urgentBypass: urgentBypass,
            pressureIsOurs: ours
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
        urgentBypass: Bool,
        pressureIsOurs: Bool = true
    ) -> ComputeChannel {
        // Tier 1: Memory pressure — force the degraded lane if severe AND ours.
        // Uncorroborated machine pressure must not cost this request its prefix
        // cache: bypassing the session pool re-creates KV per request (more
        // allocation churn, slower first token) without releasing the foreign
        // memory that caused the reading.
        let memShiftLevel = policy.memoryShiftLevel
        if memoryPressure >= memShiftLevel, pressureIsOurs {
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
        case .nominal: 0
        case .fair: 1
        case .serious: 2
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

    /// One `host_statistics64` read, shared by every memory signal here so the
    /// router never mixes counts sampled at different instants.
    struct VMPageCounts: Sendable {
        let free: UInt64
        let inactive: UInt64
        let speculative: UInt64
        let active: UInt64
        let wire: UInt64
        let compressor: UInt64
        let pageSize: UInt64
        let memSize: UInt64
    }

    /// nil when the kernel query fails — callers must treat unknown as unknown,
    /// never as zero pressure.
    static func vmPageCounts() -> VMPageCounts? {
        #if os(macOS) || os(iOS)
        var pageSize: UInt64 = 4096
        var size1 = MemoryLayout<Int>.size
        sysctlbyname("vm.pagesize", &pageSize, &size1, nil, 0)

        // vm_statistics64: required by HOST_VM_INFO64 (host_statistics64 expects
        // the 64-bit layout, which also carries compressor_page_count). Using the
        // 32-bit vm_statistics here is a type-contract violation (UB) and silently
        // drops compressed-page accounting. Reference: omlx SystemStatsSampler.swift.
        var vmStat = vm_statistics64()
        var count: mach_msg_type_number_t = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let kr = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var memSize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &len, nil, 0)

        return VMPageCounts(
            free: UInt64(vmStat.free_count),
            inactive: UInt64(vmStat.inactive_count),
            speculative: UInt64(vmStat.speculative_count),
            active: UInt64(vmStat.active_count),
            wire: UInt64(vmStat.wire_count),
            compressor: UInt64(vmStat.compressor_page_count),
            pageSize: pageSize,
            memSize: memSize
        )
        #else
        return nil
        #endif
    }

    @inline(__always)
    static func memoryUsageFraction() -> Double {
        guard let c = Self.vmPageCounts() else { return 0.5 }
        // 仅把「不可回收」的物理页计入压力：active + wire + compressor 占用。
        //
        // 关键：inactive_count 是内核可随时回收的文件缓存（磁盘缓存，
        // demand-paging 可即时换回），不产生真实内存压力。把它计入"已用"会把
        // 现代 macOS 稳态（inactive 缓存常态数 GB）误判为高压力 —— 实测本机
        // inactive≈4.0G 时，含它=79% (L3，强制 CPU) vs 剔它=49.5% (L1, 走 GPU)，
        // 直接把 GPU 优先路由架空成恒定 CPU。真实压力下系统会 purge inactive
        // 缓存（active 涨 / inactive 跌），所以剔它不掩盖真压力。
        // compressor_page_count 保留：它是压缩页真实占用的物理 RAM（虽可回收，
        // 但保守计入压力）。参考 omlx SystemStatsSampler.swift 的 vm_statistics64 用法。
        return Self.usedFraction(
            active: c.active,
            wire: c.wire,
            compressor: c.compressor,
            pageSize: c.pageSize,
            memSize: c.memSize
        )
    }

    /// Physical RAM the process could still be handed: free + inactive +
    /// speculative pages, i.e. everything the kernel can reclaim without paging
    /// out live anonymous memory. `purgeable_count` is deliberately NOT added —
    /// purgeable pages already live in the inactive queue, so adding it here
    /// would double-count them.
    ///
    /// nil when the kernel query fails (caller decides the conservative default).
    static func reclaimableMemoryBytes() -> UInt64? {
        guard let c = Self.vmPageCounts() else { return nil }
        return (c.free + c.inactive + c.speculative) * c.pageSize
    }

    /// Total physical RAM, 0 when unavailable.
    static func physicalMemoryBytes() -> UInt64 {
        Self.vmPageCounts()?.memSize ?? 0
    }

    /// Is whole-machine memory pressure actually ours to relieve?
    ///
    /// The system "used" fraction counts `wire_count`, and on Apple Silicon that
    /// includes GPU-wired pages belonging to EVERY process. One foreign process
    /// holding RAM therefore reads as critical pressure here while ocoreai's own
    /// footprint sits comfortably inside its budget. Observed 10-12 on a 128 GB
    /// host: a stray python/MLX process holding ~79 GB put the machine at ~74 %
    /// used (level 3) while this app used 3.5 GB of a 70 GB budget — and the
    /// uncorroborated verdict cost prefix-cache reuse plus speculation on every
    /// request, spending throughput without giving back the memory that mattered.
    ///
    /// Corroborate with our own numbers instead:
    /// - we hold ≥ half of our own budget (`gpuFraction` here is
    ///   our-active-bytes ÷ our-budget, not a machine ratio), or
    /// - the machine genuinely cannot hand us memory: reclaimable bytes below
    ///   max(1 GiB, physical/16).
    /// Unknown inputs count as ours — when we cannot tell, protect memory.
    static func pressureIsOurs(
        gpuFraction: Double,
        reclaimableBytes: UInt64?,
        memSizeBytes: UInt64
    ) -> Bool {
        if gpuFraction >= 0.5 { return true }
        guard let reclaimable = reclaimableBytes, memSizeBytes > 0 else { return true }
        return reclaimable < max(1024 * 1024 * 1024, memSizeBytes / 16)
    }

    /// Pure memory-occupancy fraction, decoupled from live sysctl reads so it
    /// is unit-testable without a specific machine.
    ///
    /// Counts only high-cost / non-reclaimable physical occupancy:
    /// - `active`   — anonymous (real RAM) + referenced file pages
    /// - `wire`     — kernel-pinned, non-reclaimable
    /// - `compressor` — compressed anonymous, reclaimable but costly
    ///
    /// Deliberately EXCLUDES `inactive` (reclaimable file/disk cache) — see
    /// the caller for the full rationale and the measured L3→L1 impact.
    static func usedFraction(
        active: UInt64,
        wire: UInt64,
        compressor: UInt64,
        pageSize: UInt64,
        memSize: UInt64
    ) -> Double {
        guard memSize > 0 else { return 0.5 }
        return Double((active + wire + compressor) * pageSize) / Double(memSize)
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
        case .efficiency: 1  // shift at .fair
        case .balanced: 2  // shift at .serious
        case .performance: 3  // shift at .critical
        }
    }

    var memoryShiftLevel: Int {
        switch self {
        case .efficiency: 1  // shift at pressure level 1
        case .balanced: 2  // shift at pressure level 2
        case .performance: 3  // shift at pressure level 3
        }
    }

    var gpuWatermark: Double {
        switch self {
        case .efficiency: 0.6
        case .balanced: 0.7
        case .performance: 0.9
        }
    }
}

// MARK: - State Snapshot

/// Frozen snapshot of hardware state for observability.
/// Thermal states stored as Int (0-3) since ProcessInfo.ThermalState is not Codable.
public struct HardwareStateSnapshot: Sendable, Codable, CustomStringConvertible {
    public let thermalState: Int  // 0=nominal, 1=fair, 2=serious, 3=critical
    public let memoryPressure: Int  // 0-3 pressure level derived from memory usage fraction
    public let gpuUsageFraction: Double
    public let memoryUsageFraction: Double
    public let computeCores: Int
    public let totalCores: Int

    public var description: String {
        "Thermal: \(thermalState), Mem: \(String(format: "%.1f%%", memoryUsageFraction * 100)), "
            + "GPU: \(String(format: "%.1f%%", gpuUsageFraction * 100)), "
            + "Cores: \(computeCores)/\(totalCores)"
    }
}
