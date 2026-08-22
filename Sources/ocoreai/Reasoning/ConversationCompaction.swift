// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConversationCompaction.swift — Rule-based context-window compaction.
///
/// When a chat request's estimated prompt size exceeds the model's per-model
/// `max_context_window` (omlx convention), ChatHandler Phase 3.5 previously
/// failed with a hard 400. This module adds a LLM-free compaction pass in
/// front of that wall: it removes the OLDEST fully-removable conversation
/// units first — while protecting the leading system instructions and the
/// most recent turns — and never orphans a tool result from the assistant
/// turn that issued its matching tool call.
///
/// Design notes:
/// - Parallels codex-rs `core/compact.rs` (compact toward a token budget,
///   leave a note describing what was removed) but stays deterministic and
///   local: no LLM round-trip in the hot request path.
/// - Token estimation mirrors the exact Phase 3 heuristic already used by
///   the wall check (UTF-8 bytes/4 for Latin-heavy, /3 when CJK-heavy,
///   avg bytes/char > 1.5) so the same number that drives the wall also
///   drives the compaction budget.
/// - Tool-call atomicity: an assistant message carrying `toolCalls` and the
///   CONSECUTIVE `tool` messages whose `toolCallID`s match are treated as one
///   unit. Removing only the assistant half would hand the model an orphan
///   tool result; removing only the results loses the model's observation.
/// - One-shot per request: applied at most once before the wall backstop;
///   the wall remains the source of the 400 when even a compacted transcript
///   still exceeds the cap.

import Foundation

/// Deterministic, LLM-free compaction of a chat transcript against a token
/// budget. Pure value-type core: every API is synchronous and side-effect
/// free, so the logic is exactly-testable without an engine or a handle.
enum ConversationCompaction {

    /// Budget + protection settings.
    struct Config: Equatable {
        /// Estimated token budget the final prompt must fit within.
        /// `nil` disables compaction (nothing is ever removed).
        var maxPromptTokens: Int?
        /// Tokens reserved for the expected reply; subtracted from
        /// `maxPromptTokens` before measuring the transcript.
        var reserveTokens: Int
        /// Number of LEADING messages (system, opening context) never removed.
        var protectedPrefixCount: Int
        /// Number of TRAILING messages (latest user/assistant turns) never removed.
        var protectedSuffixCount: Int

        init(
            maxPromptTokens: Int?,
            reserveTokens: Int = 4096,
            protectedPrefixCount: Int = 1,
            protectedSuffixCount: Int = 2
        ) {
            self.maxPromptTokens = maxPromptTokens
            self.reserveTokens = reserveTokens
            self.protectedPrefixCount = protectedPrefixCount
            self.protectedSuffixCount = protectedSuffixCount
        }
    }

    /// Result of a compaction pass.
    struct Result {
        /// The compacted message list, ready to feed to the model.
        let messages: [Message]
        /// Count of original messages removed (0 = input already fit).
        let removedCount: Int
        /// Human-readable summary of what was removed; `nil` when nothing
        /// was removed. When non-nil, the note is also embedded in `messages`
        /// as a system message so the model knows earlier turns were compacted.
        let summary: String?
        /// Estimated token count of `messages` under the same estimator.
        let estimatedTokens: Int
    }

    /// Estimate tokens for one message — mirrors ChatHandler Phase 3 exactly:
    /// UTF-8 bytes/4 for Latin-heavy text, /3 when CJK-heavy (avg bytes/char > 1.5).
    static func estimatedTokensPerMessage(_ message: Message) -> Int {
        let text = message.textContent()
        let bytes = text.utf8.count
        let chars = text.count
        let avg = chars > 0 ? Double(bytes) / Double(chars) : 1.0
        let divisor = avg > 1.5 ? 3 : 4
        return max(0, Int(Double(bytes) / Double(divisor)))
    }

