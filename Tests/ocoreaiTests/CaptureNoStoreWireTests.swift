// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! CaptureNoStoreWireTests — a capture response must never be cacheable, and no leg may
//! bypass the one builder that says so.
//!
//! Why this exists (AGENTS.md invariant 2 plus the adoption privacy contract): a
//! `POST /v1/multimodal/capture` body carries the frame or the sample itself, as a
//! `data:` URL — the bytes of what this box just saw or heard travel inside the JSON. Any
//! intermediary that stored one would hold the user's camera frame after the request ended.
//! A cached *refusal* is its own dishonesty: it would keep answering "refused" after the
//! user grants the channel, which is the surface quoting a permission the process has
//! already disproved.
//!
//! The header alone is a claim, so the second half of this suite scans the emit site: every
//! capture leg must route through `captureWireResponse`, and the file that puts frame bytes on
//! the wire must not own an encoder. It did (`fileprivate extension Response.json`), one that
//! silently swallowed header arguments — the leg that runs on a denied host bound to it, so the
//! header a reader could see being set was never the header being sent. Root found by searching,
//! floor on its own hit count (§ Testing Quality).
//!
//! Scope, stated because the first version of this file overstated it: several handlers still
//! hold a private `JSONEncoder` for their own response shapes (completions, Anthropic messages,
//! chat, model download, lifecycle). "One JSON-encoding home repo-wide" is therefore NOT this
//! invariant, and a scan of `Response.json` declarations alone is blind to any helper that
//! encodes under another name — so the scan here is on the mechanism (`JSONEncoder(`), scoped
//! to the file that carries bytes. Folding the per-handler encoders is a separate cleanup.

import Foundation
import HTTPTypes
import Testing

@testable import ocoreai

@Suite("capture wire — no-store, and one builder")
struct CaptureNoStoreWireTests {

