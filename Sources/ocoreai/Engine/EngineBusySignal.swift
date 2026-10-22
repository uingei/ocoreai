// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineBusySignal — one home for "the engine is at capacity".
///
/// Why this exists as a type and not a string at two call sites (measured 10-22, live):
/// the MLX path emitted the literal `"Engine busy"` on the error channel, the handler
/// turned any error-channel string into `AppError.generationError`, and the wire answered
/// **500 `app_error`** — while `AppError.engineBusy` already existed two files away and
/// already mapped to 429. So the same condition had two homes and the one actually taken
/// was the wrong one: a client that backs off on 429 retried forever against a 500.
///
/// Capacity is also not an instant refusal. `vllm` and `sglang` queue rather than reject
/// (`sglang` signals capacity with 503 `overloaded_error`, not a per-request 500:
/// `sglang/python/sglang/srt/entrypoints/http_server.py:595`); an unbounded wait would
/// just move the problem, so the wait is bounded and the refusal names when to come back.
import Foundation
import Logging

enum EngineBusySignal {
    /// The marker the engine puts on the error channel. Handlers map it to
    /// ``AppError/engineBusy``; anything else on that channel is a generation failure.
    static let message = "Engine busy"

    /// How long a second request waits for the lock before it is refused.
    static let envWait = "OCOREAI_ENGINE_BUSY_WAIT"
    static let defaultWaitSeconds = 20
    static let maxWaitSeconds = 120

    /// Robust to wrapping: some paths prefix the message ("Generation failed: Engine busy"),
    /// and a wrapped capacity refusal is still a capacity refusal.
    static func isBusy(_ text: String) -> Bool {
        text.contains(message)
    }

    /// Operator knob, clamped: `0` restores the old fail-fast behavior (every concurrent
    /// request refused immediately), useful for a caller that would rather retry than wait.
    static var waitSeconds: Int {
        let raw = ProcessInfo.processInfo.environment[envWait]
        guard let parsed = raw.flatMap({ Int($0) }) else { return defaultWaitSeconds }
        return min(max(parsed, 0), maxWaitSeconds)
    }

    static var wait: Duration { .seconds(waitSeconds) }

    /// The queue has to be visible in the log, or a 200 after a wait is indistinguishable
    /// from a turn that never overlapped: measured 10-22, probe 29's queue leg passed while
    /// nothing had contended, because the chat face never said it had queued (only the
    /// token face did). One home, both faces, one string for the probe to grep.
    static let log = Logger(label: "ocoreai")

    static func logQueued(waitMs: Int, face: String) {
        log.info("Queued for inference: +\(waitMs)ms (face=\(face))")
    }

    /// The refusal names the window it spent waiting, so "busy" is a measured duration and
    /// not an assertion; `\(envWait)=0` is the escape hatch back to fail-fast.
    static func logRefused(face: String) {
        log.warning(
            "Engine busy — refused after \(waitSeconds)s queued (face=\(face), \(envWait)=0 refuses immediately)"
        )
    }

    /// A 429 without `Retry-After` makes the client guess the backoff; RFC 9110 §10.2.3
    /// gives the number a home, and here it is exactly the window the server just spent
    /// waiting. `0` (fail-fast mode) still has to promise at least one second.
    static var retryAfterSeconds: Int { max(1, waitSeconds) }
}
