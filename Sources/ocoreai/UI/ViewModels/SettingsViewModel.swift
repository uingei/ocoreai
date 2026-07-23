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
        customSystemPrompt = SettingsStore.shared.customSystemPrompt
        hfToken = SettingsStore.shared.hfToken
        modelScopeToken = SettingsStore.shared.modelScopeToken
    }

    // MARK: - Server Connection (persisted via SettingsStore)

    var serverHost: String = SettingsStore.shared.serverHost {
        didSet { guard oldValue != serverHost else { return }; SettingsStore.shared.serverHost = serverHost }
    }

    var serverPort: Int = SettingsStore.shared.serverPort {
        didSet { guard oldValue != serverPort else { return }; SettingsStore.shared.serverPort = serverPort }
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
        didSet { guard oldValue != pollIntervalSec else { return }; SettingsStore.shared.pollIntervalSec = pollIntervalSec }
    }

    var chartWindowSec: Int = SettingsStore.shared.chartWindowSec {
        didSet { guard oldValue != chartWindowSec else { return }; SettingsStore.shared.chartWindowSec = chartWindowSec }
    }

    // MARK: - KV Cache Settings

    var kvQuantizationEnabled: Bool = SettingsStore.shared.kvQuantizationEnabled {
        didSet { guard oldValue != kvQuantizationEnabled else { return }; SettingsStore.shared.kvQuantizationEnabled = kvQuantizationEnabled }
    }

    var kvQuantizationBits: Int = SettingsStore.shared.kvQuantizationBits {
        didSet { guard oldValue != kvQuantizationBits else { return }; SettingsStore.shared.kvQuantizationBits = kvQuantizationBits }
    }

    var kvCacheBudgetGB: Double = SettingsStore.shared.kvCacheBudgetGB {
        didSet { guard oldValue != kvCacheBudgetGB else { return }; SettingsStore.shared.kvCacheBudgetGB = kvCacheBudgetGB }
    }

    // MARK: - Logs & Profiling

    var logLevel: LogLevelRaw = SettingsStore.shared.logLevel {
        didSet { guard oldValue != logLevel else { return }; SettingsStore.shared.logLevel = logLevel }
    }

    var profileEnabled: Bool = SettingsStore.shared.profileEnabled {
        didSet { guard oldValue != profileEnabled else { return }; SettingsStore.shared.profileEnabled = profileEnabled }
    }

    // MARK: - App Preferences

    var appLocale: OCALocale = SettingsStore.shared.appLocale {
        didSet { guard oldValue != appLocale else { return }; SettingsStore.shared.appLocale = appLocale }
    }

    var appThemeMode: ThemeModeRaw = SettingsStore.shared.appThemeMode {
    	didSet { guard oldValue != appThemeMode else { return }; SettingsStore.shared.appThemeMode = appThemeMode }
    }

    /// User's custom system prompt — every new inference uses this value.
    var customSystemPrompt: String = SettingsStore.shared.customSystemPrompt {
    	didSet { guard oldValue != customSystemPrompt else { return }; SettingsStore.shared.customSystemPrompt = customSystemPrompt }
    }

    // MARK: - Hub Tokens (persisted via SettingsStore)

    var hfToken: String? = SettingsStore.shared.hfToken {
        didSet { guard oldValue != hfToken else { return }; SettingsStore.shared.hfToken = hfToken }
    }

    var modelScopeToken: String? = SettingsStore.shared.modelScopeToken {
        didSet { guard oldValue != modelScopeToken else { return }; SettingsStore.shared.modelScopeToken = modelScopeToken }
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
        customSystemPrompt = SettingsStore.shared.customSystemPrompt
        hfToken = nil
        modelScopeToken = nil
        errorMessage = StringKey.settingsResetToDefaults.l
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
    	let customSystemPrompt: String

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
        	customSystemPrompt = state.customSystemPrompt
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
            state.customSystemPrompt = customSystemPrompt
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
            SettingsStore.shared.customSystemPrompt = customSystemPrompt
            }
    }
}
