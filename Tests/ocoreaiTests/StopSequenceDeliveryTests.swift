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

import Foundation
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

// MARK: - Inbound shape: `stop` is a union on the wire

/// The spec types `stop` as `string | array[string] | null` -- vllm `StopParam`
/// (entrypoints/generate/base/protocol.py:26), sglang Optional[Union[str, List[str]]]
/// (srt/entrypoints/openai/protocol.py:368) -- and the canonical SDKs send whichever
/// spelling the caller wrote. Decoding [String]-only turned a legal bare string into a
/// 400 on that field, while its neighbour `prompt` on the very same body already
/// honoured the same union (CompletionRequest.init(from:)).
///
/// Each body below is written ONCE and fed to both OpenAI faces: the shape rule has one
/// home (decodeStopUnion), so per-face expectations would be a second truth able to drift.
@Suite("`stop` decodes the union the spec types it as -- both OpenAI faces")
struct StopUnionDecodeTests {

    private func chatStop(_ body: String) throws -> [String]? {
        try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(body.utf8)).stop
    }

    private func completionsStop(_ body: String) throws -> [String]? {
        try JSONDecoder().decode(CompletionRequest.self, from: Data(body.utf8)).stop
    }

    /// A legal `stop` field and the sequences it must decode to.
    private struct Spelling {
        let name: String
        let field: String
        let expected: [String]?
    }

    private static let legal: [Spelling] = [
        Spelling(name: "bare string", field: "\"stop\": \"END\"", expected: ["END"]),
        Spelling(name: "single-element array", field: "\"stop\": [\"END\"]", expected: ["END"]),
        Spelling(
            name: "multi-element array keeps order", field: "\"stop\": [\"STOP\", \"END\"]",
            expected: ["STOP", "END"]
        ),
        Spelling(name: "explicit null", field: "\"stop\": null", expected: nil),
        Spelling(name: "absent", field: "", expected: nil),
    ]

    @Test("chat face honours every legal spelling, exact value")
    func chatLegal() throws {
        for spelling in Self.legal {
            let body = Self.body(Self.messagesChunk, spelling.field)
            #expect(try chatStop(body) == spelling.expected, "spelling: \(spelling.name)")
        }
    }

    @Test("completions face honours the same spellings -- the sibling fix")
    func completionsLegal() throws {
        for spelling in Self.legal {
            let body = Self.body(Self.promptChunk, spelling.field)
            #expect(
                try completionsStop(body) == spelling.expected, "spelling: \(spelling.name)")
        }
    }

    /// Both faces decode the field through the same helper, so any divergence here is
    /// the two-faces-two-answers defect class coming back.
    @Test("the two faces cannot disagree about one stop value")
    func facesAgree() throws {
        for spelling in Self.legal {
            let viaChat = try chatStop(Self.body(Self.messagesChunk, spelling.field))
            let viaCompletions =
                try completionsStop(Self.body(Self.promptChunk, spelling.field))
            #expect(viaChat == viaCompletions, "spelling: \(spelling.name)")
        }
    }

    /// Premise of routing through one helper: the union must not widen into a black hole
    /// that turns a malformed body into a silent no-op. AGENTS.md invariant 2 -- a caller
    /// bug costs a 4xx naming the field, never the server and never a quietly ignored
    /// knob (the shape RequestNumericDomainTests and probe 09 pin for numeric knobs).
    @Test("a non-string, non-array stop still throws rather than becoming no-stop")
    func wrongTypeStillThrows() {
        let badFields = [
            "\"stop\": 5",
            "\"stop\": [5]",
            "\"stop\": {\"a\": 1}",
        ]
        for field in badFields {
            let body = Self.body(Self.messagesChunk, field)
            #expect(throws: (any Error).self) {
                _ = try self.chatStop(body)
            }
            let completionsBody = Self.body(Self.promptChunk, field)
            #expect(throws: (any Error).self) {
                _ = try self.completionsStop(completionsBody)
            }
        }
    }

    /// Premise: the union sits beside fields that already had their own shapes and must
    /// not have disturbed them -- `prompt` keeps its own union, and an absent stop
    /// leaves the rest of the request intact.
    @Test("premise: neighbouring fields are untouched by the union")
    func neighboursIntact() throws {
        let req = try JSONDecoder().decode(
            CompletionRequest.self,
            from: Data("{\"prompt\": [\"a\", \"b\"], \"model\": \"m\"}".utf8))
        #expect(req.prompt == ["a", "b"])
        #expect(req.stop == nil)
        #expect(req.model == "m")

        let ids = try JSONDecoder().decode(
            CompletionRequest.self,
            from: Data("{\"prompt\": [1, 2, 3]}".utf8))
        #expect(ids.stop == nil)
    }

    // MARK: Body builders

    private static let messagesChunk =
        "\"messages\": [{\"role\": \"user\", \"content\": \"count\"}]"
    private static let promptChunk =
        "\"prompt\": \"count to twenty\""

    private static func body(_ required: String, _ stopField: String) -> String {
        var fields = [required]
        if !stopField.isEmpty { fields.append(stopField) }
        return "{" + fields.joined(separator: ", ") + "}"
    }
}
