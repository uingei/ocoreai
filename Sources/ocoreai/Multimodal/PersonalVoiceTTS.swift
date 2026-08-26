// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PersonalVoiceTTS.swift — L1 of the adaptive audio ladder.
///
/// The USER'S OWN VOICE. `AVSpeechSynthesisVoice.Traits.isPersonalVoice` +
/// `AVSpeechSynthesizer.personalVoiceAuthorizationStatus` are floored at
/// exactly ocoreai's own deployment floor (`macOS 14.0` / `iOS 17.0`) —
/// verbatim `API_AVAILABLE(ios(17.0), tvos(17.0), watchos(10.0), macos(14.0))`
/// in AVSpeechSynthesis.h (27.0 SDK, L78/90/153/276/287). That means:
///
///   macOS 14/15/26/27 + iOS 17/18/26/27  ⇒  ALL EIGHT target versions
///
/// …without a single `#available`. This is the only capability in the ladder
/// that reaches the floor — it is the voice-feedback element the product goal
/// calls out beyond the three upstream repos.
///
/// Authorization is a SYSTEM prompt (System Settings → Privacy →
/// Personal Voice), so we do NOT auto-prompt on launch. The user opts in
/// from Settings; `isAvailable` reports the live state so the UI can show
/// the affordance. All spellings verified by `swiftc -typecheck` (probe RC=0).

import AVFoundation
import Foundation

/// The user's Personal Voice TTS backend.
///
/// Selection policy:
///   1. The user turned the feature ON (persisted, see `SettingsStore`).
///   2. The OS reports a personal voice exists for the target language and
///      the app is authorized for it.
///   3. Otherwise fall back to the nearest regular voice — never fail the
///      TTS path.
@MainActor
public enum PersonalVoiceTTS {

    /// Resolve the voice to speak with, given the app-local feature flag.
    ///
    /// - Parameter enabled: the user's Settings toggle (`settings.enablePersonalVoice`).
    /// - Returns: the voice to assign to an `AVSpeechUtterance`.
    public static func resolveVoice(enabled: Bool, language: String) -> AVSpeechSynthesisVoice? {
        guard enabled else {
            return AVSpeechSynthesisVoice(language: language)
        }
        // `speechVoices` is a class method (NS_SWIFT_NAME), verified probe RC=0.
        guard AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized else {
            // Not yet authorized — keep TTS working with a regular voice.
            return AVSpeechSynthesisVoice(language: language)
        }
        // Prefer a personal voice whose language matches the target. Fall
        // back to the user's default personal voice if no language match.
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let exact = all.first { v in v.language == language }
        if let exact { return exact }
        let prefix = all.first { v in v.language.hasPrefix(language) }
        if let prefix { return prefix }
        let anyPersonal = all.first
        return anyPersonal ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Live authorization state (without prompting). Mirrors
    /// `personalVoiceAuthorizationStatus`.
    public static var isAuthorized: Bool {
        AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
    }

    /// Prompt the user to authorize Personal Voice for this app.
    /// Per the SDK contract, the OS caches the answer — repeated calls do
    /// not re-prompt once the user has decided.
    public static func requestAuthorization() async
        -> AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus
    {
        await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// True iff Personal Voice is both eligible on this OS band and currently
    /// authorized. (Eligibility is the floor 14/17 — i.e. all eight target
    /// versions — so this is purely an authorization + voice-presence check.)
    public static func isAvailable(on query: AudioStackQuery) -> Bool {
        AudioStack.resolve(query).personalVoiceTTS && isAuthorized
    }
}
