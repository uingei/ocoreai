// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Audio I/O service — microphone capture + TTS playback + STT transcription + VAD
///
/// Cross-platform: AVFoundation available on macOS, iOS, iPadOS.
/// Recording via AVAudioRecorder (16kHz mono — STT sufficient),
/// TTS via AVSpeechSynthesizer, STT via SFSpeechRecognizer.
///
/// Voice Activity Detection (VAD): Practical energy-based VAD using
/// `AVAudioRecorder.isMeteringEnabled` power level thresholding.
/// Detects speech vs silence to auto-stop transcription on extended quiet periods.
///
/// NOTE: macOS 26+ SpeechAnalyzer + SpeechDetector provides a hardware-backed
/// VAD alternative, but requires CaptureInputSequenceProvider (Beta) and a
/// different streaming pipeline. Energy-based VAD is the production-ready path
/// for macOS 26 with stable APIs.
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import AVFoundation
import AudioToolbox
import Foundation
import Speech
import os.log

private let audioLogger = Logger(subsystem: "ocoreai", category: "audioio")

/// Audio feedback — start/stop beeps via AudioToolbox
private enum AudioFeedback {
    /// Play a short system sound
    static func play(_ soundID: UInt32 = 1108) {
        AudioServicesPlaySystemSound(soundID)
    }

    /// Recording start sound (subtle)
    static func playRecordingStart() {
        Self.play(1108)
    }

    /// Recording end sound
    static func playRecordingEnd() {
        Self.play(1104)
    }

    /// Transcription started sound
    static func playTranscriptionStart() {
        Self.play(1108)
    }

    /// Transcription completed sound
    static func playTranscriptionEnd() {
        Self.play(1104)
    }
}

@Observable
@MainActor
final class AudioIO: NSObject {
    static let shared = AudioIO()

    // MARK: - Microphone state

    /// Is recording
    var isRecording: Bool = false

    // MARK: - TTS state

    /// Is speaking
    var isSpeaking: Bool = false

    // MARK: - STT state

    /// Is recognizing (voice-to-text in progress)
    var isRecognizing: Bool = false

    /// Recognized text (final result)
    var recognizedText: String = ""

    /// Partial transcription text (real-time streaming)
    var partialText: String = ""

    // MARK: - VAD state

    /// Current audio power level (-160 to 0 dB, higher = louder)
    var audioPowerLevel: Float = -160

    /// Whether speech is currently detected (based on VAD threshold)
    var isSpeechDetected: Bool = false

    /// VAD: power-level tracking via tap buffer RMS.
    /// macOS AVAudioInputNode has no metering API — compute from tap buffers.
    private var _vadRMS: Float = 0
    private var _vadTapCount: Int = 0

    /// Returns approximate dB level from recent tap buffers.
    private var vadDBLevel: Float {
        if _vadTapCount == 0 { return -160 }
        return 20 * log10(_vadRMS)
    }

    // MARK: - VAD Configuration

    /// VAD silence threshold in dB (default -40 dB)
    /// Values below this are considered silence/noise.
    let vadSilenceThreshold: Float = -40.0

    /// Consecutive silence samples to trigger VAD end
    /// (each sample = ~100ms, so 15 = ~1.5s of silence)
    let vadSilenceSamples: Int = 15

    // MARK: - Internal

    private let synthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?
    private var recordedURL: URL?
    private let audioEngine = AVAudioEngine()

