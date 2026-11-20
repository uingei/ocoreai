// ToolSurfaceHonestyTests.swift — enforcement of the measured tool-surface negative is
// opt-in (`settings.toolsSurface.enforce`, default OFF); publication already lives on
// `/v1/models` (`toolCallDelivery`) and is not re-published here.
//
// Why this exists: the wire answers 200 to a declaring request even after this server has
// *seen* that checkpoint keep every call in the prose (open-items § "one knob is gated,
// the surface is not"). The measured negative has exactly one carrier — a completed
// tool-declaring turn that left a call-shaped answer unparsed — because a template that
// ignores tools is not by itself a failure: the prose lane compensates and the delivery
// ledger measures whether that whole chain actually delivered. So refusal needs BOTH a
// declaration and `prose_only`; `parsed` and `not_observed` always pass through (the
// asymmetry `ReasoningEffortLedger` states: a refusal costs a turn, so only an observed
// failure may cost one).
//
// Gold standard mirrors `ReasoningEffortHonestyTests`: the rule as a pure truth table, the
// refusal naming the knob, the ledger's own evidence line, and both exits — plus the
// negatives: flag OFF must be byte-identical to today, and a caller that declared nothing
// is never refused whatever the flag or the ledger says.

import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("tools[] surface honesty (refusal on the observed negative, opt-in)", .serialized)
struct ToolSurfaceHonestyTests {

    private let model = "mlx-community/gemma-4-e2b-it-4bit"

    private func refusalText(_ error: AppError?) -> String? {
        guard case .some(.invalidRequest(let message)) = error else { return nil }
        return message
    }

    private func record(parsed: Int, prose: Int, declared: Int) -> ToolCallDeliveryRecord {
        var r = ToolCallDeliveryRecord()
        r.parsedTurns = parsed
        r.proseTurns = prose
        r.declaredTurns = declared
        return r
    }

    // MARK: - the decision, as a truth table

    @Test("the truth table: declared x delivery status, six exact booleans")
    func refusalTruthTable() {
        // Nothing declared: nothing demanded, nothing to refuse — whatever was measured.
        #expect(
            ToolCallWire.refuseSurface(
                declared: false, status: ToolCallDeliveryLedger.statusProseOnly) == false)
        #expect(
            ToolCallWire.refuseSurface(
                declared: false, status: ToolCallDeliveryLedger.statusParsed) == false)
        #expect(
            ToolCallWire.refuseSurface(
                declared: false, status: ToolCallDeliveryLedger.statusNotObserved) == false)
        // Declared: refused ONLY on the observed negative; one delivered call or no evidence
        // yet keeps the declaration passing through.
        #expect(
            ToolCallWire.refuseSurface(
                declared: true, status: ToolCallDeliveryLedger.statusProseOnly) == true)
        #expect(
            ToolCallWire.refuseSurface(
                declared: true, status: ToolCallDeliveryLedger.statusParsed) == false)
        #expect(
            ToolCallWire.refuseSurface(
                declared: true, status: ToolCallDeliveryLedger.statusNotObserved) == false)
    }

    // MARK: - the refusal a caller reads

    @Test("the refusal names the knob, the ledger's own evidence, and both exits")
    func refusalNamesTheRemedy() {
        let r = record(parsed: 0, prose: 2, declared: 2)
        let message = refusalText(
            ToolCallWire.surfaceRefusal(modelId: model, declaredToolCount: 1, record: r))
        guard let message else {
            Issue.record("expected a refusal for a declaring caller against prose_only")
            return
        }
        #expect(message.contains(model), "which checkpoint cannot serve it")
        #expect(message.contains("tools[]"), "which knob to stop sending")
        #expect(
            message.contains(r.evidenceLine),
            "the ledger's own sentence, not a second explanation of it")
        #expect(message.contains("Drop tools[]"), "exit one")
        #expect(message.contains("toolCallDelivery=\"parsed\""), "exit two, in the wire's word")
        // A caller's argument is what must change; this is not a server fault.
        #expect(!message.lowercased().contains("internal"))
    }

    @Test("nothing is refused on a measured positive, no evidence, or no declaration")
    func noRefusalWithoutAnObservedFailure() {
        #expect(
            ToolCallWire.surfaceRefusal(
                modelId: model, declaredToolCount: 1,
                record: record(parsed: 1, prose: 0, declared: 1)
            ) == nil)
        #expect(
            ToolCallWire.surfaceRefusal(modelId: model, declaredToolCount: 1, record: nil) == nil)
        #expect(
            ToolCallWire.surfaceRefusal(
                modelId: model, declaredToolCount: 0,
                record: record(parsed: 0, prose: 3, declared: 3)
            ) == nil)
    }

    // MARK: - the knob

    @Test("enforcement is opt-in: the key is settings.toolsSurface.enforce, default OFF")
    @MainActor
    func knobDefaultsOff() throws {
        #expect(SettingsStore.Key.toolsSurfaceEnforce.rawValue == "settings.toolsSurface.enforce")
        let suite = try #require(
            UserDefaults(suiteName: "test.ocoreai.\(UUID().uuidString)"),
            "the fresh suite must exist for the default-OFF assertion")
        let store = SettingsStore(defaults: suite)
        #expect(store.toolsSurfaceEnforce == false, "OFF means today")
        store.toolsSurfaceEnforce = true
        #expect(SettingsStore(defaults: suite).toolsSurfaceEnforce == true, "the vote persists")
    }

    // MARK: - the wiring, scanned with its own floors

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

    /// The enforcement decision has one producer and two flag reads (the two
    /// `/v1/chat/completions lanes); the publication stays one home too. Floors run first so a
    /// rename cannot pass vacuously.
    @Test("the gate has one seat; the flag is read on exactly the two chat lanes")
    func wiringHasOneHome() throws {
        let handler = try Self.source("Sources/ocoreai/Handlers/ChatHandler.swift")
        let router = try Self.source("Sources/ocoreai/Router/ChatCompletionsRouter.swift")
        // Floors: the neighbors of this gate exist before anything counts.
        #expect(handler.contains("ReasoningEffortWire.refusal("))
        #expect(router.contains("objects[i].toolCallDelivery = "))
        #expect(
            try Self.count(#"objects\[i\]\.toolCallDelivery = "#, in: router) == 1,
            "the delivery status keeps exactly one publisher — this gate adds no second column")
        #expect(try Self.count(#"ToolCallWire\.surfaceRefusal\("#, in: handler) == 1)
        #expect(
            try Self.count(#"SettingsStore\.shared\.toolsSurfaceEnforce"#, in: router) == 2,
            "both /v1/chat/completions lanes read the flag, no lane more")
    }
}

