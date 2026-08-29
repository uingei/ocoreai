// Copyright © 2026 uingei@163.com
// Licensed under MIT.
/// TTSCleaningTests.swift — canonical TTS cleaning (thinking + code) invariants.
///
/// Locks the single source of truth that the agent `speak` tool
/// (`Speak.build`) and the chat speaker (`MultimodalState.speakIfEnabled`)
/// now both route through. Each behavior is asserted with an EXACT value —
/// no count-`>` weak assertions.

import Foundation
import Testing

@testable import ocoreai

@Suite("TTSCleaning — thinking tags")
struct TTSCleaningThinkingTests {

    @Test
    func stripsThinkingBlockAndKeepsText() {
        let in_ = "Here is the answer.<thinking>\nplan step 1\nplan step 2\n</thinking>Done."
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out == "Here is the answer.Done.")
        #expect(!out.contains("<thinking>"))
        #expect(!out.contains("plan step"))
    }

    @Test
    func stripsNestedThinkingTags() {
        let in_ = "A<thinking>outer</thinking><thinking>mid</thinking>B"
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out == "AB")
    }

    @Test
    func noThinkingTagLeavesTextUnchanged() {
        let in_ = "plain text, no tags"
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out == in_)
    }

    @Test
    func multiLineThinkingBodyIsRemoved() {
        let in_ =
            "prefix\n<thinking>\nline 1\n```\ncode in thinking\n```\nline 2\n</thinking>\nsuffix"
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out == "prefix\n\nsuffix")
        #expect(!out.contains("line 1"))
        #expect(!out.contains("code in thinking"))
        #expect(!out.contains("line 2"))
    }
}

@Suite("TTSCleaning — code blocks")
struct TTSCleaningCodeTests {

    @Test
    func dropsFencedCodeBlock() {
        let in_ = "Use this:\n```swift\nlet x = 1\nlet y = 2\n```\nDone."
        let out = TTSCleaning.speakable(in_, 0)
        #expect(!out.contains("```"))
        #expect(!out.contains("let x = 1"))
        #expect(!out.contains("let y = 2"))
        #expect(out.contains("Use this:"))
        #expect(out.contains("Done."))
    }

    @Test
    func dropsMultiFenceBlocksPreservesOrder() {
        let in_ = "start\n```py\nprint(1)\n```\nmiddle\n```sh\necho hi\n```\nend"
        let out = TTSCleaning.speakable(in_, 0)
        #expect(!out.contains("print(1)"))
        #expect(!out.contains("echo hi"))
        #expect(out.contains("start"))
        #expect(out.contains("middle"))
        #expect(out.contains("end"))
    }

    @Test
    func noCodeBlockLeavesTextUnchanged() {
        let in_ = "no fences here"
        #expect(TTSCleaning.speakable(in_, 0) == in_)
    }
}

@Suite("TTSCleaning — idempotency (applying twice == once)")
struct TTSCleaningIdempotencyTests {

    @Test
    func doubleApplicationIsStable() {
        let in_ = "hi\n```code\nx\n```\n<thinking>t</thinking>bye"
        let once = TTSCleaning.speakable(in_, 0)
        let twice = TTSCleaning.speakable(once, 0)
        #expect(once == twice)
        #expect(once == "hi\nbye")
    }

    @Test
    func noEllipsisResidueAfterSecondPass() {
        let in_ = "<thinking>think about it</thinking>actual answer"
        let once = TTSCleaning.speakable(in_, 0)
        let twice = TTSCleaning.speakable(once, 0)
        #expect(twice == "actual answer")
        #expect(!twice.contains("…"))
    }
}

@Suite("TTSCleaning — combined (thinking + code together)")
struct TTSCleaningCombinedTests {

    @Test
    func codeInThinkingAndThinkingInCodeAreBothHandled() {
        // Thinking block containing code, plus a standalone code block.
        let in_ = """
            <thinking>
            planning…
            ```
            some code
            ```
            </thinking>
            ```
            let real = 42
            ```
            here is the result
            """
        let out = TTSCleaning.speakable(in_, 0)
        #expect(!out.contains("thinking"))
        #expect(!out.contains("let real = 42"))
        #expect(!out.contains("some code"))
        #expect(out.contains("here is the result"))
        #expect(!out.contains("```"))
    }

    @Test
    func emptyAfterCleaningIsEmpty() {
        let in_ = "<thinking>only thinking</thinking>"
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out.isEmpty)
    }

    @Test
    func whitespaceOnlyAfterCleaningIsEmpty() {
        let in_ = "```swift\nx\n```"
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out.isEmpty)
    }
}

@Suite("TTSCleaning — cap boundary")
struct TTSCleaningCapTests {

    @Test
    func speakerDefaultCapIs500() {
        #expect(TTSCleaning.speakerDefaultCap == 500)
    }

    @Test
    func truncatesToCapAndStaysSpeakable() {
        let body = String(repeating: "word ", count: 200)
        let out = TTSCleaning.speakable(body, 50)
        #expect(out.count <= 50)
        #expect(!out.contains(">"))
        #expect(out.hasPrefix(String(body.prefix(50))))
    }

    @Test
    func exactLimitIsNoTruncation() {
        let in_ = String(repeating: "a", count: 500)
        let out = TTSCleaning.speakable(in_, 500)
        #expect(out.count == 500)
    }

    @Test
    func limitZeroMeansNoTruncation() {
        let in_ = String(repeating: "a", count: 9000)
        let out = TTSCleaning.speakable(in_, 0)
        #expect(out.count == 9000)
    }
}
