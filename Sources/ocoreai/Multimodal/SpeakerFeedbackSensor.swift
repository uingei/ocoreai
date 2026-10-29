// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// SpeakerFeedbackSensor — the `.speaker` perception channel's reader.
///
/// Reports one measured fact: whether this process is speaking right now. That is all
/// AVFoundation exposes about an utterance in flight — queue depth and speech rate were
/// reported here as `queue=0` and a `rate=` clause that could not fire, i.e. constants a
/// reader would take for readings (§ Invariant 2), so they are absent rather than zero.
///
/// The returned line is injected into the model's context, so a word of it is a behaviour
/// change (root § Documentation Map).

/// The one line the channel publishes. Pure so the exact text is testable without the
/// speech engine (`pure…` = exact-value seam, house pattern).
func pureSpeakerContextText(isSpeaking: Bool) -> String {
    "[speaker] tts=\(isSpeaking ? "active" : "idle")"
}

@MainActor
final class SpeakerFeedbackSensor {
    static let shared = SpeakerFeedbackSensor()

    private init() {}

    /// Read live: the channel's sampling loop is the only timer this needs.
    func contextText() -> String {
        pureSpeakerContextText(isSpeaking: AudioIO.shared.isSpeaking)
    }
}