    /// Estimated tokens for a whole transcript (per-message rule, in order).
    static func estimatePromptTokens(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimatedTokensPerMessage($1) }
    }

    /// The system note inserted into the transcript when compaction removed
    /// at least one message. Exposed as a constant so tests can assert the
    /// exact placement of the note.
    static let compactionNote =
        "[Context note] Earlier turns were compacted to fit the model's context window; the conversation continues from the most recent turns below."

    /// Compact `messages` to fit `config.maxPromptTokens` (after subtracting
    /// `config.reserveTokens`).
    ///
    /// Contract:
    /// - No-op (unchanged input, `removedCount == 0`, `summary == nil`) when
    ///   `maxPromptTokens` is nil, or when the transcript already fits.
    /// - Otherwise removes the OLDEST fully-removable units (a unit is either
    ///   one plain message or one atomic assistant + tool-result group) from
    ///   the region between the protected prefix and protected suffix, until
    ///   the whole final transcript (protected + compacted middle + note)
    ///   fits the target.
    /// - Stops when either the transcript fits, or the removable region is
    ///   exhausted. In the latter case the caller (ChatHandler) still owns
    ///   the 400 wall.
    /// - Deterministic: same input + same config always yields the same result.
    static func compact(_ messages: [Message], _ config: Config) -> Result {
        let n = messages.count
        let est = (0 ..< n).map { estimatedTokensPerMessage(messages[$0]) }
        let startEst = est.reduce(0, +)
        guard let budget = config.maxPromptTokens else {
            return Result(
                messages: messages, removedCount: 0, summary: nil, estimatedTokens: startEst)
        }
        let target = max(0, budget - config.reserveTokens)
        let noteEst = Self.noteEst
        if startEst <= target {
            return Result(
                messages: messages, removedCount: 0, summary: nil, estimatedTokens: startEst)
        }

        let prefixN = min(max(0, config.protectedPrefixCount), n)
        let suffixRoom = max(0, n - prefixN)
        let suffixN = min(max(0, config.protectedSuffixCount), suffixRoom)
        let firstSuffix = max(prefixN, n - suffixN)
        let fixedIdx = Array(0 ..< prefixN) + Array(firstSuffix ..< n)
        let fixedEst = fixedIdx.reduce(0) { $0 + est[$1] }

        // Removable region = messages strictly between the protected prefix and suffix.
        var region = Array(prefixN ..< firstSuffix)
        guard !region.isEmpty else {
            return Result(
                messages: messages, removedCount: 0, summary: nil, estimatedTokens: startEst)
        }

        // Greedy oldest-first sweep: remove units until the FINAL transcript
        // (protected prefix + note + remaining region + protected suffix) fits
        // the target, or the removable region is exhausted.
        var removed = 0
        while let oldest = region.first {
            if fixedEst + noteEst + region.reduce(0) { $0 + est[$1] } <= target { break }
            let unit = unitSpanFor(messages, startingAt: oldest).filter { region.contains($0) }
            guard !unit.isEmpty else { break }
            for i in unit { region.removeAll { $0 == i } }
            removed += unit.count
        }

        guard removed > 0 else {
            return Result(
                messages: messages, removedCount: 0, summary: nil, estimatedTokens: startEst)
        }

        var out: [Message] = Array(messages[0 ..< prefixN])
        out.append(Message(role: "system", content: .text(Self.compactionNote)))
        out.append(contentsOf: region.map { messages[$0] })
        out.append(contentsOf: messages[firstSuffix ..< n])
        return Result(
            messages: out,
            removedCount: removed,
            summary:
                "\(removed) earlier message(s) were compacted to fit the model's context window.",
            estimatedTokens: estimatePromptTokens(out)
        )
    }

    // MARK: - Internals

    private static var noteEst: Int {
        estimatedTokensPerMessage(Message(role: "system", content: .text(Self.compactionNote)))
    }

    /// Span of indices forming the atomic unit beginning at `startIdx`.
    /// A unit is `startIdx` alone, or `startIdx` followed by CONSECUTIVE
    /// `tool` messages whose `toolCallID` matches one of `startIdx`'s
    /// `toolCalls` (OpenAI wire order: assistant turn, then its tool results).
    /// Stops at the first tool message that does NOT match.
    private static func unitSpanFor(_ messages: [Message], startingAt startIdx: Int) -> [Int] {
        let first = messages[startIdx]
        guard first.role == "assistant", let calls = first.toolCalls, !calls.isEmpty else {
            return [startIdx]
        }
        let callIDs = Set(calls.map(\.id))
        var span = [startIdx]
        var i = startIdx + 1
        while i < messages.count {
            let m = messages[i]
            if m.role == "tool", let id = m.toolCallID, callIDs.contains(id) {
                span.append(i)
                i += 1
            } else {
                break
            }
        }
        return span
    }
}
