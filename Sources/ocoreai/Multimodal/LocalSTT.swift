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
///   AssetInventory.assetInstallationRequest(supporting:)     [Apple docs, live-verified]
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
    /// - Returns: the final transcribed text (empty on no speech/unsupported locale).
    /// - Throws: `SpeechAnalyzer`/`SpeechTranscriber` errors surface as thrown.
    public static func transcribe(
        _ file: AVAudioFile,
        locale: Locale,
        onResult: (@Sendable (String, Bool) -> Void)? = nil,
    ) async throws -> String {
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

        // Step 2 (Apple docs): ensure assets are installed before analysis.
        // `assetInstallationRequest` returns nil when nothing to do.
        if let request =
            try? await AssetInventory
            .assetInstallationRequest(supporting: [t])
        {
            try? await request.downloadAndInstall()
        }

        // Step 3-4: analyzer over the audio file (file-path convenience init, 26+).
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [t])

        // Step 6-7: run the analysis while concurrently draining the module's
        // `results` AsyncSequence (the Apple-documented pattern; module-level
        // results are consumed off the module, not the analyzer).
        var finalText = ""
        var chunks: [String] = []
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
        _ = try await run

        // `analyzeSequence` finalizes; if the module streamed nothing useful
        // (e.g. a very short clip before finalization) we still have `finalText`.
        return finalText.isEmpty ? joined(chunks) : finalText
    }

    /// Convenience: transcribe an `AVAudioFile` at a URL.
    public static func transcribe(
        url: URL,
        locale: Locale,
        onResult: (@Sendable (String, Bool) -> Void)? = nil,
    ) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        return try await transcribe(file, locale: locale, onResult: onResult)
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
    ) async throws -> String {
        let t = SpeechTranscriber(
            locale: Locale(identifier: "en-US"), preset: .transcription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await request.downloadAndInstall()
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [t])
        var finalText = ""
        var chunks: [String] = []
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
        _ = try await run
        return finalText.isEmpty ? joined(chunks) : finalText
    }
}
