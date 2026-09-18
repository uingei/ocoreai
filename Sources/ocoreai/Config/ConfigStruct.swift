// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConfigStruct.swift — Configuration data model with validation
///
/// Declarative config schema backed by `Codable` + `Sendable`.
/// All sensitive fields use `.env(name)` — never plaintext.
///
/// File location: `~/.ocoreai/config.yaml`

import Foundation
import Yams

// MARK: - Top-level Config

/// Single decode funnel for a `config.yaml` document (recovery / load share it).
/// Lenient per-block defaults (12-factor hand-authored files) PLUS a
/// recognized-key probe:
///   * YAML syntax error              → throws (as before),
///   * document with NO recognized top-level key (bare scalar, comment-only,
///     unknown-key garbage like `broken:`, empty mapping) → throws,
///   * document with ≥1 recognized key → decodes leniently to
///     AppConfig + (caller) validate().
///
/// Why the probe matters: a lenient decode of a no-op document trivially
/// succeeds to pure `AppConfig()` defaults; adopting it as the known-good
/// snapshot inverts the recovery guarantee (`restoreLastGood` would hand back
/// values the owner never wrote). A document that wrote at least one
/// recognized key decodes leniently (what the owner wrote wins); a document
/// that wrote none is rejected with a visible error, never silently defaulted.
public func decodeVerifiedConfig(from data: Data) throws -> AppConfig {
    struct TopKeyProbe: Decodable {
        let recognized: Int
        private struct AnyKey: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
            var intValue: Int? { nil }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            recognized =
                c.allKeys.filter {
                    ["server", "backend", "models", "memory", "metrics", "safety", "agent"]
                        .contains($0.stringValue)
                }.count
        }
    }
    let count = try YAMLDecoder().decode(TopKeyProbe.self, from: data).recognized
    guard count >= 1 else {
        throw ConfigValidationError(
            "config.yaml carries no recognized top-level key (server, backend, models, memory, metrics, safety, agent) — refusing to default-adopt this document"
        )
    }
    return try YAMLDecoder().decode(AppConfig.self, from: data)
}

/// Root configuration structure — decoded from YAML, written back on change.
public struct AppConfig: Sendable, Codable, Equatable {
    public var server: ServerConfig
    public var backend: BackendConfig
    public var models: [String: ModelConfigEntry]
    public var memory: MemoryConfig
    public var metrics: MetricsConfig
    public var safety: SafetyConfig
    public var agent: AgentConfig

    public init(
        server: ServerConfig = .default,
        backend: BackendConfig = .default,
        models: [String: ModelConfigEntry] = ModelConfigEntry.defaultModels,
        memory: MemoryConfig = .default,
        metrics: MetricsConfig = .default,
        safety: SafetyConfig = .default,
        agent: AgentConfig = .default,
    ) {
        self.server = server
        self.backend = backend
        self.models = models
        self.memory = memory
        self.metrics = metrics
        self.safety = safety
        self.agent = agent
    }

    // MARK: Codable — lenient (12-factor / hand-authored configs)

    /// A hand-written `config.yaml` routinely carries ONLY the blocks the owner
    /// cares about (commonly `agent:`, sometimes `agent:`+`models:`/`server:`);
    /// the previous synthesized strict decode of a partial file THREW, and
    /// `ConfigSystem.load` cascaded into recovery / defaults-generation / `.good`
    /// adoption and silently DROPPED the user's file (`AgentConfig`'s note names
    /// this exact failure for one key). Decode each block with the block's
    /// documented `.default` so *what the owner wrote wins* and the rest is
    /// defaulted — behavior-superset: a full file still decodes to the identical
    /// values, and `validate()` (a separate step) still rejects bad values, so
    /// the corruption/recovery tests keep their guarantees.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.server = (try? c.decode(ServerConfig.self, forKey: .server)) ?? .default
        self.backend = (try? c.decode(BackendConfig.self, forKey: .backend)) ?? .default
        self.models =
            (try? c.decode([String: ModelConfigEntry].self, forKey: .models))
            ?? ModelConfigEntry.defaultModels
        self.memory = (try? c.decode(MemoryConfig.self, forKey: .memory)) ?? .default
        self.metrics = (try? c.decode(MetricsConfig.self, forKey: .metrics)) ?? .default
        self.safety = (try? c.decode(SafetyConfig.self, forKey: .safety)) ?? .default
        self.agent = (try? c.decode(AgentConfig.self, forKey: .agent)) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(server, forKey: .server)
        try c.encode(backend, forKey: .backend)
        try c.encode(models, forKey: .models)
        try c.encode(memory, forKey: .memory)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(safety, forKey: .safety)
        try c.encode(agent, forKey: .agent)
    }

    private enum CodingKeys: String, CodingKey {
        case server, backend, models, memory, metrics, safety, agent
    }

    /// Run validation — throws on invalid config.
    public func validate() throws {
        try server.validate()
        try backend.validate()
        try memory.validate()
        try safety.validate()
        try agent.validate()
    }
}

// MARK: - Safety Config

