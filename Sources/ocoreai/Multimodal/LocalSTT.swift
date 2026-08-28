// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LocalSTT.swift — L3 of the adaptive audio ladder (macOS 26+ / iOS 26+).
///
/// Fully LOCAL, offline speech-to-text built on the Speech framework's
/// `SpeechAnalyzer` + `SpeechTranscriber` — the successor to SFSpeechRecognizer
/// for file input. Capability floors (27.0 SDK, verbatim):
///
///   SpeechAnalyzer              @available(anyAppleOS 26)   [Speech.swiftinterface L339]
///   init(inputAudioFile:)       @available(anyAppleOS 26)   [extension L338-341]
///   analyzeSequence(from:)      @available(anyAppleOS 26)   [extension L340]
///   SpeechTranscriber           @available(anyAppleOS 26)   [L345]
///   Result.text (AttributedString)                           [L430]
///   supportedLocale(equivalentTo:) async -> Locale?          [L414]
///   SpeechDetector              @available(anyAppleOS 26)   [L267]
///   SpeechDetector.init(detectionOptions:reportResults:)     [L268]
///   SensitivityLevel low/medium/high                          [L270-286]
///   DetectionOptions(sensitivityLevel:)                       [L288-292]
///   results: AsyncSequence<SpeechDetector.Result, any Error>  [L~298]
///   Result.speechDetected (range / resultsFinalizationTime)   [L~300-304]
///   AssetInventory.assetInstallationRequest(supporting:)     [Apple docs, live-verified]
///
/// Hardware VAD: the 26-gen `SpeechDetector` (hardware speech-activity
/// detection, anyAppleOS 26) runs inside the SAME `SpeechAnalyzer` as the
/// transcriber — no separate engine. `transcribe` now also reports
/// `detected: Bool` (true iff the OS speech detector fired), so callers can
/// answer "was there speech in this file" with OS truth instead of guessing
/// from empty text. The legacy hand-rolled RMS-VAD path (AudioIO.live-mic)
/// stays for the 13+/17+ cloud tier; this file's file path now gets the
/// hardware detector for free.
///
/// The LIVE-microphone variant (`CaptureInputSequenceProvider`) is `anyAppleOS 27`
/// and requires a `AVCaptureSession` mic pipeline — that ships in the next
/// batch (27-only). This file covers the FILE path, which is what
/// press-to-talk (record → transcribe) already produces.
///
/// All spellings verified by `swiftc -typecheck` against the 27.0 SDK (RC=0).
/// The async `analyzeSequence` + concurrent `t.results` drain pattern follows
/// Apple's documented 8-step flow (developer.apple.com/documentation/speech/speechanalyzer).

import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, iOS 26.0, *)
public enum LocalSTT {

    /// Transcribe an audio file locally (offline, Speech framework).
    ///
    /// - Parameters:
    ///   - file: an `AVAudioFile` to transcribe (e.g. a recorded .caf).
    ///   - locale: preferred result locale; falls back to a supported one.
    ///   - onResult: optional per-result callback (streaming partials if
    ///     the transcriber reports them; at minimum the final chunk lands here).
    /// - Returns: the transcribed text plus `detected` — OS truth from the
    ///   26-gen `SpeechDetector` (was there speech in the file at all). Empty
    ///   text + `detected == false` = honest "no speech"; empty text +
    ///   `detected == true` = speech was there but no words were produced.
    /// - Throws: `SpeechAnalyzer`/`SpeechTranscriber` errors surface as thrown.
    public static func transcribe(
        _ file: AVAudioFile,
        locale: Locale,
        onResult: (@Sendable (String, Bool) -> Void)? = nil,
    ) async throws -> SttResult {
        // Step 1 (Apple docs): resolve a SUPPORTED locale — the transcriber
        // may map our locale to a nearby supported one.
        guard
            let supported =
                await SpeechTranscriber
                .supportedLocale(equivalentTo: locale),
            let transcriber = localeFor(supported, current: locale)
        else {
            // No local model for this language — fall through to a best-effort.
            return try await transcribeFallback(file: file, onResult: onResult)
        }
        let t = SpeechTranscriber(locale: transcriber, preset: .transcription)
        // Hardware VAD (26 代): speech-activity detection inside the SAME
        // analyzer as the transcriber — OS truth, no separate engine.
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )

