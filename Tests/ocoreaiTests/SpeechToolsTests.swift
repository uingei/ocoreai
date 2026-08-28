// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `transcribe_audio` + `speak` 工具 — 精确值测试(全离线, fake backend, 不触 OS Speech/TTS).
///
/// 覆盖两组 seam:
///   transcribe_audio: `TranscribeAudio.build`(locale/maxChars clamp 100...8000)
///                     + `TranscribeAudio.report`(精确两行形态、trim、cap+…)
///                     + `TranscribeAudioClient.runForTool` 5 种 outcome 映射。
///   speak:           `Speak.build`(trim/空→ok=false/超上限截断)+ `Speak.report`
///                     + `SpeakClient.runForTool` 成功/空文本 error。

import Foundation
import Testing

@testable import ocoreai

/// 文件级假 STT 后端 — parser/client 测试复用(离线, 不发真实识别).
/// 观察量(收到的 locale)走共享引用 cell, 避开 struct 协议见证不能改 self 的约束。
final class RefBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

struct FakeSTT: STTTranscriber {
    let outcome: STTOutcome
    let lastLocale: RefBox<String>
    init(outcome: STTOutcome, lastLocale: RefBox<String> = RefBox<String>("")) {
        self.outcome = outcome
        self.lastLocale = lastLocale
    }
    nonisolated func transcribe(url: URL, locale: Locale) async -> STTOutcome {
        lastLocale.value = locale.identifier
        return outcome
    }
}

/// 文件级假 TTS 后端 — 记录被 speak 的文本, 不触发 OS 语音合成.
struct FakeTTS: TTSBackend {
    let spoken: RefBox<[String]>
    init(spoken: RefBox<[String]> = RefBox<[String]>([])) {
        self.spoken = spoken
    }
    nonisolated func speak(_ text: String) async {
        spoken.value.append(text)
    }
}

// MARK: - transcribe_audio: 请求构建

@Suite("transcribe_audio request construction")
struct TranscribeAudioRequestTests {

    @Test
    func defaultLocaleIsAppLocaleWithDefaultCap() {
        let b = TranscribeAudio.build(locale: nil, maxChars: nil)
        #expect(b.maxChars == TranscribeAudio.defaultMaxChars)
        #expect(!b.localeIdentifier.isEmpty)
    }

    @Test
    func explicitLocaleIsPreserved() {
        let b = TranscribeAudio.build(locale: "zh-Hans", maxChars: nil)
        #expect(b.localeIdentifier == "zh-Hans")
    }

    @Test
    func clampsBelowMinTo100() {
        let b = TranscribeAudio.build(locale: nil, maxChars: 1)
        #expect(b.maxChars == 100)
    }

    @Test
    func clampsAboveMaxTo8000() {
        let b = TranscribeAudio.build(locale: nil, maxChars: 100_000)
        #expect(b.maxChars == 8000)
    }

    @Test
    func preservesInRangeValue() {
        let b = TranscribeAudio.build(locale: nil, maxChars: 1234)
        #expect(b.maxChars == 1234)
    }

    @Test
    func zeroAndNegativeClampToFloor() {
        #expect(TranscribeAudio.build(locale: nil, maxChars: 0).maxChars == 100)
        #expect(TranscribeAudio.build(locale: nil, maxChars: -5).maxChars == 100)
    }
}

@Suite("transcribe_audio report shape")
struct TranscribeAudioReportTests {

    @Test
    func shortTextIsVerbatimWithCount() {
        let r = TranscribeAudio.report(
            text: "hello world", localeIdentifier: "en-US", maxChars: 2000)
        let lines = r.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "transcribe_audio OK — 11 chars (locale=en-US)")
        #expect(lines[1] == "hello world")
    }

    @Test
    func leadingTrailingWhitespaceIsTrimmedBeforeCountAndBody() {
        let r = TranscribeAudio.report(text: "  padded  ", localeIdentifier: "en", maxChars: 2000)
        #expect(r.contains("transcribe_audio OK — 6 chars (locale=en)"))
        #expect(r.contains("\npadded"))
    }

    @Test
    func overLimitIsCappedWithEllipsis() {
        let text = String(repeating: "a", count: 30)
        let r = TranscribeAudio.report(text: text, localeIdentifier: "en", maxChars: 10)
        // 计数用 trim 后全长(30), 正文只留前 10 个 'a' + '…'
        #expect(r.contains("30 chars"))
        #expect(r.contains(String(repeating: "a", count: 10) + "…"))
    }

    @Test
    func exactlyLimitHasNoEllipsis() {
        let text = String(repeating: "a", count: 10)
        let r = TranscribeAudio.report(text: text, localeIdentifier: "en", maxChars: 10)
        #expect(r.contains(String(repeating: "a", count: 10)))
        #expect(!r.contains("…"))
    }
}

@Suite("transcribe_audio client outcome mapping (fake backend)")
struct TranscribeAudioClientTests {

    @Test
    func successMapsToReport() async {
        let out = await TranscribeAudioClient.runForTool(
            path: "/tmp/x.caf", locale: "en-US", maxChars: 2000,
            backend: FakeSTT(outcome: .success(text: "  hello world "))
        )
        #expect(out.contains("transcribe_audio OK — 11 chars (locale=en-US)"))
        #expect(out.contains("hello world"))
    }

    @Test
    func noSpeechMapsToHonestError() async {
        let out = await TranscribeAudioClient.runForTool(
            path: "/tmp/x.caf", locale: nil, maxChars: nil,
            backend: FakeSTT(outcome: .noSpeech))
        #expect(out == "transcribe_audio: error: no recognizable speech in the file")
    }

