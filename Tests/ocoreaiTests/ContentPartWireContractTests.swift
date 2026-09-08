// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ContentPartWireContractTests.swift — locks the OpenAI wire JSON contract
/// for `ContentPart` Codable (snake_case wire keys → camelCase Swift props).
///
/// Regression class (09-08 live bug): the model silently dropped every
/// image sent over `/v1/chat/completions`. Root cause: `ContentPart` had
/// no `CodingKeys`, so bare Codable derived the JSON key from the Swift
/// property name (`imageUrl`) while the OpenAI wire sends `image_url` —
/// decoded to `nil`, `hasMediaPart == false`, the engine ran text-only and
/// returned a confident blind answer ("I need an image… provide a file
/// path"), HTTP 200, `prompt_tokens:187` = zero vision tokens.
///
/// These tests decode REAL wire JSON (not in-process construction) and
/// assert exact decoded values + exact re-encoded wire keys, so dropping
/// `CodingKeys` fails loudly here instead of silently losing pixels.
///
/// Methodology: exact-value assertions (==), all three media part types,
/// decode + encode + round-trip — no weak `count > N` asserts.

import Foundation
import Testing

@testable import ocoreai

// MARK: - Decode: real OpenAI wire body → non-nil Swift properties

@Suite("ContentPart wire decode — snake_case JSON in, camelCase props out")
struct ContentPartWireDecodeTests {
    private static let imageDataURL = "data:image/png;base64,iVBORw0KGgo="