/// Content safety configuration — an OPTIONAL owner-facing filter.
///
/// Stored in `~/.ocoreai/config.yaml` under the `safety:` key.
///
/// **Principle (owner directive):** the standing safety principle of ocoreai is
/// 最大求真 + 最大好奇心 + 诚实 (maximum truth-seeking + maximum curiosity +
/// honesty), NOT human-preference alignment. A keyword wall is a human-preference
/// filter, so it is **opt-in and OFF by default**: it must never gate legitimate
/// work (engineering synthesis, security research, etc.). When the owner opts in,
/// they have full authority over every category — **no category is non-negotiable**.
public struct SafetyConfig: Sendable, Codable, Equatable {
    /// Master toggle. Default is **off** — the system defaults to letting requests
    /// through (maximum truth-seeking) and only filters when the owner opts in.
    public var enabled: Bool

    /// Per-category detection mode override (default: auto).
    public var categoryModes: [String: String]

    /// Additional keywords to detect (category → keyword list).
    public var additionalKeywords: [String: [String]]

    /// Minimum number of keyword matches before blocking a category.
    public var minMatchesRequired: Int

    /// Whether to redact offending content in logs.
    public var logRedaction: Bool

    public static let `default` = SafetyConfig()

    public init(
        enabled: Bool = false,
        categoryModes: [String: String] = [:],
        additionalKeywords: [String: [String]] = [:],
        minMatchesRequired: Int = 1,
        logRedaction: Bool = true,
    ) {
        self.enabled = enabled
        self.categoryModes = categoryModes
        self.additionalKeywords = additionalKeywords
        self.minMatchesRequired = max(1, min(minMatchesRequired, 5))
        self.logRedaction = logRedaction
    }

    // MARK: Codable — lenient (a partial hand-authored `safety:` block, e.g.
    // only `safety: {enabled: true}`, keeps what the owner wrote and defaults
    // the rest, instead of failing the whole `safety:` block).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.categoryModes = (try? c.decode([String: String].self, forKey: .categoryModes)) ?? [:]
        self.additionalKeywords =
            (try? c.decode([String: [String]].self, forKey: .additionalKeywords)) ?? [:]
        let mmr = (try? c.decode(Int.self, forKey: .minMatchesRequired)) ?? d.minMatchesRequired
        self.minMatchesRequired = max(1, min(mmr, 5))
        self.logRedaction = (try? c.decode(Bool.self, forKey: .logRedaction)) ?? d.logRedaction
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(categoryModes, forKey: .categoryModes)
        try c.encode(additionalKeywords, forKey: .additionalKeywords)
        try c.encode(minMatchesRequired, forKey: .minMatchesRequired)
        try c.encode(logRedaction, forKey: .logRedaction)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, categoryModes, additionalKeywords, minMatchesRequired, logRedaction
    }

    func validate() throws {
        // No category is non-negotiable. When the (opt-in) filter is enabled the
        // owner has full authority over which categories are active — disabling any
        // is allowed. This encodes the standing principle: default is maximum
        // truth-seeking/curiosity, not a hardcoded human-preference wall.
    }
}

// MARK: - Agent Config

/// Agent tool-approval configuration (codex `AskForApproval` shape, two
/// surfaces: GUI app + bare CLI/headless).
///
/// Stored in `~/.ocoreai/config.yaml` under the `agent:` key so the policy is
/// a **single source of truth** across entry points — previously it lived in
/// `UserDefaults.standard`, which resolves to a DIFFERENT domain per surface
/// (GUI app bundle vs. bare executable), so a GUI choice silently did not
/// apply to the CLI/headless path and vice versa (live-verified 2026-09-18:
/// GUI domain said `interactive` while the CLI domain said `auto`).
///
/// `approvalPolicy` values: `interactive` (ask, fail-closed when no UI is
/// present to answer), `auto` (no ask, proceed), `never` (no ask, deny).
/// The runtime `ApprovalPolicy` enum is the canonical domain type; the string
/// here is its YAML-friendly spelling.
public struct AgentConfig: Sendable, Codable, Equatable {
    public var approvalPolicy: String

    public static let `default` = AgentConfig()

    public init(
        approvalPolicy: String = "interactive",
    ) {
        self.approvalPolicy = approvalPolicy
    }

    // MARK: Codable — backward compatible: old config.yaml files lack the
    // `agent:` key entirely; decode must default, not fail the whole config
    // (a decode failure in `ConfigSystem.load` falls back to recovery /
    // defaults generation and silently drops the user's file — the last-known
    // good copy is the only survivor, so decode robustness matters).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.approvalPolicy = (try? c.decode(String.self, forKey: .approvalPolicy)) ?? "interactive"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(approvalPolicy, forKey: .approvalPolicy)
    }

    private enum CodingKeys: CodingKey { case approvalPolicy }

    /// The enum value, or nil if the string is not a known policy.
    public var approvalPolicyParsed: ApprovalPolicy? {
        ApprovalPolicy(rawValue: approvalPolicy)
    }

    func validate() throws {
        guard ApprovalPolicy(rawValue: approvalPolicy) != nil else {
            throw ConfigValidationError(
                "agent.approvalPolicy must be one of \(ApprovalPolicy.allCases.map(\.rawValue).sorted()), got \(approvalPolicy)"
            )
        }
    }
}

