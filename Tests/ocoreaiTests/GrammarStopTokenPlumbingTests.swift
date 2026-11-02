// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// GrammarStopTokenPlumbingTests.swift — the caller's stop token ids must reach xgrammar.
///
/// `ConstrainedDecodingStrategy.createSession` derives single-token stop ids from the request's
/// `stop` field (`:97`) and logs them as applied. Until `3b9c61f` the value went nowhere: the
/// session built its `TokenizerInfo` without them and the vendored bridge handed xgrammar
/// `std::nullopt`, so xgrammar substituted the eight literals it detects by text
/// (`tokenizer_info.cc:281`: `</s>`, `<|end_of_text|>`, `<|eot_id|>` and five peers). A stop token
/// matching none of them was classified `special` instead, and the two lists are disjoint — that
/// line routes each vocabulary entry down exactly one branch. This is coreai-models #374 (6a6bb0e),
/// which fixed the identical discard upstream; our `Sources/lib/CXGrammar` is their file, so the
/// bridge patch is consumed, not re-authored.
///
/// ### What xgrammar does with a named id — the model this suite asserts
/// The same branch that classifies it also **withholds it from `sorted_decoded_vocab_`**, the
/// vocabulary the matcher matches against (`tokenizer_info.cc:281-287`: one if / else-if / else
/// chain, and the third arm is the one that pushes into the sorted vocab). So naming an id does not
/// reserve it for the end of the document; it takes it out of the grammar's alphabet, and
/// `grammar_matcher.cc:1065`/`:1085` only add it back at a terminal state and subtract it at a
/// non-terminal one. Both consequences are measured, on this host, through this tree's own bridge
/// against the pinned xgrammar 0.2.2 (`4d145cc`) — recipe in CHANGELOG 11-02(104):
/// naming `"` where the grammar admits it drops the mask from 3 allowed tokens to 2 (the witness
/// that the ids arrive at all), and naming `{` at the start leaves **zero** allowed.
///
/// ### Why the first version of this suite was red on the macOS 27 runner
/// It asked `nextTokenBitmask()` for `false` where the honest answer is `nil`: an all-zero mask is
/// read as "the grammar is done" (`ConstrainedGenerationSession.swift:175`), so a starved grammar
/// reports the document complete. That is a hazard, not a contract — a caller whose one-token
/// `stop` string is a character the schema needs (`"`, `{`, a digit) should not get truncated JSON
/// presented as finished. It is asserted here in the shape the engine actually produces, so that
/// the guard `open-items.md` puts to its owner turns *this* test red instead of this test quietly
/// rotting into a tautology.
///
/// The Swift surface is `@available(macOS 27.0, *)` (the whole GuidedGeneration directory is
/// CoreAI-gated), so this suite skips on a macOS 26 host through `PlatformPremise.hasMacOS27`
/// rather than reporting a green it did not run; what was measured here is the C layer underneath.

#if canImport(CoreAI)

import Foundation
import Testing

@testable import ocoreai

@Suite(
    "Grammar stop tokens: a caller's stop id must reach the grammar",
    .enabled(if: PlatformPremise.hasMacOS27)
)
struct GrammarStopTokenPlumbingTests {

    /// A byte-level vocabulary: one entry per id, every JSON character present, plus `"q"` as an
    /// ordinary character the schema's grammar never accepts.
    private static let vocabulary: [String] = [
        "{", "}", "[", "]", ":", ",", "\"", " ", "\n",
        "a", "1", "0", "-", "+", ".", "e", "E", "n", "u", "l", "t", "r", "f", "s", "e2", "q",
    ]
    private static let lbrace = 0
    private static let quote = 6
    private static let ordinaryQ = 25

    private static let schema =
        """
        {"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}
        """

    /// The mask after feeding a prefix, plus what the session then believes about itself. `mask == nil`
    /// is the session's own verdict "nothing left to generate", reached either by explicit termination
    /// or by the all-zero mask (`ConstrainedGenerationSession.swift:175`) — the two are reported
    /// together on purpose, because which one happened *is* the finding.
    @available(macOS 27.0, *)
    private static func maskAfterFeeding(
        stopTokenIds: [Int32]?, fed: [Int] = []
    ) throws -> (mask: [Int32]?, terminated: Bool) {
        var session = try ConstrainedGenerationSession(
            jsonSchema: schema,
            vocabulary: vocabulary,
            vocabType: .byteLevel,
            stopTokenIds: stopTokenIds
        )
        for token in fed where !session.acceptToken(Int32(token)) {
            Issue.record("the grammar must admit the prefix token \(token)")
            return (nil, false)
        }
        let mask = session.nextTokenBitmask()
        return (mask, session.isTerminated)
    }

