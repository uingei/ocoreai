// ChatMediaResolutionTests.swift — a media part that names an unreadable file is refused
// by name, with the blame assigned to the right party.
//
// The condition is real and was measured 10-16: before `ChatMedia` existed, a turn whose
// media path did not resolve came back as
// `500 {"message":"Generation failed: Inference failed: The operation could not be
// completed","type":"app_error","code":500}` — a server-side status naming neither the
// axis, the part, nor the file. These tests pin the replacement: classify paths (never
// `data:`, never remote URLs), assign origin (caller's path → theirs to fix; this
// server's own spool → ours to report), and hand back a status plus a remediation a
// client can act on. `fileExists` is injected, so every branch here is exercised without
// touching a disk — and the "spool file vanished" branch, which is otherwise a race, is
// directly expressible.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

private func textPart(_ s: String) -> ContentPart {
    ContentPart(type: "text", text: s, imageUrl: nil)
}

private func imagePart(_ url: String) -> ContentPart {
    ContentPart(type: "image_url", text: nil, imageUrl: ContentPart.ImageURL(url: url))
}

private func videoPart(_ url: String) -> ContentPart {
    var part = ContentPart(type: "video_url", text: nil, imageUrl: nil)
    part.videoUrl = ContentPart.VideoURL(url: url)
    return part
}

private func audioPart(_ url: String) -> ContentPart {
    var part = ContentPart(type: "audio_url", text: nil, imageUrl: nil)
    part.audioURL = ContentPart.AudioURL(url: url)
    return part
}

private func partsMessage(_ parts: [ContentPart], role: String = "user") -> Message {
    Message(role: role, content: .parts(parts))
}

@Suite("ChatMedia — what counts as a reference this server must open")
struct MediaReferenceClassificationTests {
    @Test("media parts are collected in wire order, per message")
    func collectsPartsInOrder() {
        let messages = [
            Message(role: "system", content: .text("be brief")),
            partsMessage([
                textPart("look"), videoPart("file:///a.mp4"),
                audioPart("data:audio/wav;base64,AAA"),
            ]),
            partsMessage([imagePart("https://example.com/x.png")]),
        ]
        let parts = ChatMedia.mediaParts(in: messages)
        #expect(parts.count == 3)
        #expect(parts.map(\.kind) == [.video, .audio, .image])
        #expect(parts.map(\.messageIndex) == [1, 1, 2])
    }

    @Test("plain-text conversations carry no media to resolve")
    func textOnlyHasNoReferences() {
        let messages = [
            Message(role: "system", content: .text("hi")),
            Message(role: "user", content: .text("no media here")),
            Message(role: "user", content: nil),
        ]
        #expect(ChatMedia.mediaParts(in: messages).isEmpty)
        #expect(ChatMedia.unresolvable(in: messages, fileExists: { _ in false }).isEmpty)
    }

    @Test("classification: data: is inline, http(s) is upstream's to fetch, paths are ours to open")
    func referencePathShapes() {
        #expect(ChatMedia.referencePath("data:video/mp4;base64,AAAA") == nil)
        #expect(ChatMedia.referencePath("   ") == nil)
        #expect(ChatMedia.referencePath("https://host/clip.mp4")?.remote == true)
        #expect(ChatMedia.referencePath("http://host/clip.mp4")?.remote == true)
        #expect(ChatMedia.referencePath("file:///tmp/clip.mp4")?.path == "/tmp/clip.mp4")
        #expect(ChatMedia.referencePath("/tmp/clip.mp4")?.path == "/tmp/clip.mp4")
        // A relative path has no documented meaning for this server, so it is treated as a
        // path to check rather than quietly resolved against some working directory.
        #expect(ChatMedia.referencePath("clip.mp4")?.remote == false)
    }
}

@Suite("ChatMedia — unresolvable references and who they blame")
struct MediaRefusalTests {
    private var spool: URL { URL(fileURLWithPath: "/var/lib/ocoreai/cache/media") }

