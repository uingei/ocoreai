// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// 听觉 + 语音反馈轴的 agent 可触面(两个工具),复用 ocoreai 已有、已在 UI/passive 侧
/// 消费的音频基设,不平行另造:
///
///   transcribe_audio  听觉感知   — 复用 `LocalSTT`(L3, macOS/iOS 26+ 离线 Speech
///                                   framework)+ `AudioIO` 的 live-mic 兜底阶梯
///   speak             语音反馈   — 复用 `AudioIO.speak` + `PersonalVoiceTTS`(L1,
///                                   用户自己的声音, floor=部署 floor 14/17)
///
/// 形态先例 = `view_screen`(ScreenCaptureTool.swift):同一套「基设已建、补 agent 面」,
/// 纯核对(请求构建/报告形态/纯逻辑)= testable, 真实 I/O 收口到一个 protocol seam,
/// 测试注入 fake 不触 OS。MLX 工具通道文本-only(同 view_image/web_fetch),所以
/// transcribe 返回识别出的**文字**(非音频), speak 返回已入队的事实(非音频流)。
///
/// 三仓基准无 audio 工具(codex/coreai-models/mlx-swift-lm 均不 ship)→ Apple 原生轴
/// 自有面, 不引入基准行为分叉。
import AVFoundation
import Foundation

// MARK: - transcribe_audio

/// 规范化识别请求 + 报告构建 = 纯函数(无 I/O, 离线可测)。
enum TranscribeAudio {
    /// 识别文本长度边界 — clamp 到有限、诚实的 token 预算。
    static let defaultMaxChars = 2000
    static let minMaxChars = 100
    static let maxMaxChars = 8000

    struct Built: Equatable {
        let localeIdentifier: String
        let maxChars: Int
    }

    /// `locale` = BCP-47 tag(nil → follow the app's locale);`maxChars` nil→default, 0/负→按 100,
    /// 否则 clamp 进 [100, 8000]。
    static func build(locale: String?, maxChars: Int?) -> Built {
        let tag = (locale ?? OCALocale.userSelected().bcp47Tag)
        var cap = defaultMaxChars
        if let raw = maxChars {
            cap = min(max(raw, minMaxChars), maxMaxChars)
        }
        return Built(localeIdentifier: tag, maxChars: cap)
    }

    /// 精确两/三行报告(可离线断言):
    /// ```
    /// transcribe_audio OK — 123 chars (locale=zh-Hans)
    /// <text>            （超过 maxChars 时末尾加 …,且只保留前 maxChars 字符）
    /// ```
    static func report(
        text: String, localeIdentifier: String, maxChars: Int
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(trimmed.prefix(maxChars))
        let ellipsis = trimmed.count > maxChars ? "…" : ""
        return "transcribe_audio OK — \(trimmed.count) chars (locale=\(localeIdentifier))\n"
            + head + ellipsis
    }
}

/// 识别结果 — 区分「有文字 / 无文字 / 低于 floor / 文件缺失 / 失败」,
/// 让工具诚实地告诉模型发生了什么(对齐 view_screen 的 honest error 先例)。
enum STTOutcome: Equatable {
    case success(text: String)
    case noSpeech
    case belowFloor
    case fileMissing
    case failed(String)
}

/// STT 后端 seam — 唯一的真实 I/O 边界。平台实现包裹 `LocalSTT`(L3 离线);
/// 测试注入 fake,不触 OS Speech 引擎、不下载资产。
protocol STTTranscriber: Sendable {
    func transcribe(url: URL, locale: Locale) async -> STTOutcome
}

/// 纯判定(无 I/O,可单测):`(OS 文本, SpeechDetector 检出?, OS outcome) → outcome`。
/// 规则:
///   - 文本非空 → `.success`(以 trim 后为准)
///   - 文本空 + OS outcome 非 `.noSpeech` → 沿用 OS 语义(fileMissing/belowFloor/failed)
///   - 文本空 + `.noSpeech`:检测器检出过语音 → `.failed`(有语音无词 ≠ 真无语音);
///     未检出 → `.noSpeech`(诚实)
enum STTDecision {
    static func decide(
        trimmedText: String,
        osDetected: Bool,
        osOutcome: STTOutcome
    ) -> STTOutcome {
        if !trimmedText.isEmpty {
            return .success(text: trimmedText)
        }
        switch osOutcome {
        case .noSpeech:
            return osDetected
                ? .failed("speech was detected but no words were transcribed")
                : .noSpeech
        case .success, .fileMissing, .belowFloor, .failed:
            return osOutcome
        }
    }
}

/// 平台实现: 优先 `LocalSTT` 离线引擎(macOS/iOS 26+);文件缺失/低于 floor 给出
/// 可区分的诚实 outcome。OS 语义由 `LocalSTT`(locale 无模型时 en-US best-effort)+
/// `SpeechDetector`(硬件 VAD 真值)产生;裁决收在纯 `STTDecision.decide`。
struct PlatformSTTTranscriber: STTTranscriber, @unchecked Sendable {
    // 无共享可变状态(纯转发 LocalSTT 静态 API + 纯裁决),故 @unchecked Sendable 安全。
    nonisolated func transcribe(url: URL, locale: Locale) async -> STTOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fileMissing }
        guard #available(macOS 26.0, iOS 26.0, *) else { return .belowFloor }
        do {
            let result = try await LocalSTT.transcribe(url: url, locale: locale)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .success(text: trimmed)
            }
            return STTDecision.decide(
                trimmedText: "", osDetected: result.detected, osOutcome: .noSpeech)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - speak