    @available(macOS 27.0, *)
    private static func allowed(_ id: Int, in mask: [Int32]?) -> Bool? {
        guard let mask else { return nil }
        return (mask[id / 32] >> (UInt32(id % 32))) & 1 == 1
    }

    @available(macOS 27.0, *)
    private static func allowedCount(_ mask: [Int32]?) -> Int? {
        guard let mask else { return nil }
        return (0 ..< vocabulary.count).filter { Self.allowed($0, in: mask) == true }.count
    }

    @Test(
        "a named stop id leaves the grammar's alphabet — the witness that the ids arrive",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func namedStopIdLeavesTheAlphabet() throws {
        // `"` is what the grammar wants after `{`, and naming it takes it away: 3 tokens allowed
        // become 2 (the two whitespace spellings), measured through the bridge on this host. Both
        // counts are asserted, so a discard at the bridge or at TokenizerInfo shows up as 3/3 and a
        // starved grammar shows up as nil — neither can pass as "the ids got through".
        let unnamed = try Self.maskAfterFeeding(stopTokenIds: nil, fed: [Self.lbrace])
        #expect(Self.allowed(Self.quote, in: unnamed.mask) == true)
        #expect(Self.allowedCount(unnamed.mask) == 3)
        #expect(!unnamed.terminated)

        let named = try Self.maskAfterFeeding(
            stopTokenIds: [Int32(Self.quote)], fed: [Self.lbrace])
        #expect(Self.allowed(Self.quote, in: named.mask) == false)
        #expect(Self.allowedCount(named.mask) == 2)
        #expect(!named.terminated, "one id withheld is not the grammar ending")
    }

    @Test(
        "naming a token the grammar needs starves it, and the session calls that done",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func namingANeededTokenStarvesTheGrammar() throws {
        // The hazard face, asserted as measured — not as desirable. `{` is the only token that can
        // open this document, and once it is out of the alphabet nothing is admissible at position 0:
        // the mask comes back all zeros, which the session reads as a complete document. So a wire
        // request whose one-token `stop` is `{` (or `"` further in) ends the constrained turn with a
        // truncated object and no error. Pinned at the shape the engine produces; the owner call in
        // `open-items.md` is whether to refuse such a `stop` at the seam, and this test goes red when
        // that guard lands.
        let starved = try Self.maskAfterFeeding(stopTokenIds: [Int32(Self.lbrace)])
        #expect(
            starved.mask == nil,
            "measured: naming a token the grammar needs empties the mask")
        #expect(
            starved.terminated,
            "the all-zero mask is read as 'document complete' — the reason this is a hazard")
        // The same session asked with nothing named opens normally, so the nil above is the naming's
        // doing and not this vocabulary or schema failing on its own.
        let unowned = try Self.maskAfterFeeding(stopTokenIds: nil)
        #expect(Self.allowed(Self.lbrace, in: unowned.mask) == true)
    }

    @Test(
        "the ids own classification, not the token's spelling",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func acceptFollowsTheNamedList() throws {
        // The matcher's other entry point (`grammar_matcher.cc:634`): a named id is refused as input,
        // and is an ordinary character when the caller named somebody else. Two entry points, so a
        // discard at either one goes red.
        let namedStop = try Self.acceptsFirst(Self.lbrace, stopTokenIds: [Int32(Self.lbrace)])
        #expect(!namedStop)
        let namedElsewhere = try Self.acceptsFirst(
            Self.lbrace, stopTokenIds: [Int32(Self.ordinaryQ)])
        #expect(namedElsewhere)
    }

    /// `acceptToken` on a fresh session, read into a value first: the session is `~Copyable`, and
    /// `#expect` would otherwise try to capture it.
    @available(macOS 27.0, *)
    private static func acceptsFirst(_ id: Int, stopTokenIds: [Int32]?) throws -> Bool {
        var session = try ConstrainedGenerationSession(
            jsonSchema: schema,
            vocabulary: vocabulary,
            vocabType: .byteLevel,
            stopTokenIds: stopTokenIds
        )
        return session.acceptToken(Int32(id))
    }
}

#endif
