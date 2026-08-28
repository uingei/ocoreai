// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// 视频生成轴(五要素④)的 agent 可触面 — 一个工具 `generate_video`。
/// 形态先例 = SpeechTools(transcribe_audio/speak) + view_screen「基设已建、
/// 补 agent 面」: 纯核对(规范化/clamp/报告)= 离线可测; 真实 I/O 收口一个
/// seam, 测试注入 fake,不触 CoreAI、不需要 .aimodel。
/// 真实实现复用已 absorb 的视频基设(三仓基准消费,不另造):
///   - WanPipeline(coreai-models conformer, @available 27.0) -> [CGImage]
///   - VideoWriter(coreai-models Output, 纯 AVFoundation) -> mp4/gif/apng/webp
/// 低于 floor / 无 CoreAI / 权重未部署 -> 诚实上报, 不静默失败。
import CoreGraphics
import Foundation

enum VideoFormat: String, Equatable {
    case mp4
    case gif
    case apng
    case webp
}

enum GenerateVideo {
    static let minNumFrames = 5
    static let maxNumFrames = 81
    static let minDimension = 32
    static let maxDimension = 1280
    static let minFps = 1
    static let maxFps = 60
    static let minSteps = 1
    static let maxSteps = 60
    static let defaultFps = 16
    static let defaultNumFrames = 81
    static let defaultStepCount = 50
    static let defaultSeed: UInt32 = 42

    /// 请求参数（Codable，由工具框架反序列化；可选字段缺省用默认值）。
    struct Args: Codable, Sendable {
        let prompt: String?
        let numFrames: Int?
        let fps: Int?
        let width: Int?
        let height: Int?
        let steps: Int?
        let seed: UInt32?
        let format: String?
    }

    struct Built: Equatable {
        let prompt: String
        let numFrames: Int
        let fps: Int
        let width: Int
        let height: Int
        let steps: Int
        let seed: UInt32
        let format: VideoFormat
    }

    /// 请求 → 规范化（纯函数，无 I/O，可离线断言）。
    static func build(_ a: Args) -> Built {
        let prompt = (a.prompt ?? "cinematic").trimmingCharacters(in: .whitespacesAndNewlines)
        let numFrames = clampFrames(a.numFrames ?? defaultNumFrames)
        let fps = clampFps(a.fps ?? defaultFps)
        let width = clampDimension(a.width ?? defaultVideoSize().width)
        let height = clampDimension(a.height ?? defaultVideoSize().height)
        let steps = clampSteps(a.steps ?? defaultStepCount)
        let seed = a.seed ?? defaultSeed
        let format = parseFormat(a.format)
        return Built(
            prompt: prompt, numFrames: numFrames, fps: fps,
            width: width, height: height, steps: steps,
            seed: seed, format: format
        )
    }

    static func defaultVideoSize() -> (width: Int, height: Int) { (832, 480) }

    static func clampFrames(_ v: Int) -> Int {
        let c = max(min(v, maxNumFrames), minNumFrames)
        // VAE 时间压缩: (frames-1) % 4 == 0 → 取 ≤c 最近的合法帧数
        // c mod 4 = 0→c-3, 1→c, 2→c-1, 3→c-2
        let r = c % 4
        return max(minNumFrames, c - (r + 3) % 4)
    }

    static func clampFps(_ v: Int) -> Int { max(min(v, maxFps), minFps) }
    static func clampDimension(_ v: Int) -> Int { max(min(v, maxDimension), minDimension) }
    static func clampSteps(_ v: Int) -> Int { max(min(v, maxSteps), minSteps) }

    static func parseFormat(_ raw: String?) -> VideoFormat {
        guard let raw = raw?.lowercased() else { return .mp4 }
        if let f = VideoFormat(rawValue: raw) { return f }
        return .mp4
    }

    static func extensionFor(_ f: VideoFormat) -> String {
        switch f {
        case .mp4: return "mp4"
        case .gif: return "gif"
        case .apng: return "apng"
        case .webp: return "webp"
        }
    }

