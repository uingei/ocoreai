// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DecisionsHandler.swift — `POST /v1/decisions`, the Jev / System 1 decision surface.
///
/// ### What a decision answer is, so the refusal below is checkable
/// sglang routes this API with the words *"scoring single-token answer labels through the scoring
/// API, without generation"* (`~/references/sglang/python/sglang/srt/entrypoints/http_server.py:2050`),
/// so an answer is not generated text to parse: it is the probability of each offered label read at
/// the answer position, then normalized. That is the same primitive as A2 loglikelihood — score a
/// prompt against a forced continuation — which this repo already ports copy-first from
/// coreai-models (`Engine/EngineLogprobs.swift:5-19`, from upstream
/// `swift/Sources/Tools/llm-server/CompletionHandler.swift` at b11ac19), and which upstream has
/// since reshaped into a reusable entry point `runLoglikelihood` with the unsupported refusal in
/// one constant (coreai-models 1c25c57 / #382, read 11-02).
///
/// ### Why every valid request is refused here today
/// That port is CoreAI-gated (`Engine/EngineLogprobs.swift:22` — `#if canImport(CoreAI)`,
/// `@available(macOS 27.0, *)`), and the MLX path computes logits without publishing them
/// (`Engine/EngineInference.swift:914,997` take `includeLogits: true` in-tree for constrained
/// decoding only). So on the delivery platform there is no place to read a label probability from —
/// which is exactly why `POST /v1/completions` with `logprobs` answers 501 there
/// (`Handlers/CompletionsHandler.swift:102`). The route therefore validates for real and refuses
/// scoring, naming the missing prerequisite and both exits. Inventing a number is the one answer
/// this API must never give (`docs/agent/systemone-decisions.md` § the cheapest honest slice,
/// item 5), so no path here can produce a probability without a read.
///
/// ### Why the contract is enforced before the refusal
/// sglang validates the body before the server touches a model (`http_server.py:2048-2052`), and
/// that order is what makes this route useful today: a client integrating against the API learns
/// its request is malformed (400, every reason at once) even on a build that cannot score, and
/// learns what is missing (501) only once the body is right.

import Hummingbird

enum DecisionsHandler {

    /// Answer labels a validated request would need scored, so the refusal can say what went
    /// unmeasured instead of reporting a bare 501. The count is the question's own (`labelCount`), so
    /// this cannot drift from what a scorer would later read.
    static func labelCount(for request: DecisionsRequest) -> Int {
        request.questions.reduce(0) { $0 + $1.labelCount }
    }

    /// The one answer this build gives a request that passed the contract.
    static func handle(_ request: DecisionsRequest) throws -> Response {
        throw AppError.decisionsUnavailable(
            "an answer is the probability of each offered label at the answer position "
                + "(\(request.questions.count) question(s), \(labelCount(for: request)) label(s) "
                + "asked here), and this build publishes no logits to read them from: the ported "
                + "scoring path is CoreAI-gated (macOS 27) and the MLX engine keeps its logits "
                + "in-tree. Exits: serve this request from the CoreAI engine, where logprobs are "
                + "published; or ask for text and score the labels client-side. This route returns "
                + "no probability rather than an invented one."
        )
    }
}
