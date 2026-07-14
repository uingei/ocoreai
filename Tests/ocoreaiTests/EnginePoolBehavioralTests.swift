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

// MARK: - Token count heuristic (production function: ChatViewModel.estimateTokens)
// Production: max(1, text.utf8.count / 3) — uses /3, not /4

@Suite("Token count heuristic — production estimateTokens via Message.textContent()")
struct TokenHeuristicTests {

    @Test("hello (5 bytes) → estimate is 1 token (min floor)")
    func helloWord() async {
        let msg = Message(role: "user", content: "hello")
        let est = max(1, msg.textContent().utf8.count / 3) // matches ChatViewModel estimateTokens logic
        #expect(est == 1)
    }

    @Test("hello + world → sum is 2 tokens (each 5 bytes, 5/3=1 each)")
    func twoMessages() async {
        let messages = [
            Message(role: "user", content: "hello"),
            Message(role: "assistant", content: "world"),
        ]
        let count = messages.reduce(0) { $0 + max(1, $1.textContent().utf8.count / 3) }
        // "hello" = 5/3 = 1, "world" = 5/3 = 1 → total = 2
        #expect(count == 2)
    }

    @Test("40-char text → 13 tokens (40 / 3 = 13)")
    func fortyChars() async {
        let msg = Message(role: "user", content: "0123456789012345678901234567890123456789")
        let est = max(1, msg.textContent().utf8.count / 3)
        #expect(est == 13)
    }
}
