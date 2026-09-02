// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MessageMediaDetectionTests.swift — precise-value invariants for the
/// `Message.hasMediaPart` / `Message.mediaPartCount` / `ContentPart.isMedia`
/// media-detection predicates (single source of truth for the engine's VLM
/// guard and the MessageBuilder complexity fallback).
///
/// Previously this predicate was inlined in two places (EngineInference
/// closure `hasMultimodalContent` + MessageBuilder `reduce` over
/// ContentPart). Drift between the two copies is the regression class this
/// suite locks (e.g. one copy adding a new part type before the other).
///
/// Methodology: exact-value assertions (==), exhaustive part-type coverage
/// (text / image / video / audio / mixed), no `count > N` weak asserts.

import Foundation
import Testing

@testable import ocoreai

// MARK: - ContentPart.isMedia

@Suite("ContentPart.isMedia — pure predicate per part type")
struct ContentPartIsMediaTests {
    @Test("text-only part → false")
    func textOnly() {
        let p = ContentPart(type: "text", text: "hello", imageUrl: nil)
        #expect(p.isMedia == false)
    }

    @Test("image part → true")
    func image() {
        let p = ContentPart(
            type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "https://img.png"))
        #expect(p.isMedia == true)
    }

    @Test("video part → true")
    func video() {
        let p = ContentPart(
            type: "video", text: nil, imageUrl: nil,
            videoUrl: ContentPart.VideoURL(url: "https://vid.mp4", maxFrames: 8))
        #expect(p.isMedia == true)
    }

    @Test("audio part → true")
    func audio() {
        let p = ContentPart(
            type: "audio", text: nil, imageUrl: nil, audioURL: ContentPart.AudioURL(url: "a.mp3"))
        #expect(p.isMedia == true)
    }

    @Test("text + image dual → true (any media wins)")
    func textAndImage() {
        let p = ContentPart(
            type: "image_url", text: "caption", imageUrl: ContentPart.ImageURL(url: "https://i.png")
        )
        #expect(p.isMedia == true)
    }
}

// MARK: - Message.hasMediaPart / mediaPartCount

@Suite("Message media detection — predicate + count per content shape")
struct MessageMediaPartTests {
    @Test("plain .text message → hasMediaPart false, count 0")
    func plainText() {
        let m = Message(role: "user", content: .text("hello"))
        #expect(m.hasMediaPart == false)
        #expect(m.mediaPartCount == 0)
    }

    @Test("nil .content → false, 0 (guard path)")
    func nilContent() {
        let m = Message(role: "user", content: nil, name: nil, toolCalls: nil, toolCallID: nil)
        #expect(m.hasMediaPart == false)
        #expect(m.mediaPartCount == 0)
    }

    @Test(".parts with text only → false, 0")
    func partsTextOnly() {
        let m = Message(
            role: "user",
            content: .parts([
                ContentPart(type: "text", text: "a", imageUrl: nil),
                ContentPart(type: "text", text: "b", imageUrl: nil),
            ]))
        #expect(m.hasMediaPart == false)
        #expect(m.mediaPartCount == 0)
    }

    @Test(".parts with 1 image among 2 text → true, 1")
    func oneImage() {
        let m = Message(
            role: "user",
            content: .parts([
                ContentPart(type: "text", text: "look", imageUrl: nil),
                ContentPart(
                    type: "image_url", text: nil,
                    imageUrl: ContentPart.ImageURL(url: "https://i.png")),
                ContentPart(type: "text", text: "this", imageUrl: nil),
            ]))
        #expect(m.hasMediaPart == true)
        #expect(m.mediaPartCount == 1)
    }

    @Test(".parts image + video + audio → true, 3 (each type counted once)")
    func threeMediaTypes() {
        let m = Message(
            role: "user",
            content: .parts([
                ContentPart(
                    type: "image_url", text: nil,
                    imageUrl: ContentPart.ImageURL(url: "https://i.png")),
                ContentPart(
                    type: "video", text: nil, imageUrl: nil,
                    videoUrl: ContentPart.VideoURL(url: "https://v.mp4")),
                ContentPart(
                    type: "audio", text: nil, imageUrl: nil,
                    audioURL: ContentPart.AudioURL(url: "a.mp3")),
            ]))
        #expect(m.hasMediaPart == true)
        #expect(m.mediaPartCount == 3)
    }

    @Test("multi-message: contains(where:) detects a single media message in a list")
    func mixedList() {
        let msgs: [Message] = [
            Message(role: "system", content: .text("you are useful")),
            Message(role: "user", content: .text("describe this")),
            Message(
                role: "user",
                content: .parts([
                    ContentPart(
                        type: "image_url", text: nil,
                        imageUrl: ContentPart.ImageURL(url: "https://i.png"))
                ])),
        ]
        #expect(msgs.contains(where: \.hasMediaPart) == true)
        // Total media across the whole conversation — exact 1 (not >= 1).
        let total = msgs.reduce(0) { $0 + $1.mediaPartCount }
        #expect(total == 1)
    }
}
