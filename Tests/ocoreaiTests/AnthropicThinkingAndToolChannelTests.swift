// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AnthropicThinkingAndToolChannelTests.swift — `thinking` must reach the engine, and the
/// agent context must not depend on which wire the client speaks.
///
/// Measured live 10-19 (`mlx-community/gemma-4-e2b-it-4bit`, temperature 0, this host):
///   • `thinking:{"type":"enabled","budget_tokens":400}` on `/v1/messages` → 38 output
///     tokens and no thinking block; the same model and prompt on `/v1/chat/completions`
///     with `{"reasoning":true}` → 335 tokens. The field that opens the reasoning channel
///     (`InferenceOptions.enableReasoning`) had no assignment on this face at all, and
///     `type:"disabled"` mapped to `true`, so asking for thinking OFF asked for it ON.
///   • The identical one-turn request cost 24 `input_tokens` here against 774
///     `prompt_tokens` on the OpenAI face, and "List the skills you have available"
///     answered "terminal / file / search / memory" there but "Processing and understanding
///     natural language…" here — the face that skipped the shared assembly answered as a
///     different product, which is invariant 2, not a token-accounting detail.
///   • `POST /v1/steer` then `/v1/messages` on that session answered "Please provide more
///     context" (the steer was never drained), while the same sequence on
///     `/v1/chat/completions` delivered it. The route's own doc names `/v1/messages`.
///
/// Everything here is offline: preference mapping, wire shape, emitter ordering, and
/// source-scan guards that assert their own premises.

import Foundation
import Testing

@testable import ocoreai

private struct MissingSource: Error, CustomStringConvertible {
    let path: String
    var description: String { "could not find \(path) walking up from the test file" }
}

/// Reads a repo source file by locating the root from this file's path — never a fixed
/// number of `deletingLastPathComponent()` hops, which is how a "passing" scan turns out
/// to have been reading nothing (`V1EndpointCatalogTests` carries that failure).
private func source(_ relative: String) throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 6 {
        let candidate = dir.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    throw MissingSource(path: "\(dir.path)/\(relative)")
}

private let handlerSource = "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift"
private let modelsSource = "Sources/ocoreai/Models/AnthropicModels.swift"
private let routerSource = "Sources/ocoreai/Router/ChatCompletionsRouter.swift"

