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

// MARK: - agentic (upstream #182 protocol markers; #206 streaming hardening merged 2026-09-04)

/// Upstream `AgenticThinkTagParserTests` 用的真 marker 协议（Muse Glimmer / ATEM
/// 风格）：`to=self<|message|>` / `to=user<|message|>` + eom/eot boundary tokens。
/// 旧占位假 marker（`to-self`/`to-user`）不保 — 没有任何 ocoreai 生产消费者
/// 走该路径（Engine / MLXBridge / CoreAI* 全走 tagPair + `primedInside`）。
/// 真正的 agentic 断言面 → `AgenticThinkTagParserVendoredTests.swift`（#206）。
@Suite("ThinkTagParser agentic — marker protocol parity guard")
struct ThinkTagParserAgenticProtocolTests {
    private let selfMarker = "to=self<|message|>"
    private let userMarker = "to=user<|message|>"
    private let eom = "<|eom|>"
    private let eot = "<|eot|>"

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

    @Test("first-turn agentic: leading-space self→user boundary, protocol not leaked")
    func firstTurnReasoningThenUser() {
        var p = make()
        let stream = " to=self<|message|>thinking...<|eom|><|start|>assistant to=user<|message|>hi"
        let out = p.consume(stream) + p.flush()
        #expect(eventStrings(out, kind: .reasoning).joined().contains("thinking..."))
        #expect(eventStrings(out, kind: .text).joined() == "hi")
        #expect(eventStrings(out, kind: .text).joined().doesNotContainProtocol)
    }

    @Test("reasoning boundary eom emits reasoning, then user segment emits text")
    func eomBoundaryTransition() {
        var p = make()
        let stream = " to=self<|message|>think<|eom|>user text"
        let out = p.consume(stream) + p.flush()
        #expect(eventStrings(out, kind: .reasoning).joined() == "think")
        #expect(eventStrings(out, kind: .text).joined() == "user text")
    }
}

/// Protocol-leak guard: no agentic token may appear in user-facing text
/// (`to=`/`<|message|>`/`<|start|>`/`<|eom|>`/`<|eot|>`).
extension String {
    fileprivate var doesNotContainProtocol: Bool {
        !contains("to=self") && !contains("to=user") && !contains("<|message|>")
            && !contains("<|start|>") && !contains("<|eom|>") && !contains("<|eot|>")
    }
}
