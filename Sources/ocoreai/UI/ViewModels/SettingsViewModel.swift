// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Settings ViewModel — bridges SettingsStore (UserDefaults persistence)
/// with transient UI state (verify status, model list).
///
/// @Observable: property-level change tracking.
///
/// Architecture:
///   SettingsView  ←  SettingsState  ←  SettingsStore  ←  UserDefaults
///   (read-only)    (bridge + state)  (typed accessor)

import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class SettingsState {
    /// Shared singleton — survives view recreation (tab switch, NavigationSplitView).
    static let shared = SettingsState()
    private init() {
        // Properties are initialized below with SettingsStore defaults —
        // @Observable macro requires all stored properties initialized before
        // calling any method on self.
    }

    /// Reload all settings from SettingsStore — safe to call multiple times.
    func reloadFromStore() {
        serverHost = SettingsStore.shared.serverHost
        serverPort = SettingsStore.shared.serverPort
        pollIntervalSec = SettingsStore.shared.pollIntervalSec
        chartWindowSec = SettingsStore.shared.chartWindowSec
        kvQuantizationEnabled = SettingsStore.shared.kvQuantizationEnabled
        kvQuantizationBits = SettingsStore.shared.kvQuantizationBits
        kvCacheBudgetGB = SettingsStore.shared.kvCacheBudgetGB
        logLevel = SettingsStore.shared.logLevel
        profileEnabled = SettingsStore.shared.profileEnabled
        appLocale = SettingsStore.shared.appLocale
        appThemeMode = SettingsStore.shared.appThemeMode
        hfToken = SettingsStore.shared.hfToken
        modelScopeToken = SettingsStore.shared.modelScopeToken
    }

    // MARK: - Server Connection (persisted via SettingsStore)

    var serverHost: String = SettingsStore.shared.serverHost {
        didSet { SettingsStore.shared.serverHost = serverHost }
    }

    var serverPort: Int = SettingsStore.shared.serverPort {
        didSet { SettingsStore.shared.serverPort = serverPort }
    }

    var portField: String {
        get { String(serverPort) }
        set {
            if let p = Int(newValue), p > 0, p < 65536 {
                serverPort = p
            }
        }
    }

    // MARK: - Performance Settings

    var pollIntervalSec: Int = SettingsStore.shared.pollIntervalSec {
        didSet { SettingsStore.shared.pollIntervalSec = pollIntervalSec }
    }

    var chartWindowSec: Int = SettingsStore.shared.chartWindowSec {
        didSet { SettingsStore.shared.chartWindowSec = chartWindowSec }
    }

    // MARK: - KV Cache Settings

    var kvQuantizationEnabled: Bool = SettingsStore.shared.kvQuantizationEnabled {
        didSet { SettingsStore.shared.kvQuantizationEnabled = kvQuantizationEnabled }
    }

    var kvQuantizationBits: Int = SettingsStore.shared.kvQuantizationBits {
        didSet { SettingsStore.shared.kvQuantizationBits = kvQuantizationBits }
    }

    var kvCacheBudgetGB: Double = SettingsStore.shared.kvCacheBudgetGB {
        didSet { SettingsStore.shared.kvCacheBudgetGB = kvCacheBudgetGB }
    }

    // MARK: - Logs & Profiling

    var logLevel: LogLevelRaw = SettingsStore.shared.logLevel {
        didSet { SettingsStore.shared.logLevel = logLevel }
    }

    var profileEnabled: Bool = SettingsStore.shared.profileEnabled {
        didSet { SettingsStore.shared.profileEnabled = profileEnabled }
    }

    // MARK: - App Preferences

    var appLocale: OCALocale = SettingsStore.shared.appLocale {
        didSet { SettingsStore.shared.appLocale = appLocale }
    }

    var appThemeMode: ThemeModeRaw = SettingsStore.shared.appThemeMode {
        didSet { SettingsStore.shared.appThemeMode = appThemeMode }
    }

    // MARK: - Hub Tokens (persisted via SettingsStore)

    var hfToken: String? = SettingsStore.shared.hfToken {
        didSet { SettingsStore.shared.hfToken = hfToken }
    }

    var modelScopeToken: String? = SettingsStore.shared.modelScopeToken {
        didSet { SettingsStore.shared.modelScopeToken = modelScopeToken }
    }

    /// Masked tokens for UI display
    var hfTokenMasked: String {
        guard let token = hfToken, token.count > 4 else { return "" }
        return String(token.prefix(2)) + "••••" + String(token.suffix(2))
    }

    var modelScopeTokenMasked: String {
        guard let token = modelScopeToken, token.count > 4 else { return "" }
        return String(token.prefix(2)) + "••••" + String(token.suffix(2))
    }

    // MARK: - Transient UI State (not persisted)

    var verifying: Bool = false
    var connected: Bool = false
    var verifyMessage: String?
    var errorMessage: String?

    // Model picker options
    var selectedModelID: String = ""
    var modelOptions: [String] = []

    // MARK: - Undo support

    private var undoSettings: SettingsSnapshot?
    var hasUndo: Bool {
        undoSettings != nil
    }

    // MARK: - Lifecycle

    /// Load settings on screen appear
    func load() async {
        await loadModels()
    }

    private func loadModels() async {
        guard let pool = OcoreaiEngine.shared.activeEnginePool else {
            modelOptions = [""]
            return
        }
        let entries = await pool.listModels()
        modelOptions = entries.map { $0["id"] ?? "unknown" }
        if modelOptions.isEmpty { modelOptions = [""] }
        if !modelOptions.contains(selectedModelID) {
            selectedModelID = modelOptions.first ?? ""
        }
    }

    /// Check connection via Fast Path (EnginePool ready)
    func verifyConnection() async {
        verifying = true
        verifyMessage = nil
        errorMessage = nil
        let ready = OcoreaiEngine.shared.activeEnginePool != nil
        connected = ready
        verifyMessage = ready ? nil : "Engine not initialized"
        verifying = false
    }

    /// Snapshot current settings, then reset all to defaults.
    /// NOTE: Hub tokens are NOT snapshotted — they are sensitive credentials
    /// that should never be restored via Cmd+Z after a reset.
    func resetToDefaults() {
        undoSettings = SettingsSnapshot(from: self, includeTokens: false)
        SettingsStore.shared.resetToDefaults()
        // Reload from store
        serverHost = SettingsStore.shared.serverHost
        serverPort = SettingsStore.shared.serverPort
        pollIntervalSec = SettingsStore.shared.pollIntervalSec
        chartWindowSec = SettingsStore.shared.chartWindowSec
        kvQuantizationEnabled = SettingsStore.shared.kvQuantizationEnabled
        kvQuantizationBits = SettingsStore.shared.kvQuantizationBits
        kvCacheBudgetGB = SettingsStore.shared.kvCacheBudgetGB
        logLevel = SettingsStore.shared.logLevel
        profileEnabled = SettingsStore.shared.profileEnabled
        appLocale = SettingsStore.shared.appLocale
        appThemeMode = SettingsStore.shared.appThemeMode
        hfToken = nil
        modelScopeToken = nil
        errorMessage = "Settings reset to defaults"
        // Register undo with AppState for Cmd+Z access
        AppState.shared.undoAction = { [weak self] in self?.undoResetToDefaults() }
    }

    /// Restore from the last snapshot if one exists.
    func undoResetToDefaults() {
        guard let snapshot = undoSettings else { return }
        snapshot.apply(to: self)
        undoSettings = nil
    }
}

