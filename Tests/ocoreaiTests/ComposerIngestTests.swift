// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ComposerIngest — the composer front door's ingest policy, pinned.
///
/// Why this file exists: `ComposerIngest.swift` declares its path-token format
/// "AGENT-FACING — pinned by ComposerIngestTests", and until this file existed that
/// claim was false — no such suite was in the repo. The token is what the model
/// reads and the only durable attachment surface (the messages table has no
/// attachment column), so an unpinned format is an unpinned model-behaviour contract.
///
/// Every assertion is exact-value per the repo's testing standard: routing, the
/// byte-exact agent-facing token, dedupe, refusal wording that must name the file,
/// and the picker-derivation invariant that replaced the images-only panel sitting
/// behind an "Attach Files" label.

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import ocoreai

private func composerPath(_ name: String) -> URL {
    URL(fileURLWithPath: "/Users/tester/Documents/\(name)")
}

@Suite("ComposerIngest — image routing")
struct ImageRoutingTests {

    /// Every declared image extension reaches the VLM pipeline with the URL
    /// preserved byte-exact — a re-encoded or renamed handoff breaks parity.
    @Test("every image extension routes to .image, URL preserved")
    func everyImageExtensionRoutes() {
        for ext in ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"] {
            let url = composerPath("shot.\(ext)")
            #expect(
                ComposerIngest.classify(url: url, isDirectory: false, byteCount: 1024)
                    == .image(url), "ext \(ext) must route to .image")
        }
        // Uppercase on disk is the user's right — matching is case-folded.
        let upper = composerPath("SHOT.PNG")
        #expect(
            ComposerIngest.classify(url: upper, isDirectory: false, byteCount: 1024)
                == .image(upper))
    }

    /// The ceiling is raw bytes before decode, and inclusive at exactly the cap
    /// (it replaced the picker's `size <= maxFileSize`).
    @Test("size ceiling is inclusive at exactly 10 MiB")
    func sizeCeilingInclusive() {
        let url = composerPath("big.png")
        #expect(
            ComposerIngest.classify(
                url: url, isDirectory: false, byteCount: ComposerIngest.maxImageBytes)
                == .image(url))
        #expect(
            ComposerIngest.classify(
                url: url, isDirectory: false, byteCount: ComposerIngest.maxImageBytes + 1)
                == .reject(url, reason: .tooLarge(bytes: ComposerIngest.maxImageBytes + 1)))
    }

    /// Documents carry NO byte ceiling on purpose: the engine windows them through
    /// `read_file`. A UI-side cap would veto a file the agent can read.
    @Test("documents are not byte-capped — the engine windows them")
    func documentsUncapped() {
        let huge = composerPath("server.log")
        #expect(
            ComposerIngest.classify(url: huge, isDirectory: false, byteCount: 500 * 1024 * 1024)
                == .file(huge))
    }
}

@Suite("ComposerIngest — document and folder routing")
struct DocumentRoutingTests {

    /// These are the files the old picker refused behind an "Attach Files" label.
    @Test("documents and code route to .file")
    func documentsRouteToPathToken() {
        for ext in ["pdf", "md", "csv", "py", "swift", "log", "json", "tsv", "ipynb", "sql"] {
            let url = composerPath("notes.\(ext)")
            #expect(
                ComposerIngest.classify(url: url, isDirectory: false, byteCount: 4096)
                    == .file(url), "ext \(ext) must route to .file")
        }
    }

    @Test("folders route to .folder")
    func foldersRoute() {
        let dir = URL(fileURLWithPath: "/Users/tester/Projects")
        #expect(
            ComposerIngest.classify(url: dir, isDirectory: true, byteCount: nil) == .folder(dir))
    }

    /// An unsupported extension must refuse while NAMING the extension, and never
    /// fall through to the file path — a bogus token would send the agent to
    /// `read_file` on a binary it cannot decode.
    @Test("unsupported extension refuses and names the extension")
    func unsupportedRefuses() {
        let dmg = composerPath("installer.dmg")
        #expect(
            ComposerIngest.classify(url: dmg, isDirectory: false, byteCount: 64)
                == .reject(dmg, reason: .unsupportedType(ext: "dmg")))
        let noExt = composerPath("LICENSE")
        #expect(
            ComposerIngest.classify(url: noExt, isDirectory: false, byteCount: 64)
                == .reject(noExt, reason: .unsupportedType(ext: "")))
    }

    /// A vanished path is reported, not skipped in silence (the old empty `catch {}`).
    @Test("missing file reports unreadable through the stat overload")
    func missingFileIsUnreadable() {
        let gone = URL(fileURLWithPath: "/Users/tester/nope/gone.pdf")
        #expect(ComposerIngest.classify(url: gone) == .reject(gone, reason: .unreadable))
    }
}

@Suite("ComposerIngest — clipboard precedence")
struct PasteRouteTests {

