// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ProcessGlobalLeaseDisciplineTests, the lease contract: what a release hands back.
//!
//! The *adoption* scan (every Tests file that mutates a process-global also takes a lease) used to
//! live here, and reading its verdict cost a debug build and a Metal run — a file joined the
//! offender list at `1f201c0c` (11-25) and stayed red two days unread, long enough for its race to
//! write another suite's test file into the repo root (the 11-27 `x.py`). The scan is a pure file
//! pattern, so it moved to `scripts/audit.swift_patterns.sh` Class-S: same semantics, same floors,
//! and seats that actually run (`make push-ready`, `make audit`, the ubuntu lint leg).
//! What stays here is what only a running process can prove: the save/restore contract of the
//! lease itself — a value the process came in with survives the suite that borrowed the key, and a
//! value a test invented does not.
import Foundation
import Testing

@testable import ocoreai

@Suite("process globals — the lease hands back what the process already had")
struct ProcessGlobalLeaseDisciplineTests {

    @Test("release restores the prior value")
    func releaseRestoresThePriorValue() async {
        let key = "OCOREAI_LEASE_DISCIPLINE_PROBE"
        setenv(key, "outer", 1)
        defer { unsetenv(key) }

        let lease = await ProcessGlobalLease(envKeys: [key])
        setenv(key, "inner", 1)
        #expect(
            ProcessInfo.processInfo.environment[key] == "inner", "the lease does not block writes")
        lease.release()
        #expect(
            ProcessInfo.processInfo.environment[key] == "outer",
            "a value the process came in with survives the suite that borrowed the key")
    }

    @Test("a key the process did not have is not left behind")
    func releaseClearsAnInventedKey() async {
        let key = "OCOREAI_LEASE_DISCIPLINE_PROBE_2"
        unsetenv(key)

        let lease = await ProcessGlobalLease(envKeys: [key])
        setenv(key, "invented", 1)
        lease.release()
        #expect(
            ProcessInfo.processInfo.environment[key] == nil,
            "what a test invented must not outlive it — that is how a temp MODELS_DIR leaked")
    }
}