    @Test("image_url part decodes to non-nil imageUrl with url intact")
    func imagePartDecodes() throws {
        let wire = #"""
            {"type":"image_url","text":null,"image_url":{"url":"\#(Self.imageDataURL)"}}
            """#
        let part = try JSONDecoder().decode(
            ContentPart.self, from: wire.data(using: .utf8)!)
        #expect(part.type == "image_url")
        #expect(part.imageUrl != nil)
        #expect(part.imageUrl?.url == Self.imageDataURL)
        #expect(part.isMedia == true)
    }

    @Test("video_url part decodes to non-nil videoUrl with maxFrames intact")
    func videoPartDecodes() throws {
        let wire = #"""
            {"type":"video","text":null,"video_url":{"url":"https://v.mp4","max_frames":8}}
            """#
        let part = try JSONDecoder().decode(
            ContentPart.self, from: wire.data(using: .utf8)!)
        #expect(part.videoUrl != nil)
        #expect(part.videoUrl?.url == "https://v.mp4")
        #expect(part.isMedia == true)
    }

    @Test(
        "video_url WITHOUT max_frames (real-client shape) decodes — 09-08 E2E"
    )
    func videoPartDecodesWithoutMaxFrames() throws {
        // The 09-08 audio/video/video-red probes sent {"url": "data:..."} with
        // NO max_frames. The synthesized `init(from:)` required `max_frames`
        // (non-optional Int), so the `[ContentPart]` array decode threw and
        // `ContentPolymorphic` fell back to `.text("")` — the video AND its
        // sibling text were dropped end-to-end (prompt_tokens:180, zero video
        // tokens, model answered boilerplate). A part-only decode of this wire
        // is the exact red case that fix must turn green.
        let wire = #"""
            {"type":"video","text":null,"video_url":{"url":"data:video/mp4;base64,QUJD"}}
            """#
        let part = try JSONDecoder().decode(
            ContentPart.self, from: wire.data(using: .utf8)!)
        #expect(part.videoUrl != nil)
        #expect(part.videoUrl?.url == "data:video/mp4;base64,QUJD")
        #expect(part.videoUrl?.maxFrames == 16)
        #expect(part.isMedia == true)
    }

    @Test(
        "mixed [text, video] array decodes when video lacks max_frames"
    )
    func mixedArraySurvivesVideoWithoutMaxFrames() throws {
        // The production drop was the ARRAY falling back to .text(""), not a
        // single part. This asserts the array — including a text sibling — is
        // preserved when the video part is the minimal real-client shape.
        let wire = #"""
            [
                {"type":"text","text":"What color is this video?"},
                {"type":"video","video_url":{"url":"data:video/mp4;base64,QUJD"}}
            ]
            """#
        let content = try JSONDecoder().decode(
            ContentPolymorphic.self, from: wire.data(using: .utf8)!)
        guard case .parts(let parts) = content else {
            Issue.record("array fell back to .text('') — video dropped")
            return
        }
        #expect(parts.count == 2)
        #expect(parts.first?.text == "What color is this video?")
        #expect(parts.last?.videoUrl != nil)
        #expect(parts.last?.isMedia == true)
    }

    @Test("audio_url part decodes to non-nil audioURL with url intact")
    func audioPartDecodes() throws {
        let wire = #"""
            {"type":"audio","text":null,"audio_url":{"url":"https://a.mp3"}}
            """#
        let part = try JSONDecoder().decode(
            ContentPart.self, from: wire.data(using: .utf8)!)
        #expect(part.audioURL != nil)
        #expect(part.audioURL?.url == "https://a.mp3")
        #expect(part.isMedia == true)
    }

    @Test("text part still decodes (no media fields) — control case")
    func textPartDecodes() throws {
        let wire = #"""
            {"type":"text","text":"What color is the square?"}
            """#
        let part = try JSONDecoder().decode(
            ContentPart.self, from: wire.data(using: .utf8)!)
        #expect(part.text == "What color is the square?")
        #expect(part.imageUrl == nil)
        #expect(part.isMedia == false)
    }
}

// MARK: - Message-level: the hasMediaPart predicate on a decoded wire conversation

@Suite("Message wire decode — hasMediaPart true on a real OpenAI body")
struct MessageWireMediaDetectionTests {
    @Test("real OpenAI chat message (text + image_url parts) → hasMediaPart true, count 1")
    func realWireMessageDetected() throws {
        let wire = #"""
            {"role":"user","content":[
               {"type":"text","text":"What color is the square? Answer in one word."},
               {"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}
            ]}
            """#
        let msg = try JSONDecoder().decode(
            Message.self, from: wire.data(using: .utf8)!)
        #expect(msg.hasMediaPart == true)
        #expect(msg.mediaPartCount == 1)
    }

    @Test("real OpenAI chat message with text only → hasMediaPart false, count 0")
    func textOnlyWireMessage() throws {
        let wire = #"""
            {"role":"user","content":"hello"}
            """#
        let msg = try JSONDecoder().decode(
            Message.self, from: wire.data(using: .utf8)!)
        #expect(msg.hasMediaPart == false)
        #expect(msg.mediaPartCount == 0)
    }
}

// MARK: - Encode: Swift property → snake_case wire key (no camelCase leak)

@Suite("ContentPart wire encode — camelCase props in, snake_case JSON out")
struct ContentPartWireEncodeTests {
    private func encodeKeys(_ part: ContentPart) throws -> [String: Any] {
        let data = try JSONEncoder().encode(part)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj ?? [:]
    }

    @Test("image part encodes as image_url, never imageUrl")
    func imageEncodesSnakeCase() throws {
        let part = ContentPart(
            type: "image_url", text: nil,
            imageUrl: ContentPart.ImageURL(url: "https://i.png"))
        let obj = try encodeKeys(part)
        #expect(obj["image_url"] != nil)
        #expect(obj["imageUrl"] == nil)
    }

    @Test("video part encodes as video_url, never videoUrl")
    func videoEncodesSnakeCase() throws {
        let part = ContentPart(
            type: "video", text: nil, imageUrl: nil,
            videoUrl: ContentPart.VideoURL(url: "https://v.mp4"))
        let obj = try encodeKeys(part)
        #expect(obj["video_url"] != nil)
        #expect(obj["videoUrl"] == nil)
    }

    @Test("audio part encodes as audio_url, never audioURL")
    func audioEncodesSnakeCase() throws {
        let part = ContentPart(
            type: "audio", text: nil, imageUrl: nil,
            audioURL: ContentPart.AudioURL(url: "https://a.mp3"))
        let obj = try encodeKeys(part)
        #expect(obj["audio_url"] != nil)
        #expect(obj["audioURL"] == nil)
    }

    @Test("round-trip: wire JSON → Swift → wire JSON keeps the same value")
    func roundTrip() throws {
        let part = ContentPart(
            type: "image_url", text: "caption",
            imageUrl: ContentPart.ImageURL(url: "data:image/png;base64,AAA="))
        let re = try JSONDecoder().decode(
            ContentPart.self,
            from: JSONEncoder().encode(part)
        )
        #expect(re.imageUrl?.url == part.imageUrl?.url)
        #expect(re.text == part.text)
        #expect(re.isMedia == true)
    }
}