// MARK: - Server Config

public struct ServerConfig: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var workers: Int
    public var corsOrigin: String?
    public var bindInterface: String

    public static let `default` = ServerConfig()

    public init(
        host: String? = nil,
        port: Int = 8080,
        workers: Int? = nil,
        corsOrigin: String? = nil,
        bindInterface: String? = nil,
    ) {
        self.host = host ?? "127.0.0.1"
        self.port = port
        self.workers = workers ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        self.corsOrigin = corsOrigin
        self.bindInterface = bindInterface ?? "localhost"
    }

    // MARK: Codable — lenient (a partial hand-authored `server:` block must keep
    // the keys the owner wrote and default the rest — e.g. `server: {port: 9100}`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.host = (try? c.decode(String.self, forKey: .host)) ?? d.host
        self.port = (try? c.decode(Int.self, forKey: .port)) ?? d.port
        self.workers = (try? c.decode(Int.self, forKey: .workers)) ?? d.workers
        self.corsOrigin = try? c.decode(String.self, forKey: .corsOrigin)
        self.bindInterface = (try? c.decode(String.self, forKey: .bindInterface)) ?? d.bindInterface
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(workers, forKey: .workers)
        try c.encodeIfPresent(corsOrigin, forKey: .corsOrigin)
        try c.encode(bindInterface, forKey: .bindInterface)
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, workers, corsOrigin, bindInterface
    }

    func validate() throws {
        guard (1 ... 65535).contains(port) else {
            throw ConfigValidationError("server.port must be 1-65535, got \(port)")
        }
    }
}

// MARK: - Backend Config

/// Wired memory policy configuration for GPU hard-isolation.
///
/// On Apple Silicon UMA, wired memory prevents the GPU from paging out
/// model weights and activations when the system is under memory pressure.
/// This is Layer 0 — the hardware-level protection below OOMGuard.
///
/// See upstream: references/mlx-swift-lm/Libraries/MLXLMCommon/WiredMemoryPolicies.swift
/// and references/mlx-swift-lm/Libraries/MLXLMCommon/WiredMemoryUtils.swift
public struct WiredMemoryConfig: Sendable, Codable, Equatable {
    /// Master toggle — disabled means wired memory is not applied per-request.
    public var enabled: Bool
    /// Policy type — "max" (peak ticket), "sum" (aggregate tickets),
    /// "budget" (baseline + base + sum), or "fixed" (constant cap).
    /// Aligns with upstream WiredMemoryPolicies.swift (4 policies).
    public var policy: String
    /// Override the per-request budget in bytes. Auto-detected when 0.
    public var bytesOverride: Int
    /// Base budget for WiredBudgetPolicy (weights + workspace bytes).
    /// Only used when policy == "budget". Ignored otherwise.
    public var budgetBaseBytes: Int
    /// Hard cap for WiredBudgetPolicy. nil = auto from recommendedWorkingSetBytes().
    public var budgetCap: Int?
    /// Fixed limit for WiredFixedPolicy. Ignored when policy != "fixed".
    public var fixedLimit: Int

    public static let `default` = WiredMemoryConfig()

    public init(
        enabled: Bool = true,
        policy: String = "max",
        bytesOverride: Int = 0,
        budgetBaseBytes: Int = 0,
        budgetCap: Int? = nil,
        fixedLimit: Int = 0,
    ) {
        self.enabled = enabled
        self.policy = policy
        self.bytesOverride = bytesOverride
        self.budgetBaseBytes = budgetBaseBytes
        self.budgetCap = budgetCap
        self.fixedLimit = fixedLimit
    }

    // MARK: Codable — lenient (partial hand-authored `wiredMemory:` keeps the
    // keys the owner wrote, defaults the rest).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.policy = (try? c.decode(String.self, forKey: .policy)) ?? d.policy
        self.bytesOverride = (try? c.decode(Int.self, forKey: .bytesOverride)) ?? d.bytesOverride
        self.budgetBaseBytes =
            (try? c.decode(Int.self, forKey: .budgetBaseBytes)) ?? d.budgetBaseBytes
        self.budgetCap = try? c.decode(Int.self, forKey: .budgetCap)
        self.fixedLimit = (try? c.decode(Int.self, forKey: .fixedLimit)) ?? d.fixedLimit
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(policy, forKey: .policy)
        try c.encode(bytesOverride, forKey: .bytesOverride)
        try c.encode(budgetBaseBytes, forKey: .budgetBaseBytes)
        try c.encodeIfPresent(budgetCap, forKey: .budgetCap)
        try c.encode(fixedLimit, forKey: .fixedLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, policy, bytesOverride, budgetBaseBytes, budgetCap, fixedLimit
    }
}