    @Test("a caller-supplied path that is not there is the caller's error")
    func clientPathIsClientError() {
        let failures = ChatMedia.unresolvable(
            in: [partsMessage([textPart("colour?"), videoPart("file:///nope/clip.mp4")])],
            spoolDirectory: spool,
            fileExists: { _ in false }
        )
        #expect(failures.count == 1)
        #expect(failures[0].origin == .clientPath)
        #expect(failures[0].kind == .video)
        #expect(failures[0].messageIndex == 0)
        #expect(failures[0].reference.contains("clip.mp4"))
        let remedy = ChatMedia.remediation(for: failures)
        #expect(remedy.contains("video_url"))
        #expect(remedy.contains("data: URL"))
    }

    @Test("a missing file inside this server's own spool is this server's error")
    func spoolLossIsServerError() {
        let missing = spool.appendingPathComponent("19606c0bf0d2cb57-2887.mp4").path
        let failures = ChatMedia.unresolvable(
            in: [partsMessage([videoPart("file://\(missing)")])],
            spoolDirectory: spool,
            fileExists: { _ in false }
        )
        #expect(failures.count == 1)
        #expect(failures[0].origin == .spool)
        let remedy = ChatMedia.remediation(for: failures)
        #expect(remedy.contains("Re-send the clip"))
        #expect(remedy.contains("OCOREAI_MEDIA_SPOOL"))
    }

    @Test("inline and remote payloads are never refused, even when nothing exists on disk")
    func inlineAndRemoteAreNeverRefused() {
        let failures = ChatMedia.unresolvable(
            in: [
                partsMessage([
                    videoPart("data:video/mp4;base64,AAAA"),
                    imagePart("https://example.com/clip.png"),
                    audioPart("http://example.com/s.caf"),
                ])
            ],
            spoolDirectory: spool,
            fileExists: { _ in false }
        )
        #expect(failures.isEmpty)
    }

    @Test("a path that exists is not a failure — the check must not invent refusals")
    func existingPathsPass() {
        let failures = ChatMedia.unresolvable(
            in: [partsMessage([videoPart("file:///tmp/a.mp4"), imagePart("/tmp/b.png")])],
            spoolDirectory: spool,
            fileExists: { path in path == "/tmp/a.mp4" || path == "/tmp/b.png" }
        )
        #expect(failures.isEmpty)
    }

    @Test("several failures name the count and still quote only the first path")
    func pluralRemediation() {
        let failures = ChatMedia.unresolvable(
            in: [
                partsMessage([videoPart("file:///gone/one.mp4")]),
                partsMessage([audioPart("/gone/two.caf")], role: "user"),
            ],
            spoolDirectory: spool,
            fileExists: { _ in false }
        )
        #expect(failures.count == 2)
        let remedy = ChatMedia.remediation(for: failures)
        #expect(remedy.hasPrefix("2 media parts name files this server cannot open"))
        #expect(remedy.contains("one.mp4"))
        #expect(!remedy.contains("two.caf"))
    }

    @Test("a long reference is truncated rather than quoted back whole")
    func longReferenceTruncated() {
        let huge = "file:///tmp/" + String(repeating: "x", count: 400) + ".mp4"
        let failures = ChatMedia.unresolvable(
            in: [partsMessage([videoPart(huge)])],
            spoolDirectory: spool,
            fileExists: { _ in false }
        )
        #expect(failures.count == 1)
        #expect(failures[0].reference.count == 160)
        #expect(failures[0].reference.hasSuffix("..."))
    }

    @Test("blame reaches the HTTP status: caller's path is 400, our loss is 500")
    func statusesMatchBlame() {
        #expect(AppError.mediaUnresolvable(reason: "gone").status == .badRequest)
        #expect(AppError.mediaLost(reason: "gone").status == .internalServerError)
        // A refusal that no longer carries its reason is a different bug; keep the sentence.
        #expect(
            AppError.mediaUnresolvable(reason: "video_url /tmp/x.mp4").description
                .contains("video_url /tmp/x.mp4"))
    }

    @Test("remediation for no failures is empty, so a caller cannot emit a phantom fix")
    func emptyInputEmptyRemediation() {
        #expect(ChatMedia.remediation(for: []) == "")
    }
}
