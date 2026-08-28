// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SpecDecodingConfigTests — exact-value verification of the UI→engine
/// specDecoding overlay (the fix for the dead specDecoding toggles found in the
/// 2026-08-28 evidence-first audit: 5 UI knobs wrote UserDefaults with 0 engine
/// consumers; `backend.specDecoding` is the engine's sole read point).
///
/// The merge rule under test (`pureSpecDecodingUIOverlay` in Config/ConfigStruct.swift):
///   - a UI dimension the user never touched (nil) keeps the AUTHORED value,
///   - a UI dimension the user DID touch takes PRECEDENCE in that dimension only,
///   - the untouched draft model / token / memoryPolicy fields are never modified
///     (they have no UI surface — authored-in-config file only).
///
/// This is the single source of merge semantics between `SettingsStore` (UI)
/// and `EngineConfig.specDecoding` → `EnginePool.loadMTPDrafter`, so a
/// regression (e.g. UI "off" clobbering an authored "off", or a nil dimension
/// resetting the authored value) is caught here, not only by the E2E MTP path.

import Foundation
import Testing

@testable import ocoreai

@Suite("pureSpecDecodingUIOverlay — merge semantics")
struct SpecDecodingOverlayTests {

    // MARK: - Helpers

    /// Authored config mirroring a typical config-system file: MTP on, 5 draft tokens,
    /// qwen3.8 self-spec via nil draftModelId.
    private func authored() -> SpecDecodingConfig {
        SpecDecodingConfig(
            enabled: true,
            mode: "mtp",
            draftModelId: nil,
            numDraftTokens: 5,
            memoryPolicy: "recommendedWorkingSet"
        )
    }

    // MARK: - Both UI dimensions absent (nil) → authored wins, nothing moves

    @Test("nil,nil leaves the authored specDecoding untouched")
    func nilNilKeepsAuthored() {
        var cfg = authored()
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: nil, uiMode: nil)
        #expect(cfg.enabled == true)
        #expect(cfg.mode == "mtp")
        // Invariant: fields with no UI surface are never touched.
        #expect(cfg.draftModelId == nil)
        #expect(cfg.numDraftTokens == 5)
        #expect(cfg.memoryPolicy == "recommendedWorkingSet")
    }

    @Test("nil,nil is a no-op for an authored-OFF config too")
    func nilNilKeepsAuthoredOff() {
        var cfg = SpecDecodingConfig(enabled: false, mode: "traditional")
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: nil, uiMode: nil)
        #expect(cfg.enabled == false)
        #expect(cfg.mode == "traditional")
    }

    // MARK: - uiEnabled present → enables in that dimension, mode untouched

    @Test("UI enabled=true overrides authored enabled=false; mode stays authored")
    func uiEnableOnOverrides() {
        var cfg = SpecDecodingConfig(enabled: false, mode: "traditional")
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: true, uiMode: nil)
        #expect(cfg.enabled == true)
        #expect(cfg.mode == "traditional", "mode must keep the authored value when UI mode absent")
    }

    @Test("UI enabled=false overrides authored enabled=true; mode stays authored")
    func uiEnableOffOverrides() {
        var cfg = authored()
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: false, uiMode: nil)
        #expect(cfg.enabled == false)
        #expect(cfg.mode == "mtp", "mode must keep the authored value when UI mode absent")
    }

    @Test("UI enabled matching authored is a value no-op")
    func uiEnableMatchesAuthored() {
        var cfg = authored()
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: true, uiMode: nil)
        #expect(cfg.enabled == true)
        #expect(cfg.mode == "mtp")
    }

    // MARK: - uiMode present → mode in that dimension, enabled untouched

    @Test("UI mode=traditional overrides authored mtp; enabled stays authored")
    func uiModeTraditionalOverrides() {
        var cfg = authored()
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: nil, uiMode: "traditional")
        #expect(cfg.enabled == true, "enabled must keep the authored value when UI enabled absent")
        #expect(cfg.mode == "traditional")
    }

    @Test("UI mode=mtp overrides authored traditional; enabled stays authored")
    func uiModeMTPOverrides() {
        var cfg = SpecDecodingConfig(enabled: false, mode: "traditional")
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: nil, uiMode: "mtp")
        #expect(cfg.enabled == false)
        #expect(cfg.mode == "mtp")
    }

    @Test("UI mode matching authored is a value no-op")
    func uiModeMatchesAuthored() {
        var cfg = authored()
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: nil, uiMode: "mtp")
        #expect(cfg.mode == "mtp")
        #expect(cfg.enabled == true)
    }

    // MARK: - Both UI dimensions present (the real-world toggle flip)

    @Test("UI enabled+mode both present set both; draft fields untouched")
    func bothDimensionsSet() {
        var cfg = authored()
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: false, uiMode: "traditional")
        #expect(cfg.enabled == false)
        #expect(cfg.mode == "traditional")
        #expect(cfg.draftModelId == nil)
        #expect(cfg.numDraftTokens == 5)
        #expect(cfg.memoryPolicy == "recommendedWorkingSet")
    }

    @Test("UI enabled=true + mode=traditional is a legal combination (mixed)")
    func mixedDimensionsSet() {
        var cfg = SpecDecodingConfig(enabled: false, mode: "mtp")
        pureSpecDecodingUIOverlay(config: &cfg, uiEnabled: true, uiMode: "traditional")
        #expect(cfg.enabled == true)
        #expect(cfg.mode == "traditional")
    }

    // MARK: - SettingsStore IsSet semantics (the boot-time nil-or-not guard)

    @Suite("IsSet distinguishes touched from untouched controls")
    struct IsSetTests {
        private func freshDefaults() -> UserDefaults {
            UserDefaults(suiteName: "test.ocoreai.isset.\(UUID().uuidString)")!
        }

        @Test("fresh store: both controls report unset")
        @MainActor
        func freshStoreUnset() {
            let s = SettingsStore(defaults: freshDefaults())
            #expect(s.specDecodingEnabledIsSet == false)
            #expect(s.specDecodingModeIsSet == false)
        }

        @Test("setting enabled flips its IsSet; mode IsSet stays false")
        @MainActor
        func enabledWriteFlipsOnlyItsFlag() {
            let s = SettingsStore(defaults: freshDefaults())
            s.specDecodingEnabled = true
            #expect(s.specDecodingEnabledIsSet == true)
            #expect(s.specDecodingEnabled == true)
            #expect(s.specDecodingModeIsSet == false, "mode untouched → still unset")
        }

        @Test("setting mode flips its IsSet; enabled IsSet stays false")
        @MainActor
        func modeWriteFlipsOnlyItsFlag() {
            let s = SettingsStore(defaults: freshDefaults())
            s.specDecodingMode = "traditional"
            #expect(s.specDecodingModeIsSet == true)
            #expect(s.specDecodingMode == "traditional")
            #expect(s.specDecodingEnabledIsSet == false, "enabled untouched → still unset")
        }

        @Test("removing the key restores unset semantics")
        @MainActor
        func removeRestoresUnset() {
            let ud = freshDefaults()
            let s = SettingsStore(defaults: ud)
            s.specDecodingEnabled = true
            ud.removeObject(forKey: "settings.specDecoding.enabled")
            #expect(s.specDecodingEnabledIsSet == false, "key removed → control reports untouched")
        }
    }
}