    /// A Finder copy carries file URLs AND a bitmap rendition of the same file:
    /// URLs must win, or the model receives a picture of the file's own icon.
    @Test("file URLs beat bitmaps beat text")
    func precedence() {
        #expect(
            ComposerIngest.route(hasFileURLs: true, hasImageData: true, hasString: true)
                == .fileURLs)
        #expect(
            ComposerIngest.route(hasFileURLs: true, hasImageData: false, hasString: true)
                == .fileURLs)
        #expect(
            ComposerIngest.route(hasFileURLs: false, hasImageData: true, hasString: true)
                == .imageData)
        #expect(
            ComposerIngest.route(hasFileURLs: false, hasImageData: false, hasString: true)
                == .text)
        #expect(
            ComposerIngest.route(hasFileURLs: false, hasImageData: false, hasString: false)
                == .nothing)
    }
}

@Suite("ComposerIngest — agent-facing token format")
struct TokenFormatTests {

    /// BYTE-EXACT contract: this string is what the model sees and what survives
    /// SQLite persistence. Changing it changes model behaviour.
    @Test("file token is byte-exact")
    func fileTokenExact() {
        #expect(
            ComposerIngest.token(url: composerPath("src/main.swift"), isDirectory: false)
                == " [Attached file] /Users/tester/Documents/src/main.swift")
    }

    @Test("folder token is byte-exact")
    func folderTokenExact() {
        #expect(
            ComposerIngest.token(url: composerPath("Projects"), isDirectory: true)
                == " [Attached folder] /Users/tester/Documents/Projects")
    }

    /// No angle brackets, ever: `<…>` is reserved for reasoning/tool markers
    /// (`ThinkTagParser`), so an angle-bracketed token parses as a marker.
    @Test("tokens contain no angle brackets")
    func noAngleBrackets() {
        let file = ComposerIngest.token(url: composerPath("a.pdf"), isDirectory: false)
        let folder = ComposerIngest.token(url: composerPath("b"), isDirectory: true)
        #expect(!file.contains("<") && !file.contains(">"))
        #expect(!folder.contains("<") && !folder.contains(">"))
    }

    /// Dedupe keys on the full path, not the basename: two same-named files in
    /// different folders are two different things the agent must be able to read.
    @Test("dedupe matches the full path, not the basename")
    func dedupeUsesFullPath() {
        let url = composerPath("notes.md")
        #expect(ComposerIngest.isReferenced(url, in: "read \(url.path) please"))
        #expect(!ComposerIngest.isReferenced(url, in: "read notes.md please"))
        // The parent directory alone must not count as referencing the file.
        #expect(!ComposerIngest.isReferenced(url, in: "in /Users/tester/Documents/ today"))
    }

    @Test("append keeps the composer text byte-exact")
    func appendExact() {
        let token = ComposerIngest.token(url: composerPath("x.py"), isDirectory: false)
        // Empty text: the token's leading space must not orphan at position 0.
        #expect(
            ComposerIngest.append(tokens: [token], to: "")
                == "[Attached file] /Users/tester/Documents/x.py")
        // Non-empty text: exactly one space before the bracket, never doubled.
        #expect(
            ComposerIngest.append(tokens: [token], to: "summarise")
                == "summarise [Attached file] /Users/tester/Documents/x.py")
        // Multiple tokens keep their order and their own separators.
        let second = ComposerIngest.token(url: composerPath("y.csv"), isDirectory: false)
        #expect(
            ComposerIngest.append(tokens: [token, second], to: "hi")
                == "hi [Attached file] /Users/tester/Documents/x.py [Attached file] /Users/tester/Documents/y.csv"
        )
        #expect(ComposerIngest.append(tokens: [], to: "hi") == "hi")
    }
}

@Suite("ComposerIngest — honest refusals")
struct RefusalTests {

    /// A refusal that does not name its file is useless when 20 files are dropped.
    @Test("every refusal names the file and is never empty")
    func refusalsNameTheFile() {
        let url = composerPath("mystery.bin")
        let reasons: [ComposerIngest.RejectReason] = [
            .unsupportedType(ext: "bin"), .tooLarge(bytes: 15 * 1024 * 1024), .unreadable,
        ]
        for reason in reasons {
            let message = ComposerIngest.rejectionMessage(url: url, reason: reason)
            #expect(!message.isEmpty)
            #expect(message.contains("mystery.bin"), "refusal must name the file: \(message)")
        }
        #expect(
            ComposerIngest.rejectionMessage(url: url, reason: .unsupportedType(ext: "bin"))
                .contains("bin"))
    }

    /// Byte counts are not reviewable prose — sizes render as MB, one decimal.
    @Test("megabyte formatting is exact")
    func megabytesExact() {
        #expect(ComposerIngest.megabytes(10 * 1024 * 1024) == "10.0")
        #expect(ComposerIngest.megabytes(15 * 1024 * 1024) == "15.0")
        #expect(ComposerIngest.megabytes(512 * 1024) == "0.5")
        #expect(ComposerIngest.megabytes(0) == "0.0")
        let message = ComposerIngest.rejectionMessage(
            url: composerPath("clip.png"), reason: .tooLarge(bytes: 15 * 1024 * 1024))
        #expect(message.contains("15.0") && message.contains("10.0"))
    }
}