/// Speculative decoding configuration.
///
/// When enabled, a smaller draft model proposes candidate tokens that the
/// main model verifies in a single forward pass — significant TTFT and
/// throughput speedup with zero quality degradation.
///
/// For MTP models (Qwen3.5, Gemma4), use `mode: "mtp"` — the main model's
/// built-in MTP layers act as the drafter, no separate draft model needed.
/// For non-MTP models, use `mode: "traditional"` with a smaller `draftModelId`.
public struct SpecDecodingConfig: Sendable, Codable, Equatable {
    /// Master toggle — disabled means speculative decoding is off.
    public var enabled: Bool
    /// Mode: "mtp" (main model's MTP layers as drafter) or "traditional"
    /// (separate draft model).
    public var mode: String
    /// Draft model repository ID for traditional mode (ignored for "mtp").
    public var draftModelId: String?
    /// Number of tokens proposed per speculation cycle (1-16, default 5).
    public var numDraftTokens: Int
    /// Memory policy for traditional mode: "recommendedWorkingSet" to
    /// auto-fallback when main+draft exceed available memory.
    public var memoryPolicy: String?

    public static let `default` = SpecDecodingConfig()

    public init(
        enabled: Bool = false,
        mode: String = "traditional",
        draftModelId: String? = nil,
        numDraftTokens: Int = 5,
        memoryPolicy: String? = "recommendedWorkingSet"
    ) {
        self.enabled = enabled
        self.mode = mode
        self.draftModelId = draftModelId
        self.numDraftTokens = max(1, min(numDraftTokens, 16))
        self.memoryPolicy = memoryPolicy
    }

    // MARK: Codable — lenient (partial hand-authored `specDecoding:` block).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.mode = (try? c.decode(String.self, forKey: .mode)) ?? d.mode
        self.draftModelId = try? c.decode(String.self, forKey: .draftModelId)
        self.numDraftTokens = (try? c.decode(Int.self, forKey: .numDraftTokens)) ?? d.numDraftTokens
        self.memoryPolicy = try? c.decode(String.self, forKey: .memoryPolicy)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(draftModelId, forKey: .draftModelId)
        try c.encode(numDraftTokens, forKey: .numDraftTokens)
        try c.encodeIfPresent(memoryPolicy, forKey: .memoryPolicy)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, draftModelId, numDraftTokens, memoryPolicy
    }

    func validate() throws {
        guard mode == "mtp" || mode == "traditional" else {
            throw ConfigValidationError(
                "backend.specDecoding.mode: must be 'mtp' or 'traditional' (got '\(mode)')")
        }
        // NOTE: draftModelId is optional — when nil, runtime uses the main model
        // as the drafter (self-speculation). createSpeculativeConfig() logs a warning
        // and falls back to mlxModelHandle at inference time.
    }
}

/// Pure overlay of UI specDecoding selections onto an authored config.
/// `uiEnabled` / `uiMode` are `nil` when the user never touched the matching
/// UI control (UserDefaults key absent) — that dimension keeps the authored value.
/// When a value is present it takes precedence over the authored one in that dimension.
/// Kept pure so the merge semantics are exact-value testable (cf. pureMTPDrafterSelection).
func pureSpecDecodingUIOverlay(
    config: inout SpecDecodingConfig,
    uiEnabled: Bool?,
    uiMode: String?
) {
    if let uiEnabled {
        config.enabled = uiEnabled
    }
    if let uiMode {
        config.mode = uiMode
    }
}

/// Merge an explicit UI KV-quantization choice into the authored backend
/// config. A `nil` dimension means the user did not touch that control
/// (UserDefaults key absent) — that dimension keeps the authored value.
///
/// When `uiBits` is present it also pins `kvScheme` to the matching affine
/// width: the engine's scheme-first resolver (MLXBridge `makeKVCacheConfiguration`)
/// takes an authored `"turbo*"` scheme over `bits`, so without the scheme fix an
/// explicit UI bit selection would be silently ignored (UI shows 8, engine runs
/// 4-bit turbo). `"affine\<bits>"` routes the engine to the affine branch where
/// the bit width is honored; 4/8 are the valid affine widths.
/// Kept pure so the merge semantics are exact-value testable
/// (cf. `pureSpecDecodingUIOverlay`, `pureMTPDrafterSelection`).
func pureKVQuantUIOverlay(
    config: inout KVCacheQuantizationConfig,
    uiEnabled: Bool?,
    uiBits: Int?
) {
    if let uiEnabled {
        config.enabled = uiEnabled
    }
    if let uiBits {
        config.bits = uiBits
        config.kvScheme = "affine\(uiBits)"
    }
}

/// Inference backend selection and resource limits.
public struct BackendConfig: Sendable, Codable, Equatable {
    public var preference: [String]
    public var maxConcurrentSessions: Int
    public var kvCacheGB: Double
    public var kvCacheQuantization: KVCacheQuantizationConfig
    public var wiredMemory: WiredMemoryConfig
    public var specDecoding: SpecDecodingConfig
    /// VLM image resize dimensions. Applied to all inference paths so per-image
    /// token counts are consistent. Default 1024×1024 preserves VLM detail while
    /// bounding token overhead.
    public var vlmImageResizeWidth: Int
    public var vlmImageResizeHeight: Int

    public static let `default` = BackendConfig()