private func wireJSON<T: Encodable>(_ value: T) -> [String: Any] {
    let data = try! JSONEncoder().encode(value)
    return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private func request(_ json: String) throws -> AnthropicMessageRequest {
    try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
}

/// A minimal valid `/v1/messages` body, with extra top-level fields merged in. Built by
/// serializing rather than splicing strings: hand-built JSON is where a missing comma turns
/// into a test that decodes nothing and asserts nothing.
private func body(_ extra: [String: Any] = [:]) -> String {
    var fields: [String: Any] = [
        "model": "m",
        "max_tokens": 512,
        "messages": [["role": "user", "content": "7 * 8?"]],
    ]
    for (key, value) in extra { fields[key] = value }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return String(decoding: data, as: UTF8.self)
}

/// `thinking:{"type":"enabled","budget_tokens":…}` as a body fragment. A function, not a
/// global `let`: `[String: Any]` is not `Sendable`, and strict concurrency is right that a
/// shared dictionary literal is shared mutable state.
private func enabledThinking(_ budget: Int = 400) -> [String: Any] {
    ["type": "enabled", "budget_tokens": budget]
}

@Suite("Anthropic thinking — the preference reaches the engine")
struct AnthropicThinkingPreferenceTests {

    /// `thinking.type` is the field that decides. Three states, because Anthropic
    /// distinguishes "off" from "not stated", and mlx-swift-lm models it as
    /// `thinkingEnabled: Bool?`.
    @Test(
        "thinking.type resolves to the three-state reasoning preference",
        arguments: [
            (#"{"type":"enabled","budget_tokens":400}"#, true),
            (#"{"type":"disabled"}"#, false),
            // An unrecognised type is never a guess that the client wanted thinking.
            (#"{"type":"adaptive"}"#, nil),
        ] as [(String, Bool?)]
    )
    func typeDecides(thinkingJSON: String, expected: Bool?) throws {
        let decoded = try JSONDecoder().decode(
            AnthropicThinkingConfig.self, from: Data(thinkingJSON.utf8))
        #expect(
            decoded.reasoningEnabled == expected,
            "\(thinkingJSON) → \(String(describing: expected))")
        // The dict, not the struct: the body has to be what a client would put on the wire
        // (`NSJSONSerialization` traps on an arbitrary Swift value, and a trap in a helper
        // takes the whole run down with it).
        let onTheWire = try JSONSerialization.jsonObject(with: Data(thinkingJSON.utf8))
        let req = try request(body(["thinking": onTheWire]))
        #expect(try toChatCompletionRequest(req).reasoning == expected)
    }

    /// Absent `thinking` is not "off": the model template's own default stays in force.
    @Test("absent thinking states no preference")
    func absentIsNil() throws {
        #expect(try request(body()).thinking == nil)
        #expect(try toChatCompletionRequest(request(body())).reasoning == nil)
    }

    /// Before this fix the check was `thinking != nil`, so the request to turn thinking
    /// OFF turned it ON — the one mapping that had to be exactly backwards to matter.
    @Test("disabled means off, not on")
    func disabledIsNotEnabled() throws {
        let req = try request(body(["thinking": ["type": "disabled"]]))
        #expect(req.thinking?.reasoningEnabled == false)
        #expect(try toChatCompletionRequest(req).reasoning == false)
    }

    /// `budget_tokens` is the thinking *half* of the output, so it cannot also be the
    /// ceiling on the whole answer. `min(max_tokens, budget)` used to sit here, which
    /// left the answer no room on exactly the requests that asked to think.
    @Test("budget_tokens does not cap max_tokens")
    func budgetDoesNotCapOutput() throws {
        let req = try request(body(["thinking": enabledThinking()]))
        let internalRequest = try toChatCompletionRequest(req)
        let maxTokens = internalRequest.maxTokens ?? -1
        #expect(maxTokens == 512, "the caller's ceiling stands, and got \(maxTokens)")
        #expect(internalRequest.reasoning == true)
    }

    /// Anthropic's pairing rule, enforced: the budget must leave room for the answer.
    /// Refusing is the alternative to accepting a request whose numbers cannot both hold.
    @Test("a budget that eats the ceiling is refused by name")
    func budgetMustBeBelowMaxTokens() throws {
        let req = try request(body(["thinking": ["type": "enabled", "budget_tokens": 512]]))
        let error = req.numericDomainError()
        guard case .some(.invalidParameter(let param, let message, _)) = error else {
            Issue.record("budget_tokens == max_tokens must be refused")
            return
        }
        #expect(param == "thinking.budget_tokens")
        #expect(message.contains("max_tokens"), "the message must name both sides: \(message)")
    }

    /// A disabled config keeps its stale budget without tripping the rule — the pair is
    /// only a live constraint when thinking is on.
    @Test("a disabled config is not constrained by a stale budget")
    func disabledIgnoresBudgetRule() throws {
        let req = try request(body(["thinking": ["type": "disabled", "budget_tokens": 600]]))
        #expect(req.numericDomainError() == nil)
    }
}

@Suite("Anthropic thinking — wire shape")
struct AnthropicThinkingWireShapeTests {

    @Test("a thinking block encodes as type/thinking/signature and nothing else")
    func thinkingBlockEncodes() {
        let json = wireJSON(
            AnthropicAssistantContent(thinking: "step by step", signature: "sig-abc"))
        #expect(json["type"] as? String == "thinking")
        #expect(json["thinking"] as? String == "step by step")
        #expect(json["signature"] as? String == "sig-abc")
        #expect(json.keys.contains("text") == false, "reasoning never sits in a text block")
        #expect(json.keys.contains("input") == false)
    }

    /// `content_block_start` opens a thinking block empty, with no signature — that field
    /// arrives in its own delta, and inventing one at open time would put an unverifiable
    /// value where a client expects a verification token.
    @Test("the thinking block opens without a signature")
    func thinkingBlockStartOmitsSignature() {
        let json = wireJSON(AnthropicStreamEvent.thinkingBlockStart(index: 0))
        #expect(json["type"] as? String == "content_block_start")
        let block = json["content_block"] as? [String: Any]
        #expect(block?["type"] as? String == "thinking")
        #expect(block?["thinking"] as? String == "")
        #expect(block?.keys.contains("signature") == false)
    }

    /// `delta.type` is the discriminator SDKs dispatch on, so each member carries only its
    /// own payload key — the same rule that made `text_delta` a fix (round 19).
    @Test("thinking and signature deltas carry only their own payload")
    func thinkingDeltasAreDiscriminated() {
        let thinking = wireJSON(AnthropicStreamEvent.thinkingDelta(index: 0, thinking: "hm"))
        let thinkingDelta = thinking["delta"] as? [String: Any]
        #expect(thinkingDelta?["type"] as? String == "thinking_delta")
        #expect(thinkingDelta?["thinking"] as? String == "hm")
        #expect(thinkingDelta?.keys.contains("text") == false)
        #expect(thinkingDelta?.keys.contains("signature") == false)

        let signed = wireJSON(
            AnthropicStreamEvent.signatureDelta(index: 0, signature: "sig-1"))
        let signatureDelta = signed["delta"] as? [String: Any]
        #expect(signatureDelta?["type"] as? String == "signature_delta")
        #expect(signatureDelta?["signature"] as? String == "sig-1")
        #expect(signatureDelta?.keys.contains("thinking") == false)
    }

    /// The opaque id is a block id, not a credential. Its shape is pinned so the
    /// documentation in `AnthropicAssistantContent.signature` cannot drift from the wire.
    @Test("the signature is an opaque id with a stable prefix")
    func signatureShape() {
        let first = anthropicThinkingSignature()
        #expect(first.hasPrefix("sig-"), "opaque id shape: \(first)")
        #expect(first.count > 4)
        #expect(first != anthropicThinkingSignature(), "ids differ per block")
    }
}

@Suite("Anthropic SSE — thinking precedes the answer, in its own blocks")
struct AnthropicThinkingStreamOrderingTests {

    /// One line per event: `event|index|deltaType|blockType`. A string list compares exactly,
    /// and a failure prints the whole ordering rather than the first mismatch only.
    private func lines(_ events: [AnthropicStreamEvent]) -> [String] {
        events.map { event in
            let json = wireJSON(event)
            let delta = (json["delta"] as? [String: Any])?["type"] as? String ?? "-"
            let block = (json["content_block"] as? [String: Any])?["type"] as? String ?? "-"
            let type = json["type"] as? String ?? "-"
            let index = json["index"] as? Int ?? -1
            return "\(type)|\(index)|\(delta)|\(block)"
        }
    }

    /// Anthropic's order for a turn that thinks, then answers: thinking block (0), text
    /// block (1). The signature closes the thinking block inside it, before its stop.
    @Test("thinking then text: two blocks, signature before the thinking block closes")
    func thinkingThenTextOrdering() {
        var emitter = AnthropicStreamEmitter()
        var events = emitter.feedReasoning("Let me ")
        events += emitter.feedReasoning("think. ")
        events += emitter.feedText("56.")
        events += emitter.close()

        #expect(
            lines(events) == [
                "content_block_start|0|-|thinking",
                "content_block_delta|0|thinking_delta|-",
                "content_block_delta|0|thinking_delta|-",
                "content_block_delta|0|signature_delta|-",
                "content_block_stop|0|-|-",
                "content_block_start|1|-|text",
                "content_block_delta|1|text_delta|-",
                "content_block_stop|1|-|-",
            ],
            "unexpected stream shape: \(lines(events))")
    }

    /// Reasoning never lands in the answer's block, and the answer never lands in the
    /// reasoning block — the separation is the point of the block types.
    @Test("reasoning and answer never share a block")
    func channelsNeverMix() {
        var emitter = AnthropicStreamEmitter()
        var events = emitter.feedReasoning("why ")
        events += emitter.feedReasoning("and how")
        events += emitter.flushText()
        events += emitter.feedText("56")
        events += emitter.close()
        for event in events {
            let json = wireJSON(event)
            guard let delta = json["delta"] as? [String: Any] else { continue }
            let kind = delta["type"] as? String ?? ""
            switch kind {
            case "thinking_delta":
                #expect(delta.keys.contains("text") == false, "reasoning must not carry text")
            case "text_delta":
                #expect(delta.keys.contains("thinking") == false, "the answer is not reasoning")
            default:
                break
            }
        }
    }

    /// A call after thinking: thinking closes with its signature, the call takes the next
    /// index — block numbering stays addressable across all three block kinds.
    @Test("thinking then a call numbers the blocks 0 and 1")
    func thinkingThenToolCallNumbering() {
        var emitter = AnthropicStreamEmitter()
        _ = emitter.feedReasoning("I should call the tool")
        let events = emitter.emitToolCall(
            id: "toolu_1", name: "get_weather", arguments: "{\"city\":\"Paris\"}")
        #expect(
            lines(events) == [
                "content_block_delta|0|signature_delta|-",
                "content_block_stop|0|-|-",
                "content_block_start|1|-|tool_use",
                "content_block_delta|1|input_json_delta|-",
            ],
            "unexpected stream shape: \(lines(events))")
    }

    /// A turn that only thought still closes its block and needs no empty text block after.
    @Test("a thinking-only turn closes its block and invents no empty one")
    func thinkingOnlyTurn() {
        var emitter = AnthropicStreamEmitter()
        let opened = emitter.feedReasoning("pondering")
        let closed = emitter.close()
        #expect(emitter.hasEmittedAnyBlock)
        #expect(
            lines(opened + closed) == [
                "content_block_start|0|-|thinking",
                "content_block_delta|0|thinking_delta|-",
                "content_block_delta|0|signature_delta|-",
                "content_block_stop|0|-|-",
            ],
            "unexpected stream shape: \(lines(opened + closed))")
        #expect(emitter.ensureSomeBlock().isEmpty, "a block was already emitted")
    }

    /// Reasoning arriving after text is unusual but not illegal; it gets its own block at
    /// the next index rather than being appended to the answer.
    @Test("late reasoning takes its own block rather than joining the answer")
    func lateReasoningOwnBlock() {
        var emitter = AnthropicStreamEmitter()
        _ = emitter.feedText("The answer is 56.")
        let events = emitter.feedReasoning("because 7 times 8")
        #expect(
            lines(events) == [
                "content_block_stop|0|-|-",
                "content_block_start|1|-|thinking",
                "content_block_delta|1|thinking_delta|-",
            ],
            "unexpected stream shape: \(lines(events))")
    }
}

