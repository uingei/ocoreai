// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProcessGlobalLease. Exclusive access, in tests, to state that is global to the process.
///
/// `SessionWorkspace`'s active directory (an `NSLock`-guarded singleton), `OCOREAI_WORKSPACE`
/// and `OCOREAI_MODELS_DIR` are process-wide: they have no per-test scope, so two tests
/// touching them read each other's values.
///
/// `.serialized` does not fix this. It orders a suite's *own* tests, not suites against each
/// other. Measured 10-22: `WorkspacePathAnchorTests` and `SessionWorkspaceWorktreeTests` both
/// carry `.serialized`, and running them together with `EditMismatchRecoveryTests` failed in
/// 3/3 runs with three different victims (one suite resolved `calc.py` inside another suite's
/// temp dir; `effectiveCwd` picked up a foreign `OCOREAI_WORKSPACE`). The same shape crashed
/// the runner outright once: a foreign `OCOREAI_MODELS_DIR` made `localCoreAIModelDir` return
/// nil and a force-unwrap SIGTRAP'd the process, so every suite scheduled after it reported
/// nothing.
///
/// Every test that touches one of those globals takes a lease and releases it in a `defer`.
/// Releasing restores each key to whatever the process held *before* the lease. Unset if it held
/// nothing, and drops the shared workspace, so a value CI exported survives the suite while a
/// value a test invented does not. One slot covers all of them: contention costs seconds, a
/// missed collision costs a false green.
///
/// Gate: adoption is Class-S of `scripts/audit.swift_patterns.sh` (floored, no-build, so
/// `push-ready` / `make audit` / the ubuntu lint leg read it every round); the save/restore
/// contract is `ProcessGlobalLeaseDisciplineTests`.
import Foundation
import Testing

@testable import ocoreai

final class ProcessGlobalLease: @unchecked Sendable {
    /// The slot is a semaphore, not an `NSLock`, because the wait and the release now live on
    /// different threads by design (see `init`): a semaphore is made for that hand-off, an
    /// `NSLock` is owned by the thread that took it. A timed-out wait consumes no permit, and a
    /// starved lease never signals, so one permit is exactly one holder.
    private static let slot = DispatchSemaphore(value: 1)
    /// How long a holder may sit before every waiter reports it rather than endure it. A holder
    /// does bounded *local* I/O: measured 10-26, every lease here is held for milliseconds once
    /// the hub-facing suites stopped paying a real connect timeout (holds that cross an await —
    /// scripted-lane fixtures, an ACP load — became survivable on 11-27 because the wait is
    /// non-parking, but they must stay in that milliseconds band: the budget below still goes
    /// red on a hog). A minute is orders of magnitude above the band, and it is not a licence to
    /// do a minute of work under a process-global lease: at 240 s one leaked lease cost every
    /// waiter four minutes, which is how a 122 s run became 370 s with nine false reds.
    static let waitBudget: TimeInterval = 60
    /// Written while the lock is free (i.e. by the holder), read by a waiter that just lost the
    /// race. A benign race by construction, and only ever used to name a stall in a message.
    nonisolated(unsafe) private static var holder: String = "<never>"
    nonisolated(unsafe) private static var heldSince = Date.distantPast

    private let envKeys: [String]
    private let savedValues: [String: String]
    private var held = true

    /// A blocked cooperative thread is the hazard this class had to acquire: measured 10-26, five
    /// parallel `ReadyHubDownloaderFlatTests` cases each entered `freshModelRoot()`, nineteen
    /// cooperative threads parked on `NSLock.lock`, and the run stalled past 13 minutes because the
    /// holder's continuation had no thread left to resume on. Bounding the wait turned that hang into
    /// reds but kept the convoy: measured 11-27, one holder crossing `waitBudget` parked enough
    /// cooperative threads that holders and waiters alike stalled — 86 suites red around a single
    /// 60 s hold, a pure test costing 180 s, and every starved suite proceeding unleased onto
    /// someone else's globals. So the wait now suspends: the timed `NSLock` wait runs on a GCD
    /// worker thread (which expands and never feeds the Swift concurrency pool) and the test's
    /// cooperative thread returns to the pool while it waits. The budget stays as the hog tripwire.
    init(envKeys: [String] = [], caller: String = #function) async {
        let deadline = DispatchTime.now() + Self.waitBudget
        let acquired = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.slot.wait(timeout: deadline) == .success)
            }
        }
        guard acquired else {
            self.envKeys = envKeys
            self.savedValues = [:]
            self.held = false
            Issue.record(
                "lease starved after \(Self.waitBudget)s — held by \(Self.holder) for \(-Self.heldSince.timeIntervalSinceNow)s; the holder sat on the process globals far past the budget, so this test proceeds unleased and the run goes red"
            )
            return
        }
        Self.holder = caller
        Self.heldSince = Date()
        self.envKeys = envKeys
        var saved: [String: String] = [:]
        for key in envKeys {
            if let value = ProcessInfo.processInfo.environment[key] { saved[key] = value }
        }
        self.savedValues = saved
    }

    /// Return the process globals to the state this lease found, then hand them to the next test.
    func release() {
        guard held else { return }
        held = false
        Self.holder = "<released>"
        Self.heldSince = Date()
        SessionWorkspace.clear()
        for key in envKeys {
            if let value = savedValues[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        Self.slot.signal()
    }
}
