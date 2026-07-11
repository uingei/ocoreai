// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HardwareRouterMirrorTests.swift — Mirror fixture for HardwareRouter routing logic.
/// Tests the pure routing function and policy thresholds without system calls.
///
/// Coverage: HardwareRouter.route(), thermalLevel(), RoutingPolicy thresholds,
/// ComputeChannel mapping, ThermalPressureEvent, HardwareStateSnapshot.
///
/// Rationale: HardwareRouter had 3 data-flow-disconnect fixes in July (P0 wiring,
/// dispatch break, routing chain gap). Mirror fixture prevents regression.

import Foundation
import Testing
@testable import ocoreai

// MARK: - Policy threshold tests

@Suite("RoutingPolicy thresholds")
struct RoutingPolicyThresholdTests {
    @Test("Balanced: thermal shift at level 2 (serious)")
    func balancedThermal() {
        #expect(RoutingPolicy.balanced.thermalShiftLevel == 2)
    }

    @Test("Efficiency: thermal shift at level 1 (fair)")
    func efficiencyThermal() {
        #expect(RoutingPolicy.efficiency.thermalShiftLevel == 1)
    }

    @Test("Performance: thermal shift at level 3 (critical)")
    func performanceThermal() {
        #expect(RoutingPolicy.performance.thermalShiftLevel == 3)
    }

    @Test("Balanced: memory shift at level 2")
    func balancedMemory() {
        #expect(RoutingPolicy.balanced.memoryShiftLevel == 2)
    }

    @Test("Efficiency: memory shift at level 1")
    func efficiencyMemory() {
        #expect(RoutingPolicy.efficiency.memoryShiftLevel == 1)
    }

    @Test("Balanced: GPU watermark at 0.7")
    func balancedGPUWatermark() {
        #expect(RoutingPolicy.balanced.gpuWatermark == 0.7)
    }

    @Test("Efficiency: GPU watermark at 0.6")
    func efficiencyGPUWatermark() {
        #expect(RoutingPolicy.efficiency.gpuWatermark == 0.6)
    }

    @Test("Performance: GPU watermark at 0.9")
    func performanceGPUWatermark() {
        #expect(RoutingPolicy.performance.gpuWatermark == 0.9)
    }
}

// MARK: - Thermal level mapping

@Suite("HardwareRouter.thermalLevel mapping")
struct ThermalLevelTests {
    @Test("Nominal maps to 0")
    func nominal() {
        #expect(HardwareRouter.thermalLevel(.nominal) == 0)
    }

    @Test("Fair maps to 1")
    func fair() {
        #expect(HardwareRouter.thermalLevel(.fair) == 1)
    }

    @Test("Serious maps to 2")
    func serious() {
        #expect(HardwareRouter.thermalLevel(.serious) == 2)
    }

    @Test("Critical maps to 3")
    func critical() {
        #expect(HardwareRouter.thermalLevel(.critical) == 3)
    }
}

// MARK: - Pure routing function

@Suite("HardwareRouter.route() — pure routing decisions")
struct RoutingDecisionTests {
    // Tier 1: Memory pressure forces CPU
    @Test("Tier 1: Memory pressure ≥ policy threshold → CPU (balanced)")
    func memoryPressureForcesCPU() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 2,       // balanced threshold = 2
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("Tier 1: Memory pressure below threshold → continues")
    func memoryPressureBelowThreshold() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 1,       // below balanced threshold 2
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .gpu)
    }

    // Tier 2: Thermal shift
    @Test("Tier 2: Thermal at balanced threshold → ANE")
    func thermalShiftToANE() {
        let channel = HardwareRouter.route(
            thermal: .serious,       // level 2 = balanced threshold
            memoryPressure: 1,
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .ane)
    }

    @Test("Tier 2: Thermal critical (level 3) → CPU")
    func thermalCriticalForcesCPU() {
        let channel = HardwareRouter.route(
            thermal: .critical,      // level 3
            memoryPressure: 0,
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("Tier 2: Urgent bypass stays GPU at moderate thermal")
    func urgentBypassStaysGPU() {
        let channel = HardwareRouter.route(
            thermal: .serious,       // level 2 < 3
            memoryPressure: 0,
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: true)
        #expect(channel == .gpu)
    }

    @Test("Tier 2: Urgent bypass still shifts at critical")
    func urgentBypassStillShiftsAtCritical() {
        let channel = HardwareRouter.route(
            thermal: .critical,      // level 3, bypass doesn't help
            memoryPressure: 0,
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: true)
        #expect(channel == .cpu)
    }

    // Tier 3: GPU saturation
    @Test("Tier 3: GPU fraction > balanced watermark (0.7) → ANE")
    func gpuSaturationShiftsToANE() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 0,
            gpuFraction: 0.75,       // > 0.7 balanced watermark
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .ane)
    }

    @Test("Tier 3: GPU fraction below watermark → stays GPU")
    func gpuBelowWatermark() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 0,
            gpuFraction: 0.5,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .gpu)
    }

    // Default: healthy conditions → GPU
    @Test("Default: all healthy → GPU")
    func healthyCondition() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 0,
            gpuFraction: 0.3,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .gpu)
    }

    // Policy comparisons
    @Test("Policy: performance stays GPU longer (thermal serious, low memory)")
    func performanceStaysGPU() {
        let channel = HardwareRouter.route(
            thermal: .serious,       // performance threshold = 3
            memoryPressure: 1,       // performance threshold = 3
            gpuFraction: 0.8,        // performance watermark = 0.9
            policy: .performance,
            urgentBypass: false)
        #expect(channel == .gpu)
    }

    @Test("Policy: efficiency shifts earlier (thermal fair)")
    func efficiencyShiftsEarly() {
        let channel = HardwareRouter.route(
            thermal: .fair,          // efficiency threshold = 1
            memoryPressure: 0,
            gpuFraction: 0.3,
            policy: .efficiency,
            urgentBypass: false)
        #expect(channel == .ane)
    }
}