// MARK: - Settings Snapshot for undo

extension SettingsState {
    @MainActor
    struct SettingsSnapshot {
        let serverHost: String
        let serverPort: Int
        let pollIntervalSec: Int
        let chartWindowSec: Int
        let kvQuantizationEnabled: Bool
        let kvQuantizationBits: Int
        let kvCacheBudgetGB: Double
        let logLevel: LogLevelRaw
        let profileEnabled: Bool
        let appLocale: OCALocale
        let appThemeMode: ThemeModeRaw

        /// Create snapshot. Tokens are intentionally excluded for security —
        /// they should never be restored via Cmd+Z.
        init(from state: SettingsState, includeTokens: Bool = false) {
            serverHost = state.serverHost
            serverPort = state.serverPort
            pollIntervalSec = state.pollIntervalSec
            chartWindowSec = state.chartWindowSec
            kvQuantizationEnabled = state.kvQuantizationEnabled
            kvQuantizationBits = state.kvQuantizationBits
            kvCacheBudgetGB = state.kvCacheBudgetGB
            logLevel = state.logLevel
            profileEnabled = state.profileEnabled
            appLocale = state.appLocale
            appThemeMode = state.appThemeMode
        }

        func apply(to state: SettingsState) {
            state.serverHost = serverHost
            state.serverPort = serverPort
            state.pollIntervalSec = pollIntervalSec
            state.chartWindowSec = chartWindowSec
            state.kvQuantizationEnabled = kvQuantizationEnabled
            state.kvQuantizationBits = kvQuantizationBits
            state.kvCacheBudgetGB = kvCacheBudgetGB
            state.logLevel = logLevel
            state.profileEnabled = profileEnabled
            state.appLocale = appLocale
            state.appThemeMode = appThemeMode
            // Persist to disk
            SettingsStore.shared.serverHost = serverHost
            SettingsStore.shared.serverPort = serverPort
            SettingsStore.shared.pollIntervalSec = pollIntervalSec
            SettingsStore.shared.chartWindowSec = chartWindowSec
            SettingsStore.shared.kvQuantizationEnabled = kvQuantizationEnabled
            SettingsStore.shared.kvQuantizationBits = kvQuantizationBits
            SettingsStore.shared.kvCacheBudgetGB = kvCacheBudgetGB
            SettingsStore.shared.logLevel = logLevel
            SettingsStore.shared.profileEnabled = profileEnabled
            SettingsStore.shared.appLocale = appLocale
            SettingsStore.shared.appThemeMode = appThemeMode
        }
    }
}
