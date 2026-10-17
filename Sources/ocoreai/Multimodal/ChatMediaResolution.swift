// ChatMediaResolution.swift — a media part the client *named* but this process cannot
// open must be refused by name, never answered as an opaque server error.
//
// ### Why
// `makeMLXVideo`/`makeMLXAudio`/`makeMLXImage` resolve a wire part to something the
// processor can read. When the reference is a path and the path is not there, the failure
// surfaces from deep inside AVFoundation as:
//
//     500 {"message":"Generation failed: Inference failed: The operation could not be
//          completed","type":"app_error","code":500}
//
// — measured 10-16 while chasing a different defect. That message names neither the axis
// (media), nor the part (video), nor the file, and its status blames the service for what
// was a missing file. The repo already refuses on this standard elsewhere: bad bytes get
// `invalid_audio` + `remediation` (`AppError`), and a conversation that cannot be heard
// gets `speech_denied` before any engine handle is touched (`ChatAudioIngestion`). Media
// references had no equivalent, so this file adds one — checked in the handler, before
// scheduling, for exactly the reason the audio guard is there: a request this box cannot
// satisfy should not reserve the resources to fail at.
//
// ### What counts as unresolvable
// Only references the client gave as a *path*: `file://…` and bare filesystem paths.
// `data:` URLs carry their bytes inline (nothing to open here), and `http(s)://` media is
// upstream's to fetch — refusing it would break a working path, so it stays untouched.
//
// Two origins, two statuses, because they blame different parties:
//   • `.clientPath` — a path the request named that does not exist → 400 `media_unresolvable`
//     with the part type and the path, so the caller can fix the payload;
//   • `.spool` — a path this server wrote into its own ``MediaSpool`` and can no longer
//     read → 500 `media_lost`, naming it as ours. A conversation transcript can outlive a
//     careless sweep, and when it does, "the operation could not be completed" is not an
//     acceptable answer for a byte-loss this server caused.

import Foundation

/// One media reference that could not be opened.
struct UnresolvableMedia: Equatable, Sendable {
    /// Which kind of wire part carried it: `image_url`, `video_url`, `audio_url`.
    enum Kind: String, Sendable {
        case image = "image_url"
        case video = "video_url"
        case audio = "audio_url"
    }

    /// Who supplied the path, and therefore whose error the refusal is.
    enum Origin: Equatable, Sendable {
        /// A path the request named that does not exist here.
        case clientPath
        /// A path this server wrote into its own media spool, now gone.
        case spool
    }

    let kind: Kind
    let origin: Origin
    /// Index of the message that carried the part, so the client can point at its payload.
    let messageIndex: Int
    /// The offending path as it arrived, truncated for the wire.
    let reference: String
}

enum ChatMedia {
    /// Short enough to quote in an error without throwing a client's entire (possibly
    /// signed, possibly multi-megabyte) URL back at them.
    static func summarize(_ reference: String) -> String {
        reference.count <= 160 ? reference : String(reference.prefix(157)) + "..."
    }

    /// Every media part in the conversation, in wire order.
    ///
    /// Pure over the wire DTO: no engine, no filesystem — the extraction both the refusal
    /// and any future disclosure key off, so they cannot disagree about what arrived.
    static func mediaParts(
        in messages: [Message]
    ) -> [(messageIndex: Int, kind: UnresolvableMedia.Kind, url: String)] {
        var found: [(messageIndex: Int, kind: UnresolvableMedia.Kind, url: String)] = []
        for (index, message) in messages.enumerated() {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if let image = part.imageUrl, !image.url.isEmpty {
                    found.append((index, .image, image.url))
                }
                if let video = part.videoUrl, !video.url.isEmpty {
                    found.append((index, .video, video.url))
                }
                if let audio = part.audioURL, !audio.url.isEmpty {
                    found.append((index, .audio, audio.url))
                }
            }
        }
        return found
    }

    /// Classify one reference: `nil` when there is nothing for this process to open
    /// (`data:` inline, or a remote URL upstream fetches itself).
    static func referencePath(_ url: String) -> (path: String, remote: Bool)? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return (trimmed, true)
        }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return (url.path, false)
        }
        // Bare absolute path (`/tmp/clip.mp4`) — the spelling a local client writes when
        // it forgets the scheme. Relative paths are refused too: this server has no
        // documented working-directory contract, so "it resolved somewhere else" is not an
        // answer a client could act on.
        if trimmed.hasPrefix("/") { return (trimmed, false) }
        return (trimmed, false)
    }

    /// Which media parts this process cannot open.
    ///
    /// `fileExists` is injected so the classification is testable without touching a disk,
    /// and so a test can express "the spool file is gone" directly.
    static func unresolvable(
        in messages: [Message],
        spoolDirectory: URL = MediaSpool.directory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [UnresolvableMedia] {
        mediaParts(in: messages).compactMap { part in
            guard let resolved = referencePath(part.url), !resolved.remote else { return nil }
            if fileExists(resolved.path) { return nil }
            let origin: UnresolvableMedia.Origin =
                resolved.path.hasPrefix(spoolDirectory.path) ? .spool : .clientPath
            return UnresolvableMedia(
                kind: part.kind,
                origin: origin,
                messageIndex: part.messageIndex,
                reference: summarize(part.url)
            )
        }
    }

    /// Wire-ready explanation for the first unresolvable reference, plus whether it is
    /// ours to blame. One sentence per request is enough to act on; the list rides along
    /// in the error's metadata for the cases with several.
    static func remediation(for failures: [UnresolvableMedia]) -> String {
        guard let first = failures.first else { return "" }
        switch first.origin {
        case .clientPath:
            return failures.count > 1
                ? "\(failures.count) media parts name files this server cannot open (first: \(first.kind.rawValue) \(first.reference)). Serve the bytes inline as a data: URL, put them where this host can read them, or omit the part."
                : "\(first.kind.rawValue) names a file this server cannot open (\(first.reference)). Serve the bytes inline as a data: URL, put them where this host can read them, or omit the part."
        case .spool:
            return
                "Media this server spooled for the conversation is no longer readable (\(first.reference)). Re-send the clip as a data: URL; if it repeats, the media spool budget is expiring bytes mid-conversation (OCOREAI_MEDIA_SPOOL, SessionPoolConfig.mediaMaxBytes)."
        }
    }
}
