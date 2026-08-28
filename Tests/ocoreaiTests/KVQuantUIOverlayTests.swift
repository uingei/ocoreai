// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// KVQuantUIOverlayTests — exact-value verification of the UI→engine
/// KV-cache quantization overlay (the fix for the dead `kvQuantization.*`
/// panel controls found in the 2026-08-28 evidence-first audit).
///
/// The engine already consumes `backend.kvCacheQuantization` through
/// `EngineInference.makeGenerateParameters` →
/// `makeKVCacheConfiguration` → `GenerateParameters.kvCache` (typed upstream
/// `KVCacheConfiguration`), so this is the same wiring class as the
/// specDecoding fix — not a new mechanism.
///
/// Merge rule under test (`pureKVQuantUIOverlay` in Config/ConfigStruct.swift):
///   - a dimension the user never touched (nil) keeps the AUTHORED value,
///   - a dimension the user DID touch takes PRECEDENCE in that dimension only,
///   - when `uiBits` is present it ALSO pins `kvScheme` to `affine<bits>`:
///     the engine's scheme-first resolver takes an authored `"turbo*"` scheme
///     OVER `bits`, so without the scheme pin an explicit UI bit selection
///     would be silently ignored (UI shows 8, engine runs 4-bit turbo).
///
/// The final group of tests calls the real engine bridge
/// (`makeKVCacheConfiguration`) to prove the 8-bit path reaches the affine
/// branch (8-bit honored) rather than the turbo branch (4-bit forced).

import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

// MARK: - Overlay semantics

@Suite("pureKVQuantUIOverlay — merge semantics")
struct KVQuantOverlayTests {
    /// Authored config mirroring `KVCacheQuantizationConfig.default`
    /// (what a typical config-system file yields): turbo4 scheme, 4-bit, enabled.
    static let authored = KVCacheQuantizationConfig.default

    @Test("untouched: overlay keeps every authored value")
    func untouchedKeepsAuthored() {
        var cfg = KVQuantOverlayTests.authored
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: nil, uiBits: nil)
        #expect(cfg.enabled == true)
        #expect(cfg.bits == 4)
        #expect(cfg.kvScheme == "turbo4")
        #expect(cfg.groupSize == 64)
        #expect(cfg.quantizedKVStart == 256)
    }

    @Test("uiBits=4: bits and scheme both pinned to affine4")
    func uiBits4PinsAffine4() {
        var cfg = KVQuantOverlayTests.authored
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: nil, uiBits: 4)
        #expect(cfg.bits == 4)
        #expect(
            cfg.kvScheme == "affine4",
            "scheme pinned so the engine's affine branch sees 4-bit, not turbo4")
        #expect(cfg.enabled == true, "enabled untouched → authored kept")
        #expect(cfg.groupSize == 64)
    }

    @Test("uiBits=8: bits and scheme both pinned to affine8 — the key regression")
    func uiBits8PinsAffine8() {
        var cfg = KVQuantOverlayTests.authored
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: nil, uiBits: 8)
        #expect(cfg.bits == 8)
        #expect(
            cfg.kvScheme == "affine8",
            "without this the engine would run 4-bit turbo and the UI '8' would lie")
    }

    @Test("uiEnabled=false override: authored enabled stays on unless user chose otherwise")
    func untouchEnabledStaysOn() {
        var cfg = KVQuantOverlayTests.authored
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: nil, uiBits: 8)
        #expect(
            cfg.enabled == true,
            "uiEnabled nil → authored `enabled: true` preserved (no silent off)")
    }

    @Test("uiEnabled=false: explicit off wins")
    func explicitOffWins() {
        var cfg = KVQuantOverlayTests.authored
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: false, uiBits: nil)
        #expect(cfg.enabled == false)
    }

    @Test("dimensions apply independently")
    func independentDimensions() {
        var cfg = KVQuantOverlayTests.authored
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: true, uiBits: 8)
        #expect(cfg.enabled == true)
        #expect(cfg.bits == 8)
        #expect(cfg.kvScheme == "affine8")
    }
}

// MARK: - IsSet semantics (boot-time nil-or-not guard)

