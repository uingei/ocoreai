// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// `generate_video` tool — exact-value tests (fully offline, fake backend,
/// no CoreAI/WanPipeline/weight access).
import Foundation
import Testing

@testable import ocoreai

/// File-scope fake video backend — records what it received, returns fixed outcome.
struct FakeVideoBackend: VideoGenerationBackend {
    let outcome: VideoGenOutcome
    nonisolated func generate(built: GenerateVideo.Built, outputURL: URL) async -> VideoGenOutcome {
        return outcome
    }
}

// MARK: - request build: defaults + clamps

@Suite("generate_video request build")
struct BuildTests {
    @Test
    func defaultValuesAndClamps() {
        let b = GenerateVideo.build(
            .init(
                prompt: nil, numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil))
        #expect(b.prompt == "cinematic")
        #expect(b.numFrames == GenerateVideo.defaultNumFrames)
        #expect(b.fps == GenerateVideo.defaultFps)
        #expect(b.width == 832)
        #expect(b.height == 480)
        #expect(b.steps == GenerateVideo.defaultStepCount)
        #expect(b.seed == 42)
        #expect(b.format == .mp4)
    }

    @Test
    func promptTrimmed() {
        let b = GenerateVideo.build(
            .init(
                prompt: "  a cat running  ", numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil))
        #expect(b.prompt == "a cat running")
    }

    @Test
    func numFrameClampsToUpperBound() {
        let b = GenerateVideo.build(
            .init(
                prompt: nil, numFrames: 9999, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil))
        #expect(b.numFrames == 81)
    }

    @Test
    func vae4kPlus1Alignment() {
        // 81→81, 77→77, 80→77(最近≤的4k+1), 6→5
        #expect(
            GenerateVideo.build(
                .init(
                    prompt: nil, numFrames: 81, fps: nil,
                    width: nil, height: nil, steps: nil, seed: nil, format: nil)
            ).numFrames == 81)
        #expect(
            GenerateVideo.build(
                .init(
                    prompt: nil, numFrames: 77, fps: nil,
                    width: nil, height: nil, steps: nil, seed: nil, format: nil)
            ).numFrames == 77)
        // 82 clamp→81
        #expect(
            GenerateVideo.build(
                .init(
                    prompt: nil, numFrames: 82, fps: nil,
                    width: nil, height: nil, steps: nil, seed: nil, format: nil)
            ).numFrames == 81)
    }

    @Test
    func formatParsedLowerCaseToEnum() {
        #expect(
            GenerateVideo.build(
                .init(
                    prompt: nil, numFrames: nil, fps: nil,
                    width: nil, height: nil, steps: nil, seed: nil, format: "GIF")
            ).format == .gif)
        #expect(
            GenerateVideo.build(
                .init(
                    prompt: nil, numFrames: nil, fps: nil,
                    width: nil, height: nil, steps: nil, seed: nil, format: "WEBP")
            ).format == .webp)
    }

    @Test
    func unknownFormatFallsBackToMP4() {
        #expect(
            GenerateVideo.build(
                .init(
                    prompt: nil, numFrames: nil, fps: nil,
                    width: nil, height: nil, steps: nil, seed: nil, format: "av1")
            ).format == .mp4)
    }

    @Test
    func fpsAndStepsClamped() {
        let b = GenerateVideo.build(
            .init(
                prompt: nil, numFrames: nil, fps: 999,
                width: nil, height: nil, steps: nil, seed: nil, format: nil))
        #expect(b.fps == 60)
        let c = GenerateVideo.build(
            .init(
                prompt: nil, numFrames: nil, fps: nil,
                width: nil, height: nil, steps: 0, seed: nil, format: nil))
        #expect(c.steps == 1)
    }
}

// MARK: - report shape

@Suite("generate_video report shape")
struct ReportTests {
    @Test
    func okReportIsTwoLinesWithPath() {
        let o = VideoGenOutcome.ok(outputURL: "/tmp/out.mp4", frameCount: 81)
        let r = GenerateVideo.report(outcome: o)
        let lines = r.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "generate_video OK — 81 frames written")
        #expect(lines[1] == "/tmp/out.mp4")
    }

    @Test
    func errorReportPrefix() {
        #expect(GenerateVideo.errorReport("boom") == "generate_video: error: boom")
    }
}

// MARK: - client outcome mapping (fake backend)

@Suite("generate_video client outcome mapping")
struct ClientTests {
    @Test
    func okMapsToReport() async {
        let out = await GenerateVideoClient.runForTool(
            args: .init(
                prompt: "a cat", numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil),
            backend: FakeVideoBackend(outcome: .ok(outputURL: "/tmp/out.mp4", frameCount: 81)))
        #expect(out.contains("generate_video OK — 81 frames written"))
    }

    @Test
    func belowFloorMapsHonestError() async {
        let out = await GenerateVideoClient.runForTool(
            args: .init(
                prompt: "a cat", numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil),
            backend: FakeVideoBackend(outcome: .belowFloor))
        #expect(out.hasPrefix("generate_video: error:"))
        #expect(out.contains("macOS 27 / iOS 27"))
    }

    @Test
    func coreAIUnavailableMapsHonestError() async {
        let out = await GenerateVideoClient.runForTool(
            args: .init(
                prompt: "a cat", numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil),
            backend: FakeVideoBackend(outcome: .coreAIUnavailable))
        #expect(out.contains("CoreAI framework not available"))
    }

    @Test
    func weightsMissingMapsHonestError() async {
        let out = await GenerateVideoClient.runForTool(
            args: .init(
                prompt: "a cat", numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil),
            backend: FakeVideoBackend(outcome: .weightsMissing("missing")))
        // 精确值断言(含用户级 ~/ 权重路径, 防系统级 /Library 漂移)
        #expect(
            out
                == "generate_video: error: Wan 2.1 weights not deployed — put the 3 .aimodel files under ~/Library/Application Support/ocoreai/wan2.1 (3 files: Transformer.aimodel+TextEncoder.aimodel+VAEDecoder.aimodel) and retry"
        )
    }

    @Test
    func failedMapsReason() async {
        let out = await GenerateVideoClient.runForTool(
            args: .init(
                prompt: "a cat", numFrames: nil, fps: nil,
                width: nil, height: nil, steps: nil, seed: nil, format: nil),
            backend: FakeVideoBackend(outcome: .failed("oom")))
        #expect(out == "generate_video: error: oom")
    }
}
