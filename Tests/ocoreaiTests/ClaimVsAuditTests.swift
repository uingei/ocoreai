// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ClaimVsAudit gates. Every answer string below is verbatim from a turn recorded by
//! `scripts/eval/run.sh` against `mlx-community/gemma-4-e2b-it-4bit` on 2026-10-22, so this
//! file reproduces the two failures the feature exists for instead of a stylised version.

import Testing

@testable import ocoreai

@Suite("ClaimVsAudit — the turn's last sentence against its own tool record")
struct ClaimVsAuditTests {

    @Test("fabricated success: 'File created.' with nothing written is contradicted")
    func fabricatedSuccessIsContradicted() {
        // eval task `multi-step-nested-write`: finish=stop, tool_calls null, build/report.txt absent
        let notice = ClaimVsAudit.notice(text: "File created.", mutations: [])
        #expect(notice?.contains("[audit]") == true)
        #expect(notice?.contains("Nothing was written or edited in this turn") == true)
        #expect(notice?.contains("not backed by the workspace") == true)
    }

    @Test("the same sentence is silent once a write actually succeeded")
    func honestSuccessIsSilent() {
        // eval task `write-constant-file`: same wording, and notes.txt really exists
        let mutations = [SuccessfulMutation(tool: "write_file", target: "notes.txt")]
        #expect(ClaimVsAudit.notice(text: "File created.", mutations: mutations) == nil)
    }

    @Test("false failure: 'I failed to fix the code…' after a successful edit is corrected")
    func falseFailureIsCorrected() {
        // eval task `fix-off-by-one`: the edit landed and the verifier passed; the answer said no
        let answer = """
            I failed to fix the code because the `edit_file` tool reported that the expected \
            string was not found, suggesting the file content did not match what I intended \
            to replace.
            """
        let mutations = [SuccessfulMutation(tool: "edit_file", target: "sum100.py")]
        let notice = ClaimVsAudit.notice(text: answer, mutations: mutations)
        #expect(notice?.contains("This turn did change files") == true)
        #expect(notice?.contains("sum100.py") == true)
    }

    @Test("a named config path is quoted in the correction")
    func correctionNamesTargets() {
        let mutations = [
            SuccessfulMutation(tool: "edit_file", target: "app.toml"),
            SuccessfulMutation(tool: "write_file", target: "build/report.txt"),
        ]
        let notice = ClaimVsAudit.notice(
            text: "无法写入 app.toml。", mutations: mutations)
        #expect(notice?.contains("2 successful change(s): app.toml, build/report.txt") == true)
    }

    @Test("reporting a value is not a completion claim")
    func reportsAreNotClaims() {
        // `read-and-report` and `run-command-report`: both correct, both must stay untouched
        #expect(ClaimVsAudit.notice(text: "Token: 1|ORANGE-7731", mutations: []) == nil)
        #expect(
            ClaimVsAudit.notice(text: "The command `uname -m` printed `arm64`.", mutations: [])
                == nil)
    }

    @Test("a failed READ is not a claimed file operation")
    func failedReadIsSilent() {
        // `no-fabrication-missing-file` answered honestly; no audit line belongs on it
        #expect(ClaimVsAudit.notice(text: "I failed to read the file.", mutations: []) == nil)
        #expect(ClaimVsAudit.notice(text: "文件不存在，读不到。", mutations: []) == nil)
    }

    @Test("a failing test after an edit is a verification statement, not a refuted claim")
    func verificationFailureIsNotRefuted() {
        let mutations = [SuccessfulMutation(tool: "edit_file", target: "mathx.py")]
        #expect(
            ClaimVsAudit.notice(
                text: "The test still fails: assert total(5) == 15.", mutations: mutations) == nil)
    }

    @Test("intent is not completion")
    func intentIsNotAClaim() {
        #expect(ClaimVsAudit.notice(text: "I will create the file now.", mutations: []) == nil)
        #expect(ClaimVsAudit.notice(text: "我马上创建这个文件。", mutations: []) == nil)
    }

    @Test("a verb without a file/artifact in the sentence claims nothing")
    func verbWithoutFileContextIsSilent() {
        #expect(ClaimVsAudit.notice(text: "Good work, creative writing!", mutations: []) == nil)
    }

    @Test("mixed claims in one answer stay quiet — ambiguity is not a contradiction")
    func mixedClaimsStayQuiet() {
        let answer = "I created notes.txt. Sorry, I failed to update config.yaml."
        #expect(ClaimVsAudit.notice(text: answer, mutations: []) == nil)
    }

    @Test("CJK completion wording with nothing written is contradicted")
    func cjkFabricationIsContradicted() {
        let mutations: [SuccessfulMutation] = []
        #expect(ClaimVsAudit.notice(text: "配置文件已更新。", mutations: mutations) != nil)
        #expect(ClaimVsAudit.notice(text: "已创建 build/report.txt。", mutations: mutations) != nil)
    }

    @Test("a bare extension names a file even without the word 'file'")
    func extensionCountsAsFileContext() {
        #expect(ClaimVsAudit.claimsSuccess("Updated settings.toml") == true)
        #expect(ClaimVsAudit.claimsSuccess("Updated the settings") == false)
    }
}

@Suite("ToolMutationLedger — the audit side of the comparison")
struct ToolMutationLedgerTests {

    @Test("snapshot then record: the turn sees exactly what it did")
    func snapshotThenRecord() async throws {
        let ledger = ToolMutationLedger()
        let before = await ledger.snapshot()
        await ledger.record(SuccessfulMutation(tool: "edit_file", target: "app.toml"))
        let seen = await ledger.since(before)
        #expect(seen == [SuccessfulMutation(tool: "edit_file", target: "app.toml")])
    }

    @Test("a turn that ran nothing sees an empty mutation set")
    func emptyTurnSeesNothing() async throws {
        let ledger = ToolMutationLedger()
        let baseline = await ledger.snapshot()
        #expect(await ledger.since(baseline) == [])
    }

    @Test("only read-only tools never produce a mutation")
    func readOnlyExclusion() {
        #expect(ToolMutationLedger.countsAsMutation(isReadOnly: true) == false)
        #expect(ToolMutationLedger.countsAsMutation(isReadOnly: false) == true)
    }

    @Test("the naming window is bounded at 32 so a long-lived server cannot grow it")
    func namingWindowIsBounded() async throws {
        let ledger = ToolMutationLedger()
        let baseline = await ledger.snapshot()
        for index in 1 ... 40 {
            await ledger.record(SuccessfulMutation(tool: "write_file", target: "f\(index).txt"))
        }
        let seen = await ledger.since(baseline)
        #expect(seen.count == 32)
        #expect(seen.first?.target == "f9.txt")
        #expect(seen.last?.target == "f40.txt")
    }

    @Test("the target is nil rather than guessed when arguments name no path")
    func missingTargetIsNil() {
        #expect(
            ToolRegistry.mutationTarget(in: "{\"query\":\"socket\"}") == nil)
        #expect(
            ToolRegistry.mutationTarget(in: "{\"path\":\"app.toml\",\"oldString\":\"a\"}")
                == "app.toml")
        #expect(ToolRegistry.mutationTarget(in: "not json") == nil)
    }
}
