// ReasoningEffortHonestyTests.swift — `reasoning_effort` may only be honored by a checkpoint
// this server measured reading it (AGENTS.md invariant 2: the surface never claims more than
// the engine delivered).
//
// Why this exists: the wire forwards the caller's word verbatim into the chat-template context
// (`ReasoningEffortWire` deliberately owns no enum and no word table), and for a checkpoint
// whose template never names the variable the word is dropped before generation — the caller
// still gets 200 and believes it asked for thinking control. Both host checkpoints measured
// that way; Qwen3.8 is the other face of the same fact (it raises inside jinja on a word it
// does not accept). The refusal is shaped after codex's `unsupported_code_mode_warning`
// (`core/src/session/code_mode_warning.rs:6-24`): name the knob, name the evidence, name both
// exits.
//
// Gold standard: exact wire strings and the exact sentence fragments a client acts on, plus the
// negatives — an unmeasured checkpoint must NOT be refused, and a caller that asked for nothing
// must never be.

import Foundation
import Testing

@testable import ocoreai

@Suite("reasoning_effort honesty (per-checkpoint, measured only)", .serialized)
struct ReasoningEffortHonestyTests {

    private let model = "mlx-community/gemma-4-e2b-it-4bit"

    /// The message a refused caller actually reads, or nil when nothing was refused.
    private func refusalText(_ error: AppError?) -> String? {
        guard case .some(.invalidRequest(let message)) = error else { return nil }
        return message
    }

    // MARK: - closed vocabulary

    @Test("the published vocabulary is exactly three values, spelled for the wire")
    func vocabularyIsClosed() {
        #expect(ReasoningEffortMode.allCases.count == 3)
        #expect(ReasoningEffortMode.honored.wireMode == "honored")
        #expect(ReasoningEffortMode.templateIgnores.wireMode == "template_ignores")
        #expect(ReasoningEffortMode.notObserved.wireMode == "not_observed")
    }

    @Test("the measurement alone distinguishes 'ignored' from 'never looked'")
    func measurementDistinguishesNegativeFromUnknown() {
        #expect(ReasoningEffortMode.honored.measuredTemplateReadsKwarg == true)
        #expect(ReasoningEffortMode.templateIgnores.measuredTemplateReadsKwarg == false)
        #expect(ReasoningEffortMode.notObserved.measuredTemplateReadsKwarg == nil)
    }

    // MARK: - the decision, as a truth table