@Suite("SettingsStore KV IsSet distinguishes touched from untouched controls")
struct KVIsSetTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ocoreai.kvisset.\(UUID().uuidString)")!
    }

    @Test("fresh store: both KV controls report unset")
    @MainActor
    func freshStoreUnset() {
        let s = SettingsStore(defaults: freshDefaults())
        #expect(s.kvQuantizationEnabledIsSet == false)
        #expect(s.kvQuantizationBitsIsSet == false)
    }

    @Test("setting enabled flips its IsSet; bits IsSet stays false")
    @MainActor
    func enabledWriteFlipsOnlyItsFlag() {
        let s = SettingsStore(defaults: freshDefaults())
        s.kvQuantizationEnabled = false
        #expect(s.kvQuantizationEnabledIsSet == true)
        #expect(s.kvQuantizationEnabled == false)
        #expect(s.kvQuantizationBitsIsSet == false, "bits untouched → still unset")
    }

    @Test("setting bits flips its IsSet; enabled IsSet stays false")
    @MainActor
    func bitsWriteFlipsOnlyItsFlag() {
        let s = SettingsStore(defaults: freshDefaults())
        s.kvQuantizationBits = 8
        #expect(s.kvQuantizationBitsIsSet == true)
        #expect(s.kvQuantizationBits == 8)
        #expect(s.kvQuantizationEnabledIsSet == false, "enabled untouched → still unset")
    }

    @Test("removing the key restores unset semantics")
    @MainActor
    func removeRestoresUnset() {
        let ud = freshDefaults()
        let s = SettingsStore(defaults: ud)
        s.kvQuantizationBits = 8
        ud.removeObject(forKey: "settings.kvCache.quantBits")
        #expect(s.kvQuantizationBitsIsSet == false, "key removed → control reports untouched")
    }
}

// MARK: - Engine bridge: proof the 8-bit path reaches the affine branch

@Suite("Engine bridge honors the UI bit selection (not the authored turbo scheme)")
struct KVQuantEngineBridgeTests {

    /// The authored engine config — the `KVCacheQuantizationConfig.default`
    /// value that `EngineConfig` ships when the config file has no override
    /// (the exact case that made the UI '8' knob a lie).
    private static let authored = KVCacheQuantizationConfig.default

    /// Apply the UI overlay (as `OcoreaiEngine.start()` does) then call the
    /// real engine bridge and assert the resulting strategy routes to the
    /// affine branch (not turbo).
    private static func runBridge(
        uiEnabled: Bool?,
        uiBits: Int?,
        authoredScheme: String?
    ) -> (result: MLXLMCommon.KVCacheConfiguration?, strategyID: String) {
        var cfg = KVQuantEngineBridgeTests.authored
        cfg.kvScheme = authoredScheme
        pureKVQuantUIOverlay(config: &cfg, uiEnabled: uiEnabled, uiBits: uiBits)
        let result = makeKVCacheConfiguration(
            kvCacheQuant: cfg,
            fallbackBits: nil,
            fallbackGroupSize: 64,
            fallbackQuantizedKVStart: 0,
            fallbackScheme: nil
        )
        return (result, result?.strategy.identifier.rawValue ?? "nil")
    }

    @Test("UI 8-bit → engine affine (not turbo) — the scheme-pinning regression")
    func ui8BitReachesAffine() {
        let (result, strategyID) = KVQuantEngineBridgeTests.runBridge(
            uiEnabled: nil, uiBits: 8, authoredScheme: "turbo4")
        #expect(result != nil, "bridge produced a cache configuration")
        #expect(strategyID == "affine", "8-bit must route to the affine branch, not turbo4")
    }

    @Test("UI 4-bit → engine affine")
    func ui4BitReachesAffine() {
        let (result, strategyID) = KVQuantEngineBridgeTests.runBridge(
            uiEnabled: nil, uiBits: 4, authoredScheme: "turbo4")
        #expect(result != nil)
        #expect(strategyID == "affine")
    }

    @Test("UI untouched → authored turbo4 still wins (no silent off)")
    func untouchedPreservesAuthoredTurbo() {
        let (result, strategyID) = KVQuantEngineBridgeTests.runBridge(
            uiEnabled: nil, uiBits: nil, authoredScheme: "turbo4")
        #expect(result != nil)
        #expect(strategyID == "turbo-quant")
    }

    @Test("UI enable=false → bridge returns nil (no quantization)")
    func explicitOffDisables() {
        let (result, _) = KVQuantEngineBridgeTests.runBridge(
            uiEnabled: false, uiBits: nil, authoredScheme: "turbo4")
        #expect(result == nil, "enabled=false must disable the cache strategy")
    }
}