    @Test
    func belowFloorMapsToHonestError() async {
        let out = await TranscribeAudioClient.runForTool(
            path: "/tmp/x.caf", locale: nil, maxChars: nil,
            backend: FakeSTT(outcome: .belowFloor))
        #expect(out.contains("macOS 26 / iOS 26+"))
        #expect(out.hasPrefix("transcribe_audio: error:"))
    }

    @Test
    func fileMissingMapsToHonestErrorWithPath() async {
        let out = await TranscribeAudioClient.runForTool(
            path: "/tmp/missing.caf", locale: nil, maxChars: nil,
            backend: FakeSTT(outcome: .fileMissing))
        #expect(out == "transcribe_audio: error: file not found at /tmp/missing.caf")
    }

    @Test
    func failureMapsReason() async {
        let out = await TranscribeAudioClient.runForTool(
            path: "/tmp/x.caf", locale: nil, maxChars: nil,
            backend: FakeSTT(outcome: .failed("boom")))
        #expect(out == "transcribe_audio: error: boom")
    }

    @Test
    func emptyPathIsRejected() async {
        let out = await TranscribeAudioClient.runForTool(
            path: "   ", locale: nil, maxChars: nil,
            backend: FakeSTT(outcome: .success(text: "x")))
        #expect(out == "transcribe_audio: error: path is required")
        // 真空路径同被驳回
        #expect(
            await TranscribeAudioClient.runForTool(
                path: "", locale: nil, maxChars: nil, backend: FakeSTT(outcome: .success(text: "x"))
            )
                == "transcribe_audio: error: path is required")
    }

    @Test
    func localeIsForwardedToBackend() async {
        let obs = RefBox<String>("")
        _ = await TranscribeAudioClient.runForTool(
            path: "/tmp/x.caf", locale: "ja-JP", maxChars: 2000,
            backend: FakeSTT(outcome: .success(text: "ok"), lastLocale: obs))
        #expect(obs.value == "ja-JP")
    }
}

// MARK: - speak: 请求构建 + 报告

@Suite("speak request construction + report")
struct SpeakRequestTests {

    @Test
    func trimsWhitespaceAndIsOK() {
        let b = Speak.build("  hi there  ")
        #expect(b.ok == true)
        #expect(b.text == "hi there")
    }

    @Test
    func emptyAndWhitespaceOnlyAreRejected() {
        #expect(Speak.build("").ok == false)
        #expect(Speak.build("     ").ok == false)
        #expect(Speak.build("").text == "")
    }

    @Test
    func overLimitIsTruncated() {
        let b = Speak.build(String(repeating: "a", count: 9000))
        #expect(b.ok == true)
        #expect(b.text.count == Speak.maxMaxChars)
    }

    @Test
    func reportShowsEnqueuedFactAndLocale() {
        let r = Speak.report(enqueued: true, text: "hello", localeIdentifier: "zh-Hans")
        #expect(r == "speak OK — 5 chars enqueued (locale=zh-Hans)")
    }

    @Test
    func reportUnenqueuedIsError() {
        let r = Speak.report(enqueued: false, text: "hello", localeIdentifier: "en")
        #expect(r == "speak: error: speech synthesis unavailable")
    }
}

@Suite("speak client (fake backend)")
struct SpeakClientTests {

    @Test
    func successForwardsTextAndReports() async {
        let fake = FakeTTS()
        let out = await SpeakClient.runForTool(text: "  read this out ", backend: fake)
        #expect(fake.spoken.value.count == 1)
        #expect(fake.spoken.value[0] == "read this out")
        #expect(out.hasPrefix("speak OK —"))
        #expect(out.contains("chars enqueued"))
    }

    @Test
    func emptyTextIsRejectedWithoutSpeaking() async {
        let fake = FakeTTS()
        let out = await SpeakClient.runForTool(text: "   ", backend: fake)
        #expect(fake.spoken.value.isEmpty)
        #expect(out == "speak: error: no text to speak")
    }

    @Test
    func longTextIsCappedBeforeHandoff() async {
        let fake = FakeTTS()
        _ = await SpeakClient.runForTool(text: String(repeating: "b", count: 9000), backend: fake)
        #expect(fake.spoken.value[0].count == Speak.maxMaxChars)
    }
}

// MARK: - STTDecision: OS 真值裁决(纯)

/// `STTDecision.decide` — 文本空时, `SpeechDetector` 硬件 VAD 真值决定
/// 「真没语音」还是「有语音但没认出词」。纯函数, 精确断言。
@Suite("STTDecision — honest no-speech arbitration (pure)")
struct STTDecisionTests {

    @Test
    func nonEmptyTextIsSuccessRegardlessOfDetector() {
        #expect(
            STTDecision.decide(trimmedText: "hello", osDetected: false, osOutcome: .noSpeech)
                == .success(text: "hello"))
    }

    @Test
    func emptyTextUndetectedIsHonestNoSpeech() {
        #expect(
            STTDecision.decide(trimmedText: "", osDetected: false, osOutcome: .noSpeech)
                == .noSpeech)
    }

    @Test
    func emptyTextButDetectorFiredIsFailedWithReason() {
        #expect(
            STTDecision.decide(trimmedText: "", osDetected: true, osOutcome: .noSpeech)
                == .failed("speech was detected but no words were transcribed"))
    }

    @Test
    func osOutcomePassthrough() {
        #expect(
            STTDecision.decide(trimmedText: "", osDetected: false, osOutcome: .fileMissing)
                == .fileMissing)
        #expect(
            STTDecision.decide(trimmedText: "", osDetected: false, osOutcome: .belowFloor)
                == .belowFloor)
        #expect(
            STTDecision.decide(trimmedText: "", osDetected: false, osOutcome: .failed("boom"))
                == .failed("boom"))
    }
}