@Suite("Anthropic face — one assembly, both wires")
struct AnthropicSharedAssemblySourceTests {

    /// Premises of the scans below: the files exist and contain the symbols the guards
    /// rely on. A moved file or renamed symbol must fail here, not quietly switch these
    /// assertions off.
    @Test(
        "the scans read the real files",
        arguments: [
            "private func nonStreamAnthropicResponse(",
            "private func streamAnthropicResponse(",
            "func buildAnthropicMessageList(",
            "func anthropicConversationMessages(",
        ]
    )
    func scanPremises(marker: String) throws {
        #expect(
            try source(handlerSource).contains(marker),
            "handler scan found no \(marker) — file or symbol moved")
    }

    /// The face assembles its messages through the shared builder, so the agent context
    /// (skills catalogue, workspace section, recalled memory, reasoning scaffold) is the
    /// same on both wires. `systemPromptBuilder` was an injected-but-unread parameter
    /// here, which is how a face can look wired and be disconnected.
    @Test(
        "the handler routes through the shared message assembly",
        arguments: [
            "messageBuilder.buildMessages(",
            "MessageBuilderContext(",
            "messageBuilder: MessageBuilder,",
        ]
    )
    func sharedAssemblyWiring(marker: String) throws {
        #expect(try source(handlerSource).contains(marker), "handler missing \(marker)")
    }

    @Test("no parameter is injected and ignored on this face")
    func noDeadInjection() throws {
        let s = try source(handlerSource)
        #expect(
            s.contains("systemPromptBuilder _: SystemPromptBuilder") == false,
            "an unread builder parameter is how a disconnected seam survives review")
    }

    /// `/v1/steer` documents that a steer survives into the NEXT request for the session,
    /// and names `/v1/messages` among the routes that carry it. A promise needs a delivery
    /// line, and this face had none.
    @Test(
        "steering has a delivery site on the Anthropic face",
        arguments: [
            "SteerQueue.shared.drain(sessionKey:",
            "mergingSteeredTurn(",
            "SteerQueue.shared.enqueue(sessionKey:",
        ]
    )
    func steerDeliverySites(marker: String) throws {
        #expect(try source(handlerSource).contains(marker), "handler missing \(marker)")
    }

    /// Both reasoning-consuming modes bind the text: `case .reasoning:` with no binding is
    /// the shape of "accepted the capability, dropped the output".
    @Test("both modes consume reasoning text")
    func bothModesConsumeReasoning() throws {
        let s = try source(handlerSource)
        #expect(
            s.components(separatedBy: "case .reasoning(let r):").count - 1 == 2,
            "both stream and non-stream must bind and deliver reasoning")
        #expect(
            s.components(separatedBy: "case .reasoning:").count - 1 == 0,
            "an unbound .reasoning case drops the text it names")
        #expect(
            s.contains("enableReasoning: chatRequest.reasoning"),
            "the preference must reach InferenceOptions")
    }

    /// One builder, both entrances: `/v1/messages` calls it from the handler, and
    /// `count_tokens` from the route. Two lists would let the pre-flight budget a request
    /// that then costs more — the reason this endpoint exists.
    @Test("the two Anthropic routes count one list")
    func oneBuilderTwoRoutes() throws {
        #expect(
            try source(handlerSource).components(separatedBy: "buildAnthropicMessageList(").count
                - 1 == 2,
            "the handler must define the builder and call it once")
        #expect(
            try source(routerSource).components(separatedBy: "await buildAnthropicMessageList(")
                .count - 1 == 1,
            "count_tokens must count the same builder's list")
    }

    /// Both faces disclose what they assembled, from one helper. The parity claim of this
    /// round ("one assembly, both wires") was settled by reading those lines — before the
    /// helper existed, a divergence between the faces was only visible as an unexplained
    /// token delta in a probe. One home, two callers; a face that stops reporting is red.
    @Test("both faces disclose the prompt they assembled")
    func bothFacesDiscloseAssembly() throws {
        #expect(
            try source("Sources/ocoreai/Handlers/ChatHandler.swift")
                .contains("logAssembledPrompt("),
            "the OpenAI face must report what it assembled")
        #expect(
            try source(handlerSource).contains("logAssembledPrompt("),
            "the Anthropic face must report what it assembled")
        #expect(
            try source("Sources/ocoreai/Handlers/MessageBuilder.swift")
                .contains("func logAssembledPrompt("),
            "the disclosure lives in one home next to the assembly it describes")
    }

    /// `usage` on this face reports the engine's measured prompt count, not a second
    /// number for the same prompt. Textual because the value needs an engine: the live
    /// pair is probe 13 §9.
    @Test("usage prefers the engine's measured prompt count")
    func usageReportsMeasurement() throws {
        let s = try source(handlerSource)
        #expect(
            s.components(separatedBy: "observedPromptTokens ?? inputTokenCount").count - 1 == 2,
            "both response modes must report the measured prompt count when the engine has one"
        )
    }

    /// The engine side of the tool channel this face now feeds (quoted so a rename of the
    /// engine mapping is a red test, not a silently wrong comment in three files).
    @Test("the engine maps the shapes this face now produces")
    func engineConsumesTheChannel() throws {
        let s = try source("Sources/ocoreai/Engine/EngineInference.swift")
        #expect(s.contains("case \"tool\": .tool"), "the template path needs the tool role")
        #expect(
            s.contains("Chat.Message.tool(contentStr, id: tid)"),
            "results pair with calls by id on the engine side")
        #expect(
            s.contains("Chat.Message.assistant(\"\", toolCalls: mlxTCs)"),
            "calls reach the template as structured calls")
    }
}
