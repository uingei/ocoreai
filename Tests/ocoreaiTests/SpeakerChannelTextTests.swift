// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SpeakerChannelTextTests — the exact line the `.speaker` channel injects into the
/// model's context, and the fields it must never claim to have measured.

import Testing

@testable import ocoreai

@Suite("Speaker channel — the injected line is one measured fact")
struct SpeakerChannelTextTests {

    @Test("both states are exact strings a reader can act on")
    func exactStates() {
        #expect(pureSpeakerContextText(isSpeaking: true) == "[speaker] tts=active")
        #expect(pureSpeakerContextText(isSpeaking: false) == "[speaker] tts=idle")
    }

    @Test("the line carries no field this process cannot measure")
    func noUnmeasuredField() {
        // Red against the shape before 10-30(57): the channel published `queue=0` from a
        // field hard-coded to 0, and a `rate=` clause whose source could never be non-zero.
        for state in [true, false] {
            let text = pureSpeakerContextText(isSpeaking: state)
            #expect(!text.contains("queue="), "queue depth is not measurable here: \(text)")
            #expect(!text.contains("rate="), "speech rate is not measurable here: \(text)")
        }
    }
}
