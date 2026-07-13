// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Engine-pool behavioral tests — contentToString actual pipeline, sampling
/// normalization, token count heuristic. Only tests that exercise real
/// data transformation logic.

import Testing
import Foundation
@testable import ocoreai

// MARK: - contentToString pipeline

@Suite("contentToString — actual compactMap/join pipeline")
struct ContentToStringPipelineTests {

    @Test("plain text passthrough")
    func textPassthrough() async {
        let (text, dropped) = contentToString(ContentPolymorphic.text("hello"))
        #expect(text == "hello")
        #expect(dropped == 0)
    }

    @Test("parts: text + image + text → image dropped, text joined")
    func mixedParts() async {
        let parts = [
            ContentPart(type: "text", text: "first", imageUrl: nil),
            ContentPart(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "https://img.png")),
            ContentPart(type: "text", text: "last", imageUrl: nil),
        ]
        let content = ContentPolymorphic.parts(parts)
        let (text, dropped) = contentToString(content)
        #expect(text == "first last")
        #expect(dropped == 1)
    }

    @Test("parts: nil text → filtered by compactMap")
    func nilTextFiltered() async {
        let parts = [
            ContentPart(type: "text", text: "visible", imageUrl: nil),
            ContentPart(type: "text", text: nil, imageUrl: nil),
        ]
        let content = ContentPolymorphic.parts(parts)
        let (text, dropped) = contentToString(content)
        #expect(text == "visible")
        #expect(dropped == 1)
    }

    @Test("parts: empty string text → kept (compactMap keeps \"\" not nil)")
    func emptyTextKept() async {
        let parts = [
            ContentPart(type: "text", text: "a", imageUrl: nil),
            ContentPart(type: "text", text: "", imageUrl: nil),
            ContentPart(type: "text", text: "b", imageUrl: nil),
        ]
        let content = ContentPolymorphic.parts(parts)
        let (text, dropped) = contentToString(content)
        // ["a", "", "b"].joined(separator: " ") == "a  b"
        #expect(text == "a  b")
        #expect(dropped == 0)
    }

    @Test("all image parts → empty text, dropped = count")
    func allImages() async {
        let parts = [
            ContentPart(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "a.png")),
            ContentPart(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: "b.png")),
        ]
        let content = ContentPolymorphic.parts(parts)
        let (text, dropped) = contentToString(content)
        #expect(text.isEmpty)
        #expect(dropped == 2)
    }

    @Test("nil content → empty string, 0 dropped")
    func nilContent() async {
        let (text, dropped) = contentToString(nil)
        #expect(text.isEmpty)
        #expect(dropped == 0)
    }

    @Test("empty parts array → empty string, 0 dropped")
    func emptyPartsArray() async {
        let content = ContentPolymorphic.parts([])
        let (text, dropped) = contentToString(content)
        #expect(text.isEmpty)
        #expect(dropped == 0)
    }
}

// MARK: - Token count heuristic

@Suite("Token count heuristic — UTF-8/4 estimation")
struct TokenHeuristicTests {

    @Test("multiple messages → sum is positive")
    func multipleMessages() async {
        let messages = [
            Message(role: "user", content: "hello"),
            Message(role: "assistant", content: "world"),
        ]
        let count = messages.reduce(0) { $0 + $1.textContent().utf8.count / 4 }
        #expect(count > 0)
    }

    @Test("longer text → higher estimate")
    func longerTextMoreTokens() async {
        let msg1 = Message(role: "user", content: "hi")
        let msg2 = Message(role: "user", content: "this is a much longer message with more words")
        let est1 = msg1.textContent().utf8.count / 4
        let est2 = msg2.textContent().utf8.count / 4
        #expect(est2 > est1)
    }
}