    public init(
        preference: [String] = ["coreai", "mlx"],
        maxConcurrentSessions: Int = 8,
        kvCacheGB: Double = 16.0,
        kvCacheQuantization: KVCacheQuantizationConfig? = nil,
        wiredMemory: WiredMemoryConfig? = nil,
        specDecoding: SpecDecodingConfig? = nil,
        vlmImageResizeWidth: Int = 1024,
        vlmImageResizeHeight: Int = 1024,
    ) {
        self.preference = preference
        self.maxConcurrentSessions = maxConcurrentSessions
        self.kvCacheGB = kvCacheGB
        self.kvCacheQuantization = kvCacheQuantization ?? .default
        self.wiredMemory = wiredMemory ?? .default
        self.specDecoding = specDecoding ?? .default
        self.vlmImageResizeWidth = max(64, min(vlmImageResizeWidth, 4096))
        self.vlmImageResizeHeight = max(64, min(vlmImageResizeHeight, 4096))
    }

    // MARK: Codable — lenient (a partial hand-authored `backend:` block keeps the
    // keys the owner wrote — e.g. only `backend: {preference: [mlx]}` — and
    // defaults the rest, instead of failing the whole file).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.preference = (try? c.decode([String].self, forKey: .preference)) ?? d.preference
        self.maxConcurrentSessions =
            (try? c.decode(Int.self, forKey: .maxConcurrentSessions)) ?? d.maxConcurrentSessions
        self.kvCacheGB = (try? c.decode(Double.self, forKey: .kvCacheGB)) ?? d.kvCacheGB
        self.kvCacheQuantization =
            (try? c.decode(KVCacheQuantizationConfig.self, forKey: .kvCacheQuantization))
            ?? .default
        self.wiredMemory = (try? c.decode(WiredMemoryConfig.self, forKey: .wiredMemory)) ?? .default
        self.specDecoding =
            (try? c.decode(SpecDecodingConfig.self, forKey: .specDecoding)) ?? .default
        self.vlmImageResizeWidth =
            (try? c.decode(Int.self, forKey: .vlmImageResizeWidth)) ?? d.vlmImageResizeWidth
        self.vlmImageResizeHeight =
            (try? c.decode(Int.self, forKey: .vlmImageResizeHeight)) ?? d.vlmImageResizeHeight
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preference, forKey: .preference)
        try c.encode(maxConcurrentSessions, forKey: .maxConcurrentSessions)
        try c.encode(kvCacheGB, forKey: .kvCacheGB)
        try c.encode(kvCacheQuantization, forKey: .kvCacheQuantization)
        try c.encode(wiredMemory, forKey: .wiredMemory)
        try c.encode(specDecoding, forKey: .specDecoding)
        try c.encode(vlmImageResizeWidth, forKey: .vlmImageResizeWidth)
        try c.encode(vlmImageResizeHeight, forKey: .vlmImageResizeHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case preference, maxConcurrentSessions, kvCacheGB, kvCacheQuantization
        case wiredMemory, specDecoding, vlmImageResizeWidth, vlmImageResizeHeight
    }

    func validate() throws {
        guard !preference.isEmpty else {
            throw ConfigValidationError("backend.preference: must have at least one backend")
        }
        guard maxConcurrentSessions > 0 else {
            throw ConfigValidationError("backend.maxConcurrentSessions: must be > 0")
        }
        try kvCacheQuantization.validate()
        if specDecoding.enabled {
            try specDecoding.validate()
        }
    }
}

/// KV cache dynamic quantization configuration.
///
/// When enabled, KV cache auto-downgrades from FP16 → INT8/INT4 after
/// ``quantizedKVStart`` tokens, saving up to 4× memory on long-context sessions.
/// Backed by mlx-swift-lm ``GenerateParameters.kvBits`` /\
/// ``GenerateParameters.quantizedKVStart`` / ``GenerateParameters.kvScheme``
/// (see MLXLMCommon/Evaluate.swift:54-78).
public struct KVCacheQuantizationConfig: Sendable, Codable, Equatable {
    /// Master toggle — enabled means KV cache quantization is active.
    public var enabled: Bool
    /// Quantization bits: 4 (most aggressive) or 8 (conservative). nil = disabled.
    public var bits: Int?
    /// SV/MLX group size for KV quantization (default: 64).
    public var groupSize: Int
    /// Token step after which KV quantization kicks in (default: 256).
    /// 0 means quantize immediately; higher values keep early context in FP16 for accuracy.
    public var quantizedKVStart: Int
    /// Optional compression scheme string (e.g. "affine4", "affine8").
    /// When set, overrides kvBits — see upstream Evaluate.swift L75-78.
    public var kvScheme: String?

    public static let `default` = KVCacheQuantizationConfig(
        enabled: true,
        bits: 4,
        groupSize: 64,
        quantizedKVStart: 256,
        kvScheme: "turbo4"
    )

    public init(
        enabled: Bool = true,
        bits: Int? = 4,
        groupSize: Int = 64,
        quantizedKVStart: Int = 256,
        kvScheme: String? = "turbo4"
    ) {
        self.enabled = enabled
        self.bits = bits
        self.groupSize = groupSize
        self.quantizedKVStart = quantizedKVStart
        self.kvScheme = kvScheme
    }

