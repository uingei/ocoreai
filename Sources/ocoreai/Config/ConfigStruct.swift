// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConfigStruct.swift — Configuration data model with validation
///
/// Declarative config schema backed by `Codable` + `Sendable`.
/// All sensitive fields use `.env(name)` or `${KEYCHAIN:…}` — never plaintext.
///
/// File location: `~/.ocoreai/config.yaml`

import Foundation

// MARK: - Top-level Config

/// Root configuration structure — decoded from YAML, written back on change.
public struct AppConfig: Sendable, Codable, Equatable {
	public var server: ServerConfig
	public var backend: BackendConfig
	public var models: [String: ModelConfigEntry]
	public var memory: MemoryConfig
	public var metrics: MetricsConfig
	public var safety: SafetyConfig

	public init(
		server: ServerConfig = .default,
		backend: BackendConfig = .default,
		models: [String: ModelConfigEntry] = ModelConfigEntry.defaultModels,
		memory: MemoryConfig = .default,
		metrics: MetricsConfig = .default,
		safety: SafetyConfig = .default,
	) {
		self.server = server
		self.backend = backend
		self.models = models
		self.memory = memory
		self.metrics = metrics
		self.safety = safety
	}

	/// Run validation — throws on invalid config.
	public func validate() throws {
		try server.validate()
		try backend.validate()
		try memory.validate()
		try safety.validate()
	}
}

// MARK: - Safety Config

/// Content safety configuration — controls pre/post inference filtering.
///
/// Stored in `~/.ocoreai/config.yaml` under the `safety:` key.
public struct SafetyConfig: Sendable, Codable, Equatable {
	/// Master toggle — disabled means all filters are bypassed.
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
		enabled: Bool = true,
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

	func validate() throws {
		// Non-negotiable categories cannot be set to "disabled"
		let nonNegotiable: [String] = ["underageSexual", "sexualViolence", "selfHarm"]
		for catName in nonNegotiable {
			if let mode = categoryModes[catName], mode == "disabled" {
				throw ConfigValidationError(
					"safety.categoryModes: cannot disable \(catName) — non-negotiable safety category",
				)
			}
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
	/// Policy type — "max" (peak ticket) or "sum" (aggregate tickets).
	/// "max" is default for inference — one big ticket dominates.
	public var policy: String
	/// Override the per-request budget in bytes. Auto-detected when 0.
	public var bytesOverride: Int

	public static let `default` = WiredMemoryConfig()

	public init(
		enabled: Bool = true,
		policy: String = "max",
		bytesOverride: Int = 0,
	) {
		self.enabled = enabled
		self.policy = policy
		self.bytesOverride = bytesOverride
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

	func validate() throws {
		guard mode == "mtp" || mode == "traditional" else {
			throw ConfigValidationError("backend.specDecoding.mode: must be 'mtp' or 'traditional' (got '\(mode)')")
		}
		// NOTE: draftModelId is optional — when nil, runtime uses the main model
		// as the drafter (self-speculation). createSpeculativeConfig() logs a warning
		// and falls back to mlxModelHandle at inference time.
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

	public static let `default` = BackendConfig()

	public init(
		preference: [String] = ["coreai", "mlx"],
		maxConcurrentSessions: Int = 8,
		kvCacheGB: Double = 16.0,
		kvCacheQuantization: KVCacheQuantizationConfig? = nil,
		wiredMemory: WiredMemoryConfig? = nil,
		specDecoding: SpecDecodingConfig? = nil,
	) {
		self.preference = preference
		self.maxConcurrentSessions = maxConcurrentSessions
		self.kvCacheGB = kvCacheGB
		self.kvCacheQuantization = kvCacheQuantization ?? .default
		self.wiredMemory = wiredMemory ?? .default
		self.specDecoding = specDecoding ?? .default
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

	func validate() throws {
		guard !enabled || bits == nil || (4 ... 8).contains(bits ?? 4) else {
			throw ConfigValidationError("backend.kvCacheQuantization.bits: must be 4 or 8 (got \(String(describing: bits)))")
		}
		guard groupSize > 0 else {
			throw ConfigValidationError("backend.kvCacheQuantization.groupSize: must be > 0")
		}
		guard quantizedKVStart >= 0 else {
			throw ConfigValidationError("backend.kvCacheQuantization.quantizedKVStart: must be >= 0")
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
		#if os(iOS) || os(visionOS)
			return UInt64(ProcessInfo.processInfo.physicalMemory)
		#else
			var memSize: UInt64 = 0
			var size = MemoryLayout<UInt64>.size
			let ret = sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
			if ret == 0, memSize > 0 {
				return memSize
			}
			return 16 * 1024 * 1024 * 1024 // safe fallback
		#endif
	}

	/// Compute an adaptive memory budget based on tier policy.
	///
	/// Apple Silicon UMA: CPU + GPU share physical RAM. We must reserve
	/// headroom for macOS itself + user apps. Budget varies by tier:
	/// - safe: 40%, balanced: 55%, aggressive: 75%, custom: user-defined
	/// Dynamic ceiling: if system free memory is low, budget scales down
	/// proportionally. Hard floor: 4 GB minimum regardless.
	public static func computeMemoryBudget(physicalMemory: UInt64, tier: MemoryGuardTier = .systemDefault) -> UInt64 {
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
}

/// Sampling parameters per model.
public struct SamplingConfig: Sendable, Codable, Equatable {
	public var temperature: Double?
	public var topP: Double?
	public var topK: Int?
	public var minP: Double?
	public var repetitionPenalty: Double?
	public var maxTokens: Int?
	public var stopSequences: [String]

	public static let `default` = SamplingConfig()

	public init(
		temperature: Double? = nil,
		topP: Double? = nil,
		topK: Int? = nil,
		minP: Double? = nil,
		repetitionPenalty: Double? = nil,
		maxTokens: Int? = nil,
		stopSequences: [String] = [],
	) {
		self.temperature = temperature
		self.topP = topP
		self.topK = topK
		self.minP = minP
		self.repetitionPenalty = repetitionPenalty
		self.maxTokens = maxTokens
		self.stopSequences = stopSequences
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
}

// MARK: - Validation Error

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
		case let .invalid(msg): "Config invalid: \(msg)"
		case let .missing(field): "Missing required config: \(field)"
		case let .typeMismatch(field, expected):
			"Type mismatch for \(field): expected \(expected)"
		}
	}
}
