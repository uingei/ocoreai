// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineBusyAdmissionTests — capacity is a status, and a queue must not sleep on the deadline.
///
/// Measured 10-22 (`scripts/eval`, run-3): 13 consecutive tasks in 4 seconds answered
/// `{"error":{"message":"Generation failed: Engine busy","code":500}}`. The engine's
/// contention guard was a fail-fast CAS, and the handler turned any error-channel string into
/// `generationError` — so a well-formed request against an occupied engine was reported as a
/// server failure, while `AppError.engineBusy` (429) sat unused two files away.
import Foundation
import Testing

@testable import ocoreai

@Suite("Engine busy — admission and status", .serialized)
struct EngineBusyAdmissionTests {

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ToolError.checkFailed("no .git above \(#filePath) — the scan below has no root")
    }

    @Test("a queued request starts the moment the lock frees, not at the deadline")
    func queueWakesOnRelease() async throws {
        let model = makeLoadedModel()
        #expect(model.tryAcquireInference())  // occupy it

        // The release instant is returned, not assumed. A wall-clock ceiling here (`waitedMs <
        // 1000`) took 120 ms as its premise, so it measured the host's scheduler: on a loaded
        // machine the *releaser* task is itself late, the waiter is correct to wait, and the
        // gate went red for a bug that was not there (measured in a full set run: this was the
        // last red on the host). Returning the instant makes the slack a measured difference,
        // which is the sentence the test's name actually claims.
        let releaser = Task<Int, Never> {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try? await Task.sleep(for: .milliseconds(120))
            model.releaseInference()
            return Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }

        // Control: what one 50 ms sleep costs on this host right now, measured while the waiter
        // waits. A set run shares one concurrency pool across thousands of tests, so wall clock
        // here is a property of the scheduler and the bound has to be too. Measured on this host
        // in set runs: a 50 ms poll landed 1109 ms and 2194 ms after the release, so any ceiling
        // of a few hundred ms reds the host rather than the code.
        let control = Task<Int, Never> {
            var worst = 0
            for _ in 0 ..< 4 {
                let tick = DispatchTime.now()
                try? await Task.sleep(for: .milliseconds(50))
                worst = max(worst, Self.msSince(tick))
            }
            return max(0, worst - 50)
        }
        let start = DispatchTime.now()
        let acquired = await model.acquireInference(waiting: .seconds(5))
        let waitedMs = Self.msSince(start)
        let freedAtMs = await releaser.value
        let controlMs = await control.value
        let wakeSlackMs = waitedMs > freedAtMs ? waitedMs - freedAtMs : 0

        #expect(
            acquired,
            "the lock freed at \(freedAtMs)ms of a 5000ms window and the waiter missed it")
        // The defect this suite exists for is `Task.sleep(until: deadline)` inside the pending
        // loop: it reaches the guard only when the window closes, so its signature is a wake
        // slack of ~4.8 s against a release at ~120 ms. The bound sits between the two measured
        // ends of this host's behaviour and that signature: the worst set-run wake here was
        // 2194 ms (3350 tests sharing one pool; the control reads low because a saturated
        // clock's tail is far worse than its median), and 3 s stays clearly under the defect.
        // Both ends are re-measurable, and the control term keeps the bound honest on a host
        // slower than this one.
        let budgetMs = max(3000, 4 * controlMs)
        #expect(
            wakeSlackMs < budgetMs,
            """
            wake slack \(wakeSlackMs)ms against a \(budgetMs)ms budget (host latency \
            \(controlMs)ms, lock freed at \(freedAtMs)ms, waiter took \(waitedMs)ms)
            """)
        model.releaseInference()
    }

    private static func msSince(_ epoch: DispatchTime) -> Int {
        Int(
            (epoch.uptimeNanoseconds.distance(to: DispatchTime.now().uptimeNanoseconds))
            / 1_000_000)
    }

    @Test("a full wait says no, and a zero wait says no immediately")
    func waitIsBounded() async throws {
        let model = makeLoadedModel()
        #expect(model.tryAcquireInference())

        let start = DispatchTime.now()
        let acquired = await model.acquireInference(waiting: .milliseconds(250))
        let waitedMs =
            (start.uptimeNanoseconds.distance(to: DispatchTime.now().uptimeNanoseconds)) / 1_000_000
        #expect(!acquired, "an occupied lock must time out rather than hang a caller")
        #expect(waitedMs >= 200 && waitedMs < 1500, "bounded wait measured \(waitedMs)ms")

        // fail-fast mode: an operator who would rather retry than wait gets an answer at t=0
        let immediate = await model.acquireInference(waiting: .zero)
        #expect(!immediate, "occupied lock + zero wait must refuse at once")
        model.releaseInference()
        #expect(await model.acquireInference(waiting: .zero), "free lock + zero wait = acquired")
        model.releaseInference()
    }

    @Test("capacity is 429 with a retry promise; a generation failure stays 500")
    func capacityIsNotAServerError() {
        #expect(AppError.engineBusy.status == .tooManyRequests)
        #expect(AppError.generationError("the model tripped").status == .internalServerError)
        #expect(EngineBusySignal.retryAfterSeconds >= 1, "Retry-After must never promise 0")
        // `isBusy` decides the status, so it has to catch the wrapped form too — the 500 body
        // this whole round is about is `Generation failed: Engine busy`.
        #expect(EngineBusySignal.isBusy(EngineBusySignal.message))
        #expect(EngineBusySignal.isBusy("Generation failed: Engine busy"))
        #expect(!EngineBusySignal.isBusy("Model not loaded"), "other failures keep their status")
    }

    @Test("the busy sentence has one home in the engine", arguments: ["EngineInference.swift"])
    func markerHasOneHome(_ file: String) throws {
        let root = try repoRoot()
        let dir = root.appendingPathComponent("Sources/ocoreai/Engine")
        let text = try String(
            contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        // Floor the scan's own premises: a path typo here would pass everything vacuously.
        #expect(
            text.contains("acquireInference(waiting:"),
            "\(file) must go through the bounded acquire, not a fail-fast CAS")
        #expect(
            text.contains("EngineBusySignal"),
            "\(file) must name the shared signal, not invent its own")
        // The literal is the regression: once a call site hardcodes it, the handler mapping and
        // the engine can disagree again, which is exactly how the 500 was born.
        let hardcoded =
            text
            .components(separatedBy: "\n")
            .filter {
                $0.contains("\"Engine busy\"")
                    && !$0.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("//")
            }
        #expect(
            hardcoded.isEmpty,
            "hardcoded busy literals came back in \(file) — one home is the fix: \(hardcoded)")
    }

    @Test(
        "the queue window is clamped, and 0 stays fail-fast",
        arguments: [
            ("0", 0), ("3", 3), ("999", EngineBusySignal.maxWaitSeconds),
            ("-4", 0), ("soon", EngineBusySignal.defaultWaitSeconds),
        ])
    func waitKnob(_ raw: String, _ expected: Int) throws {
        let lease = ProcessGlobalLease(envKeys: [EngineBusySignal.envWait])
        defer { lease.release() }
        setenv(EngineBusySignal.envWait, raw, 1)
        #expect(EngineBusySignal.waitSeconds == expected, "raw \(raw) must clamp to \(expected)")
    }
}
