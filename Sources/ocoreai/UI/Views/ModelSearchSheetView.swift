// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Standalone model search sheet — reusable from ModelView and ChatView.
/// Directly interacts with OcoreaiEngine, no ChatState dependency.
/// Features: HuggingFace / ModelScope hub search, direct model ID loading, progress indicator.

import Observation
import SwiftUI

// MARK: - ViewModel

@Observable
@MainActor
final class ModelSearchState {
	// Local models
	var localModels: [ModelID] = []
	var defaultModelId: String = ""

	// Hub search
	var searchQuery = ""
	var hfResults: [HFHubModel] = []
	var msResults: [MSHubModel] = []
	var isSearching = false
	var selectedSource: HubSource = .huggingFace

	// Download
	var downloadingModelId: String = ""
	var isDownloading = false

	// Error
	var errorMessage: String?

	func performSearch(_ query: String) async {
		guard !query.isEmpty else { hfResults = []; msResults = []; return }
		isSearching = true
		errorMessage = nil

		switch selectedSource {
		case .huggingFace:
			let results = await searchHub(keyword: query)
			hfResults = results
		case .modelScope:
			let results = await searchModelScope(keyword: query)
			msResults = results
		}
		isSearching = false
	}

	func loadModel(_ modelId: String, onSuccess: (() -> Void)?) {
		guard let pool = OcoreaiEngine.shared.activeEnginePool else {
			errorMessage = StringKey.engineNotAvailable.l
			return
		}

		let normalizedId: String = if selectedSource == .modelScope, !modelId.hasPrefix("mscope:") {
			"mscope:\(modelId)"
		} else {
			modelId
		}

		isDownloading = true
		downloadingModelId = modelId

		Task {
			do {
				_ = try await pool.acquire(model: normalizedId)
				await pool.releaseSession(modelId: normalizedId, sessionId: "init")
				await self.refreshLocalModels()
				self.isDownloading = false
				self.downloadingModelId = ""
				onSuccess?()
			} catch {
				self.errorMessage = error.localizedDescription
				self.isDownloading = false
				self.downloadingModelId = ""
			}
		}
	}

	func refreshLocalModels() async {
		guard let pool = OcoreaiEngine.shared.activeEnginePool else { return }
		localModels = await pool.loadedModels.map {
			ModelID(id: $0.key, maxContext: $0.value.modelConfig.maxContextLength, tokenizer: $0.value.modelConfig.tokenizer)
		}
		defaultModelId = UserDefaults.standard.string(forKey: "DefaultModelId") ?? ""
	}

	private func setDefault(_ modelId: String) {
		defaultModelId = modelId
		UserDefaults.standard.set(modelId, forKey: "DefaultModelId")
	}

	// MARK: - Hub Search (delegated to HuggingFaceSearchClient / ModelScopeSearchClient)

	private func searchHub(keyword: String, limit: Int = 15) async -> [HFHubModel] {
		do {
			let client = HuggingFaceSearchClient()
			return try await client.search(query: keyword, limit: limit)
		} catch {
			return []
		}
	}

	private func searchModelScope(keyword: String, pageSize: Int = 15) async -> [MSHubModel] {
		do {
			let client = ModelScopeSearchClient()
			let result = try await client.search(keyword: keyword, pageSize: min(pageSize, 100))
			return result.models
		} catch {
			return []
		}
	}
}

// MARK: - View

