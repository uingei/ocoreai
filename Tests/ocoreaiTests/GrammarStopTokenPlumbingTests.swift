// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// GrammarStopTokenPlumbingTests.swift — the caller's stop token ids must reach xgrammar.
///
/// `ConstrainedDecodingStrategy.createSession` derives single-token stop ids from the request's
/// `stop` field and logs them as applied. Until now the value went nowhere: the session built its
/// `TokenizerInfo` without them and the vendored bridge handed xgrammar `std::nullopt`, so
/// xgrammar substituted the eight literals it detects by text (`tokenizer_info_impl.h:92`:
/// `</s>`, `<|end_of_text|>`, `<|eot_id|>` and five peers). A stop token matching none of them was
/// classified `special` instead, and the two lists are disjoint — `tokenizer_info.cc:280` routes
/// each vocabulary entry down exactly one branch. Measured on this host: the cached
/// `mlx-community/LFM2.5-Embedding-350M-4bit` declares the `<|eos|>` literal as its `eos_token`,
/// which is not among the eight.
///
/// What those lists drive lives in xgrammar's bitmask filler (`grammar_matcher.cc:1065` un-sets a
/// stop id when the grammar can reach its end, `:1085` sets it when it cannot, and a special id is
/// set in neither case) and in `AcceptToken` (`:634` routes a stop id to `AcceptStopToken`). So the
/// caller's id being in the stop list is observable two ways, and both are read here: the argument a
/// caller passes must change what the grammar does.
///
/// This is coreai-models #374 (6a6bb0e), which fixed the identical discard upstream; our
/// `Sources/lib/CXGrammar` is their file, so the bridge patch is consumed, not re-authored.
///
/// The grammar surface is `@available(macOS 27.0, *)` (CoreAI-gated), so this suite skips on a
/// macOS 26 host through `PlatformPremise.hasMacOS27` rather than reporting a green it did not run.

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
    private static let ordinaryQ = 25

    private static let schema =
        """
        {"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}
        """

    /// One bit of a session's first mask. `nil` mask means xgrammar reported the grammar as done.
    @available(macOS 27.0, *)
    private static func allowedAtStart(_ id: Int, stopTokenIds: [Int32]?) throws -> Bool? {
        var session = try ConstrainedGenerationSession(
            jsonSchema: schema,
            vocabulary: vocabulary,
            vocabType: .byteLevel,
            stopTokenIds: stopTokenIds
        )
        guard let mask = session.nextTokenBitmask() else { return nil }
        return (mask[id / 32] >> (UInt32(id % 32))) & 1 == 1
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

    @Test(
        "naming a stop id blocks it while the document is incomplete",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func namedStopIdIsBlockedMidDocument() throws {
        // Without ids the caller's stop token is nothing to xgrammar, so `{` opens as usual.
        let unowned = try Self.allowedAtStart(Self.lbrace, stopTokenIds: nil)
        #expect(unowned == true)
        // Naming it makes xgrammar own it: blocked until the grammar can reach its end.
        let owned = try Self.allowedAtStart(Self.lbrace, stopTokenIds: [Int32(Self.lbrace)])
        #expect(owned == false)
    }

    @Test(
        "the ids own classification, not the token's spelling",
        .enabled(if: PlatformPremise.hasMacOS27))
    @available(macOS 27.0, *)
    func acceptFollowsTheNamedList() throws {
        // The same value through the matcher's other entry point (`:634` → `AcceptStopToken`): a named
        // stop id is refused until the document is complete, and accepted as an ordinary character when
        // the caller named somebody else. Two entry points, so a discard at either one goes red.
        let namedStop = try Self.acceptsFirst(Self.lbrace, stopTokenIds: [Int32(Self.lbrace)])
        #expect(!namedStop)
        let namedElsewhere = try Self.acceptsFirst(
            Self.lbrace, stopTokenIds: [Int32(Self.ordinaryQ)])
        #expect(namedElsewhere)
    }
}

#endif
