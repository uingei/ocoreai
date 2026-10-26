// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! SessionPoolPolicyTests.swift — the pool switch, and the escape hatch that lets a live
//! check reach the lane with no pool.
//!
//! `OCOREAI_SESSION_POOL=0` exists so probe 17 can boot a server on the unpooled lane on
//! demand instead of waiting for the HardwareRouter to degrade a turn under memory
//! pressure. That lane is where the video ledger used to lose its record, so the knob is
//! not a convenience: without it the fix would be a claim with no instrument. These pin
//! every accepted spelling, that a typo cannot disable pooling by accident, and that a
//! missing config never invents a pool.

import Foundation
import Testing

@testable import ocoreai

@Suite("SessionPoolPolicy — config asks, environment may veto")
struct SessionPoolPolicyTests {

    @Test("config decides when the environment says nothing")
    func configDecidesWithoutEnvironment() {
        var on = SessionPoolConfig.default
        on.enabled = true
        #expect(SessionPoolPolicy.enabled(config: on, environment: [:]))
        #expect(SessionPoolPolicy.environmentOverride(environment: [:]) == nil)

        on.enabled = false
        #expect(!SessionPoolPolicy.enabled(config: on, environment: [:]))
    }

    @Test("no config is no pool — the policy never invents one")
    func missingConfigMeansNoPool() {
        #expect(!SessionPoolPolicy.enabled(config: nil, environment: [:]))
    }

    @Test("each off-spelling disables pooling, exact values")
    func offSpellingsDisable() {
        var on = SessionPoolConfig.default
        on.enabled = true
        for raw in ["0", "false", "FALSE", "Off", "no", " 0 "] {
            #expect(
                !SessionPoolPolicy.enabled(
                    config: on, environment: ["OCOREAI_SESSION_POOL": raw]),
                "\(raw)")
            #expect(
                SessionPoolPolicy.environmentOverride(
                    environment: ["OCOREAI_SESSION_POOL": raw])
                    == raw.trimmingCharacters(
                        in: .whitespaces
                    ).lowercased(),
                "\(raw)")
        }
    }

    @Test("a typo leaves pooling alone and is still reported verbatim")
    func unknownValueDoesNotDisable() {
        var on = SessionPoolConfig.default
        on.enabled = true
        for raw in ["1", "true", "yes", "ture", ""] {  // codespell:ignore
            #expect(
                SessionPoolPolicy.enabled(
                    config: on, environment: ["OCOREAI_SESSION_POOL": raw]), "\(raw)")
        }
        // `ture` is a typo for `true`, not a request to disable; the override stays nil so  // codespell:ignore
        // the boot log does not claim the hatch took effect when it did not.
        #expect(
            SessionPoolPolicy.environmentOverride(
                environment: ["OCOREAI_SESSION_POOL": "ture"]) == nil)  // codespell:ignore
    }

    @Test("the environment cannot turn a disabled config back on")
    func environmentCannotOverrideConfigOff() {
        var off = SessionPoolConfig.default
        off.enabled = false
        #expect(!SessionPoolPolicy.enabled(config: off, environment: ["OCOREAI_SESSION_POOL": "1"]))
    }

    @Test("the documented variable name is the one the code reads")
    func variableNameIsPinned() {
        #expect(SessionPoolPolicy.environmentVariable == "OCOREAI_SESSION_POOL")
    }
}
