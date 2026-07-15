// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// ModelManager.swift — Single source of truth for all model management.
//
// Replaces ModelRepositoryState + ModelsState with one @Observable class.
//
// Responsibilities:
//   1. Hub search (HF / ModelScope) — via dedicated SearchClients
//   2. Model load/download via EnginePool — unified progress tracking
//   3. Local model list — single [ModelID] array, always fresh
//   4. Error state — typed RepositoryError
//
// Uses ModelIdentity for prefix-free model identifiers.

import Foundation
import Observation

// MARK: - Unified Error Type

enum RepositoryError: LocalizedError {
	case engineUnavailable
	case searchFailed(String)
	case loadFailed(String)
	case deleteFailed(String)
	case noResults

	var errorDescription: String? {
		switch self {
		case .engineUnavailable:
			return StringKey.engineNotAvailable.l
		case .searchFailed(let msg):
			return "\(StringKey.modelSearchNoResults.l): \(msg)"
		case .loadFailed(let msg):
			return "\(StringKey.modelLoadError.l): \(msg)"
		case .deleteFailed(let msg):
			return "\(StringKey.modelDeleteError.l): \(msg)"
		case .noResults:
			return StringKey.modelSearchNoResults.l
		}
	}
}

// MARK: - Unified Model Manager

@Observable
@MainActor
final class ModelManager {
	// MARK: - Shared instance

	/// Singleton shared across all views — ensures model list, progress
	/// and download state are consistent no matter which tab is active.
	static let shared = ModelManager()

	private init() {}

	// MARK: - Search state

	var searchQuery: String = ""
	var selectedSource: HubSource = .huggingFace
	var isSearching: Bool = false

	var hfResults: [HFHubModel] = []
	var msResults: [MSHubModel] = []

	// MARK: - Download state

	var isDownloading: Bool = false
	var downloadingModelId: String = ""

	// MARK: - Local models (single source of truth)

	var localModels: [ModelID] = []

	/// Models currently serving inference requests (activeSessions > 0).
	/// Updated alongside localModels during refresh.
	var servingModelIds: Set<String> = []

	// MARK: - Error state (typed)

	var currentError: RepositoryError?

	// MARK: - EnginePool accessor

	private var _enginePool: EnginePool? {
		OcoreaiEngine.shared.activeEnginePool
	}

	// MARK: - Search

	/// Search the selected Hub source and populate the corresponding results array.
	func search(_ query: String) async {
		guard !query.isEmpty else {
			hfResults = []
			msResults = []
			return
		}

		isSearching = true
		currentError = nil

		switch selectedSource {
		case .huggingFace:
			let results = await _searchHF(query)
			hfResults = results
			if results.isEmpty {
				currentError = .noResults
			}
		case .modelScope:
			let results = await _searchMS(query)
			msResults = results
			if results.isEmpty {
				currentError = .noResults
			}
		}

		isSearching = false
	}

	private func _searchHF(_ query: String) async -> [HFHubModel] {
		let client = HuggingFaceSearchClient()
		do {
			return try await client.search(query: query, limit: 15)
		} catch {
			currentError = .searchFailed(error.localizedDescription)
			return []
		}
	}

	private func _searchMS(_ query: String) async -> [MSHubModel] {
		// Inject MODELSCOPE_TOKEN so search hits (including gated repos) work correctly
		// Priority: env var > UserDefaults (persisted from Settings UI)
		let msToken = SettingsStore.shared.modelScopeToken
		let client = ModelScopeSearchClient(token: msToken)
		do {
			let result = try await client.search(keyword: query, pageSize: 15)
			return result.models
		} catch {
			currentError = .searchFailed(error.localizedDescription)
			return []
		}
	}

	// MARK: - Load / Download

	/// Acquire a model from the EnginePool (triggers download if needed), then release.
	/// Refreshes the local model list afterwards.
	///
	/// Uses `selectedSource` to determine the Hub source — prevents ModelScope results
	/// from being routed to HuggingFace due to bare "org/repo" string ambiguity.
	@discardableResult
	func load(_ modelId: String) async -> Bool {
		await load(modelId, hub: selectedSource)
	}

	/// Acquire a model from the EnginePool with an explicit Hub source override.
	/// - Parameters:
	///   - modelId: The raw model ID (with or without prefix)
	///   - hub: Override Hub source. When nil, ModelIdentity.parse uses its own heuristic.
	@discardableResult
	private func load(_ modelId: String, hub: HubSource?) async -> Bool {
		guard let pool = _enginePool else {
			currentError = .engineUnavailable
			return false
		}

		// Resolve identity with hub override
		let identity: ModelIdentity
		if let hub {
			identity = ModelIdentity.parse(modelId, hub: hub)
		} else {
			identity = ModelIdentity.parse(modelId)
		}
		let normalizedId = identity.prefixedId

		// Progress key = repoId (no prefix) — aligns UI with MLXBridge callbacks
		let progressKey = identity.repoId

		// Fast-check: if model is already cached, load directly without progress UI
		if pool.isHubModel(normalizedId) {
			if case .local = identity.source {
				// Local path — skip cache check, go to download path below
			} else {
				let provider: MLXModelLoader.HubProvider
				let repoId: String
				switch identity.source {
				case .modelScope(let r):
					provider = .modelScope
					repoId = r
				case .huggingFace(let r):
					provider = .huggingFace
					repoId = r
				case .local:
					// Unreachable — handled by outer guard
					assertionFailure("unreachable — handled by outer guard")
					return false
				}

				// Check if already cached
				if MLXModelLoader.isModelCached(provider, repoId: repoId) {
					currentError = nil
					do {
						let handle = try await pool.acquire(model: normalizedId)
						// Use handle.release() — uses the real UUID sessionId from acquire(),
						// ensuring pagedKVCache evicts the correct session entry.
						// Fixes P0-2: pagedKVCache sessionId leak (UUID never evicted when sessionId="init")
						await handle.release()
						await refreshLocalModels()
						return true
					} catch {
						currentError = .loadFailed(error.localizedDescription)
						return false
					}
				}
			}
		}

		// Model not cached or non-hub model — use full download path with progress UI
		return await _downloadAndLoad(normalizedId: normalizedId, progressKey: progressKey, pool: pool)
	}

