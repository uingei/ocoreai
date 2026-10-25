// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EditLinesContractTests — the seam that answers with line numbers instead of bytes.
///
/// `edit_file` refuses when `oldString` is not byte-exact, and the scoreboard's repair tasks die
/// there: measured over the k=3 baseline of `scripts/eval/tasks-edit-repair.json`, the model
/// retries the same guess until the turn ends, even
/// though the refusal quotes the file with `N|` numbers. `edit_lines` takes those numbers back as
/// input, so the thing the model already knows (which lines) is the thing the tool asks for.
/// These tests pin the range semantics, the shared numbering, and the wire spelling.
///
/// `.serialized` because `SessionWorkspace` is a process-global (see `EditMismatchRecoveryTests`).
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("edit_lines — line ranges, one numbering, read-back verified", .serialized)
struct EditLinesContractTests {

    private func seeded(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_editlines_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionWorkspace.setDirectory(dir.path)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let sum100 = """
        def total(n):
            s = 0
            for i in range(1, n):
                s += i
        return s

        """

    @Test("the numbering edit_lines accepts is the numbering read_file prints")
    func numberingHasOneHome() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        _ = try seeded("sum100.py", Self.sum100)
        defer { SessionWorkspace.clear() }

        let shown = try FileTools.read(path: "sum100.py")
        let counted = FileTools.numberedContentLines(Self.sum100)
        #expect(counted.count == 5, "a file ending in a newline has 5 content lines: \(counted)")
        #expect(
            shown.contains("total_lines: 5"),
            "read_file's own count must equal the helper's: \(shown)")
        #expect(shown.contains("3|    for i in range(1, n):"), "line 3 is the buggy line: \(shown)")
    }

    @Test("rewriting exactly the line read_file numbered 3 fixes the off-by-one")
    func replacesOneNumberedLine() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("sum100.py", Self.sum100)
        defer { SessionWorkspace.clear() }

        let out = try FileTools.editLines(
            path: "sum100.py",
            startLine: 3,
            endLine: 3,
            newText: "    for i in range(1, n + 1):")
        #expect(
            out.contains("replaced lines 3-3 (1) with 1"),
            "the verdict must name the range it applied: \(out)")
        #expect(out.contains("read-back verified"), "\(out)")
        let fixed =
            "def total(n):\n    s = 0\n    for i in range(1, n + 1):\n        s += i\nreturn s\n"
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == fixed, "byte-exact result expected, got: \(onDisk.debugDescription)")
    }

    @Test("end_line == start_line - 1 inserts without deleting anything")
    func insertsWithoutDeleting() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "one\nthree\n")
        defer { SessionWorkspace.clear() }

        let out = try FileTools.editLines(
            path: "notes.md", startLine: 2, endLine: 1, newText: "two")
        #expect(out.contains("inserted 1 line(s) before line 2 of 2"), "\(out)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\nthree\n")
    }

    @Test("start_line total+1 appends at end of file and keeps the trailing newline")
    func appendsAtEOF() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "one\ntwo\n")
        defer { SessionWorkspace.clear() }

        let out = try FileTools.editLines(
            path: "notes.md", startLine: 3, endLine: 2, newText: "three\nfour")
        #expect(out.contains("inserted 2 line(s) before line 3 of 2"), "\(out)")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "one\ntwo\nthree\nfour\n", "byte-exact append expected: \(onDisk)")
    }

    @Test("empty new_text deletes the range")
    func deletesRange() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "keep\ndrop1\ndrop2\nkeep2\n")
        defer { SessionWorkspace.clear() }

        let out = try FileTools.editLines(
            path: "notes.md", startLine: 2, endLine: 3, newText: "")
        #expect(out.contains("deleted 2 line(s) 2-3 of 4"), "\(out)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep\nkeep2\n")
    }

    @Test("a range outside the file is refused and names the file's real line count")
    func outOfRangeNamesTheBound() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "a\nb\nc\n")
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.editLines(
                path: "notes.md", startLine: 99, endLine: 99, newText: "x")
            Issue.record("an out-of-range start_line must not edit")
        } catch let ToolError.invalidParameter(message) {
            #expect(
                message.contains("outside 1...4") && message.contains("3 lines"),
                "the refusal must carry the bound and the count: \(message)")
            #expect(
                message.contains("do not answer the user before that retry"),
                "a refusal stating the range sends the retry before the answer: \(message)")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\nb\nc\n", "refusal never writes")
    }

    @Test("rewriting a range into what it already says is a refused no-op")
    func noOpIsRefused() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "a\nb\nc\n")
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.editLines(
                path: "notes.md", startLine: 1, endLine: 2, newText: "a\nb")
            Issue.record("a no-op range must be refused, not reported as work done")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("no-op"), "\(message)")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\nb\nc\n")
    }

    @Test("the wire accepts snake_case and it reaches the engine")
    func wireSnakeCaseReachesTheEngine() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "old-one\nold-two\nkeep\n")
        defer { SessionWorkspace.clear() }

        let registry = ToolRegistry(log: Logger(label: "test.editlines"))
        await bootstrapBuiltInTools(registry: registry)
        let schema = await registry.schema(for: "edit_lines")
        #expect(schema?.parameters["start_line"] != nil, "start_line must be on the schema")
        #expect(schema?.parameters["new_text"] != nil, "new_text must be on the schema")

        let out = try await registry.call(
            "edit_lines",
            arguments:
                #"{"path":"notes.md","start_line":1,"end_line":2,"new_text":"new-one"}"#,
            caller: "test",
            headless: true)
        #expect(out.contains("read-back verified"), "\(out)")
        #expect(
            try String(contentsOf: url, encoding: .utf8) == "new-one\nkeep\n",
            "snake_case arguments must reach the same seam as the Swift API")
    }
}