/// The route-level half: flag ON + a pool that observed prose_only + a declaring request →
/// refused naming both exits; flag OFF → byte-identical to the unseeded server; a caller that
/// declared nothing is never refused whatever the flag says.
@Suite("tools[] enforcement is opt-in (settings.toolsSurface.enforce, default OFF)", .serialized)
struct ToolSurfaceEnforcementTests {

    private static let model = ScriptedInference.modelId

    private struct Fixture {
        let pool: EnginePool
        let scheduler: SchedulerActor
        let metrics: MetricsRegistry
        let compressor: SessionCompressor
        let builder: MessageBuilder
        let db1: String
        let db2: String

        static func make(label: String) async throws -> Fixture {
            var config = EnginePoolConfig.default
            config.defaultModelId = ""
            let pool = EnginePool(
                config: config, logger: Logger(label: label), tokenizerManager: TokenizerManager())
            let db1 = Self.uuidPath()
            let db2 = Self.uuidPath()
            let store = SQLiteStore(path: db1)
            try await store.open()
            let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
            let mbStore = SQLiteStore(path: db2)
            try await mbStore.open()
            let builder = MessageBuilder(
                systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
                sessionCompressor: SessionCompressor(
                    store: mbStore, fts: FTS5Search(store: mbStore)),
                complexityAnalyzer: ComplexityAnalyzer(),
                thinkingBudget: ThinkingBudget()
            )
            let scheduler = SchedulerActor(
                maxQueueSize: 4, memoryTracker: nil, log: Logger(label: label))
            return Fixture(
                pool: pool, scheduler: scheduler, metrics: MetricsRegistry(),
                compressor: compressor, builder: builder, db1: db1, db2: db2)
        }

        static func uuidPath() -> String {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "toolsurface_\(UUID().uuidString.prefix(8)).sqlite"
            ).path
        }

        func cleanup() {
            try? FileManager.default.removeItem(atPath: db1)
            try? FileManager.default.removeItem(atPath: db2)
        }

