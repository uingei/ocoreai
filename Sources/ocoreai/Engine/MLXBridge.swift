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
//   Auto-detect VLM via `preprocessor_config.json`:
//    - VLM → VLMModelFactory.loadContainer(...) — supports images/video/audio
//    - LLM → LLMModelFactory.loadContainer(...) — text only
//
// Reference: MLXChatExample/Services/MLXService.swift (ml-explore upstream)
//   — gold standard for native MLX loading pattern.


	// MARK: - Imports

	import Foundation
	import Logging
	import MLXLLM
	import MLXLMCommon
	import MLXVLM

	// MARK: - MLX Core (MLXArray, stacked — needed by EmbeddingService)

	import MLX

	// MARK: - MLXEmbedders Integration

	import MLXEmbedders

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
	/// VLM auto-detection: if model directory has `preprocessor_config.json`,
	/// it uses `VLMModelFactory` instead of `LLMModelFactory`.
	///
	/// HF path: native `#hubDownloader()` + `#huggingFaceTokenizerLoader()` (zero handwritten code)
	/// MS path:  custom `ModelScopeDownloader` (upstream has no ModelScope support)
	/// Local:   auto-detect VLM vs LLM then load accordingly
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

		// MARK: - VLM Detection

		/// VLM models have `processor_config.json` (processor_class).
			nonisolated static func isVLMModel(at directory: URL) -> Bool {
			let processorPath = directory.appendingPathComponent("processor_config.json")
			return FileManager.default.fileExists(atPath: processorPath.path)
		}

		/// Load container auto-detecting VLM vs LLM from directory.
		@inline(never)
		func loadContainer(
			from directory: URL,
			repoId: String? = nil
		) async throws -> MLXLMCommon.ModelContainer {
			if MLXModelLoader.isVLMModel(at: directory) {
				logger.info("VLM model detected — using VLMModelFactory")
				return try await MLXVLM.VLMModelFactory.shared.loadContainer(
					from: directory,
					using: #huggingFaceTokenizerLoader(),
				)
			}
			// LLM path
			return try await LLMModelFactory.shared.loadContainer(
				from: directory,
				using: #huggingFaceTokenizerLoader(),
			)
		}

		// MARK: - Cache Check

	/// Check if a model is already downloaded in the local cache.
	///
	/// - Parameters:
	///   - provider: Hub provider (ModelScope or HuggingFace)
	///   - repoId: Repository identifier (e.g. "Qwen/Qwen2.5-7B-Instruct")
	///   - logger: For diagnostic output (warning on incomplete cache)
	/// - Returns: true if a valid safetensors file exists in the expected cache directory
	///
	/// Integrity: verifies .safetensors files have non-zero size.
	/// Zero-length files indicate interrupted downloads — model is NOT cached.
		static func isModelCached(_ provider: MLXModelLoader.HubProvider, repoId: String, logger: Logger) -> Bool {
			Self.hasValidSafetensors(for: provider, repoId: repoId, log: logger)
		}

		/// Overload for callers without a Logger (e.g. UI ViewModel context).
		static func isModelCached(_ provider: MLXModelLoader.HubProvider, repoId: String) -> Bool {
			Self.hasValidSafetensors(for: provider, repoId: repoId, log: nil)
		}

		/// Resolve cache directory for a provider/repo pair, then check for valid safetensors.
		private static func hasValidSafetensors(
			for provider: MLXModelLoader.HubProvider,
			repoId: String,
			log: Logger?
		) -> Bool {
			let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
			guard let baseDir = urls.first else { return false }

			let cacheRoot: URL
			switch provider {
			case .modelScope:
				cacheRoot = baseDir
					.appendingPathComponent("ocoreai/modelscope")
					.appendingPathComponent(repoId)
					.appendingPathComponent("master")
			case .huggingFace:
				cacheRoot = baseDir
					.appendingPathComponent("org.ml-explore.mlx-swift-lm")
					.appendingPathComponent(repoId)
			}

			// Must have at least one non-empty safetensors file
			return hasValidSafetensors(in: cacheRoot, log: log)
		}

		private static func hasValidSafetensors(in url: URL, log: Logger?) -> Bool {
			guard FileManager.default.fileExists(atPath: url.path) else {
				return false
			}
			do {
				let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
				for item in files where item.pathExtension == "safetensors" {
					let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
					if size > 0 {
						return true
					}
					// Zero-length safetensors = incomplete download
					log?.warning("Incomplete cache: \(item.lastPathComponent) is 0 bytes — model will re-download")
				}
				return false
			} catch {
				// If directory listing fails, assume not cached — caller will retry download
				return false
			}
		}

		/// Recursively sum directory size in bytes. Omlx-style: used for
		/// progress estimation during HF downloads where we can't inject a callback.
		private static func directoryByteCount(_ url: URL) -> Int64 {
			guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
			var total: Int64 = 0
			do {
				let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
				for item in contents {
					let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
					if item.hasDirectoryPath {
						total += directoryByteCount(item)
					} else {
						total += Int64(size)
					}
				}
			} catch {
				// Directory may have changed — return what we got so far
			}
			return total
		}

		/// Start polling HF cache directory to estimate download progress.
		/// Returns a cancellable Task — cancel it when download completes.
		/// Omlx pattern: watch directory byte count + newest file mtime,
		/// estimate progress from observed growth vs expected size.
		///
		/// **mtime stall detection**: In addition to byte-count, track the
		/// modification date of the newest file. If byte count is flat AND
		/// newest file hasn't changed for `stallTimeout`, abort — prevents
		/// false-positive stall warnings during multi-file sequential downloads
		/// where one file finishes before the next starts.
		private static func startHFProgressPolling(
			cacheDir: URL,
			modelId: String,
			logger: Logger
		) -> Task<Void, Never> {
			Task.detached {
				let pollInterval: TimeInterval = 2
				var lastBytes: Int64 = directoryByteCount(cacheDir)
				var expectedBytes: Int64 = max(lastBytes, 1) * 2  // crude lower-bound
				var idleCount = 0  // consecutive polls with no growth
				var lastMtime: Date? = newestModificationDate(in: cacheDir)
				let mtimeStallTimeout: TimeInterval = 90  // 90s mtime stagnation = stall

				while !Task.isCancelled {
					try? await Task.sleep(for: .seconds(pollInterval))

					let currentBytes = directoryByteCount(cacheDir)

					if currentBytes > lastBytes {
						// Directory growing — update estimate and progress
						expectedBytes = max(expectedBytes, currentBytes * 2)
						let fraction = Double(currentBytes) / Double(max(expectedBytes, 1))
						let progress = Progress(totalUnitCount: 100)
						progress.completedUnitCount = Int64(min(max(1, fraction * 99), 99))
						await MainActor.run {
							OcoreaiDownloadProgress.shared.update(progress, for: modelId)
						}
						lastBytes = currentBytes
						idleCount = 0
						lastMtime = newestModificationDate(in: cacheDir)
					} else {
						idleCount += 1
						// mtime-based stall: if newest file hasn't changed,
						// the downloader is truly stuck (not just between files)
						if let currentMtime = newestModificationDate(in: cacheDir),
						   let last = lastMtime,
						   currentMtime.timeIntervalSince(last) == 0,
						   Date().timeIntervalSince(last) > mtimeStallTimeout {
							logger.warning("HF download stalled — mtime unchanged for ~\(Int(mtimeStallTimeout))s")
							break
						}
						// Legacy byte-count timeout — catches empty cache edge case
						if idleCount > 15 {
							logger.warning("HF download polling stopped — no growth for ~30s")
							break
						}
					}
				}
			}
		}

		/// Return the newest modification date among files in `directory`.
		private static func newestModificationDate(in directory: URL) -> Date? {
			guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
			do {
				var newest: Date? = nil
				let items = try FileManager.default.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: [.contentModificationDateKey]
				)
				for item in items {
					if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path),
					   let mtime = attrs[.modificationDate] as? Date,
					   mtime > newest ?? Date(timeIntervalSince1970: 0) {
						newest = mtime
					}
					// Recurse into subdirectories
					if item.hasDirectoryPath,
					   let subMtime = newestModificationDate(in: item),
					   subMtime > newest ?? Date(timeIntervalSince1970: 0) {
						newest = subMtime
					}
				}
				return newest
			} catch {
				return nil
			}
		}

		// MARK: - Public Load

	/// Primary load entry point — called by ``EnginePool``.
	/// Hub routing is handled by the loader's `defaultHub` configuration property,
	/// except for explicit "hf:" prefix override.
		func load(
			modelURL: URL,
			modelId: String,
		) async throws -> (any MLXModelHandle) {
			logger.info("Loading MLX model \(modelId) from \(modelURL.path)")
			let start = ContinuousClock.now

			// Local path
			if modelId.hasPrefix("/") || modelId.hasPrefix("~/") {
				logger.info("Loading local model: \(modelId)")
				let container = try await loadLocal(Path(modelId), modelId: modelId)
				logElapsed("MLX model \(modelId) loaded", start)
				return MLXModelHandleImpl(modelContainer: container, modelId: modelId)
			}

			// Determine hub provider — defaultHub property decides, hf: prefix overrides
			let provider: HubProvider
			let repoId: String

			if modelId.hasPrefix("hf:") || defaultHub == "huggingface" {
				provider = .huggingFace
				repoId = modelId.hasPrefix("hf:") ? String(modelId.dropFirst(3)) : modelId
			} else {
				provider = .modelScope
				repoId = modelId
			}

			// Try configured provider, fall back to the other on failure
			func loadFromHubWithFallback() async throws -> MLXLMCommon.ModelContainer {
				do {
					return try await loadFromHub(provider, repoId: repoId, modelId: modelId)
				} catch {
					logger.warning("\(provider == .modelScope ? "ModelScope" : "HuggingFace") failed for \(modelId) — falling back: \(error.localizedDescription)")
					let fallback: HubProvider = provider == .modelScope ? .huggingFace : .modelScope
					return try await loadFromHub(fallback, repoId: repoId, modelId: modelId)
				}
			}

			let container: MLXLMCommon.ModelContainer = try await loadFromHubWithFallback()

			logElapsed("MLX model \(modelId) loaded", start)

			return MLXModelHandleImpl(modelContainer: container, modelId: modelId)
		}

		// MARK: - Local Load

		func loadLocal(_ path: Path, modelId: String) async throws -> MLXLMCommon.ModelContainer {
			logger.info("Using local path for \(modelId): \(path.rawValue)")
			let directory = URL(fileURLWithPath: path.rawValue)
			do {
				return try await loadContainer(from: directory)
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

			// Strip prefix for progress tracking — UI components query by the plain repo id
			let progressKey = modelId.hasPrefix("mscope:") ? String(modelId.dropFirst(7))
				: modelId.hasPrefix("hf:") ? String(modelId.dropFirst(3))
				: modelId.hasPrefix("huggingface:") ? String(modelId.dropFirst(12))
				: modelId

			switch provider {
			case .modelScope:
				logger.info("Downloading from ModelScope: \(repoId)")
				// Notify UI that download started
				await MainActor.run {
					OcoreaiDownloadProgress.shared.start(modelId: progressKey)
				}
				// ProgressHandler: synchronous Sendable context — fire-and-forget to MainActor
				let msDownloader = ModelScopeDownloader(token: modelScopeToken)
				let directory = try await msDownloader.download(
					id: repoId, revision: nil, matching: ["*.safetensors", "*.json", "*.jinja"], useLatest: false,
					progressHandler: { [progressKey] progress in
						Task { @MainActor in
							OcoreaiDownloadProgress.shared.update(progress, for: progressKey)
						}
					},
				)
				logElapsed("ModelScope download \(repoId) completed", start)
				do {
					// VLM auto-detection: check for preprocessor_config.json
					let container = try await loadContainer(from: directory, repoId: repoId)
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: true)
					}
					return container
				} catch {
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: false)
					}
					throw error
				}

			case .huggingFace:
				// Native MLX path — #hubDownloader() gives built-in cache, resume, progress.
				// Auth auto-detected by HubClient from HF_TOKEN / filesystem.
				// Equivalent to MLXChatExample: factory.loadContainer(from: downloader, ...)
				// VLM: try LLMModelFactory first, fall back to VLMModelFactory on error.
				//
				// Progress: #hubDownloader() is a black-box macro with no callback injection.
				// We use omlx-style directory polling to estimate progress.
				logger.info("Downloading from HuggingFace: \(repoId)")
				// Notify UI that download started
				await MainActor.run {
					OcoreaiDownloadProgress.shared.start(modelId: progressKey)
				}

				// Determine HF cache directory for polling
				let hfCacheDir: URL = {
					let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
					guard let baseDir = urls.first else {
						return URL(fileURLWithPath: "/dev/null")
					}
					return baseDir
						.appendingPathComponent("org.ml-explore.mlx-swift-lm")
						.appendingPathComponent(repoId)
				}()

				// Start directory polling task for progress estimation
				let pollTask = Self.startHFProgressPolling(
					cacheDir: hfCacheDir,
					modelId: progressKey,
					logger: logger
				)

				do {
					let container = try await LLMModelFactory.shared.loadContainer(
						from: #hubDownloader(),
						using: #huggingFaceTokenizerLoader(),
						configuration: ModelConfiguration(id: repoId),
					)
					pollTask.cancel()
					await MainActor.run {
						OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: true)
					}
					return container
				} catch {
					// LLM load failed — try VLM factory (model may have preprocessor_config.json)
					logger.info("LLM load failed for \(repoId), trying VLM: \(error.localizedDescription)")
					do {
						let container = try await MLXVLM.VLMModelFactory.shared.loadContainer(
							from: #hubDownloader(),
							using: #huggingFaceTokenizerLoader(),
							configuration: ModelConfiguration(id: repoId),
						)
						pollTask.cancel()
						await MainActor.run {
							OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: true)
						}
						return container
					} catch {
						pollTask.cancel()
						await MainActor.run {
							OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: false)
						}
						throw error
					}
				}
			}
		}

		// MARK: - Path Type

		struct Path: ExpressibleByStringLiteral {
			let rawValue: String
			init(_ value: String) {
				rawValue = value
			}

			init(stringLiteral value: String) {
				rawValue = value
			}
		}

		// MARK: - MTP Drafter

		func loadMTPDrafter(modelId: String) async throws -> MLXLMCommon.MTPDrafterContainer {
			logger.info("Loading MTP drafter: \(modelId)")
			// ModelScope path
			if defaultHub != "huggingface" && !modelId.hasPrefix("hf:") {
				let msDownloader = ModelScopeDownloader(token: modelScopeToken)
				let drafter = try await MLXLMCommon.MTPDrafterModelFactory.shared.load(
					from: msDownloader as any Downloader,
					using: NoOpTokenizerLoader(),
					configuration: MLXLMCommon.ModelConfiguration(id: modelId)
				)
				return MLXLMCommon.MTPDrafterContainer(context: drafter)
			} else {
				let drafter = try await MLXLMCommon.MTPDrafterModelFactory.shared.load(
					from: #hubDownloader(),
					using: NoOpTokenizerLoader(),
					configuration: MLXLMCommon.ModelConfiguration(id: modelId)
				)
				return MLXLMCommon.MTPDrafterContainer(context: drafter)
			}
		}

	// MARK: - Teardown

		func teardown() {
			logger.info("MLXModelLoader teardown requested")
		}

		// MARK: - Helpers

		private func logElapsed(_ msg: String, _ start: ContinuousClock.Instant) {
			let elapsed = start.duration(to: ContinuousClock.now)
			let ms = Double(elapsed.components.seconds) * 1000.0
				+ Double(elapsed.components.attoseconds) / 1e15
			logger.info("\(msg) in \(String(format: "%.0fms", ms))")
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
		if let config = kvCacheQuant, config.enabled {
			params.kvBits = config.bits
			params.kvGroupSize = config.groupSize
			params.quantizedKVStart = config.quantizedKVStart
			params.kvScheme = config.kvScheme
		}
		if let temp = sampling.temperature {
			params.temperature = Float(temp)
		}
		if let topP = sampling.topP, topP > 0 {
			params.topP = Float(topP)
		}
		if let topK = sampling.topK {
			params.topK = topK
		}
		if let minP = sampling.minP, minP > 0 {
			params.minP = Float(minP)
		}
		if let repPen = sampling.repetitionPenalty, repPen > 0 {
			params.repetitionPenalty = Float(repPen)
		}
		if let pPen = sampling.presencePenalty, pPen > 0 {
			params.presencePenalty = Float(pPen)
		}
		if let fPen = sampling.frequencyPenalty, fPen > 0 {
			params.frequencyPenalty = Float(fPen)
		}
		// Seed → reproducible sampling (upstream PR #377)
		if let s = sampling.seed {
			params.seed = UInt64(s)
		}
		// Prefill step size — controls prompt chunking for long inputs
		if let prefillStepSize = sampling.prefillStepSize {
			params.prefillStepSize = prefillStepSize
		}
		// Max KV cache size — enables RotatingKVCache when set
		if let maxKVSize = sampling.maxKVSize {
			params.maxKVSize = maxKVSize
		}
		// Context window sizes for repetition/presence/frequency penalties
		params.repetitionContextSize = sampling.repetitionContextSize
		params.presenceContextSize = sampling.presenceContextSize
		params.frequencyContextSize = sampling.frequencyContextSize
		return params
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

	// MARK: - EmbeddingService (P0-2: MLXEmbedders real integration)

	/// Lightweight bridge between MLXEmbedders and ocoreai's embedding pipeline.
	///
	/// - Loads `mlx-community/LFM2.5-Embedding-350M-4bit` (350M, 1024-dim, 4-bit quantized).
	///   Falls back to bf16 if quantization fails.
	/// - Produces dense [Float] vectors compatible with `MemoryConfig.vectorDim`.
	/// - Thread-safe: shares one `EmbedderModelContainer` via `actor` isolation.
	actor EmbeddingService {
		static let logger = Logger(label: "ocoreai.embedding")

		/// Lazy singleton — loads model on first `embed(_:)` call.
		private var container: EmbedderModelContainer?

		/// Current embedding dimension (1024 for LFM2.5 models).
		var embeddingDim: Int { 1024 }

		// MARK: - Public API

		/// Embed a single string → normalized dense vector as raw `Data`.
		/// Compatible with `SessionMessage.embedVector: Data?`.
		func embedText(_ text: String) async throws -> Data {
			try await embedTexts([text]).first ?? Data()
		}

		/// Batch-embed strings. Returns `[Data]` (one 1024-float32 vector per input).
		func embedTexts(_ texts: [String]) async throws -> [Data] {
			guard !texts.isEmpty else { return [] }

			let container = try await ensureContainer()

			// Perform embedding inside the container (non-isolated context)
			let vectors: [[Float]] = await container.perform { context in
				let tokenizer = context.tokenizer
				let model = context.model
				let pooling = context.pooling
				let eosId = tokenizer.eosTokenId ?? 0

				// Encode inputs
				let encoded = texts.map {
					tokenizer.encode(text: $0, addSpecialTokens: true)
				}

				// Pad to longest sequence
				let maxLength = encoded.reduce(into: 16) { acc, elem in
					acc = max(acc, elem.count)
				}

				let padded = stacked(
					encoded.map { elem in
						MLXArray(
							elem + Array(repeating: eosId, count: maxLength - elem.count)
						)
					}
				)
				let mask = padded .!= eosId
				let tokenTypes = MLXArray.zeros(like: padded)

				// Run model + pool + normalize
				let modelOutput = model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
				let result = pooling(modelOutput, normalize: true, applyLayerNorm: true)
				result.eval()

				return result.map { $0.asArray(Float.self) }
			}

			// Convert [Float] vectors to Data (float32 little-endian)
			return vectors.map { Data(bytes: $0, count: $0.count * MemoryLayout<Float>.size) }
		}

		/// Cosine similarity between two already-embedded vectors.
		static func cosineSimilarity(_ a: Data, _ b: Data) -> Float {
			guard a.count == b.count else { return 0 }
			let count = a.count / MemoryLayout<Float>.size
			var result: Float = 0
			withUnsafeBytes(of: a) { bufA in
				guard let ptrA = bufA.bindMemory(to: Float.self).baseAddress else { return }
				withUnsafeBytes(of: b) { bufB in
					guard let ptrB = bufB.bindMemory(to: Float.self).baseAddress else { return }
					for i in 0..<count {
						result += ptrA[i] * ptrB[i]
					}
				}
			}
			return result
		}

		// MARK: - Model loading

		private func ensureContainer() async throws -> EmbedderModelContainer {
			if let container { return container }

			// Try 4-bit quantized first (smaller, faster on Apple Silicon)
			let configs: [ModelConfiguration] = [
				EmbedderRegistry.lfm2_embedding_350m_4bit,  // 4-bit quantized
				EmbedderRegistry.lfm2_embedding_350m,       // bf16 fallback
			]

			for config in configs {
				do {
					let container = try await EmbedderModelFactory.shared.loadContainer(
						from: #hubDownloader(),
						using: #huggingFaceTokenizerLoader(),
						configuration: config
					)
					Self.logger.info(
						"Embedding model loaded: \(config.id)",
						metadata: ["embeddingDim": .string(String(embeddingDim))]
					)
					self.container = container
					return container
				} catch {
					Self.logger.warning(
						"Failed to load \(config.id), trying next: \(error.localizedDescription)"
					)
				}
			}

			throw EmbeddingError.modelLoadFailed(
				"All embedding model candidates failed to load"
			)
		}

		// MARK: - Errors

		enum EmbeddingError: Error, LocalizedError {
			case modelLoadFailed(String)

			var errorDescription: String? {
				switch self {
				case .modelLoadFailed(let msg): "Embedding unavailable: \(msg)"
				}
			}
		}
	}

