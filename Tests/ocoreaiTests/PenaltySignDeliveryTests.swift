// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Gate: the three penalty knobs keep their sign on the way to the engine.
///
/// Located 10-18 by reading what our build actually consumes: at mlx-swift-lm
/// `48114ee` (the pin) the processor applies each penalty whenever it is merely
/// non-zero — Libraries/MLXLMCommon/Evaluate.swift:345 (repetition), :355 (presence),
/// :365 (frequency) — and *subtracts* it from the selected logits
/// (Libraries/MLXLMCommon/Evaluate.swift:614). So `presence_penalty: -1.5` is a
/// meaningful, spec-legal OpenAI value in [-2, 2]: it rewards tokens that are already
/// present instead of punishing them.
///
/// Our mapping gated all three on `> 0` (MLXBridge, pre-10-18), which accepted such a
/// request, ran a full generation, and answered as if the client had sent nothing —
/// the surface claiming a behaviour it did not deliver (AGENTS.md invariant 2). The
/// handlers already cascaded with `!= 0` (ChatHandler:568 / CompletionsHandler:166), so
/// the sign survived everywhere except the last hop, which is exactly where a sign
/// should not be able to die.
///
/// Surviving companion: live probe `scripts/probes/10-sampling-knob-delivery.sh`, which
/// measures that a negative and a positive penalty produce visibly different generations.

import Foundation
import Testing

@testable import ocoreai

@Suite("upstreamPenalty — sign kept, zero means not set")
struct UpstreamPenaltyMappingTests {

    @Test("zero and absent both mean not-set", arguments: [0.0, -0.0])
    func zeroIsNotSet(_ value: Double) {
        #expect(upstreamPenalty(nil) == nil)
        #expect(
            upstreamPenalty(value) == nil, "0 must stay unset, as upstream (Evaluate.swift:355)")
    }

    /// The regression itself: before 10-18 this returned nil, and the client's request
    /// silently meant "no penalty".
    @Test("negative penalties survive the mapping", arguments: [-0.1, -1.5, -2.0])
    func negativeSurvives(_ value: Double) {
        #expect(upstreamPenalty(value) == Float(value), "\(value) must reach the engine intact")
    }

    @Test("positive penalties are unchanged", arguments: [0.5, 1.0, 2.0])
    func positiveUnchanged(_ value: Double) {
        #expect(upstreamPenalty(value) == Float(value))
    }

    /// Upstream engages a penalty only when its context window is positive, so a mapping
    /// that keeps the sign still delivers nothing if our own default window were 0.
    /// This asserts the premise the mapping depends on, not just the mapping.
    @Test("premise: the default context windows are the ones upstream engages on")
    func contextWindowsArePositive() {
        let config = SamplingConfiguration(
            repetitionPenalty: -1.5, presencePenalty: -1.5, frequencyPenalty: -1.5)
        #expect(config.presenceContextSize > 0, "presence penalty would be inert upstream")
        #expect(config.frequencyContextSize > 0, "frequency penalty would be inert upstream")
        #expect(config.repetitionContextSize > 0, "repetition penalty would be inert upstream")
    }
}

@Suite("Negative penalties are legal on both wires and keep their sign through decode")
struct PenaltyWireSignTests {

    private static func chat(_ fields: String) -> ChatCompletionRequest {
        let json =
            "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]"
            + fields + "}"
        return try! JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
    }

    @Test("the numeric-domain gate lets the whole [-2, 2] span through, sign included")
    func gateLetsNegativesThrough() {
        let legal = Self.chat(",\"presence_penalty\":-1.5,\"frequency_penalty\":-2.0")
        #expect(legal.presencePenalty == -1.5)
        #expect(legal.frequencyPenalty == -2.0)
        let violation = legal.numericDomainError()
        #expect(
            violation == nil,
            "a legal negative must not be refused: \(String(describing: violation))")

        // …and still refuses what is genuinely out of range, on either side.
        #expect(Self.chat(",\"presence_penalty\":-2.1").numericDomainError() != nil)
        #expect(Self.chat(",\"presence_penalty\":2.1").numericDomainError() != nil)
    }

    /// `Float` defaults to 0 (not Optional) on this DTO, so "absent" and "explicitly 0"
    /// arrive as the same value and the cascade in ChatHandler falls back to the runtime
    /// default. What must not happen is a negative being normalised away at decode.
    @Test("repetition_penalty keeps a negative for the engine, while the gate names it")
    func repetitionPenaltySignAndGate() {
        let decoded = Self.chat(",\"repetition_penalty\":-1.2")
        #expect(decoded.repetitionPenalty == -1.2, "decode must preserve the sign")
        let error = decoded.numericDomainError()
        guard case .some(.invalidParameter(let param, let message, _)) = error else {
            Issue.record(
                "repetition_penalty <= 0 must be refused (multiplicative knob), got \(String(describing: error))"
            )
            return
        }
        #expect(param == "repetition_penalty")
        #expect(message.contains("greater than zero"), "must say why: \(message)")
    }
}
