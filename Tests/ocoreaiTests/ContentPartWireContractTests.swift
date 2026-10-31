// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ContentPartWireContractTests.swift — locks the OpenAI wire JSON contract
/// for `ContentPart` Codable (snake_case wire keys → camelCase Swift props).
///
/// Why it matters: a key-name mismatch decodes media parts to `nil` →
/// `hasMediaPart == false` → the engine runs text-only yet returns HTTP 200
/// with a confident blind answer. Silent data loss, not an error — so the
/// wire keys are pinned exactly, not by inference.
///
/// Coverage: all three media part types + text control, decode + encode +
/// round-trip on real wire JSON (not in-process construction), including
/// the minimal real-client shape (video without max_frames), and the carriage
/// rule — the spec's `input_audio` arrives as the one audio shape this engine
/// reads, and a part that names an attachment this server cannot carry is
/// reported by name instead of decoding into nothing (`CarriageTests`).

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
        "video_url WITHOUT max_frames (real-client shape) decodes"
    )
    func videoPartDecodesWithoutMaxFrames() throws {
        // Real clients send {"url": "data:..."} with
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

// MARK: - Carriage: what the wire names, this server either carries or refuses by name

/// Measured on one live server, same bytes, two shapes: `audio_url` with a real wav was
/// refused honestly (`503 Transcription unavailable`), while OpenAI's `input_audio` with
/// those identical bytes returned **200 and a blind answer** — the part decoded into a
/// `ContentPart` carrying nothing, so ingestion, media resolution, the tokenizer and the
/// engine were each correct about a request that had silently lost its payload. `file`,
/// an unknown part type, an `image_url` with no payload object and an empty media URL
/// had the same fate. Now the spec shape is carried, and the rest is refused by name
/// with the client's own field path (`ChatHandler` → `ChatMedia.uncarried`).
@Suite("ContentPart carriage — input_audio carried, an un-honoured part refused by name")
struct ContentPartCarriageTests {
    private static let wavBase64 = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQAAAAA="

    private func decode(_ wire: String) throws -> ContentPart {
        try JSONDecoder().decode(ContentPart.self, from: wire.data(using: .utf8)!)
    }

    @Test("input_audio (OpenAI spec) becomes the one audio shape this engine reads")
    func inputAudioBecomesAudioURL() throws {
        let wire =
            #"{"type":"input_audio","input_audio":{"data":"\#(Self.wavBase64)","format":"wav"}}"#
        let part = try decode(wire)
        // vllm constructs the same reference (content_parser.py: `data:audio/{format};base64,{data}`),
        // and `makeMLXAudio`/`ChatAudio` already resolve a `data:` audio reference.
        #expect(part.audioURL?.url == "data:audio/wav;base64," + Self.wavBase64)
        #expect(part.isMedia == true)
        #expect(part.uncarriedType == nil)
    }

    @Test("input_audio encoded on the way out writes audio_url, never the spec key twice")
    func carriedAudioEncodesCanonically() throws {
        let wire =
            #"{"type":"input_audio","input_audio":{"data":"\#(Self.wavBase64)","format":"mp3"}}"#
        let obj =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try decode(wire))) as? [String: Any]
        #expect((obj ?? [:])["audio_url"] != nil)
        #expect((obj ?? [:])["input_audio"] == nil)
    }

    @Test(arguments: [
        ("{\"type\":\"file\",\"file\":{\"filename\":\"a.pdf\",\"file_data\":\"AAAA\"}}", "file"),
        ("{\"type\":\"mystery_part\"}", "mystery_part"),
        ("{\"type\":\"image_url\"}", "image_url"),
        ("{\"type\":\"audio_url\",\"audio_url\":{\"url\":\"\"}}", "audio_url"),
        ("{\"type\":\"video_url\",\"video_url\":{\"url\":\"\"}}", "video_url"),
        // A named attachment with nothing in it: no container name, no bytes — guessing
        // `wav` would invent a format the client never sent.
        (
            "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"\",\"format\":\"wav\"}}",
            "input_audio"
        ),
        ("{\"type\":\"input_audio\",\"input_audio\":{\"format\":\"wav\"}}", "input_audio"),
    ])
    func uncarriedShapesAreInvisibleBelowAndNamedByTheirOwnType(wire: String, expected: String)
        throws
    {
        let part = try decode(wire)
        #expect(part.uncarriedType == expected)
        // Why the drop was silent: every consumer below the handler keys off a payload that
        // arrived, so each of these reads as "no media in this conversation" — which is why
        // the refusal cannot live below here.
        let conversation = [Message(role: "user", content: .parts([part]))]
        #expect(ChatMedia.mediaParts(in: conversation).isEmpty)
        #expect(ChatAudio.audioParts(in: conversation).isEmpty)
    }

    @Test(arguments: [
        // A declared text part carries nothing and is still not a lost attachment — clients
        // pad with these, and refusing one would break a working request for no gain.
        "{\"type\":\"text\"}",
        "{\"type\":\"text\",\"text\":\"\"}",
        // Real content under a type string this server does not know: the words arrive, so
        // the turn is answerable and refusing it would throw a message away.
        "{\"type\":\"file\",\"text\":\"summarise this\"}",
        "{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://i.png\"}}",
        "{\"type\":\"audio\",\"audio_url\":{\"url\":\"/tmp/a.wav\"}}",
        "{\"type\":\"video_url\",\"video_url\":{\"url\":\"https://v.mp4\"}}",
    ])
    func carriedOrTextualPartsAreNeverRefused(wire: String) throws {
        #expect(try decode(wire).uncarriedType == nil)
    }

    @Test("the extraction publishes the wire path of each offender, in wire order")
    func indicesPointAtTheOffendingField() throws {
        let wire = #"""
            {"model":"m","messages":[
              {"role":"user","content":[{"type":"text","text":"fine"}]},
              {"role":"user","content":[{"type":"file","file":{"filename":"a.pdf"}},{"type":"text","text":"kept"}]}
            ]}
            """#
        let request = try JSONDecoder().decode(
            ChatCompletionRequest.self, from: wire.data(using: .utf8)!)
        let found = ChatMedia.uncarried(in: request.messages)
        #expect(found.count == 1)
        // The refusal's `param` is built from exactly these: messages[1].content[0].type
        #expect(found.first?.messageIndex == 1)
        #expect(found.first?.partIndex == 0)
        #expect(found.first?.type == "file")
    }
}
