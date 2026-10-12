// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ComposerIngest.swift — pure ingest policy for the chat composer front door.
///
/// ### Why this exists (proven gap, 2026-10-12)
/// The composer is the app's front door, and a user's hands hold three kinds of
/// things: text, images, and *files*. Text worked. Images worked — but only via
/// `NSOpenPanel` filtered to 4 image UTTypes (`ChatView.pickImages`). Files were
/// physically impossible to hand over: no `.dropDestination`, no `.onPasteCommand`
/// (both grep to 0 across `Sources/`), and the picker rejected everything that
/// was not a picture — while its own accessibility label promised "Attach Files".
/// That is a front-door gap, not an engine gap: `read_file` already consumes text,
/// code, and PDF text layers natively (see CHANGELOG 09-28 PDF slice). The
/// capability existed; the door refused to open.
///
/// ### First principles
/// 1. Accept what the user has in hand: drop, paste, or pick — same policy once.
/// 2. Route by what the ENGINE can consume, not by file-icon prettiness:
///    • image bytes → the existing image-attachment pipeline (VLM content part)
///    • text/code/document/PDF → a self-describing ABSOLUTE PATH token, because
///      the agent reads those with `read_file`/`search_files`. Passing a path
///      reuses the engine's windowing instead of re-slurping bytes into context.
/// 3. Never lie, never stay silent: anything refused reports WHY, naming the file.
///    The old picker swallowed read failures in an empty `catch {}`.
/// 4. The picker's offered types are DERIVED from this policy (one source of
///    truth) so the panel can never offer what the policy would reject.
///
/// ### Path token format (AGENT-FACING — pinned by ComposerIngestTests)
/// `" [Attached file] /abs/path"` / `" [Attached folder] /abs/path"`, matching the
/// existing `" [Voice Input] …"` bracket convention in `ChatState.chat()`. The token
/// lands in the composer's own text, so the user sees exactly what the model gets,
/// can edit it away, and it survives SQLite persistence + session resume (the
/// messages table has no attachment column — text is the only durable surface).
/// No angle brackets: those are reserved for reasoning/tool markers.

import Foundation
import UniformTypeIdentifiers

/// Pure composer ingest policy. No UI, no globals, no I/O except one stat call.
enum ComposerIngest {

    // MARK: - Actions

    /// What the composer does with one incoming URL.
    enum Action: Equatable {
        /// Image bytes → existing image-attachment pipeline (`ContentPart.image_url`).
        case image(URL)
        /// Non-image document/code/PDF → absolute-path token for `read_file`.
        case file(URL)
        /// Directory → absolute-path token for the folder tools.
        case folder(URL)
        /// Refused, with a reason that names the file to the user.
        case reject(URL, reason: RejectReason)
    }

    /// Honest refusal reasons — every one renders a message that names the file.
    enum RejectReason: Equatable {
        /// Extension the engine has no reader for (reported without the dot).
        case unsupportedType(ext: String)
        /// Image over the raw-byte ceiling before decode.
        case tooLarge(bytes: Int)
        /// Path vanished or bytes unreadable (sandbox denial, eject, race).
        case unreadable
    }

    /// Where one clipboard event should route. Pure so precedence is testable
    /// without touching `NSPasteboard` (same pure/live split as ClipboardTools).
    enum PasteRoute: Equatable {
        case fileURLs
        case imageData
        /// Text field pastes it itself — the composer must not intercept.
        case text
        case nothing
    }

    // MARK: - Policy constants

    /// Raw-byte ceiling for image ingest — inherited verbatim from the image
    /// picker it replaces (10 MB raw → ~500 KB after `compressImage`).
    static let maxImageBytes = 10 * 1024 * 1024