    static func formatLabel(_ f: VideoFormat) -> String {
        switch f {
        case .mp4: return "MP4"
        case .gif: return "GIF"
        case .apng: return "APNG"
        case .webp: return "WebP"
        }
    }

    /// 成功报告 — 两行形态(对齐 transcribe_audio OK 报告): 摘要 + 输出路径。
    static func report(outcome: VideoGenOutcome) -> String {
        guard case .ok(let outputURL, let frameCount) = outcome else {
            return "generate_video: error: unexpected result"
        }
        return "generate_video OK — \(frameCount) frames written\n\(outputURL)"
    }

    /// 失败报告 — 统一前缀。
    static func errorReport(_ reason: String) -> String {
        return "generate_video: error: \(reason)"
    }
}

// MARK: - outcome + seam

/// 生成结果 — 区分「成功+落盘 / 低于 floor / 无 CoreAI / 权重缺 / 失败」，
/// 让工具诚实告诉模型发生了什么（对齐 transcribe_audio 的 honest outcome 先例）。
enum VideoGenOutcome: Equatable {
    case ok(outputURL: String, frameCount: Int)
    case belowFloor
    case coreAIUnavailable
    case weightsMissing(String)
    case failed(String)
}

/// 视频生成后端 seam — 唯一的真实 I/O 边界。平台实现包裹
/// `WanPipeline.generateVideo` → `VideoWriter.write`；测试注入 fake，
/// 不触 CoreAI、不需要 .aimodel 权重、不下载资产。
protocol VideoGenerationBackend: Sendable {
    func generate(built: GenerateVideo.Built, outputURL: URL) async -> VideoGenOutcome
}