    // MARK: Codable — lenient (partial hand-authored `kvCacheQuantization:`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.bits = try? c.decode(Int.self, forKey: .bits)
        self.groupSize = (try? c.decode(Int.self, forKey: .groupSize)) ?? d.groupSize
        self.quantizedKVStart =
            (try? c.decode(Int.self, forKey: .quantizedKVStart)) ?? d.quantizedKVStart
        self.kvScheme = try? c.decode(String.self, forKey: .kvScheme)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(bits, forKey: .bits)
        try c.encode(groupSize, forKey: .groupSize)
        try c.encode(quantizedKVStart, forKey: .quantizedKVStart)
        try c.encodeIfPresent(kvScheme, forKey: .kvScheme)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, bits, groupSize, quantizedKVStart, kvScheme
    }

    func validate() throws {
        guard !enabled || bits == nil || (4 ... 8).contains(bits ?? 4) else {
            throw ConfigValidationError(
                "backend.kvCacheQuantization.bits: must be 4 or 8 (got \(String(describing: bits)))"
            )
        }
        guard groupSize > 0 else {
            throw ConfigValidationError("backend.kvCacheQuantization.groupSize: must be > 0")
        }
        guard quantizedKVStart >= 0 else {
            throw ConfigValidationError(
                "backend.kvCacheQuantization.quantizedKVStart: must be >= 0")
        }
    }
}

// MARK: - Model Configuration

/// Per-model settings stored in config.yaml under `models.<id>`.
public struct ModelConfigEntry: Sendable, Codable, Equatable {
    public var enabled: Bool
    /// Source hint for EngineConfig prefix resolution.
    /// `"huggingface"` → adds "hf:" prefix to force HF path.
    /// Any other value (or omitted) → bare path, uses defaultHub ("modelscope").
    public var source: String = "modelscope"
    public var modelId: String
    public var version: String?
    public var sampling: SamplingConfig
    public var maxSessionTokens: Int

    public static let defaultEntry = ModelConfigEntry(
        enabled: true,
        source: "modelscope",
        modelId: "mlx-community/gemma-4-e2b-it-4bit",
        version: nil,
        sampling: .default,
        maxSessionTokens: 32768,
    )

    public static var defaultModels: [String: ModelConfigEntry] {
        ["default": defaultEntry]
    }

    // MARK: - Dynamic Memory Enforcer (4-tier)

    /// 4-tier memory ceiling policy.
    ///
    /// - safe: 40% physical RAM ceiling (reserve 60% for macOS + user apps)
    /// - balanced: 55% ceiling (default, reserve 45%)
    /// - aggressive: 75% ceiling (reserve 25%, for high-RAM machines)
    /// - custom(pct): user-specified percentage (clamped to 20-85%)
    public struct MemoryGuardTier: Sendable, Codable, Equatable, CustomStringConvertible {
        public let percentage: Int

        public init(percentage: Int) {
            self.percentage = min(max(percentage, 20), 85)
        }

        public static var safe: MemoryGuardTier {
            MemoryGuardTier(percentage: 40)
        }

        public static var balanced: MemoryGuardTier {
            MemoryGuardTier(percentage: 55)
        }

        public static var aggressive: MemoryGuardTier {
            MemoryGuardTier(percentage: 75)
        }

        public static var systemDefault: MemoryGuardTier {
            .balanced
        }

        public var description: String {
            switch percentage {
            case 40: "safe"
            case 55: "balanced"
            case 75: "aggressive"
            default: "custom(\(percentage)%)"
            }
        }
    }

    /// Infer appropriate memory tier from physical RAM size.
    ///
    /// Conservative heuristic: larger machines get more aggressive allocation.
    /// - safe: < 16 GB RAM (40% ceiling)
    /// - balanced: 16-31 GB RAM (55% ceiling)
    /// - aggressive: >= 32 GB RAM (75% ceiling)
    public static func inferMemoryTier(from physicalMemory: UInt64) -> MemoryGuardTier {
        let gb = Double(physicalMemory) / 1_073_741_824.0
        if gb >= 32 { return .aggressive }
        if gb >= 16 { return .balanced }
        return .safe
    }

    /// Detect physical memory. macOS via sysctl hw.memsize; iOS via ProcessInfo hardwareInfo.
    /// Returns bytes. Falls back to 16 GB if detection fails.
    public static func detectPhysicalMemory() -> UInt64 {
        #if os(iOS)
        return UInt64(ProcessInfo.processInfo.physicalMemory)
        #else
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let ret = sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        if ret == 0, memSize > 0 {
            return memSize
        }
        return 16 * 1024 * 1024 * 1024  // safe fallback
        #endif
    }

    /// Compute an adaptive memory budget based on tier policy.
    ///
    /// Apple Silicon UMA: CPU + GPU share physical RAM. We must reserve
    /// headroom for macOS itself + user apps. Budget varies by tier:
    /// - safe: 40%, balanced: 55%, aggressive: 75%, custom: user-defined
    /// Dynamic ceiling: if system free memory is low, budget scales down
    /// proportionally. Hard floor: 4 GB minimum regardless.
    public static func computeMemoryBudget(
        physicalMemory: UInt64, tier: MemoryGuardTier = .systemDefault
    ) -> UInt64 {
        let baseBudget = physicalMemory * UInt64(tier.percentage) / 100
        return max(baseBudget, 4 * 1024 * 1024 * 1024)
    }

