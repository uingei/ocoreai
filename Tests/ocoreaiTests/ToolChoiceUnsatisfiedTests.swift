// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! A demanded tool call that never arrived has to reach the client in the turn's own result.
//!
//! Red sample: measured 2026-11-01 against the installed `ocoreai.app`, `tool_choice:"required"`
//! answered `200 · finish_reason:"stop" · content:""` with zero calls executed, and the only
//! trace of the gap was a server log line — which a harness does not read. Every expectation
//! below is an exact value; the scans floor their own hit counts.

import Foundation
import Testing

@testable import ocoreai

private func rootFile(_ relative: String) throws -> String {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}

@Suite("UnsatisfiedToolChoice — an unmet demand is stated, never smoothed over")
struct ToolChoiceUnsatisfiedTests {

    @Test("the measured case: required, no call, no text")
    func unmetDemandIsNamedWithItsEvidence() {
        let verdict = unsatisfiedToolChoice(
            demanded: "required", toolCallsMade: false, finishReason: "stop", contentEmpty: true)
        let text = verdict?.demanded ?? ""
        #expect(text == "required", "the demand echoed: \(text)")
        #expect(verdict?.finishReason == "stop", "the word actually carried")
        #expect(verdict?.contentEmpty == true, "the case that reads as a normal end")
        #expect(
            verdict?.remedy.contains("tool_choice \"auto\"") == true,
            "a next step, not a shrug: \(verdict?.remedy ?? "")")
        #expect(
            verdict?.remedy.contains("tool_call_delivery") == true,
            "points at the per-checkpoint fact: \(verdict?.remedy ?? "")")
    }

    @Test("a met or undemanded turn has no verdict, because absence is a fact here")
    func metAndUndemandedTurnsSayNothing() {
        #expect(
            unsatisfiedToolChoice(
                demanded: "required", toolCallsMade: true, finishReason: "tool_calls",
                contentEmpty: false) == nil)
        #expect(
            unsatisfiedToolChoice(
                demanded: "auto", toolCallsMade: false, finishReason: "stop", contentEmpty: false)
                == nil)
        #expect(
            unsatisfiedToolChoice(
                demanded: "none", toolCallsMade: false, finishReason: "stop", contentEmpty: false)
                == nil)
        #expect(
            unsatisfiedToolChoice(
                demanded: nil, toolCallsMade: false, finishReason: "stop", contentEmpty: true)
                == nil)
    }

    @Test("a named tool is a demand, and its name is what the client gets back")
    func namedDemandKeepsItsName() {
        let verdict = unsatisfiedToolChoice(
            demanded: "function:get_weather", toolCallsMade: false, finishReason: "stop",
            contentEmpty: false)
        #expect(verdict?.demanded == "function:get_weather")
        #expect(verdict?.contentEmpty == false, "text arrived, the call did not")
    }

    @Test("the wire key is the namespaced one, with the measured fields inside it")
    func jsonShapeIsThePublishedOne() throws {
        let verdict = unsatisfiedToolChoice(
            demanded: "required", toolCallsMade: false, finishReason: "stop", contentEmpty: true)
        let turn = OcoreaiTurn.assemble(toolResults: [], toolChoiceUnsatisfied: verdict)
        let data = try JSONEncoder().encode(turn)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"tool_choice_unsatisfied\""), "\(json)")
        #expect(json.contains("\"content_empty\":true"), "\(json)")
        #expect(json.contains("\"demanded\":\"required\""), "\(json)")
    }

    @Test("nothing measured means no extension at all, never an empty object")
    func emptyTurnPublishesNothing() {
        #expect(OcoreaiTurn.assemble(toolResults: []) == nil)
    }

    /// The field is one decision assembled at four sites (two faces x stream / non-stream) —
    /// the same parity rule `scripts/probes/21-sleep-steer-wake.sh` §7 holds for
    /// `ocoreai.tool_results`: a face that lost its site would still answer correctly while
    /// quietly dropping the verdict.
    @Test("all four sites assemble the extension through one rule")
    func allFourSitesUseTheOneRule() throws {
        for file in [
            "Sources/ocoreai/Handlers/ChatHandler.swift",
            "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift",
        ] {
            let text = try rootFile(file)
            let assemblies = text.components(separatedBy: "OcoreaiTurn.assemble(").count - 1
            #expect(assemblies == 2, "\(file): \(assemblies) assembly sites, expected 2")
            let verdicts = text.components(separatedBy: "unsatisfiedToolChoice(").count - 1
            #expect(verdicts == 2, "\(file): \(verdicts) verdict sites, expected 2")
            let handRolled = text.components(separatedBy: "OcoreaiTurn(toolResults:").count - 1
            #expect(handRolled == 0, "\(file): a site bypasses the one rule")
        }
    }
}
