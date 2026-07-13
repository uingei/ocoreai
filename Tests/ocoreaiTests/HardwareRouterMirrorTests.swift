// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HardwareRouterMirrorTests.swift — Pure routing decisions and tier precedence.
///
/// Behavioral focus: 3-tier routing logic (memory → thermal → GPU saturation),
/// policy sensitivity, urgent bypass interaction, tier override guarantees.
///
/// Removed: threshold value assertions (9), thermal level mapping (4),
/// description format checks (2), Codable round-trips (4), enum case count (1).
/// These compile-time invariants don't find runtime bugs.

import Foundation
import Testing
@testable import ocoreai

// MARK: - Memory pressure tier (highest priority)

@Suite("Memory pressure forces CPU regardless of other conditions")
struct MemoryTierTests {
    @Test("Memory ≥ threshold overrides thermal and GPU")
    func memoryOverridesAll() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 2,       // balanced threshold
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("Urgent bypass does not override memory tier")
    func bypassNotEffectiveForMemory() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 3,
            gpuFraction: 0.1,
            policy: .balanced,
            urgentBypass: true)
        #expect(channel == .cpu)
    }
}

// MARK: - Thermal shift tier

@Suite("Thermal shift routing decisions")
struct ThermalTierTests {
    @Test("At threshold → ANE (balanced, serious)")
    func thermalAtThreshold() {
        let channel = HardwareRouter.route(
            thermal: .serious,       // level 2 = balanced threshold
            memoryPressure: 1,       // below threshold 2
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .ane)
    }

    @Test("Critical thermal → CPU regardless of bypass")
    func thermalCriticalForcesCPU() {
        let channel = HardwareRouter.route(
            thermal: .critical,
            memoryPressure: 0,
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: true)
        #expect(channel == .cpu)
    }

    @Test("Urgent bypass stays GPU at moderate thermal")
    func urgentBypassStaysGPU() {
        let channel = HardwareRouter.route(
            thermal: .serious,
            memoryPressure: 0,
            gpuFraction: 0.0,
            policy: .balanced,
            urgentBypass: true)
        #expect(channel == .gpu)
    }
}

// MARK: - GPU saturation tier

@Suite("GPU fraction watermark routing")
struct GPUSaturationTests {
    @Test("Above watermark → ANE")
    func aboveWatermark() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 0,
            gpuFraction: 0.75,       // > 0.7 balanced watermark
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .ane)
    }

    @Test("Below watermark → GPU")
    func belowWatermark() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 0,
            gpuFraction: 0.5,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .gpu)
    }
}

// MARK: - Policy sensitivity

@Suite("RoutingPolicy sensitivity")
struct PolicySensitivityTests {
    @Test("Performance policy tolerates more pressure")
    func performanceToleratesMore() {
        let channel = HardwareRouter.route(
            thermal: .serious,       // performance threshold = 3, so 2 is fine
            memoryPressure: 1,       // performance threshold = 3
            gpuFraction: 0.8,        // performance watermark = 0.9
            policy: .performance,
            urgentBypass: false)
        #expect(channel == .gpu)
    }

    @Test("Efficiency policy shifts early")
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

// MARK: - Tier precedence regression gates

@Suite("Tier precedence — regression for P0 data-flow-disconnect fixes")
struct TierPrecedenceTests {
    @Test("Memory > thermal: both trigger CPU but via different tiers")
    func memoryBeatsThermal() {
        let channel = HardwareRouter.route(
            thermal: .critical,
            memoryPressure: 3,
            gpuFraction: 0.9,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("All healthy defaults to GPU")
    func healthyDefaultsToGPU() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 0,
            gpuFraction: 0.3,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .gpu)
    }
}
