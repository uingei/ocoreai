// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! PipelineGate.swift — a counting gate that bounds in-flight Metal encodes.
//!
//! Why this type lives in its own file, and not inside `CoreAIPipelinedEngine.swift`:
//! it is a self-contained piece of concurrency accounting — an integer, a waiter queue and
//! `OSAllocatedUnfairLock` (`os`, macOS 13 / iOS 16 — below this package's floor of macOS 14 /
//! iOS 17, so the type needs no `@available` at all). It references no CoreAI and no Metal
//! symbol. Sitting inside that file's single file-level `#if canImport(CoreAI)` deleted it
//! on the macOS 26 delivery SDK anyway (AGENTS.md § Compile-time gates: a `#if canImport(X)`
//! must name the dependency the code inside actually uses), and — the part that mattered — it made
//! the class unreachable by any test on any runner this project has, while its comment claimed
//! "exercised by `PipelineGateTests`". That suite now exists and runs on the CLT route, so the
//! availability is whatever the *body* requires — here, nothing beyond the declared platforms.
//!
//! The invariant the suite pins is the one codex #55581 (`e8aa7c1678`, 10-20) fixes on the Rust
//! side: **a one-shot waiter must leave the state before it is consumed, and must never be
//! consumed twice.** codex left a `try_recv`-closed receiver in session state, so a later `await`
//! panicked instead of falling back. Here the analogous mistakes are "resume a waiter that is
//! still in `waiters`" (double resume ⇒ runtime trap) and "release a slot nobody holds" (the gate
//! becomes a permit factory and the OOM this type exists to prevent comes back).

import Foundation
import os

/// Bounds in-flight encode calls so MPSGraph's per-encode scratch
/// (sized by the graph's max shape — multiple GB on large models) can't accumulate.
///
/// Without this, the decode loop submits encodes (~220/s) faster than the sampler callback drains
/// them (~70/s); depth grows until `MPSCommandBufferImageCache` fails to allocate another private
/// MTLBuffer.
///
/// Capacity matches `pipelineDepth` — covers {logits encode + sampler commit + optional KV-cache
/// grow}; deeper queues only cost memory.
///
/// Class, not actor: `release()` runs synchronously from the Metal callback — an actor would force
/// `Task { await release() }` with ordering ambiguity.
/// `internal` (not `private`) so `PipelineGateTests` can reach it.

final class PipelineGate: Sendable {
    private struct State: Sendable {
        var inFlight: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Take a slot; suspend if all slots are busy.
    func acquire() async {
        // Fast path: take a slot without suspending.
        let takenImmediately = state.withLock { state -> Bool in
            guard state.inFlight < capacity else { return false }
            state.inFlight += 1
            return true
        }
        if takenImmediately { return }

        // Slow path: enqueue a waiter. Re-check under the lock in case a slot
        // opened between the fast path and now.
        await withCheckedContinuation { cont in
            let runImmediately = state.withLock { state -> Bool in
                if state.inFlight < capacity {
                    state.inFlight += 1
                    return true
                }
                state.waiters.append(cont)
                return false
            }
            if runImmediately { cont.resume() }
        }
    }

    /// Give back a slot. Called from the sampler's GPU-completion callback on a
    /// Metal callback thread; resumes any pending waiter (slot transferred
    /// directly without decrementing `inFlight`) or decrements the count.
    ///
    /// The waiter is resumed *outside* the lock so a rescheduled task can't
    /// re-enter `acquire` while we still hold it.
    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if !state.waiters.isEmpty {
                // Slot transferred to the woken waiter — inFlight count unchanged. The waiter is
                // out of `state` before anyone resumes it: exactly-once by construction, not by
                // luck in the caller.
                return state.waiters.removeFirst()
            }
            // Clamp at zero. An unbalanced release is a caller bug, but a gate that goes negative
            // hands out more permits than `capacity` and the encode backlog this type exists to
            // bound comes back — so the bug costs a dropped permit, never the box.
            if state.inFlight > 0 { state.inFlight -= 1 }
            return nil
        }
        waiter?.resume()
    }

    // Test-only introspection. Kept as underscored names to discourage
    // production use; exercised by PipelineGateTests.

    var _inFlightForTesting: Int {
        state.withLock { $0.inFlight }
    }

    var _waitersForTesting: Int {
        state.withLock { $0.waiters.count }
    }
}