    @MainActor
    override init() {
        super.init()
        // Wire delegate so didFinish/didCancel reset `isSpeaking` — without
        // this the flag stays true forever once speak() is called, corrupting
        // the SpeakerFeedbackSensor perception channel and the UI state pill.
        synthesizer.delegate = self
        Task {
            if #available(macOS 15, *) {
                await AVCaptureDevice.requestAccess(for: .audio)
            }
        }
    }

    /// Start recording audio — 16kHz mono (STT only needs 16kHz)
    func startRecording(maxDuration _: TimeInterval = 30) async -> Bool {
        guard !isRecording else { return false }
        _ = await hasMicPermission()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        recordedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_audio_\(UUID().uuidString).caf")
        guard let url = recordedURL else { return false }

        beginRecording(to: url, settings: settings)
        AudioFeedback.playRecordingStart()
        return true
    }

    /// Stop recording and return audio as base64 data URL
    ///
    /// - Parameter keepFile: when `true`, the .caf file stays on disk and
    ///   `recordedURL` remains valid so a file-based consumer (the L3 local
    ///   engine via `transcribeFromFile()`) can use it; the caller owns
    ///   cleanup. Default `false` preserves the historical consume-and-delete
    ///   behavior (VLM raw-audio path).
    func stopRecording(keepFile: Bool = false) async -> String? {
        guard isRecording else { return nil }
        stopRecordingInternal()
        isRecording = false
        AudioFeedback.playRecordingEnd()

        guard let url = recordedURL,
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            if !keepFile {
                try? FileManager.default.removeItem(at: url)
            }
            return "data:audio/caf;base64,\(data.base64EncodedString())"
        } catch {
            audioLogger.error("[AudioIO] Failed to read recording: \(error.localizedDescription)")
            return nil
        }
    }

    /// Transcribe the LAST recorded file on the ladder's local engine (L3).
    ///
    /// macOS 26 / iOS 26+: `LocalSTT` runs the stored .caf OFFLINE via the
    /// Speech framework — no network, no cloud dictation. Below the floor
    /// (macOS 14/15, iOS 17/18) it falls back to the live-mic
    /// `SFSpeechRecognizer` + VAD path so press-to-talk never regresses.
    ///
    /// Precondition (ladder = `.localSpeechFile`): `stopRecording(keepFile:
    /// true)` kept the file on disk and `recordedURL` points at it.
    func transcribeFromFile() async -> String? {
        // Resolution: user preference (Settings ▸ Voice Feedback) × the
        // adaptive ladder. "cloud" always forces live-mic dictation;
        // "local" forces the offline file engine if the OS supports it
        // (else graceful live-mic fallback); "auto" follows the ladder
        // (local on macOS 26 / iOS 26+, cloud below).
        let preference = SettingsStore.shared.sttEngine
        let ladderLocal = AudioStack.current.stt == .localSpeechFile
        let useLocal =
            (preference == "cloud")
            ? false
            : (preference == "local")
                ? true
                : ladderLocal

        if useLocal, #available(macOS 26.0, iOS 26.0, *),
            let url = recordedURL,
            FileManager.default.fileExists(atPath: url.path)
        {
            do {
                let text = try await LocalSTT.transcribe(
                    url: url, locale: Locale(identifier: OCALocale.userSelected().bcp47Tag))
                try? FileManager.default.removeItem(at: url)
                if !text.isEmpty {
                    recognizedText = text
                    audioLogger.info("[AudioIO] LocalSTT OK — \(text.count) chars (offline)")
                    return text
                }
                audioLogger.info("[AudioIO] LocalSTT empty — live-mic fallback")
            } catch {
                audioLogger.error(
                    "[AudioIO] LocalSTT failed: \(error.localizedDescription) — live-mic fallback")
            }
            try? FileManager.default.removeItem(at: url)
        } else if preference == "local" {
            audioLogger.info(
                "[AudioIO] sttEngine=.local requested but OS below the local floor (macOS 26 / iOS 26) or no file — live-mic fallback"
            )
            // Clean any leftover file from keepFile:true
            if let url = recordedURL, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        } else if ladderLocal, let url = recordedURL {
            // Auto ladder is local but the file is gone/other guard miss —
            // still clean up defensively.
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        return await transcribe(timeout: 20, useVAD: true, feedback: false)
    }

    /// Toggle recording on/off
    func toggleRecording() async -> String? {
        if isRecording {
            return await stopRecording()
        }
        _ = await startRecording()
        return nil
    }

    private func beginRecording(to url: URL, settings: [String: Any]) {
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            recorder?.record()
            isRecording = true
        } catch {
            audioLogger.error("[AudioIO] Recording error: \(error.localizedDescription)")
            isRecording = false
        }
    }

    private func stopRecordingInternal() {
        recorder?.stop()
        recorder = nil
    }
}

// MARK: - TTS

extension AudioIO {
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // Match TTS voice to current app locale (BCP 47 tag: "zh-Hans", "ja", "en", ...).
        // L1 of the adaptive audio ladder (see AudioStack): the user's Personal
        // Voice has a floor of macOS 14 / iOS 17 — exactly ocoreai's deployment
        // floor — so it is eligible on all eight target versions with no
        // #available. Selection is opt-in (Settings ▸ Voice Feedback); off, or
        // not yet authorized in System Settings, keeps the regular locale
        // voice. resolveVoice() never returns a failing voice.
        let langTag = OCALocale.userSelected().languageCode
        utterance.voice = PersonalVoiceTTS.resolveVoice(
            enabled: SettingsStore.shared.enablePersonalVoice, language: langTag)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - Speech-to-Text with VAD

extension AudioIO {
    /// Request authorization for speech recognition
    func requestSpeechPermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return granted
    }

