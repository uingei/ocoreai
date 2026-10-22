// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DegenerateMarginProbe.swift — measure *why* a collapsed turn answers EOS.
///
/// ### The question this exists to answer
/// `DegenerateTurn` detects the shape (1 token + `.eos` under a budget that asked for more) but
/// cannot say what the model was choosing between. Two survivors remain after seven
/// single-variable experiments and two dead mechanism stories (`scripts/probes/30-repeated-prompt
/// -delivery.sh` carries that record):
///   • a near-tie at slot 2 between EOS and the next candidate, resolved by numerics that are
///     fixed per process — expected margin of order 1e-2…1e-1;
///   • the delivered input differs from what the accounting claims — expected margin ≥ 5.
/// Those two are separated by **one number**: the log-probability margin between the chosen EOS
/// and the best non-EOS candidate at the step where the collapse happened.
///
/// ### Why it cannot ride the chat face
/// `ChatSession` contains zero references to `logProbabilities` or `LogProbabilityTokenLoopHandler`
/// (verified against the built checkout at the pinned revision), and `.probability` events exist
/// only on `LogProbabilityTokenLoopHandler` (`LogProbabilityTokenLoopHandler.swift:9`). Assigning
/// `chatSession.generateParameters.logProbabilities` would therefore be a silent no-op — exactly
/// the class AGENTS.md forbids (a knob that is accepted but never reaches the engine; a
/// substitution must be detectable at runtime). So this probe re-enters upstream's own
/// observability seam instead: `TokenIterator` + `generateLoopTask` wrapped in
/// `LogProbabilityTokenLoopHandler`, per `Documentation.docc/generation-observability.md`.
///
/// ### Fidelity, and how a wrong reconstruction announces itself
/// The prompt is assembled the way `ChatSession` assembles it — `UserInput(chat:)` through
/// `ModelContainer.prepare(input:)`, with instructions on the leading `.system` message — and the
/// probe reports `fidelity` by comparing *its own* `promptTokenCount` against the number the
/// failed turn recorded. A reconstruction that silently dropped the injected instructions would
/// report `fidelity=UNVERIFIED`, and its margins must then be read as nothing.
///
/// ### Cost and default
/// One extra short generation, gated by the caller: by default it fires only on a turn already
/// judged degenerate (`OCOREAI_MARGIN_PROBE=1`), so healthy turns pay nothing.
/// `OCOREAI_MARGIN_PROBE=all` widens that gate to every turn on the standard path, which is the
/// only way to read a margin *against* an outcome — collapse-only mode has no healthy comparison
/// in the same build, so it can never test "small margin ⇒ collapse".
///
/// ### What arm E measured (10-23, 12 cold boots, one content, greedy, `all` mode)
/// Identical prompt bytes landed in **four discrete step-1 logprob regimes**, and the outcome
/// tracked the regime with zero overlap: collapsed turns sat at lp −0.0111 / −0.0094 (margin
/// 5.5677 / 5.8204), healthy turns at −0.0278 / −0.0222 (margin 4.4361 / 4.6290). So the
/// collapse is preceded by *more* certainty at the first sampled token, not by a near-tie — and
/// a margin width cannot be the mechanism, since the collapsed margins are the wider ones.
/// Collapsed turns also record no step 2 at all: generation ends at the first sampled token, so
/// whatever terminates the turn sits between the first token and the next forward pass.
/// Retracted by this run: a previously recorded "0.0466 nats at slot 2" does not appear in any
/// of these reconstructions (step-2 margin here is 0.2172–0.8533), so it was a one-off reading
/// of one reconstruction and must not be quoted as the margin at the collapse. Reconstruction
/// still ≠ live turn — it re-prepares without the session's KV — which is why the regime, not
/// any single margin, is the number worth chasing.

import Foundation
import Logging
import MLX
import MLXLMCommon

enum DegenerateMarginProbe {
    /// Opt-in switch: the probe re-runs a generation, so it stays off unless a diagnostician
    /// (or `scripts/collapse-discriminators.sh`) asks for it explicitly.
    static var isEnabled: Bool {
        let mode = ProcessInfo.processInfo.environment["OCOREAI_MARGIN_PROBE"]
        return mode == "1" || mode == "all"
    }

