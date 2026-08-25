// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PerceptionMediaDeliveryTests.swift — b4 tests for the perception→VLM media
/// delivery wire (2026-08-25):
///   b1 `PerceptionEngine.mediaContentParts()` — media-only part filtering
///      (image/audio bytes in; OCR/text frames out, staying on the
///      `contextText()` system path so nothing is double-delivered).
///   b2 `attachPerceptionMedia(...)` — attaches decoded media to the LAST
///      user message (user-turn semantics, not system instructions), returns
///      temp audio file URLs for caller cleanup.
///   b2 decoders `makeMLXImage` / `makeMLXAudio` — real byte decoding:
///      data-URL → CIImage / temp `.caf` with exact-byte round-trip.
///
/// All assertions are exact values (counts, URLs, byte round-trips). The
/// shared `PerceptionEngine.shared.buffer` is cleared in every test — the
/// singleton outlives test boundaries (30s frame TTL), so without clearing
/// results are nondeterministic.

import CoreImage
import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

private enum Fixtures {
    /// 1×1 PNG (valid, decodable). Deterministic — no network, no temp assets.
    static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    static var onePixelImageDataURL: String {
        "data:image/png;base64,\(onePixelPNGBase64)"
    }

    static let wavBytes = Data([
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45,
    ])
    static var wavDataURL: String {
        "data:audio/wav;base64,\(wavBytes.base64EncodedString())"
    }

    static func imagePart(_ url: String) -> ContentPart {
        ContentPart(type: "image_url", text: nil, imageUrl: .init(url: url))
    }

    static func audioPart(_ url: String) -> ContentPart {
        ContentPart(
            type: "audio", text: nil, imageUrl: nil,
            audioURL: .init(url: url))
    }
}

@Suite("PerceptionEngine — mediaContentParts() gating (b1)")
struct MediaContentPartsGateTests {

    @MainActor
    @Test("empty buffer → exactly 0 media parts")
    func emptyBufferYieldsZeroMedia() {
        PerceptionEngine.shared.buffer.clear()
        #expect(PerceptionEngine.shared.mediaContentParts().isEmpty)
        PerceptionEngine.shared.buffer.clear()
    }

    @MainActor
    @Test("image frame → exactly 1 image_url part, URL intact")
    func imageFrameDelivers() {
        PerceptionEngine.shared.buffer.clear()
        defer { PerceptionEngine.shared.buffer.clear() }
        let url = Fixtures.onePixelImageDataURL
        PerceptionEngine.shared.buffer.push(PerceptionFrame(channel: .camera, imageURL: url))
        let parts = PerceptionEngine.shared.mediaContentParts()
        #expect(parts.count == 1)
        #expect(parts[0].type == "image_url")
        #expect(parts[0].imageUrl?.url == url)
        #expect(parts[0].text == nil)
        #expect(parts[0].audioURL == nil)
    }

    @MainActor
    @Test("audio frame → exactly 1 audio part, URL intact")
    func audioFrameDelivers() {
        PerceptionEngine.shared.buffer.clear()
        defer { PerceptionEngine.shared.buffer.clear() }
        let url = Fixtures.wavDataURL
        PerceptionEngine.shared.buffer.push(PerceptionFrame(channel: .audio, audioURL: url))
        let parts = PerceptionEngine.shared.mediaContentParts()
        #expect(parts.count == 1)
        #expect(parts[0].type == "audio")
        #expect(parts[0].audioURL?.url == url)
        #expect(parts[0].imageUrl == nil)
    }

    @MainActor
    @Test("OCR frame → 0 media parts (stays on the contextText() path, not double-delivered)")
    func ocrFrameExcluded() {
        PerceptionEngine.shared.buffer.clear()
        defer { PerceptionEngine.shared.buffer.clear() }
        PerceptionEngine.shared.buffer.push(PerceptionFrame(channel: .screen, ocrText: "Hello OCR"))
        let media = PerceptionEngine.shared.mediaContentParts()
        #expect(media.isEmpty)
        // The OCR text itself MUST still be on the contentParts()/contextText() text path.
        let full = PerceptionEngine.shared.contentParts()
        #expect(full.count == 1)
        #expect(full[0].type == "text")
        #expect(full[0].text?.contains("Hello OCR") == true)
    }

    @MainActor
    @Test("mixed buffer → exactly the 2 media parts, text parts excluded")
    func mixedBufferExactMediaSet() {
        PerceptionEngine.shared.buffer.clear()
        defer { PerceptionEngine.shared.buffer.clear() }
        PerceptionEngine.shared.buffer.push(
            PerceptionFrame(channel: .camera, imageURL: Fixtures.onePixelImageDataURL))
        PerceptionEngine.shared.buffer.push(
            PerceptionFrame(channel: .audio, audioURL: Fixtures.wavDataURL))
        PerceptionEngine.shared.buffer.push(
            PerceptionFrame(channel: .screen, ocrText: "text-only frame"))
        PerceptionEngine.shared.buffer.push(
            PerceptionFrame(channel: .system, textContext: "uptime 0"))
        let media = PerceptionEngine.shared.mediaContentParts()
        #expect(media.count == 2)
        let types = media.map(\.type).sorted()
        #expect(types == ["audio", "image_url"])
        #expect(!media.contains { $0.type == "text" })
    }
}

@Suite("attachPerceptionMedia — user-turn attachment (b2)")
struct AttachPerceptionMediaTests {