struct ModelSearchSheetView: View {
	@State private var searchState = ModelSearchState()
	// Local binding for TextField — avoids macOS Form + @Observable dynamic member focus leak
	@State private var searchQueryLocal = ""
	// Download progress — global store, auto-updates from MLXBridge
	@State private var downloadProgress = OcoreaiDownloadProgress.shared
	@Environment(\.dismiss) private var dismiss
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		onChange(of: searchQueryLocal) { _, newValue in
			searchState.searchQuery = newValue
		}
		NavigationStack {
			Form {
				// ① Local models section
				localModelsSection

				// ② Hub source toggle
				hubToggleSection

				// ③ Search
				searchSection

				// ④ Results
				if !searchState.hfResults.isEmpty, searchState.selectedSource == .huggingFace {
					hfResultsSection
				}
				if !searchState.msResults.isEmpty, searchState.selectedSource == .modelScope {
					msResultsSection
				}

				// Error
				if let error = searchState.errorMessage {
					errorSection(error)
				}
			}
			.navigationTitle(StringKey.tabModels.l)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(StringKey.modelSearchDismiss.l) {
						dismiss()
					}
					.disabled(searchState.isDownloading)
				}
			}
			.task {
				_ = await searchState.refreshLocalModels()
			}
		}
	}

	// MARK: - Local Models Section

	@ViewBuilder
	private var localModelsSection: some View {
		if searchState.localModels.isEmpty {
			Section {
				HStack {
					Image(systemName: "cpu")
						.font(.title2)
						.foregroundStyle(theme.accent)
					Text(StringKey.noModelsLoaded.l)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity)
			}
		} else {
			Section(header: Text(StringKey.sectionModels.l)) {
				ForEach(searchState.localModels, id: \.id) { model in
					HStack {
						Text(model.id)
							.lineLimit(1)
						Spacer()
						if searchState.defaultModelId == model.id {
							Image(systemName: "checkmark.circle.fill")
								.foregroundStyle(.green)
								.imageScale(.medium)
						}
					}
				}
			}
			.headerProminence(.increased)
		}
	}

	// MARK: - Hub Toggle

	private var hubToggleSection: some View {
		Section(header: Text(StringKey.modelSearchHubSource.l)) {
			Picker(StringKey.modelSearchSelectHub.l, selection: $searchState.selectedSource) {
				ForEach(HubSource.allCases, id: \.self) { source in
					Text(source.rawValue).tag(source)
				}
			}
			.pickerStyle(.segmented)
		}
	}

	// MARK: - Search Section

	private var searchSection: some View {
		Section {
			TextField(
				searchState.selectedSource == .huggingFace
					? StringKey.modelSearchHFHub.l
					: StringKey.modelSearchModelScope.l,
				text: $searchQueryLocal,
			)
			.textFieldStyle(.plain)
			.onSubmit {
				searchState.searchQuery = searchQueryLocal
				Task { await searchState.performSearch(searchQueryLocal) }
			}
			.disableAutocorrection(true)

			if searchState.isSearching {
				HStack {
					ProgressView()
					Text(StringKey.modelSearchSearching.l)
						.foregroundStyle(.secondary)
					Spacer()
				}
				.padding(.vertical, 4)
			}
		}
	}

	// MARK: - HF Results

	private var hfResultsSection: some View {
		Section(header: Text(StringKey.modelSearchResults.l)) {
			ForEach(searchState.hfResults.prefix(15), id: \.id) { model in
				resultRow(id: model.id, label: model.id, sub: model.pipelineTag)
			}
		}
	}

	// MARK: - MS Results

	private var msResultsSection: some View {
		Section(header: Text(StringKey.modelSearchResults.l)) {
			ForEach(searchState.msResults.prefix(15), id: \.id) { model in
				resultRow(id: model.path, label: model.path, sub: "\(model.stars)")
			}
		}
	}

	// MARK: - Result Row

	private func resultRow(id: String, label: String, sub: String?) -> some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(label)
					.fontWeight(.medium)
					.lineLimit(1)
				if let sub {
					Text(sub)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			downloadButton(for: id, action: {
				searchState.loadModel(id, onSuccess: { dismiss() })
			})
		}
	}

	// MARK: - Download Button

	@ViewBuilder
	private func downloadButton(for modelId: String, action: @escaping () -> Void) -> some View {
		// Use global progress store for real-time progress
		let progressState = downloadProgress.progress(for: modelId)
		let isDown = downloadProgress.isDownloading(modelId)

		if isDown, let state = progressState {
			// Show real progress bar with percentage
			HStack(spacing: 6) {
				ProgressView(value: state.fraction)
					.progressViewStyle(.linear)
					.frame(width: 80)
				Text(Int(state.fraction * 100) == 100 ? "✓" : "\(Int(state.fraction * 100))%")
					.font(.caption)
					.foregroundStyle(state.fraction >= 1 ? .green : .secondary)
					.monospacedDigit()
			}
			.animation(.smooth, value: state.fraction)
		} else {
			Button(StringKey.modelSearchLoad.l, action: action)
				.disabled(searchState.isDownloading)
		}
	}

	// MARK: - Error Section

	private func errorSection(_ error: String) -> some View {
		Section {
			HStack {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.red)
				Text(error)
					.foregroundStyle(.secondary)
					.font(.subheadline)
			}
		}
	}
}
