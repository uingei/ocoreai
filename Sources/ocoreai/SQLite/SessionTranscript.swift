// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! SessionTranscript.swift — what one turn actually adds to a stored conversation.
//!
//! A chat client re-sends the whole history on every request, while `messages` rows are
//! append-only. Inserting the whole transcript each turn charged a session for the same
//! messages over and over (measured 10-21: three turns on one conversation key wrote one
//! snapshot session per request), and that running total is what ``SessionCompressor``
//! compares against `tokenThreshold` to decide when to prune — so the number that gates
//! memory was counting history once per turn.
//!
//! The rule comes from the conversation's own shape: both the stored rows and the incoming
//! transcript start at the beginning of the conversation, so what a turn adds is whatever
//! follows the longest prefix the stored rows already hold.

/// One persisted turn boundary: the pair a `messages` row is about.
struct TranscriptEntry: Equatable, Sendable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

extension TranscriptEntry {
    init(_ message: MessageModel) {
        self.init(role: message.role, content: message.content)
    }
}

enum SessionTranscript {

    /// The roles a conversation contributes to storage, in one place because two consumers
    /// read it: the in-memory filter below, and the SQL that reads a session's stored rows
    /// (`SessionCompressor.transcriptAscending`). A second hand-written `role IN (…)` list
    /// is how the two sides would drift into comparing different shapes.
    static let persistedRoles: [String] = ["user", "tool"]

    /// Entries `incoming` adds to a session whose stored transcript is `existing`
    /// (both oldest-first).
    ///
    /// - No stored rows ⇒ the whole transcript is new (first turn of a conversation).
    /// - `incoming` extends `existing` ⇒ only the tail is new — the ordinary turn.
    /// - `incoming` is a prefix of `existing` (a rewind) ⇒ nothing is added; the stored
    ///   rows already reach further than the client's view.
    /// - The two diverge mid-history (the client reworded a past turn) ⇒ everything from the
    ///   divergence on is appended. That is the best honest answer an append-only store can
    ///   give, and it is the same reason the engine refuses to reuse a KV cache for a
    ///   diverged transcript (`canReusePooledSession`).
    static func newEntries(
        existing: [TranscriptEntry], incoming: [TranscriptEntry]
    ) -> [TranscriptEntry] {
        var overlap = 0
        let limit = min(existing.count, incoming.count)
        while overlap < limit, existing[overlap] == incoming[overlap] {
            overlap += 1
        }
        return Array(incoming.dropFirst(overlap))
    }

    /// Which roles a conversation contributes to storage: what the client *said*.
    ///
    /// Assistant rows are written when this server generates them, and the instruction channel
    /// (`system`/`developer`) is not conversation content, so a re-sent history carries
    /// neither. Both sides of ``newEntries(existing:incoming:)`` must use this filter: the
    /// stored rows interleave assistant replies, so comparing them shape-for-shape against a
    /// client list that has none would stop the overlap at the first reply and re-store every
    /// earlier turn — the same defect this file exists to fix, one level down.
    static func persists(role: String) -> Bool {
        persistedRoles.contains(role)
    }

    /// The client transcript, oldest-first, in the shape storage keeps.
    static func client(_ messages: [Message]) -> [TranscriptEntry] {
        messages.filter { persists(role: $0.role) }
            .map { TranscriptEntry(role: $0.role, content: $0.textContent()) }
    }

    /// The rows already in a session, oldest-first, in the same shape as ``client(_:)``.
    static func stored(_ rows: [MessageModel]) -> [TranscriptEntry] {
        rows.filter { persists(role: $0.role) }.map(TranscriptEntry.init)
    }
}
