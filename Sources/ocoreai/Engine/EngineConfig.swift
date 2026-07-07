// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineConfig.swift — EnginePool configuration

import Foundation
import Logging

/// Engine pool configuration — passed by value, immutable after initialization.
///
/// Controls concurrent session limits, queue depth, model paths, warmup behavior,
/// and optional KV cache management.
public struct EnginePoolConfig: Sendable {
	/// Maximum concurrent inference sessions before queueing
	public var maxConcurrentSessions: Int

	/// Maximum queued requests before rejection
	public var maxQueueSize: Int

	/// Base filesystem path to model configuration files
	public var modelConfigPath: String

	/// Base filesystem path to model weight directories
	public var modelDirectory: String

	/// Default model identifier (Hub id or local path)
	/// Format: "org/model" for hub, "/path/to/model" for local
	public var defaultModelId: String

	/// Number of tokens for the prewarm (warmup) inference run
	public var warmupTokens: Int

	/// Optional KV cache management configuration (nil = kvCache disabled)
	var kvCacheConfig: KVCacheManager.Config?

	/// Hard timeout for a single inference request (seconds).
	/// Prevents hung inference from permanently holding resources.
	var inferenceTimeoutSeconds: Int

	/// Optional session pool configuration (nil = pooling disabled).
	/// When enabled, ChatSession instances are pooled per-conversation for KV cache reuse.
	var sessionPoolConfig: SessionPoolConfig?

	/// KV cache dynamic quantization — KV auto-downgrades FP16 → INT4/INT8 after N tokens.
	var kvCacheQuantization: KVCacheQuantizationConfig = .default

	/// Wired memory GPU hard-isolation (Layer 0 below OOMGuard).
	var wiredMemory: WiredMemoryConfig = .default

	/// Speculative decoding — draft model proposes tokens, main model verifies.
	/// Defaults to disabled (zero behavior change).
	var specDecoding: SpecDecodingConfig = .default

	/// Default configuration with sensible production values
	public static let `default`: EnginePoolConfig = .init(
		maxConcurrentSessions: 8,
		maxQueueSize: 32,
		modelConfigPath: "./models/config.json",
		modelDirectory: "./models",
		defaultModelId: "mlx-community/gemma-4-e2b-it-4bit",
		warmupTokens: 4,
		kvCacheConfig: nil,
		inferenceTimeoutSeconds: 180,
		sessionPoolConfig: .default,
		kvCacheQuantization: .default,
		wiredMemory: .default,
		specDecoding: .default,
	)

	/// Build from the config system's ``AppConfig``.
	///
	/// Maps `backend.*` → engine limits, `models.default` → model id,
	/// `backend.kvCacheQuantization` → KV cache policy.
	/// Missing or invalid values fall back to `.default`.
	///
	/// When `appConfig` is `nil` the system works with hard-coded defaults.
	public init(from appConfig: AppConfig?, logger: Logger) {
		guard let app = appConfig else {
			self = Self.default
			logger.warning("No AppConfig available — using EnginePoolConfig defaults")
			return
		}

		self.maxConcurrentSessions = max(1, app.backend.maxConcurrentSessions)
		self.maxQueueSize = 32
		self.modelConfigPath = "./models/config.json"
		self.modelDirectory = "./models"

		// Resolve default model from config, fallback to hard-coded.
		// Bare "org/repo" → Loader's defaultHub decides.
		// HF override: use "hf:org/repo" in modelId directly.
		if let defaultEntry = app.models["default"] {
			self.defaultModelId = switch defaultEntry.source {
			case "huggingface": "hf:\(defaultEntry.modelId)"
			default: defaultEntry.modelId
			}
		} else {
			self.defaultModelId = Self.default.defaultModelId
		}
		self.warmupTokens = 4
		self.kvCacheConfig = nil
		self.inferenceTimeoutSeconds = 180
		self.sessionPoolConfig = .default
		self.kvCacheQuantization = app.backend.kvCacheQuantization
		self.wiredMemory = app.backend.wiredMemory

		let backendStr = app.backend.preference.joined(separator: ", ")
		logger.info("EnginePoolConfig from AppConfig — backend: \(backendStr), defaultModel: \(self.defaultModelId), sessions: \(self.maxConcurrentSessions)")
	}

	init(
		maxConcurrentSessions: Int,
		maxQueueSize: Int,
		modelConfigPath: String,
		modelDirectory: String,
		defaultModelId: String,
		warmupTokens: Int,
		kvCacheConfig: KVCacheManager.Config?,
		inferenceTimeoutSeconds: Int,
		sessionPoolConfig: SessionPoolConfig?,
		kvCacheQuantization: KVCacheQuantizationConfig,
		wiredMemory: WiredMemoryConfig,
		specDecoding: SpecDecodingConfig = .default,
	) {
		self.maxConcurrentSessions = maxConcurrentSessions
		self.maxQueueSize = maxQueueSize
		self.modelConfigPath = modelConfigPath
		self.modelDirectory = modelDirectory
		self.defaultModelId = defaultModelId
		self.warmupTokens = warmupTokens
		self.kvCacheConfig = kvCacheConfig
		self.inferenceTimeoutSeconds = inferenceTimeoutSeconds
		self.sessionPoolConfig = sessionPoolConfig
		self.kvCacheQuantization = kvCacheQuantization
		self.wiredMemory = wiredMemory
		self.specDecoding = specDecoding
	}
}
