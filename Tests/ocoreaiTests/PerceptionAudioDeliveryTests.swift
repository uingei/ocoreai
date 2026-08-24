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

// MARK: - Producer wiring (batch 2: .audio channel producer loop)

/// Regression for the `.audio` perception channel producer wiring:
/// `ChannelFlags.audio` must register the channel in `activeChannels`,
/// `ChannelConfig` must carry a non-zero sampling interval, and a text
/// transcript frame must surface on the live `contextText()` path.
@Suite("PerceptionEngine — audio channel producer wiring")
struct PerceptionAudioChannelWiringTests {

    @MainActor
    @Test("audio flag registers the .audio channel")
    func audioFlagRegistersChannel() {
        PerceptionEngine.shared.channels = ChannelFlags(
            camera: false, screen: false, network: false,
            filesystem: false, internet: false, system: false,
            speaker: false, audio: true)
        #expect(PerceptionEngine.shared.activeChannels == [.audio])
    }

    @MainActor
    @Test("audio default is OFF (no mic contention by default)")
    func audioDefaultOff() {
        let flags = ChannelFlags()
        #expect(!flags.audio)
    }

    @MainActor
    @Test("presets carry a finite audio interval; minimal/halted halt audio")
    func audioIntervalConfigured() {
        // Sampling presets run the loop; power-saving presets intentionally halt it (interval=0).
        #expect(ChannelConfig.default.audioInterval > 0)
        #expect(ChannelConfig.reduced.audioInterval > 0)
        #expect(ChannelConfig.minimal.audioInterval == 0)
        #expect(ChannelConfig.halted.audioInterval == 0)
    }

    @MainActor
    @Test("audio transcript frame renders on the live contextText() path")
    func audioTranscriptRendersInContextText() {
        let frame = PerceptionFrame(channel: .audio, textContext: "hello from ambient loop")
        PerceptionEngine.shared.buffer.push(frame)
        let text = PerceptionEngine.shared.contextText()
        #expect(text.hasPrefix("[System Perception]"))
        #expect(text.contains("audio=hello from ambient loop"))
    }
}
