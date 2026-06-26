// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// MLXBridge.swift — MLX inference bridge
//
// Compiled only when 'mlx' trait is active. Implements:
//   - MLXModelLoader (actor) — loads models via ModelScope, HF, or local path
//   - Sampling parameter bridge — MLXSamplingConfig → GenerateParameters
//   - Message conversion — ocoreai Message → mlx-swift-lm Chat.Message
//
// ### Architecture:
// - Models can be loaded from:
//   1. Local path: `/path/to/model/` or `~/path/to/model/`
//   2. ModelScope Hub: `mscope:Qwen/Qwen2.5-7B-Instruct`
//   3. HuggingFace Hub: `hf:mlx-community/Qwen3.5-4B`
//
// ### MLX Stack (mlx-swift-lm):
//   LLMModelFactory.loadContainer(from: downloader, using: tokenizerLoader)
//     → ModelContainer (thread-safe shell around ModelContext)
//       → ChatSession (KVCache + generate + tokenization)
//
// Reference: MLXChatExample/Services/MLXService.swift (ml-explore upstream)
//   — gold standard for native MLX loading pattern.

#if mlx

	import Foundation
	import Logging
	import MLXLLM
	import MLXLMCommon

	// MARK: - HuggingFace Integration

	import HuggingFace

	/// Native MLX download + tokenizer via swift-huggingface macros.
	/// Auth auto-detected by HubClient from HF_TOKEN env var / filesystem.
	import MLXHuggingFace
	import Tokenizers

	// MARK: - MLX Model Handle

	/// Protocol for an MLX-loaded model handle — hides MLX-specific types
	/// so EngineManager can talk to it without directly importing MLXLLM.
	protocol MLXModelHandle: Sendable {
		var modelContainer: MLXLMCommon.ModelContainer { get }
		var modelId: String { get }
		var layerCount: Int { get }
	}

	final class MLXModelHandleImpl: MLXModelHandle {
		let modelContainer: MLXLMCommon.ModelContainer
		let modelId: String
		let layerCount: Int

		init(modelContainer: MLXLMCommon.ModelContainer, modelId: String) {
			self.modelContainer = modelContainer
			self.modelId = modelId
			layerCount = 0
		}
	}

	// MARK: - MLX Model Loader

	/// Load an MLX model from local filesystem, ModelScope Hub, or HuggingFace.
	///
	/// HF path: native `#hubDownloader()` + `#huggingFaceTokenizerLoader()` (zero handwritten code)
	/// MS path:  custom `ModelScopeDownloader` (upstream has no ModelScope support)
	/// Local:   `LLMModelFactory.loadContainer(from: directory, using: tokenizer)`
	actor MLXModelLoader {
		// MARK: - Configuration

		private let logger: Logger
		private let defaultHub: String
		private let modelScopeToken: String?

		init(
			logger: Logger,
			cacheBase _: URL? = nil,
			defaultHub: String = "modelscope",
			modelScopeToken: String? = nil,
			hfToken _: String? = nil,
		) {
			self.logger = logger
			self.defaultHub = defaultHub
			self.modelScopeToken = modelScopeToken
			// hfToken is auto-detected by HubClient from HF_TOKEN env var — kept for API compat
		}

		// MARK: - Public Load

		func load(modelURL: URL, modelId: String) async throws -> (any MLXModelHandle) {
			logger.info("Loading MLX model \(modelId) from \(modelURL.path)")
			let start = ContinuousClock.now

			// Prefer raw modelId for source detection — modelURL.path is often mangled
			// by URL(fileURLWithPath:) which adds a "/" prefix breaking prefix detection.
			let source = MLXModelLoader.parseSource(modelId, fallbackPath: modelURL.path)

			let container: MLXLMCommon.ModelContainer = switch source {
			case let .local(localPath):
				try await loadLocal(Path(localPath), modelId: modelId)

			case let .mscope(repoId):
				try await loadFromHub(
					.modelScope, repoId: repoId, modelId: modelId,
				)

			case let .huggingFace(repoId):
				try await loadFromHub(
					.huggingFace, repoId: repoId, modelId: modelId,
				)

			default:
				try await loadLocal(url: modelURL, fallback: modelId)
			}

			logElapsed("MLX model \(modelId) loaded", start)

			return MLXModelHandleImpl(modelContainer: container, modelId: modelId)
		}

		// MARK: - Local Load

		func loadLocal(_ path: Path, modelId: String) async throws -> MLXLMCommon.ModelContainer {
			logger.info("Using local path for \(modelId): \(path.rawValue)")
			let directory = URL(fileURLWithPath: path.rawValue)
			do {
				return try await LLMModelFactory.shared.loadContainer(
					from: directory,
					using: #huggingFaceTokenizerLoader(),
				)
			} catch {
				logger.error("Local load failed for \(modelId): \(error.localizedDescription)")
				throw MLXLoadError.localLoadFailed(path: path.rawValue, error: error.localizedDescription)
			}
		}

		func loadLocal(url: URL, fallback modelId: String) async throws -> MLXLMCommon.ModelContainer {
			do {
				return try await loadLocal(Path(url.path), modelId: modelId)
			} catch {
				logger.warning("Local path failed for \(modelId), trying hub: \(error.localizedDescription)")
			}

			let repoId = url.lastPathComponent
			return try await loadFromHub(.modelScope, repoId: repoId, modelId: modelId)
		}

		// MARK: - Hub Load

		enum HubProvider { case modelScope, huggingFace }

		@inline(never)
		func loadFromHub(_ provider: MLXModelLoader.HubProvider, repoId: String, modelId: String) async throws -> MLXLMCommon.ModelContainer {
			let start = ContinuousClock.now

			switch provider {
			case .modelScope:
				logger.info("Downloading from ModelScope: \(repoId)")
				// Notify UI that download started
				await MainActor.run {
					OcoreaiDownloadProgress.shared.start(modelId: modelId)
				}
				// Note: Downloader protocol requires synchronous progressHandler.
				// v3 breaking change: progressHandler must be (@Sendable (Progress) -> Void), not async.
				// UI progress is handled via start/finish markers instead.
				let msDownloader = ModelScopeDownloader()
				let directory = try await msDownloader.download(
					id: repoId, revision: nil, matching: [], useLatest: false,
					progressHandler: { _ in
						// Synchronous callback — no MainActor.run allowed here.
						// Progress reporting is handled by start/finish markers.
					},
				)
				logElapsed("ModelScope download \(repoId) completed", start)
				do {
					let container = try await LLMModelFactory.shared.loadContainer(
						from: directory,
						using: #huggingFaceTokenizerLoader(),
					)
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: modelId, success: true)
					}
					return container
				} catch {
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: modelId, success: false)
					}
					throw error
				}

			case .huggingFace:
				// Native MLX path — #hubDownloader() gives built-in cache, resume, progress.
				// Auth auto-detected by HubClient from HF_TOKEN / filesystem.
				// Equivalent to MLXChatExample: factory.loadContainer(from: downloader, ...)
				logger.info("Downloading from HuggingFace: \(repoId)")
				// Notify UI that download started
				await MainActor.run {
					OcoreaiDownloadProgress.shared.start(modelId: modelId)
				}
				do {
					let container = try await LLMModelFactory.shared.loadContainer(
						from: #hubDownloader(),
						using: #huggingFaceTokenizerLoader(),
						configuration: ModelConfiguration(id: repoId),
					)
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: modelId, success: true)
					}
					return container
				} catch {
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: modelId, success: false)
					}
					throw error
				}
			}
		}

		// MARK: - Source Parsing

		struct Path: ExpressibleByStringLiteral {
			let rawValue: String
			init(_ value: String) {
				rawValue = value
			}

			init(stringLiteral value: String) {
				rawValue = value
			}
		}

		/// Parse the source type from the raw model ID.
		/// - Parameters:
		///   - modelId: Raw model identifier (e.g. "hf:org/repo", "org/repo", "/local/path")
		///   - fallbackPath: modelURL.path — used only when modelId is ambiguous
		nonisolated static func parseSource(
			_ modelId: String,
			fallbackPath: String? = nil,
		) -> ModelSource {
			if modelId.hasPrefix("mscope:") {
				return .mscope(String(modelId.dropFirst(7)))
			}
			if modelId.hasPrefix("hf:") {
				return .huggingFace(String(modelId.dropFirst(3)))
			}
			if modelId.hasPrefix("huggingface:") {
				return .huggingFace(String(modelId.dropFirst(12)))
			}
			// Bare "org/repo" pattern — treat as HuggingFace Hub
			// (most HF models use this format; ModelScope models should use mscope: prefix)
			if modelId.contains("/") && !modelId.hasPrefix("/") && !modelId.hasPrefix("~/") {
				return .huggingFace(modelId)
			}
			// Fallback to modelURL.path if modelId was a plain name without slashes
			if let fallback = fallbackPath {
				if fallback.contains("/"), !fallback.hasPrefix("/"), !fallback.hasPrefix("~/") {
					return .huggingFace(fallback)
				}
			}
			// Absolute or tilde path → local
			let check = modelId.hasPrefix("/") || modelId.hasPrefix("~/")
			if check {
				return .local(modelId)
			}
			// Single-component name with no slash — try local fallback
			return .local(fallbackPath ?? modelId)
		}

		// MARK: - Teardown

		func teardown() {
			logger.info("MLXModelLoader teardown requested")
		}

		// MARK: - Helpers

		private func logElapsed(_ msg: String, _ start: ContinuousClock.Instant) {
			let elapsed = ContinuousClock.now.duration(to: start)
			let ms = Double(elapsed.components.seconds) * 1000.0
				+ Double(elapsed.components.attoseconds) / 1e15
			logger.info("\(msg) in \(String(format: "%.0fms", ms))")
		}
	}

	// MARK: - Model Source

	extension MLXModelLoader {
		enum ModelSource {
			case local(String)
			case mscope(String)
			case huggingFace(String)
			case unknown(String)
		}
	}

	// MARK: - Sampling Config Bridge

	/// Convert ``SamplingConfiguration`` to mlx-swift-lm ``GenerateParameters``.
	nonisolated func makeGenerateParameters(
		from sampling: SamplingConfiguration,
		maxTokens: Int?,
		kvCacheQuant: KVCacheQuantizationConfig? = nil,
	) -> MLXLMCommon.GenerateParameters {
		var params = MLXLMCommon.GenerateParameters()
		params.maxTokens = maxTokens ?? 1024
		if let config = kvCacheQuant, config.enabled, let bits = config.bits {
			params.kvBits = bits
			params.kvGroupSize = config.groupSize
			params.quantizedKVStart = config.quantizedKVStart
		}
		if let temp = sampling.temperature, temp > 0 {
			params.temperature = Float(temp)
		}
		if let topP = sampling.topP, topP > 0 {
			params.topP = Float(topP)
		}
		if let topK = sampling.topK {
			params.topK = topK
		}
		if let repPen = sampling.repetitionPenalty, repPen > 0 {
			params.repetitionPenalty = Float(repPen)
		}
		return params
	}

	// MARK: - Message Conversion

	/// Convert internal `Message` (ocoreai type) to `Chat.Message` (mlx-swift-lm).
	nonisolated func toMLXChatMessage(_ msg: Message) -> Chat.Message {
		let text = toMessageText(msg)
		switch msg.role {
		case "system": return Chat.Message.system(text)
		case "assistant": return Chat.Message.assistant(text)
		case "tool": return Chat.Message.tool(text)
		default: return Chat.Message.user(text)
		}
	}

	private nonisolated func toMessageText(_ msg: Message) -> String {
		switch msg.content {
		case let .some(.text(s)): s
		case let .some(.parts(parts)):
			parts.compactMap(\.text).joined(separator: "\n")
		case .none: ""
		}
	}

	// MARK: - Errors

	enum MLXLoadError: LocalizedError {
		case localLoadFailed(path: String, error: String)
		case hubDownloadFailed(repoId: String, error: String)
		case invalidHubId(String)

		var errorDescription: String? {
			switch self {
			case let .localLoadFailed(path, err):
				"Local model load failed at \(path): \(err)"
			case let .hubDownloadFailed(repo, err):
				"Hub download failed for '\(repo)': \(err)"
			case let .invalidHubId(id):
				"Invalid hub identifier: \(id)"
			}
		}
	}

#endif // mlx
