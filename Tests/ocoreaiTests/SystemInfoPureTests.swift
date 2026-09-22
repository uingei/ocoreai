// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// SystemInfo Pure 段(跨平台离线可测, 零 OS I/O, 纯函数精确值断言, 禁 count>0 弱断言):
//   humanReadableBytes(精确换算) / cpuLine / report(固定输入 → 逐行精确串)。
import Testing

@testable import ocoreai

struct SystemInfoPureTests {

    @Test("humanReadableBytes: 精确 GB 换算到 2 位小数; 0 与极小 → 0 GB 兜底")
    func humanReadableBytesExact() {
        let GiB: Double = 1_073_741_824
        #expect(SystemInfoPure.humanReadableBytes(0) == "0 GB")
        #expect(SystemInfoPure.humanReadableBytes(1024) == "0 GB", "<0.01 GiB 兜底 0 GB")
        #expect(SystemInfoPure.humanReadableBytes(1_000_000_000) == "0.93 GB")
        #expect(SystemInfoPure.humanReadableBytes(UInt64(GiB)) == "1.00 GB")
        #expect(SystemInfoPure.humanReadableBytes(UInt64(16.0 * GiB)) == "16.00 GB")
        #expect(SystemInfoPure.humanReadableBytes(UInt64(2.0 * GiB)) == "2.00 GB")
        #expect(SystemInfoPure.humanReadableBytes(UInt64(0.5 * GiB)) == "0.50 GB")
    }

    @Test("cpuLine: active/physical 双计数, 精确拼接")
    func cpuLineExact() {
        #expect(SystemInfoPure.cpuLine(active: 10, physical: 10) == "cpu: 10 active / 10 cores")
        #expect(SystemInfoPure.cpuLine(active: 1, physical: 4) == "cpu: 1 active / 4 cores")
    }

    @Test("report: 固定输入 → 逐行精确(ram/disk/cpu 行精确; 磁盘缺席 → 诚实标注不捏造 0)")
    func reportExact() {
        let GiB = 1_073_741_824
        let withDisk = SystemInfoPure.report(
            os: "Version 1.0 (Build X)",
            activeCpu: 8,
            physicalCpu: 8,
            ramBytes: UInt64(16 * GiB),
            diskTotalBytes: 20_000_000_000,
            diskAvailBytes: 10_000_000_000
        )
        // 逐行精确(不含 platform/arch 两行 — 那两行走编译期, 另断言):
        let lines = withDisk.split(separator: "\n").map(String.init)
        #expect(lines.contains("os: Version 1.0 (Build X)"))
        #expect(lines.contains("cpu: 8 active / 8 cores"))
        #expect(lines.contains("ram: 16.00 GB"))
        #expect(lines.contains("disk: 9.31 GB free of 18.63 GB"), "got: \(lines)")

        // 磁盘不可用(iOS 沙盒常见) → 诚实行, 绝不编 "0 GB free":
        let noDisk = SystemInfoPure.report(
            os: "Version 2.0", activeCpu: 2, physicalCpu: 4,
            ramBytes: UInt64(8 * GiB),
            diskTotalBytes: nil, diskAvailBytes: nil
        )
        #expect(noDisk.contains("disk: not available on this platform"))
        #expect(!noDisk.contains("free of"), "磁盘缺席不应出现 free-of 行")
    }

    @Test("arch/platform 编译期 getter: 本机取值自洽(arch 必为已知枚举, platform 必非空)")
    func compileTimeGettersSelfConsistent() {
        let arch = SystemInfoPure.archName
        #expect(arch == "arm64" || arch == "x86_64", "got arch: \(arch)")
        let plat = SystemInfoPure.platformName
        #expect(plat == "macOS" || plat == "iOS" || plat == "other", "got platform: \(plat)")
        #expect(!plat.isEmpty)
    }
}