    @Test("a refusal needs BOTH a demand and a measured negative")
    func refusalTruthTable() {
        // No demand: the word was never asked, so there is nothing to refuse — whatever the
        // measurement says.
        for mode in ReasoningEffortMode.allCases {
            #expect(
                !ReasoningEffortRule.refuse(callerValue: nil, mode: mode),
                "no value asked in \(mode)")
            #expect(
                !ReasoningEffortRule.refuse(callerValue: "", mode: mode), "empty in \(mode)")
            #expect(
                !ReasoningEffortRule.refuse(callerValue: "   \n", mode: mode),
                "blank in \(mode)")
        }
        // Demand + measured negative: refuse.
        #expect(ReasoningEffortRule.refuse(callerValue: "high", mode: .templateIgnores))
        // Demand + measured positive, or a fact nobody measured: pass through.
        #expect(!ReasoningEffortRule.refuse(callerValue: "high", mode: .honored))
        #expect(!ReasoningEffortRule.refuse(callerValue: "high", mode: .notObserved))
    }

    @Test("the refusal names the knob, the evidence, and both exits")
    func refusalNamesTheRemedy() {
        let message = refusalText(
            ReasoningEffortWire.refusal(
                modelId: model, requestedValue: "high", mode: .templateIgnores))
        guard let message else {
            Issue.record("expected a refusal for a measured negative with a demanded value")
            return
        }
        #expect(message.contains(model), "which checkpoint cannot honor it")
        #expect(message.contains("reasoning_effort"), "which knob to stop sending")
        #expect(message.contains("high"), "the value that was sent")
        #expect(
            message.contains(ReasoningEffortMode.templateIgnores.reasonPhrase),
            "the ledger's own evidence sentence, not a paraphrase of it")
        #expect(message.contains("Omit reasoning_effort"), "exit one")
        #expect(message.contains("honored"), "exit two: a model whose row says honored")
        // It must not read as a server fault: the caller's argument is what changes.
        #expect(!message.lowercased().contains("internal"))
    }

    @Test("nothing is refused when the model reads it or the fact was never measured")
    func noRefusalWithoutAMeasuredNegative() {
        #expect(
            ReasoningEffortWire.refusal(modelId: model, requestedValue: "high", mode: .honored)
                == nil)
        #expect(
            ReasoningEffortWire.refusal(modelId: model, requestedValue: "high", mode: .notObserved)
                == nil)
        #expect(
            ReasoningEffortWire.refusal(modelId: model, requestedValue: nil, mode: .templateIgnores)
                == nil)
    }

    // MARK: - the record, keyed by weights that are here

    @Test("record maps the measurement, an unknown id is not_observed, unload drops the claim")
    func ledgerFollowsTheWeights() {
        var ledger = ReasoningEffortLedger()
        #expect(ledger.mode(modelId: model) == .notObserved, "never measured ≠ measured false")
        #expect(ledger.record(modelId: model, templateReadsKwarg: false) == .templateIgnores)
        #expect(ledger.record(modelId: model, templateReadsKwarg: true) == .honored)
        #expect(ledger.record(modelId: model, templateReadsKwarg: nil) == .notObserved)
        #expect(ledger.record(modelId: "other", templateReadsKwarg: false) == .templateIgnores)
        #expect(ledger.modes.count == 2, "keyed per checkpoint, not per family")
        ledger.forget(modelId: "other")
        #expect(ledger.mode(modelId: "other") == .notObserved, "the claim never outlives weights")
        #expect(ledger.mode(modelId: model) == .notObserved)
    }

    // MARK: - the wire stays wire-not-brain

    @Test("the probe value belongs to no effort table and is still injected verbatim")
    func probeStaysWireNotBrain() {
        // The sentinel must not be a word a template could accept, or the probe would report
        // "reads it" for a template that merely tolerated a legal value.
        let codexWords = ["minimal", "low", "medium", "high", "xhigh"]
        #expect(!codexWords.contains(ReasoningEffortWire.probeValue))
        #expect(ReasoningEffortWire.key == "reasoning_effort")
        let ctx = ReasoningEffortWire.context(nil, rawValue: ReasoningEffortWire.probeValue)
        #expect(ctx?[ReasoningEffortWire.key] as? String == ReasoningEffortWire.probeValue)
        // Absent stays absent: no context, no behavior change for thinking-off traffic.
        #expect(ReasoningEffortWire.context(nil, rawValue: nil) == nil)
        #expect(ReasoningEffortWire.context(nil, rawValue: "  ") == nil)
    }

    // MARK: - the face

    @Test("`/v1/models` omits the field rather than inventing a mode")
    func modelsFaceOmitsUnknown() throws {
        let plain = try JSONEncoder().encode(ModelObject(id: "m", state: "ready"))
        let body = String(data: plain, encoding: .utf8) ?? ""
        #expect(!body.contains(#""reasoningEffort""#), "nil means absent, not a fourth word")

        let stated = try JSONEncoder().encode(
            ModelObject(id: "m", state: "ready", reasoningEffort: "template_ignores"))
        let statedBody = String(data: stated, encoding: .utf8) ?? ""
        #expect(statedBody.contains(#""reasoningEffort":"template_ignores""#))
    }

    @Test("the load-time log line and the refusal carry one explanation, not two")
    func narratorsShareOneReason() {
        let line = ReasoningEffortWire.logLine(modelId: model, mode: .templateIgnores)
        #expect(line.contains("Reasoning effort templateIgnores for \(model)"))
        #expect(line.contains(ReasoningEffortMode.templateIgnores.reasonPhrase))
        #expect(
            ReasoningEffortWire.logLine(modelId: model, mode: .notObserved)
                .contains(ReasoningEffortMode.notObserved.reasonPhrase))
    }
}
