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
            throw ToolError.invalidParameter("edit_file: oldString == newString (no-op)")
        }
        let count = original.components(separatedBy: oldString).count - 1
        // `replace_all` states intent without demanding the count, so the caller cannot be
        // wrong about N; an explicit `occurrences` still has to match, which is the guard
        // against a partial edit (oldString appearing 5 times when the caller saw 1).
        // Zero matches stay a refusal under `replace_all` too: expected = 0 would let the
        // guard pass and return an OK for a file nobody touched (measured 10-22, caught by
        // `replaceAllNeedsNoCount`) — invariant 2, the surface may not claim more than the
        // engine did.
        let expected = replaceAll == true ? max(1, count) : max(1, occurrences ?? 1)
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
            let remedy: String
            if count == 0 {
                remedy = ": oldString is not in this file — read_file it and copy the exact text"
            } else {
                remedy =
                    " — to replace every occurrence retry this call yourself with replace_all: true"
                    + " (or occurrences: \(count) to be exact); do not ask the user for the count"
            }
            let hint = count == 0 ? nearestLinesHint(text: original, oldString: oldString) : ""
            throw ToolError.invalidParameter(
                "\(head)\(remedy), refusing partial edit\(hint)")
        }
        let echo = PresentationEcho.repair(newString)
        let updated = original.replacingOccurrences(of: oldString, with: echo.text)
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
    ///   - startLine: First line to replace, 1-based; `total + 1` appends at end of file.
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
        guard startLine >= 1, startLine <= total + 1 else {
            throw ToolError.invalidParameter(
                "edit_lines: start_line \(startLine) is outside 1...\(total + 1) — \(path) has "
                    + "\(total) lines (\(total + 1) appends at end of file)")
        }
        guard endLine >= startLine - 1, endLine <= total else {
            throw ToolError.invalidParameter(
                "edit_lines: end_line \(endLine) is outside \(startLine - 1)...\(total) — "
                    + "\(startLine - 1) inserts before line \(startLine) without deleting")
        }

        let echo = PresentationEcho.repair(newText)
        var insertion: [String] =
            echo.text.isEmpty ? [] : echo.text.components(separatedBy: "\n")
        if insertion.last == "" { insertion.removeLast() }
        let cutEnd = min(endLine, total)
        let replacedCount = max(0, cutEnd - (startLine - 1))
        // Split with explicit types: the single concat expression timed out the type-checker.
        var updatedLines: [String] = []
        updatedLines.append(contentsOf: lines[0 ..< (startLine - 1)])
        updatedLines.append(contentsOf: insertion)
        updatedLines.append(contentsOf: lines[cutEnd ..< total])
        var updated = updatedLines.joined(separator: "\n")
        if original.hasSuffix("\n"), !updated.isEmpty { updated += "\n" }
        guard updated != original else {
            throw ToolError.invalidParameter(
                "edit_lines: lines \(startLine)-\(endLine) already read as newText (no-op)")
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
        let delta = bytes.count - (original.data(using: .utf8)?.count ?? 0)
        let verdict = Self.writeVerdict(path: url.path, fileContent: updated, echo: echo)
        let verb: String
        if replacedCount == 0 {
            verb = "inserted \(insertion.count) line(s) before line \(startLine) of \(total)"
        } else if insertion.isEmpty {
            verb = "deleted \(replacedCount) line(s) \(startLine)-\(endLine) of \(total)"
        } else {
            verb =
                "replaced lines \(startLine)-\(endLine) (\(replacedCount)) with \(insertion.count), "
                + "of \(total) lines"
        }
        return
            "edit_lines: \(verdict.marker) — \(verb), \(delta >= 0 ? "+" : "")\(delta) bytes, "
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
        let candidates: [URL] = isDir.boolValue ? listFiles(under: url) : [url]

        if (target ?? "files") == "content" {
            var matches: [String] = []
            var scanned = 0
            for candidate in candidates {
                if matches.count >= maxResults || scanned >= maxSearchFiles { break }
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
                return
                    "search_files: 0 files containing '\(pattern)' under \(path) (scanned \(scanned))"
            }
            return matches.map { "  \($0)" }.joined(separator: "\n")
                + "\n─── total: \(matches.count) (substring in file content) ───"
        }

        var matches: [String] = []
        for candidate in candidates where matches.count < maxResults {
            if globMatch(candidate.lastPathComponent, pattern) {
                matches.append(candidate.path)
            }
        }
        matches.sort()
        if matches.isEmpty {
            return "search_files: 0 files matching '\(pattern)' under \(path)"
        }
        return matches.map { "  \($0)" }.joined(separator: "\n")
            + "\n─── total: \(matches.count) (filename glob) ───"
    }

    // MARK: - Helpers

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
    ) -> String {
        func normalized(_ slice: some StringProtocol) -> String {
            slice.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        let lines = Self.numberedContentLines(text)
        guard !lines.isEmpty else { return "" }
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
        func numbered(_ range: Range<Int>) -> String {
            range.map { "\($0 + 1)|\(lines[$0])" }.joined(separator: "\n")
        }
        // A small file is quoted whole: scoring the nearest window was a false economy —
        // measured 10-22 it pointed at line 5 (`return s`) when the line the caller needed
        // was line 3 (`for i in range(1, n):`), which is a hint that misleads.
        let whole = numbered(0 ..< lines.count)
        if whole.count <= limit {
            return
                " — the file says (all \(lines.count) lines, quote exactly, indentation included):\n\(whole)"
        }
        let end = min(bestIndex + maxLines, lines.count)
        let window = numbered(bestIndex ..< end)
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
            " — nearest actual lines (quote exactly, indentation included):\n\(shown)"
            + "\n[lines \(bestIndex + 1)-\(end) of \(lines.count) lines\(clipNote)"
            + " — read_file for the rest]"
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

    /// Hidden files and VCS/build dirs are skipped; depth-bounded DFS.
    static func listFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        while let (current, depth) = stack.popLast() {
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: current, includingPropertiesForKeys: nil)
            else { continue }
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                var childIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDir)
                else { continue }
                if childIsDir.boolValue {
                    if depth + 1 <= maxWalkDepth {
                        stack.append((child, depth + 1))
                    }
                } else {
                    out.append(child)
                }
            }
        }
        return out
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