/// 消费 WanPipeline + VideoWriter 的真实 backend（macOS 27 / iOS 27）。
/// 权重目录约定: <weightsURL>/Transformer.aimodel+TextEncoder.aimodel+VAEDecoder.aimodel
/// 缺目录→ .weightsMissing（诚实， 权重部署属产品面）
#if canImport(CoreAI)
@available(macOS 27.0, iOS 27.0, *)
struct RealVideoBackend: VideoGenerationBackend, @unchecked Sendable {
    // 无共享可变状态(纯转发 WanPipeline/VideoWriter), 故 @unchecked Sendable 安全。
    static func defaultWeightsURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        guard let base = base else { return nil }
        let w = base.appendingPathComponent("ocoreai/wan2.1", isDirectory: true)
        return FileManager.default.fileExists(atPath: w.path) ? w : nil
    }

    nonisolated func generate(
        built: GenerateVideo.Built,
        outputURL: URL
    ) async -> VideoGenOutcome {
        guard #available(macOS 27.0, iOS 27.0, *) else { return .belowFloor }
        let wu = Self.defaultWeightsURL()
        guard let wu = wu else { return .weightsMissing("(no default wan2.1 weights)") }
        let outDir = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: outDir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: outDir, withIntermediateDirectories: true)
            } catch { return .failed(error.localizedDescription) }
        }
        do {
            let pipeline = try await WanPipeline(from: wu)
            let cfg = VideoConfiguration(
                prompt: built.prompt,
                negativePrompt: "",
                seed: built.seed,
                stepCount: built.steps,
                guidanceScale: 5.0,
                numFrames: built.numFrames,
                fps: built.fps,
                width: built.width,
                height: built.height,
                dumpDirectory: nil,
                loadNoisePath: nil,
                vaeTileSize: nil,
                vaeTileOverlap: 4,
                cfgCutoffFraction: nil
            )
            let result = try await pipeline.generateVideo(
                configuration: cfg,
                progressHandler: { _ in true }
            )
            try await VideoWriter.write(frames: result.frames, fps: result.fps, to: outputURL)
            return .ok(outputURL: outputURL.path, frameCount: result.frames.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
#endif

/// Fallback backend： 无 CoreAI 框架的平台（ iOS 26 / macOS 26）→ 诚实上报缺 CoreAI。
/// 无共享可变状态, 故 @unchecked Sendable 安全。
struct PlatformVideoBackend: VideoGenerationBackend, @unchecked Sendable {
    nonisolated func generate(
        built: GenerateVideo.Built,
        outputURL: URL
    ) async -> VideoGenOutcome {
        return .coreAIUnavailable
    }
}

// MARK: - client (seam + args 绑定 + 注册壳)

enum GenerateVideoClient {

    static let toolName = "generate_video"

    /// 按平台能力选 backend： 有 CoreAI 且 >=27.0 → RealVideoBackend； 否则 PlatformVideoBackend。
    static func selectedBackend() -> VideoGenerationBackend {
        if #available(macOS 27.0, iOS 27.0, *) {
            #if canImport(CoreAI)
            return RealVideoBackend()
            #else
            return PlatformVideoBackend()
            #endif
        }
        return PlatformVideoBackend()
    }

    static func toolEntry(
        backend: VideoGenerationBackend = selectedBackend()
    ) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "video",
            argsType: GenerateVideo.Args.self,
            description:
                "Video generation: turn a text prompt into a short video clip "
                + "(81 frames default, clamped 5...81; fps default 16, clamped 1...60; "
                + "width/height default 832x480, clamped 32...1280). "
                + "Returns the local file path of the rendered clip (.mp4 by default; "
                + ".gif/.apng/.webp also supported). Requires macOS 27 / iOS 27 + a "
                + "Wan 2.1 weight deployment under ~/Library/Application Support/ocoreai/wan2.1; "
                + "below the floor or without weights it reports the blocker honestly.",
            schema: ToolSchema(parameters: [
                "prompt": ToolParameter(
                    type: .string,
                    description: "What the video should depict (subject, motion, style). Required."
                ),
                "numFrames": ToolParameter(
                    type: .integer,
                    description:
                        "Frame count (default 81; clamped to 5...81, 4k+1 preferred: 17,33,49,65,81)."
                ),
                "fps": ToolParameter(
                    type: .integer,
                    description: "Playback fps (default 16; clamped 1...60)."
                ),
                "width": ToolParameter(
                    type: .integer,
                    description: "Pixel width (default 832; clamped 32...1280)."
                ),
                "height": ToolParameter(
                    type: .integer,
                    description: "Pixel height (default 480; clamped 32...1280)."
                ),
                "steps": ToolParameter(
                    type: .integer,
                    description:
                        "Denoising steps (default 50; clamped 1...60). More = higher fidelity, slower."
                ),
                "seed": ToolParameter(
                    type: .integer,
                    description:
                        "Deterministic RNG seed (default 42). Same seed + params → same clip."
                ),
                "format": ToolParameter(
                    type: .string,
                    description: "Output format: mp4 | gif | apng | webp (default mp4)."
                ),
            ])
        ) { args in
            await runForTool(args: args, backend: backend)
        }
    }

    static func runForTool(
        args: GenerateVideo.Args,
        backend: VideoGenerationBackend
    ) async -> String {
        let built = GenerateVideo.build(args)
        let dir =
            FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let outDir = dir.appendingPathComponent("ocoreai/video-output", isDirectory: true)
        if !FileManager.default.fileExists(atPath: outDir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: outDir, withIntermediateDirectories: true)
            } catch { return GenerateVideo.errorReport(error.localizedDescription) }
        }
        let ext = GenerateVideo.extensionFor(built.format)
        let name = "gen-\(built.seed)-\(built.numFrames)fps\(built.fps).\(ext)"
        let out = outDir.appendingPathComponent(name)
        let outcome = await backend.generate(built: built, outputURL: out)
        switch outcome {
        case .ok(let url, let frameCount):
            return GenerateVideo.report(outcome: outcome)
        case .belowFloor:
            return "generate_video: error: needs macOS 27 / iOS 27 (this OS is below the floor)"
        case .coreAIUnavailable:
            return "generate_video: error: CoreAI framework not available in this build"
        case .weightsMissing:
            let w =
                "~/Library/Application Support/ocoreai/wan2.1 (3 files: Transformer.aimodel+TextEncoder.aimodel+VAEDecoder.aimodel)"
            return
                "generate_video: error: Wan 2.1 weights not deployed — put the 3 .aimodel files under \(w) and retry"
        case .failed(let reason):
            return "generate_video: error: \(reason)"
        }
    }
}
