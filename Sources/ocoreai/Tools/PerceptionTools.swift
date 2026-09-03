// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// perception namespace — 「Computer = AI 的感知环境」的 agent 自查询面:
///
///   observe_state   无参, 报告 PerceptionEngine 各通道(screen/camera/audio/network/
///                   environment/system/speaker)的最新观察值 + 新鲜度(秒龄)。
///                   通道无值 → 不列该通道(诚实缺席, 非伪造在场)。
///
/// 定位: 感知管线 (sensors → PerceptionBuffer(RingBuffer+TTL+budget) → 推理注入)
/// 已在 UI 侧接通(每轮 tool loop 经 systemInstructions 注入)。agent 面缺的是
/// 「主动查询」入口——模型按当前任务主动问「现在环境是什么样」, 不依赖被动注入,
/// 也不重复采集(本工具是只读观察, 对 sensor 零副作用)。
///
/// 真值源 = PerceptionEngine.shared.buffer —— 与 UI 注入路径同一实例、同一环形缓冲,
/// 工具读快照不改任何 sensor 状态。
import Foundation

// MARK: - 纯计算(离线可测, 不触 PerceptionEngine)

enum PerceptionObserve {
    struct ChannelView: Equatable {
        let channel: PerceptionChannel
        let kind: String  // "ocr:text" / "image" / "audio" / "text"
        let preview: String
        let ageSeconds: Int
    }

    struct Report: Equatable {
        let channels: [ChannelView]
        let staleCount: Int
    }

    /// 预览截断上限(300 字符 ≈ ~75 token, 防单帧刷爆 budget 硬上限的语义上限)。
    static let maxPreviewChars = 300
    /// stale 判定阈值 = PerceptionBudget.default.maxAgeSeconds(30s):
    /// 超龄观察值仍报告(标 stale), 不隐藏——宁可「30 秒前的真相 + 新鲜度」, 不可无。
    static let staleThresholdSeconds: Int = Int(PerceptionBudget.default.maxAgeSeconds)

    /// 稳定通道序 = PerceptionChannel.allCases 声明序(输出确定性, 可精确断言)。
    /// 同帧类型优先级 = ocr > image > audio > text(与 PerceptionFrame 字段语义一致:
    /// ocr 是 screen/camera 的文本化, image 其次, audio/环境文本最后)。
    static func build(frames: [PerceptionChannel: PerceptionFrame], now: Date) -> Report {
        var channels: [ChannelView] = []
        for c in PerceptionChannel.allCases {
            guard let frame = frames[c] else { continue }
            let age = Int(max(0, now.timeIntervalSince(frame.capturedAt)))
            if let ocr = frame.ocrText, !ocr.isEmpty {
                channels.append(
                    ChannelView(channel: c, kind: "ocr:text", preview: clip(ocr), ageSeconds: age))
            } else if let img = frame.imageURL {
                channels.append(
                    ChannelView(channel: c, kind: "image", preview: img, ageSeconds: age))
            } else if let audio = frame.audioURL {
                channels.append(
                    ChannelView(channel: c, kind: "audio", preview: audio, ageSeconds: age))
            } else if let t = frame.textContext, !t.isEmpty {
                channels.append(
                    ChannelView(channel: c, kind: "text", preview: clip(t), ageSeconds: age))
            }
        }
        let stale = channels.filter { $0.ageSeconds > staleThresholdSeconds }.count
        return Report(channels: channels, staleCount: stale)
    }

    /// 300 字符硬截断(边界精确: ≤300 原样, >300 截到 300)。
    static func clip(_ s: String) -> String {
        s.count <= maxPreviewChars ? s : String(s.prefix(maxPreviewChars))
    }

    /// 渲染(离线可测; now 注入 = 新鲜度精确断言不依赖 wall clock)。
    static func render(frames: [PerceptionChannel: PerceptionFrame], now: Date) -> String {
        let r = build(frames: frames, now: now)
        guard !r.channels.isEmpty else {
            return
                "[Perception] no recent frames in buffer. Perception may be disabled or idle; nothing observed in the TTL window."
        }
        var lines: [String] = [
            "[Perception] \(r.channels.count) channel(s), \(r.staleCount) stale(>\(staleThresholdSeconds)s)"
        ]
        for c in r.channels {
            lines.append(
                "- \(c.channel.description)(\(c.kind), age \(c.ageSeconds)s): \(c.preview)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - client(seam 绑定)

enum ObserveStateClient {
    static let toolName = "observe_state"

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "perception",
            argsType: Args.self,
            description:
                "Observe the current state of the Computer from perception channels "
                + "(screen, camera, audio, network, environment, system, speaker). "
                + "Read-only: returns each channel's latest observation with its age. "
                + "Use to ground multi-step tasks in the live environment instead of guessing.",
            schema: ToolSchema(parameters: [:])
        ) { _ in
            await runForTool()
        }
    }

    struct Args: Codable, Sendable {}

    /// 生产路径: 读 PerceptionEngine 快照(@MainActor — 跨 actor 必 await, 铁律)。
    static func runForTool() async -> String {
        let frames = await MainActor.run { PerceptionEngine.shared.snapshot() }
        return PerceptionObserve.render(frames: frames, now: Date())
    }

    /// 离线精确值路径: 注入任意帧集 → 渲染(测试不启动任何 sensor)。
    static func runForTest(frames: [PerceptionChannel: PerceptionFrame], now: Date) -> String {
        PerceptionObserve.render(frames: frames, now: now)
    }
}
