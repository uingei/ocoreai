// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// SystemInfo live — Driver.collect() 真机采集的不变量测试(非精确值, 精确值走 Pure):
//   报告自洽(6 行) / ram 必 >0 / cpu active≥1 且 ≤ physical / 磁盘行合法
// 真机值随机器而异 → 只断"恒真不变量", 不钉具体 GB 数。
import Foundation
import Testing

@testable import ocoreai

struct SystemInfoLiveTests {

    @Test("collect→report: 真机报告自洽, ram/cpu 不变量恒真")
    func liveInvariants() {
        let s = SystemInfoDriver.collect()
        let report = SystemInfoPure.report(
            os: s.os, activeCpu: s.activeCpu, physicalCpu: s.physicalCpu,
            ramBytes: s.ramBytes,
            diskTotalBytes: s.diskTotalBytes, diskAvailBytes: s.diskAvailBytes
        )
        let lines = report.split(separator: "\n").map(String.init)
        // 恒 6 行: platform/arch/os/cpu/ram/disk
        #expect(lines.count == 6, "expect 6 lines, got \(lines.count): \(lines)")
        #expect(lines[0].hasPrefix("platform: "))
        #expect(lines[1].hasPrefix("arch: "))
        #expect(lines[2].hasPrefix("os: "))
        #expect(lines[3].hasPrefix("cpu: "))
        #expect(lines[4].hasPrefix("ram: "))
        #expect(lines[5].hasPrefix("disk: "))
        // 恒真不变量:
        #expect(s.ramBytes > 0, "真实机器 ram 必 > 0, got \(s.ramBytes)")
        #expect(s.activeCpu >= 1, "active cpu 必 ≥ 1, got \(s.activeCpu)")
        #expect(
            s.physicalCpu >= s.activeCpu, "physical 必 ≥ active, \(s.physicalCpu) vs \(s.activeCpu)")
        // os 串非空(至少含版本号主体)
        #expect(!s.os.isEmpty)
        // ram 行必是合法 GB 串(N.NN GB), 不空
        #expect(lines[4].contains("GB"), "ram 行应含 GB: \(lines[4])")
        // 磁盘行: 要么 free-of, 要么明确 not-available(二选一, 不空不编造)
        #expect(
            lines[5].contains("free of") || lines[5].contains("not available on this platform"),
            "disk 行非法: \(lines[5])")
    }
}
