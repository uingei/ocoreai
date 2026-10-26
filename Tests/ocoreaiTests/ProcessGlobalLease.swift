// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProcessGlobalLease — exclusive access, in tests, to state that is global to the process.
///
/// `SessionWorkspace`'s active directory (an `NSLock`-guarded singleton), `OCOREAI_WORKSPACE`
/// and `OCOREAI_MODELS_DIR` are process-wide: they have no per-test scope, so two tests
/// touching them read each other's values.
///
/// `.serialized` does not fix this — it orders a suite's *own* tests, not suites against each
/// other. Measured 10-22: `WorkspacePathAnchorTests` and `SessionWorkspaceWorktreeTests` both
/// carry `.serialized`, and running them together with `EditMismatchRecoveryTests` failed in
/// 3/3 runs with three different victims (one suite resolved `calc.py` inside another suite's
/// temp dir; `effectiveCwd` picked up a foreign `OCOREAI_WORKSPACE`). The same shape crashed
/// the runner outright once: a foreign `OCOREAI_MODELS_DIR` made `localCoreAIModelDir` return
/// nil and a force-unwrap SIGTRAP'd the process, so every suite scheduled after it reported
/// nothing.
///
/// Every test that touches one of those globals takes a lease and releases it in a `defer`.
/// Releasing restores each key to whatever the process held *before* the lease — unset if it held
/// nothing — and drops the shared workspace, so a value CI exported survives the suite while a
/// value a test invented does not. One lock covers all of them: contention costs seconds, a
/// missed collision costs a false green.
///
/// Gate: `ProcessGlobalLeaseDisciplineTests` — a floored scan that fails when a test file mutates
/// one of these globals without taking a lease, plus the save/restore contract itself.
import Foundation
import Testing

@testable import ocoreai

final class ProcessGlobalLease: @unchecked Sendable {
    private static let lock = NSLock()
    /// How long a waiter may sit before the convoy is reported rather than endured. A holder does
    /// bounded *local* I/O: measured 10-26, every lease here is held for milliseconds once the
    /// hub-facing suites stopped paying a real connect timeout. A minute is orders of magnitude
    /// above that, and it is not a licence to do a minute of work under a process-global lease —
    /// at 240 s one leaked lease cost every waiter four minutes, which is how a 122 s run became
    /// 370 s with nine false reds.
    static let waitBudget: TimeInterval = 60
    /// Written while the lock is free (i.e. by the holder), read by a waiter that just lost the
    /// race — a benign race by construction, and only ever used to name a stall in a message.
    nonisolated(unsafe) private static var holder: String = "<never>"
    nonisolated(unsafe) private static var heldSince = Date.distantPast

    private let envKeys: [String]
    private let savedValues: [String: String]
    private var held = true

    /// A blocked cooperative thread is the hazard this class had to acquire: measured 10-26, five
    /// parallel `ReadyHubDownloaderFlatTests` cases each entered `freshModelRoot()`, nineteen
    /// cooperative threads parked on `NSLock.lock`, and the run stalled past 13 minutes because the
    /// holder's continuation had no thread left to resume on. So the wait is bounded and attributed:
    /// a lease that cannot be had within `waitBudget` records a named failure and proceeds, which is
    /// a loud red instead of a silent hang, and the holder's own name travels in the message.
    init(envKeys: [String] = [], caller: String = #function) {
        let deadline = Date().addingTimeInterval(Self.waitBudget)
        guard Self.lock.lock(before: deadline) else {
            self.envKeys = envKeys
            self.savedValues = [:]
            self.held = false
            Issue.record(
                "lease starved after \(Self.waitBudget)s — held by \(Self.holder) for \(-Self.heldSince.timeIntervalSinceNow)s; a blocked cooperative thread starves the pool, so this test proceeds unleased and the run goes red"
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
        Self.lock.unlock()
    }
}
