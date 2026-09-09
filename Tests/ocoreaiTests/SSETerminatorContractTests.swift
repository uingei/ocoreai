// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// `SSE.doneMarker` — the OpenAI-compatible SSE stream terminator, now a
// single source of truth (SSEHelpers.swift) referenced by every emitter.
//
// Regression contract pinned here (exact values, transport-safe):
//   1. The marker is byte-identical to the canonical upstream `[DONE]`
//      (vllm/sglang/omlx/codex + swift-huggingface all terminate on this).
//   2. `yieldSSERaw(marker)` renders exactly `data: [DONE]\n\n` — the frame
//      consumers (swift-huggingface HTTPClient) strip the `data:` prefix,
//      trim whitespace/newlines, and compare `==` to the canonical token.
//   3. Case IS part of the contract — a lowercase variant must NOT equal the
//      canonical form (this is the exact bug the old chat-stream `[done]`
//      had: it would silently hang a case-sensitive upstream client).
//
// Canonical bytes are assembled from UnicodeScalar code points (not a raw
// literal) so the comparison is independent of any transport-layer mangling
// of the literal in the production file — if that literal were corrupted,
// test (1) below would fail.
import Foundation
import Testing

@testable import ocoreai

@Suite("SSE terminator — wire contract (single source of truth)")
struct SSETerminatorContractTests {
    /// Canonical upstream terminator, assembled from bytes.
    /// `[DONE]` = 0x5B 0x44 0x4F 0x4E 0x45 0x5D
    private static let canonicalBytes: [UInt8] =
        [0x5B, 0x44, 0x4F, 0x4E, 0x45, 0x5D]
    private static var canonical: String {
        String(decoding: canonicalBytes, as: UTF8.self)
    }
    /// Lowercase trap (the historical chat-stream value) = `[done]`
    /// = 0x5B 0x64 0x6F 0x6E 0x45 0x5D
    private static let lowercaseTrapBytes: [UInt8] =
        [0x5B, 0x64, 0x6F, 0x6E, 0x45, 0x5D]
    private static var lowercaseTrap: String {
        String(decoding: lowercaseTrapBytes, as: UTF8.self)
    }

    @Test("doneMarker is byte-identical to the canonical upstream token")
    func markerMatchesUpstream() {
        #expect(SSE.doneMarker == Self.canonical)
    }

    @Test("case is part of the contract — lowercase value must NOT equal canonical")
    func caseSensitivity() {
        // If the production literal were ever lowercased, markerMatchesUpstream
        // fails; this test makes the case-trap explicit and self-documenting.
        #expect(Self.lowercaseTrap != Self.canonical)
        #expect(SSE.doneMarker != Self.lowercaseTrap)
    }

    @Test("doneFrame renders exactly the data-line consumers strip+trim+compare")
    func frameRoundTripThroughConsumerLogic() {
        // yieldSSERaw(marker) yields "data: \(marker)\n\n".
        #expect(SSE.doneFrame == "data: \(SSE.doneMarker)\n\n")

        // Emulate swift-huggingface HTTPClient: split on newline, take the
        // `data:` line, strip the `data: ` prefix, trimming whitespace/newlines,
        // then it compares the payload `==` the canonical terminator.
        let raw = SSE.doneFrame
        let lines = raw.split(separator: "\n")
        #expect(!lines.isEmpty)
        let dataLine = lines.first.map(String.init) ?? ""
        let prefix = "data: "
        #expect(dataLine.hasPrefix(prefix))
        let payload = String(dataLine.dropFirst(prefix.count))
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == Self.canonical)
    }

    @Test("marker is the exact 6-byte token (no stray/zero-width chars)")
    func markerLengthAndBytes() {
        let bytes = Array(SSE.doneMarker.utf8)
        #expect(bytes.count == 6)
        let expected: [UInt8] = [0x5B, 0x44, 0x4F, 0x4E, 0x45, 0x5D]
        #expect(bytes == expected)
    }
}
