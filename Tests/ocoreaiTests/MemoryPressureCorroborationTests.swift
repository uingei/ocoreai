// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MemoryPressureCorroborationTests — 整机内存压力必须先与**自己**的占用对账，
/// 才允许花钱（丢前缀缓存 / 关投机解码）。
///
/// 实机起因（10-12，M5 Max / 128 GB）：一个游离的 python/MLX 进程占着 ~79 GB，
/// `memoryUsageFraction()` 因此读到 ~74% ⇒ level 3 ⇒ `route()` Tier-1 判 `.cpu`
/// ⇒ 每个请求绕过 SessionPool（KV 每轮重建）+ 关投机解码；而 ocoreai 自己只用
/// 3.5 GB / 70 GB 预算。Apple Silicon 的 `wire_count` 含**所有进程**的 GPU 锁定页，
/// 所以这个数字本身证明不了「是我们的压力」——它既没换来内存，又把吞吐花了。
/// 本文件钉纯函数契约：`pressureIsOurs` 的边界 + `route()` 在对账不过时不得降级。

#if os(macOS) || os(iOS)
import Foundation
import Testing

@testable import ocoreai

private let GiB: UInt64 = 1024 * 1024 * 1024

@Suite("Memory pressure corroboration", .serialized)
struct MemoryPressureCorroborationTests {

    @Test("foreign hog: 5 % of our budget + ample reclaimable ⇒ not ours")
    func foreignHogIsNotOurPressure() {
        // 实测本机: ours 3.5 / 70.4 GB, reclaimable ≈ 28 GB, physical 128 GB
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 3.5 / 70.4,
                reclaimableBytes: 28 * GiB,
                memSizeBytes: 128 * GiB) == false)
    }

    @Test("holding half our own budget is ours (boundary inclusive)")
    func ownHalfBudgetIsOurs() {
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.5,
                reclaimableBytes: 64 * GiB,
                memSizeBytes: 128 * GiB) == true)
    }

    @Test("just under half our budget with ample reclaimable ⇒ not ours")
    func justUnderHalfIsNotOurs() {
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.49,
                reclaimableBytes: 64 * GiB,
                memSizeBytes: 128 * GiB) == false)
    }

    @Test("machine cannot hand us memory ⇒ ours, even at 5 % of budget")
    func scarceMachineIsOurs() {
        // floor = max(1 GiB, 128 GiB / 16 = 8 GiB) = 8 GiB; 0.5 GiB < floor
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.05,
                reclaimableBytes: GiB / 2,
                memSizeBytes: 128 * GiB) == true)
    }

    @Test("scarce floor is machine-scaled (1 GiB floor on an 8 GiB host)")
    func scarceFloorScalesWithMachine() {
        // floor = max(1 GiB, 8 GiB / 16 = 0.5 GiB) = 1 GiB
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.05,
                reclaimableBytes: 2 * GiB,
                memSizeBytes: 8 * GiB) == false)
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.05,
                reclaimableBytes: GiB / 2,
                memSizeBytes: 8 * GiB) == true)
    }

    @Test("unknown inputs protect memory (count as ours)")
    func unknownCountsAsOurs() {
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.05,
                reclaimableBytes: nil,
                memSizeBytes: 128 * GiB) == true)
        #expect(
            HardwareRouter.pressureIsOurs(
                gpuFraction: 0.05,
                reclaimableBytes: 64 * GiB,
                memSizeBytes: 0) == true)
    }

    @Test("severe-but-foreign pressure keeps the fast lane")
    func routeStaysGPUWhenNotOurs() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 3,
            gpuFraction: 0.05,
            policy: .balanced,
            urgentBypass: false,
            pressureIsOurs: false)
        #expect(channel == .gpu)
    }

    @Test("the same reading when it IS ours still degrades (both directions pinned)")
    func routeDegradesWhenOurs() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 3,
            gpuFraction: 0.9,
            policy: .balanced,
            urgentBypass: false,
            pressureIsOurs: true)
        #expect(channel == .cpu)
    }

    @Test("corroboration never masks thermal: serious heat still leaves GPU")
    func thermalStillApplies() {
        let channel = HardwareRouter.route(
            thermal: .serious,
            memoryPressure: 3,
            gpuFraction: 0.05,
            policy: .balanced,
            urgentBypass: false,
            pressureIsOurs: false)
        #expect(channel == .ane)
    }

    @Test("callers that pass nothing stay protective (old semantics preserved)")
    func defaultParameterStaysProtective() {
        let channel = HardwareRouter.route(
            thermal: .nominal,
            memoryPressure: 3,
            gpuFraction: 0.05,
            policy: .balanced,
            urgentBypass: false)
        #expect(channel == .cpu)
    }

    @Test("readers agree with the OS on this host")
    func readerInvariants() {
        let total = Int(HardwareRouter.physicalMemoryBytes())
        #expect(total == ProcessInfo.processInfo.physicalMemory)
        let reclaimable = HardwareRouter.reclaimableMemoryBytes()
        #expect(reclaimable != nil)
        if let reclaimable {
            #expect(Int(reclaimable) <= total)
        }
    }
}
#endif
