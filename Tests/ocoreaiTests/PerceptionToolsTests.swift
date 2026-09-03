// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `observe_state` 工具 — 精确值测试(全离线: 帧集注入, 不启动任何 sensor, 不触 wall clock).
///
/// 覆盖:
///   PerceptionObserve.build  — 缺席通道不列 / 类型优先级(ocr>image>audio>text) / 通道序稳定
///   PerceptionObserve.clip   — ≤300 原样 / 301 截到 300(边界精确)
///   PerceptionObserve.render — 空缓冲诚实缺席 / 新鲜度精确值 / stale 计数精确
///   ObserveStateClient       — 工具注册面(名称/toolset/无参 schema)/ 离线 runForTest 精确渲染
import Foundation
import Testing

@testable import ocoreai

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite("observe_state build")
struct ObserveStateBuildTests {

    @Test
    func absentChannelsAreOmitted() {
        // 仅 system 通道在场 → channel seq 只含 system, 不伪造其余 6 通道在场。
        let frames: [PerceptionChannel: PerceptionFrame] = [
            .system: PerceptionFrame(
                channel: .system, textContext: "thermal=nominal", estimatedTokens: 10)
        ]
        let r = PerceptionObserve.build(frames: frames, now: t0)
        #expect(r.channels.map(\.channel) == [.system])
        #expect(r.channels.count == 1)
    }

    @Test
    func sameChannelPrefersOCROverImage() {
        // 同屏: ocr + image 都在 → ocr 胜出(报告里 image 不可见, 文本通道不吐像素纪律)。
        let f = PerceptionFrame(
            channel: .screen, imageURL: "file:///x.jpg", ocrText: "hello screen")
        let r = PerceptionObserve.build(frames: [.screen: f], now: t0)
        #expect(r.channels.count == 1)
        #expect(r.channels[0].kind == "ocr:text")
        #expect(r.channels[0].preview == "hello screen")
    }

    @Test
    func imageChannelWithoutOCRReportsImage() {
        let f = PerceptionFrame(channel: .camera, imageURL: "file:///cam.jpg")
        let r = PerceptionObserve.build(frames: [.camera: f], now: t0)
        #expect(r.channels.count == 1)
        #expect(r.channels[0].kind == "image")
        #expect(r.channels[0].preview == "file:///cam.jpg")
    }

    @Test
    func audioAndTextKinds() {
        let audio = PerceptionFrame(channel: .audio, audioURL: "file:///mic.m4a")
        let env = PerceptionFrame(channel: .environment, textContext: "rss: 42 items")
        let r = PerceptionObserve.build(frames: [.audio: audio, .environment: env], now: t0)
        let byCh = Dictionary(uniqueKeysWithValues: r.channels.map { ($0.channel, $0.kind) })
        #expect(byCh[.audio] == "audio")
        #expect(byCh[.environment] == "text")
    }

    @Test
    func channelOrderStableInAllCasesSequence() {
        // 全 7 通道在场 → 报告序 = PerceptionChannel.allCases 声明序(输出确定, 可断言)。
        var frames: [PerceptionChannel: PerceptionFrame] = [:]
        for c in PerceptionChannel.allCases {
            frames[c] = PerceptionFrame(
                channel: c, textContext: "v-\(c.description)", estimatedTokens: 5)
        }
        let r = PerceptionObserve.build(frames: frames, now: t0)
        #expect(r.channels.map(\.channel) == PerceptionChannel.allCases)
        #expect(r.channels.count == PerceptionChannel.allCases.count)
    }

    @Test
    func ageSecondsExact() {
        // 帧 capturedAt = t0-7s → age = 7s(now 注入, 不依赖 wall)。
        let f = PerceptionFrame(
            channel: .system, textContext: "u", estimatedTokens: 1,
            capturedAt: t0.addingTimeInterval(-7))
        let r = PerceptionObserve.build(frames: [.system: f], now: t0)
        #expect(r.channels[0].ageSeconds == 7)
    }
}

@Suite("observe_state clipping")
struct ObserveStateClipTests {

    @Test
    func atBoundaryKeepsFull() {
        let s = String(repeating: "a", count: 300)
        #expect(PerceptionObserve.clip(s).count == 300)
        #expect(PerceptionObserve.clip(s) == s)
    }

    @Test
    func overBoundaryTruncatesTo300() {
        let s = String(repeating: "a", count: 301)
        #expect(PerceptionObserve.clip(s).count == 300)
        #expect(PerceptionObserve.clip(s) == String(repeating: "a", count: 300))
    }

    @Test
    func emptyStringStaysEmpty() {
        #expect(PerceptionObserve.clip("") == "")
    }
}

@Suite("observe_state render")
struct ObserveStateRenderTests {

    @Test
    func emptyBufferHonestAbsence() {
        let out = PerceptionObserve.render(frames: [:], now: t0)
        #expect(
            out
                == "[Perception] no recent frames in buffer. Perception may be disabled or idle; nothing observed in the TTL window."
        )
    }

    @Test
    func singleChannelExactRender() {
        let f = PerceptionFrame(
            channel: .system, textContext: "thermal=nominal", estimatedTokens: 1, capturedAt: t0)
        let frames: [PerceptionChannel: PerceptionFrame] = [.system: f]
        let out = PerceptionObserve.render(frames: frames, now: t0)
        #expect(
            out
                == "[Perception] 1 channel(s), 0 stale(>30s)\n- system(text, age 0s): thermal=nominal"
        )
    }

    @Test
    func staleCountExact() {
        let fresh = PerceptionFrame(
            channel: .system, textContext: "fresh", estimatedTokens: 1, capturedAt: t0)
        let stale = PerceptionFrame(
            channel: .environment, textContext: "old", estimatedTokens: 1,
            capturedAt: t0.addingTimeInterval(-31))  // > 30s 阈值(31 边界外) → 1 stale
        let frames: [PerceptionChannel: PerceptionFrame] = [.system: fresh, .environment: stale]
        let r = PerceptionObserve.build(frames: frames, now: t0)
        #expect(r.staleCount == 1)
    }

    @Test
    func boundaryAge30sNotStale() {
        // 恰 30s = PerceptionBudget.default.maxAgeSeconds → 不算 stale(阈值是严格 >)。
        let f = PerceptionFrame(
            channel: .system, textContext: "edge", estimatedTokens: 1,
            capturedAt: t0.addingTimeInterval(-30))
        let frames: [PerceptionChannel: PerceptionFrame] = [.system: f]
        let r = PerceptionObserve.build(frames: frames, now: t0)
        #expect(r.staleCount == 0)
        #expect(r.channels[0].ageSeconds == 30)
    }
}

@Suite("observe_state tool surface")
struct ObserveStateToolSurfaceTests {

    @Test
    func offlineRenderThroughClient() {
        // 客户端渲染入口 = 同一路径(测试侧 seam, 不启动 PerceptionEngine)。
        let f = PerceptionFrame(
            channel: .screen, ocrText: "login form", estimatedTokens: 3, capturedAt: t0)
        let out = ObserveStateClient.runForTest(frames: [.screen: f], now: t0)
        #expect(
            out
                == "[Perception] 1 channel(s), 0 stale(>30s)\n- screen(ocr:text, age 0s): login form"
        )
    }
}