    private enum ScanError: Error {
        case rootNotFound
        case handlerMissing
        case laneBoundary
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let marker = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: marker.path),
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("Sources").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw ScanError.rootNotFound
    }

    private static func read(_ relative: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScanError.handlerMissing
        }
        return text
    }

    /// Just the capture lane: `multimodalCaptureHandler` and the `captureGate` it calls, cut
    /// at the next declaration. Cut by declaration rather than by payload type because the
    /// speak legs reuse `CaptureResponse` and carry no captured bytes — they are not this
    /// invariant. A renamed boundary throws instead of scanning nothing.
    private static func captureLane(_ text: String) throws -> String {
        guard let start = text.range(of: "func multimodalCaptureHandler(") else {
            throw ScanError.laneBoundary
        }
        let tail = text[start.lowerBound...]
        guard let end = tail.range(of: "private func captureFailureNote(") else {
            throw ScanError.laneBoundary
        }
        return String(tail[..<end.lowerBound])
    }

    /// Doc comments discuss the header in prose; a scan that counts prose passes on a
    /// sentence instead of a call.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
            }
            .joined(separator: "\n")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var search = haystack[haystack.startIndex...]
        while let found = search.range(of: needle) {
            count += 1
            search = search[found.upperBound...]
        }
        return count
    }

    /// Call sites wrap at 90 columns, so a two-rule scan has to see through the line break:
    /// whitespace-stripped text turns `Response.json(\n CaptureResponse(` into one token.
    private static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    // ── the value a client can actually observe ───────────────────────────────

    @Test("a capture response carries cache-control: no-store")
    func captureResponseIsNoStore() throws {
        let response = try captureWireResponse(
            CaptureResponse(
                dataType: "image/jpeg",
                dataURL: "data:image/jpeg;base64,AAAA",
                message: "Frame captured"))
        #expect(response.headers[.cacheControl] == "no-store")
    }

    @Test("the refusal leg is no-store too — the only leg that runs on a denied host")
    func refusalLegIsNoStore() throws {
        // `captureGate`'s answer has no bytes in it, which is exactly why it is the leg a
        // per-response-argument design forgets. A cached refusal is a stale permission.
        let response = try captureWireResponse(
            CaptureResponse(
                dataType: "image/png",
                dataURL: nil,
                message: "Capture refused — screen recording is denied"))
        #expect(response.headers[.cacheControl] == "no-store")
        #expect(response.headers[.contentType] == "application/json")
    }

    @Test("no-store does not displace content-type, and is the only cache directive")
    func headersSurviveTheMerge() throws {
        let response = try captureWireResponse(
            CaptureResponse(dataType: "audio/caf", dataURL: nil, message: "Recording started"))
        // `HTTPFields` yields `HTTPField`, not tuples: a merge loop written as
        // `for (key, value) in` does not compile, and one written to overwrite the map
        // would drop content-type on the floor instead.
        #expect(response.headers[.contentType] == "application/json")
        let cacheFields = response.headers.filter { $0.name == .cacheControl }
        #expect(cacheFields.count == 1)
    }

    // ── the emit site: one builder, no decoy encoder ──────────────────────────

    @Test("every capture leg routes through captureWireResponse")
    func captureLegsUseTheBuilder() throws {
        let lane = try Self.captureLane(
            Self.read("Sources/ocoreai/Handlers/MultimodalHandler.swift"))
        // Floor 7: camera (frame / no-frame), microphone (sample / started / not-started),
        // screen (frame / no-frame) = 7 legs, plus the shared gate refusal = 8 today. Below
        // 7 a leg exists that does not pass through the header at all.
        let tight = Self.squeezed(Self.codeOnly(lane))
        // Floor 7: camera (frame / no-frame), microphone (sample / started / not-started),
        // screen (frame / no-frame) = 7 legs, plus the gate refusal all three share = 8 today.
        // Below 7 a leg exists that never passes through the header.
        let builderSites = Self.occurrences(of: "captureWireResponse(CaptureResponse(", in: tight)
        #expect(
            builderSites >= 7,
            "only \(builderSites) captureWireResponse sites — a capture leg now encodes its own response, so nothing guarantees no-store on it"
        )

        // Not one `CaptureResponse` may reach the wire through a direct encoder. The speak
        // and status legs encode directly and are allowed to — they carry no captured bytes.
        let bypassed = Self.occurrences(of: "Response.json(CaptureResponse(", in: tight)
        #expect(
            bypassed == 0,
            "\(bypassed) CaptureResponse encoded directly — it would leave without no-store")
    }

    @Test("one `Response.json` declaration — a same-named local one shadowed the header")
    func oneResponseJSONDeclaration() throws {
        // The decoy was real: a `fileprivate static func json` in MultimodalHandler.swift
        // taking no header argument. Calls in that file bound to it, so the header being set
        // visibly was not the header being sent. This scans DECLARATIONS of that name, which
        // is the shadowing hazard; it deliberately does not claim to find every encoder
        // (see the file header — helpers under other names exist and are another cleanup).
        let root = try Self.repoRoot()
        let sources = root.appendingPathComponent("Sources/ocoreai")
        guard
            let enumerator = FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: nil)
        else { throw ScanError.rootNotFound }
        var homes: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if Self.occurrences(of: "static func json(", in: Self.codeOnly(text)) > 0 {
                homes.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        #expect(
            homes == ["Sources/ocoreai/Router/ChatCompletionsRouter.swift"],
            "more than one `Response.json` declaration — a second can shadow the first: \(homes)")
    }

    @Test("the file that puts frame bytes on the wire owns no encoder of its own")
    func byteCarrierDoesNotOwnEncoder() throws {
        // Mechanism, not name: `JSONEncoder(` is what an encoder looks like whatever the
        // helper is called. A file that builds its own response also owns its own headers,
        // and that is exactly where a directive goes missing.
        let text = Self.codeOnly(
            try Self.read("Sources/ocoreai/Handlers/MultimodalHandler.swift"))
        let owned = Self.occurrences(of: "JSONEncoder(", in: text)
        #expect(
            owned == 0,
            "MultimodalHandler.swift builds \(owned) JSONEncoder(s) — the frame-carrying file must encode through the shared Response.json so the header rides along")
    }
}
