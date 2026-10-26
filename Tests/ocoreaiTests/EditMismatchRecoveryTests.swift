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
import Logging
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

    @Test("a miss quotes the file's real lines, as text the caller can copy verbatim")
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
                message.contains("    for i in range(1, n):"),
                "the refusal must show the actual line, indentation and all: \(message)")
            // Nearest-window scoring alone pointed at the wrong line on 10-22 (`return s` at
            // line 5), so a file this small is quoted whole — the target line cannot be hidden.
            #expect(
                message.contains("def total(n):"),
                "a small file is quoted whole so the target cannot be missed: \(message)")
            #expect(
                message.contains("verbatim"),
                "and say what to do with it: \(message)")
            // The quoted body must be copyable as-is: `read_file`'s `N|` prefixes in a message
            // that says "quote verbatim" is a guaranteed miss on the next call, and §
            // PresentationEcho measured that a sentence asking the model to drop them does not
            // work. Position stays in labels ("all N lines", "[lines a-b of N]").
            #expect(
                !message.contains("1|def total(n):"),
                "a hint that says verbatim may not hand back chrome: \(message)")
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
                message.contains("    return a +"),
                "the file's real indentation is what makes the next attempt succeed: \(message)")
            #expect(
                !message.contains("2|    return a +"),
                "quotable means quotable: \(message)")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == body, "a refusal never writes")
    }

    @Test(
        "a multi-match refusal names the knob that resolves it, and using it works",
        arguments: [3])
    func multiMatchRefusalNamesTheRemedy(n: Int) throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        // Measured 10-22 (two rounds): `edit-replace-all` was 0/3 with a bare count in the
        // refusal, and stayed 0/3 after naming `occurrences: 3` — the model read the count and
        // answered the *user* ("please specify how many occurrences you intended") instead of
        // retrying. So the refusal now names the conventional knob first and says out loud
        // that resolving it is this call's job, not the user's.
        let body = "FOO bar\nbaz FOO\nFOO end\n"
        let url = try seeded("notes.md", body)
        do {
            _ = try FileTools.editFile(path: "notes.md", oldString: "FOO", newString: "BAR")
            Issue.record("a default of one must not silently rewrite three occurrences")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 3"), "strict refusal keeps the count: \(message)")
            #expect(
                message.contains("replace_all: true"),
                "the conventional knob has to be named: \(message)")
            #expect(
                message.contains("occurrences: 3"),
                "and the exact count, for a caller that prefers to be explicit: \(message)")
            // the measured failure was escalating to the user; the refusal closes that door
            #expect(
                message.contains("do not ask the user"),
                "the refusal must resolve itself, not bounce to the human: \(message)")
            #expect(message.contains("refusing partial edit"), "the refusal stays strict")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == body, "a refusal never writes")

        let result = try FileTools.editFile(
            path: "notes.md", oldString: "FOO", newString: "BAR", occurrences: n)
        #expect(result.contains("3 replacement(s)"), "result was \(result)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "BAR bar\nbaz BAR\nBAR end\n")
    }

    /// `replace_all` states the intent without making the caller count: it cannot be wrong
    /// about N, which is the failure the count-based knob kept hitting.
    @Test("replace_all rewrites every occurrence without the caller naming a count")
    func replaceAllNeedsNoCount() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "FOO bar\nbaz FOO\nFOO end\n")

        let result = try FileTools.editFile(
            path: "notes.md", oldString: "FOO", newString: "BAR", replaceAll: true)
        #expect(result.contains("3 replacement(s)"), "result was \(result)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "BAR bar\nbaz BAR\nBAR end\n")

        // replace_all on a miss is still a refusal, and still says what to do about it
        do {
            _ = try FileTools.editFile(
                path: "notes.md", oldString: "nope", newString: "x", replaceAll: true)
            Issue.record("replace_all must not invent a match")
        } catch let ToolError.invalidParameter(message) {
            #expect(
                message.contains("read_file"),
                "a miss still names the recovery: \(message)")
        }
    }

    /// The wire name is what the model actually sends. Decoding here is the difference
    /// between "the Swift API supports it" and "a tool call from a model reaches it"
    /// (AGENTS.md: a knob the wire accepts must reach the engine).
    @Test("a model's {replace_all: true} tool call decodes and dispatches")
    func wireKnobReachesTheEngine() async throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("notes.md", "FOO bar\nbaz FOO\nFOO end\n")

        let registry = ToolRegistry(log: Logger(label: "test.editall"))
        await bootstrapBuiltInTools(registry: registry)
        #expect(await registry.schema(for: "edit_file")?.parameters["replace_all"] != nil)

        let out = try await registry.call(
            "edit_file",
            arguments:
                #"{"path":"notes.md","oldString":"FOO","newString":"BAR","replace_all":true}"#,
            caller: "test",
            headless: true)
        #expect(out.contains("3 replacement(s)"), "dispatch said: \(out)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "BAR bar\nbaz BAR\nBAR end\n")
    }

    /// A quoted window that gets clipped has to say so and say how big the file is — codex
    /// `format_exec_output_for_model` publishes `Total output lines` whenever it shows less
    /// than it has. A silent clip can drop the exact line the caller needed.
    @Test("a clipped hint states the file's real size instead of trailing off")
    func clippedHintStatesTotals() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        var lines: [String] = []
        for i in 0 ..< 120 {
            lines.append(
                "let value_\(i) = \"some fairly long filler text to push past the hint limit\"")
        }
        lines[60] = "let target = compute(a, b)"
        let url = try seeded("big.swift", lines.joined(separator: "\n"))

        do {
            _ = try FileTools.editFile(
                path: "big.swift",
                oldString: "let target = compute(a, c)",
                newString: "let target = compute(a, b)")
            Issue.record("a near-miss must not edit")
        } catch let ToolError.invalidParameter(message) {
            #expect(
                message.contains("of 120 lines"),
                "the hint must state the whole while showing a part: \(message)")
            #expect(
                message.contains("let target = compute(a, b)"),
                "and it must reach the line the caller was aiming at: \(message)")
            #expect(
                !message.contains("61|let target"),
                "the number belongs to the label, not the quoted text: \(message)")
            #expect(message.contains("read_file"), "and name how to see the rest: \(message)")
            #expect(
                !message.contains("Retry this call now"),
                "a window must not order a retry whose line it may have clipped: \(message)")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == lines.joined(separator: "\n"))
    }

    /// The scoreboard shape this contract came from: `fix-boundary-comparison` quoted a
    /// `capacity.py` line that did not exist, the refusal printed the two-line file whole —
    /// with the caller's own `newString` already correct — and the turn ended at "I need to
    /// read the file first". The data was there; the next action was not. So a refusal that
    /// quoted everything names the retry and closes the exit that loses the task.
    @Test("a whole-file quote orders the retry instead of a round trip it already served")
    func wholeFileQuoteOrdersTheRetry() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded(
            "capacity.py", "def fits(load, limit):\n    return load < limit\n")
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.editFile(
                path: "capacity.py",
                oldString: "return load == limit",
                newString: "return load <= limit")
            Issue.record("a non-matching oldString must not edit")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 0"), "the refusal stays strict: \(message)")
            #expect(
                message.contains("all 2 lines") && message.contains("return load < limit"),
                "the whole file is in the message: \(message)")
            #expect(
                message.contains("Retry this call now"),
                "and the next action is named: \(message)")
            #expect(
                message.contains("Do not answer the user before that retry"),
                "the give-up exit is closed: \(message)")
            #expect(
                !message.contains("exec_command"),
                "a replacement intent is never nudged toward rm: \(message)")
            #expect(
                !message.contains("read_file it"),
                "no round trip may be ordered for a file already quoted whole: \(message)")
        }
        let untouched = try String(contentsOf: url, encoding: .utf8)
        #expect(
            untouched == "def fits(load, limit):\n    return load < limit\n",
            "a refusal never writes")
    }

    /// The failure shape the scoreboard's `fix-*` tasks actually hit: the caller quoted
    /// `read_file` faithfully — chrome and all — and the raw count came back 0. Stripping is
    /// decided by the match itself (attempted only after a raw miss, accepted only when the
    /// stripped string matches `expected`), and the verdict says out loud that it happened.
    @Test("a quote copied from read_file is stripped to match, and says so")
    func copiedReadChromeIsStrippedToMatch() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let body = "def first_n(items, n):\n    return items[0:n - 1]\n"
        let url = try seeded("page.py", body)
        defer { SessionWorkspace.clear() }

        let ok = try FileTools.editFile(
            path: "page.py",
            oldString: "1|def first_n(items, n):\n2|    return items[0:n - 1]",
            newString: "def first_n(items, n):\n    return items[0:n]",
            occurrences: 1)
        #expect(ok.contains("OK"), "a faithful quote must not be lost: \(ok)")
        #expect(ok.contains("1 replacement(s)"), "\(ok)")
        #expect(ok.contains("oldString carried read_file chrome"), "never silent: \(ok)")
        #expect(
            try String(contentsOf: url, encoding: .utf8)
                == "def first_n(items, n):\n    return items[0:n]\n")
    }

    /// The false-positive floor: `1|alpha` is legitimate content in a pipe-delimited file, so a
    /// raw match is never second-guessed and no repair is claimed.
    @Test("genuine pipe-delimited content matches raw and is never called chrome")
    func pipeDelimitedContentMatchesRaw() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let body = "1|alpha\n2|beta\n"
        let url = try seeded("table.txt", body)
        defer { SessionWorkspace.clear() }

        let ok = try FileTools.editFile(
            path: "table.txt", oldString: "1|alpha", newString: "1|ALPHA", occurrences: 1)
        #expect(ok.contains("1 replacement(s)"), "\(ok)")
        #expect(!ok.contains("chrome"), "a raw match is not a repair: \(ok)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "1|ALPHA\n2|beta\n")
    }

    /// Reproduced from the scoreboard, not imagined: `delete-only-what-was-asked` aimed an
    /// `edit_file` with an empty `newString` (the caller's own deletion intent) at a file whose
    /// one line it had not read, was refused with that line quoted whole, and answered the user
    /// asking for exactly that line. `edit_file` can empty a file and no file tool deletes one,
    /// so the refusal has to say which route exists — or the turn dies on a two-line file.
    @Test("an empty newString names the removal route the retry cannot be")
    func deletionIntentNamesTheRemovalRoute() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("stale.log", "old\n")
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.editFile(
                path: "stale.log", oldString: "stale lock entry", newString: "")
            Issue.record("a non-matching oldString must not edit")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 0"), "still strict: \(message)")
            #expect(
                message.contains("exec_command") && message.contains("rm stale.log"),
                "removal intent gets the route that exists: \(message)")
        }
        #expect(
            try String(contentsOf: url, encoding: .utf8) == "old\n",
            "naming a route must not delete anything by itself")
    }

}