    /// `OCOREAI_MARGIN_PROBE=all` — measure healthy turns too, so margins can be paired with
    /// outcomes instead of only with collapses.
    static var runsOnEveryTurn: Bool {
        ProcessInfo.processInfo.environment["OCOREAI_MARGIN_PROBE"] == "all"
    }

    /// Sendable transport for the conversation the failed turn delivered.
    ///
    /// `Chat.Message` carries media arrays and is not `Sendable`, so it cannot cross into
    /// `ModelContainer.perform { }` (measured: `#RegionIsolation::SendingRisksDataRace`). This
    /// is the same snapshot trick the std path uses at `EngineInference.swift:4288`
    /// (`msgPairsSnapshot` → rebuild inside the closure).
    struct MessagePair: Sendable {
        let role: String
        let content: String
    }

    /// One generated step, reduced to what discriminates.
    struct Step: Sendable {
        let index: Int
        let chosenID: Int
        let chosenText: String
        let chosenLogProb: Double
        /// Best candidate that is not the chosen one (`nil` when the model offered no rival).
        let runnerUpID: Int?
        let runnerUpText: String?
        let margin: Double?
        /// Log-probability of this model's EOS token at this step, when it was in the top set.
        let eosLogProb: Double?
        let eosIsChosen: Bool
    }

    struct Report: Sendable {
        var attempted = false
        var promptTokens = -1
        var expectedPromptTokens = -1
        var fidelityMatched = false
        var steps: [Step] = []
        var failure: String? = nil
    }

