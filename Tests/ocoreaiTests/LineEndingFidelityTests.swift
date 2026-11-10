// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LineEndingFidelityTests — an edit writes the bytes the caller named and no others.
///
/// `read_file` renders a file's lines with `\r` stripped (`FileTools.numberedContentLines`), so the
/// only text a caller can copy off it is LF. Both write seams then worked on the file's raw bytes:
/// `edit_file` matched a multi-line quote against them, so on a CRLF file a *correct* quote answered
/// `found 0` — and the retry the refusal neighbour suite owns reproduces the same miss, because the
/// caller has no other view of the file. `edit_lines` was worse: it rebuilt the file from the
/// stripped view, so editing line 2 rewrote every line ending in the file and returned OK naming a
/// byte delta nobody asked for (invariant 2: the surface may not claim more than the engine did).
///
/// The field lands one rule here, not a flatten: pi splices each replacement back into the original
/// text — "text outside the replaced ranges keeps its bytes, including its line endings"
/// (pi d448c51e, #11751); opencode matches "the LF view Read shows the model, then maps offsets back
/// to the source, so CRLF and mixed line endings neither block matches nor leak into untouched
/// regions" (`packages/core/src/tool/plugin/edit.ts:165-188`); codex keeps a per-line ending with the
/// first one preferred for inserted lines (`codex-rs/apply-patch/src/text_file.rs:19-33`).
/// qwen-code normalizes the whole file to one ending instead (`packages/core/src/tools/edit.ts:269`)
/// — the flatten pi's commit removes.
///
/// `.serialized` + the workspace lease for the same reason as `EditMismatchRecoveryTests`:
/// `SessionWorkspace` is a process-global, and a lease never spans live I/O.
import Foundation
import Testing

@testable import ocoreai

@Suite("line endings — the file's own endings survive an edit", .serialized)
struct LineEndingFidelityTests {

    /// A frozen pair: the bytes on disk, the caller's text, the bytes required back, and the phrase
    /// the result owes about what it did to the endings (`""` when it owes none — `PresentationEcho`
    /// names CRLF for its own reasons, so the assertion is on this seam's phrase, not the word).
    struct Pair: Sendable {
        let label: String
        let seed: String
        let oldText: String
        let newText: String
        let expected: String
        let note: String
        var replaceAll: Bool = false
    }

    /// The two phrases `edit_file` may add, and nothing else.
    private static let viewNote = "matched the LF view"
    private static let reendedNote = "wrote the new lines with the file's CRLF endings"