	private func _downloadAndLoad(
		normalizedId: String,
		progressKey: String,
		pool: EnginePool
	) async -> Bool {
		isDownloading = true
		downloadingModelId = progressKey
		currentError = nil
		OcoreaiDownloadProgress.shared.start(modelId: progressKey)

		do {
			let handle = try await pool.acquire(model: normalizedId)
			// Use handle.release() — real UUID sessionId from acquire()
			// (same fix as P0-2 above)
			await handle.release()

			OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: true)

			await refreshLocalModels()

			isDownloading = false
			downloadingModelId = ""
			return true
		} catch {
			OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: false)
			currentError = .loadFailed(error.localizedDescription)
			isDownloading = false
			downloadingModelId = ""
			return false
		}
	}

	// MARK: - Local models

	/// Refresh the list of currently loaded models from EnginePool,
	/// applying persisted sampling configs.
	func refreshLocalModels() async {
		guard let pool = _enginePool else { return }

		let entries = await pool.listModels()
		let store = SettingsStore.shared

		var models: [ModelID] = []
		var serving: Set<String> = []
		var configBatch: [String: ModelSamplingConfig] = [:]

		for entry in entries {
			let model = ModelID.fromListModels(entry)
			let config = store.loadSamplingConfig(for: model.id)
			configBatch[model.id] = config
			var info = model
			info.paramsCustomized = !config.isDefault
			models.append(info)
			// Track active inference sessions
			if let activeStr = entry["active_sessions"],
			   let active = Int(activeStr), active > 0 {
				serving.insert(model.id)
			}
		}

		// Batch-apply all configs in a single actor mailbox round-trip
		if !configBatch.isEmpty {
			await pool.updateSamplingConfigs(configBatch)
		}

		localModels = models
		servingModelIds = serving
	}

	/// Load models on view appearance — thin wrapper for .task{} usage.
	func loadModels() async {
		await refreshLocalModels()
	}

	/// Get model IDs as plain strings — for ChatView toolbar picker.
	func modelIdStrings() -> [String] {
		localModels.map { $0.id }
	}

	// MARK: - Convenience

	/// Unload a model from memory without removing cached files.
	@discardableResult
	func unload(_ modelId: String) async -> Bool {
		guard let pool = _enginePool else {
			currentError = .engineUnavailable
			return false
		}
		let ok = await pool.unloadModel(modelId)
		if ok {
			await SettingsStore.shared.resetSamplingConfig(for: modelId)
			await refreshLocalModels()
		}
		return ok
	}

	/// Delete a model: unload from memory, remove cached files from disk, clear settings.
	/// Returns true if the model was successfully removed.
	@discardableResult
	func deleteModel(_ modelId: String) async -> Bool {
		guard let pool = _enginePool else {
			currentError = .engineUnavailable
			return false
		}

		// 1. Unload from memory (best-effort — continue even if not loaded)
		_ = await pool.unloadModel(modelId)

		// 2. Remove cached files from disk
		let identity = ModelIdentity.parse(modelId)
		do {
			try await deleteCachedFiles(for: identity)
		} catch {
			currentError = .deleteFailed(error.localizedDescription)
			return false
		}

		// 3. Clear persisted sampling config
		await SettingsStore.shared.resetSamplingConfig(for: modelId)

		// 4. Clear download progress state
		OcoreaiDownloadProgress.shared.finish(modelId: identity.repoId, success: false)

		currentError = nil
		await refreshLocalModels()
		return true
	}

	private func deleteCachedFiles(for identity: ModelIdentity) async throws {
		let fileManager = FileManager.default
		guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
			throw RepositoryError.deleteFailed("Cannot locate cache directory")
		}

		switch identity.source {
		case .modelScope(let repoId):
				let dir = cachesDir
					.appendingPathComponent("ocoreai/modelscope")
					.appendingPathComponent(repoId)
				if fileManager.fileExists(atPath: dir.path) {
					try fileManager.removeItem(at: dir)
				}
		case .huggingFace(let repoId):
			let dir = cachesDir
				.appendingPathComponent("org.ml-explore.mlx-swift-lm")
				.appendingPathComponent(repoId)
			if fileManager.fileExists(atPath: dir.path) {
				try fileManager.removeItem(at: dir)
			}
		case .local:
			// Local models are not managed in cache — nothing to delete
			break
		}
	}

	// MARK: - Convenience

	/// Clear search results and reset state for a fresh start.
	func clearSearch() {
		searchQuery = ""
		hfResults = []
		msResults = []
		currentError = nil
	}

	/// Switch hub source and clear stale results from the other source.
	func switchSource(to source: HubSource) {
		selectedSource = source
		if source == .huggingFace {
			msResults = []
		} else {
			hfResults = []
		}
	}

	/// Check if a specific model is currently downloading.
	func isDownloading(_ modelId: String) -> Bool {
		isDownloading && downloadingModelId == modelId
	}

	/// Get download progress for a model (bridge to OcoreaiDownloadProgress).
	func downloadProgress(for modelId: String) -> OcoreaiDownloadProgressState? {
		OcoreaiDownloadProgress.shared.progress(for: modelId)
	}
}
