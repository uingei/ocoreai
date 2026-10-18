// ToolCallDeliveryDisclosureTests.swift — `/v1/models` may only say what a
// declaring turn actually did in this process (AGENTS.md invariant 2).
//
// Why this ledger exists: `agent_loop: true` on `/v1/capabilities` and a healthy
// `/v1/models` said nothing about the one thing an agent client routes on — whether
// a `tools[]` request ever came back as `tool_calls`. Measured 10-18: it had not,
// and the surface was silent in both directions.
//
// Gold standard here (ThinkingBudget/ComplexityAnalyzer style): exact values, not
// `> 0`, plus the negatives — `not_observed` must be published, not omitted, and a
// model that simply answered a question must not be labelled broken.

import Foundation
import Testing

@testable import ocoreai

@Suite("Tool-call delivery disclosure (per-model, measured only)")
struct ToolCallDeliveryDisclosureTests {

    private let model = "mlx-community/gemma-4-e2b-it-4bit"

    // MARK: - closed vocabulary

    @Test("the published vocabulary is exactly three values")
    func vocabularyIsClosed() {
        #expect(ToolCallDeliveryLedger.statusParsed == "parsed")
        #expect(ToolCallDeliveryLedger.statusProseOnly == "prose_only")
        #expect(ToolCallDeliveryLedger.statusNotObserved == "not_observed")
    }