    private func seeded(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_eol_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionWorkspace.setDirectory(dir.path)
        let url = dir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    /// Bytes, never a decoded String: a claim about `\r` cannot be read off a value that has already
    /// been through the caller's own decoder.
    private func bytes(_ url: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: url, options: .uncached))
    }

    private static let cases: [Pair] = [
        Pair(
            label: "CRLF file, the LF quote read_file shows",
            seed: "a\r\nb\r\nc\r\n", oldText: "a\nb\n", newText: "a\nX\n",
            expected: "a\r\nX\r\nc\r\n", note: viewNote),
        Pair(
            label: "CRLF file with no trailing newline",
            seed: "a\r\nb\r\nc", oldText: "b\nc", newText: "B\nc",
            expected: "a\r\nB\r\nc", note: viewNote),
        Pair(
            label: "an LF file is untouched by the rule",
            seed: "a\nb\nc\n", oldText: "a\nb\n", newText: "a\nX\n",
            expected: "a\nX\nc\n", note: ""),
        Pair(
            label: "mixed endings: each untouched line keeps its own",
            seed: "a\nb\r\nc\n", oldText: "b\nc", newText: "B\nC",
            expected: "a\nB\r\nC\n", note: viewNote),
        Pair(
            label: "an exact CRLF quote still matches, and never doubles the CR",
            seed: "a\r\nb\r\n", oldText: "a\r\nb", newText: "a\r\nB",
            expected: "a\r\nB\r\n", note: ""),
        Pair(
            label: "a newline the caller wrote as LF gains the line's own ending",
            seed: "a\r\nb\r\n", oldText: "b", newText: "b\nc",
            expected: "a\r\nb\r\nc\r\n", note: reendedNote),
        Pair(
            label: "a single-line quote in an LF file gains nothing",
            seed: "a\nb\n", oldText: "b", newText: "b2",
            expected: "a\nb2\n", note: ""),
        Pair(
            label: "a lone CR inside a line is data, not an ending",
            seed: "a\rb\r\nc\r\n", oldText: "c", newText: "C",
            expected: "a\rb\r\nC\r\n", note: ""),
        Pair(
            label: "replace_all over a CRLF file keeps every ending",
            seed: "x\r\ny\r\nx\r\ny\r\n", oldText: "x\ny\n", newText: "x\nz\n",
            expected: "x\r\nz\r\nx\r\nz\r\n", note: viewNote, replaceAll: true),
    ]

    @Test("edit_file writes those bytes and no others", arguments: cases)
    func editFileByteFidelity(_ pair: Pair) throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("f.txt", pair.seed)
        defer { SessionWorkspace.clear() }

        let out: String
        do {
            out = try FileTools.editFile(
                path: "f.txt", oldString: pair.oldText, newString: pair.newText,
                replaceAll: pair.replaceAll ? true : nil)
        } catch let ToolError.invalidParameter(message) {
            Issue.record("\(pair.label): a correct quote must edit, not refuse: \(message)")
            return
        }
        let onDisk = try bytes(url)
        #expect(
            Array(pair.expected.utf8) == onDisk,
            "\(pair.label): verdict said \(out); bytes on disk were \(onDisk)")
        // The verdict is the only report of what happened to the bytes, so where the file's own
        // endings were applied to text the caller wrote as LF, the result says so (invariant 2) —
        // and where nothing was applied it stays silent, or the note stops meaning anything.
        if pair.note.isEmpty {
            #expect(
                !out.contains(Self.viewNote) && !out.contains(Self.reendedNote),
                "\(pair.label): nothing was converted, so nothing may be claimed: \(out)")
        } else {
            #expect(
                out.contains(pair.note),
                "\(pair.label): the result must name what it did to the endings: \(out)")
        }
    }

    @Test("a genuine miss on a CRLF file stays a refusal, and never writes")
    func crlfMissStillRefused() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("f.txt", "a\r\nb\r\nc\r\n")
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.editFile(
                path: "f.txt", oldString: "a\nq\n", newString: "a\nX\n")
            Issue.record("text that is not in the file must not edit it")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("found 0"), "strict refusal: \(message)")
        }
        let onDisk = try bytes(url)
        #expect(Array("a\r\nb\r\nc\r\n".utf8) == onDisk, "a refusal never writes")
    }

    @Test(
        "edit_lines keeps the endings of the lines it was not given",
        arguments: [
            ("CRLF interior", "a\r\nb\r\nc\r\n", 2, 2, "X", "a\r\nX\r\nc\r\n"),
            ("CRLF insert at the top", "a\r\nb\r\n", 1, 0, "Z", "Z\r\na\r\nb\r\n"),
            ("CRLF, no trailing newline stays without one", "a\r\nb", 2, 2, "X", "a\r\nX"),
            ("an LF file is untouched by the rule", "a\nb\nc\n", 2, 2, "X", "a\nX\nc\n"),
            (
                "mixed: the replaced line keeps its own ending, not the file's majority",
                "a\nb\r\nc\n",
                2, 2, "X", "a\nX\r\nc\n"
            ),
            (
                "two inserted lines gain the region's ending", "a\r\nb\r\n", 2, 1, "P\nQ",
                "a\r\nP\r\nQ\r\nb\r\n"
            ),
            (
                "a deletion leaves the neighbours' endings alone", "a\r\nb\r\nc\r\n", 2, 2, "",
                "a\r\nc\r\n"
            ),
        ])
    func editLinesKeepsEndings(
        label: String, seed: String, start: Int, end: Int, newText: String, expected: String
    ) throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("f.txt", seed)
        defer { SessionWorkspace.clear() }

        do {
            let out = try FileTools.editLines(
                path: "f.txt", startLine: start, endLine: end, newText: newText)
            let onDisk = try bytes(url)
            #expect(Array(expected.utf8) == onDisk, "\(label): verdict \(out), bytes \(onDisk)")
        } catch let ToolError.invalidParameter(message) {
            Issue.record("\(label): must edit, not refuse: \(message)")
        }
    }

    @Test("an edit_lines call that changes nothing says OK-no-change on a CRLF file too")
    func okNoChangeReachesACrlfFile() throws {
        let lease = ProcessGlobalLease(envKeys: [WorkspaceContext.workspaceEnvironmentKey])
        defer { lease.release() }
        let url = try seeded("f.txt", "a\r\nb\r\nc\r\n")
        defer { SessionWorkspace.clear() }

        // Rebuilding from the stripped view made this unreachable: the flattened file always differed
        // from the original, so "it already says exactly that" answered with a write instead (the
        // state 2f63a64c exists to name).
        let out = try FileTools.editLines(path: "f.txt", startLine: 2, endLine: 2, newText: "b")
        #expect(out.contains("OK-no-change"), "the state is a fact about the goal: \(out)")
        let onDisk = try bytes(url)
        #expect(Array("a\r\nb\r\nc\r\n".utf8) == onDisk, "it wrote nothing: \(out)")
    }
}
