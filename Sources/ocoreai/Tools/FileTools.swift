// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FileTools — real file operations for the agent tool surface.
///
/// Closes the P0 tool-surface gap (codex borrow points): the registry whitelist
/// already reserved read_file / search_files and the destructive blacklist
/// reserved write_file, but none were implemented — the surface was
/// placeholder-only (info/skills_*/echo).
///
/// Apply-before-verify (codex apply-patch discipline): write_file compares
/// the bytes it writes against what it re-reads from disk — a successful
/// write call is corroborated, not assumed.
import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

enum FileTools {
    // Bounds — every traversal is resource-bounded.
    static let maxReadBytes = 2_097_152  // 2MB per read
    static let maxWriteBytes = 1_048_576  // 1MB per write
    static let defaultReadLimit = 2000  // lines
    static let maxSearchFileBytes = 65_536  // per-file content scan cap
    static let maxSearchFiles = 500  // files scanned per content search
    static let maxWalkDepth = 5

    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico",
        "mp4", "mov", "m4a", "mp3", "wav", "flac",
        "zip", "gz", "tar", "7z",
        "pdf", "bin", "dylib", "so", "a", "o", "class", "jar",
        "woff", "woff2", "ttf", "otf",
        "sqlite", "db",
    ]

    // MARK: - read_file

    /// Read a text file as numbered `N|line` text.
    /// - Parameters:
    ///   - path: Absolute, `~`-expanded, or cwd-relative path.
    ///   - offset: 1-based first line (default 1).
    ///   - limit: Max lines (default 2000).
    static func read(path: String, offset: Int? = 1, limit: Int? = defaultReadLimit) throws
        -> String
    {
        let url = resolve(path)
        guard let data = try? Data(contentsOf: url, options: .uncached) else {
            throw ToolError.invalidParameter(
                "read_file: cannot read: \(path)\(Self.pathContext(url))")
        }
        guard data.count <= maxReadBytes else {
            throw ToolError.invalidParameter(
                "read_file: file too large (\(data.count) bytes, max \(maxReadBytes)): \(path)")
        }
        // PDF — extract the text layer (system framework, no third-party dep → 开箱即用).
        // Runs before the plain-text decode: a PDF is not a NUL-byte UTF-8 file, and
        // PDFKit's `page.string` is the honest source of its text.
        #if canImport(PDFKit)
        if url.pathExtension.lowercased() == "pdf" || data.prefix(4) == Data("%PDF".utf8) {
            return try readPDF(data: data, path: path, offset: offset, limit: limit)
        }
        #endif
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("\0") else {
            throw ToolError.invalidParameter("read_file: not a text file: \(path)")
        }
        let lines = Self.numberedContentLines(text)
        let total = lines.count
        guard total > 0 else { return "read_file: empty file: \(path)" }
        let start = max(1, offset ?? 1)
        guard start <= total else {
            throw ToolError.invalidParameter(
                "read_file: offset \(start) exceeds file length (\(total) lines)")
        }
        // Window from `start` inclusive holds `total - start + 1` lines.
        // Clamp limit into [1, holdable] so that:
        //   1. `end = start + safeLimit - 1` can never overflow (safeLimit ≤ holdable ≤ total)
        //   2. `end ≥ start` always, so `start...end` satisfies its range precondition (no limit=0 crash)
        let holdable = total - start + 1
        let safeLimit = min(max(1, limit ?? defaultReadLimit), holdable)
        let end = start + safeLimit - 1  // ≤ total, overflow-proof
        var out = ""
        for i in start ... end {
            out += "\(i)|\(lines[i - 1])\n"
        }
        out += Self.presentationFooter(total: total, start: start, end: end)
        return out
    }

    // MARK: - read_file PDF branch

    /// Extract a PDF's text layer via PDFKit (system framework — no third-party
    /// dep, works on macOS 14+ floor). Output format matches plain-file reads:
    /// `N|line` numbered lines + footer.
    ///
    /// Honesty contract: if the PDF has NO extractable text (scanned / image-only),
    /// throw a clear error with an actionable hint (attach the file for the VLM / use
    /// `view_image`) — do NOT fabricate "0 lines" or silently return an empty window.
    static func readPDF(
        data: Data,
        path: String,
        offset: Int? = 1,
        limit: Int? = defaultReadLimit
    ) throws -> String {
        guard let doc = PDFDocument(data: data) else {
            throw ToolError.invalidParameter(
                "read_file: cannot parse PDF: \(path) (file damaged or not a valid PDF)")
        }
        guard doc.pageCount > 0 else {
            throw ToolError.invalidParameter("read_file: PDF has 0 pages: \(path)")
        }
        // Extract per-page text, join with page separators.
        var lines: [String] = []
        var extractedAnyText = false
        for pageIndex in 0 ..< doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            let pageText = (page.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pageText.isEmpty {
                extractedAnyText = true
            }
            // Prepend a `─── page N ───` marker for multi-page files so the model
            // can ground per-page references. Single-page: no marker.
            let marker = doc.pageCount > 1 ? ("page \(pageIndex + 1) of \(doc.pageCount)") : ""
            if marker.isEmpty {
                lines.append(contentsOf: pageText.components(separatedBy: "\n"))
            } else {
                lines.append("─── \(marker) ───")
                lines.append(contentsOf: pageText.components(separatedBy: "\n"))
            }
        }
        guard extractedAnyText else {
            throw ToolError.invalidParameter(
                "read_file: \"\(path)\" is a PDF with no extractable text layer "
                    + "(scanned or image-only — PDFKit returns 0 characters from all \"\(doc.pageCount)\" page(s)). "
                    + "Options: (1) use the `view_image` tool on a rendered page, or "
                    + "(2) attach the file to a multimodal model turn, or "
                    + "(3) run `pdftotext`/`qpdf` via the shell tools if installed.")
        }
        // Window (offset/limit) over the flattened line array, same semantics as plain read.
        let total = lines.count
        let start = max(1, offset ?? 1)
        guard start <= total else {
            throw ToolError.invalidParameter(
                "read_file: offset \(start) exceeds PDF text length (\(total) lines): \(path)")
        }
        let holdable = total - start + 1
        let safeLimit = min(max(1, limit ?? defaultReadLimit), holdable)
        let end = start + safeLimit - 1
        var out = ""
        for i in start ... end {
            let line = lines[i - 1].replacingOccurrences(of: "\r", with: "")
            out += "\(i)|\(line)\n"
        }
        out += Self.presentationFooter(total: total, start: start, end: end)
        return out
    }

    // MARK: - write_file

    /// Write (create or replace) a file, then verify by read-back.
    static func write(path: String, content: String) throws -> String {
        let url = resolve(path)
        let echo = PresentationEcho.repair(content)
        let bytes = Data(echo.text.utf8)
        guard bytes.count <= maxWriteBytes else {
            throw ToolError.invalidParameter(
                "write_file: content too large (\(bytes.count) bytes, max \(maxWriteBytes))")
        }
        let existingBytes = (try? Data(contentsOf: url, options: .uncached))?.count
        let parent = url.deletingLastPathComponent()
        if parent != URL(fileURLWithPath: "/") {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw ToolError.invalidParameter("write_file: \(error.localizedDescription)")
        }
        // Apply-before-verify: read-back must byte-match what we wrote.
        guard let back = try? Data(contentsOf: url, options: .uncached), back == bytes else {
            throw ToolError.invalidParameter("write_file: read-back verification failed: \(path)")
        }
        let lineCount = echo.text.components(separatedBy: "\n").count
        let verb = existingBytes.map { "replaced \($0) bytes" } ?? "created"
        // Durability was proven above; validity is a separate question and the model has to
        // be told which of the two it got (PostWriteSyntax: why "OK" is not enough).
        let verdict = Self.writeVerdict(path: url.path, fileContent: echo.text, echo: echo)
        return
            "write_file: \(verdict.marker) — \(bytes.count) bytes, \(lineCount) lines, \(verb), read-back verified (\(path))"
            + verdict.suffix
    }

    // MARK: - edit_file

    /// Search-and-replace within a single file (codex apply-patch discipline:
    /// unique match required by default, replacement verified by read-back).
    /// - Parameters:
    ///   - path: File to edit.
    ///   - oldString: Exact text to find. Must occur exactly `occurrences` times.
    ///   - newString: Replacement text (may be empty to delete).
    ///   - occurrences: Expected count of `oldString` in the file (default 1).
    ///     Any other count throws before writing — no partial edits.
    ///   - replaceAll: Replace every occurrence, whatever the count. Measured 10-22 the
    ///     scoreboard's `edit-replace-all` stayed 0/3 with `occurrences` alone: the model read
    ///     "pass occurrences: 3" and answered the *user* ("please specify how many") instead of
    ///     retrying. `replace_all` is the name every mainstream agent tool uses, so it is the
    ///     knob a model has seen before; `occurrences` stays for callers already on it.
    /// - Returns: Verification summary (match count, bytes before/after).
    static func editFile(
        path: String,
        oldString: String,
        newString: String,
        occurrences: Int? = 1,
        replaceAll: Bool? = nil
    ) throws -> String {
        let url = resolve(path)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError.invalidParameter(
                "edit_file: cannot read (missing or non-UTF8): \(path)\(Self.pathContext(url))")
        }
        guard !oldString.isEmpty else {
            throw ToolError.invalidParameter("edit_file: oldString must not be empty")
        }
        guard oldString != newString else {
            // The 5-word refusal could not tell the caller which of two opposite truths it faced,
            // and the retry spun on both: 3 strikes inside 12 s in one task window, the same
            // shape on four consecutive boards, halved to 2 by this split's rerun. The decision
            // is edit_lines' OK-no-change — name the state, give the next step, never claim a
            // write (never a pass either: an OK here would book a change nobody made).
            let places = original.components(separatedBy: oldString).count - 1
            if places > 0 {
                throw ToolError.invalidParameter(
                    "edit_file: oldString == newString (no-op) — \(path) already holds exactly"
                        + " the text you sent (\(places) place(s)), so nothing can change here. If"
                        + " that text is the change you wanted, it is already in the file: check"
                        + " it and say so. If you meant to change something, send the edit whose"
                        + " newString differs from what you quoted. Nothing was written.")
            }
            let hint = Self.nearestLinesHint(text: original, oldString: oldString)
            let order: String
            if hint.quotedWholeFile {
                // The sentences that took the `found 0` class from retry storms to 6/6 recovery.
                order =
                    " Retry this call now with the exact text above as oldString and a newString"
                    + " that differs from it: the whole file is quoted above, so nothing has to"
                    + " be read first. Do not answer the user before that retry."
            } else {
                order =
                    " read_file the whole file, then retry with copied text as oldString and a"
                    + " newString that differs from it."
            }
            throw ToolError.invalidParameter(
                "edit_file: oldString == newString (no-op) — that text is not in \(path)"
                    + " either, so nothing can be replaced with it\(hint.text).\(order)"
                    + " Nothing was written.")
        }
        var count = original.components(separatedBy: oldString).count - 1
        // `replace_all` states intent without demanding the count, so the caller cannot be
        // wrong about N; an explicit `occurrences` still has to match, which is the guard
        // against a partial edit (oldString appearing 5 times when the caller saw 1).
        // Zero matches stay a refusal under `replace_all` too: expected = 0 would let the
        // guard pass and return an OK for a file nobody touched (measured 10-22, caught by
        // `replaceAllNeedsNoCount`) — invariant 2, the surface may not claim more than the
        // engine did.
        var expected = replaceAll == true ? max(1, count) : max(1, occurrences ?? 1)
        // A caller quotes what the only read surface it has shows: `read_file` answers with `N|`
        // prefixes and a `total_lines:` footer, so a correct quote arrives carrying chrome and
        // counts zero against the raw file. Measured on the scoreboard's `fix-*` tasks, that
        // refusal ("found 0") was the last thing the model tried. Stripping is decided, not
        // guessed: it runs only after the raw count already failed, and is accepted only when the
        // stripped text matches `expected` exactly — then the verdict says it happened.
        var located = oldString
        var chromeNote = ""
        // A byte test, deliberately: `contains("\r")` compares graphemes, and `"\r\n"` is its own
        // grapheme, so the Character question is false for every CRLF file in the tree (measured
        // 11-10 — it made this gate never open and the view rung dead code).
        let endings = original.utf8.contains(0x0D) ? Endings(original) : nil
        var matchedInView = false
        var repairedText: String?
        if count != expected {
            let repair = PresentationEcho.repair(oldString)
            if repair.didRepair && !repair.isUnrepaired {
                let stripped = original.components(separatedBy: repair.text).count - 1
                let strippedExpected =
                    replaceAll == true ? max(1, stripped) : max(1, occurrences ?? 1)
                if stripped == strippedExpected {
                    located = repair.text
                    count = stripped
                    expected = strippedExpected
                    repairedText = repair.text
                    let families = repair.removed.map { $0.artifact.rawValue }
                    chromeNote =
                        " [oldString carried read_file chrome (\(families.joined(separator: ", ")))"
                        + " — matched after stripping it]"
                }
            }
        }
        // The next rung down is the view the caller was shown: a CRLF file cannot be matched by LF
        // text at all, so a correct quote answered `found 0` and the refusal quoted back the same
        // stripped text it had just asked for (`LineEndingFidelityTests`). Decided like the rung
        // above, never guessed — it runs only after the raw count already failed, is accepted only
        // when the view count equals `expected` exactly, and the verdict says it happened.
        if count != expected, let e = endings {
            for candidate in [located, repairedText.map { $0 }].compactMap({ $0 }) {
                let needle = candidate.replacingOccurrences(of: "\r\n", with: "\n")
                let found = Endings.ranges(of: needle, in: e.view).count
                let foundExpected =
                    replaceAll == true ? max(1, found) : max(1, occurrences ?? 1)
                if found > 0, found == foundExpected {
                    located = needle
                    count = found
                    expected = foundExpected
                    matchedInView = true
                    break
                }
            }
        }
        let head: String
        if replaceAll == true {
            head = "edit_file: replace_all found \(count) occurrence(s) of oldString in \(path)"
        } else {
            head =
                "edit_file: expected exactly \(expected) occurrence(s) of oldString in \(path),"
                + " found \(count)"
        }
        guard count == expected else {
            // The refusal stays strict (a whitespace-tolerant apply would be a location guess),
            // but strictness without a next step is a dead end: measured 10-22 the scoreboard's
            // `edit-replace-all` scored 0/3 because the model wanted exactly the operation the
            // tool supports — replace every occurrence — met `found 3 — refusing partial edit`,
            // which names the count but never says that `occurrences` is the knob for it.
            let hint =
                count == 0
                ? Self.nearestLinesHint(text: original, oldString: oldString) : MismatchHint()
            if hint.quotedWholeFile {
                // A refusal that orders a round trip it already completed is how a recoverable
                // miss ends the turn: measured on the scoreboard, `fix-boundary-comparison` got
                // the file quoted whole in this very message — with the caller's own newString
                // already correct — and answered "I need to read the file first", task unmade.
                // When every line is in hand the only next step is the retry, so the message
                // names it and closes the other exit (the shape that took `edit-replace-all`
                // from 0/3 to a pass: name the knob, then forbid stopping).
                // An empty newString is the caller's own deletion intent, and the retry ordered
                // above cannot finish that job: edit_file can empty a file, and no file tool
                // deletes one. Measured on the scoreboard, `delete-only-what-was-asked` met this
                // refusal, had no route to a removal, and asked the user for the line quoted in
                // the same message. So name the route that does exist — and only where the
                // caller's own argument proves removal intent, because an `rm` suggestion in an
                // ordinary mismatch would nudge a mistyped edit into an unrecoverable delete.
                let removal =
                    newString.isEmpty
                    ? "\nDeleting the file itself is not a file tool: use exec_command with"
                        + " `rm \(path)`. The retry above empties the file instead."
                    : ""
                throw ToolError.invalidParameter(
                    "\(head), refusing partial edit\(hint.text)"
                        + "\nRetry this call now with the exact line above as oldString:"
                        + " the whole file is quoted above, so nothing has to be read first."
                        + " Do not answer the user before that retry.\(removal)")
            }
            let remedy: String
            if count == 0 {
                remedy = ": oldString is not in this file — read_file it and copy the exact text"
            } else {
                remedy =
                    " — to replace every occurrence retry this call yourself with replace_all: true"
                    + " (or occurrences: \(count) to be exact); do not ask the user for the count"
            }
            throw ToolError.invalidParameter(
                "\(head)\(remedy), refusing partial edit\(hint.text)")
        }
        let echo = PresentationEcho.repair(newString)
        // Where the file ends its lines, it keeps doing so: the caller's text is spliced into the
        // bytes that were matched, so the lines around the edit are copied rather than re-rendered,
        // and a line break the caller wrote as LF joins the style of the region it replaces.
        var endingsNote = ""
        let updated: String
        if let e = endings {
            let regions =
                matchedInView
                ? e.sourceRegions(ofViewNeedle: located)
                : Endings.ranges(of: located, in: e.source)
            let spliced = e.splice(regions, with: echo.text)
            updated = spliced.text
            // Only what actually happened to this call's bytes, and nothing that repeats the
            // chrome report above: a caller who sent the file's own endings was not converted, so
            // has nothing to be told.
            var why: [String] = []
            if matchedInView { why.append("matched the LF view read_file shows") }
            if !spliced.appliedEndings.isEmpty {
                let styles = spliced.appliedEndings.map { $0 == "\r\n" ? "CRLF" : "LF" }.sorted()
                why.append(
                    "wrote the new lines with the file's \(styles.joined(separator: "/")) endings")
            }
            if !why.isEmpty { endingsNote = " [\(why.joined(separator: "; "))]" }
        } else {
            updated = original.replacingOccurrences(of: located, with: echo.text)
        }
        let bytes = updated.data(using: .utf8) ?? Data()
        guard bytes.count <= maxWriteBytes else {
            throw ToolError.invalidParameter(
                "edit_file: result too large (\(bytes.count) bytes, max \(maxWriteBytes))")
        }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw ToolError.invalidParameter(
                "edit_file: write failed: \(error.localizedDescription)")
        }
        guard let readBack = try? Data(contentsOf: url, options: .uncached),
            readBack == bytes
        else {
            throw ToolError.invalidParameter("edit_file: read-back verification failed: \(path)")
        }
        let delta = bytes.count - (original.data(using: .utf8)?.count ?? 0)
        let verdict = Self.writeVerdict(path: url.path, fileContent: updated, echo: echo)
        return
            "edit_file: \(verdict.marker) — \(count) replacement(s), \(delta >= 0 ? "+" : "")\(delta) bytes, "
            + "read-back verified (\(path))"
            + verdict.suffix
            + chromeNote
            + endingsNote
    }
    // MARK: - edit_lines

    /// The one line-numbering this toolset shows a caller: `N|text` over content lines, so a file
    /// ending in a newline has no phantom last line. `read_file` renders this list and names its
    /// length `total_lines:`, `edit_file` quotes it on a mismatch, and `edit_lines` accepts it as
    /// input — one number, one meaning (AGENTS.md: one home per decision).
    static func numberedContentLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.replacingOccurrences(of: "\r", with: "") }
    }

    /// The LF view of a file and the endings it was written with — what both write seams need to
    /// agree with what `read_file` showed.
    ///
    /// `numberedContentLines` renders every line with `\r` stripped, so LF is the only text a caller
    /// can copy off `read_file`. Both write seams worked on the raw bytes: on a CRLF file a correct
    /// multi-line quote answered `found 0` while the refusal quoted back the very stripped text that
    /// cannot match, and `edit_lines` rebuilt the file *from* that stripped text, so an edit to one
    /// line re-ended every line in the file and booked the deleted CRs as a byte delta under `OK`
    /// (`LineEndingFidelityTests`, 11-10). A line breaks at `\n` or at `\r\n`, exactly where
    /// `numberedContentLines` breaks one, so a line range means the same number on both seams, and a
    /// `\r` that is not a terminator is data that keeps its byte.
    ///
    /// The rule is the field's, spliced rather than flattened: pi d448c51e (#11751) keeps a line's
    /// own bytes "including its line endings" outside the replaced ranges; opencode
    /// `tool/plugin/edit.ts:165-188` matches "the LF view Read shows the model, then maps offsets
    /// back to the source, so CRLF and mixed line endings neither block matches nor leak into
    /// untouched regions"; codex `apply-patch/src/text_file.rs:19-33` prefers the file's first ending
    /// for lines it inserts. qwen-code `tools/edit.ts:269` normalizes the whole file to one ending
    /// instead, which is the flatten pi's commit exists to remove. `write_file` stays outside this
    /// seam: the caller authored every byte it sends, so there is no untouched region to protect.
    struct Endings {
        /// The file's bytes, held here so a slice of them stays meaningful.
        let source: String
        /// The LF view `read_file` shows: the lines joined by `\n`, no `\r` anywhere.
        let view: String
        /// Whether each line is terminated; `false` only for a last line that has none. `edit_lines`
        /// asks, because the file keeps its own trailing state whichever line ends up last.
        let terminated: [Bool]
        /// Each line's text, terminator excluded — for a CRLF line that excludes its `\r` too, which
        /// `carriage` records rather than folding into the text.
        private let texts: [Substring]
        /// Whether the line ends CRLF. A `\r` anywhere else is inside `texts`: data, not a terminator.
        private let carriage: [Bool]
        /// `\r\n` when the file's first terminated line carries a CR, `\n` otherwise — the style text
        /// joins when the region it replaces holds no terminator of its own.
        private let first: String
        /// Where each line starts in `source` and in `view`, index-for-index with `texts`.
        private let sourceStarts: [String.Index]
        private let viewStarts: [String.Index]

        /// `"\r\n"` is one `Character` in Swift, so the terminator test has to name both spellings:
        /// scanning for `\n` alone walks straight past every CRLF and reports the file as one line.
        init(_ text: String) {
            var texts: [Substring] = []
            var carriage: [Bool] = []
            var terminated: [Bool] = []
            var sourceStarts: [String.Index] = []
            var lineStart = text.startIndex
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let ch = text[cursor]
                if ch == "\n" || ch == "\r\n" {
                    texts.append(text[lineStart ..< cursor])
                    carriage.append(ch == "\r\n")
                    terminated.append(true)
                    sourceStarts.append(lineStart)
                    lineStart = text.index(after: cursor)
                }
                cursor = text.index(after: cursor)
            }
            if lineStart < text.endIndex {
                texts.append(text[lineStart ..< text.endIndex])
                carriage.append(false)
                terminated.append(false)
                sourceStarts.append(lineStart)
            }
            var viewParts: [String] = []
            viewParts.reserveCapacity(texts.count)
            // The style an inserted line joins is the first terminator the file actually has.
            var first = "\n"
            for n in texts.indices where terminated[n] {
                first = carriage[n] ? "\r\n" : "\n"
                break
            }
            for n in texts.indices {
                viewParts.append(String(texts[n]))
                if terminated[n] { viewParts.append("\n") }
            }
            let view = viewParts.joined()
            var viewStarts: [String.Index] = []
            var at = view.startIndex
            viewStarts.append(at)
            while at < view.endIndex {
                if view[at] == "\n" { viewStarts.append(view.index(after: at)) }
                at = view.index(after: at)
            }
            self.source = text
            self.texts = texts
            self.carriage = carriage
            self.terminated = terminated
            self.view = view
            self.first = first
            self.sourceStarts = sourceStarts
            self.viewStarts = viewStarts
        }

        /// The line's own bytes, terminator included — what an untouched line has to be written back
        /// as, and the reason `carriage` and `terminated` are separate facts.
        func bytes(atLine line: Int) -> String {
            guard texts.indices.contains(line) else { return "" }
            return String(texts[line]) + (carriage[line] ? "\r" : "")
                + (terminated[line] ? "\n" : "")
        }

        /// The style this line ends in, which is the style text replacing it should join.
        func ending(atLine line: Int) -> String {
            guard texts.indices.contains(line) else { return first }
            return carriage[line] ? "\r\n" : "\n"
        }

        /// Non-overlapping occurrences of `needle` in `haystack`, as ranges of `haystack`.
        ///
        /// A hit is kept only when its bytes equal the needle's: `range(of:)` answers for
        /// canonically-equal text too, and a splice that replaces more occurrences than the guard
        /// counted would claim a change it did not make (invariant 2). Bytes are the only literal
        /// comparison here, which is also what `components(separatedBy:)` — the counter — does.
        static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
            guard !needle.isEmpty else { return [] }
            let want = Array(needle.utf8)
            var found: [Range<String.Index>] = []
            var from = haystack.startIndex
            while from < haystack.endIndex,
                let hit = haystack.range(of: needle, range: from ..< haystack.endIndex)
            {
                if Array(haystack[hit].utf8) == want { found.append(hit) }
                from = hit.upperBound
            }
            return found
        }

        /// Where `needle` occurs in the view, mapped onto the file's bytes.
        func sourceRegions(ofViewNeedle needle: String) -> [Range<String.Index>] {
            Self.ranges(of: needle, in: view).map {
                source($0.lowerBound) ..< source($0.upperBound)
            }
        }

        /// The position in the file for a position in the view: a view line's text is its file line's
        /// text, so only the offset *within* that line has to be carried across.
        private func source(_ offset: String.Index) -> String.Index {
            guard offset != view.endIndex, !sourceStarts.isEmpty else { return source.endIndex }
            var line = viewStarts.count - 1
            for (n, start) in viewStarts.enumerated() where start > offset {
                line = n - 1
                break
            }
            if line < 0 { line = 0 }
            let within = view.distance(from: viewStarts[line], to: offset)
            return source.index(sourceStarts[line], offsetBy: within)
        }

        /// The file's bytes with each region replaced, the replacement's line breaks taking the
        /// ending of the region it replaces — the file's first ending when that region holds none.
        /// Everything outside the regions is copied, never re-rendered.
        /// - Returns: the new bytes, and the endings actually written where they differ from the bytes
        ///   the caller supplied (a caller who sent CRLF into a CRLF file was not converted, so has
        ///   nothing to be told).
        func splice(
            _ regions: [Range<String.Index>], with replacement: String
        ) -> (text: String, appliedEndings: Set<String>) {
            let lf = replacement.replacingOccurrences(of: "\r\n", with: "\n")
            var out = ""
            out.reserveCapacity(source.count)
            var cursor = source.startIndex
            var applied: Set<String> = []
            for region in regions {
                guard region.lowerBound >= cursor else { continue }
                out += source[cursor ..< region.lowerBound]
                let ending = Self.ending(
                    ofRegion: source[region.lowerBound ..< region.upperBound], fallback: first)
                let written = lf.replacingOccurrences(of: "\n", with: ending)
                if written != replacement { applied.insert(ending) }
                out += written
                cursor = region.upperBound
            }
            out += source[cursor ..< source.endIndex]
            return (out, applied)
        }

        /// The terminator that ends the first line inside `region`, since that is the style the text
        /// replacing it should join. Both spellings, for the reason named on `init`.
        static func ending(ofRegion region: Substring, fallback: String) -> String {
            for ch in region {
                if ch == "\r\n" { return "\r\n" }
                if ch == "\n" { return "\n" }
            }
            return fallback
        }
    }

    /// The footer `read_file` prints under a numbered window, said in one place because both
    /// readers emit it. Nothing persuasive goes in here: measured on the scoreboard, a sentence
    /// telling the caller not to copy the numbering was itself copied into the produced file, so
    /// the disclaimer belongs on the write side, where a violation is what summons it.
    static func presentationFooter(total: Int, start: Int, end: Int) -> String {
        let scope =
            end < total
            ? "window \(start)–\(end); continue at offset=\(end + 1)" : "full"
        return "─── total_lines: \(total) (\(scope)) ───"
    }

    /// Durability was proven by the caller's read-back; this is the other half of the report.
    /// Syntax is judged over the whole file, presentation-echo only over the text this call
    /// supplied — otherwise a file that already holds a numbered dump would condemn every
    /// unrelated edit made in it.
    private static func writeVerdict(
        path: String,
        fileContent: String,
        echo: PresentationEcho.Repair
    ) -> (marker: String, suffix: String) {
        let syntax = PostWriteSyntax.check(path: path, content: fileContent)
        let marker: String
        if syntax?.failed == true || echo.isUnrepaired {
            marker = "OK-but-invalid"
        } else {
            marker = echo.didRepair ? "OK-but-repaired" : "OK"
        }
        return (marker, PostWriteSyntax.suffix(syntax) + PresentationEcho.suffix(echo))
    }

    /// Replace, insert, or delete a numbered line range, verified by read-back.
    ///
    /// `edit_file` asks the caller to reproduce bytes; the measured failure mode on the repair tasks
    /// is `found 0` — the model knows which lines to change and not their exact indentation. Every
    /// surface here already prints the file with `N|` numbers, so this seam takes the numbers back
    /// instead of the bytes. A range means exactly what `read_file` printed.
    /// - Parameters:
    ///   - path: File to edit.
    ///   - startLine: First line to replace, 1-based; `total + 1` appends at end of file, and
    ///     anything past the end clamps onto it, stated in the result.
    ///   - endLine: Last line to replace, inclusive; `endLine == startLine - 1` inserts without
    ///     deleting, so append and insert are the same mode — no third one exists.
    ///   - newText: Replacement text; empty deletes the range.
    /// - Returns: Verification summary (range, line counts, byte delta, read-back state).
    static func editLines(path: String, startLine: Int, endLine: Int, newText: String) throws
        -> String
    {
        let url = resolve(path)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError.invalidParameter(
                "edit_lines: cannot read (missing or non-UTF8): \(path)\(Self.pathContext(url))")
        }
        let lines = Self.numberedContentLines(original)
        let total = lines.count
        guard total > 0 else {
            throw ToolError.invalidParameter("edit_lines: \(path) is empty — write_file it instead")
        }
        // A line number past the end has exactly one legal reading: the text belongs after the
        // last line; below 1 can only mean at the top. The strict version was measured as a trap
        // — `make-third-test-pass` re-sent `start_line: 14` into a 10-line file six times, each
        // refusal printing the bound and commanding a retry, none of them landing (scoreboard
        // FAIL, zero writes). The clamp performs the one thing that can be meant and reports the
        // deviation in the same result (`clampedNote` below), so the caller gets a file to verify
        // instead of arithmetic to redo (invariant 2: the verdict travels with the answer).
        let start = min(max(startLine, 1), total + 1)
        let end = min(max(endLine, start - 1), total)

        let echo = PresentationEcho.repair(newText)
        var insertion: [String] =
            echo.text.isEmpty ? [] : echo.text.components(separatedBy: "\n")
        if insertion.last == "" { insertion.removeLast() }
        let cutEnd = end
        let replacedCount = max(0, cutEnd - (start - 1))
        // Rebuild from the file's own lines, never from the LF view: joining the stripped lines with
        // `\n` re-ended every line in a CRLF file, so an edit to line 2 rewrote the whole file and
        // reported the deleted CRs as a byte delta under an `OK` (`Endings`, measured 11-10:
        // `edit_lines: OK — replaced lines 2-2 … -4 bytes` on a 3-line CRLF file). A line the caller
        // did not name keeps the bytes it had; a line it supplied joins the ending of the region it
        // replaces — pi #11751, opencode `withRegionEndings`, codex's `preferred_ending`.
        let eol = Endings(original)
        // The style a new line joins: the replaced line's own ending, and for a pure insertion the
        // line it goes above (or, appending, the line above it).
        let newLineEnding = eol.ending(atLine: min(max(start - 1, 0), max(total - 1, 0)))
        // Split with explicit types: the single concat expression timed out the type-checker.
        var pieces: [(text: String, ending: String)] = []
        for n in 0 ..< (start - 1) {
            pieces.append((eol.bytes(atLine: n), ""))
        }
        for text in insertion {
            pieces.append((text, newLineEnding))
        }
        for n in cutEnd ..< total {
            pieces.append((eol.bytes(atLine: n), ""))
        }
        let updatedLineCount = pieces.count
        // Whichever line ends up last, the file keeps its own trailing state: no newline where it
        // had none, one where it had one.
        if updatedLineCount > 0, cutEnd >= total, !insertion.isEmpty,
            !(eol.terminated.last ?? false)
        {
            pieces[pieces.count - 1].ending = ""
        }
        let updated = pieces.map { $0.text + $0.ending }.joined()
        guard updated != original else {
            // "It already says exactly that" is a fact about the goal, not a bad parameter: the
            // refusal bought four identical refusals on `make-two-tests-pass` (zero writes, FAIL)
            // because nothing in it named the state the file was in. A result that wrote nothing
            // must not claim verification, so this one says what is true and what to do next.
            let state =
                replacedCount == 0 && insertion.isEmpty
                ? "lines \(start)-\(end) hold nothing to insert or delete"
                : "lines \(start)-\(end) already read exactly as newText"
            return
                "edit_lines: OK-no-change — \(state); the file is unchanged (\(total) lines)."
                + Self.currentLinesNote(lines: lines, start: start, end: end)
                + " To change them, send newText that differs from the lines quoted above."
        }

        let bytes = updated.data(using: .utf8) ?? Data()
        guard bytes.count <= maxWriteBytes else {
            throw ToolError.invalidParameter(
                "edit_lines: result too large (\(bytes.count) bytes, max \(maxWriteBytes))")
        }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw ToolError.invalidParameter(
                "edit_lines: write failed: \(error.localizedDescription)")
        }
        guard let readBack = try? Data(contentsOf: url, options: .uncached), readBack == bytes
        else {
            throw ToolError.invalidParameter("edit_lines: read-back verification failed: \(path)")
        }
        let clampedNote: String
        if start == startLine, end == endLine {
            clampedNote = ""
        } else {
            clampedNote =
                " (clamped: start_line \(startLine) -> \(start), end_line \(endLine) -> \(end);"
                + " \(path) has \(total) lines, now \(updatedLineCount))"
        }
        let delta = bytes.count - (original.data(using: .utf8)?.count ?? 0)
        let verdict = Self.writeVerdict(path: url.path, fileContent: updated, echo: echo)
        let verb: String
        if replacedCount == 0 {
            verb = "inserted \(insertion.count) line(s) before line \(start) of \(total)"
        } else if insertion.isEmpty {
            verb = "deleted \(replacedCount) line(s) \(start)-\(end) of \(total)"
        } else {
            verb =
                "replaced lines \(start)-\(end) (\(replacedCount)) with \(insertion.count), "
                + "of \(total) lines"
        }
        return
            "edit_lines: " + verdict.marker + " — " + verb + clampedNote + ", "
            + "\(delta >= 0 ? "+" : "")\(delta) bytes, "
            + "read-back verified (\(path))"
            + verdict.suffix
    }

    // MARK: - search_files

    /// Find files by filename pattern or search file contents.
    /// - Parameters:
    ///   - path: Directory to search (or single file for a direct name check).
    ///   - pattern: Filename mode — `*` glob on the basename. Content mode — substring.
    ///   - target: "files" (default) or "content".
    ///   - limit: Max results (default 50).
    static func search(
        path: String,
        pattern: String,
        target: String? = "files",
        limit: Int? = 50
    ) throws -> String {
        let url = resolve(path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ToolError.invalidParameter("search_files: path not found: \(path)")
        }
        let maxResults = max(1, limit ?? 50)
        let walk = isDir.boolValue ? listFiles(under: url) : DirectoryWalk(urls: [url])
        // A root the engine cannot open has no honest search result: "0 files matching"
        // would report a complete scan that never ran, so the refusal names the OS
        // reason instead (codex #57186 fails closed on the same face).
        if let blocked = walk.blockedRoot {
            throw ToolError.checkFailed(
                "search_files: path not readable: \(url.path) (\(blocked))"
            )
        }
        let candidates = walk.urls
        let partialNote = walk.partialNote

        if (target ?? "files") == "content" {
            var matches: [String] = []
            var scanned = 0
            // Which bound fired decides the wording below, so the break records it rather than
            // leaving the tally to guess from the counts.
            var bound: ResultBound = .complete
            var scanBudgetHit = false
            for candidate in candidates {
                if matches.count >= maxResults {
                    bound = .capped(knownTotal: nil)
                    break
                }
                if scanned >= maxSearchFiles {
                    bound = .capped(knownTotal: nil)
                    scanBudgetHit = true
                    break
                }
                scanned += 1
                guard let data = try? Data(contentsOf: candidate, options: .uncached),
                    data.count <= maxSearchFileBytes
                else { continue }
                // PDF — extract the text layer (reuse the same extractor as `read`);
                // skip anything that can't be opened as a PDF (binary / invalid).
                #if canImport(PDFKit)
                if candidate.pathExtension.lowercased() == "pdf"
                    || data.prefix(4) == Data("%PDF".utf8)
                {
                    guard let doc = PDFDocument(data: data) else { continue }
                    var extracted = ""
                    for i in 0 ..< min(doc.pageCount, 100) {
                        extracted += (doc.page(at: i)?.string ?? "")
                    }
                    if extracted.contains(pattern) { matches.append(candidate.path) }
                    continue
                }
                #endif
                guard !isBinary(candidate) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                guard !text.contains("\0"), text.contains(pattern) else { continue }
                matches.append(candidate.path)
            }
            if matches.isEmpty {
                // Zero over a partial scan is not "the pattern is absent" — the same claim the
                // blocked root refuses to make, in the other direction.
                let budgetNote =
                    scanBudgetHit
                    ? " — scan budget reached after \(scanned) file(s), so this was not an exhaustive scan"
                    : ""
                return
                    "search_files: 0 files containing '\(pattern)' under \(path) (scanned \(scanned))"
                    + budgetNote + partialNote
            }
            return matches.map { "  \($0)" }.joined(separator: "\n")
                + resultTally(
                    shown: matches.count, kind: "substring in file content", bound: bound)
                + partialNote
        }

        // Filename mode costs no I/O, so the whole set is counted and only the window is shown —
        // the total travels with it rather than being guessed at. The window is the
        // lexicographically-first N, which is also the first deterministic answer this face has had:
        // before, the shown set was walk-order and only the display was sorted.
        let allMatches =
            candidates
            .filter { globMatch($0.lastPathComponent, pattern) }
            .map { $0.path }
            .sorted()
        if allMatches.isEmpty {
            return "search_files: 0 files matching '\(pattern)' under \(path)" + partialNote
        }
        let shown = Array(allMatches.prefix(maxResults))
        return shown.map { "  \($0)" }.joined(separator: "\n")
            + resultTally(
                shown: shown.count,
                kind: "filename glob",
                bound: allMatches.count > shown.count
                    ? .capped(knownTotal: allMatches.count) : .complete)
            + partialNote
    }

    // MARK: - Helpers

    /// Why a search stopped looking, which is the only thing that decides what its count may claim.
    enum ResultBound: Equatable {
        /// Every candidate was examined, so the shown count *is* the total.
        case complete
        /// Stopped at a limit. `knownTotal` is non-nil only where counting the rest cost nothing
        /// (in-memory matching over an already-walked list); where the rest costs the I/O the cap
        /// exists to avoid, it is nil and says so.
        case capped(knownTotal: Int?)
    }

    /// How a result set states its own completeness — one home, because "total" is the one word this
    /// tool may not spend on a number it stopped counting.
    ///
    /// A caller reads `─── total: 50 ───` as *the search is finished* and stops refining; when the
    /// loop broke at the cap, that line was not a total but a returned count wearing the word. Three
    /// trees settled the same rule independently: codex's preview carries the whole length beside the
    /// flag (`PostPreview`, `codex-rs/message-board/src/types.rs:23-30`) and its paged read carries
    /// `next_offset_chars` (`PostContent`, same file `:33-39`) — the way out, not just the bound;
    /// deepseek-harness pins `truncated`/`total` on every capped view "so a UI never presents a
    /// partial result as complete" (`docs/subsystems/tools.md:623`); pi's exec result carries
    /// `truncated: boolean` beside the text and `fullOutputPath` where the whole output went
    /// (`packages/coding-agent/src/core/bash-executor.ts:26-37`). It is also the rule this file
    /// already enforces two screens up: a blocked root is refused rather than rendered as zero
    /// matches, because neither may report a scan that never ran.
    ///
    /// An unknown total is named unknown. It is never rounded up to the shown count, and every bound
    /// leaves with the knob that lifts it, so the next turn has a move instead of a dead end.
    ///
    /// Two sibling faces carry the same pair in their own idioms, since the decoration differs per
    /// surface while the rule does not: `DirectSearchOutcome.report` (a SERP page cut by `maxHits`)
    /// and `PerceptionObserve.clip` (a 300-char preview).
    static func resultTally(shown: Int, kind: String, bound: ResultBound) -> String {
        switch bound {
        case .complete:
            return "\n─── total: \(shown) (\(kind)) ───"
        case .capped(let knownTotal):
            if let knownTotal, knownTotal > shown {
                return
                    "\n─── showing \(shown) of \(knownTotal) (\(kind); \(knownTotal - shown) not "
                    + "shown — narrow the path or raise limit) ───"
            }
            return "\n─── showing \(shown) (\(kind); the limit was reached and more may exist — "
                + "narrow the path or raise limit) ───"
        }
    }

    /// Where a relative path actually landed, in words the model can act on.
    ///
    /// `read_file: cannot read: calc.py` is true and useless: nothing in it tells the
    /// caller which directory held the miss, so the next turn retries the same wrong
    /// path. Measured 10-22 (`scripts/eval/`): a fix-syntax-error turn repeated the same
    /// failed `edit_file` and gave up, and the scoreboard called it 4/9. Naming the
    /// resolved path (and who anchored it) turns an unrecoverable refusal into a
    /// correctable one — the cheapest reliability win in the execution chain.
    static func pathContext(_ url: URL) -> String {
        let session = SessionWorkspace.currentDirectory()
        let configured = WorkspaceContext.configuredDirectory()
        let anchor = session ?? configured ?? FileManager.default.currentDirectoryPath
        let source =
            if session != nil {
                "session workspace"
            } else if configured != nil {
                "configured workspace"
            } else {
                "process cwd — no workspace set: send absolute paths or set OCOREAI_WORKSPACE"
            }
        return " (resolved: \(url.path); anchored to \(anchor); \(source))"
    }

    /// The lines a no-change answer was pointed at, quoted in the numbering `read_file` prints,
    /// so the caller sees the state it asked about without paying a second read. Bounded: a long
    /// range quotes its head and says how much it left out; an empty range quotes the line it sits
    /// before (or says the position is past the end).
    static func currentLinesNote(lines: [String], start: Int, end: Int) -> String {
        let lo = max(1, min(start, lines.count))
        // lo <= hi always holds here: the file is non-empty (guarded above) and both bounds are
        // clamped into 1...count, so a range of any shape — including the append position and an
        // insert-before range — still names at least the line it sits against.
        let hi = min(max(end, lo), lines.count)
        var quoted: [String] = []
        for index in lo ... hi {
            let text = lines[index - 1]
            quoted.append(
                "\(index)|" + (text.count > 200 ? String(text.prefix(200)) + "..." : text))
        }
        let shown = quoted.count > 12 ? Array(quoted.prefix(12)) : quoted
        var note = " The file currently says: " + shown.joined(separator: " ")
        if quoted.count > shown.count {
            note += " (+\(quoted.count - shown.count) more lines not quoted)"
        }
        return note
    }
    /// What a mismatch hint handed the caller: quotable text, and whether that text is the
    /// whole file. The refusal's next step depends on the second answer — everything quoted
    /// means the retry needs nothing else, a window means the needed line may be out of view.
    struct MismatchHint {
        var text: String = ""
        var quotedWholeFile: Bool = false
    }

    /// When `oldString` misses, quote the file's own lines back so the caller can correct
    /// instead of re-sending the same guess.
    ///
    /// The refusal itself is right — matching loosely is how a partial edit lands somewhere
    /// unintended — but `found 0` alone is unanswerable: measured 10-22 (`scripts/eval/`),
    /// one turn retried `edit_file` on `sum100.py` five times and gave up, because the model
    /// had edited from an assumption instead of a read and nothing told it what the file
    /// actually says. So the edit stays refused, and the message becomes correctable.
    static func nearestLinesHint(
        text: String, oldString: String, maxLines: Int = 8, limit: Int = 1200
    ) -> MismatchHint {
        func normalized(_ slice: some StringProtocol) -> String {
            slice.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        let lines = Self.numberedContentLines(text)
        guard !lines.isEmpty else { return MismatchHint() }
        let target = oldString.split(separator: "\n").first.map(normalized) ?? ""
        var bestIndex = 0
        var bestScore = -1.0
        let targetTokens = Set(target.split(separator: " ").map(String.init))
        for (index, line) in lines.enumerated() {
            let tokens = Set(normalized(line).split(separator: " ").map(String.init))
            let score: Double
            if tokens == targetTokens && !targetTokens.isEmpty {
                score = 1
            } else {
                let union = tokens.union(targetTokens).count
                score =
                    union == 0 ? 0 : Double(tokens.intersection(targetTokens).count) / Double(union)
            }
            if score > bestScore {
                bestScore = score
                bestIndex = index
                if score == 1 { break }
            }
        }
        // Quotable, not echoed. `read_file` shows `N|` prefixes, but this body is exactly what the
        // caller is being told to copy into `oldString`, and a prefix copied there is a guaranteed
        // miss. Telling the model "quote exactly" beside text it must not quote verbatim is the
        // contradiction; § PresentationEcho measured that a sentence asking for restraint makes the
        // artefact bigger, so the chrome comes out of the body and the position stays in labels.
        func quoted(_ range: Range<Int>) -> String {
            range.map { lines[$0] }.joined(separator: "\n")
        }
        // A small file is quoted whole: scoring the nearest window was a false economy —
        // measured 10-22 it pointed at line 5 (`return s`) when the line the caller needed
        // was line 3 (`for i in range(1, n):`), which is a hint that misleads.
        let whole = quoted(0 ..< lines.count)
        if whole.count <= limit {
            return
                MismatchHint(
                    text:
                        " — the file says (all \(lines.count) lines, verbatim, indentation"
                        + " included, and this is the file's own text, not the read_file view):"
                        + "\n\(whole)",
                    quotedWholeFile: true)
        }
        let end = min(bestIndex + maxLines, lines.count)
        let window = quoted(bestIndex ..< end)
        // Showing part of a file while naming only the part is how a hint misleads: the line
        // the caller needs may be the one that got clipped. Codex does the same for exec
        // output — `Total output lines` appears exactly when fewer lines are shown than exist
        // (codex-rs/core/src/tools/mod.rs:90-109).
        let shown: String
        let clipNote: String
        if window.count > limit {
            shown = String(window.prefix(limit))
            clipNote = ", clipped at \(limit) chars"
        } else {
            shown = window
            clipNote = ""
        }
        return
            MismatchHint(
                text:
                    " — nearest actual lines (verbatim, indentation included, and this is the"
                    + " file's own text, not the read_file view):\n\(shown)"
                    + "\n[lines \(bestIndex + 1)-\(end) of \(lines.count) lines\(clipNote)"
                    + " — read_file for the rest]")
    }

    /// Resolve a tool-supplied path: `~` expanded; absolute stays; relative
    /// anchors to the configured workspace, falling back to the process cwd
    /// when no workspace is set (pre-feature behavior).
    static func resolve(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded)
        }
        let anchor =
            SessionWorkspace.currentDirectory()
            ?? WorkspaceContext.configuredDirectory()
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: anchor))
    }

    /// What a directory walk actually read, and what it could not.
    ///
    /// `blockedRoot`/`skipped` are not decoration: a walk that dropped unreadable
    /// directories on the floor let `search_files` answer "0 files matching" about a
    /// tree it never opened — the surface claiming more than the engine measured.
    struct DirectoryWalk: Sendable {
        var urls: [URL] = []
        /// The OS reason when the root itself could not be opened (nothing was scanned).
        var blockedRoot: String?
        /// Sub-trees skipped, `"path — reason"` each, in walk order.
        var skipped: [String] = []

        /// Appended to every result a partial walk produced, so a negative answer
        /// states its own bound instead of implying an exhaustive search.
        var partialNote: String {
            skipped.isEmpty
                ? ""
                : "\n[partial scan: \(skipped.count) unreadable dir(s), first: \(skipped[0])"
                    + " — only readable sub-trees were searched]"
        }
    }

    /// Hidden files and VCS/build dirs are skipped; depth-bounded DFS.
    static func listFiles(under root: URL) -> DirectoryWalk {
        var walk = DirectoryWalk()
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        while let (current, depth) = stack.popLast() {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: current, includingPropertiesForKeys: nil)
            } catch {
                if depth == 0 {
                    walk.blockedRoot = error.localizedDescription
                } else {
                    walk.skipped.append("\(current.path) — \(error.localizedDescription)")
                }
                continue
            }
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                var childIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDir)
                else { continue }
                if childIsDir.boolValue {
                    if depth + 1 <= maxWalkDepth {
                        stack.append((child, depth + 1))
                    }
                } else {
                    walk.urls.append(child)
                }
            }
        }
        return walk
    }

    /// `*` glob over a basename: leading, trailing, both, or exact.
    static func globMatch(_ name: String, _ pattern: String) -> Bool {
        let lead = pattern.hasPrefix("*")
        let trail = pattern.hasSuffix("*")
        var core = pattern
        if lead { core.removeFirst() }
        if trail && core.hasSuffix("*") { core.removeLast() }
        switch (lead, trail) {
        case (false, false): return name == pattern
        case (true, false): return name.hasSuffix(core)
        case (false, true): return name.hasPrefix(core)
        case (true, true): return name.contains(core)
        }
    }

    static func isBinary(_ url: URL) -> Bool {
        if binaryExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return true }
        return data.prefix(1024).contains(0)
    }
}
