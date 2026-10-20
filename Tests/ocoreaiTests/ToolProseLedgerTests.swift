// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolProseLedgerTests.swift — one declaration per turn, decided by a measurement of the
/// checkpoint rather than by which family its config key names.
///
/// Live evidence (probe 16, `mlx-community/gemma-4-e2b-it-4bit`, temp 0): one declared tool
/// grew the delivered `usage.prompt_tokens` 707 → 823 (+116) while this server's own tokenizer
/// attributed +65 to the `## Tool:` prose it wrote (systemChars +302); a second declared tool
/// took the residue to +103, i.e. +52 again — per-entry duplication, not one-off template
/// overhead. The checkpoint's `chat_template.jinja` renders every `ChatSession.tools` entry as
/// `<|tool>declaration<tool|>` (:196-203), and that is the copy the model was trained on.
///
/// What these tests pin: the truth table from the one measured fact; that an unmeasured model
/// keeps the old behaviour instead of silently un-declaring its tools; that the answer belongs
/// to a loaded model and not to the process; and that the decision has exactly one producer
/// and one consumer in the source.

import Foundation
import Testing

@testable import ocoreai

@Suite("ToolProseRule — one measured fact, three honest outcomes")
struct ToolProseRuleTests {

    @Test("the truth table, by exact value")
    func truthTable() {
        #expect(ToolProseRule.decide(templateRendersTools: true) == .skippedTemplateRenders)
        #expect(ToolProseRule.decide(templateRendersTools: false) == .injectedTemplateIgnores)
        #expect(ToolProseRule.decide(templateRendersTools: nil) == .injectedUnmeasured)
    }

    @Test("only a measured `renders` may drop the prose")
    func injectsProseTable() {
        #expect(ToolProseMode.skippedTemplateRenders.injectsProse == false)
        #expect(ToolProseMode.injectedTemplateIgnores.injectsProse == true)
        #expect(ToolProseMode.injectedUnmeasured.injectsProse == true)
    }

    /// `nil` is the difference between "this template ignores tools" and "we never asked".
    /// Collapsing them would let an unrendered probe un-declare every tool in a turn.
    @Test("unmeasured is not the same answer as measured-false")
    func unmeasuredIsNotFalse() {
        let notAsked = ToolProseRule.decide(templateRendersTools: nil)
        let asked = ToolProseRule.decide(templateRendersTools: false)
        #expect(notAsked != asked)
        #expect(notAsked.injectsProse == asked.injectsProse)
    }

    @Test("the wire vocabulary stays closed at three values")
    func vocabulary() {
        let raw = ToolProseMode.allCases.map(\.rawValue)
        #expect(raw == ["skippedTemplateRenders", "injectedTemplateIgnores", "injectedUnmeasured"])
    }

    /// A reader of one log line must be able to tell a measurement from a default.
    @Test("reason phrases distinguish measured from unmeasured")
    func reasons() {
        let skipped = ToolProseMode.skippedTemplateRenders.reasonPhrase
        #expect(skipped.contains("renders tools"))
        #expect(skipped.contains("second copy"))
        #expect(
            ToolProseMode.injectedTemplateIgnores.reasonPhrase.contains(
                "ignores the tools variable"))
        #expect(ToolProseMode.injectedUnmeasured.reasonPhrase.contains("not measured"))
    }
}

@Suite("ToolProseLedger — the answer belongs to the loaded model")
struct ToolProseLedgerTests {

    @Test("an unseen model defaults to the behaviour that predates the ledger")
    func defaultIsInject() async {
        let ledger = ToolProseLedger()
        #expect(await ledger.mode(modelId: "someone-elses-model") == .injectedUnmeasured)
        #expect(await ledger.templateRendersTools(modelId: "someone-elses-model") == nil)
    }

