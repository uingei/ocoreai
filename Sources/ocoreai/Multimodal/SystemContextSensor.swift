// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SystemContextSensor — system-level context awareness
///
/// Monitors thermal state, memory pressure, CPU count,
/// physical memory, uptime, and low-power mode for environmental awareness.
///
/// OS version gating:
/// - macOS 15/iOS 18: thermalState, physicalMemory, processorCount,
///   memory usage via sysctl (macOS) / heuristic (iOS)
/// - macOS 26/iOS 26: ProcessInfo.thermalState (stable API),
///   memoryPressure (ProcessInfo), ProcessInfo.processInfo 增强
/// - macOS 27/iOS 27: CoreAI 推理管线可用但感知层保持不变
///
/// Produces PerceptionFrame(.system) with structured context text.
/// Cross-platform: adapts to macOS vs iOS capabilities.
/// Pattern: follows HardwareRouter sysctlbyname + nonisolated read.

import Foundation
import os.log

#if os(macOS)
import Darwin
import AppKit
#endif

private let sysLogger = Logger(subsystem: "ocoreai", category: "system_context_sensor")

// MARK: - Memory Pressure Level

enum MemoryPressureLevel: String, Sendable {
    case none, light, moderate, serious, critical, unknown

    /// Pure threshold classification (unit-testable, no system I/O).
    /// Half-open bands: <0.6 none / <0.75 light / <0.85 moderate / <0.92 serious / ≥0.92 critical.
    static func classify(usedFraction: Double) -> MemoryPressureLevel {
        if usedFraction < 0.6 { return .none }
        if usedFraction < 0.75 { return .light }
        if usedFraction < 0.85 { return .moderate }
        if usedFraction < 0.92 { return .serious }
        return .critical
    }
}

// MARK: - Sensor

@Observable
@MainActor
final class SystemContextSensor: Sendable {
    static let shared = SystemContextSensor()

    // MARK: - Public state

    var isActive: Bool = false
    var latestContext: SystemContextData?

    // MARK: - Internal

    private var _monitorTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 60  // System changes slowly

    /// Start polling system context
    func start() {
        guard !isActive else { return }
        isActive = true

        _monitorTask = Task.detached(priority: .utility) {
            await Self.shared.pollLoop()
        }

        sysLogger.info("[SystemContextSensor] started")
    }

    /// Stop polling
    @MainActor
    func stop() {
        _monitorTask?.cancel()
        _monitorTask = nil
        isActive = false
        sysLogger.info("[SystemContextSensor] stopped")
    }

    // MARK: - Polling loop

    private nonisolated func pollLoop() async {
        while !Task.isCancelled {
            let ctx = Self.readSystemContext()
            Task { @MainActor in
                Self.shared.latestContext = ctx
            }
            try? await Task.sleep(for: .seconds(Self.shared.pollInterval))
        }
    }

    // MARK: - System reads (nonisolated for performance)

    private nonisolated static func readSystemContext() -> SystemContextData {
        // Thermal state (macOS 12.5+/iOS 15.4+)
        let thermalLevel = Self.readThermalLevel()

        // Memory pressure (macOS via sysctl / iOS public API)
        let memoryPressure = Self.readMemoryPressure()

        // Memory
        let physicalMemoryGB = Self.readPhysicalMemoryGB()

        // CPU
        let processorCount = ProcessInfo.processInfo.processorCount
        let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount

        // Uptime
        let uptimeHours = Self.readUptimeHours()

        // Low power mode
        let isLowPower = Self.readLowPowerMode()

        return SystemContextData(
            thermalLevel: thermalLevel,
            memoryPressure: memoryPressure,
            physicalMemoryGB: physicalMemoryGB,
            processorCount: processorCount,
            activeProcessorCount: activeProcessorCount,
            uptimeHours: uptimeHours,
            isLowPowerMode: isLowPower
        )
    }

    // MARK: - Individual reads

    private nonisolated static func readThermalLevel() -> String {
        #if os(macOS) || os(iOS) || os(ipadOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious throttling"
        case .critical: return "critical throttling"
        @unknown default: return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    private nonisolated static func readMemoryPressure() -> String {
        #if os(macOS)
        let pressure = Self.vmPressureLevel()
        return pressure.rawValue
        #elseif os(iOS) || os(ipadOS)
        // iOS doesn't expose detailed memory pressure via public API
        return "unknown"
        #else
        return "unknown"
        #endif
    }

    #if os(macOS)
    private nonisolated static func vmPressureLevel() -> MemoryPressureLevel {
        // NOTE: `sysctlbyname("vm.page_count")` was the previous source but it is
        // (a) removed from macOS 27 (returns "unknown oid") and (b) always reported
        // total page count, not free pages — used fraction would be stuck at 0.0.
        // The mach kernel interface reports real free pages and works across macOS 12+.
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .unknown }

        var pageSize: UInt64 = 4096
        var pageSizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("vm.pagesize", &pageSize, &pageSizeLen, nil, 0)
        var hwMem: UInt64 = 0
        var hwMemLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &hwMem, &hwMemLen, nil, 0)
        guard hwMem > 0 else { return .unknown }

        // Free pages * page size gives real free bytes.
        let freeBytes = Double(UInt64(stats.free_count)) * Double(pageSize)
        let usedFraction = 1.0 - freeBytes / Double(hwMem)

        return MemoryPressureLevel.classify(usedFraction: usedFraction)
    }
    #endif

    private nonisolated static func readPhysicalMemoryGB() -> Double {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Double(bytes) / (1024.0 * 1024.0 * 1024.0)
    }

    private nonisolated static func readUptimeHours() -> Double {
        let seconds = ProcessInfo.processInfo.systemUptime
        return seconds / 3600.0
    }

    private nonisolated static func readLowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - Context text

    public func contextText() -> String {
        guard let ctx = latestContext else {
            return "[system] no context"
        }

        var parts: [String] = ["[system]"]
        parts.append("thermal=\(ctx.thermalLevel)")
        parts.append("memory=\(ctx.memoryPressure)")
        parts.append("cpu=\(ctx.activeProcessorCount)/\(ctx.processorCount)")
        parts.append("ram=\(String(format: "%.0fGB", ctx.physicalMemoryGB))")
        parts.append("uptime=\(String(format: "%.1fh", ctx.uptimeHours))")
        if ctx.isLowPowerMode {
            parts.append("low_power=YES")
        }

        return parts.joined(separator: ", ")
    }
}

// MARK: - Data model

struct SystemContextData: Sendable {
    let thermalLevel: String
    let memoryPressure: String
    let physicalMemoryGB: Double
    let processorCount: Int
    let activeProcessorCount: Int
    let uptimeHours: Double
    let isLowPowerMode: Bool
}
