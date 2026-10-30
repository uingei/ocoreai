import MLXLMCommon
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThinkingBudgetPolicy — exact-value tests for how a finite `maxTokens` is split
/// between thinking and the answer, on every lane.
///
/// Why this needs a gate of its own: measured 10-30 on gemma-4-e2b-it-4bit at
/// `max_tokens: 256`, an unbounded thought spent the whole limit and the caller
/// received the thought as the answer with `finish_reason=length` (probe 44 §1).
/// The split is a policy decision, so the policy is pinned here at the exact
/// numbers; whether those numbers actually bite on the wire is probe 44's job.
///
/// The processor's own arithmetic (budget + transition + reserve must fit the
/// limit) is deliberately NOT recomputed here — `applyingThinkingBudget` installs
/// a parameter validator and these tests assert that validator's verdict.
import Testing

@testable import ocoreai

/// A tokenizer that knows only the protocol markers a budget plan compiles, so
/// the policy can be exercised without a checkpoint. Every boundary encodes to
/// exactly one token, which is the cheapest shape that satisfies
/// `ThinkingBudgetPlan` (`Libraries/MLXLMCommon/ThinkingBudget.swift:560`).
private struct MarkerTokenizer: Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [7] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { 7 }
    func convertIdToToken(_ id: Int) -> String? { "token" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw TokenizerError.missingChatTemplate
    }
}

private func parameters(maxTokens: Int?) -> GenerateParameters {
    var params = GenerateParameters()
    params.maxTokens = maxTokens
    return params
}

@Suite("ThinkingBudgetPolicy — the thinking/answer split (exact values)")
struct ThinkingBudgetPolicyTests {

    @Test("A declared transition is respected, not overridden")
    func declaredTransitionIsNotOverridden() {
        let declared = ThinkingBudgetPolicy.split(
            reasoning: QwenReasoningProtocol.qwen3, maxTokens: 256, thinkingEnabled: true)
        #expect(declared?.forcesImmediateTransition == false)
        // The same limit on a protocol that declares nothing opts into `.immediate`.
        let undeclared = ThinkingBudgetPolicy.split(
            reasoning: QwenReasoningProtocol.tagged, maxTokens: 256, thinkingEnabled: true)
        #expect(undeclared?.forcesImmediateTransition == true)
    }

    @Test("No budget for the three faces that would bound nothing")
    func noBudgetFaces() {
        let qwen = QwenReasoningProtocol.qwen3
        #expect(
            ThinkingBudgetPolicy.split(reasoning: qwen, maxTokens: nil, thinkingEnabled: true)
                == nil)
        #expect(
            ThinkingBudgetPolicy.split(reasoning: qwen, maxTokens: 256, thinkingEnabled: false)
                == nil)
        // An unspecified preference is the template's default, which may think — so the
        // ceiling covers the caller who never mentioned reasoning at all.
        #expect(
            ThinkingBudgetPolicy.split(reasoning: qwen, maxTokens: 256, thinkingEnabled: nil)
                == ThinkingBudgetPolicy.Split(
                    maximumTokenCount: 128, minimumAnswerTokenCount: 64,
                    forcesImmediateTransition: false))
    }

    @Test("Split values, and the split never asks for more than the limit")
    func splitValuesAndFloor() {
        let tagged = QwenReasoningProtocol.tagged
        #expect(
            ThinkingBudgetPolicy.split(reasoning: tagged, maxTokens: 256, thinkingEnabled: true)
                == ThinkingBudgetPolicy.Split(
                    maximumTokenCount: 128, minimumAnswerTokenCount: 64,
                    forcesImmediateTransition: true))
        #expect(
            ThinkingBudgetPolicy.split(reasoning: tagged, maxTokens: 1, thinkingEnabled: true)
                == ThinkingBudgetPolicy.Split(
                    maximumTokenCount: 0, minimumAnswerTokenCount: 0,
                    forcesImmediateTransition: true))
        for limit in [16, 64, 256, 1024, 2048, 8192, 32_768] {
            guard
                let split = ThinkingBudgetPolicy.split(
                    reasoning: tagged, maxTokens: limit, thinkingEnabled: true)
            else {
                Issue.record("limit \(limit) must produce a split")
                continue
            }
            #expect(split.maximumTokenCount == limit / 2, "half of \(limit)")
            #expect(split.minimumAnswerTokenCount == limit / 4, "quarter of \(limit)")
            // Corollary, not a restatement: a thinking cap plus the answer reserve can
            // never exceed what the caller asked for, at any limit.
            #expect(
                split.maximumTokenCount + split.minimumAnswerTokenCount <= limit,
                "limit \(limit)")
        }
    }

    @Test("A turn with something to bound gets the processor and a satisfiable limit")
    func componentsInstalled() throws {
        let params = parameters(maxTokens: 256)
        let components = ThinkingBudgetPolicy.components(
            reasoning: QwenReasoningProtocol.tagged,
            tokenizer: MarkerTokenizer(),
            parameters: params,
            thinkingEnabled: true,
            answerOnly: true
        )
        #expect(components.logitProcessorFactory != nil)
        guard let validator = components.parameterValidator else {
            Issue.record("a budgeted turn must carry upstream's limit validator")
            return
        }
        try validator(params)
    }

    @Test("A limit too small to fit the budget generates anyway, unbounded")
    func impossibleLimitDegrades() {
        let components = ThinkingBudgetPolicy.components(
            reasoning: QwenReasoningProtocol.tagged,
            tokenizer: MarkerTokenizer(),
            parameters: parameters(maxTokens: 8),
            thinkingEnabled: true,
            answerOnly: true
        )
        #expect(components.logitProcessorFactory == nil)
        #expect(components.parameterValidator == nil)
    }

    @Test("A turn that owes a tool call is never capped")
    func toolBearingTurnIsNeverCapped() {
        // Measured 10-30 on Qwen3.6-35B-A3B-4bit: one declared tool at `max_tokens: 64` answered
        // 200 at HEAD and 500 once this cap was installed on that lane — the thought closed at 32
        // tokens, the tool-call payload never completed, and each rejected-tool-call retry re-ran
        // under the same ceiling. Gate: probe 44 §2b.
        let components = ThinkingBudgetPolicy.components(
            reasoning: QwenReasoningProtocol.tagged,
            tokenizer: MarkerTokenizer(),
            parameters: parameters(maxTokens: 256),
            thinkingEnabled: true,
            answerOnly: false
        )
        #expect(components.logitProcessorFactory == nil)
        #expect(components.parameterValidator == nil)
    }

    @Test(
        "Nothing installed without a thought protocol, a limit, consent to think, or an answer-only turn"
    )
    func nothingInstalled() {
        let tokenizer = MarkerTokenizer()
        for reasoning in [nil, QwenReasoningProtocol.tagged] {
            for maxTokens in [nil, 256] {
                for thinking in [nil, true, false] {
                    for answerOnly in [false, true] {
                        let components = ThinkingBudgetPolicy.components(
                            reasoning: reasoning,
                            tokenizer: tokenizer,
                            parameters: parameters(maxTokens: maxTokens),
                            thinkingEnabled: thinking,
                            answerOnly: answerOnly
                        )
                        let shouldInstall =
                            reasoning != nil && maxTokens != nil && thinking != false && answerOnly
                        #expect(
                            (components.logitProcessorFactory != nil) == shouldInstall,
                            "reasoning=\(reasoning != nil) maxTokens=\(String(describing: maxTokens)) thinking=\(String(describing: thinking)) answerOnly=\(answerOnly)"
                        )
                    }
                }
            }
        }
    }
}