// MARK: - Data model tests

@Suite("ThermalPressureEvent")
struct ThermalPressureEventTests {
    @Test("Description contains from→to and trigger")
    func descriptionFormat() {
        let event = ThermalPressureEvent(
            from: .gpu,
            to: .ane,
            trigger: "thermal",
            timestamp: Date()
        )
        #expect(event.description.contains("gpu"))
        #expect(event.description.contains("ane"))
        #expect(event.description.contains("thermal"))
    }

    @Test("Codable round-trip")
    func Codable() throws {
        let event = ThermalPressureEvent(
            from: .gpu,
            to: .cpu,
            trigger: "memory",
            timestamp: Date())
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ThermalPressureEvent.self, from: data)
        #expect(decoded.from == .gpu)
        #expect(decoded.to == .cpu)
        #expect(decoded.trigger == "memory")
    }
}

@Suite("HardwareStateSnapshot")
struct HardwareStateSnapshotTests {
    @Test("Description contains all fields")
    func descriptionContainsAllFields() {
        let snap = HardwareStateSnapshot(
            thermalState: 2,
            memoryPressure: 1,
            gpuUsageFraction: 0.65,
            memoryUsageFraction: 0.45,
            computeCores: 8,
            totalCores: 10)
        let desc = snap.description
        #expect(desc.contains("Thermal"))
        #expect(desc.contains("GPU"))
        #expect(desc.contains("Cores"))
    }

    @Test("Codable round-trip (thermalState as Int, not ThermalState)")
    func Codable() throws {
        let snap = HardwareStateSnapshot(
            thermalState: 3,
            memoryPressure: 2,
            gpuUsageFraction: 0.8,
            memoryUsageFraction: 0.6,
            computeCores: 10,
            totalCores: 12)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(HardwareStateSnapshot.self, from: data)
        #expect(decoded.thermalState == 3)
        #expect(decoded.gpuUsageFraction == 0.8)
    }
}

@Suite("ComputeChannel")
struct ComputeChannelTests {
    @Test("All cases are present")
    func caseCount() {
        #expect(ComputeChannel.allCases.count == 3)
    }

    @Test("Raw values map correctly")
    func rawValues() {
        #expect(ComputeChannel.gpu.rawValue == "gpu")
        #expect(ComputeChannel.ane.rawValue == "ane")
        #expect(ComputeChannel.cpu.rawValue == "cpu")
    }

    @Test("Codable round-trip")
    func Codable() throws {
        let ch = ComputeChannel.ane
        let data = try JSONEncoder().encode(ch)
        let decoded = try JSONDecoder().decode(ComputeChannel.self, from: data)
        #expect(decoded == .ane)
    }
}

// MARK: - Tier ordering verification (regression gate)

@Suite("Routing tier precedence — regression for P0 data-flow-disconnect fixes")
struct RoutingTierPrecedenceTests {
    @Test("Memory pressure overrides thermal (Tier 1 > Tier 2)")
    func memoryBeatThermal() {
        let channel = HardwareRouter.route(
            thermal: .critical,      // would shift to CPU normally
            memoryPressure: 3,       // memory forces CPU first — same result here
            gpuFraction: 0.9,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("Memory pressure overrides GPU saturation (Tier 1 > Tier 3)")
    func memoryBeatGPU() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 2,       // balanced threshold — forces CPU
            gpuFraction: 0.95,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("Urgent bypass only affects thermal tier, not memory tier")
    func bypassNotEffectiveForMemory() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 3,       // forces CPU regardless
            gpuFraction: 0.1,
            policy: .balanced,
            urgentBypass: true)
        #expect(channel == .cpu)
    }
}
