// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AudioStack.swift — version-adaptive perception/voice capability layer.
///
/// ocoreai ships ONE binary against a floor of `.macOS(.v14)` / `.iOS(.v17)`
/// (Package.swift) and must behave correctly on macOS 14/15/26/27 and
/// iOS 17/18/26/27. Rather than a single hardcoded audio path, the concrete
/// backends (STT / TTS voice / mic enhancement) are selected AT RUNTIME from
/// the live OS version. This is the adaptive ladder:
///
///   macOS 14 → dictation STT · personal-voice TTS · baseline mic
///   macOS 15 → dictation STT · personal-voice TTS · enhanced mic (15+)
///   macOS 26 → **local offline STT** · personal-voice TTS · enhanced mic
///   macOS 27 → **local offline STT** · personal-voice TTS · enhanced mic
///   iOS   17 → dictation STT · personal-voice TTS · baseline mic
///   iOS   18 → dictation STT · personal-voice TTS · enhanced mic (18+)
///   iOS   26 → **local offline STT** · personal-voice TTS · enhanced mic
///   iOS   27 → **local offline STT** · personal-voice TTS · enhanced mic
///
/// This file is the PURE CORE: `resolve(_:)` maps (platform, major-version)
/// → the exact capability set. Keeping it pure (no ProcessInfo, no
/// AVFoundation) makes the ladder exactly testable on any host — the tests
/// assert the exact set for all eight target versions without depending on
/// which Mac the test runs on.
///
/// Capability floors are read VERBATIM from the macOS 27.0 SDK (2026-08-26,
/// first-hand; probe-verified by `swiftc -typecheck`):
///   Personal Voice TTS : API_AVAILABLE(macos 14.0, ios 17.0)   [AVSpeechSynthesis.h L78/90/153/276/287]
///   SpeechAnalyzer file: @available(anyAppleOS 26)             [Speech.swiftinterface L337-342]
///   SpeechTranscriber  : @available(anyAppleOS 26)             [Speech.swiftinterface L345]
///   windNoiseRemoval   : API_AVAILABLE(macos 15.0, ios 18.0)   [AVCaptureInput.h L393/403]
///   multichannelAudio  : API_AVAILABLE(macos 15.0, ios 18.0)   [AVCaptureInput.h]
///   CaptureInputSeqProv: @available(anyAppleOS 27)             [Speech.swiftinterface L717-736]
///   SpeechAnalyzer.start(inputSequence:)                       [Speech.swiftinterface L238]
///
/// Rule of thumb applied throughout: the ENTRY type's floor is NOT the
/// effective gate — e.g. `SpeechAnalyzer` is 26, but its LIVE-microphone
/// input provider (`CaptureInputSequenceProvider`) is 27, so B1 wires the
/// FILE path (26) and the live path ships next batch.  ← B2 (this file) now
/// carries that live-mic flag: `supportsLiveMic == true` iff majorVersion ≥ 27.

import Foundation

// MARK: - Platform / version query

/// The two Apple OS lines ocoreai targets. (watch/tv out of scope —
/// ocoreai is a macOS/iOS app.)
public enum AudioPlatform: String, Sendable {
    case macOS
    case iOS
}

/// A (platform, major-OS-version) pair — the unit the ladder is queried with.
public struct AudioStackQuery: Equatable, Sendable {
    public var platform: AudioPlatform
    public var majorVersion: Int

    public init(platform: AudioPlatform, majorVersion: Int) {
        self.platform = platform
        self.majorVersion = majorVersion
    }
}

// MARK: - Capability ladder

/// Which STT engine press-to-talk uses for a given OS.
public enum STTTier: String, Equatable, Sendable, CaseIterable {
    /// `SFSpeechRecognizer` dictation — the floor engine, every supported
    /// version (graceful baseline; system decides cloud vs on-device).
    case cloudDictation
    /// `SpeechAnalyzer` + `SpeechTranscriber` over an `AVAudioFile`
    /// (Speech framework, macOS 26+ / iOS 26+) — fully local, offline.
    case localSpeechFile
}

