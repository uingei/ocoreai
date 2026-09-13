// Copyright © 2026 uingeai.
// Licensed under MIT.
/// TranscriptPart tests for the `.truncatedByBudget` badge part (GAP-4 close).
///
/// The budget-truncation signal (Engine `.guidedGenDiagnostic(incompleteOutput:
/// true)` → DirectInferenceClient → final `DirectChatChunk.truncatedByBudget`)
/// must be user-visible by default: without an always-visible part, a
/// budget-truncated answer renders as a normal ending.
///
/// Strategy: @testable import + real `TranscriptPart` values — no mocks.

import Foundation
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - TranscriptPart.truncatedByBudget invariants

@Suite("TranscriptPart: .truncatedByBudget badge invariants")
struct TruncatedByBudgetPartTests {

    @Test("visibleByDefault is true — the user's only signal the answer is incomplete")
    func visibleByDefault() {
        #expect(TranscriptPart.truncatedByBudget.visibleByDefault == true)
    }

    @Test("displayText renders a non-empty truncation marker")
    func displayText() {
        let text = TranscriptPart.truncatedByBudget.displayText
        #expect(!text.isEmpty)
        #expect(text.lowercased().contains("truncat"))
    }

    @Test("hashable: .truncatedByBudget is a distinct stable identity")
    func hashableIdentity() {
        let a = TranscriptPart.truncatedByBudget
        let b = TranscriptPart.truncatedByBudget
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        // Must not collide with another badge part
        #expect(a != TranscriptPart.compactionNote(removedCount: 3))
    }

    @Test("Codable round-trip preserves the case")
    func codableRoundTrip() throws {
        let parts: [TranscriptPart] = [
            .text("partial answer"),
            .truncatedByBudget,
        ]
        let data = try JSONEncoder().encode(parts)
        let decoded = try JSONDecoder().decode([TranscriptPart].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[1] == .truncatedByBudget)
        #expect(decoded[1].visibleByDefault)
    }
}

// MARK: - ChatMessage surface for a truncated-termination badge

@Suite("TranscriptPart: .truncatedByBudget survives message flattening")
struct TruncatedByBudgetMessageTests {

    @Test("flatText includes the truncation marker (legacy-surface visibility)")
    func flatTextIncludesMarker() {
        let parts: [TranscriptPart] = [
            .text("Here is the reasoning..."),
            .truncatedByBudget,
        ]
        let msg = ChatMessage(role: "assistant", parts: parts)
        #expect(msg.hasParts)
        #expect(msg.textContent.lowercased().contains("truncat"))
    }

    @Test("coexists with compactionNote without cross-contamination")
    func coexistsWithCompaction() {
        let parts: [TranscriptPart] = [
            .compactionNote(removedCount: 5),
            .text("answer"),
            .truncatedByBudget,
        ]
        let msg = ChatMessage(role: "assistant", parts: parts)
        #expect(msg.textContent.contains("Compacted"))
        #expect(msg.textContent.lowercased().contains("truncat"))
    }
}