    public init(
        enabled: Bool = true,
        source: String = "modelscope",
        modelId: String,
        version: String? = nil,
        sampling: SamplingConfig = .default,
        maxSessionTokens: Int = 32768,
    ) {
        self.enabled = enabled
        self.source = source
        self.modelId = modelId
        self.version = version
        self.sampling = sampling
        self.maxSessionTokens = maxSessionTokens
    }

    // MARK: Codable — lenient (a partial hand-authored `models.<id>:` entry keeps
    // the keys the owner wrote, defaults the rest). `modelId` is REQUIRED — it
    // is the entry's identity; an entry without it is malformed and the
    // `models` block falls back to `defaultModels` (a visible, logged
    // degradation), never the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultEntry
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.source = (try? c.decode(String.self, forKey: .source)) ?? d.source
        self.modelId = try c.decode(String.self, forKey: .modelId)
        self.version = try? c.decode(String.self, forKey: .version)
        self.sampling = (try? c.decode(SamplingConfig.self, forKey: .sampling)) ?? .default
        self.maxSessionTokens =
            (try? c.decode(Int.self, forKey: .maxSessionTokens)) ?? d.maxSessionTokens
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(source, forKey: .source)
        try c.encode(modelId, forKey: .modelId)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(sampling, forKey: .sampling)
        try c.encode(maxSessionTokens, forKey: .maxSessionTokens)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, source, modelId, version, sampling, maxSessionTokens
    }
}

/// Sampling-strategy selection mirrored from upstream MLXSamplingMode.
/// When set, this takes precedence over individual topP/topK fields
/// (explicit-zero-wins semantics: greedy → temperature 0, ignores filters).
public enum SamplingMode: Sendable, Codable, Equatable {
    /// Deterministic decoding — always pick the most likely token.
    case greedy
    /// Nucleus (top-p) sampling. Value is the probability cutoff (0-1).
    case nucleus(Double)
    /// Top-k sampling. Value is the k parameter (1-vocabSize).
    case topK(Int)

    public static let `default`: SamplingMode? = nil
}

/// Sampling parameters per model.
public struct SamplingConfig: Sendable, Codable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    /// Explicit mode selection (mirrors upstream MLXSamplingMode). Takes precedence
    /// over topP/topK when set. nil → legacy behavior (respect topP/topK individually).
    public var mode: SamplingMode?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var seed: Int64?
    /// Prefill config — stepSize (ceiling per forward), chunking (division strategy).
    /// Aligns with upstream PrefillParameters (Evaluate.swift L58).
    public var prefill: PrefillConfig = .default
    /// Max KV cache size (enables RotatingKVCache when set)
    public var maxKVSize: Int? = nil
    /// Context window for repetition penalty
    public var repetitionContextSize: Int = 20
    /// Context window for presence penalty
    public var presenceContextSize: Int = 20
    /// Context window for frequency penalty
    public var frequencyContextSize: Int = 20
    public var maxTokens: Int?
    public var stopSequences: [String]

    public static let `default` = SamplingConfig()

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        mode: SamplingMode? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int64? = nil,
        prefill: PrefillConfig = .default,
        maxKVSize: Int? = nil,
        repetitionContextSize: Int = 20,
        presenceContextSize: Int = 20,
        frequencyContextSize: Int = 20,
        maxTokens: Int? = nil,
        stopSequences: [String] = [],
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.mode = mode
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
        self.prefill = prefill
        self.maxKVSize = maxKVSize
        self.repetitionContextSize = repetitionContextSize
        self.presenceContextSize = presenceContextSize
        self.frequencyContextSize = frequencyContextSize
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }

    // MARK: Codable — lenient (a partial hand-authored `sampling:` block keeps
    // the keys the owner wrote, defaults the rest — no key is structurally
    // required; `stopSequences`/`prefill` are present-by-default).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.temperature = try? c.decode(Double.self, forKey: .temperature)
        self.topP = try? c.decode(Double.self, forKey: .topP)
        self.topK = try? c.decode(Int.self, forKey: .topK)
        self.mode = try? c.decode(SamplingMode.self, forKey: .mode)
        self.minP = try? c.decode(Double.self, forKey: .minP)
        self.repetitionPenalty = try? c.decode(Double.self, forKey: .repetitionPenalty)
        self.presencePenalty = try? c.decode(Double.self, forKey: .presencePenalty)
        self.frequencyPenalty = try? c.decode(Double.self, forKey: .frequencyPenalty)
        self.seed = try? c.decode(Int64.self, forKey: .seed)
        self.prefill = (try? c.decode(PrefillConfig.self, forKey: .prefill)) ?? .default
        self.maxKVSize = try? c.decode(Int.self, forKey: .maxKVSize)
        self.repetitionContextSize =
            (try? c.decode(Int.self, forKey: .repetitionContextSize)) ?? d.repetitionContextSize
        self.presenceContextSize =
            (try? c.decode(Int.self, forKey: .presenceContextSize)) ?? d.presenceContextSize
        self.frequencyContextSize =
            (try? c.decode(Int.self, forKey: .frequencyContextSize)) ?? d.frequencyContextSize
        self.maxTokens = try? c.decode(Int.self, forKey: .maxTokens)
        self.stopSequences = (try? c.decode([String].self, forKey: .stopSequences)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encodeIfPresent(topK, forKey: .topK)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(minP, forKey: .minP)
        try c.encodeIfPresent(repetitionPenalty, forKey: .repetitionPenalty)
        try c.encodeIfPresent(presencePenalty, forKey: .presencePenalty)
        try c.encodeIfPresent(frequencyPenalty, forKey: .frequencyPenalty)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encode(prefill, forKey: .prefill)
        try c.encodeIfPresent(maxKVSize, forKey: .maxKVSize)
        try c.encode(repetitionContextSize, forKey: .repetitionContextSize)
        try c.encode(presenceContextSize, forKey: .presenceContextSize)
        try c.encode(frequencyContextSize, forKey: .frequencyContextSize)
        try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try c.encode(stopSequences, forKey: .stopSequences)
    }

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, mode, minP
        case repetitionPenalty, repetitionContextSize, presencePenalty, presenceContextSize
        case frequencyPenalty, frequencyContextSize, seed, prefill, maxKVSize
        case maxTokens, stopSequences
    }
}

