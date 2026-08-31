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
        set {
            defaults.set(
                newValue == 4 || newValue == 8 ? newValue : 4,
                forKey: Key.kvQuantizationBits.rawValue)
        }
    }

    /// True when the user has explicitly toggled the KV-quantization enable
    /// control (UserDefaults key present). `Bool` reads default to `false` for
    /// an untouched key, so without this flag the engine's authored default
    /// (`enabled: true`) would silently flip off. When false, that dimension
    /// keeps the authored value.
    var kvQuantizationEnabledIsSet: Bool {
        defaults.object(forKey: Key.kvQuantizationEnabled.rawValue) != nil
    }

    /// True when the user has explicitly chosen the KV-quantization bits.
    /// Untouched (`integer(forKey:)` → 0, which is not a legal width) must not
    /// be read as a selection; that dimension keeps the authored value.
    var kvQuantizationBitsIsSet: Bool {
        defaults.object(forKey: Key.kvQuantizationBits.rawValue) != nil
    }

    /// KV cache memory budget in GB
    var kvCacheBudgetGB: Double {
        get {
            let val = defaults.double(forKey: Key.kvCacheBudgetGB.rawValue)
            return max(0.5, min(val, 128))
        }
        set { defaults.set(max(0.5, min(newValue, 128)), forKey: Key.kvCacheBudgetGB.rawValue) }
    }

    // MARK: - Speculative Decoding

    /// Master toggle for speculative decoding
    var specDecodingEnabled: Bool {
        get { defaults.bool(forKey: Key.specDecodingEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.specDecodingEnabled.rawValue) }
    }

    /// Mode: "mtp" or "traditional"
    var specDecodingMode: String {
        get { defaults.string(forKey: Key.specDecodingMode.rawValue) ?? "mtp" }
        set {
            let val = (newValue == "mtp" || newValue == "traditional") ? newValue : "mtp"
            defaults.set(val, forKey: Key.specDecodingMode.rawValue)
        }
    }

    /// update_plan opt-in（**默认 false**，对齐 codex `#41744`；UserDefaults Bool 未触达 = false）。
    var updatePlanEnabled: Bool {
        get { defaults.bool(forKey: Key.updatePlanEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.updatePlanEnabled.rawValue) }
    }

    /// True when the user has explicitly set the specDecoding enabled control
    /// (UserDefaults key present). When false, the engine must keep whatever the
    /// authored config declares for that dimension rather than defaulting it.
    var specDecodingEnabledIsSet: Bool {
        defaults.object(forKey: Key.specDecodingEnabled.rawValue) != nil
    }

    /// True when the user has explicitly set the specDecoding mode control.
    var specDecodingModeIsSet: Bool {
        defaults.object(forKey: Key.specDecodingMode.rawValue) != nil
    }

    // MARK: - Logs & Profiling

    var logLevel: LogLevelRaw {
        get {
            LogLevelRaw(rawValue: defaults.string(forKey: Key.logLevel.rawValue) ?? "info") ?? .info
        }
        set { defaults.set(newValue.rawValue, forKey: Key.logLevel.rawValue) }
    }

    var profileEnabled: Bool {
        get { defaults.bool(forKey: Key.profileEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.profileEnabled.rawValue) }
    }

    // MARK: - App Preferences

    var appLocale: OCALocale {
        // Default: follow the system locale (HIG: a language picker must
        // default to the user's language, not a hardcoded one).
        get {
            if let raw = defaults.string(forKey: Key.appLocale.rawValue),
                let locale = OCALocale(rawValue: raw),
                OCALocale.availableLocales.contains(locale)
            {
                return locale
            }
            return .systemLocale()
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appLocale.rawValue) }
    }

    var appThemeMode: ThemeModeRaw {
        get {
            ThemeModeRaw(rawValue: defaults.string(forKey: Key.appThemeMode.rawValue) ?? "auto")
                ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appThemeMode.rawValue) }
    }

    /// User's custom system prompt — injected into the system prompt chain
    /// with highest priority in MessageBuilderContext.userSystemPrompt.
    var customSystemPrompt: String {
        get { defaults.string(forKey: Key.customSystemPrompt.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.customSystemPrompt.rawValue) }
    }

    // MARK: - Perception

    /// Master toggle for continuous perception system
    var perceptionEnabled: Bool {
        get { defaults.bool(forKey: Key.perceptionEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.perceptionEnabled.rawValue) }
    }

    /// Filesystem monitoring channel
    var perceptionFilesystemEnabled: Bool {
        get { defaults.bool(forKey: Key.perceptionFilesystemEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.perceptionFilesystemEnabled.rawValue) }
    }

    /// Internet content awareness channel
    var perceptionInternetEnabled: Bool {
        get { defaults.bool(forKey: Key.perceptionInternetEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.perceptionInternetEnabled.rawValue) }
    }

    /// System context awareness channel (thermal, memory, CPU)
    var perceptionSystemEnabled: Bool {
        get { defaults.bool(forKey: Key.perceptionSystemEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.perceptionSystemEnabled.rawValue) }
    }

    /// Speaker feedback channel (TTS output loopback)
    var perceptionSpeakerEnabled: Bool {
        get { defaults.bool(forKey: Key.perceptionSpeakerEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.perceptionSpeakerEnabled.rawValue) }
    }

    /// Audio (ambient speech) channel — continuous STT transcript stream
    var perceptionAudioEnabled: Bool {
        get { defaults.bool(forKey: Key.perceptionAudioEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.perceptionAudioEnabled.rawValue) }
    }

    /// Power profile for perception sampling rate
    var perceptionPowerProfile: String {
        get { defaults.string(forKey: Key.perceptionPowerProfile.rawValue) ?? "normal" }
        set {
            let val = ["normal", "reduced", "minimal"].contains(newValue) ? newValue : "normal"
            defaults.set(val, forKey: Key.perceptionPowerProfile.rawValue)
        }
    }

    // MARK: - Voice Feedback (L1 Personal Voice)

    /// Speak replies with the USER'S OWN VOICE (Personal Voice TTS, L1 of the
    /// audio ladder — floor macOS 14 / iOS 17 = all eight target versions).
    /// Live availability is gated by the System-Settings authorization.
    var enablePersonalVoice: Bool {
        get { defaults.bool(forKey: Key.enablePersonalVoice.rawValue) }
        set { defaults.set(newValue, forKey: Key.enablePersonalVoice.rawValue) }
    }

    /// Preferred press-to-talk STT engine (L3). "auto" follows the adaptive
    /// ladder (local Speech framework on 26+, cloud dictation below); "cloud"
    /// forces SFSpeechRecognizer; "local" forces the Speech framework (on <26
    /// degrades to the live-mic fallback so input never breaks).
    var sttEngine: String {
        get { defaults.string(forKey: Key.sttEngine.rawValue) ?? "auto" }
        set {
            let val = ["auto", "local", "cloud"].contains(newValue) ? newValue : "auto"
            defaults.set(val, forKey: Key.sttEngine.rawValue)
        }
    }

    /// Agent approval policy (codex AskForApproval 形状).
    /// 合法值三档（对齐 codex 三轴：on-request / 沙箱允许面 / Never）；
    /// 非法/缺失 → `.interactive`（默认高危才问，fail-safe 不静默放行）。
    var approvalPolicy: String {
        get { defaults.string(forKey: Key.approvalPolicy.rawValue) ?? "interactive" }
        set {
            let val =
                ["interactive", "auto", "never"].contains(newValue) ? newValue : "interactive"
            defaults.set(val, forKey: Key.approvalPolicy.rawValue)
        }
    }

    var lastSessionId: Int64? {
        get { defaults.object(forKey: Key.lastSessionId.rawValue) as? Int64 }
        set {
            if let v = newValue {
                defaults.set(v, forKey: Key.lastSessionId.rawValue)
            } else {
                defaults.removeObject(forKey: Key.lastSessionId.rawValue)
            }
        }
    }

    // MARK: - Hub Tokens

    /// HuggingFace token — env var HF_TOKEN takes precedence, then UserDefaults (persisted form).
    /// Note: env-first mirrors upstream mlx-swift-lm / coreai-models (no keychain token storage).
    var hfToken: String? {
        get {
            ProcessInfo.processInfo.environment["HF_TOKEN"]
                ?? defaults.string(forKey: Key.hfToken.rawValue)
        }
        set {
            if let v = newValue, !v.isEmpty {
                defaults.set(v, forKey: Key.hfToken.rawValue)
            } else {
                defaults.removeObject(forKey: Key.hfToken.rawValue)
            }
        }
    }

    /// ModelScope token — env var MODELSCOPE_TOKEN takes precedence, then UserDefaults (persisted form).
    /// Note: env-first mirrors upstream mlx-swift-lm / coreai-models (no keychain token storage).
    var modelScopeToken: String? {
        get {
            ProcessInfo.processInfo.environment["MODELSCOPE_TOKEN"]
                ?? defaults.string(forKey: Key.modelScopeToken.rawValue)
        }
        set {
            if let v = newValue, !v.isEmpty {
                defaults.set(v, forKey: Key.modelScopeToken.rawValue)
            } else {
                defaults.removeObject(forKey: Key.modelScopeToken.rawValue)
            }
        }
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

        // Speculative Decoding
        case specDecodingEnabled = "settings.specDecoding.enabled"
        case specDecodingMode = "settings.specDecoding.mode"

        // Plan（update_plan opt-in，对齐 codex `#41744`）
        case updatePlanEnabled = "settings.updatePlan.enabled"

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

        // Perception
        case perceptionEnabled = "settings.perception.enabled"
        case perceptionFilesystemEnabled = "settings.perception.filesystem"
        case perceptionInternetEnabled = "settings.perception.internet"
        case perceptionSystemEnabled = "settings.perception.system"
        case perceptionSpeakerEnabled = "settings.perception.speaker"
        case perceptionAudioEnabled = "settings.perception.audio"
        case perceptionPowerProfile = "settings.perception.powerProfile"

        // Voice Feedback (L1 Personal Voice + L3 STT engine)
        case enablePersonalVoice = "settings.voice.enablePersonalVoice"
        case sttEngine = "settings.voice.sttEngine"

        // Agent approval (codex AskForApproval 两档 + 沙箱允许面 ≈ 第三档)
        case approvalPolicy = "settings.agent.approvalPolicy"
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
