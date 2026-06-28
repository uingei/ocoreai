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
	case noResults

	var errorDescription: String? {
		switch self {
		case .engineUnavailable:
			return StringKey.engineNotAvailable.l
		case .searchFailed(let msg):
			return "\(StringKey.modelSearchNoResults.l): \(msg)"
		case .loadFailed(let msg):
			return "\(StringKey.modelLoadError.l): \(msg)"
		case .noResults:
			return StringKey.modelSearchNoResults.l
		}
	}
}

// MARK: - Unified Model Manager

@Observable
@MainActor
final class ModelManager {
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
		let client = ModelScopeSearchClient()
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
	/// Optimized flow:
	/// 1. Check local cache first via MLXModelLoader.isModelCached() (when mlx trait)
	/// 2. If cached → load directly, skip progress UI
	/// 3. If not cached → show progress UI then download via EnginePool
	@discardableResult
	func load(_ modelId: String) async -> Bool {
		guard let pool = _enginePool else {
			currentError = .engineUnavailable
			return false
		}

		// Resolve identity — normalizes prefix handling to one place
		let identity = ModelIdentity.parse(modelId)
		let normalizedId = identity.prefixedId

		// Progress key = repoId (no prefix) — aligns UI with MLXBridge callbacks
		let progressKey = identity.repoId

		// Fast-check: if model is already cached, load directly without progress UI
		#if mlx
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
					fatalError("unreachable — handled by outer guard")
				}

				// Check if already cached
				if MLXModelLoader.isModelCached(provider, repoId: repoId) {
					currentError = nil
					do {
						_ = try await pool.acquire(model: normalizedId)
						await pool.releaseSession(modelId: normalizedId, sessionId: "init")
						await refreshLocalModels()
						return true
					} catch {
						currentError = .loadFailed(error.localizedDescription)
						return false
					}
				}
			}
		}
		#endif

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
			_ = try await pool.acquire(model: normalizedId)
			await pool.releaseSession(modelId: normalizedId, sessionId: "init")

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
		for entry in entries {
			let model = ModelID.fromListModels(entry)
			let config = store.loadSamplingConfig(for: model.id)
			await pool.updateSamplingConfig(modelId: model.id, config: config)
			var info = model
			info.paramsCustomized = !config.isDefault
			models.append(info)
		}
		localModels = models
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
