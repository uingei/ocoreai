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
/// Releasing clears the shared state, so nothing can outlive the test that set it. One lock
/// covers all of them: contention costs seconds, a missed collision costs a false green.
import Foundation

@testable import ocoreai

final class ProcessGlobalLease: @unchecked Sendable {
    private static let lock = NSLock()
    private let envKeys: [String]
    private var held = true

    init(envKeys: [String] = []) {
        Self.lock.lock()
        self.envKeys = envKeys
    }

    /// Drop the shared state, then hand the globals to the next test.
    func release() {
        guard held else { return }
        held = false
        SessionWorkspace.clear()
        for key in envKeys { unsetenv(key) }
        Self.lock.unlock()
    }
}
