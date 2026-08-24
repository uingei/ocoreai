// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PerceptionAudioDeliveryTests.swift — regression tests for the audio branch
/// of PerceptionEngine.contentParts(): an `.audio` frame carrying an audioURL
/// must be delivered as an `audio` ContentPart with the URL intact (not
/// degraded to a "[Audio recording context]" text placeholder that drops the
/// bytes). Closes the vision/audio behavior fork: image frames carry bytes,
/// audio frames did not (fixed 2026-08-24).

import Foundation
import Testing

@testable import ocoreai

@Suite("PerceptionEngine — audio frame delivery (contentParts)")
struct PerceptionAudioDeliveryTests {

    @MainActor
    private static func pushAudioFrame(url: String = "https://example.com/clip.caf") {
        let frame = PerceptionFrame(channel: .audio, audioURL: url)
        PerceptionEngine.shared.buffer.push(frame)
    }

    @MainActor
    @Test("audio frame produces an audio ContentPart with the URL intact")
    func audioFrameDeliversBytes() {
        Self.pushAudioFrame()
        let parts = PerceptionEngine.shared.contentParts().filter { $0.type == "audio" }
        #expect(parts.count == 1)
        #expect(parts[0].audioURL?.url == "https://example.com/clip.caf")
        #expect(parts[0].text == nil)
    }

    @MainActor
    @Test("audio frame is no longer delivered as a text placeholder")
    func audioFrameNotDowngradedToText() {
        Self.pushAudioFrame()
        let parts = PerceptionEngine.shared.contentParts()
        #expect(
            !parts.contains {
                $0.type == "text" && ($0.text?.contains("[Audio recording context]") == true)
            }
        )
    }
}
