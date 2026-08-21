// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// F2 — `ThinkTagParser` alignment: the merged parser must keep ocoreai's
// `primedInside` routing (upstream `coreai-models` has no equivalent) and add
// the #182 agentic `Format` path (upstream `684ae8e`
// `swift/Sources/CoreAILanguageModels/LanguageModel/ThinkTagParser.swift`),
// with the tagPair drain/hold-back behaviour identical on both sides.
//
// Assertion style follows upstream `ThinkTagParserTests.swift`: `Event` is
// deliberately not `Equatable` in both trees, so tests compare the compacted
// per-kind strings (`eventStrings`). Expectations are exact arrays / exact
// joined strings — no `isEmpty`/`contains` soft checks.

import Foundation
import Testing

@testable import ocoreai

private enum EventKind {
    case text
    case reasoning
}

/// Upstream `ThinkTagParserTests.eventStrings(_:_:)` — compact a parser event
/// list down to the payloads of one kind, preserving order.
private func eventStrings(_ events: [ThinkTagParser.Event], kind: EventKind) -> [String] {
    events.compactMap { event in
        if case .text(let s) = event, kind == .text { return s }
        if case .reasoning(let s) = event, kind == .reasoning { return s }
        return nil
    }
}

// MARK: - tagPair: ocoreai ahead (`primedInside`) + parity drain

@Suite("ThinkTagParser tagPair — ocoreai ahead parity")
struct ThinkTagParserTagPairTests {
    @Test("open/close tags routed across consume boundaries")
    func openCloseAcrossBoundaries() {
        var p = ThinkTagParser()  // default "<thinking>" / "</thinking>"
        var out: [ThinkTagParser.Event] = []
        out += p.consume("a")
        out += p.consume("<thinking")
        out += p.consume(">mid")
        out += p.consume("</thi")
        out += p.consume("nking>b")
        out += p.flush()
        #expect(eventStrings(out, kind: .text) == ["a", "b"])
        #expect(eventStrings(out, kind: .reasoning) == ["mid"])
    }

    @Test("balanced tag pair inside one delta: payload routed to reasoning")
    func balancedDelta() {
        var p = ThinkTagParser()
        var out: [ThinkTagParser.Event] = []
        out += p.consume("abc")
        out += p.consume("<thinking>hidden</thinking>")
        out += p.consume("def")
        out += p.flush()
        #expect(eventStrings(out, kind: .text) == ["abc", "def"])
        #expect(eventStrings(out, kind: .reasoning) == ["hidden"])
    }

    @Test("primedInside: first chunk is reasoning until close tag")
    func primedInsideRoutesFirstChunkToReasoning() {
        var p = ThinkTagParser(primedInside: true)
        let out =
            p.consume("prefill text ") + p.consume("</thinking>") + p.consume("visible") + p.flush()
        #expect(eventStrings(out, kind: .reasoning) == ["prefill text "])
        #expect(eventStrings(out, kind: .text) == ["visible"])
    }

    @Test("open tag with no close at EOS: remainder is reasoning")
    func unclosedOpenTagIsReasoning() {
        var p = ThinkTagParser()
        let out = p.consume("before<thinking>tail") + p.flush()
        #expect(eventStrings(out, kind: .text) == ["before"])
        #expect(eventStrings(out, kind: .reasoning) == ["tail"])
    }

    @Test("promptEndsInsideReasoning: unbalanced tail is inside")
    func promptEndsInsideUnbalanced() {
        #expect(
            ThinkTagParser.promptEndsInsideReasoning(
                renderedPromptTail: "user: hi\nassistant: <thinking>",
                openMarker: "<thinking>",
                closeMarker: "</thinking>"
            ) == true)
        #expect(
            ThinkTagParser.promptEndsInsideReasoning(
                renderedPromptTail: "user: hi\nassistant: <thinking>done</thinking>",
                openMarker: "<thinking>",
                closeMarker: "</thinking>"
            ) == false)
        #expect(
            ThinkTagParser.promptEndsInsideReasoning(
                renderedPromptTail: "   ",
                openMarker: "<thinking>",
                closeMarker: "</thinking>"
            ) == false)
    }
}

// MARK: - agentic (upstream #182): Format routing

@Suite("ThinkTagParser agentic — upstream #182 path")
struct ThinkTagParserAgenticTests {
    private let selfMarker = "to-self"
    private let userMarker = "to-user"
    private let eom = "end-message"
    private let eot = "end-turn"

    private func make() -> ThinkTagParser {
        ThinkTagParser(
            format: .agentic(
                selfMarker: selfMarker,
                userMarker: userMarker,
                endOfMessage: eom,
                endOfTurn: eot
            )
        )
    }

    @Test("content before first end-marker routes to reasoning")
    func firstSegmentIsReasoning() {
        var p = make()
        let out = p.consume("thinking about it") + p.flush()
        #expect(eventStrings(out, kind: .reasoning).joined() == "thinking about it")
        #expect(eventStrings(out, kind: .text) == [])
    }

    @Test("endOfMessage terminates the reasoning segment; after routes to text")
    func eomTerminatesReasoningSegment() {
        var p = make()
        let out = p.consume("reasoning chunk" + eom + "after") + p.flush()
        #expect(eventStrings(out, kind: .reasoning) == ["reasoning chunk"])
        #expect(eventStrings(out, kind: .text) == ["after"])
    }

    @Test("userMarker: payload before marker is reasoning, rest buffered")
    func userMarkerTransitions() {
        var p = make()
        let out = p.consume("reasoning content" + userMarker + "visible<") + p.flush()
        #expect(eventStrings(out, kind: .reasoning) == ["reasoning content"])
        #expect(eventStrings(out, kind: .text).joined() == "visible<")
    }

    @Test("full round trip: reasoning → user → reasoning")
    func multiTurnRoundTrip() {
        var p = make()
        let out = p.consume("think" + eom + userMarker + "hello") + p.flush()
        #expect(eventStrings(out, kind: .reasoning) == ["think"])
        #expect(eventStrings(out, kind: .text).joined() == "hello")
    }
}
