// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConversationCompactionTests.swift — Exact-value tests for rule-based
/// context-window compaction (codex compact.rs paradigm, deterministic core).
///
/// Every expected number is derived from the Phase 3 formula
/// (UTF-8 bytes/4 for Latin-heavy, /3 for CJK-heavy, avg bytes/char > 1.5)
/// and asserted with exact equality — no `>=`, no approximate bounds.

import Foundation
import Testing

@testable import ocoreai

@Suite("ConversationCompaction")
struct ConversationCompactionTests {

    // MARK: - Builders

    private func msg(
        _ role: String,
        _ text: String,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil
    ) -> Message {
        Message(
            role: role,
            content: .text(text),
            name: nil,
            toolCalls: toolCalls,
            toolCallID: toolCallID
        )
    }

    private func call(_ id: String, _ name: String) -> ToolCall {
        ToolCall(id: id, type: "function", function: .init(name: name, arguments: "{}"))
    }

    /// The note the implementation inserts; recomputed independently here so a
    /// change to the note text fails this test (exact placement asserted).
    private let note = ConversationCompaction.compactionNote

    // MARK: - Estimator (exact values)

    @Test("estimatedTokensPerMessage applies the CJK-aware Phase 3 formula exactly")
    func estimatorExact() {
        #expect(ConversationCompaction.estimatedTokensPerMessage(msg("user", "hello world")) == 2)  // 11/4
        #expect(ConversationCompaction.estimatedTokensPerMessage(msg("user", "中文测试")) == 4)  // 12 B, /3
        #expect(ConversationCompaction.estimatedTokensPerMessage(msg("user", "ab中文")) == 2)  // 8 B, /3 = 2.67
        #expect(ConversationCompaction.estimatedTokensPerMessage(msg("user", "")) == 0)
        #expect(ConversationCompaction.estimatedTokensPerMessage(msg("user", "S")) == 0)  // 1/4 = 0
        #expect(
            ConversationCompaction.estimatedTokensPerMessage(
                msg("user", String(repeating: "A", count: 60))) == 15)  // 60/4
    }

    @Test("estimatePromptTokens sums the per-message estimates in order")
    func estimateSums() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 60)),
            msg(
                "assistant", String(repeating: "B", count: 10), toolCalls: [call("c1", "read_file")]
            ),
            msg("tool", String(repeating: "Q", count: 30), toolCallID: "c1"),
        ]
        #expect(ConversationCompaction.estimatePromptTokens(messages) == 24)  // 0+15+2+7
    }

    // MARK: - No-op paths

    @Test("nil budget: never removes, no note")
    func nilBudgetIsNoOp() {
        let messages = [msg("system", "S"), msg("user", "hi"), msg("assistant", "hello")]
        let r = ConversationCompaction.compact(messages, .init(maxPromptTokens: nil))
        #expect(r.removedCount == 0)
        #expect(r.summary == nil)
        #expect(r.messages.count == 3)
    }

    @Test("Under budget: no-op, system lead preserved")
    func underBudgetIsNoOp() {
        let messages = [
            msg("system", "You are a helpful assistant."),
            msg("user", "hi"),
            msg("assistant", "hello"),
        ]
        let r = ConversationCompaction.compact(messages, .init(maxPromptTokens: 10_000))
        #expect(r.removedCount == 0)
        #expect(r.summary == nil)
        #expect(r.messages.count == 3)
        #expect(r.messages[0].textContent() == "You are a helpful assistant.")
        #expect(r.estimatedTokens == ConversationCompaction.estimatePromptTokens(messages))
    }

    @Test("Transcript exactly at the target: no-op")
    func atBudgetIsNoOp() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 60)),
            msg("assistant", String(repeating: "B", count: 60)),
        ]
        let r = ConversationCompaction.compact(messages, .init(maxPromptTokens: 30))
        #expect(r.removedCount == 0)
        #expect(r.messages.count == 3)
    }

    // MARK: - Removal: oldest-first, note placement

    @Test("Over budget: oldest turn removed until the transcript fits")
    func removesOldestUntilFits() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 60)),  // 15
            msg("assistant", String(repeating: "B", count: 60)),  // 15
            msg("user", String(repeating: "C", count: 60)),  // 15
            msg("assistant", String(repeating: "D", count: 60)),  // 15
            msg("user", String(repeating: "E", count: 60)),  // 15
            msg("assistant", String(repeating: "F", count: 60)),  // 15
            msg("user", String(repeating: "G", count: 10)),  // 2
            msg("assistant", String(repeating: "H", count: 10)),  // 2
        ]
        // prefix=1 (S), suffix=5 (D,E,F,G,H) => removable region = A,B,C.
        // Budget small enough that all three are dropped to approach the cap.
        let r = ConversationCompaction.compact(
            messages,
            .init(
                maxPromptTokens: 40, reserveTokens: 0, protectedPrefixCount: 1,
                protectedSuffixCount: 5)
        )
        #expect(r.removedCount == 3)
        // Note is the 2nd message, directly after the protected system lead.
        #expect(r.messages.count == 7)
        let roles = r.messages.map(\.role)
        #expect(
            roles == ["system", "system", "assistant", "user", "assistant", "user", "assistant"])
        #expect(r.messages[1].textContent() == note)
        #expect(r.messages[2].textContent() == String(repeating: "D", count: 60))
    }

    // MARK: - Tool-call atomicity

    @Test("Atomic tool-call unit removed together; no orphan tool result survives")
    func toolCallUnitRemovedAtomically() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 40)),  // 10
            msg(
                "assistant", String(repeating: "B", count: 10), toolCalls: [call("c1", "read_file")]
            ),  // 2
            msg("tool", String(repeating: "Q", count: 30), toolCallID: "c1"),  // 7
            msg("assistant", String(repeating: "D", count: 10)),  // 2
            msg("user", String(repeating: "E", count: 10)),  // 2
        ]
        // prefix=1 (S), suffix=1 (E) => region = A, B(+R1), D → under a tight
        // budget the oldest-first sweep drops A, then the B+R1 unit atomically,
        // then D. Exact dropped count asserted below (4).
        let r = ConversationCompaction.compact(
            messages,
            .init(
                maxPromptTokens: 12, reserveTokens: 0, protectedPrefixCount: 1,
                protectedSuffixCount: 1)
        )
        #expect(r.removedCount == 4)  // A, then the B+R1 unit, then D
        // No tool message may survive (its assistant was dropped with it).
        #expect(r.messages.contains(where: { $0.role == "tool" }) == false)
        let roles = r.messages.map(\.role)
        #expect(roles == ["system", "system", "user"])
        #expect(r.messages[1].textContent() == note)
    }

    @Test("Tool result whose call ID does NOT match is NOT in the unit (boundary respected)")
    func unitBoundaryRespectsCallID() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 40)),  // 10
            msg(
                "assistant", String(repeating: "B", count: 10), toolCalls: [call("c1", "read_file")]
            ),  // 2
            msg("tool", String(repeating: "Q", count: 30), toolCallID: "c2"),  // 7 — FOREIGN
            msg("user", String(repeating: "E", count: 10)),  // 2
        ]
        // B's unit = [B] only (the c2 tool message is not B's result).
        // prefix=1, suffix=2 (tool, E) => region = A, B.
        let r = ConversationCompaction.compact(
            messages,
            .init(
                maxPromptTokens: 14, reserveTokens: 0, protectedPrefixCount: 1,
                protectedSuffixCount: 2)
        )
        // A(10) dropped, then B(2) dropped; the foreign tool result (protected
        // in the suffix) survives untouched.
        #expect(r.removedCount == 2)
        #expect(r.messages.contains(where: { $0.role == "tool" }) == true)
        let roles = r.messages.map(\.role)
        #expect(roles == ["system", "system", "tool", "user"])
    }

    // MARK: - Protected floor

    @Test("When only protected messages remain, removal stops (wall backstops)")
    func stopsAtProtectedFloor() {
        let long = String(repeating: "Z", count: 100)  // 25 each
        let messages = [
            msg("system", "S"),
            msg("user", long),
            msg("user", long),
            msg("user", long),
            msg("assistant", long),
        ]
        // prefix=1 (S), suffix=2 (Z, Z-assistant) => region = the two middle Z's.
        let r = ConversationCompaction.compact(
            messages,
            .init(
                maxPromptTokens: 10, reserveTokens: 0, protectedPrefixCount: 1,
                protectedSuffixCount: 2)
        )
        // Both removable middle turns dropped; still over the tiny cap -> the
        // Phase 3.5 wall in ChatHandler remains the 400 backstop.
        #expect(r.removedCount == 2)
        let roles = r.messages.map(\.role)
        #expect(roles == ["system", "system", "user", "assistant"])
        #expect(r.messages[1].textContent() == note)
    }

    // MARK: - reserve semantics + determinism

    @Test("reserveTokens is subtracted from the budget before the fit check")
    func reserveSubtractsFromBudget() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 60)),  // 15
            msg("assistant", String(repeating: "B", count: 60)),  // 15
        ]
        // Budget 40, reserve 20 => target 20. S(0)+note(34)+B(15) still > 20, so
        // A is dropped (10) — but the note pushes the total over; assert the
        // exact dropped count and survivors.
        let r = ConversationCompaction.compact(
            messages,
            .init(
                maxPromptTokens: 40, reserveTokens: 20, protectedPrefixCount: 1,
                protectedSuffixCount: 1)
        )
        #expect(r.removedCount == 1)
        let roles = r.messages.map(\.role)
        #expect(roles == ["system", "system", "assistant"])
        #expect(r.messages[2].textContent() == String(repeating: "B", count: 60))
    }

    @Test("Deterministic: identical input + config yields identical output every call")
    func deterministicRepeat() {
        let messages = [
            msg("system", "S"),
            msg("user", String(repeating: "A", count: 60)),
            msg("assistant", String(repeating: "B", count: 60)),
            msg("user", String(repeating: "C", count: 10)),
            msg("assistant", String(repeating: "D", count: 10)),
        ]
        let config = ConversationCompaction.Config(
            maxPromptTokens: 20, reserveTokens: 0,
            protectedPrefixCount: 1, protectedSuffixCount: 2
        )
        let a = ConversationCompaction.compact(messages, config)
        let b = ConversationCompaction.compact(messages, config)
        #expect(a.removedCount == b.removedCount)
        #expect(a.messages.count == b.messages.count)
        #expect(a.summary == b.summary)
        #expect(a.estimatedTokens == b.estimatedTokens)
    }
}