        func request(declaredTools: Bool) throws -> ChatCompletionRequest {
            let tools =
                declaredTools
                ? #","tools":[{"type":"function","function":{"name":"probe_tool","description":"probe","parameters":{"type":"object","properties":{}}}}]"#
                : ""
            let json =
                #"{"model":"\#(ToolSurfaceEnforcementTests.model)","messages":[{"role":"user","content":"hi"}]\#(tools)}"#
            return try JSONDecoder().decode(
                ChatCompletionRequest.self, from: Data(json.utf8))
        }
    }

    /// What a run did, reduced to the parts the flag is allowed to change. The
    /// `threwInvalidRequest` payload is compared verbatim, so two runs are equal only when
    /// they fail the same way for the same reason.
    private enum Outcome: Equatable {
        case served(status: Int)
        case threwInvalidRequest(String)
        case threwOther(String)
    }

    private func run(_ fixture: Fixture, declaredTools: Bool, enforced: Bool) async -> Outcome {
        do {
            let response = try await chatCompletionsHandler(
                request: try fixture.request(declaredTools: declaredTools),
                enginePool: fixture.pool,
                scheduler: fixture.scheduler,
                metrics: fixture.metrics,
                sessionCompressor: fixture.compressor,
                semanticSearch: nil,
                messageBuilder: fixture.builder,
                logger: Logger(label: "test.tool-surface.enforce"),
                toolsSurfaceEnforced: enforced
            )
            return .served(status: Int(response.status.code))
        } catch let error as AppError {
            if case .invalidRequest(let message) = error {
                return .threwInvalidRequest(message)
            }
            return .threwOther(String(reflecting: error))
        } catch {
            return .threwOther(String(reflecting: type(of: error)))
        }
    }

    /// Leases the scripted engine so the flag-OFF arms replay a real turn instead of touching
    /// a real checkpoint; the refusal arm throws before the lane matters either way.
    private func scriptedLane() throws -> ProcessGlobalLease {
        let lease = ProcessGlobalLease(envKeys: [ScriptedInference.environmentKey])
        let path = NSTemporaryDirectory() + "ocoreai-tool-surface-\(UUID().uuidString).json"
        try Data(#"{"segments":["ok"]}"#.utf8).write(to: URL(fileURLWithPath: path))
        setenv(ScriptedInference.environmentKey, path, 1)
        return lease
    }

    @Test("flag ON + observed prose_only + declared tools → refused naming knob and both exits")
    func flagOnRefusesADeclaringRequest() async throws {
        let lease = try scriptedLane()
        defer { lease.release() }
        let fixture = try await Fixture.make(label: "test.tool-surface.on")
        defer { fixture.cleanup() }
        await fixture.pool.recordToolCallDelivery(
            modelId: Self.model, outcome: .proseOnly)
        let outcome = await run(fixture, declaredTools: true, enforced: true)
        guard case .threwInvalidRequest(let message) = outcome else {
            Issue.record("a declaring caller must be refused, got \(outcome)")
            return
        }
        #expect(message.contains(Self.model))
        #expect(message.contains("tools[]"))
        #expect(message.contains("Drop tools[]"), "exit one")
        #expect(message.contains("toolCallDelivery=\"parsed\""), "exit two")
    }

    @Test("flag OFF: the ledger changes nothing about the same request")
    func flagOffBehavesAsToday() async throws {
        let lease = try scriptedLane()
        defer { lease.release() }
        let seeded = try await Fixture.make(label: "test.tool-surface.off-seeded")
        defer { seeded.cleanup() }
        await seeded.pool.recordToolCallDelivery(
            modelId: Self.model, outcome: .proseOnly)
        let unseeded = try await Fixture.make(label: "test.tool-surface.off-clean")
        defer { unseeded.cleanup() }
        let withClaim = await run(seeded, declaredTools: true, enforced: false)
        let withoutClaim = await run(unseeded, declaredTools: true, enforced: false)
        #expect(
            withClaim == withoutClaim,
            "with the flag OFF the ledger must be unobservable: \(withClaim) vs \(withoutClaim)")
        if case .threwInvalidRequest(let message) = withClaim {
            #expect(
                !message.contains("Drop tools[]"),
                "the flag-OFF lane must never emit the refusal: \(message)")
        }
    }

    @Test("flag ON never refuses a caller that declared no tools[]")
    func flagOnNeverRefusesADeclaredNothingRequest() async throws {
        let lease = try scriptedLane()
        defer { lease.release() }
        let seeded = try await Fixture.make(label: "test.tool-surface.ontools-seeded")
        defer { seeded.cleanup() }
        await seeded.pool.recordToolCallDelivery(
            modelId: Self.model, outcome: .proseOnly)
        let unseeded = try await Fixture.make(label: "test.tool-surface.ontools-clean")
        defer { unseeded.cleanup() }
        let withClaim = await run(seeded, declaredTools: false, enforced: true)
        let withoutClaim = await run(unseeded, declaredTools: false, enforced: true)
        #expect(
            withClaim == withoutClaim,
            "nothing declared, nothing refused: \(withClaim) vs \(withoutClaim)")
        if case .threwInvalidRequest(let message) = withClaim {
            #expect(!message.contains("Drop tools[]"), "no tools, no refusal: \(message)")
        }
    }

    @Test("flag ON + a delivered call on record → the declaration passes through")
    func flagOnPassesAMeasuredPositive() async throws {
        let lease = try scriptedLane()
        defer { lease.release() }
        let fixture = try await Fixture.make(label: "test.tool-surface.positive")
        defer { fixture.cleanup() }
        await fixture.pool.recordToolCallDelivery(
            modelId: Self.model, outcome: .parsed, calledNames: ["probe_tool"])
        let outcome = await run(fixture, declaredTools: true, enforced: true)
        if case .threwInvalidRequest(let message) = outcome {
            #expect(
                !message.contains("Drop tools[]"),
                "a measured positive must never meet the refusal: \(message)")
        }
    }
}