/// The resolved audio/voice capability set for one OS.
/// Plain value type ⇒ trivially `==`-comparable in tests, `Sendable` cross-actor.
public struct PerceivedAudioStack: Equatable, Sendable {
    /// Selected press-to-talk STT engine.
    public var stt: STTTier
    /// Personal-voice TTS — the USER'S OWN VOICE (floor 14/17 = ocoreai's own
    /// deployment floor ⇒ eligible on all eight target versions; live
    /// availability still gated by the user's System-Settings authorization —
    /// see `PersonalVoiceTTS`).
    public var personalVoiceTTS: Bool
    /// Enhanced microphone capture: multichannel mode + wind-noise removal
    /// (macOS 15+ / iOS 18+), via `AVCaptureDeviceInput`.
    public var micEnhancement: Bool
    /// **Live-microphone local STT** — `CaptureInputSequenceProvider` +
    /// `SpeechAnalyzer.start(inputSequence:)` streaming real-time capture into
    /// the same local offline transcriber as the file path.  Floor `anyAppleOS 27`
    /// (SDK swiftinterface L717-736): the *provider* is 27 even though the
    /// *analyzer* is 26 — the analyzer alone is not enough to stream a live
    /// mic; you need the 27-level capture provider that yields
    /// `AnalyzerInput` sequences.  Only meaningful when `stt == .localSpeechFile`
    /// (26+); on 27 both file AND live are available.
    public var supportsLiveMic: Bool

    public init(
        stt: STTTier, personalVoiceTTS: Bool, micEnhancement: Bool,
        supportsLiveMic: Bool = false,
    ) {
        self.stt = stt
        self.personalVoiceTTS = personalVoiceTTS
        self.micEnhancement = micEnhancement
        self.supportsLiveMic = supportsLiveMic
    }
}

// MARK: - The adaptive resolver (PURE)

public enum AudioStack {

    /// Map (platform, major-version) → exact capability set. Exhaustive over
    /// the support matrix (see file header). Deterministic: same input ⇒ same
    /// output, no side effects — that is what makes it unit-testable.
    public static func resolve(_ q: AudioStackQuery) -> PerceivedAudioStack {
        let stt: STTTier
        if q.majorVersion >= 26 {
            stt = .localSpeechFile
        } else {
            stt = .cloudDictation
        }

        let micEnhancement =
            (q.platform == .macOS
                ? q.majorVersion >= 15
                : q.majorVersion >= 18)
        // Personal Voice TTS floor = macos(14.0)/ios(17.0) = ocoreai's own
        // deployment floor ⇒ eligible on every target version.
        let pvEligible =
            (q.platform == .macOS
                ? q.majorVersion >= 14
                : q.majorVersion >= 17)

        // Live-mic floor = anyAppleOS 27 (CaptureInputSequenceProvider).
        // Only meaningful when the local STT engine is also available
        // (stt == .localSpeechFile, i.e. majorVersion >= 26); on every 27+
        // version this is automatically satisfied.  Explicit guard for clarity.
        let liveMic = (q.majorVersion >= 27 && stt == .localSpeechFile)

        return PerceivedAudioStack(
            stt: stt, personalVoiceTTS: pvEligible, micEnhancement: micEnhancement,
            supportsLiveMic: liveMic,
        )
    }

    // MARK: - Live probe

    /// Detect the HOST OS (platform + major version) at runtime.
    ///
    /// `ProcessInfo.operatingSystemVersion` reflects the machine the app is
    /// ACTUALLY running on — not the SDK it was built against — so one
    /// artifact adapts across all eight target versions.
    public static func currentQuery() -> AudioStackQuery {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let platform: AudioPlatform = .iOS
        #elseif os(macOS)
        let platform: AudioPlatform = .macOS
        #else
        let platform: AudioPlatform = .macOS
        #endif
        return AudioStackQuery(platform: platform, majorVersion: Int(v.majorVersion))
    }

    /// The stack the app should run RIGHT NOW on this machine.
    public static var current: PerceivedAudioStack {
        resolve(currentQuery())
    }
}
