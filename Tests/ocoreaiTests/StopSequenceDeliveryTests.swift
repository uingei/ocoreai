// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Gate: `stop` on the wire actually cuts the reply — at the earliest occurrence, before
/// the stop text, and with OpenAI's word for it.
///
/// Located 10-18 by measuring, not reading: `POST /v1/chat/completions` with
/// `stop:["2"]` on a counting prompt returned the full `1 2 3 … 20` with
/// `finish_reason:"stop"`, while the same binary's own engine log recorded
/// `stopmatch=2 len=3` — the engine had already decided to stop and the stream ignored it.
/// Two independent causes, both at the seam every path shares:
///   1. every call site did `if shouldBreak { … break }` from inside a `switch` nested in
///      the generation loop, so `break` left the switch and the loop kept streaming.
///   2. the test was `accumulated.hasSuffix(stop)`, which misses a stop that arrives in
///      the middle of a decoded chunk, and when it did match at offset 0 the whole chunk
///      was dropped — `stop:["banana"]` returned four bananas where the same prompt with
///      no stop returned five. Text lost, and the client never told why.
/// Contract now (OpenAI/vllm: the stop text is not part of the returned content): cut at
/// the earliest occurrence anywhere in the reply, hand over only text that is both new and
/// precedes the cut, then report termination — spelled `"stop"`, because OpenAI's
/// `finish_reason` enum is `stop | length | tool_calls | content_filter` and this repo
/// already translates Anthropic's `stop_sequence` to `"stop"` on the way in
/// (`AnthropicModels.swift:726`).
///
/// Surviving companion: live probe `scripts/probes/10-sampling-knob-delivery.sh`, which
/// measures truncation on a real model in both streaming and non-streaming modes.

import Testing

@testable import ocoreai

@Suite("firstStopOccurrence — earliest match anywhere in the reply")
struct FirstStopOccurrenceTests {

    @Test("no sequences, no occurrence, and empty-only sequences all mean do-not-stop")
    func noStop() {
        #expect(EnginePool.firstStopOccurrence(in: "hello", sequences: []) == nil)
        #expect(EnginePool.firstStopOccurrence(in: "hello", sequences: ["zzz"]) == nil)
        #expect(EnginePool.firstStopOccurrence(in: "hello", sequences: ["", ""]) == nil)
    }

    /// The defect this replaces matched suffixes only, so a stop that arrived mid-chunk
    /// never fired. Here "2" is followed by more text on purpose.
    @Test("a stop in the middle of the reply is found, not just one at the end")
    func midTextMatch() {
        let text = "1 2 3 4"
        let hit = EnginePool.firstStopOccurrence(in: text, sequences: ["2"])
        guard let hit else {
            Issue.record("\"2\" occurs at index 2 and must stop the reply")
            return
        }
        #expect(String(text[hit.range]) == "2")
        #expect(text[text.startIndex ..< hit.range.lowerBound] == "1 ")
    }

    @Test("the earliest of several candidates wins, whichever order they are sent in")
    func earliestWins() {
        let text = "one two three"
        let forward = EnginePool.firstStopOccurrence(in: text, sequences: ["two", "three"])
        let reverse = EnginePool.firstStopOccurrence(in: text, sequences: ["three", "two"])
        #expect(forward?.sequence == "two")
        #expect(reverse?.sequence == "two", "list order must not decide when the reply does")
        if let forward {
            #expect(String(text[forward.range]) == "two")
        }
    }

    @Test("a reply that begins with the stop sequence cuts everything")
    func matchAtOffsetZero() {
        let text = "banana banana"
        let hit = EnginePool.firstStopOccurrence(in: text, sequences: ["banana"])
        guard let hit else {
            Issue.record("expected a match at offset 0")
            return
        }
        #expect(hit.range.lowerBound == text.startIndex)
        #expect(text[text.startIndex ..< hit.range.lowerBound] == "")
    }

    /// Pinning the tie-break: same start offset keeps the sequence listed first. Behaviour
    /// is only a contract if something says which way it goes.
    @Test("same start offset keeps the earlier-listed sequence")
    func tieBreaksToFirstListed() {
        let text = "aaaa"
        let hit = EnginePool.firstStopOccurrence(in: text, sequences: ["aa", "aaa"])
        #expect(hit?.sequence == "aa")
        if let hit {
            #expect(hit.range.lowerBound == text.startIndex)
        }
    }

    /// Cutting is done in Characters; a byte/Character mix would split a grapheme cluster.
    @Test("multibyte content cuts at a character boundary, not a byte offset")
    func multibyteSafe() {
        let text = "café ☕🍌 done"
        let hit = EnginePool.firstStopOccurrence(in: text, sequences: ["🍌"])
        guard let hit else {
            Issue.record("expected the emoji stop sequence to be found")
            return
        }
        let kept = String(text[text.startIndex ..< hit.range.lowerBound])
        #expect(kept == "café ☕")
        #expect(
            kept.count == 6, "Character count, not UTF-8 byte count (the emoji alone is 4 bytes)")
    }
}

@Suite("Termination is reported with OpenAI's word")
struct OpenAIFinishReasonWordTests {

    @Test("stop-string termination reports \"stop\", the only spelling in OpenAI's enum")
    func stopSequenceReportsStop() {
        #expect(stopReasonToString(.stopSequence) == "stop")
        #expect(stopReasonToString(.eos) == "stop")
        #expect(stopReasonToString(.maxTokens) == "length")
        #expect(stopReasonToString(.cancelled) == "cancelled")
        #expect(stopReasonToString(.error) == "error")
        #expect(stopReasonToString(nil) == nil)
    }

    /// Premise of the shared-helper change: the Anthropic wire translates from these words,
    /// so re-spelling `stop_sequence` as `stop` must land on `end_turn` — the value it
    /// already produced via the `default:` arm. Without this, the fix above would silently
    /// change /v1/messages.
    @Test("premise: Anthropic's mapping is unchanged by the OpenAI word fix")
    func anthropicSideUnchanged() {
        #expect(openAIToAnthropicStopReason("stop") == "end_turn")
        #expect(openAIToAnthropicStopReason("stop_sequence") == "end_turn")
        #expect(openAIToAnthropicStopReason("length") == "max_tokens")
        #expect(openAIToAnthropicStopReason("tool_calls") == "tool_use")
    }
}
