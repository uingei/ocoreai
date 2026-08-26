// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AudioStackTests.swift — exact, value-asserted coverage of the adaptive
/// audio ladder (`AudioStack.resolve`).
///
/// `resolve(_:)` is a PURE function (platform, major-version) → capability
/// set, so its output is deterministic on ANY host. These tests pin the full
/// 8-version matrix the header documents (macOS 14/15/26/27, iOS
/// 17/18/26/27) as exact value assertions (`#expect(...) == ...`), plus the
/// pure boundary rules and the Sendable value-equality contract. Running them
/// on macOS 27 does NOT weaken them: `resolve` never touches the host OS —
/// only `currentQuery()` does.
import Testing

@testable import ocoreai

@Suite("AudioStack — adaptive capability ladder (pure resolve)")
struct AudioStackTests {

    private static let m14 = AudioStackQuery(platform: .macOS, majorVersion: 14)
    private static let m15 = AudioStackQuery(platform: .macOS, majorVersion: 15)
    private static let m26 = AudioStackQuery(platform: .macOS, majorVersion: 26)
    private static let m27 = AudioStackQuery(platform: .macOS, majorVersion: 27)
    private static let i17 = AudioStackQuery(platform: .iOS, majorVersion: 17)
    private static let i18 = AudioStackQuery(platform: .iOS, majorVersion: 18)
    private static let i26 = AudioStackQuery(platform: .iOS, majorVersion: 26)
    private static let i27 = AudioStackQuery(platform: .iOS, majorVersion: 27)

    @Test("macOS 14 → dictation STT + personal voice + baseline mic")
    func macOS14() {
        #expect(
            AudioStack.resolve(Self.m14)
                == PerceivedAudioStack(
                    stt: .cloudDictation, personalVoiceTTS: true, micEnhancement: false))
    }

    @Test("macOS 15 → dictation STT + personal voice + ENHANCED mic (15+)")
    func macOS15() {
        #expect(
            AudioStack.resolve(Self.m15)
                == PerceivedAudioStack(
                    stt: .cloudDictation, personalVoiceTTS: true, micEnhancement: true))
    }

    @Test("macOS 26 → LOCAL STT + personal voice + enhanced mic")
    func macOS26() {
        #expect(
            AudioStack.resolve(Self.m26)
                == PerceivedAudioStack(
                    stt: .localSpeechFile, personalVoiceTTS: true, micEnhancement: true))
    }

    @Test("macOS 27 → LOCAL STT + personal voice + enhanced mic")
    func macOS27() {
        #expect(
            AudioStack.resolve(Self.m27)
                == PerceivedAudioStack(
                    stt: .localSpeechFile, personalVoiceTTS: true, micEnhancement: true))
    }

    @Test("iOS 17 → dictation STT + personal voice + baseline mic")
    func iOS17() {
        #expect(
            AudioStack.resolve(Self.i17)
                == PerceivedAudioStack(
                    stt: .cloudDictation, personalVoiceTTS: true, micEnhancement: false))
    }

    @Test("iOS 18 → dictation STT + personal voice + ENHANCED mic (18+)")
    func iOS18() {
        #expect(
            AudioStack.resolve(Self.i18)
                == PerceivedAudioStack(
                    stt: .cloudDictation, personalVoiceTTS: true, micEnhancement: true))
    }

    @Test("iOS 26 → LOCAL STT + personal voice + enhanced mic")
    func iOS26() {
        #expect(
            AudioStack.resolve(Self.i26)
                == PerceivedAudioStack(
                    stt: .localSpeechFile, personalVoiceTTS: true, micEnhancement: true))
    }

    @Test("iOS 27 → LOCAL STT + personal voice + enhanced mic")
    func iOS27() {
        #expect(
            AudioStack.resolve(Self.i27)
                == PerceivedAudioStack(
                    stt: .localSpeechFile, personalVoiceTTS: true, micEnhancement: true))
    }

    @Test("STT boundary: localSpeechFile iff majorVersion >= 26")
    func sttBoundary() {
        // 25 is the floor-just-below; 26 is the first local-eligible version.
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .macOS, majorVersion: 25)
            ).stt == .cloudDictation)
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .macOS, majorVersion: 26)
            ).stt == .localSpeechFile)
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .iOS, majorVersion: 25)
            ).stt == .cloudDictation)
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .iOS, majorVersion: 26)
            ).stt == .localSpeechFile)
    }

    @Test("mic boundary: enhanced iff mac >= 15 / ios >= 18")
    func micBoundary() {
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .macOS, majorVersion: 14)
            ).micEnhancement == false)
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .macOS, majorVersion: 15)
            ).micEnhancement == true)
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .iOS, majorVersion: 17)
            ).micEnhancement == false)
        #expect(
            AudioStack.resolve(
                AudioStackQuery(platform: .iOS, majorVersion: 18)
            ).micEnhancement == true)
    }

    @Test("personal-voice TTS eligible on every supported target version")
    func personalVoiceAllVersions() {
        for q in [
            Self.m14, Self.m15, Self.m26, Self.m27, Self.i17, Self.i18,
            Self.i26, Self.i27,
        ] {
            #expect(AudioStack.resolve(q).personalVoiceTTS == true)
        }
    }

    @Test("resolve is deterministic (Sendable value-equality contract)")
    func deterministic() {
        #expect(AudioStack.resolve(Self.m26) == AudioStack.resolve(Self.m26))
        #expect(AudioStack.resolve(Self.i18) == AudioStack.resolve(Self.i18))
    }
}
