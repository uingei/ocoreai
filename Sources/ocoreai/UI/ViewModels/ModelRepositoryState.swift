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
	func load(_ modelId: String) async -> Bool {
		guard let pool = _enginePool else {
			currentError = .engineUnavailable
			return false
		}

		// Normalize: ModelScope needs "mscope:" prefix
		let normalizedId: String = if selectedSource == .modelScope, !modelId.hasPrefix("mscope:") {
			"mscope:\(modelId)"
		} else {
			modelId
		}

		isDownloading = true
		downloadingModelId = normalizedId
		currentError = nil

		// Start tracking in global progress store
		OcoreaiDownloadProgress.shared.start(modelId: normalizedId)

		do {
			_ = try await pool.acquire(model: normalizedId)
			await pool.releaseSession(modelId: normalizedId, sessionId: "init")

			// Signal success in progress store
			OcoreaiDownloadProgress.shared.finish(modelId: normalizedId, success: true)

			// Refresh local model list
			await refreshLocalModels()

			isDownloading = false
			downloadingModelId = ""
			return true
		} catch {
			OcoreaiDownloadProgress.shared.finish(modelId: normalizedId, success: false)
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