    /// Extensions the VLM path consumes as image parts. `compressImage` decodes
    /// all of these through `CGImageSource`.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif",
    ]

    /// Extensions `read_file` / `search_files` consume natively (text or PDF text
    /// layer). Routed as path tokens — the engine windows the bytes, not the UI.
    static let documentExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdx", "rst", "log", "csv", "tsv", "json",
        "jsonl", "yaml", "yml", "toml", "ini", "env", "xml", "html", "htm", "css",
        "scss", "swift", "py", "pyi", "js", "jsx", "ts", "tsx", "mjs", "cjs", "java",
        "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "go", "rb", "php",
        "sh", "bash", "zsh", "fish", "sql", "gradle", "cmake", "make",
        "mk", "diff", "patch", "pdf", "ipynb", "svg", "tex", "bib", "srt", "vtt",
    ]

    /// Every extension this policy accepts. The picker's allowed types derive
    /// from this set — the panel can never offer what classify() would reject.
    static var allowedExtensions: Set<String> {
        imageExtensions.union(documentExtensions)
    }

    // MARK: - Classification

    /// Lowercased extension without the dot ("" when the name has none).
    static func ext(for url: URL) -> String {
        url.pathExtension.lowercased()
    }

    /// Pure classification from already-known facts — no stat, fully testable.
    static func classify(url: URL, isDirectory: Bool, byteCount: Int?) -> Action {
        if isDirectory { return .folder(url) }
        let ext = ext(for: url)
        if imageExtensions.contains(ext) {
            if let bytes = byteCount, bytes > maxImageBytes {
                return .reject(url, reason: .tooLarge(bytes: bytes))
            }
            return .image(url)
        }
        if documentExtensions.contains(ext) { return .file(url) }
        return .reject(url, reason: .unsupportedType(ext: ext))
    }

    /// Classification with the one stat call the callers would otherwise repeat.
    static func classify(url: URL) -> Action {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .reject(url, reason: .unreadable)
        }
        if isDir.boolValue { return .folder(url) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = attrs?[.size] as? Int
        return classify(url: url, isDirectory: false, byteCount: bytes)
    }

    /// Clipboard routing precedence: a Finder copy carries file URLs *and* a
    /// bitmap rendition of the same file, so URLs must win or the file would
    /// arrive as a re-encoded picture of its own icon.
    static func route(hasFileURLs: Bool, hasImageData: Bool, hasString: Bool) -> PasteRoute {
        if hasFileURLs { return .fileURLs }
        if hasImageData { return .imageData }
        if hasString { return .text }
        return .nothing
    }

    // MARK: - Tokens

    /// Agent-facing path token. Bracket convention matches `" [Voice Input] …"`.
    static func token(url: URL, isDirectory: Bool) -> String {
        isDirectory ? " [Attached folder] \(url.path)" : " [Attached file] \(url.path)"
    }

    /// A path already referenced in the composer text is not referenced twice —
    /// duplicate tokens burn context and read as clutter to the user.
    static func isReferenced(_ url: URL, in text: String) -> Bool {
        text.contains(url.path)
    }

    /// Append tokens to composer text. No leading space when text is empty.
    static func append(tokens: [String], to text: String) -> String {
        let joined = tokens.joined()
        guard !joined.isEmpty else { return text }
        guard !text.isEmpty else { return String(joined.drop(while: { $0 == " " })) }
        return text + joined
    }

    // MARK: - Honest refusals

    /// Human-readable MB with one decimal — a byte count is not reviewable prose.
    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / (1024.0 * 1024.0))
    }

    /// Rejection message naming the file. Never empty, never silent — the old
    /// picker dropped unreadable files inside an empty `catch {}`.
    static func rejectionMessage(url: URL, reason: RejectReason) -> String {
        let name = url.lastPathComponent
        switch reason {
        case .unsupportedType(let ext):
            return String(format: StringKey.attachUnsupportedType.l, name, ext.isEmpty ? "—" : ext)
        case .tooLarge(let bytes):
            return String(
                format: StringKey.attachTooLarge.l, name, megabytes(bytes),
                megabytes(maxImageBytes))
        case .unreadable:
            return String(format: StringKey.attachUnreadable.l, name)
        }
    }

    // MARK: - Picker surface (derived, never hand-maintained)

    /// `NSOpenPanel.allowedContentTypes` derived from `allowedExtensions`, plus
    /// folders. One source of truth: a type the panel offers is by construction a
    /// type `classify()` accepts — no more "Attach Files" label over an
    /// images-only panel.
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = []
        for ext in allowedExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.folder)
        return types
    }
}
