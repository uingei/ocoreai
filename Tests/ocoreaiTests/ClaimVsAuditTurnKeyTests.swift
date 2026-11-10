// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// The audit's record is attributable to the turn that dispatched it — the fix for the skew
/// measured 2026-11-01, where a turn that dispatched no tool at all was told "This turn did
/// change files" because a concurrent turn's writes landed inside its baseline window. An
/// inflated set does not merely suppress the honest notice; it INVENTS the other one, which is
/// the invariant-2 breach this mechanism exists to prevent (`Models/ClaimVsAudit.swift`).
///
/// Every assertion is an exact value; the scans floor their own hit counts so a wiring edit
/// that removes a `turnToken:` argument reddens the scan rather than the inference below it.

import Foundation
import Logging
import Testing

@testable import ocoreai

private func turnKeyRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func readSource(_ relative: String) throws -> String {
    try String(contentsOf: turnKeyRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

// The state tests own their ledger instances (the `.shared` actor is written by every suite
// that dispatches a tool — load-immunity by ownership, per ToolAttemptLedgerTests 11-01(100));
// the one dispatch test pins its OWN record by tool+target+token, unknowable-count-free.
@Suite("ClaimVsAudit — the record is attributed to the turn that dispatched it")
struct ClaimVsAuditTurnKeyTests {

    /// Foreign turns cannot inflate the set; a keyless record belongs to no audited turn.
    @Test func turnKeyedMutationQueryIgnoresForeignAndKeylessRecords() async {
        let ledger = ToolMutationLedger()
        await ledger.record(
            SuccessfulMutation(tool: "write_file", target: "mine.txt", turnToken: "turn-A"))
        await ledger.record(
            SuccessfulMutation(tool: "write_file", target: "theirs.txt", turnToken: "turn-B"))
        await ledger.record(
            SuccessfulMutation(tool: "write_file", target: "orphan.txt"))
        let mine = await ledger.since(0, turnToken: "turn-A")
        #expect(mine.count == 1, "exactly this turn's write: \(mine.map(\.target))")
        #expect(mine.first?.target == "mine.txt")
        let theirs = await ledger.since(0, turnToken: "turn-B")
        #expect(theirs.count == 1)
        #expect(theirs.first?.target == "theirs.txt")
        let nobody = await ledger.since(0, turnToken: "turn-C")
        #expect(nobody.isEmpty, "a key no turn holds matches nothing: \(nobody.count)")
        let all = await ledger.since(0)
        #expect(all.count == 3, "the unkeyed form still reads the whole window: \(all.count)")
    }

    /// The baseline still bounds its own turn: a record from the SAME key that predates the
    /// turn head does not ride into the next request that happens to reuse the instance.
    @Test func baselineStillBoundsTheOwnKey() async {
        let ledger = ToolMutationLedger()
        await ledger.record(
            SuccessfulMutation(tool: "write_file", target: "old.txt", turnToken: "turn-A"))
        let baseline = await ledger.snapshot()
        await ledger.record(
            SuccessfulMutation(tool: "write_file", target: "new.txt", turnToken: "turn-A"))
        let mine = await ledger.since(baseline, turnToken: "turn-A")
        #expect(mine.count == 1)
        #expect(mine.first?.target == "new.txt")
    }

    /// The failure half attributes identically: one turn's failed writer stays that turn's
    /// unresolved failure and cannot open another turn's `unresolvedMutatingFailures`.
    @Test func turnKeyedAttemptQueryAttributesTheFailureHalf() async {
        let ledger = ToolAttemptLedger()
        await ledger.record(
            ToolAttempt(
                tool: "edit_file", target: "theirs.txt", evidence: .reported,
                outcome: .failed, failure: "found 0", turnToken: "turn-B"))
        await ledger.record(
            ToolAttempt(
                tool: "edit_file", target: "mine.txt", evidence: .reported,
                outcome: .failed, failure: "found 0", turnToken: "turn-A"))
        let mine = await ledger.since(0, turnToken: "turn-A")
        #expect(mine.count == 1, "one attempt, one turn: \(mine.count)")
        #expect(ToolAttemptLedger.unresolvedMutatingFailures(mine) == 1)
        let foreign = await ledger.since(0, turnToken: "turn-C")
        #expect(foreign.isEmpty)
        #expect(ToolAttemptLedger.unresolvedMutatingFailures(foreign) == 0)
    }

    /// The chokepoint stamps the caller's key onto both halves — the unit-level end of the
    /// handler → engine → registry thread. The record is pinned by tool+target+token, so
    /// concurrent dispatchers cannot perturb it (`ToolAttemptLedgerTests` ownership rule).
    @Test func dispatchedCallCarriesTheCallersTurnKey() async throws {
        let registry = ToolRegistry(log: Logger(label: "test.turnkey.dispatch"))
        await bootstrapBuiltInTools(registry: registry)
        let probePath = "/nonexistent/ocoreai-turnkey-probe"
        let baseline = await ToolAttemptLedger.shared.snapshot()
        _ = try? await registry.call(
            "read_file",
            arguments: #"{"path": "\#(probePath)"}"#,
            caller: "turnkey-test",
            headless: true,
            conversationKey: "conv-turnkey",
            turnToken: "turn-key-under-test")
        let mine =
            (await ToolAttemptLedger.shared.since(baseline, turnToken: "turn-key-under-test"))
            .filter { $0.tool == "read_file" && $0.target == probePath }
        #expect(mine.count == 1, "this dispatch, this key: \(mine.count)")
        #expect(mine.first?.turnToken == "turn-key-under-test")
    }

    /// The wiring the unit tests above cannot reach is the handler thread: both wire handlers
    /// mint one key per request and use it at every engine call and every `since`. A dropped
    /// argument there compiles green and silently reintroduces the 11-01 skew — so the scan
    /// floors its own premise against the call sites each file has.
    @Test func handlersThreadTheKeyThroughEveryAuditPath() throws {
        let chat = try readSource("Sources/ocoreai/Handlers/ChatHandler.swift")
        // 3 engine calls (main + correction stream + stream) and 4 keyed reads (2 finalize
        // sites × 2 ledgers) — each half of both functions; dropping one is the skew's return.
        #expect(occurrences(of: "turnToken: turnKey", in: chat) >= 7)
        #expect(occurrences(of: "let turnKey = UUID()", in: chat) >= 2)
        let anthropic = try readSource("Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift")
        // 2 engine calls + 4 keyed reads.
        #expect(occurrences(of: "turnToken: turnKey", in: anthropic) >= 6)
        #expect(occurrences(of: "let turnKey = UUID()", in: anthropic) >= 2)
        let registry = try readSource("Sources/ocoreai/Tools/ToolRegistry.swift")
        // 1 mutation record + 2 attempt records (success and failure paths).
        #expect(occurrences(of: "turnToken: turnToken", in: registry) >= 3)
        // The FM lane (macOS-27 runtime, compile-verified SDK-27 legs and locally): its proxies
        // forward the key through the dispatch closure; this text scan is the gate that runs
        // where the runtime does not. Verified by reading that no other lane is left: the
        // CoreAI/ANE engines hold no `ToolRegistry` reference at all — they never dispatch
        // in-process, so they produce no records to key.
        let fmBridge = try readSource("Sources/ocoreai/Engine/FMToolBridge.swift")
        #expect(occurrences(of: "turnToken: turnToken", in: fmBridge) >= 1)
        let inference = try readSource("Sources/ocoreai/Engine/EngineInference.swift")
        #expect(occurrences(of: "turnToken: turnToken", in: inference) >= 3)
    }
}
