// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SQLiteStore default path resolution — exact-value tests for the
/// `OCOREAI_DATA_DIR` env gate (R2b root-cause fix: a live-inference
/// regression harness must be able to run a real server end-to-end WITHOUT
/// writing into the operator's production `ocoreai.sqlite`; manual post-hoc
/// cleanup is the very foot-gun R2b hit. Same pattern as `OCOREAI_MODELS_DIR`
/// — ModelStore.swift:56).
import Foundation
import Testing

@testable import ocoreai

@Suite("SQLiteStore — OCOREAI_DATA_DIR env gate (exact path resolution)")
struct SQLiteStorePathResolutionTests {
    @Test("env set → path is <override>/ocoreai.sqlite verbatim (expanded)")
    func envOverrideAppendsSqliteName() {
        let result = SQLiteStore.resolveDefaultPath([
            "OCOREAI_DATA_DIR": "/tmp/ocoreai_harness/data"
        ])
        #expect(result == "/tmp/ocoreai_harness/data/ocoreai.sqlite")
        // Side contract: the override dir is created for the store to land in.
        #expect(FileManager.default.fileExists(atPath: "/tmp/ocoreai_harness/data"))
        try? FileManager.default.removeItem(atPath: "/tmp/ocoreai_harness")
    }

    @Test("env tilde-expansion — `~/x` resolves to the user's home prefix")
    func envTildeExpansion() {
        let result = SQLiteStore.resolveDefaultPath(["OCOREAI_DATA_DIR": "~/ocoreai_test_data"])
        let home = NSHomeDirectory()
        #expect(result.hasSuffix("/ocoreai_test_data/ocoreai.sqlite"))
        #expect(result.hasPrefix(home))
        // Do not leave test artifacts in the real home dir.
        try? FileManager.default.removeItem(
            atPath: (home as NSString).appendingPathComponent("ocoreai_test_data"))
    }

    @Test("env EMPTY → gate is a no-op (falls through to platform default)")
    func emptyOverrideFallsThrough() {
        let withEmpty = SQLiteStore.resolveDefaultPath(["OCOREAI_DATA_DIR": ""])
        let unset = SQLiteStore.resolveDefaultPath([:])
        #expect(withEmpty == unset)
        // The gate must not corrupt the leaf file name either way.
        #expect(withEmpty.hasSuffix("/ocoreai/data/ocoreai.sqlite"))
    }

    @Test("default (no env) ends with the exact platform leaf")
    func noEnvExactLeaf() {
        let path = SQLiteStore.resolveDefaultPath([:])
        #expect(path.hasSuffix("/ocoreai/data/ocoreai.sqlite"))
    }

    @Test("static defaultPath equals resolveDefaultPath for the live env (consistency)")
    func liveEnvConsistency() {
        // Whatever the CI/test runner env is, the two surfaces must agree —
        // this is the single-source contract: `defaultPath` is defined as
        // `resolveDefaultPath(ProcessInfo.processInfo.environment)`.
        #expect(
            SQLiteStore.defaultPath
                == SQLiteStore.resolveDefaultPath(ProcessInfo.processInfo.environment)
        )
    }
}
