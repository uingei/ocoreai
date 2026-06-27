// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelRepositoryState — shared search + download + model list for all model-related views.
///
/// Replaces the three separate implementations in:
///   1. ChatView.ModelSearchView (inline @State)
///   2. ModelSearchSheetView / ModelSearchState
///   3. ModelView (inline @State)
///
/// Single source of truth for:
///   - Hub search (HuggingFace / ModelScope) via dedicated SearchClient
///   - Model load/download via EnginePool
///   - Download progress via OcoreaiDownloadProgress
///   - Local model list
///   - Error state (typed, not String?)
///
/// @Observable pattern. @MainActor pinned for UI thread safety.

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

// MARK: - ModelRepositoryState

@Observable
@MainActor
final class ModelRepositoryState {
	// MARK: - Search state

	var searchQuery: String = ""
	var selectedSource: HubSource = .huggingFace
	var isSearching: Bool = false

	var hfResults: [HFHubModel] = []
	var msResults: [MSHubModel] = []

	// MARK: - Download state

	var downloadingModelId: String = ""
	var isDownloading: Bool = false

	// MARK: - Local models

	var localModels: [ModelID] = []

	// MARK: - Error state (typed, single)

	var currentError: RepositoryError?

	// MARK: - Private

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
	/// Updates local model list afterwards.
	///
	/// Optimized flow:
	/// 1. Check local cache first via MLXModelLoader.isModelCached() (when mlx trait)
	/// 2. If cached → load directly, skip progress UI
	/// 3. If not cached → show progress UI then download via EnginePool
	///
	/// - Note: Progress is tracked under the ORIGINAL modelId (without prefix) so that
	///   UI components can query progress using the same identifier they got from search results.
	func load(_ modelId: String) async -> Bool {
		guard let pool = _enginePool else {
			currentError = .engineUnavailable
			return false
		}

		// Normalize: ModelScope needs "mscope:" prefix for EnginePool
		let normalizedId: String = if selectedSource == .modelScope, !modelId.hasPrefix("mscope:") {
			"mscope:\(modelId)"
		} else {
			modelId
		}

		// Strip prefix for progress key alignment — UI queries by the same key
		let progressKey = modelId

		// Fast-check: if model is already cached, load directly without progress UI
		#if mlx
		if pool.isHubModel(normalizedId) {
			// Determine provider from prefix
			let provider: MLXModelLoader.HubProvider
			let repoId: String
			if normalizedId.hasPrefix("mscope:") {
				provider = .modelScope
				repoId = String(normalizedId.dropFirst(7))
			} else {
				provider = .huggingFace
				repoId = normalizedId.hasPrefix("hf:") ? String(normalizedId.dropFirst(3)) : normalizedId
			}

			// Check if already cached
			if MLXModelLoader.isModelCached(provider, repoId: repoId) {
				// Model cached — load directly, no progress UI needed
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
		#endif

		// Model not cached or non-hub model — use full download path with progress UI
		isDownloading = true
		downloadingModelId = progressKey
		currentError = nil
		OcoreaiDownloadProgress.shared.start(modelId: progressKey)

		do {
			_ = try await pool.acquire(model: normalizedId)
			await pool.releaseSession(modelId: normalizedId, sessionId: "init")

			// Signal success
			OcoreaiDownloadProgress.shared.finish(modelId: progressKey, success: true)

			// Refresh local model list
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

	/// Refresh the list of currently loaded models from EnginePool.
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
}
