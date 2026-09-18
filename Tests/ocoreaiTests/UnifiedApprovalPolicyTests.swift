// UnifiedApprovalPolicyTests.swift
//
// Locks the "one owner choice across entry points" invariant for the agent
// tool-approval policy (GUI app + bare CLI/headless were live-verified
// 2026-09-18 to disagree: GUI domain `interactive`, CLI domain `auto`).
//
// The fix gives it a single source of truth:
// `~/.ocoreai/config.yaml → agent.approvalPolicy`, resolved by
// `SettingsStore.approvalPolicyUnified` in the order:
//   1. yaml key (authored single source, 12-factor, headless-editable)
//   2. GUI bundle domain (`com.ocoreai.ocoreai`) — the owner's product-facing
//      choice, which a headless surface must ADOPT, not silently ignore
//   3. the surface's own legacy domain (pure headless install)
//   4. `interactive` (fail-safe default — never silently allow)
//
// Pattern follows SettingsStoreTests: `@testable import ocoreai`,
// `@MainActor @Suite`, fresh suite per test.
//
// ADD a new policy value / domain → update the expectations below.

import Foundation
import Testing
import Yams

@testable import ocoreai

@MainActor
@Suite("Unified approval policy")
struct UnifiedApprovalPolicyTests {

    // MARK: - Helpers

    private func tempHome() -> String {
        let dir = NSTemporaryDirectory() + "ocoreai_approval_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func yamlAt(home: String) -> String { home + "/.ocoreai/config.yaml" }

    // MARK: - 1. yaml wins over legacy domains

    @Test("yaml policy overrides legacy domains")
    func yamlPolicyOverridesLegacyDomains() {
        SettingsStore.resetTestState()
        let home = tempHome()
        defer {
            SettingsStore.resetTestState()
            try? FileManager.default.removeItem(atPath: home)
        }

        let gui = UserDefaults(suiteName: "test_uni_gui")!
        gui.removePersistentDomain(forName: "test_uni_gui")
        let own = UserDefaults(suiteName: "test_uni_own")!
        own.removePersistentDomain(forName: "test_uni_own")
        gui.set("interactive", forKey: SettingsStore.Key.approvalPolicy.rawValue)
        own.set("auto", forKey: SettingsStore.Key.approvalPolicy.rawValue)

        // Author the policy through the app's own config encoder (a real
        // config.yaml round-trips; a hand-written minimal doc would not) —
        // this mirrors how a live config.yaml actually looks on disk.
        SettingsStore.testsHomeOverride = home
        try? FileManager.default.createDirectory(
            atPath: home + "/.ocoreai", withIntermediateDirectories: true)
        var cfg = AppConfig()
        cfg.agent.approvalPolicy = "never"
        let yaml = try? Yams.YAMLEncoder().encode(cfg)
        if let yaml {
            try? yaml.write(
                toFile: home + "/.ocoreai/config.yaml", atomically: true, encoding: .utf8)
        }

        let resolved = SettingsStore.approvalPolicyUnified(defaults: own)
        #expect(
            resolved == "never",
            "yaml `never` must beat GUI `interactive` and own-domain `auto`, got \(resolved)")
    }

    // MARK: - 2. invalid yaml → default

    @Test("invalid yaml value falls back to interactive")
    func invalidYamlValueFallsBackToDefault() {
        SettingsStore.resetTestState()
        let home = tempHome()
        defer {
            SettingsStore.resetTestState()
            try? FileManager.default.removeItem(atPath: home)
        }

        let clean = UserDefaults(suiteName: "test_uni_clean")!
        clean.removePersistentDomain(forName: "test_uni_clean")

        let doc = "agent:\n  approvalPolicy: bogus-value\n"
        writeDoc(doc, to: home)

        let resolved = SettingsStore.approvalPolicyUnified(defaults: clean)
        #expect(resolved == "interactive", "invalid yaml → fail-safe default, got \(resolved)")
    }

    // MARK: - 3. nothing stored → default

    @Test("no yaml, no legacy → interactive default")
    func nothingStoredResolvesToDefault() {
        SettingsStore.resetTestState()
        let home = tempHome()
        defer {
            SettingsStore.resetTestState()
            try? FileManager.default.removeItem(atPath: home)
        }

        let clean = UserDefaults(suiteName: "test_uni_clean2")!
        clean.removePersistentDomain(forName: "test_uni_clean2")

        let resolved = SettingsStore.approvalPolicyUnified(defaults: clean)
        #expect(resolved == "interactive", "nothing stored → `interactive`")
    }

    // MARK: - 4. setter creates the agent block when yaml lacks it

    @Test("setter writes agent block when absent")
    func setterWritesAgentBlockWhenAbsent() {
        SettingsStore.resetTestState()
        let home = tempHome()
        defer {
            SettingsStore.resetTestState()
            try? FileManager.default.removeItem(atPath: home)
        }

        let base = "server:\n  host: 127.0.0.1\n  port: 8080\n"
        writeDoc(base, to: home)

        let clean = UserDefaults(suiteName: "test_uni_write")!
        clean.removePersistentDomain(forName: "test_uni_write")
        let store = SettingsStore(defaults: clean)
        store.approvalPolicy = "never"

        let after = readDoc(home)
        #expect(after.contains("agent:"), "agent block written when yaml had none:\n\(after)")
        #expect(after.contains("approvalPolicy: never"), "value `never` persisted to yaml")
    }

    // MARK: - 5. pre-existing yaml agent block is not clobbered

    @Test("pre-existing yaml agent block is preserved")
    func existingAgentBlockIsPreserved() {
        SettingsStore.resetTestState()
        let home = tempHome()
        defer {
            SettingsStore.resetTestState()
            try? FileManager.default.removeItem(atPath: home)
        }

        let base = "agent:\n  approvalPolicy: auto\n"
        writeDoc(base, to: home)

        let clean = UserDefaults(suiteName: "test_uni_keep")!
        clean.removePersistentDomain(forName: "test_uni_keep")
        let store = SettingsStore(defaults: clean)
        store.approvalPolicy = "never"  // would clobber if the guard is broken

        let after = readDoc(home)
        #expect(after.contains("approvalPolicy: auto"), "pre-authored yaml value kept:\n\(after)")
        #expect(!after.contains("approvalPolicy: never"), "no clobber of user-authored block")
    }

    // MARK: - test file IO helpers (temp-home rooted)

    private func writeDoc(_ content: String, to home: String) {
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".ocoreai").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        SettingsStore.testsHomeOverride = home
        try? content.write(
            toFile: SettingsStore.resolvedConfigYamlPath(), atomically: true, encoding: .utf8)
    }

    private func readDoc(_ home: String) -> String {
        SettingsStore.testsHomeOverride = home
        return
            (try? String(contentsOfFile: SettingsStore.resolvedConfigYamlPath(), encoding: .utf8))
            ?? ""
    }
}
