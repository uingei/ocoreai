// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PresentationEchoGuardTests — our own tool-output chrome never passes as file content.
///
/// Measured on the task scoreboard (`scripts/eval/`, `copy-with-suffix`): read-then-write turns
/// produced the tool result they had been shown — `1|KERNEL-7-COPY` plus the `total_lines:` footer
/// — with the requested transformation applied inside the copy, and both tool calls reported `OK`.
/// Baseline over 13 attempts: 0 passes. Telling the model not to copy it (a sentence in the
/// footer) made the artefact bigger, because the sentence was copied too — so the fix has to sit
/// on the write, and it has to say what it did. These tests pin the ladder: detect, repair what is
/// provable, refuse to guess, and never quote a body into a tool result.
///
/// `.serialized` because `SessionWorkspace` is a process-global (see `EditMismatchRecoveryTests`).
import Foundation
import Testing

@testable import ocoreai

@Suite("PresentationEcho — read_file's display is not the file", .serialized)
struct PresentationEchoGuardTests {

    /// The artefact a failing `copy-with-suffix` turn left on disk, byte for byte.
    private static let measured =
        "1|KERNEL-7-COPY\n─── total_lines: 1 (full) ───\n[System Perception]"

    private func workspace(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_echo_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionWorkspace.setDirectory(dir.path)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - detection

    @Test("the measured artefact is named exactly, one finding per family")
    func measuredArtefactIsNamedExactly() {
        #expect(
            PresentationEcho.findings(in: Self.measured)
                == [
                    PresentationEcho.Finding(artifact: .numberedLines, line: 1),
                    PresentationEcho.Finding(artifact: .readFooter, line: 2),
                    PresentationEcho.Finding(artifact: .perceptionHeader, line: 3),
                ],
            "numbering is corroborated here by the chrome beside it: \(PresentationEcho.findings(in: Self.measured))"
        )
    }

    @Test("clean content yields nothing to report and nothing to strip")
    func cleanContentIsUntouched() {
        let repair = PresentationEcho.repair("KERNEL-7-COPY\n")
        #expect(PresentationEcho.findings(in: "KERNEL-7-COPY\n") == [])
        #expect(repair.text == "KERNEL-7-COPY\n")
        #expect(repair.removed == [])
        #expect(!repair.didRepair)
        #expect(PresentationEcho.suffix(repair) == "")
    }

    @Test("an integer column that skips a number is a table, not a read dump")
    func integerColumnTableIsNotAnEcho() {
        let table = "1|alpha|10\n3|beta|20\n7|gamma|5\n"
        #expect(PresentationEcho.findings(in: table) == [])
        #expect(PresentationEcho.repair(table).text == table)
    }

    @Test("quoting the footer label without this repo's box-drawing rule is not a footer")
    func quotedLabelIsNotAFooter() {
        // The literal this repo's own tests write about `read_file`; accusing it would mean the
        // guard condemns the code that documents the footer.
        let quoting = "XCTAssert(out.contains(\"total_lines: 3 (full)\"))"
        #expect(PresentationEcho.findings(in: quoting) == [])
    }

