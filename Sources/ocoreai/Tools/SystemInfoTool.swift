// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SystemInfo — 「自主操作计算机 / 设计复杂系统」前的机型身份 + 资源容量查询面。
///
/// 第一性: 模型要「设计复杂系统」(如选一个多大参数量/多少张量并行的本地模型、能否同时
/// 起推理+训练), 动作链之前需要一个**主动、即时、无前置状态**的「这台机器是谁 + 有多少
/// 资源」查询面。既有 observe_state 是被动流(需 PerceptionEngine 已开 channel + TTL 窗口
/// 内有过采样), 且 SystemContextData 只到 thermal/内存压力/cpu/uptime — **不含磁盘容量、
/// CPU 架构、OS 版本**。这是"深度适配各平台 framework"的落点: ProcessInfo + 编译期 arch
/// + FileManager resourceValues 是 iOS17/macOS14 双平台一等面, 跨平台注册。
///
/// 分工(不抢 observe_state 的活):
///   observe_state(.system 流) → thermal / memory pressure / low power(被动, 时间维度)
///   system_info(主动查询)     → platform / arch / os / cpu / ram / disk(身份 + 容量快照)
///
/// 三段: Pure(fmt 纯值离线可测, 不触 OS I/O) / Driver(OS 采集, nil 容错) / Client(注册)。
/// 只读 → isDestructive=false(同 observe_state / inspect_ui, 免审批)。零 as!/try!。
import Foundation

// MARK: - Pure(跨平台离线可测: 格式化 + 编译期事实, 不触 OS I/O)

enum SystemInfoPure {
    /// bytes → "N.NN GB"(2 位小数; 0 → "0 B"; <1GiB 自动转 MB 语义由调用点决定, 这里统一 GB)。
    /// 纯: 给定 bytes 精确断言, 不依赖任何系统态。
    static func humanReadableBytes(_ bytes: UInt64) -> String {
        let gb = 1_073_741_824.0
        let v = Double(bytes) / gb
        if v < 0.01 {
            return "0 GB"
        }
        return String(format: "%.2f GB", v)
    }

    /// cpu 双计数行(纯拼接, 精确断言不依赖真机值)。
    static func cpuLine(active: Int, physical: Int) -> String {
        "cpu: \(active) active / \(physical) cores"
    }

    /// 架构(编译期 #if, 非运行时 sysctl — 双平台最稳)。
    static var archName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// 平台名(编译期 #if)。
    static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "other"
        #endif
    }

    /// 把原始采集值拼成最终文本(纯: 注入固定输入 → 精确断言)。
    /// missing 字段(如 iOS 上磁盘配额不可用)→ 对应行省略, 不捏造 0。
    static func report(
        os: String,
        activeCpu: Int,
        physicalCpu: Int,
        ramBytes: UInt64,
        diskTotalBytes: UInt64?,
        diskAvailBytes: UInt64?
    ) -> String {
        var lines: [String] = [
            "platform: \(platformName)",
            "arch: \(archName)",
            "os: \(os)",
            cpuLine(active: activeCpu, physical: physicalCpu),
            "ram: \(humanReadableBytes(ramBytes))",
        ]
        if let avail = diskAvailBytes, let total = diskTotalBytes {
            lines.append("disk: \(humanReadableBytes(avail)) free of \(humanReadableBytes(total))")
        } else {
            // 配额不可用(常见于 iOS 沙盒)→ 诚实说不可用, 不编 0。
            lines.append("disk: not available on this platform")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Driver(OS 采集, nil 容错: 配额/字段不可用 → nil, 由 Pure 侧决定如何呈现)

enum SystemInfoDriver {
    struct Sample: Sendable {
        let os: String
        let activeCpu: Int
        let physicalCpu: Int
        let ramBytes: UInt64
        let diskTotalBytes: UInt64?
        let diskAvailBytes: UInt64?
    }

    /// 即时采集(host 真机): ProcessInfo(身份+cpu+ram) + 根卷 resourceValues(磁盘)。
    /// 磁盘走 resourceValues, 全 Optional → 沙盒/受限环境自然安全, 不崩。
    static func collect() -> Sample {
        let pi = ProcessInfo.processInfo
        var diskTotal: UInt64?
        var diskAvail: UInt64?
        do {
            let rv = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
            ])
            if let t = rv.volumeTotalCapacity {
                diskTotal = UInt64(max(0, t))
            }
            if let a = rv.volumeAvailableCapacity {
                diskAvail = UInt64(max(0, a))
            }
        } catch {
            // resourceValues 失败 → 留 nil, report 侧如实标注不可用。
        }
        return Sample(
            os: pi.operatingSystemVersionString,
            activeCpu: pi.activeProcessorCount,
            physicalCpu: pi.processorCount,
            ramBytes: pi.physicalMemory,
            diskTotalBytes: diskTotal,
            diskAvailBytes: diskAvail
        )
    }
}

// MARK: - Client(注册)

enum SystemInfoClient {
    static let toolName = "system_info"

    struct NoArgs: Codable, Sendable {}

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "system",
            argsType: NoArgs.self,
            description:
                "Query the host machine's identity and resource capacity before acting or planning "
                + "a complex system: platform (macOS/iOS), CPU architecture, OS version, CPU core "
                + "count, physical RAM, and free disk space. Read-only and instant (no background "
                + "state needed, unlike observe_state's passive channels). Use to size local models "
                + "or plan concurrent inference/training against real hardware rather than guessing. "
                + "Returns a short, exact text summary.",
            schema: ToolSchema(parameters: [:])
        ) { _ in
            let s = SystemInfoDriver.collect()
            return SystemInfoPure.report(
                os: s.os,
                activeCpu: s.activeCpu,
                physicalCpu: s.physicalCpu,
                ramBytes: s.ramBytes,
                diskTotalBytes: s.diskTotalBytes,
                diskAvailBytes: s.diskAvailBytes
            )
        }
    }
}