    @Test("record maps the measurement, and a reload replaces the answer")
    func recordReplaces() async {
        let ledger = ToolProseLedger()
        #expect(
            await ledger.record(modelId: "m", templateRendersTools: true) == .skippedTemplateRenders
        )
        #expect(await ledger.mode(modelId: "m") == .skippedTemplateRenders)
        #expect(await ledger.templateRendersTools(modelId: "m") == true)
        // Same id, different weights (or a probe that could not run): the newest measurement wins.
        #expect(await ledger.record(modelId: "m", templateRendersTools: nil) == .injectedUnmeasured)
        #expect(await ledger.mode(modelId: "m") == .injectedUnmeasured)
        #expect(await ledger.templateRendersTools(modelId: "m") == nil)
    }

    @Test("two models never share one answer")
    func isolation() async {
        let ledger = ToolProseLedger()
        await ledger.record(modelId: "renders", templateRendersTools: true)
        await ledger.record(modelId: "ignores", templateRendersTools: false)
        #expect(await ledger.mode(modelId: "renders") == .skippedTemplateRenders)
        #expect(await ledger.mode(modelId: "ignores") == .injectedTemplateIgnores)
        #expect(await ledger.mode(modelId: "never-loaded") == .injectedUnmeasured)
    }

    /// The claim must not outlive the weights it was read from — the same rule the video and
    /// tool-call ledgers follow at unload.
    @Test("forget sends a model back to unmeasured")
    func forgetDropsTheClaim() async {
        let ledger = ToolProseLedger()
        await ledger.record(modelId: "m", templateRendersTools: true)
        await ledger.forget(modelId: "m")
        #expect(await ledger.mode(modelId: "m") == .injectedUnmeasured)
        #expect(await ledger.modes.keys.contains("m") == false)
    }

    // MARK: — the wiring, scanned with its own floor

    private static func source(_ relative: String) throws -> String {
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
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    private static func count(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).count
    }

    /// One producer, one consumer: the day a second call site appears, the rule has two homes
    /// again, which is the defect class this round exists to close.
    @Test("the decision has one producer and one consumer, and the scan still matches")
    func wiringHasOneHome() throws {
        let builder = try Self.source("Sources/ocoreai/Handlers/MessageBuilder.swift")
        let pool = try Self.source("Sources/ocoreai/Engine/EnginePool.swift")
        let bridge = try Self.source("Sources/ocoreai/Engine/MLXBridge.swift")
        // Floors: the seam exists in each file before counting anything.
        #expect(builder.contains("Phase 5: Inject tool definitions"))
        #expect(pool.contains("func unloadModel("))
        #expect(bridge.contains("func chatTemplateRendersTools("))
        #expect(try Self.count(#"ToolProseLedger\.shared\.mode\(modelId:"#, in: builder) == 1)
        #expect(try Self.count(#"ToolProseLedger\.shared\.record\("#, in: pool) == 1)
        #expect(try Self.count(#"ToolProseLedger\.shared\.forget\(modelId:"#, in: pool) == 1)
        #expect(try Self.count(#"chatTemplateRendersTools\("#, in: bridge) == 1)
        #expect(try Self.count(#"chatTemplateRendersTools\("#, in: pool) == 1)
    }

    /// The prose must stay behind the decision — an unconditional append is the shape that
    /// wrote the same tool twice.
    @Test("the injection is guarded by the ledger, not unconditional")
    func injectionIsGuarded() throws {
        let builder = try Self.source("Sources/ocoreai/Handlers/MessageBuilder.swift")
        #expect(try Self.count(#"if proseMode\.injectsProse \{"#, in: builder) == 1)
        #expect(
            try Self.count("Available tools:", in: builder) == 1,
            "the prose block must exist exactly once, inside the guard")
    }

    // MARK: — the published row (GET /v1/models/:model/kv-cache → toolProse)

    /// Closed vocabulary on the wire, not just in the log: a fourth spelling is how a
    /// publisher starts inventing capability.
    @Test("the wire vocabulary is snake_case and closed at three values")
    func wireVocabulary() {
        #expect(
            ToolProseMode.allCases.map(\.wireMode)
                == [
                    "skipped_template_renders", "injected_template_ignores",
                    "injected_unmeasured",
                ])
    }

    /// Every published row must carry its own evidence: the mode, the raw measurement and the
    /// reason all come from the same mode, so no row can advertise what was not measured.
    @Test("a published row never claims more than its measurement")
    func rowsMatchTheirEvidence() {
        for mode in ToolProseMode.allCases {
            let row = mode.observation
            #expect(row.mode == mode.wireMode, "\(mode): wire mode must be derived")
            #expect(
                row.reason == mode.reasonPhrase,
                "\(mode): the row must quote the ledger's own sentence, not a second explanation")
            #expect(
                row.templateRendersTools == mode.measuredTemplateRendersTools,
                "\(mode): the measurement alone must match the mode it produced")
        }
        // The specific lie this guards: an unmeasured model reading as if its template
        // were proven to render tools.
        let unmeasured = ToolProseMode.injectedUnmeasured.observation
        #expect(unmeasured.templateRendersTools == nil)
        #expect(!unmeasured.mode.contains("renders"))
        #expect(unmeasured.reason.contains("not measured"))
    }

    /// `nil` has to arrive as `null`, not as an absent key: absence is the shape that makes
    /// "engine never measured this" indistinguishable from "this build forgot to publish".
    @Test("the unmeasured row encodes an explicit null instead of dropping the key")
    func unmeasuredEncodesNull() throws {
        let data = try JSONEncoder().encode(ToolProseMode.injectedUnmeasured.observation)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("row did not encode to a JSON object")
            return
        }
        #expect(obj["mode"] as? String == "injected_unmeasured")
        #expect(
            obj.keys.contains("templateRendersTools"),
            "the synthesized Encodable dropped the optional key — a client cannot tell unmeasured from a regression: \(obj.keys.sorted())"
        )
        #expect(obj["templateRendersTools"] is NSNull)

        let rendered = try JSONEncoder().encode(ToolProseMode.skippedTemplateRenders.observation)
        let renderedObj = try JSONSerialization.jsonObject(with: rendered) as? [String: Any]
        #expect(renderedObj?["templateRendersTools"] as? Bool == true)
    }

    /// The row is published at one seam and the DTO always carries it: a caller that forgets
    /// to pass a measurement still degrades to `injected_unmeasured` rather than claiming one.
    @Test("the row has one publisher, and forgetting to pass it degrades honestly")
    func publisherHasOneHomeAndAHonestDefault() throws {
        let dto = try Self.source("Sources/ocoreai/Engine/KVCacheStatus.swift")
        #expect(
            try Self.count(#"let toolProse: ToolProseObservation"#, in: dto) == 1,
            "the DTO must carry exactly one toolProse row")
        #expect(
            try Self.count(#"ToolProseLedger\.shared\.observation\(modelId:"#, in: dto) == 1,
            "the row must be published at one seam — a second call site is a second truth about one measurement"
        )
        // Defaults are the honest value, not a flattering one.
        #expect(
            dto.contains(
                "toolProse: ToolProseObservation = ToolProseMode.injectedUnmeasured.observation"),
            "the default for a caller that passes nothing must be unmeasured, never skipped")
        // And the row must sit on the same response as prefixReuse, so one request answers
        // both measured KV questions a client has about this model.
        #expect(dto.contains("let prefixReuse: PrefixReuseObservation"))
    }
}