// MARK: - Memory Config

/// Session memory and RAG settings.
public struct MemoryConfig: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var sessionTTL: Int
    public var maxRecallResults: Int
    public var archivalTTL: Int
    public var vectorDim: Int

    public static let `default` = MemoryConfig()

    public init(
        enabled: Bool = true,
        sessionTTL: Int = 86400,
        maxRecallResults: Int = 3,
        archivalTTL: Int = 15_552_000,
        vectorDim: Int = 768,
    ) {
        self.enabled = enabled
        self.sessionTTL = sessionTTL
        self.maxRecallResults = maxRecallResults
        self.archivalTTL = archivalTTL
        self.vectorDim = vectorDim
    }

    // MARK: Codable — lenient (partial hand-authored `memory:` block).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.sessionTTL = (try? c.decode(Int.self, forKey: .sessionTTL)) ?? d.sessionTTL
        self.maxRecallResults =
            (try? c.decode(Int.self, forKey: .maxRecallResults)) ?? d.maxRecallResults
        self.archivalTTL = (try? c.decode(Int.self, forKey: .archivalTTL)) ?? d.archivalTTL
        self.vectorDim = (try? c.decode(Int.self, forKey: .vectorDim)) ?? d.vectorDim
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(sessionTTL, forKey: .sessionTTL)
        try c.encode(maxRecallResults, forKey: .maxRecallResults)
        try c.encode(archivalTTL, forKey: .archivalTTL)
        try c.encode(vectorDim, forKey: .vectorDim)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, sessionTTL, maxRecallResults, archivalTTL, vectorDim
    }

    func validate() throws {
        guard sessionTTL > 0 else {
            throw ConfigValidationError("memory.sessionTTL: must be > 0 seconds")
        }
        guard maxRecallResults > 0, maxRecallResults <= 20 else {
            throw ConfigValidationError("memory.maxRecallResults: must be 1-20")
        }
    }
}

// MARK: - Metrics Config

/// Metrics and token tracking settings.
public struct MetricsConfig: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var tokenTracking: Bool
    public var exportInterval: Int
    public var retentionDays: Int

    public static let `default` = MetricsConfig()

    public init(
        enabled: Bool = true,
        tokenTracking: Bool = true,
        exportInterval: Int = 60,
        retentionDays: Int = 30,
    ) {
        self.enabled = enabled
        self.tokenTracking = tokenTracking
        self.exportInterval = exportInterval
        self.retentionDays = retentionDays
    }

    // MARK: Codable — lenient (partial hand-authored `metrics:` block).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.tokenTracking = (try? c.decode(Bool.self, forKey: .tokenTracking)) ?? d.tokenTracking
        self.exportInterval = (try? c.decode(Int.self, forKey: .exportInterval)) ?? d.exportInterval
        self.retentionDays = (try? c.decode(Int.self, forKey: .retentionDays)) ?? d.retentionDays
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(tokenTracking, forKey: .tokenTracking)
        try c.encode(exportInterval, forKey: .exportInterval)
        try c.encode(retentionDays, forKey: .retentionDays)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, tokenTracking, exportInterval, retentionDays
    }
}

/// Configuration validation error with field path.
public enum ConfigValidationError: Error, LocalizedError, Sendable {
    case invalid(String)
    case missing(String)
    case typeMismatch(String, String)

    public init(_ message: String) {
        self = .invalid(message)
    }

    public var errorDescription: String? {
        switch self {
        case .invalid(let msg): "Config invalid: \(msg)"
        case .missing(let field): "Missing required config: \(field)"
        case .typeMismatch(let field, let expected):
            "Type mismatch for \(field): expected \(expected)"
        }
    }
}
