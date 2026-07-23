// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SettingsStore — UserDefaults persistence for UI settings.
///
/// Systematic: typed accessor so SettingsState
/// reads/writes are always in sync with disk.

import Observation
import SwiftUI

// MARK: - Settings Store

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    // MARK: - Server Connection

    var serverHost: String {
        get { defaults.string(forKey: Key.serverHost.rawValue) ?? "127.0.0.1" }
        set { defaults.set(newValue, forKey: Key.serverHost.rawValue) }
    }

    var serverPort: Int {
        get {
            let val = defaults.integer(forKey: Key.serverPort.rawValue)
            return val > 0 ? val : 8080
        }
        set { defaults.set(newValue, forKey: Key.serverPort.rawValue) }
    }

    // MARK: - Performance

    /// Polling interval in seconds (1-10)
    var pollIntervalSec: Int {
        get {
            let val = defaults.integer(forKey: Key.pollIntervalSec.rawValue)
            // UserDefaults.integer returns 0 when key missing — clamp to default
            return max(1, min(val, 10))
        }
        set { defaults.set(clampedInterval(newValue), forKey: Key.pollIntervalSec.rawValue) }
    }

    /// Chart history window in seconds (30-600)
    var chartWindowSec: Int {
        get {
            let val = defaults.integer(forKey: Key.chartWindowSec.rawValue)
            return max(30, min(val, 600))
        }
        set { defaults.set(max(30, min(newValue, 600)), forKey: Key.chartWindowSec.rawValue) }
    }

    // MARK: - KV Cache

    /// Enable KV cache quantization on dashboard
    var kvQuantizationEnabled: Bool {
        get { defaults.bool(forKey: Key.kvQuantizationEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.kvQuantizationEnabled.rawValue) }
    }

    /// Quantization bits: 4 or 8
    var kvQuantizationBits: Int {
        get { defaults.integer(forKey: Key.kvQuantizationBits.rawValue) }
        set { defaults.set(newValue == 4 || newValue == 8 ? newValue : 4, forKey: Key.kvQuantizationBits.rawValue) }
    }

    /// KV cache memory budget in GB
    var kvCacheBudgetGB: Double {
        get {
            let val = defaults.double(forKey: Key.kvCacheBudgetGB.rawValue)
            return max(0.5, min(val, 128))
        }
        set { defaults.set(max(0.5, min(newValue, 128)), forKey: Key.kvCacheBudgetGB.rawValue) }
    }

    // MARK: - Logs & Profiling

    var logLevel: LogLevelRaw {
        get { LogLevelRaw(rawValue: defaults.string(forKey: Key.logLevel.rawValue) ?? "info") ?? .info }
        set { defaults.set(newValue.rawValue, forKey: Key.logLevel.rawValue) }
    }

    var profileEnabled: Bool {
        get { defaults.bool(forKey: Key.profileEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.profileEnabled.rawValue) }
    }

    // MARK: - App Preferences

    var appLocale: OCALocale {
        get { OCALocale(rawValue: defaults.string(forKey: Key.appLocale.rawValue) ?? "en") ?? .en }
        set { defaults.set(newValue.rawValue, forKey: Key.appLocale.rawValue) }
    }

    var appThemeMode: ThemeModeRaw {
    	get { ThemeModeRaw(rawValue: defaults.string(forKey: Key.appThemeMode.rawValue) ?? "auto") ?? .auto }
    	set { defaults.set(newValue.rawValue, forKey: Key.appThemeMode.rawValue) }
    }

    /// User's custom system prompt — injected into the system prompt chain
    /// with highest priority in MessageBuilderContext.userSystemPrompt.
    var customSystemPrompt: String {
    	get { defaults.string(forKey: Key.customSystemPrompt.rawValue) ?? "" }
    	set { defaults.set(newValue, forKey: Key.customSystemPrompt.rawValue) }
    }

    var lastSessionId: Int64? {
    	get { defaults.object(forKey: Key.lastSessionId.rawValue) as? Int64 }
    	set { if let v = newValue { defaults.set(v, forKey: Key.lastSessionId.rawValue) } else { defaults.removeObject(forKey: Key.lastSessionId.rawValue) } }
    }

    // MARK: - Hub Tokens

    /// HuggingFace token — env var HF_TOKEN takes precedence, then Keychain, then UserDefaults (migration fallback)
    /// Note: Stored in macOS Keychain for security; UserDefaults fallback for migration from v1.
    var hfToken: String? {
        get {
            ProcessInfo.processInfo.environment["HF_TOKEN"]
                ?? KeychainStore.shared.string(forKey: Key.hfToken.rawValue)
                ?? defaults.string(forKey: Key.hfToken.rawValue)  // migration: migrate to Keychain on read
        }
        set { KeychainStore.shared.set(newValue, forKey: Key.hfToken.rawValue) }
    }

    /// ModelScope token — env var MODELSCOPE_TOKEN takes precedence, then Keychain, then UserDefaults (migration fallback)
    /// Note: Stored in macOS Keychain for security; UserDefaults fallback for migration from v1.
    var modelScopeToken: String? {
        get {
            ProcessInfo.processInfo.environment["MODELSCOPE_TOKEN"]
                ?? KeychainStore.shared.string(forKey: Key.modelScopeToken.rawValue)
                ?? defaults.string(forKey: Key.modelScopeToken.rawValue)  // migration: migrate to Keychain on read
        }
        set { KeychainStore.shared.set(newValue, forKey: Key.modelScopeToken.rawValue) }
    }

    /// Masked version for UI display — shows first/last 2 chars if set
    var hfTokenMasked: String {
        guard let token = hfToken, token.count > 4 else { return "" }
        return String(token.prefix(2)) + "••••" + String(token.suffix(2))
    }

    var modelScopeTokenMasked: String {
        guard let token = modelScopeToken, token.count > 4 else { return "" }
        return String(token.prefix(2)) + "••••" + String(token.suffix(2))
    }

    // MARK: - Reset

    /// Wipe all settings to defaults
    @MainActor
    func resetToDefaults() {
        let keys: [String] = Key.allCases.map(\.rawValue)
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.synchronize()
        // Also clear secrets from Keychain
        keys.forEach { KeychainStore.shared.removeObject(forKey: $0) }
    }

    // MARK: - Per-Model Sampling Config

    /// Key prefix for per-model configs in UserDefaults
    private func modelParamKey(_ modelId: String) -> String {
        "settings.model.params.\(modelId)"
    }

    /// Save sampling config for a model.
    /// The config is serialized to JSON in UserDefaults under the model's ID key.
    func saveSamplingConfig(_ config: ModelSamplingConfig, for modelId: String) async {
        let pool = OcoreaiEngine.shared.activeEnginePool
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(config) else { return }
        defaults.set(data, forKey: modelParamKey(modelId))
        if let pool {
            await pool.updateSamplingConfig(modelId: modelId, config: config)
        }
    }

    /// Load persisted sampling config for a model, or default.
    func loadSamplingConfig(for modelId: String) -> ModelSamplingConfig {
        let key = modelParamKey(modelId)
        guard let data = defaults.object(forKey: key) as? Data else {
            return .default
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(ModelSamplingConfig.self, from: data)) ?? .default
    }

    /// Reset a model's sampling config to defaults.
    func resetSamplingConfig(for modelId: String) async {
        defaults.removeObject(forKey: modelParamKey(modelId))
        let pool = OcoreaiEngine.shared.activeEnginePool
        if let pool {
            await pool.resetSamplingConfig(modelId: modelId)
        }
    }

    // MARK: - UserDefaults Keys (type-safe)

    enum Key: String, CaseIterable {
        // Server
        case serverHost = "settings.server.host"
        case serverPort = "settings.server.port"

        // Performance
        case pollIntervalSec = "settings.performance.pollInterval"
        case chartWindowSec = "settings.performance.chartWindow"

        // KV Cache
        case kvQuantizationEnabled = "settings.kvCache.quantEnabled"
        case kvQuantizationBits = "settings.kvCache.quantBits"
        case kvCacheBudgetGB = "settings.kvCache.budgetGB"

        // Logs
        case logLevel = "settings.logs.level"
        case profileEnabled = "settings.logs.profile"

        // App
        case appLocale = "settings.app.locale"
        case appThemeMode = "settings.app.themeMode"

        // Custom System Prompt
        case customSystemPrompt = "settings.app.customSystemPrompt"

        // Last selected session for restore on app launch
        case lastSessionId = "settings.app.lastSessionId"

        // Hub Tokens
        case hfToken = "settings.hub.hfToken"
        case modelScopeToken = "settings.hub.modelScopeToken"
    }

    private let defaults: UserDefaults
    @MainActor init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Private Helpers

    private func clampedInterval(_ val: Int) -> Int {
        max(1, min(val, 10))
    }
}

// MARK: - Typed Wrappers

public enum LogLevelRaw: String, CaseIterable, Sendable {
    case debug, info, warning, error
    public var displayName: String {
        switch self {
        case .debug: StringKey.logLevelDebug.l
        case .info: StringKey.logLevelInfo.l
        case .warning: StringKey.logLevelWarning.l
        case .error: StringKey.logLevelError.l
        }
    }

    public var color: Color {
        switch self {
        case .debug: .blue
        case .info: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

public enum ThemeModeRaw: String, CaseIterable, Sendable {
    case auto, light, dark
    public var displayName: String {
        switch self {
        case .auto: StringKey.themeModeAuto.l
        case .light: StringKey.themeModeLight.l
        case .dark: StringKey.themeModeDark.l
        }
    }

    public var systemName: String {
        switch self {
        case .auto: "circle.dotted"
        case .light: "sun.horizon"
        case .dark: "moon"
        }
    }
}
