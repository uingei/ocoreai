// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EditMismatchRecoveryTests — an `edit_file` refusal has to be answerable.
///
/// Measured 10-22 (`scripts/eval/run.sh`, task `fix-off-by-one`): the model edited from an
/// assumption instead of a read, and the server answered
/// `edit_file: expected exactly 1 occurrence(s) of oldString in sum100.py, found 0 —
/// refusing partial edit` five times in one turn. Correct refusal, unrecoverable message:
/// nothing in it says what the file actually contains, so the retry was the same guess and
/// the task ended unmade. The fix quotes the nearest actual lines; the refusal itself stays
/// strict (a whitespace-tolerant apply would be a location guess).
///
/// `.serialized` because `SessionWorkspace` is a process-global (`NSLock`-guarded singleton,
/// not task-local): the `setDirectory`/`clear` in `seeded` leak into tests running in
/// parallel — measured 10-22 this suite failed 3/3 standalone, two tests resolving against
/// each other's temp dir. Same trait as `SessionWorkspaceWorktreeTests`.
import Foundation
import Testing

@testable import ocoreai

@Suite("edit_file — a refusal the model can act on", .serialized)
struct EditMismatchRecoveryTests {

    private func seeded(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_editrec_\(UUID().uuidString.prefix(8))")
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

    @Test("a miss quotes the file's real lines, with the numbering read_file uses")
    func mismatchQuotesActualLines() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("sum100.py", Self.sum100)
        defer { SessionWorkspace.clear() }

        do {
            // the model's guess: `range(1, n - 1)` is not what the file says
            _ = try FileTools.editFile(
                path: "sum100.py",
                oldString: "    for i in range(1, n - 1):",
                newString: "    for i in range(1, n + 1):")
            Issue.record("a non-matching oldString must not edit")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 0"), "still a strict refusal: \(message)")
            #expect(
                message.contains("3|    for i in range(1, n):"),
                "the refusal must show the actual line at its real number: \(message)")
            // Nearest-window scoring alone pointed at the wrong line on 10-22 (`return s` at
            // line 5), so a file this small is quoted whole — the target line cannot be hidden.
            #expect(
                message.contains("1|def total(n):"),
                "a small file is quoted whole so the target cannot be missed: \(message)")
            #expect(
                message.contains("quote exactly"),
                "and say what to do with it: \(message)")
        }
        // the file is untouched — the hint adds information, never a write
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == Self.sum100)
    }

    /// More indentation than the file has is a genuine miss (a shallower indent would be a
    /// real substring, which is why this case was rewritten: the first version of this test
    /// claimed a refusal for `"  return a +"` against a four-space line, and the tool was
    /// right to match it — the test was wrong, not the engine).
    @Test("deeper indentation than the file has is refused, and the real indent is quoted")
    func indentationDriftIsRefusedAndAnswered() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let body = "def add(a, b):\n    return a +\n"
        let url = try seeded("calc.py", body)
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.editFile(
                path: "calc.py",
                oldString: "        return a +",  // eight spaces where the file has four
                newString: "        return a + b")
            Issue.record("indentation the file does not have must not be guessed into a match")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 0"), "\(message)")
            #expect(
                message.contains("2|    return a +"),
                "the file's real indentation is what makes the next attempt succeed: \(message)")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == body, "a refusal never writes")
    }

    @Test(
        "a multi-match refusal names the knob that resolves it, and using it works",
        arguments: [3])
    func multiMatchRefusalNamesTheRemedy(n: Int) throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        // Measured 10-22: `edit-replace-all` scored 0/3. The model asked for exactly what the
        // tool can do (replace every FOO), got `found 3 — refusing partial edit`, and stopped:
        // the refusal named the count but never said occurrences is the parameter that accepts it.
        let body = "FOO bar\nbaz FOO\nFOO end\n"
        let url = try seeded("notes.md", body)
        do {
            _ = try FileTools.editFile(path: "notes.md", oldString: "FOO", newString: "BAR")
            Issue.record("a default of one must not silently rewrite three occurrences")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 3"), "strict refusal keeps the count: \(message)")
            #expect(
                message.contains("occurrences: 3"),
                "the refusal has to say what to pass next: \(message)")
            #expect(message.contains("refusing partial edit"), "the refusal stays strict")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == body, "a refusal never writes")

        let result = try FileTools.editFile(
            path: "notes.md", oldString: "FOO", newString: "BAR", occurrences: n)
        #expect(result.contains("3 replacement(s)"), "result was \(result)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "BAR bar\nbaz BAR\nBAR end\n")
    }
}
