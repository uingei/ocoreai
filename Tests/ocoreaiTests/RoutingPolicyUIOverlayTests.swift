// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// RoutingPolicyUIOverlayTests — exact-value verification of the UI→config
/// hardware-routing-policy overlay.
///
/// The bridge under test (`pureRoutingPolicyUIOverlay` in
/// Config/ConfigStruct.swift, the store accessor `routingPolicy` /
/// `routingPolicyIsSet`, consumed in App.swift before the `HardwareRouter` is
/// constructed):
///   - a control the user never touched (nil) keeps the AUTHORED YAML value,
///   - a value the user DID touch takes PRECEDENCE,
///   - an unknown rawValue is whitelisted to "balanced" at the store edge,
///   - untouched `BackendConfig` dimensions are never modified.
///
/// The i18n side (5 new `StringKey`s) is locked by
/// `LocaleTableCompletenessTests` — en + zh must cover them exactly. The
/// SwiftUI surface enumerates `RoutingPolicy.allCases`, so the option list
/// cannot drift from the enum.

import Foundation
import Testing

@testable import ocoreai

// MARK: - Overlay semantics

@Suite("pureRoutingPolicyUIOverlay — merge semantics")
struct RoutingPolicyOverlayTests {

    @Test("nil keeps the authored default (balanced) untouched")
    func nilKeepsAuthoredDefault() {
        var cfg = BackendConfig(routingPolicy: .balanced)
        pureRoutingPolicyUIOverlay(config: &cfg, uiPolicy: nil)
        #expect(cfg.routingPolicy == .balanced)
    }

    @Test("nil keeps an authored non-default policy untouched")
    func nilKeepsAuthoredNonDefault() {
        var cfg = BackendConfig(routingPolicy: .efficiency)
        pureRoutingPolicyUIOverlay(config: &cfg, uiPolicy: nil)
        #expect(cfg.routingPolicy == .efficiency)
    }

    @Test("each UI policy overrides any authored value (3×3 sweep)")
    func eachUIPolicyOverridesAuthored() {
        for ui in RoutingPolicy.allCases {
            for authored in RoutingPolicy.allCases {
                var cfg = BackendConfig(routingPolicy: authored)
                pureRoutingPolicyUIOverlay(config: &cfg, uiPolicy: ui)
                #expect(
                    cfg.routingPolicy == ui,
                    "UI \(ui.rawValue) must win over authored \(authored.rawValue)")
            }
        }
    }

    @Test("untouched BackendConfig dimensions are never modified")
    func untouchedDimensionsPreserved() {
        var cfg = BackendConfig(
            preference: ["coreai", "mlx"],
            maxConcurrentSessions: 4,
            kvCacheGB: 8.0,
            routingPolicy: .performance
        )
        pureRoutingPolicyUIOverlay(config: &cfg, uiPolicy: .balanced)
        #expect(cfg.routingPolicy == .balanced)
        #expect(cfg.preference == ["coreai", "mlx"], "preference must stay authored")
        #expect(cfg.maxConcurrentSessions == 4, "maxConcurrentSessions must stay authored")
        #expect(cfg.kvCacheGB == 8.0, "kvCacheGB must stay authored")
    }
}

// MARK: - Store edge (whitelist + IsSet tri-state)

@Suite("SettingsStore.routingPolicy — whitelist + IsSet")
struct RoutingPolicyStoreTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ocoreai.routepolicy.\(UUID().uuidString)")!
    }

    @Test("fresh store: getter defaults to balanced, IsSet is false")
    @MainActor
    func freshStoreUnset() {
        let s = SettingsStore(defaults: freshDefaults())
        #expect(s.routingPolicy == "balanced")
        #expect(
            s.routingPolicyIsSet == false,
            "never touched → authored YAML must win at startup")
    }

    @Test("each valid policy round-trips through the store")
    @MainActor
    func validCasesRoundTrip() {
        let s = SettingsStore(defaults: freshDefaults())
        for raw in ["balanced", "performance", "efficiency"] {
            s.routingPolicy = raw
            #expect(s.routingPolicy == raw, "\(raw) must round-trip")
            #expect(s.routingPolicyIsSet == true)
        }
    }

    @Test("an unknown rawValue is whitelisted to balanced, still marked set")
    @MainActor
    func unknownRawValueFallsBackToBalanced() {
        let s = SettingsStore(defaults: freshDefaults())
        s.routingPolicy = "bogus"
        #expect(s.routingPolicy == "balanced", "unknown raw → default policy")
        #expect(s.routingPolicyIsSet == true, "the control was touched")
    }

    @Test("removing the key restores unset semantics")
    @MainActor
    func removeRestoresUnset() {
        let ud = freshDefaults()
        let s = SettingsStore(defaults: ud)
        s.routingPolicy = "performance"
        ud.removeObject(forKey: "settings.backend.routingPolicy")
        #expect(s.routingPolicyIsSet == false, "key removed → control reports untouched")
    }
}
