// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatState+ComposerIngest.swift — the composer's ingest funnel.
///
/// One funnel, three doors: drag-and-drop, ⌘V, and the file picker all arrive
/// here as `[URL]`, so routing is written once (`ComposerIngest`) and cannot
/// drift between doors. Policy lives in `ComposerIngest`; this file is the
/// MainActor side that mutates composer state.
///
/// ### Why (proven gap, 2026-10-12)
/// `grep -rn "dropDestination|onDrop|onPasteCommand" Sources/` = 0 hits, and
/// `ChatView.pickImages` filtered `allowedContentTypes` to `[.png, .jpeg, .heic,
/// .webP]` under a button labelled "Attach Files". A user with a `.py`, `.log`,
/// `.csv`, or `.pdf` in hand had no door: they had to transcribe a path by hand
/// into the text field, even though `read_file` reads all three natively. A
/// screenshot in the clipboard had to be saved to disk first, then navigated to.
///
/// ### Honesty contract
/// Every refusal names its file and its reason; the empty `catch {}` that used to
/// swallow unreadable picker files is replaced by `ComposerIngest.rejectionMessage`.

import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension ChatState {

    /// What one composer ingest actually did — exact counts, because "it worked"
    /// without a number is not reviewable, and the door it replaces could drop a
    /// file into an empty `catch {}` and still look successful.
    struct IngestReport: Equatable {
        var images = 0
        var files = 0
        var rejected = 0
        /// Anything that reached the composer: an image queued for decode, or a
        /// path token placed in the text field.
        var landed: Int { images + files }
    }

    // MARK: - Files → composer

    /// Ingest file URLs into the composer.
    ///
    /// Routing is `ComposerIngest`'s, not this method's:
    ///   • image → the existing attachment pipeline (bytes → `compressImage` →
    ///     `ContentPart.image_url`) — same wire, same token budget as the picker.
    ///   • document / code / PDF / folder → an absolute-path token in the text
    ///     field, which the agent opens with `read_file`. The UI never re-slurps
    ///     bytes into context: the engine windows them, once, on its own terms.
    /// Refusals name the file in `errorMessage` — never silent, never invented.
    @discardableResult
    func ingestFileURLs(_ urls: [URL]) -> IngestReport {
        var report = IngestReport()
        guard !urls.isEmpty else { return report }
        var imageURLs: [URL] = []
        var tokens: [String] = []
        var refusals: [String] = []
        for url in urls {
            switch ComposerIngest.classify(url: url) {
            case .image(let image):
                imageURLs.append(image)
            case .file(let file):
                guard !ComposerIngest.isReferenced(file, in: inputText) else { continue }
                tokens.append(ComposerIngest.token(url: file, isDirectory: false))
                report.files += 1
            case .folder(let folder):
                guard !ComposerIngest.isReferenced(folder, in: inputText) else { continue }
                tokens.append(ComposerIngest.token(url: folder, isDirectory: true))
                report.files += 1
            case .reject(let rejected, let reason):
                refusals.append(ComposerIngest.rejectionMessage(url: rejected, reason: reason))
                report.rejected += 1
            }
        }
        if !tokens.isEmpty {
            inputText = ComposerIngest.append(tokens: tokens, to: inputText)
        }
        if !refusals.isEmpty {
            errorMessage = refusals.joined(separator: "\n")
        }
        report.images = imageURLs.count
        ingestImageFiles(imageURLs)
        return report
    }

    /// Read + compress off the main actor (HIG: the front door never blocks on
    /// disk), publish thumbnails back on the main actor. An unreadable image is
    /// reported by name.
    func ingestImageFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            var appended: [ChatState.AttachedImage] = []
            var unreadable: [String] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url) else {
                    unreadable.append(
                        ComposerIngest.rejectionMessage(url: url, reason: .unreadable))
                    continue
                }
                let compressed = compressImage(data)
                appended.append(
                    ChatState.AttachedImage(
                        dataURL: "data:image/jpeg;base64,\(compressed.base64EncodedString())"))
            }
            await MainActor.run {
                self.pendingAttachments.append(contentsOf: appended)
                if !unreadable.isEmpty {
                    self.errorMessage = unreadable.joined(separator: "\n")
                }
            }
        }
    }

    // MARK: - Clipboard → composer

    /// Consume the system clipboard into the composer — ⌘V on a screenshot or a
    /// Finder copy, the way every chat app behaves. Precedence is
    /// `ComposerIngest.route`: URLs beat bitmaps, because a Finder copy carries
    /// both and taking the bitmap would hand the model a picture of the file's
    /// own icon. Plain text routes back to the caller untouched — the text field
    /// pastes that natively and must not be intercepted.
    func ingestPasteboard() -> ComposerIngest.PasteRoute {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let urls =
            (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?.map { $0 as URL } ?? []
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        let hasString = pasteboard.string(forType: .string) != nil
        #else
        let pasteboard = UIPasteboard.general
        let urls = pasteboard.urls ?? []
        let imageData =
            pasteboard.data(forType: UTType.png.identifier)
            ?? pasteboard.data(forType: UTType.tiff.identifier)
        let hasString = pasteboard.hasStrings
        #endif
        let route = ComposerIngest.route(
            hasFileURLs: !urls.isEmpty, hasImageData: imageData != nil, hasString: hasString)
        switch route {
        case .fileURLs:
            ingestFileURLs(urls)
        case .imageData:
            if let imageData {
                ingestClipboardImage(imageData)
            }
        case .text, .nothing:
            break
        }
        return route
    }

    /// Consume SwiftUI's paste payload (`onPasteCommand`) through the same
    /// funnel. Files win over bitmaps for the reason `ComposerIngest.route`
    /// gives: a Finder copy carries both, and the bitmap is just an icon.
    func ingest(itemProviders providers: [NSItemProvider]) async {
        var urls: [URL] = []
        var imageData: Data?
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await Self.pastedFileURL(provider) { urls.append(url) }
            } else if imageData == nil,
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            {
                imageData = await Self.pastedImageData(provider)
            }
        }
        if !urls.isEmpty {
            ingestFileURLs(urls)
            return
        }
        if let imageData, !imageData.isEmpty {
            ingestClipboardImage(imageData)
        }
    }

    // MARK: - NSItemProvider bridges
    //
    // `NSItemProvider` on this deployment target only exposes completion-handler
    // loading, so each bridge resumes exactly once on every path — including the
    // error path, which resumes `nil` rather than leaving the composer hanging.

    private static func pastedFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier, options: nil
            ) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let fileURL = item as? NSURL {
                    continuation.resume(returning: fileURL as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func pastedImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// A full-res screenshot is ~10 MB of raw pixels; the VLM budget wants
    /// ~500 KB. Decode + compress off the main actor, publish on it.
    private func ingestClipboardImage(_ data: Data) {
        Task.detached(priority: .utility) {
            let compressed = compressImage(data)
            await MainActor.run {
                self.pendingAttachments.append(
                    ChatState.AttachedImage(
                        dataURL: "data:image/jpeg;base64,\(compressed.base64EncodedString())"))
            }
        }
    }
}