/// TTS 入队 = 纯核对(文本清洗、空校验、长度上限)+ 报告。真实播报收口到 seam。
enum Speak {
    /// 单次播报长度上限 — 防止把整段长文整句念出(token/时长双失控);默认与上限一致,
    /// 超长只念前面。
    static let defaultMaxChars = 4000
    static let maxMaxChars = 8000

    struct Built: Equatable {
        let text: String
        let ok: Bool
    }

    /// `text` → trim → canonical TTS cleaning (strip `<thinking>` tags +
    /// fenced ``` code blocks — never spoken) → truncate to `maxChars`.
    ///
    /// The cleaning step routes through ``TTSCleaning`` so the agent `speak`
    /// tool and the chat speaker apply the exact same pre-sink cleaning.
    /// `maxChars` defaults to the historical agent cap (8000); pass a smaller
    /// value (e.g. `TTSCleaning.speakerDefaultCap`) for the speaker UX.
    static func build(_ text: String, maxChars: Int = maxMaxChars) -> Built {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Built(text: "", ok: false) }
        let speakable = TTSCleaning.speakable(trimmed, maxChars)
        guard !speakable.isEmpty else { return Built(text: "", ok: false) }
        return Built(text: speakable, ok: true)
    }

    /// 报告(可离线断言): `speak OK — 123 chars enqueued (locale=<tag>)`。
    /// 不宣称「播完了」—— AVSpeechSynthesizer 是 OS 异步驱动,入队即成功事实。
    static func report(enqueued: Bool, text: String, localeIdentifier: String) -> String {
        guard enqueued else { return "speak: error: speech synthesis unavailable" }
        return "speak OK — \(text.count) chars enqueued (locale=\(localeIdentifier))"
    }
}

/// TTS 后端 seam — 真实 I/O 边界。平台实现包裹 `AudioIO.speak`(内部已 resolve
/// Personal Voice);测试注入 fake 记录调用,不触发 OS 语音合成。
protocol TTSBackend: Sendable {
    func speak(_ text: String) async
}

struct PlatformTTSBackend: TTSBackend, @unchecked Sendable {
    // 无共享可变状态(转发 AudioIO 单例, MainActor 隔离),故 @unchecked Sendable 安全。
    nonisolated func speak(_ text: String) async {
        await MainActor.run { AudioIO.shared.speak(text) }
    }
}

// MARK: - Clients(seam + args 绑定)

enum TranscribeAudioClient {

    static let toolName = "transcribe_audio"

    static func toolEntry(
        backend: STTTranscriber = PlatformSTTTranscriber()
    ) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "audio",
            argsType: Args.self,
            description:
                "Hear an audio file: transcribe it to text using ocoreai's local offline "
                + "speech engine (macOS 26 / iOS 26+) and return the recognized words. "
                + "Use to read out what was said in a recorded .caf/.m4a/.mp3/.wav file. "
                + "Below the OS floor it reports which, instead of silently failing.",
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string,
                    description: "Filesystem path to the audio file to transcribe."
                ),
                "locale": ToolParameter(
                    type: .string,
                    description:
                        "BCP-47 language tag to recognize (default: the app's current locale)."
                ),
                "max_chars": ToolParameter(
                    type: .integer,
                    description:
                        "Cap on returned text length (default 2000; clamped 100...8000). Set 0 to get at least the floor."
                ),
            ])
        ) { args in
            await runForTool(
                path: args.path, locale: args.locale, maxChars: args.max_chars, backend: backend)
        }
    }

    struct Args: Codable, Sendable {
        let path: String
        let locale: String?
        let max_chars: Int?
    }

    static func runForTool(
        path: String, locale: String?, maxChars: Int?,
        backend: STTTranscriber = PlatformSTTTranscriber()
    ) async -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "transcribe_audio: error: path is required"
        }
        let built = TranscribeAudio.build(locale: locale, maxChars: maxChars)
        let outcome = await backend.transcribe(
            url: URL(fileURLWithPath: path),
            locale: Locale(identifier: built.localeIdentifier)
        )
        switch outcome {
        case .success(let text):
            return TranscribeAudio.report(
                text: text, localeIdentifier: built.localeIdentifier, maxChars: built.maxChars)
        case .noSpeech:
            return "transcribe_audio: error: no recognizable speech in the file"
        case .belowFloor:
            return "transcribe_audio: error: local offline speech needs macOS 26 / iOS 26+ "
                + "(this OS is below the floor — the mic press-to-talk path via Settings still works)"
        case .fileMissing:
            return "transcribe_audio: error: file not found at \(path)"
        case .failed(let reason):
            return "transcribe_audio: error: \(reason)"
        }
    }
}

enum SpeakClient {

    static let toolName = "speak"

    static func toolEntry(backend: TTSBackend = PlatformTTSBackend()) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "audio",
            argsType: Args.self,
            description:
                "Voice feedback: speak the given text aloud with the user's voice "
                + "(Personal Voice when enabled and authorized, else the closest locale voice). "
                + "Use to read a result out loud instead of — or on top of — the written reply.",
            schema: ToolSchema(parameters: [
                "text": ToolParameter(
                    type: .string,
                    description: "The text to speak aloud (capped at 8000 chars)."
                )
            ])
        ) { args in
            await runForTool(text: args.text, backend: backend)
        }
    }

    struct Args: Codable, Sendable {
        let text: String
    }

    static func runForTool(text: String, backend: TTSBackend = PlatformTTSBackend()) async -> String
    {
        let built = Speak.build(text)
        guard built.ok else {
            return "speak: error: no text to speak"
        }
        let localeTag = OCALocale.userSelected().bcp47Tag
        await backend.speak(built.text)
        return Speak.report(enqueued: true, text: built.text, localeIdentifier: localeTag)
    }
}