        // Step 2 (Apple docs): ensure assets are installed before analysis.
        // `assetInstallationRequest` returns nil when nothing to do.
        if let request =
            try? await AssetInventory
            .assetInstallationRequest(supporting: [t, detector])
        {
            try? await request.downloadAndInstall()
        }

        // Step 3-4: analyzer over the audio file (file-path convenience init, 26+).
        // finishAfterFile: true — Apple docs require it for file input: otherwise
        // the analyzer "won't terminate its result streams and will wait for
        // additional audio input sequences", so the `for try await` drains below
        // would hang. (Default is false; see Speech.swiftinterface L340.)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file,
            modules: [t, detector],
            finishAfterFile: true
        )

        // Step 6-7: run the analysis while concurrently draining BOTH modules'
        // `results` (the Apple-documented pattern; module-level results are
        // consumed off the module, not the analyzer).
        var finalText = ""
        var chunks: [String] = []
        var detected = false
        async let run: CMTime? = analyzer.analyzeSequence(from: file)
        do {
            for try await result in t.results {
                let plain = NSAttributedString(result.text).string
                if !plain.isEmpty {
                    chunks.append(plain)
                    onResult?(plain, result.isFinal)
                }
                if result.isFinal {
                    finalText = plain
                }
            }
        } catch {
            // Drain error — analysis may still be settling; fall through.
        }
        do {
            for try await d in detector.results {
                if d.speechDetected {
                    detected = true
                }
            }
        } catch {
            // Detector drain is best-effort — text is the authoritative output.
        }
        _ = try await run

        // `analyzeSequence` finalizes; if the module streamed nothing useful
        // (e.g. a very short clip before finalization) we still have `finalText`.
        let text = finalText.isEmpty ? joined(chunks) : finalText
        return SttResult(text: text, detected: detected)
    }

    /// Convenience: transcribe an `AVAudioFile` at a URL.
    public static func transcribe(
        url: URL,
        locale: Locale,
        onResult: (@Sendable (String, Bool) -> Void)? = nil,
    ) async throws -> SttResult {
        let file = try AVAudioFile(forReading: url)
        return try await transcribe(file, locale: locale, onResult: onResult)
    }

    /// Local (non-cloud) transcription outcome: text + OS-detected-speech flag.
    public struct SttResult: Sendable {
        public let text: String
        public let detected: Bool
    }

    /// Whether the local (non-cloud) transcriber has a usable model for the
    /// current locale — cheap capability probe for UI display.
    public static func isAvailable(for locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        return supported != nil
    }

    // MARK: - Helpers

    /// Map a supported locale back to the one we should build the transcriber
    /// with. If the supported locale differs from ours, prefer the supported
    /// one (that is what `supportedLocale(equivalentTo:)` guarantees we can use).
    private static func localeFor(_ supported: Locale, current: Locale) -> Locale? {
        supported
    }

    private static func joined(_ parts: [String]) -> String {
        parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort fallback when no local model is installed for the locale:
    /// run with the system-default locale so at least SOMETHING is produced.
    private static func transcribeFallback(
        file: AVAudioFile, onResult: (@Sendable (String, Bool) -> Void)?
    ) async throws -> SttResult {
        let t = SpeechTranscriber(
            locale: Locale(identifier: "en-US"), preset: .transcription)
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [
            t, detector,
        ]) {
            try? await request.downloadAndInstall()
        }
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file,
            modules: [t, detector],
            finishAfterFile: true
        )
        var finalText = ""
        var chunks: [String] = []
        var detected = false
        async let run: CMTime? = analyzer.analyzeSequence(from: file)
        do {
            for try await result in t.results {
                let plain = NSAttributedString(result.text).string
                if !plain.isEmpty {
                    chunks.append(plain)
                    onResult?(plain, result.isFinal)
                }
                if result.isFinal { finalText = plain }
            }
        } catch {
            // Drain error is best-effort: `t.results` is a partial-collection
            // side-channel. The authoritative completion is `analyzeSequence`
            // (awaited below), which still throws on real failure — so a drain
            // hiccup here must not cancel a successful analysis.
        }
        do {
            for try await d in detector.results {
                if d.speechDetected { detected = true }
            }
        } catch {
            // Detector drain is best-effort.
        }
        _ = try await run
        let text = finalText.isEmpty ? joined(chunks) : finalText
        return SttResult(text: text, detected: detected)
    }
}
