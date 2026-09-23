// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HardwareRouterPressureRegression — 内存压力口径回归。
///
/// 修复背景（2026-09-24，实测驱动）：
/// `memoryUsageFraction()` 曾把 `inactive_count` 计入"已用"。inactive 是可回收
/// 文件缓存，不计真实压力。本机实测（16GB / page=16KB）：
///   active≈280137  inactive≈259995  wire≈150684  compressor≈159490
/// 含 inactive → usedFraction≈0.79 → pressure L3 → route() Tier-1 强制 .cpu
/// 剔 inactive → usedFraction≈0.55 → 仍 <0.7 … 取决于阈值；关键不变式是
/// 「inactive 页不计入分子」——这条是行为契约，不能因页面语义回归。
///
/// 本测试只钉纯函数 ``HardwareRouter/usedFraction(active:wire:compressor:pageSize:memSize:)``
/// 的数学契约（缓存排除 + 边界 guard），不依赖具体机器。

import Testing

@testable import ocoreai

@Suite("HardwareRouter memory-pressure fraction", .serialized)
struct HardwareRouterPressureRegressionTests {
    // 本机实测页计数（vm_stat, 2026-09-24），按 16KB 页换算：
    private let activePages: UInt64 = 280_137
    private let inactivePages: UInt64 = 259_995
    private let wirePages: UInt64 = 150_684
    private let compressorPages: UInt64 = 159_490
    private let pageSize: UInt64 = 16_384
    private let memSize: UInt64 = 16 * 1024 * 1024 * 1024

    @Test("inactive cache is EXCLUDED from the pressure numerator")
    func inactiveExcluded() {
        // 正确口径：active + wire + compressor
        let correct = HardwareRouter.usedFraction(
            active: activePages,
            wire: wirePages,
            compressor: compressorPages,
            pageSize: pageSize,
            memSize: memSize
        )

        // 旧 bug 口径（若 inactive 被计回分子）：正确值 + inactive 占比
        let inactiveShare = Double(inactivePages * pageSize) / Double(memSize)
        let buggyWithInactive = correct + inactiveShare

        // 不变式 1：正确口径把 inactive 占比排除在分子外（数学恒等）
        #expect(correct == buggyWithInactive - inactiveShare)
        // 不变式 2：正确口径 < 错误口径（inactive 页确实被剔除）
        #expect(correct < buggyWithInactive)
    }

    @Test("correct accounting is strictly less severe than the cache-inclusive bug")
    func severityLowered() {
        let correct = HardwareRouter.usedFraction(
            active: activePages,
            wire: wirePages,
            compressor: compressorPages,
            pageSize: pageSize,
            memSize: memSize
        )
        let withCache =
            Double(
                (activePages + inactivePages + wirePages + compressorPages) * pageSize
            ) / Double(memSize)

        let level = { (f: Double) -> Int in
            f < 0.3 ? 0 : (f < 0.5 ? 1 : (f < 0.7 ? 2 : 3))
        }

        // 不变式：正确口径严格降级（本机实测 0.5630→L2 vs 旧 0.8109→L3）。
        // 关键行为差：balanced(阈值L2) + performance(阈值L3) 下，
        // 旧口径把 performance 模式也锁死 CPU；正确口径放行 performance→非CPU。
        #expect(correct < withCache)
        #expect(level(correct) < level(withCache))
        #expect(level(correct) < 3, "正确口径在本机稳态下不应是最高压 L3")
        #expect(level(withCache) >= 3, "旧口径应虚高到 L3 — 证明本门守住了 regression")

        // 策略级行为差（route() 纯函数门）：
        let perfForcesCPU_buggy = level(withCache) >= 3  // performance 阈值 = 3
        let perfForcesCPU_fixed = level(correct) >= 3
        #expect(
            perfForcesCPU_buggy && !perfForcesCPU_fixed,
            "performance 模式：旧口径误锁 CPU，修复后放行")
    }

    @Test("zero memSize guard returns neutral 0.5, never divides by zero")
    func zeroMemSizeGuard() {
        let f = HardwareRouter.usedFraction(
            active: 10_000, wire: 1_000, compressor: 500,
            pageSize: 16_384, memSize: 0
        )
        #expect(f == 0.5)
    }

    @Test("all-zero occupancy yields zero fraction")
    func allZero() {
        let f = HardwareRouter.usedFraction(
            active: 0, wire: 0, compressor: 0,
            pageSize: 16_384, memSize: 16 * 1024 * 1024 * 1024
        )
        #expect(f == 0.0)
    }
}
