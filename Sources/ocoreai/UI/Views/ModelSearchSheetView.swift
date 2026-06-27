// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Model search sheet — reusable from ModelView and DashboardView.
/// Uses shared ModelRepositoryState for search/download (see ModelRepositoryState.swift).
/// Previous ModelSearchState class removed — its search/load/download logic
/// was duplicated across three views and has been consolidated.

import Observation
import SwiftUI

struct ModelSearchSheetView: View {
	@State private var repositoryState: ModelRepositoryState
	// Local binding for TextField — avoids macOS Form + @Observable dynamic member focus leak
	@State private var searchQueryLocal = ""
	// Download progress — global store, auto-updates from MLXBridge
	@State private var downloadProgress = OcoreaiDownloadProgress.shared
	@Environment(\.dismiss) private var dismiss
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		onChange(of: searchQueryLocal) { _, newValue in
			repositoryState.searchQuery = newValue
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
				if !repositoryState.hfResults.isEmpty, repositoryState.selectedSource == .huggingFace {
					hfResultsSection
				}
				if !repositoryState.msResults.isEmpty, repositoryState.selectedSource == .modelScope {
					msResultsSection
				}

				// ⑤ Currently loading
				if repositoryState.isDownloading {
					Section(StringKey.modelSearchLoading.l) {
						HStack {
							ProgressView()
							VStack(alignment: .leading) {
								Text(repositoryState.downloadingModelId)
									.font(.ocoreaiText(13, weight: .medium))
									.lineLimit(1)
								Text(StringKey.modelSearchLoading.l)
									.font(.ocoreaiText(11))
									.foregroundStyle(theme.textSecondary)
							}
							Spacer()
						}
						.padding(.vertical, 4)
					}
				}

				// ⑥ Error — unified OcoreaiErrorBanner
				if let error = repositoryState.currentError {
					OcoreaiErrorBanner(error: error) { repositoryState.currentError = nil }
				}
			}
			.navigationTitle(StringKey.tabModels.l)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(StringKey.modelSearchDismiss.l) {
						dismiss()
					}
					.disabled(repositoryState.isDownloading)
				}
			}
			.task {
				await repositoryState.refreshLocalModels()
			}
		}
	}

	// MARK: - Local Models Section

	@ViewBuilder
	private var localModelsSection: some View {
		if repositoryState.localModels.isEmpty {
			Section {
				HStack {
					Image(systemName: "cpu")
						.font(.title2)
						.foregroundStyle(theme.accent)
					Text(StringKey.noModelsLoaded.l)
						.foregroundStyle(theme.textSecondary)
				}
				.frame(maxWidth: .infinity)
			}
		} else {
			Section(header: Text(StringKey.sectionModels.l)) {
				ForEach(repositoryState.localModels, id: \.id) { model in
					HStack {
						Text(model.id)
							.lineLimit(1)
						Spacer()
						if repositoryState.selectedSource == .huggingFace {
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
			Picker(StringKey.modelSearchSelectHub.l, selection: $repositoryState.selectedSource) {
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
				repositoryState.selectedSource == .huggingFace
					? StringKey.modelSearchHFHub.l
					: StringKey.modelSearchModelScope.l,
				text: $searchQueryLocal,
			)
			.textFieldStyle(.plain)
			.onSubmit {
				repositoryState.searchQuery = searchQueryLocal
				Task { await repositoryState.search(searchQueryLocal) }
			}
			.disableAutocorrection(true)

			if repositoryState.isSearching {
				HStack {
					ProgressView()
					Text(StringKey.modelSearchSearching.l)
						.foregroundStyle(theme.textSecondary)
					Spacer()
				}
				.padding(.vertical, 4)
			}
		}
	}

	// MARK: - HF Results

	private var hfResultsSection: some View {
		Section(header: Text(StringKey.modelSearchResults.l)) {
			ForEach(repositoryState.hfResults.prefix(15), id: \.id) { model in
				resultRow(id: model.id, label: model.id, sub: model.pipelineTag)
			}
		}
	}

	// MARK: - MS Results

	private var msResultsSection: some View {
		Section(header: Text(StringKey.modelSearchResults.l)) {
			ForEach(repositoryState.msResults.prefix(15), id: \.id) { model in
				resultRow(id: model.path, label: model.path, sub: model.tasks.first)
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
						.foregroundStyle(theme.textSecondary)
				}
			}
			Spacer()
			downloadButton(for: id)
		}
	}

	// MARK: - Download Button

	@ViewBuilder
	private func downloadButton(for modelId: String) -> some View {
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
					.foregroundStyle(state.fraction >= 1 ? .green : theme.textSecondary)
					.monospacedDigit()
			}
			.animation(.smooth, value: state.fraction)
		} else {
			Button(StringKey.modelSearchLoad.l) {
				Task {
					let ok = await repositoryState.load(modelId)
					if ok {
						await repositoryState.refreshLocalModels()
						dismiss()
					}
				}
			}
			.disabled(repositoryState.isDownloading)
		}
	}
}
