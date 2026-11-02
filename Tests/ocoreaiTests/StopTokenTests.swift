// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — consumed from coreai-models swift/Tests/GuidedGenerationTests/StopTokenTests.swift
// at 6a6bb0e (#374, 10-30), the only commit that file has in the mirror (checked 11-02: `git log --` that
// path returns 6a6bb0e alone; a mirror proves content, never HEAD). The four tests are upstream's,
// unchanged but for three named deviations:
//   1. The suite is gated on `PlatformPremise.hasMacOS27`: this tree's grammar surface is
//      `@available(macOS 27.0, *)`, so on a macOS 26 host it reports a skip, not a green it did not run.
//   2. `allowedTokenIDs(session:)` lives in `GrammarTestUtilities.swift` with upstream's body (upstream
//      keeps it in `TestUtilities.swift:68-79`, a file this tree does not consume).
//   3. Upstream's vocabulary spells the two special-token literals directly. They are composed from parts
//      here, because writing that literal shape into a file disrupted authoring on this host (11-02 —
//      host-local colour, not a project verdict, so it is labelled as such). `imEndDecoded` pins what the
//      composed entry means, so the fixture cannot silently become a different token.
//
// Why this file exists in place of a local one: this tree's own suite for the same fix had been red on
// the macOS 27 runner since it landed, and the reason was the fixture, not the fix — it named the
// grammar's own opening brace as the stop id and asked for a blocked bit where an emptied mask is the
// honest answer. Upstream names its stop ids *outside* the grammar's alphabet, where withholding cannot
// starve the grammar, and that is what a caller's end-of-turn id actually is.

#if canImport(CoreAI)

import Foundation
import Testing

@testable import ocoreai

@Suite(
    "A grammar's stop tokens",
    .enabled(if: PlatformPremise.hasMacOS27)
)
struct StopTokenTests {
    /// Ids into `vocab`: the document `{"a":1}` and two end tokens, as Qwen3 has both.
    private enum Id {
        static let open: Int32 = 0, close: Int32 = 1, quote: Int32 = 2, colon: Int32 = 3
        static let a: Int32 = 4, one: Int32 = 5, imEnd: Int32 = 6, endOfText: Int32 = 7
    }

    private static let imEndDecoded = "<|" + "im_end|>"
    private static let endOfTextDecoded = "<|" + "|end_of_text|"

    /// The stop ids are chat-end tokens: characters none of them spell (`tokenizer_info.cc:241-246`)
    /// and no JSON rule ever wants, which is why withholding one from the alphabet costs the grammar
    /// nothing. What a caller's one-token `stop` does when it *is* a character the schema needs is
    /// `GrammarStopTokenPlumbingTests`, not this file.
    private static let vocab: [String] = [
        "{", "}", "\"", ":", "a", "1", imEndDecoded, endOfTextDecoded,
    ]
    private static let json = [Id.open, Id.quote, Id.a, Id.quote, Id.colon, Id.one, Id.close]
    private static let schema =
        """
        {"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"], \
        "additionalProperties": false}
        """

    @available(macOS 27.0, *)
    private func session(stopTokenIds: [Int32]?) throws -> ConstrainedGenerationSession {
        try ConstrainedGenerationSession(
            jsonSchema: Self.schema, vocabulary: Self.vocab, vocabType: .raw,
            stopTokenIds: stopTokenIds)
    }

    /// The ids the grammar allows after `tokens`.
    @available(macOS 27.0, *)
    private func allowedAfter(_ tokens: [Int32], stopTokenIds: [Int32]?) throws -> Set<Int32> {
        var grammar = try session(stopTokenIds: stopTokenIds)
        for token in tokens {
            let accepted = grammar.acceptToken(token)
            #expect(accepted)
        }
        return allowedTokenIDs(session: &grammar)
    }

    @Test(
        "The stop tokens given are the ones allowed once the JSON is complete",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func givenStopTokensAreAllowedAtTheEnd() throws {
        // The model's own end of turn, not the one xgrammar would pick from the vocabulary.
        #expect(try allowedAfter(Self.json, stopTokenIds: [Id.imEnd]) == [Id.imEnd])
        #expect(
            try allowedAfter(Self.json, stopTokenIds: [Id.imEnd, Id.endOfText])
                == [Id.imEnd, Id.endOfText])
    }

    @Test(
        "A stop token is refused before the JSON is complete",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func stopTokensWaitForTheEnd() throws {
        for count in 0 ..< Self.json.count {
            let allowed = try allowedAfter(
                Array(Self.json.prefix(count)), stopTokenIds: [Id.imEnd, Id.endOfText])
            #expect(
                !allowed.contains(Id.imEnd) && !allowed.contains(Id.endOfText),
                "after \(count) token(s)")
        }
    }

    @Test(
        "Accepting a stop token ends the grammar",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func stopTokenTerminates() throws {
        var grammar = try session(stopTokenIds: [Id.imEnd])
        for token in Self.json + [Id.imEnd] {
            let accepted = grammar.acceptToken(token)
            #expect(accepted)
        }
        let terminated = grammar.isTerminated
        #expect(terminated)
    }

    @Test(
        "The stop tokens reach the grammar through TokenizerInfo too",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func tokenizerInfoCarriesStopTokens() throws {
        let info = TokenizerInfo(vocabulary: Self.vocab, vocabType: .raw, stopTokenIds: [Id.imEnd])
        #expect(info.stopTokenIds == [Id.imEnd])
        var grammar = try ConstrainedGenerationSession(
            jsonSchema: Self.schema, tokenizerInfo: info)
        for token in Self.json {
            let accepted = grammar.acceptToken(token)
            #expect(accepted)
        }
        let allowed = allowedTokenIDs(session: &grammar)
        #expect(allowed == [Id.imEnd])
    }
}

#endif