@MainActor
@Suite("ComposerIngest — funnel reports exact counts")
struct FunnelTests {

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-ingest-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ names: [String], in dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return names.map { name in
            let url = dir.appendingPathComponent(name)
            try? Data("line\n".utf8).write(to: url)
            return url
        }
    }

    /// The report is the only reviewable surface of an ingest: counts exact, and
    /// every landing visible in the composer text the user can read and edit.
    @Test("documents land as path tokens with exact counts")
    func documentsLand() throws {
        let dir = scratchDirectory()
        let urls = try write(["a.py", "b.csv", "c.pdf"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = ChatState()
        state.inputText = ""
        state.errorMessage = nil
        let report = state.ingestFileURLs(urls)
        #expect(report.files == 3)
        #expect(report.images == 0)
        #expect(report.rejected == 0)
        #expect(report.landed == 3)
        for url in urls {
            #expect(state.inputText.contains(url.path), "composer must show \(url.path)")
        }
        #expect(state.errorMessage == nil, "successful ingest must not raise an error")
    }

    /// The same path dropped twice yields one token: duplicates burn context and
    /// would make the agent read the same file twice.
    @Test("a second drop of the same path adds no token and lands 0")
    func dedupeAcrossDrops() throws {
        let dir = scratchDirectory()
        let urls = try write(["only.md"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = ChatState()
        state.inputText = ""
        #expect(state.ingestFileURLs(urls).landed == 1)
        let afterFirst = state.inputText
        #expect(state.ingestFileURLs(urls).landed == 0)
        #expect(state.inputText == afterFirst, "duplicate drop must not change composer text")
    }

    /// A mixed drop reports each outcome separately and never swallows a refusal —
    /// the picker it replaced dropped unreadable files silently.
    @Test("mixed drop reports accepted and refused separately")
    func mixedDrop() throws {
        let dir = scratchDirectory()
        let urls = try write(["report.md", "setup.exe"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = ChatState()
        state.inputText = ""
        state.errorMessage = nil
        let report = state.ingestFileURLs(urls)
        #expect(report.files == 1)
        #expect(report.rejected == 1)
        #expect(report.landed == 1)
        #expect(state.inputText.contains(urls[0].path))
        #expect(!state.inputText.contains(urls[1].path))
        guard let error = state.errorMessage else {
            Issue.record("a refusal must surface an error message")
            return
        }
        #expect(error.contains("setup.exe"))
    }

    /// Dropping nothing changes nothing — no phantom token, no false success.
    @Test("empty drop is a no-op")
    func emptyDrop() {
        let state = ChatState()
        state.inputText = "keep me"
        state.errorMessage = nil
        let report = state.ingestFileURLs([])
        #expect(report.images == 0 && report.files == 0 && report.rejected == 0)
        #expect(report.landed == 0)
        #expect(state.inputText == "keep me")
    }
}

@Suite("ComposerIngest — picker derives from policy")
struct PickerDerivationTests {

    /// The panel's allowed types come from this policy, so "the panel offered it"
    /// implies "classify() accepts it".
    @Test("every offered extension is accepted by classify")
    func offeredTypesAreAccepted() {
        #expect(ComposerIngest.allowedContentTypes.contains(.folder), "folders must be pickable")
        for ext in ComposerIngest.allowedExtensions where UTType(filenameExtension: ext) != nil {
            let url = composerPath("sample.\(ext)")
            switch ComposerIngest.classify(url: url, isDirectory: false, byteCount: 16) {
            case .image, .file: break
            case .reject(let rejected, let reason):
                Issue.record("offered ext \(ext) rejected: \(rejected.path) \(reason)")
            case .folder:
                Issue.record("extension \(ext) must not classify as folder")
            }
        }
    }

    /// Every accepted extension must also be OFFERABLE, or the door stays shut for a
    /// file the engine can read — the exact bug this slice fixed. Fails and names it.
    @Test("no accepted extension is unpickable")
    func everyAcceptedExtensionIsPickable() {
        var unpickable: [String] = []
        for ext in ComposerIngest.allowedExtensions where UTType(filenameExtension: ext) == nil {
            unpickable.append(ext)
        }
        #expect(unpickable.isEmpty, "extensions with no registered UTType: \(unpickable)")
    }

    /// The axes stay disjoint: an extension must not be both a VLM image and a
    /// path-token document, or routing would depend on iteration order.
    @Test("image and document extension sets are disjoint")
    func axesAreDisjoint() {
        #expect(
            ComposerIngest.imageExtensions.isDisjoint(with: ComposerIngest.documentExtensions))
        #expect(
            ComposerIngest.allowedExtensions
                == ComposerIngest.imageExtensions.union(ComposerIngest.documentExtensions))
    }
}