    @MainActor
    @Test("media lands on the LAST user message only — system/assistant untouched")
    func attachesToLastUser() {
        var msgs: [Chat.Message] = [
            Chat.Message(role: .system, content: "sys"),
            Chat.Message(role: .user, content: "u1"),
            Chat.Message(role: .assistant, content: "a1"),
        ]
        _ = attachPerceptionMedia(
            &msgs, mediaParts: [Fixtures.imagePart(Fixtures.onePixelImageDataURL)],
            makeImage: makeMLXImage, makeAudio: makeMLXAudio)
        #expect(msgs[0].images.isEmpty && msgs[0].audios.isEmpty)
        #expect(msgs[1].images.count == 1)
        #expect(msgs[2].images.isEmpty)
        var isCIImage = false
        if case .ciImage = msgs[1].images[0] { isCIImage = true }
        #expect(isCIImage)
    }

    @MainActor
    @Test("no user message → messages unchanged, temp audio URLs still returned for cleanup")
    func noUserMessageLeavesMessagesUnchanged() {
        var msgs: [Chat.Message] = [
            Chat.Message(role: .system, content: "sys"),
            Chat.Message(role: .assistant, content: "a1"),
        ]
        let temps = attachPerceptionMedia(
            &msgs, mediaParts: [Fixtures.audioPart(Fixtures.wavDataURL)],
            makeImage: makeMLXImage, makeAudio: makeMLXAudio)
        #expect(msgs[0].images.isEmpty && msgs[0].audios.isEmpty)
        #expect(msgs[1].images.isEmpty && msgs[1].audios.isEmpty)
        #expect(
            temps.count == 1, "the created temp .caf must be returned even when nothing is attached"
        )
        if let t = temps.first { try? FileManager.default.removeItem(at: t) }
    }

    @MainActor
    @Test("empty mediaParts → zero mutation, zero temp files")
    func emptyMediaNoop() {
        var msgs: [Chat.Message] = [Chat.Message(role: .user, content: "u")]
        let temps = attachPerceptionMedia(
            &msgs, mediaParts: [],
            makeImage: makeMLXImage, makeAudio: makeMLXAudio)
        #expect(temps.isEmpty)
        #expect(msgs[0].images.isEmpty && msgs[0].audios.isEmpty)
    }

    @MainActor
    @Test("audio part decodes to a real .caf file whose bytes round-trip exactly")
    func audioBytesRoundTrip() {
        var msgs: [Chat.Message] = [Chat.Message(role: .user, content: "u")]
        let temps = attachPerceptionMedia(
            &msgs, mediaParts: [Fixtures.audioPart(Fixtures.wavDataURL)],
            makeImage: makeMLXImage, makeAudio: makeMLXAudio)
        #expect(msgs[0].audios.count == 1)
        #expect(temps.count == 1)
        var fileURL: URL?
        if case .url(let u) = msgs[0].audios[0] { fileURL = u }
        #expect(fileURL == temps.first)
        guard let fileURL else {
            Issue.record("attached audio is not a file URL")
            return
        }
        let disk = (try? Data(contentsOf: fileURL)) ?? Data()
        #expect(disk == Fixtures.wavBytes, "byte-exact round-trip of the decoded .caf")
        try? FileManager.default.removeItem(at: fileURL)
    }
}

@Suite("makeMLXImage / makeMLXAudio — byte decoders (b2)")
struct MediaDecoderTests {

    @Test("1×1 PNG data-URL decodes to a real CIImage")
    func decodesRealImage() {
        guard let img = makeMLXImage(from: Fixtures.onePixelImageDataURL) else {
            Issue.record("expected decoded image, got nil")
            return
        }
        var dim = false
        if case .ciImage(let ci) = img { dim = ci.extent.width > 0 && ci.extent.height > 0 }
        #expect(dim)
    }

    @Test("invalid base64 data-URL → nil (no crash)")
    func badBase64ImageNil() {
        #expect(makeMLXImage(from: "data:image/png;base64,%%%not-base64%%%") == nil)
    }

    @Test("data-URL without payload comma → nil")
    func dataURLWithoutCommaNil() {
        #expect(makeMLXImage(from: "data:image/png;base64") == nil)
    }

    @Test("http URL passes through as .url")
    func httpImagePassthrough() {
        var ok = false
        let img = makeMLXImage(from: "https://example.com/x.png")
        if case .some(.url(let u)) = img { ok = (u.absoluteString == "https://example.com/x.png") }
        #expect(ok)
    }

    @Test("audio data-URL → temp .caf with exact bytes; tempURL == attachment URL")
    func decodesRealAudio() {
        let result = makeMLXAudio(from: Fixtures.wavDataURL)
        #expect(result.audio != nil)
        #expect(result.tempURL != nil)
        guard let tmp = result.tempURL else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let disk = (try? Data(contentsOf: tmp)) ?? Data()
        #expect(disk == Fixtures.wavBytes)
        var attached: URL?
        if case .url(let u) = result.audio { attached = u }
        #expect(attached == tmp)
    }

    @Test("ordinary file URL passes through; no temp file created")
    func fileAudioPassthrough() {
        let result = makeMLXAudio(from: "file:///tmp/clip.caf")
        #expect(result.tempURL == nil)
        var ok = false
        if case .url(let u) = result.audio { ok = (u.absoluteString == "file:///tmp/clip.caf") }
        #expect(ok)
    }

    @Test("invalid base64 audio → (nil, nil)")
    func badBase64AudioNil() {
        let result = makeMLXAudio(from: "data:audio/wav;base64,%%%")
        #expect(result.audio == nil)
        #expect(result.tempURL == nil)
    }
}