    /// Runs `steps` greedy tokens over the same chat assembly the failed turn used.
    ///
    /// Media turns are skipped: reconstructing an `LMInput` with images/videos would need the
    /// processor path this probe does not own, and a half-reconstructed multimodal prompt would
    /// produce margins that describe nothing.
    static func run(
        container: MLXLMCommon.ModelContainer,
        instructions: String?,
        messagePairs: [MessagePair],
        hasMedia: Bool,
        expectedPromptTokens: Int?,
        steps stepLimit: Int,
        baseParameters: MLXLMCommon.GenerateParameters,
        logger: Logger
    ) async -> Report {
        var report = Report()
        report.expectedPromptTokens = expectedPromptTokens ?? -1
        if hasMedia {
            report.failure = "skipped: turn carried media, prompt reconstruction not owned here"
            return report
        }

        // Built once and frozen: the `perform` body runs on another executor, and Swift 6 rejects
        // a captured `var` there (measured: `#SendableClosureCaptures`).
        // Parity with the failed turn: start from the engine's own GenerateParameters, so the
        // KV-cache scheme, penalties, min_p and seed are the ones that actually ran — not the
        // defaults of a fresh struct. Two deliberate deltas: a short budget, and logprob
        // reporting (0 would report only the chosen token; the discriminator needs the rival).
        // `OCOREAI_MARGIN_NO_KV=1` drops the KV-cache configuration as the control arm.
        var mutableParameters = baseParameters
        mutableParameters.maxTokens = max(1, stepLimit)
        mutableParameters.temperature = 0
        mutableParameters.logProbabilities = 8
        if ProcessInfo.processInfo.environment["OCOREAI_MARGIN_NO_KV"] == "1" {
            mutableParameters.kvCache = nil
        }
        let parameters = mutableParameters
        let instructionsSnapshot = instructions

        do {
            let (stream, task, promptTokens) = try await container.perform { context ->
                (AsyncStream<MLXLMCommon.LogProbabilityGeneration<MLXLMCommon.Generation>>,
                    Task<Void, Never>, Int) in
                // Rebuild the conversation inside the closure, and put instructions on a leading
                // .system message — what ChatSession does with its `instructions:` channel, which
                // this probe has to reproduce because it bypasses ChatSession (see file header).
                var rebuiltMessages = messagePairs.map { pair in
                    MLXLMCommon.Chat.Message(
                        role: MLXLMCommon.Chat.Message.Role(rawValue: pair.role) ?? .user,
                        content: pair.content)
                }
                if let instructionsSnapshot, !instructionsSnapshot.isEmpty,
                    rebuiltMessages.first?.role != .system
                {
                    rebuiltMessages.insert(
                        MLXLMCommon.Chat.Message(role: .system, content: instructionsSnapshot), at: 0)
                }

                let prepared = try await context.processor.prepare(
                    input: MLXLMCommon.UserInput(
                        prompt: .chat(rebuiltMessages),
                        processing: .init(),
                        additionalContext: nil))
                let count = prepared.text.tokens.size
                let iterator = try MLXLMCommon.TokenIterator(
                    input: prepared,
                    model: context.model,
                    cache: nil,
                    state: nil,
                    parameters: parameters,
                    components: .init())
                let (innerStream, innerTask) = MLXLMCommon.generateLoopTask(
                    promptTokenCount: count,
                    modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer,
                    iterator: iterator,
                    handler: MLXLMCommon.LogProbabilityTokenLoopHandler(
                        MLXLMCommon.TextToolTokenLoopHandler(
                            tokenizer: context.tokenizer,
                            stopStrings: context.configuration.effectiveStopStrings,
                            format: context.configuration.toolCallFormat ?? .json)))
                return (innerStream, innerTask, count)
            }

            report.attempted = true
            report.promptTokens = promptTokens
            report.fidelityMatched = expectedPromptTokens != nil && expectedPromptTokens == promptTokens

            let tokenizer = await container.tokenizer
            var eosIDs = Set<Int>()
            for id in await container.configuration.eosTokenIds { eosIDs.insert(id) }
            if let eos = tokenizer.eosTokenId { eosIDs.insert(eos) }

            var stepIndex = 0
            for await event in stream {
                guard case .probability(let probabilities) = event else { continue }
                stepIndex += 1
                let chosen = probabilities.chosen
                let rival = probabilities.topLogProbabilities.first { $0.token != chosen.token }
                let eosEntry = probabilities.topLogProbabilities.first { eosIDs.contains($0.token) }
                report.steps.append(
                    Step(
                        index: stepIndex,
                        chosenID: chosen.token,
                        chosenText: decode(tokenizer: tokenizer, id: chosen.token),
                        chosenLogProb: Double(chosen.logProbability),
                        runnerUpID: rival?.token,
                        runnerUpText: rival.map { decode(tokenizer: tokenizer, id: $0.token) },
                        margin: rival.map { Double(chosen.logProbability - $0.logProbability) },
                        eosLogProb: eosEntry.map { Double($0.logProbability) },
                        eosIsChosen: eosIDs.contains(chosen.token)))
            }
            _ = await task.value
            log(report, convKey: "margin", logger: logger)
        } catch {
            report.failure = String(describing: error)
            logger.warning(
                "Degenerate margin probe failed — \(report.failure ?? "?") (the collapse stays unexplained; nothing here was measured)"
            )
        }
        return report
    }

    private static func decode(tokenizer: MLXLMCommon.Tokenizer, id: Int) -> String {
        tokenizer.decode(tokenIds: [id])
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "'")
    }

    /// One line, so a probe can grep it and a human can read the discriminator without a parser.
    static func log(_ report: Report, convKey: String, logger: Logger) {
        guard report.attempted else { return }
        let fidelity = report.fidelityMatched ? "match" : "UNVERIFIED(\(report.promptTokens) vs \(report.expectedPromptTokens))"
        let steps = report.steps.map { step in
            let rival = step.runnerUpText.map { "'\($0)' id=\(step.runnerUpID ?? -1)" } ?? "none"
            let margin = step.margin.map { String(format: "%.4f", $0) } ?? "-"
            let eos = step.eosLogProb.map { String(format: "%.3f", $0) } ?? "out-of-top"
            return "step\(step.index) chose '\(step.chosenText)' id=\(step.chosenID) lp=\(String(format: "%.4f", step.chosenLogProb)) rival=\(rival) margin=\(margin) eos=\(eos) eosChosen=\(step.eosIsChosen)"
        }.joined(separator: " | ")
        logger.info(
            "Degenerate margin probe [\(convKey)] promptTokens=\(report.promptTokens) fidelity=\(fidelity) temperature=0 :: \(steps)"
        )
    }
}
