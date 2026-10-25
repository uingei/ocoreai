// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// The audit needs the failure half of the record, and only the dispatch chokepoint can keep it.
///
/// `ToolMutationLedger` counted successes only, so a turn that fired `edit_file` five times and
/// hit nothing was indistinguishable, in the audit, from a turn that never touched a tool —
/// measured 2026-10-25 on the scoreboard, where the stable failures are exactly that shape.
/// Every assertion below is an exact value; the scans floor their own hit counts so a regex
/// that stopped matching fails the run instead of passing vacuously.

import Foundation
import Logging
import Testing

@testable import ocoreai

private func attemptRoot() -> URL {
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
    try String(contentsOf: attemptRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

private func attempt(
    _ tool: String,
    _ outcome: ToolAttempt.Outcome,
    isMutation: Bool = true,
    target: String? = nil,
    failure: String? = nil
) -> ToolAttempt {
    ToolAttempt(
        tool: tool, target: target, isMutation: isMutation, outcome: outcome, failure: failure)
}

@Suite("ToolAttemptLedger — failures are audited too", .serialized)
struct ToolAttemptLedgerTests {

    /// A failed writer with no later success is open; a repaired mistake is not.
    @Test func openFailuresResetOnAnySuccessfulWrite() {
        let none: [ToolAttempt] = []
        let noOpen = ToolAttemptLedger.unresolvedMutatingFailures(none)
        #expect(noOpen == 0)
        let allGood = ToolAttemptLedger.unresolvedMutatingFailures([
            attempt("write_file", .succeeded),
            attempt("read_file", .succeeded, isMutation: false),
        ])
        #expect(allGood == 0)
        let twoOpen = ToolAttemptLedger.unresolvedMutatingFailures([
            attempt("edit_file", .failed),
            attempt("edit_file", .failed),
        ])
        #expect(twoOpen == 2)
        let repaired = ToolAttemptLedger.unresolvedMutatingFailures([
            attempt("edit_file", .failed),
            attempt("edit_file", .failed),
            attempt("edit_file", .succeeded),
        ])
        #expect(repaired == 0)
        let openAfterRepair = ToolAttemptLedger.unresolvedMutatingFailures([
            attempt("edit_file", .failed),
            attempt("edit_file", .succeeded),
            attempt("edit_file", .failed),
        ])
        #expect(openAfterRepair == 1)
    }

    /// A read that failed is not an unfinished edit, however many times it failed.
    @Test func readOnlyFailuresNeverCountAsOpenEdits() {
        let reads = ToolAttemptLedger.unresolvedMutatingFailures([
            attempt("read_file", .failed, isMutation: false),
            attempt("search_files", .failed, isMutation: false),
        ])
        #expect(reads == 0)
    }

    /// The notice names attempts by tool and count, in first-seen order, capped at four tools.
    @Test func failureSummaryIsExact() {
        let named = ToolAttemptLedger.summarizeFailures([
            attempt("edit_file", .failed),
            attempt("exec_command", .failed),
            attempt("edit_file", .failed),
            attempt("read_file", .failed, isMutation: false),
            attempt("edit_file", .succeeded),
        ])
        #expect(named == "edit_file×2, exec_command×1")
        let empty = ToolAttemptLedger.summarizeFailures([attempt("edit_file", .succeeded)])
        #expect(empty == "")
        let capped = ToolAttemptLedger.summarizeFailures(
            ["a", "b", "c", "d", "e"].map { attempt($0, .failed) })
        #expect(capped == "a×1, b×1, c×1, d×1")
    }

    /// A denial or a refusal reaches the ledger as one redacted line, capped.
    ///
    /// Exact values: the line is what an audit row and a user-visible notice both quote, so
    /// "roughly the cause" is not a specification. Redaction runs before the cut, so a secret
    /// past the cap still cannot travel.
    @Test func failureLineIsOneRedactedCappedLine() throws {
        // The shape the handlers actually throw (`ToolError: Error, LocalizedError`);
        // `CustomStringConvertible` would not reach `localizedDescription` at all.
        struct Refusal: Error, LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let multi = Refusal(
            message: "edit_file: refused, secret: SUPERSECRET-1234\nsecond\nthird")
        let line = ToolRegistry.failureLine(of: multi)
        #expect(
            line == "edit_file: refused, secret: [REDACTED_SECRET]",
            "first line only, redacted: \(line)")
        let long = Refusal(message: String(repeating: "x", count: 400))
        let capped = ToolRegistry.failureLine(of: long)
        let expectedPrefix = String(repeating: "x", count: ToolAttemptLedger.failureLineLimit)
        #expect(capped == expectedPrefix + "…", "capped at the one limit: \(capped.count)")
        // 150 y's puts the assignment inside the cap: truncate-first would leak the prefix
        // `token=ABCDEFGHIJ` into the audit line, redact-first cannot.
        let secretNearCap = Refusal(
            message: String(repeating: "y", count: 150) + " token=ABCDEFGHIJKLMNOP")
        let cut = ToolRegistry.failureLine(of: secretNearCap)
        #expect(!cut.contains("ABCDEFGHIJKLMNOP"), "no secret past the cap: \(cut)")
        #expect(!cut.contains("token=ABCDEFGHIJ"), "no partial secret either: \(cut)")
    }

    /// Success and failure both reach the ledger at the one chokepoint, with the same
    /// mutating classification the mutation ledger uses.
    @Test func bothOutcomesAreFedAtTheChokepoint() throws {
        let registry = try readSource("Sources/ocoreai/Tools/ToolRegistry.swift")
        let feeds = occurrences(
            of: "await ToolAttemptLedger.shared.record(", in: registry)
        #expect(feeds == 2, "success + failure feed, saw \(feeds)")
        let failures = occurrences(of: "outcome: .failed", in: registry)
        #expect(failures == 1, "the failure path records, saw \(failures)")
        let successes = occurrences(of: "outcome: .succeeded", in: registry)
        #expect(successes == 1, "the success path records, saw \(successes)")
        let classifier = occurrences(
            of: "ToolMutationLedger.countsAsMutation(isReadOnly: isReadOnly(name))",
            in: registry)
        #expect(classifier >= 2, "one classifier serves both halves, saw \(classifier)")
    }

    /// Every face that judges a claim must see the failure half, or one face keeps saying
    /// "nothing was written" about a turn that tried.
    @Test func everyNoticeSitePassesAttempts() throws {
        var sites = 0
        for file in [
            "Sources/ocoreai/Handlers/ChatHandler.swift",
            "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift",
        ] {
            let text = try readSource(file)
            let calls = occurrences(of: "ClaimVsAudit.notice(", in: text)
            #expect(calls >= 2, "\(file) judges claims at \(calls) sites")
            let withAttempts = occurrences(of: "attempts: ", in: text)
            #expect(withAttempts >= calls, "\(file): \(withAttempts) of \(calls) pass attempts")
            sites += calls
        }
        #expect(sites == 4, "two faces x two modes, saw \(sites)")
    }

    /// "Files were changed." over open failed writes is a different lie than over silence.
    @Test func noticeNamesTheAttemptsItLeftBehind() {
        let attempts = [attempt("edit_file", .failed, target: "app.toml")]
        let line = ClaimVsAudit.notice(
            text: "Done. I updated the config file.", mutations: [], attempts: attempts)
        #expect(line != nil, "an over-claim over open failures must be answered")
        let text = line ?? ""
        #expect(text.contains("edit_file×1"), "names what was tried: \(text)")
        #expect(text.contains("none of them landed"), "says it did not land: \(text)")
        let silent = ClaimVsAudit.notice(
            text: "Done. I updated the config file.", mutations: [], attempts: [])
        let silentText = silent ?? ""
        let plain = silentText.contains("Nothing was written")
        #expect(plain, "no attempt, plain truth: \(silentText)")
        #expect(!silentText.contains("landed"), "no invented attempts: \(silentText)")
    }

    /// A repaired attempt is not an open problem, so the notice stays the plain one.
    @Test func repairedAttemptDoesNotSummonAnAttemptNotice() {
        let attempts = [
            attempt("edit_file", .failed),
            attempt("edit_file", .succeeded),
        ]
        let unresolved = ToolAttemptLedger.unresolvedMutatingFailures(attempts)
        #expect(unresolved == 0)
        let line = ClaimVsAudit.notice(
            text: "Done. I updated the config file.", mutations: [], attempts: attempts)
        let text = line ?? ""
        let plain = text.contains("Nothing was written")
        #expect(plain, "the mutation set is the whole story: \(text)")
    }

    /// The window is a bound, not a suggestion: 70 recorded leaves exactly 64 queryable.
    @Test func windowCapsTheRetainedRecord() async {
        let baseline = await ToolAttemptLedger.shared.snapshot()
        for _ in 0..<70 {
            await ToolAttemptLedger.shared.record(attempt("edit_file", .succeeded))
        }
        let kept = await ToolAttemptLedger.shared.since(baseline)
        #expect(kept.count == 64, "window holds 64, kept \(kept.count)")
        let total = await ToolAttemptLedger.shared.snapshot()
        let advanced = Int(total &- baseline)
        #expect(advanced == 70, "the count never drops a dispatch: \(advanced)")
    }

    /// The ledger is fed by `ToolRegistry.call`, so a dispatch through the registry is an
    /// attempt with the failure line the model actually received.
    @Test func dispatchedRefusalIsRecordedWithItsCause() async throws {
        let registry = ToolRegistry(log: Logger(label: "test.attemptledger"))
        await bootstrapBuiltInTools(registry: registry)
        let baseline = await ToolAttemptLedger.shared.snapshot()
        _ = try? await registry.call(
            "read_file",
            arguments: #"{"path": "/nonexistent/ocoreai-attempt-probe"}"#,
            caller: "attempt-ledger-test",
            headless: true)
        let attempts = await ToolAttemptLedger.shared.since(baseline)
        #expect(attempts.count == 1, "one dispatch, one record: \(attempts.count)")
        let first = attempts.first
        #expect(first?.tool == "read_file", "tool named: \(String(describing: first?.tool))")
        #expect(first?.isMutation == false, "a reader is not a writer")
        let outcome: ToolAttempt.Outcome? = first?.outcome
        #expect(outcome == .failed, "a missing path is a failed dispatch")
        #expect(
            first?.failure?.contains("read_file") == true,
            "the cause travels: \(String(describing: first?.failure))")
    }
}
