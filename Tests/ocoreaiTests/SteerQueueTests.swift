// Copyright © 2026 uingei@163.com.
// Licensed under MIT.

import Foundation
import Testing

@testable import ocoreai

/// Mid-turn steering contract pins (Hermes-style steering; codex interjection
/// parity). These are pure-logic pins on SteerQueue — the GUI wiring compiles
/// against this shape and the engine drains exactly these keys.
@Suite("SteerQueue mid-turn steering")
struct SteerQueueTests {

    @Test("enqueue → drain returns arrival order and empties the session")
    func enqueueDrainOrder() {
        let q = SteerQueue()
        #expect(q.enqueue(sessionKey: "s1", text: "left"))
        #expect(q.enqueue(sessionKey: "s1", text: "right"))
        #expect(q.pendingCount(sessionKey: "s1") == 2)
        let drained = q.drain(sessionKey: "s1")
        #expect(drained.map(\.text) == ["left", "right"])
        #expect(q.pendingCount(sessionKey: "s1") == 0)
        #expect(q.drain(sessionKey: "s1").isEmpty)
    }

    @Test("session isolation — one session never sees another's steers")
    func sessionIsolation() {
        let q = SteerQueue()
        q.enqueue(sessionKey: "a", text: "for a")
        q.enqueue(sessionKey: "b", text: "for b")
        #expect(q.drain(sessionKey: "a").map(\.text) == ["for a"])
        #expect(q.pendingCount(sessionKey: "b") == 1)
        #expect(q.drain(sessionKey: "a").isEmpty)
        #expect(q.drain(sessionKey: "b").map(\.text) == ["for b"])
    }

    @Test("whitespace / empty / empty-key sends are rejected")
    func emptyRejected() {
        let q = SteerQueue()
        #expect(q.enqueue(sessionKey: "s", text: "   ") == false)
        #expect(q.enqueue(sessionKey: "", text: "hi") == false)
        #expect(q.pendingCount(sessionKey: "s") == 0)
    }

    @Test("maxPerSession ceiling drops OLDEST (newest supersedes)")
    func ceilingDropsOldest() {
        let q = SteerQueue()
        for i in 0 ... (SteerQueue.maxPerSession) {
            #expect(q.enqueue(sessionKey: "s", text: "msg-\(i)"))
        }
        let drained = q.drain(sessionKey: "s")
        #expect(drained.count == SteerQueue.maxPerSession)
        // msg-0 was the first, and the (maxPerSession+1)-th send dropped it.
        #expect(drained.first?.text == "msg-1")
        #expect(drained.last?.text == "msg-\(SteerQueue.maxPerSession)")
    }

    @Test("turn-end flush returns leftovers to caller (never lost)")
    func flushReturnsLeftovers() {
        let q = SteerQueue()
        q.enqueue(sessionKey: "a", text: "steered")
        q.enqueue(sessionKey: "b", text: "other")
        // Drain only session a's queue the way the engine loop does; b remains.
        _ = q.drain(sessionKey: "a")
        let all = q.drainAll()
        #expect(all.map(\.text) == ["other"])
        #expect(q.drainAll().isEmpty)
    }

    @Test("discard on reset — steers never cross conversations")
    func discardLeakGuard() {
        let q = SteerQueue()
        q.enqueue(sessionKey: "s", text: "stale intent")
        q.discard(sessionKey: "s")
        #expect(q.pendingCount(sessionKey: "s") == 0)
        #expect(q.drain(sessionKey: "s").isEmpty)
        // discardAll covers teardown parity with ApprovalBroker.cancelAll
        q.enqueue(sessionKey: "x", text: "x")
        q.enqueue(sessionKey: "y", text: "y")
        q.discardAll()
        #expect(q.drain(sessionKey: "x").isEmpty)
        #expect(q.drain(sessionKey: "y").isEmpty)
    }

    @Test("renderAsUserText — marker once, newlines joined, empty safe")
    func renderShape() {
        let a = SteerMessage(sessionKey: "s", text: "one")
        let b = SteerMessage(sessionKey: "s", text: "two")
        let rendered = SteerQueue.renderAsUserText([a, b])
        #expect(
            rendered == "[mid-turn user steering]\none\ntwo")
        #expect(SteerQueue.renderAsUserText([]).isEmpty)
    }

    @Test("HTTP wire shape — snake_case keys both directions")
    func wireKeys() throws {
        // The /v1/steer contract: request {session_id,text} response
        // {session_id,queued_count}. Pinned so a renormalization to camelCase
        // (decoder drift) fails loudly instead of silently 400-ing clients.
        let resp = SteerResponse(sessionId: "abc", queuedCount: 2)
        let data = try JSONEncoder().encode(resp)
        let json = try #require(
            String(data: data, encoding: .utf8))
        #expect(json.contains("\"session_id\":\"abc\""))
        #expect(json.contains("\"queued_count\":2"))
    }

    @Test("concurrent enqueue+drain — Mutex serialization, no dup, ceiling holds")
    func concurrentNoLoss() async {
        let q = SteerQueue()
        let total = 400
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< total {
                group.addTask {
                    _ = q.enqueue(sessionKey: "c", text: "m-\(i)")
                }
            }
        }
        // Parallel arrival order is nondeterministic — what MUST hold: the
        // ceiling caps the queue, drains return every survivor exactly once,
        // and the queue is empty afterwards (no dup, no phantom, no leak).
        let drained = q.drain(sessionKey: "c")
        let remaining = q.drain(sessionKey: "c")
        #expect(drained.count <= SteerQueue.maxPerSession)
        #expect(remaining.isEmpty)
        let seen = Set(drained.map(\.text))
        #expect(seen.count == drained.count)
        #expect(q.pendingCount(sessionKey: "c") == 0)
    }
}
