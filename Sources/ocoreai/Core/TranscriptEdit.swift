// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TranscriptEdit.swift — pure policy for "fix my last instruction and rerun".
///
/// ### Why this exists (proven gap, 2026-10-12)
/// `git grep "editMessage|beginEditing" Sources/` = 0. The transcript offered
/// *Regenerate* (re-run the same user text — `ChatView` context menu →
/// `ChatState.resendFromMessage`) but never offered *Edit*. When an agent goes
/// off-course because the instruction was imprecise, every comparable product
/// (LM Studio Bionic, the Codex app, ChatGPT/Claude) lets the user correct the
/// instruction **in place** and rerun from there; the only thing ocoreai offered
/// was to append a correction — which permanently pollutes the context with the
/// wrong instruction plus an apology. Recoverability is a first-principles
/// requirement for an agent that takes actions, not a nicety.
///
/// ### Durability is part of the feature, not a follow-up
/// Inference history is built from the in-memory transcript
/// (`chat()` → `cleanMessages(messages)`), while SQLite is what a session reload
/// renders. Truncating only memory therefore makes the UI and the database
/// disagree: the rerun behaves correctly *now*, and the discarded turn (with the
/// pre-edit text) walks back in the next time the session is opened. So the plan
/// carries a `dropCount`, and `SessionCompressor.dropTranscriptTail` mirrors it
/// to SQLite — one primitive shared by both Edit-and-Resend and Regenerate, so
/// the two can never drift apart again.
///
/// ### First principles encoded here
/// 1. Only the user's own messages are editable — never the model's words.
/// 2. An empty edit is not a resend — never fire a turn on blank input.
/// 3. Editing reruns from that point: the edited message and everything after it
///    are dropped, so the model never sees the abandoned branch.
/// 4. Missing target (unknown id / index out of range) is reported, never guessed.
/// 5. `dropCount` is derived from the transcript length, so a short database
///    deletes what exists — never more.

import Foundation

/// Pure edit-and-resend planning. No UI, no SQLite, no globals — every rule is
/// assertable from value in / value out (same shape as `ComposerIngest`).
enum TranscriptEdit {

    /// Reasons a resend request cannot be honored.
    enum EditError: Error, Equatable {
        /// No transcript item at that index (id did not resolve).
        case notFound
        /// The target exists but is not a user message.
        case notUser
        /// The edit left nothing to send.
        case emptyText
    }

    /// What to do once an edit is accepted.
    struct Plan: Equatable {
        /// Index in the live transcript of the message being edited.
        let index: Int
        /// Items removed from the transcript: the edited message + everything after it.
        let dropCount: Int
        /// Text to send as the replacement user turn (trimmed, never empty).
        let newText: String
    }

    /// Plan an edit against the transcript roles.
    ///
    /// - Parameters:
    ///   - roles: roles of the live transcript, oldest first (usually
    ///     `messages.map(\.role)` — taken as data so this stays UI-free).
    ///   - editing: index of the message the user chose to edit, or `nil` when
    ///     the id did not resolve to a transcript item.
    ///   - rawText: the edited text as typed.
    static func plan(
        roles: [String], editing index: Int?, rawText: String
    ) -> Result<Plan, EditError> {
        guard let index else { return .failure(.notFound) }
        guard index >= 0, index < roles.count else { return .failure(.notFound) }
        guard roles[index] == "user" else { return .failure(.notUser) }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyText) }
        return .success(
            Plan(index: index, dropCount: roles.count - index, newText: trimmed))
    }

    /// Whether the tail drop may be mirrored to SQLite. Persisting needs a live
    /// session row; the pre-send state of a brand-new chat has `sessionId == nil`,
    /// and a nil session means there is nothing durable to truncate yet.
    static func shouldMirrorToStore(sessionId: Int64?, dropCount: Int) -> Bool {
        sessionId != nil && dropCount > 0
    }
}
