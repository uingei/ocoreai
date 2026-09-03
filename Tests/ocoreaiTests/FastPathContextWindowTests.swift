// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FastPathContextWindowTests.swift — Exact-value tests for the Fast Path
/// context-window parity gate (`enforceContextWindow`, DirectInferenceClient).
///
/// Historical gap: the Fast Path used a bare 400 backstop while the wire path
/// (ChatHandler Phase 3.5) first ran a rule-based compaction pass — the same
/// prompt survived over HTTP (auto-compacted) but died with 400 in the native
/// UI. `enforceContextWindow` closes that branch with the wire path's exact
/// semantics: estimate → PreCompact veto → compact → adopt-if-fits → wall.
///
/// Every expected number is derived independently from the Phase 3 estimator
/// (UTF-8 bytes/4 for Latin text, avg bytes/char ≤ 1.5) and asserted with
/// exact equality — no `>=`, no approximate bounds.
///
/// See codex #42319 (live compaction status) + omlx `max_context_window`.

import Foundation
import Testing

@testable import ocoreai

// MARK: - Builders

/// Latin-heavy message: `estimatedTokensPerMessage` = bytes/4 (avg ≤ 1.5).
private func latin(_ n: Int) -> Message {
    Message(role: "user", content: .text(String(repeating: "a", count: n)))
}

/// The system note `ConversationCompaction.compact` inserts (exact constant).
private let noteText = ConversationCompaction.compactionNote

/// 6-message transcript, all removable-region-friendly (no tool units):
/// [20a, 200a, 204a, 20a, 200a, 12a] → per-msg estimates [5, 50, 51, 5, 50, 3].
/// prefixN=1 (20a), suffixN=2 (200a, 12a), removable region = [200a, 204a, 20a].
/// startEst = 164. noteEst ≈ 12 (note is 94 Latin chars → 23/2 rounded path;
/// asserted exactly against the estimator below rather than hardcoded).
private var fixture6: [Message] {
    [latin(20), latin(200), latin(204), latin(20), latin(200), latin(12)]
}

private func est(_ msgs: [Message]) -> Int {
    ConversationCompaction.estimatePromptTokens(msgs)
}

// MARK: - Suite

@Suite("FastPathContextWindowGate")
struct FastPathContextWindowGateTests {

    // MARK: - Fits → passthrough

    @Test("prompt under cap → transcript byte-identical, removedCount 0, store reflects it")
    func fitsCap() async throws {
        let msgs = fixture6
        let before = est(msgs)
        #expect(before == 164)  // 5 + 50 + 51 + 5 + 50 + 3 (exact, independent)

        let result = try await enforceContextWindow(cap: 200_000, messages: msgs)

        #expect(result.removedCount == 0)
        #expect(result.messages.count == msgs.count)
        #expect(
            result.messages.enumerated().allSatisfy { i, m in
                m.role == msgs[i].role && m.textContent() == msgs[i].textContent()
            })
        #expect(est(result.messages) == 164)

        // ContextStatusStore parity: `get_context_remaining` reads real values.
        let active = await ContextStatusStore.shared.peek()
        #expect(active != nil)
        #expect(active?.usedTokens ?? -1 == 164)
        #expect(active?.windowLimit ?? -1 == 200_000)
    }

    // MARK: - Over cap → compacts and survives (the wire-path behavior the UI lacked)

    @Test("over cap → oldest removable unit removed, note inserted, transcript survives")
    func overCapGetsCompacted() async throws {
        let msgs = fixture6
        #expect(est(msgs) == 164)  // sanity

        // cap 100: compact target = max(0, 100 - 4096) = 0 → remove from oldest
        // until fixedEst + noteEst + regionEst ≤ 0 (impossible) — so the greedy
        // sweep empties the removable region [200a, 204a, 20a] (50+51+5 = 106).
        let result = try await enforceContextWindow(cap: 100, messages: msgs)

        // All 3 removable units removed; prefix+suffix untouched, note in
        // position 1 (prefix, note, suffix[0], suffix[1]).
        #expect(result.removedCount == 3)
        #expect(result.messages.count == 4)
        #expect(result.messages[0].role == "user")
        #expect(result.messages[0].textContent() == String(repeating: "a", count: 20))
        #expect(result.messages[1].role == "system")
        #expect(result.messages[1].textContent() == noteText)
        #expect(result.messages[2].textContent() == String(repeating: "a", count: 200))
        #expect(result.messages[3].textContent() == String(repeating: "a", count: 12))

        // Final estimate fits cap → no wall. Exact value, independently derived:
        // fixed prefix(5) + suffix(50+3) = 58, plus the note's estimate.
        let noteEst = ConversationCompaction.estimatedTokensPerMessage(
            Message(role: "system", content: .text(noteText)))
        #expect(est(result.messages) == 58 + noteEst)
        #expect(est(result.messages) <= 100)
    }

    // MARK: - Over cap AND non-recoverable → 400 wall (identical message to wire)

    @Test("compactable region exhausted, still over cap → 400 wall with cap in message")
    func overCapStillFails() async {
        let msgs = fixture6
        #expect(est(msgs) == 164)  // sanity

        // cap 10: target 0, region fully emptied, still 63+noteEst > 10 → wall.
        do {
            _ = try await enforceContextWindow(cap: 10, messages: msgs)
            Issue.record("Expected AppError.invalidRequest (400 wall)")
        } catch let AppError.invalidRequest(msg) {
            // Same wall text as the wire path (ChatHandler Phase 3.5).
            #expect(msg.contains("configured context window of 10"))
            #expect(msg.contains("Shorten the input"))
        } catch {
            Issue.record("Expected AppError.invalidRequest, got \(type(of: error))")
        }
    }

    // MARK: - PreCompact veto (codex PreCompactHookOutcome::Stopped)

    @Test("PreCompact .deny → 400 regardless of remaining capacity")
    func preCompactVeto() async {
        let msgs = fixture6
        let runner = ToolHookRunner(hooks: [
            Hook(events: [.preCompact], matcher: nil) { _ in
                .deny(reason: "policy-veto")
            }
        ])
        do {
            _ = try await enforceContextWindow(
                cap: 100, messages: msgs, hookRunner: runner)
            Issue.record("Expected AppError.invalidRequest (veto)")
        } catch let AppError.invalidRequest(msg) {
            #expect(msg.contains("vetoed"))
            #expect(msg.contains("PreCompact"))
        } catch {
            Issue.record("Expected AppError.invalidRequest, got \(type(of: error))")
        }
    }

    // MARK: - No cap → passthrough even for a long transcript

    @Test("nil cap → passthrough, no compaction, no wall")
    func nilCap() async throws {
        let msgs = fixture6
        let result = try await enforceContextWindow(cap: nil, messages: msgs)
        #expect(result.removedCount == 0)
        #expect(result.messages.count == msgs.count)
    }
}