    @Test("an unobserved model answers not_observed, never a silent absence")
    func unobservedIsStated() {
        var ledger = ToolCallDeliveryLedger()
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusNotObserved)
        #expect(ledger.evidence(modelId: model) == nil, "no claim, no evidence line")
        #expect(ToolCallDeliveryLedger.status(of: nil) == ToolCallDeliveryLedger.statusNotObserved)
    }

    // MARK: - status precedence

    @Test("a delivered call makes the model parsed")
    func parsedWinsRecord() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .parsed, calledNames: ["get_weather"])
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusParsed)
        #expect(ledger.record(modelId: model)?.parsedTurns == 1)
        #expect(ledger.record(modelId: model)?.declaredTurns == 1)
    }

    @Test("prose-only is what a client needs when nothing ever parsed")
    func proseOnlyRecord() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .proseOnly)
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusProseOnly)
    }

    @Test("one parsed turn outranks a prose-only turn")
    func parsedOutranksProse() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .proseOnly)
        ledger.record(modelId: model, outcome: .proseOnly)
        ledger.record(modelId: model, outcome: .parsed, calledNames: ["read_file"])
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusParsed)
        #expect(ledger.record(modelId: model)?.proseTurns == 2)
    }

    @Test("a turn with no call shape is evidence of neither direction")
    func noCallStaysNotObserved() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .noCall)
        ledger.record(modelId: model, outcome: .noCall)
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusNotObserved)
        #expect(ledger.record(modelId: model)?.declaredTurns == 2)
        #expect(ledger.record(modelId: model)?.parsedTurns == 0)
    }

    @Test("unload drops the claim with the weights")
    func forgetReturnsToNotObserved() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .parsed, calledNames: ["read_file"])
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusParsed)
        ledger.forget(modelId: model)
        #expect(ledger.status(modelId: model) == ToolCallDeliveryLedger.statusNotObserved)
        #expect(ledger.evidence(modelId: model) == nil)
    }

    // MARK: - evidence lines

    @Test("parsed evidence counts turns and names the tools that came back")
    func parsedEvidence() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .parsed, calledNames: ["read_file", "exec_command"])
        ledger.record(modelId: model, outcome: .parsed, calledNames: ["read_file"])
        guard let line = ledger.evidence(modelId: model) else {
            Issue.record("expected an evidence line")
            return
        }
        #expect(line.contains("2 structured tool_call turn(s) in 2 tool-declaring turn(s)"))
        #expect(line.contains("called: exec_command, read_file"), "sorted, deduped: \(line)")
    }

    @Test("prose-only evidence says no call arrived, and counts the declaring turns")
    func proseEvidence() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .proseOnly)
        ledger.record(modelId: model, outcome: .noCall)
        guard let line = ledger.evidence(modelId: model) else {
            Issue.record("expected an evidence line")
            return
        }
        #expect(line.contains("no structured tool_calls in 2 tool-declaring turn(s)"))
        #expect(line.contains("1 of them answered in prose"))
    }

    // MARK: - aggregate (server-wide surface)

    @Test("aggregate counts models apart from turns, and is empty before any traffic")
    func aggregateCounts() {
        var ledger = ToolCallDeliveryLedger()
        #expect(ledger.aggregate().isEmpty)
        ledger.record(modelId: "a", outcome: .parsed, calledNames: ["x"])
        ledger.record(modelId: "a", outcome: .proseOnly)
        ledger.record(modelId: "b", outcome: .noCall)
        let summary = ledger.aggregate()
        #expect(summary.models == 2)
        #expect(summary.declaredTurns == 3)
        #expect(summary.parsedTurns == 1)
        #expect(summary.proseTurns == 1)
        #expect(summary.evidenceLine.contains("across 2 model(s) in 3 tool-declaring turn(s)"))
    }

    @Test("aggregate over a snapshot equals the aggregate over the ledger")
    func aggregateOverSnapshot() {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: "a", outcome: .parsed, calledNames: ["x"])
        #expect(
            ToolCallDeliveryLedger.aggregate(ledger.deliveries) == ledger.aggregate())
    }

    // MARK: - prose classification (deliberately narrow)

    @Test("call-shaped JSON naming a declared tool is prose_only")
    func proseCallShapeDetected() {
        let text =
            "```json\n{ \"tool_name\": \"get_weather\", \"params\": { \"city\": \"Paris\" } }\n```"
        #expect(
            ToolCallDeliveryLedger.classifyTurn(text: text, declaredNames: ["get_weather"])
                == .proseOnly)
    }

    @Test("a sentence that merely mentions a tool name is NOT a dialect failure")
    func ordinaryProseIsNotProseOnly() {
        let text = "I can use get_weather if you give me a city."
        #expect(
            ToolCallDeliveryLedger.classifyTurn(text: text, declaredNames: ["get_weather"])
                == .noCall)
    }

    @Test("call-shaped JSON about a tool nobody declared is not this turn's problem")
    func undeclaredNameInJSONIsNotProseOnly() {
        let text = "{\"name\": \"some_other_tool\", \"arguments\": {}}"
        #expect(
            ToolCallDeliveryLedger.classifyTurn(text: text, declaredNames: ["get_weather"])
                == .noCall)
    }

    @Test("classification needs a declaration to mean anything")
    func emptyDeclarationIsNoCall() {
        #expect(
            ToolCallDeliveryLedger.classifyTurn(text: "{\"name\":\"x\"}", declaredNames: [])
                == .noCall)
    }

    // MARK: - wire shape

    @Test("record encodes the fields the wire publishes")
    func recordEncoding() throws {
        var ledger = ToolCallDeliveryLedger()
        ledger.record(modelId: model, outcome: .parsed, calledNames: ["get_weather"])
        guard let record = ledger.record(modelId: model) else {
            Issue.record("expected a record")
            return
        }
        let data = try JSONEncoder().encode(record)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"declaredTurns\":1"))
        #expect(json.contains("\"parsedTurns\":1"))
        #expect(json.contains("\"calledNames\":[\"get_weather\"]"))
    }

    // The probe and the surface disagreed once (10-18): the probe read
    // `tool_call_delivery` off /v1/models while `ModelObject` emits camelCase, so a
    // delivered call read as an absent row. `/v1/models` objects are camelCase by the
    // convention ModelsWireShapeTests pins for this struct (`weightsDir`, `videoInput`);
    // snake_case belongs to /v1/capabilities row NAMES, not to this object's keys.
    @Test("the /v1/models keys are camelCase here, snake_case belongs to the caps row")
    func modelsObjectKeyShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parsed = ModelObject(
            id: "m",
            state: "ready",
            toolCallDelivery: ToolCallDeliveryLedger.statusParsed,
            toolCallEvidence: "delivered 1 tool call(s) in 1 declaring turn(s): get_weather")
        let parsedJSON = String(data: try encoder.encode(parsed), encoding: .utf8) ?? ""
        #expect(
            parsedJSON.contains("\"toolCallDelivery\":\"parsed\""),
            "wire keys wrong: \(parsedJSON)")
        #expect(
            parsedJSON.contains("\"toolCallEvidence\":"),
            "wire keys wrong: \(parsedJSON)")
        #expect(
            !parsedJSON.contains("tool_call_delivery"),
            "snake_case leaked into a /v1/models object key: \(parsedJSON)")

        let quiet = ModelObject(id: "m", state: "ready")
        let quietJSON = String(data: try encoder.encode(quiet), encoding: .utf8) ?? ""
        #expect(
            !quietJSON.contains("toolCallEvidence"),
            "nil evidence must not appear: \(quietJSON)")
    }
}
