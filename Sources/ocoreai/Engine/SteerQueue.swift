// Copyright © 2026 uingei@163.com.
// Licensed under MIT.

// MARK: - Mid-turn steering queue
//
// First-principles shape of "steering": the user's next message must enter the
// model's context at the NEXT turn boundary — without killing the stream in
// flight, and without being silently swallowed. This mirrors Hermes Desktop's
// out-of-band steering and codex's `review` interjection semantics:
//
//   • Enqueue  — GUI composer routes text here while a stream is active
//                (instead of disabling input: a live agent that ignores the user
//                 for the whole turn is the "chat shell" failure mode).
//   • Drain    — the engine tool loop calls `drain(sessionKey:)` once per
//                iteration, before the next generation, and appends the drained
//                messages as user-role turns to the transcript.
//   • Flush    — loop ends with items still queued → they return to the GUI
//                composer (visible in transcript + input box), never lost.
//
// The transcript persistence in ChatState is the durable truth: a steer that
// never gets drained mid-loop still reaches the model on the NEXT request via
// SQLite history. The engine queue is only the fast path ("land it this turn").
//
// Keyed by convKey (the same conversationId the engine uses: sessionId or
// "<modelId>:ephemeral") so concurrent sessions never steal each other's
// steers.

import Foundation

/// One queued steering message.
public struct SteerMessage: Sendable, Equatable {
    public let id: UUID
    public let sessionKey: String
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionKey: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.text = text
        self.createdAt = createdAt
    }
}

/// Thread-safe steering queue (Mutex pattern shared with the engine,
/// `Engine/Mutex.swift`). All operations are O(n) over pending items — n is
/// bounded by `maxPerSession` so drain stays negligible on the hot path.
public final class SteerQueue: @unchecked Sendable {
    /// Hard ceiling per session — a user typing 50 steers into a runaway loop
    /// is a UX signal, not an unbounded queue. Overflow drops OLDEST (the
    /// newest steer supersedes them; the composer flush keeps the rest).
    public static let maxPerSession = 8

    /// Wire marker prefix injected as part of the user-role text so the model
    /// (and audit logs) can distinguish a mid-turn steering interjection from
    /// the original request. Same spirit as codex's interjection cell.
    public static let wireMarker = "[mid-turn user steering]"

    private let mutex = Mutex<[SteerMessage]>([])

    public init() {}

    /// Shared instance used by the GUI producer and engine consumer.
    public static let shared = SteerQueue()

    /// Enqueue a steer. Empty/whitespace text is rejected (returning false —
    /// the composer guard should already prevent this; belt-and-braces so a
    /// whitespace steer never reaches the transcript).
    @discardableResult
    public func enqueue(sessionKey: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessionKey.isEmpty else { return false }
        mutex.withLock { items in
            if items.filter({ $0.sessionKey == sessionKey }).count >= Self.maxPerSession {
                // Drop the oldest of this session to stay under the ceiling.
                if let idx = items.firstIndex(where: { $0.sessionKey == sessionKey }) {
                    items.remove(at: idx)
                }
            }
            items.append(SteerMessage(sessionKey: sessionKey, text: trimmed))
        }
        return true
    }

    /// Drain all steers for one session, in arrival order. Returns [] when
    /// none pending. The engine appends each as a user turn with the marker.
    public func drain(sessionKey: String) -> [SteerMessage] {
        mutex.withLock { items in
            let hit = items.enumerated().filter { $0.element.sessionKey == sessionKey }
            guard !hit.isEmpty else { return [] }
            // Remove hit indices back-to-front to keep index validity.
            for i in hit.reversed() {
                items.remove(at: i.offset)
            }
            return hit.map(\.element)
        }
    }

    /// Drain EVERYTHING (loop-end flush → GUI composer). Arrival order kept.
    public func drainAll() -> [SteerMessage] {
        mutex.withLock { items in
            let all = items
            items.removeAll()
            return all
        }
    }

    /// Render drained steers into a single user-role text (one append per
    /// iteration keeps transcript churn minimal). Multiple steers in one
    /// boundary are joined by newline, marker once.
    public static func renderAsUserText(_ steers: [SteerMessage]) -> String {
        guard !steers.isEmpty else { return "" }
        let body = steers.map(\.text).joined(separator: "\n")
        return "\(wireMarker)\n\(body)"
    }

    /// Pending count for a session (read-only; UI badge + test assertion).
    public func pendingCount(sessionKey: String) -> Int {
        mutex.withLock { items in
            items.filter { $0.sessionKey == sessionKey }.count
        }
    }

    /// Drop every pending steer for a session. MUST be called on
    /// `resetConversation` / cancellation: a queued steer belongs to the
    /// conversation the user was watching — carrying it into a NEW conversation
    /// would act on stale intent (same leak class as session-approved tools
    /// surviving `cancelAll()` in ApprovalBroker).
    public func discard(sessionKey: String) {
        mutex.withLock { items in
            items.removeAll { $0.sessionKey == sessionKey }
        }
    }

    /// Drop everything (app teardown / session-ended, ApprovalBroker
    /// `cancelAll()` semantics).
    public func discardAll() {
        mutex.withLock { items in
            items.removeAll()
        }
    }
}