    @Test("a windowed footer echo is caught on its own line")
    func windowFooterIsFound() {
        let payload = "name = x\n─── total_lines: 42 (window 10–20; continue at offset=21) ───"
        #expect(
            PresentationEcho.findings(in: payload)
                == [PresentationEcho.Finding(artifact: .readFooter, line: 2)])
    }

    // MARK: - repair

    @Test("the measured artefact comes back as the content the task asked for")
    func measuredArtefactIsRepaired() {
        let repair = PresentationEcho.repair(Self.measured)
        #expect(repair.text == "KERNEL-7-COPY")
        #expect(
            repair.removed
                == [
                    PresentationEcho.Finding(artifact: .numberedLines, line: 1),
                    PresentationEcho.Finding(artifact: .readFooter, line: 2),
                    PresentationEcho.Finding(artifact: .perceptionHeader, line: 3),
                ])
        #expect(repair.remaining == [])
    }

    @Test("corroborated numbering is stripped from every line, trailing newline preserved")
    func numberedDumpIsStrippedLineByLine() {
        let dump = "1|def total(n):\n2|    s = 0\n3|    return s\n"
        let repair = PresentationEcho.repair(dump)
        #expect(repair.text == "def total(n):\n    s = 0\n    return s\n")
        #expect(repair.removed == [PresentationEcho.Finding(artifact: .numberedLines, line: 1)])
    }

    @Test("chrome that is the whole payload is never stripped — that would be a guess")
    func chromeOnlyPayloadIsNotRepaired() {
        let onlyChrome = "─── total_lines: 1 (full) ───\n"
        let repair = PresentationEcho.repair(onlyChrome)
        #expect(repair.text == onlyChrome)
        #expect(!repair.didRepair)
        #expect(repair.remaining == [PresentationEcho.Finding(artifact: .readFooter, line: 1)])
        #expect(PresentationEcho.suffix(repair).contains("whole payload"))
    }

    @Test("the verdict names patterns and lines, and quotes no file body")
    func suffixCarriesFactsNotBody() {
        let suffix = PresentationEcho.suffix(PresentationEcho.repair(Self.measured))
        #expect(
            suffix.contains(
                "presentation-echo repaired: stripped N| line numbers at line 1, "
                    + "total_lines footer at line 2, [System Perception] channel header at line 3"),
            "the report must be exact about what it removed: \(suffix)")
        #expect(!suffix.contains("KERNEL-7"), "a tool result is not where a body gets quoted")
    }

    // MARK: - the write tools

    @Test("write_file lands clean bytes and says it repaired the payload")
    func writeFileStripsChromeAndSaysSo() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let dir = try workspace("src.txt", "KERNEL-7\n").deletingLastPathComponent()
        defer { SessionWorkspace.clear() }

        let out = try FileTools.write(path: "copy.txt", content: Self.measured)
        #expect(out.contains("write_file: OK-but-repaired"), "\(out)")
        #expect(out.contains("read-back verified"), "durability is still proven: \(out)")
        #expect(out.contains("presentation-echo repaired"))
        #expect(
            try String(contentsOf: dir.appendingPathComponent("copy.txt"), encoding: .utf8)
                == "KERNEL-7-COPY")
        #expect(
            try String(contentsOf: dir.appendingPathComponent("src.txt"), encoding: .utf8)
                == "KERNEL-7\n")
    }

    @Test("a clean write keeps saying plain OK")
    func cleanWriteIsPlainOK() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try workspace("src.txt", "KERNEL-7\n")
        defer { SessionWorkspace.clear() }

        let out = try FileTools.write(path: "copy.txt", content: "KERNEL-7-COPY\n")
        #expect(out.contains("write_file: OK —"), "no chrome, no verdict: \(out)")
        #expect(!out.contains("OK-but-invalid"))
        #expect(!out.contains("presentation-echo"))
    }

    @Test("unrepairable chrome still lands, and comes back OK-but-invalid")
    func unrepairableChromeLandsFlagged() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try workspace("src.txt", "KERNEL-7\n")
        defer { SessionWorkspace.clear() }

        let payload = "─── total_lines: 1 (full) ───\n"
        let out = try FileTools.write(path: "chrome.txt", content: payload)
        #expect(out.contains("write_file: OK-but-invalid"), "\(out)")
        #expect(out.contains("read-back verified"))
    }

    @Test("edit_file repairs a replacement carrying echoed chrome")
    func editFileRepairsReplacement() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try workspace("note.txt", "KERNEL-7\n")
        defer { SessionWorkspace.clear() }

        let out = try FileTools.editFile(
            path: "note.txt",
            oldString: "KERNEL-7",
            newString: "1|KERNEL-7-COPY\n─── total_lines: 1 (full) ───")
        #expect(out.contains("edit_file: OK-but-repaired"), "\(out)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "KERNEL-7-COPY\n")
    }

    @Test("chrome already in the file does not condemn an unrelated edit")
    func judgeSuppliedTextNotTheFile() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try workspace("log.txt", "name = x\n─── total_lines: 1 (full) ───\nstale = 1\n")
        defer { SessionWorkspace.clear() }

        let out = try FileTools.editLines(
            path: "log.txt", startLine: 3, endLine: 3, newText: "live = 1")
        #expect(out.contains("edit_lines: OK —"), "only this call's text is judged: \(out)")
        #expect(!out.contains("presentation-echo"))
    }

    // MARK: - the surfaces this guard depends on

    @Test("the footer carries exactly the contract the read tests pin")
    func footerKeepsItsContract() {
        #expect(
            FileTools.presentationFooter(total: 3, start: 1, end: 3)
                == "─── total_lines: 3 (full) ───",
            "prose in read output gets copied into files (measured), so the footer stays bare")
        #expect(
            FileTools.presentationFooter(total: 9, start: 4, end: 6)
                .contains("total_lines: 9 (window 4–6; continue at offset=7)"))
    }

    @Test("no channel delivered a frame, so nothing is injected")
    func emptyChannelDeliversNoHeader() {
        #expect(PerceptionEngine.renderContext([]) == "")
        #expect(
            PerceptionEngine.renderContext([(label: "audio", value: "hello")])
                == "[System Perception], audio=hello")
    }
}
