// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SettingsStore — UserDefaults persistence for UI settings.
///
/// Systematic: typed accessor so SettingsState
/// reads/writes are always in sync with disk.

import Observation
import SwiftUI
import Yams

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

    /// Chat per-turn performance telemetry (tok/s, TTFT, reasoning/MTP token
    /// meters). Consumer-facing default is OFF — the answer is the product,
    /// "how many liters of air" is an owner knob, not the default screen.
    /// `Bool` reads default to `false` for an untouched key, which is exactly
    /// the desired consumer default (no IsSet bookkeeping needed).
    var showPerformanceMetrics: Bool {
        get { defaults.bool(forKey: Key.showPerformanceMetrics.rawValue) }
        set { defaults.set(newValue, forKey: Key.showPerformanceMetrics.rawValue) }
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

    /// Hardware routing policy ("balanced" | "performance" | "efficiency").
    /// The setter whitelists against `RoutingPolicy`, so a tampered key can
    /// never inject an invalid policy. `routingPolicyIsSet` distinguishes
    /// "user chose" from "never touched" — the startup bridge keeps the
    /// authored YAML value in the latter case.
    var routingPolicy: String {
        get { defaults.string(forKey: Key.routingPolicy.rawValue) ?? "balanced" }
        set {
            let val = RoutingPolicy(rawValue: newValue) != nil ? newValue : "balanced"
            defaults.set(val, forKey: Key.routingPolicy.rawValue)
        }
    }

    /// True when the user has explicitly set the routing-policy control.
    var routingPolicyIsSet: Bool {
        defaults.object(forKey: Key.routingPolicy.rawValue) != nil
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

    /// Workspace directory for the coding agent (codex `turn_environment.cwd()`
    /// analog): tools default their working directory here, and project
    /// AGENTS.md instructions are discovered from here into the system prompt.
    /// Setter validates (expands `~`, must be an existing directory); empty
    /// string clears the workspace.
    var workspaceDirectory: String {
        get { defaults.string(forKey: Key.workspaceDirectory.rawValue) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.workspaceDirectory.rawValue)
                return
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
                isDir.boolValue
            {
                defaults.set(expanded, forKey: Key.workspaceDirectory.rawValue)
            }
            // Non-directory write is rejected — keeps configuredDirectory() honest.
        }
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
    ///
    /// **Single source of truth across entry points** (GUI app + bare
    /// CLI/headless): the legacy store was `UserDefaults.standard`, which
    /// resolves to a different domain per surface (GUI app bundle
    /// `com.ocoreai.ocoreai` vs. bare executable `ocoreai`) — live-verified
    /// 2026-09-18: GUI said `interactive`, CLI said `auto`. Resolution order
    /// is now: `~/.ocoreai/config.yaml → agent.approvalPolicy` (shared home =
    /// shared file), then the legacy UserDefaults value, then `interactive`.
    var approvalPolicy: String {
        get { Self.approvalPolicyUnified(defaults: defaults) }
        set {
            let val =
                ["interactive", "auto", "never"].contains(newValue) ? newValue : "interactive"
            defaults.set(val, forKey: Key.approvalPolicy.rawValue)
            Self.writeApprovalPolicyToYaml(val)
        }
    }

    // MARK: Unified approval-policy resolution (yaml first, legacy fallback)

    /// Resolve the effective policy, in single-source order:
    ///   1. `~/.ocoreai/config.yaml → agent.approvalPolicy` — the authored
    ///      single source (insurable, headless-editable, 12-factor);
    ///   2. the **GUI bundle domain** legacy value — the owner faces the
    ///      product through the GUI, so its stored choice is the authority
    ///      that a headless/CLI surface must adopt (a bare CLI's own domain
    ///      otherwise wins and the GUI's choice is silently dropped);
    ///   3. this surface's own legacy value (pure headless install with no
    ///      GUI ever run);
    ///   4. `interactive` default (fail-safe: never silently allow).
    /// Precedence is per-value, not per-domain: a valid value found earlier
    /// wins even if a later domain also has one.
    static func approvalPolicyUnified(defaults: UserDefaults) -> String {
        // Env override — top of the chain (env > yaml > GUI domain > own domain),
        // same precedence convention as OCOREAI_PORT / OCOREAI_ENABLE_HTTP.
        // Lets live/CI testing override policy without touching the owner's
        // ~/.ocoreai/config.yaml (previously the only knob forced edit+restore).
        // When unset this returns nil and behavior is byte-identical to before.
        if let env = ProcessInfo.processInfo.environment["OCOREAI_APPROVAL_POLICY"],
            let p = ApprovalPolicy(rawValue: env)
        {
            return p.rawValue
        }
        if let yaml = approvalPolicyFromYaml(),
            let p = ApprovalPolicy(rawValue: yaml)
        {
            return p.rawValue
        }
        if let gui = UserDefaults(suiteName: Self.guiDomainName())?.string(
            forKey: Key.approvalPolicy.rawValue),
            let p = ApprovalPolicy(rawValue: gui)
        {
            return p.rawValue
        }
        if let own = defaults.string(forKey: Key.approvalPolicy.rawValue),
            let p = ApprovalPolicy(rawValue: own)
        {
            return p.rawValue
        }
        return "interactive"
    }

    /// The product GUI app's bundle id — read as the authority legacy domain
    /// for approval policy so a headless/CLI surface adopts the owner's GUI
    /// choice rather than its own (previously the two diverged, live-verified
    /// 2026-09-18: GUI domain `interactive`, CLI domain `auto`).
    static let guiBundleID = "com.ocoreai.ocoreai"
    private static var testsGuiDomainOverride: String?
    static func guiDomainName() -> String { testsGuiDomainOverride ?? guiBundleID }

    /// Read `agent.approvalPolicy` from `~/.ocoreai/config.yaml`. Returns nil
    /// when the file or key is absent. Never throws — a settings read must
    /// not cascade into a parse failure.
    ///
    /// Lenient single-key decode: this tier is the **authored single source**
    /// for one scalar (`agent.approvalPolicy`), 12-factor style — the owner
    /// may author a minimal config.yaml containing only that block. Decoding
    /// the whole `AppConfig` here would be wrong: its sibling sub-structs
    /// (`server`/`backend`/`memory`/…) use strict synthesized `Codable`, so a
    /// minimal hand-authored document fails `DecodingError` and this tier
    /// would silently nil — silently dropping the owner's explicit choice
    /// (live-verified 2026-09-18: minimal `agent:`-only yaml resolved to the
    /// GUI-domain `interactive` instead of the authored `auto`). The whole
    /// config is strictly validated exactly where the whole config matters:
    /// `ConfigSystem.load` (parse + `validate()` + last-known-good snapshot).
    private static func approvalPolicyFromYaml() -> String? {
        let path = resolvedConfigYamlPath()
        guard FileManager.default.fileExists(atPath: path),
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else {
            return nil
        }
        struct AgentPolicyKey: Decodable {
            let approvalPolicy: String
        }
        struct AgentBlock: Decodable {
            let agent: AgentPolicyKey
        }
        guard
            let block = try? YAMLDecoder().decode(AgentBlock.self, from: data)
        else {
            return nil
        }
        return block.agent.approvalPolicy
    }

    /// Persist the uniform policy into `~/.ocoreai/config.yaml` (`agent:`
    /// block, append-only, idempotent). If the `agent:` key already exists on
    /// disk the file is left untouched: the runtime broker is hot-switched by
    /// `SettingsViewModel.approvalPolicy.didSet`, so the in-memory policy is
    /// what matters for the active session; disk convergence happens on the
    /// first write where yaml lacks the key (e.g. legacy CLI install whose GUI
    /// policy should now be honored headlessly).
    private static func writeApprovalPolicyToYaml(_ value: String) {
        let path = resolvedConfigYamlPath()
        guard FileManager.default.fileExists(atPath: path),
            let content = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return  // fresh install: App will save the full config on startup
        }
        if content.contains("agent:") || content.contains("agent\n") {
            return  // already present — do not clobber user's authored block
        }
        let block = "\nagent:\n  approvalPolicy: \(value)\n"
        let out = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (content + block).write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Test injection

    /// Override the home-directory root used for `~/.ocoreai/config.yaml`
    /// access. Set by tests to a per-test `TemporaryDirectory`; nil = real
    /// `NSHomeDirectory()`. Production code never sets this.
    static var testsHomeOverride: String?
    static func resolvedConfigYamlPath() -> String {
        let root = testsHomeOverride ?? NSHomeDirectory()
        return "\(root)/.ocoreai/config.yaml"
    }

    /// Clear test injection state (called by tests at setup/teardown).
    static func resetTestState() {
        testsHomeOverride = nil
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
    ///
    /// **Legacy-key fallback**: GUI 早期版本按带来源前缀的 id
    /// (``mscope:org/name`` / ``hf:org/name``)存 key,canonical 去重后
    /// 统一读 bare key —— 老用户的自定义参数必须仍可读。
    /// 命中 legacy key 时**自动重写回 bare key** 并清除旧 key,一次性迁移。
    func loadSamplingConfig(for modelId: String) -> ModelSamplingConfig {
        let decoded: (Data) -> ModelSamplingConfig = {
            (try? JSONDecoder().decode(ModelSamplingConfig.self, from: $0)) ?? .default
        }
        let bareKey = modelParamKey(modelId)
        if let data = defaults.object(forKey: bareKey) as? Data {
            return decoded(data)
        }
        // 旧版 GUI 写的带前缀 key: 逐个前缀回退
        let prefixes = ["mscope:", "huggingface:", "hf:"]
        for p in prefixes {
            let legacy = modelParamKey(p + modelId)
            if let data = defaults.object(forKey: legacy) as? Data {
                let config = decoded(data)
                defaults.set(data, forKey: bareKey)  // one-shot re-key
                defaults.removeObject(forKey: legacy)
                return config
            }
        }
        return .default
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

        // Chat experience
        case showPerformanceMetrics = "settings.chat.showPerformanceMetrics"

        // Logs
        case logLevel = "settings.logs.level"
        case profileEnabled = "settings.logs.profile"

        // Speculative Decoding
        case specDecodingEnabled = "settings.specDecoding.enabled"
        case specDecodingMode = "settings.specDecoding.mode"

        // Hardware routing policy (balanced | performance | efficiency)
        case routingPolicy = "settings.backend.routingPolicy"

        // Plan（update_plan opt-in，对齐 codex `#41744`）
        case updatePlanEnabled = "settings.updatePlan.enabled"

        // App
        case appLocale = "settings.app.locale"
        case appThemeMode = "settings.app.themeMode"

        // Custom System Prompt
        case customSystemPrompt = "settings.app.customSystemPrompt"
        case workspaceDirectory = "settings.agent.workspaceDirectory"

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