    /// Check microphone permission — macOS uses AVCaptureDevice.requestAccess
    func hasMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Continuous speech recognition with VAD-gated auto-stop.
    ///
    /// Voice Activity Detection: Monitors audio power level via metering.
    /// When consecutive samples fall below threshold, transcription ends automatically
    /// — no need to wait for the full timeout on silent segments.
    ///
    /// - Parameters:
    ///   - timeout: Maximum recognition duration in seconds
    ///   - useVAD: Enable voice activity detection (default: true)
    ///   - feedback: Play start/end system feedback sounds (default: true).
    ///     Continuous perception loops pass false — beeping every cycle is not
    ///     feedback, it's noise.
    /// - Returns: Final transcribed text, or nil on cancel/error.
    ///   Partial results streamed to `partialText` property.
    func transcribe(timeout: TimeInterval = 30, useVAD: Bool = true, feedback: Bool = true) async
        -> String?
    {
        // 1. Check authorization
        let authorized = await requestSpeechPermission()
        guard authorized else {
            audioLogger.error("[AudioIO] Speech recognition not authorized")
            return nil
        }

        guard
            let recognizer = SFSpeechRecognizer(
                locale: Locale(identifier: OCALocale.userSelected().bcp47Tag))
        else {
            audioLogger.error("[AudioIO] No available speech recognizer")
            return nil
        }

        // Setup audio engine
        audioEngine.stop()
        audioEngine.reset()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buffer, _ in
            request.append(buffer)
            // VAD: compute RMS from tap buffer for power-level tracking
            if let self = self, useVAD {
                let channelData = buffer.floatChannelData?.pointee
                let frameCount = Int(buffer.frameLength)
                if let channelData = channelData, frameCount > 0 {
                    var rmsSum: Float = 0
                    for i in 0 ..< frameCount {
                        let sample = channelData[i]
                        rmsSum += sample * sample
                    }
                    let rms = sqrt(rmsSum / Float(frameCount))
                    // Exponential moving average to smooth per-buffer spikes
                    self._vadRMS = self._vadRMS * 0.8 + rms * 0.2
                    self._vadTapCount += 1
                }
            }
        }

        // VAD: power-level tracking via tap buffer RMS.
        // AVAudioInputNode has no metering API on macOS — compute from audio buffers.
        if useVAD {
            audioLogger.info("[AudioIO] VAD enabled — RMS-based silence detection")
        }

        try? audioEngine.start()
        isRecognizing = true
        recognizedText = ""
        partialText = ""
        if feedback { AudioFeedback.playTranscriptionStart() }

        do {
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard let result else { return }
                _ = Task { @MainActor in
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        AudioIO.shared.recognizedText = text
                    } else {
                        AudioIO.shared.partialText = text
                    }
                }
            }

            // VAD monitoring loop — runs concurrently with transcription
            var vadConsecutiveSilence: Int = 0

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, isRecognizing {
                // VAD: actual power-level based silence detection via tap buffer RMS.
                // Reads dB level from exponential-moving-average of tap buffer.
                if useVAD {
                    let power = vadDBLevel
                    audioPowerLevel = power

                    if power > vadSilenceThreshold {
                        vadConsecutiveSilence = 0
                        isSpeechDetected = true
                    } else {
                        vadConsecutiveSilence += 1
                        isSpeechDetected = false
                    }

                    // Auto-stop on extended silence (vadSilenceSamples * 100ms ≈ N seconds)
                    if vadConsecutiveSilence >= vadSilenceSamples {
                        audioLogger.info(
                            "[AudioIO] VAD: extended silence detected (\(vadConsecutiveSilence) samples, \(power)dB), ending transcription"
                        )
                        break
                    }
                }

                // Yield to let recognition process — check cancellation per concurrency §28
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }

            // Check if we got final text
            let finalText = recognizedText.isEmpty ? partialText : recognizedText
            if finalText.isEmpty && !recognizedText.isEmpty {
                recognizedText = recognizedText
            }

            task.cancel()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            isRecognizing = false
            partialText = ""
            if feedback { AudioFeedback.playTranscriptionEnd() }

            if !recognizedText.isEmpty {
                return recognizedText
            }
            return nil
        } catch {
            audioLogger.error("[AudioIO] STT error: \(error.localizedDescription)")
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            isRecognizing = false
            partialText = ""
            if feedback { AudioFeedback.playTranscriptionEnd() }
            return nil
        }
    }

    /// Cancel ongoing recognition immediately
    func cancelTranscription() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecognizing = false
        partialText = ""
        AudioFeedback.playRecordingEnd()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AudioIO: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        Task { @MainActor in
            AudioIO.shared.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            AudioIO.shared.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in
            AudioIO.shared.isSpeaking = false
        }
    }
}
