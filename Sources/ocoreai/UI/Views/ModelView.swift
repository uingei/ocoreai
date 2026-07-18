// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelView — model management: load, switch, quantize with inline search
/// Fast Path: reads directly from EnginePool (no HTTP)
/// @Observable pattern. i18n via StringKey. Accessibility: full VoiceOver.
/// Search/download + local model list delegated to shared ModelManager (see ModelManager.swift).
///
/// FIX: Extracted nested @ViewBuilder properties into separate View structs to
/// prevent ConditionalTypeDescriptor recursion overflow (52k+ _makeViewList frames).
/// Each dedicated View resets the conditional metadata chain.

import SwiftUI

struct ModelView: View {
	// Unified model manager — search/download + local models + sampling config merge
	@State private var modelManager: ModelManager
	@State private var editingModelId: String = ""

	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_modelManager = State(initialValue: ModelManager.shared)
	}

	var body: some View {
		// macOS: TextField keyboard input requires Form for proper responder chain
		Form {
			Section(StringKey.tabModels.l) {
				searchBoxCard

				// Search results — delegated to dedicated View to break ConditionalTypeDescriptor chain
				ModelSearchResultsView(modelManager: modelManager)

				// Error — unified OcoreaiErrorBanner
				if let error = modelManager.currentError {
					OcoreaiErrorBanner(error: error) { modelManager.currentError = nil }
				}

				// B4 fix: inline params instead of .sheet — user preference: inline embedding
				if !editingModelId.isEmpty {
					ModelParamsView(modelId: editingModelId)
						.transition(.opacity.combined(with: .slide))
				}

				// Local models — delegated to dedicated View to break ConditionalTypeDescriptor chain
				ModelLocalListView(modelManager: modelManager, onEdit: { modelId in
					editingModelId = modelId
				})
			}
		}
		.formStyle(.grouped)
		.background(theme.windowBg)
		.task {
			await modelManager.loadModels()
		}
		.animation(reduceMotion ? nil : .smooth, value: editingModelId)
		.accessibilityLabel(StringKey.tabModels.l)
	}

	@ViewBuilder
	private var searchBoxCard: some View {
		Picker(StringKey.modelSearchSelectHub.l, selection: $modelManager.selectedSource) {
			ForEach(HubSource.allCases, id: \.self) { s in
				Text(s.rawValue).tag(s)
			}
		}
		.pickerStyle(.segmented).frame(maxWidth: .infinity)

		TextField(
			modelManager.selectedSource == .huggingFace
				? StringKey.modelSearchHFHub.l
				: StringKey.modelSearchModelScope.l,
			text: Binding<String>(
				get: { modelManager.searchQuery },
				set: { modelManager.searchQuery = $0 },
			),
		)
		.disableAutocorrection(true)
		.onSubmit {
			Task { await modelManager.search(modelManager.searchQuery) }
		}

		// macOS Form intercepts .onSubmit for row navigation — use a button as the primary trigger
		Button(action: { Task { await modelManager.search(modelManager.searchQuery) } }) {
			Image(systemName: "magnifyingglass").font(.ocoreaiText(12))
		}
		.buttonStyle(.borderedProminent)
		.controlSize(.small)
		.frame(width: 80)
		.accessibilityLabel(StringKey.modelSearchSearching.l)

		if modelManager.isSearching {
			HStack {
				ProgressView()
				Text(StringKey.modelSearchSearching.l).foregroundStyle(theme.textSecondary)
				Spacer()
			}
		}
	}
}

// MARK: - Search Results (dedicated View to prevent ConditionalTypeDescriptor recursion)

private struct ModelSearchResultsView: View {
	let modelManager: ModelManager
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		let hasResults = !modelManager.hfResults.isEmpty || !modelManager.msResults.isEmpty
		let hasQuery = !modelManager.searchQuery.isEmpty

		if hasQuery || hasResults {
			if modelManager.isSearching {
				searchingPlaceholder
			} else if modelManager.selectedSource == .huggingFace, !modelManager.hfResults.isEmpty {
				HFResultsList(modelManager: modelManager, theme: theme)
			} else if modelManager.selectedSource == .modelScope, !modelManager.msResults.isEmpty {
				MSResultsList(modelManager: modelManager, theme: theme)
			} else if hasResults {
				FallbackResultsView(modelManager: modelManager, theme: theme)
			} else {
				emptySearchState
			}
		}
	}

	private var searchingPlaceholder: some View {
		VStack(spacing: 12) {
			ProgressView().scaleEffect(1.2)
			Text(StringKey.modelSearchSearching.l).foregroundStyle(theme.textSecondary)
		}
		.frame(maxWidth: .infinity).padding(.vertical, 20)
	}

	private var emptySearchState: some View {
		VStack(spacing: 10) {
			Image(systemName: "magnifyingglass").font(.ocoreaiText(28, weight: .light)).foregroundStyle(theme.textTertiary)
			Text(StringKey.modelSearchEmpty.l).font(.ocoreaiText(13)).foregroundStyle(theme.textSecondary)
		}
		.frame(maxWidth: .infinity).padding(.vertical, 24)
	}
}

// MARK: - HF Results

private struct HFResultsList: View {
	let modelManager: ModelManager
	let theme: OcoreaiTheme

	var body: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(modelManager.hfResults.prefix(20).enumerated()), id: \.offset) { _, model in
				ModelResultRow(display: model.id, sub: model.pipelineTag ?? "", modelId: model.id, modelManager: modelManager, theme: theme)
			}
		}
	}
}

// MARK: - MS Results

private struct MSResultsList: View {
	let modelManager: ModelManager
	let theme: OcoreaiTheme

	var body: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(modelManager.msResults.prefix(20).enumerated()), id: \.offset) { _, model in
				ModelResultRow(display: model.path, sub: String(model.stars), modelId: model.path, modelManager: modelManager, theme: theme)
			}
		}
	}
}

// MARK: - Fallback Results (dedicated View to break conditional chain)

private struct FallbackResultsView: View {
	let modelManager: ModelManager
	let theme: OcoreaiTheme

	var body: some View {
		if !modelManager.hfResults.isEmpty {
			HFResultsList(modelManager: modelManager, theme: theme)
		} else if !modelManager.msResults.isEmpty {
			MSResultsList(modelManager: modelManager, theme: theme)
		}
	}
}

// MARK: - Result Row (pure data view, no conditionals)

private struct ModelResultRow: View {
	let display: String
	let sub: String
	let modelId: String
	let modelManager: ModelManager
	let theme: OcoreaiTheme

	var body: some View {
		HStack(spacing: 10) {
			ZStack {
				Circle().fill(theme.accentSoft).frame(width: 28, height: 28)
				Image(systemName: "cloud").font(.ocoreaiText(11)).foregroundStyle(theme.accent)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(display).font(.ocoreaiText(14)).fontWeight(.semibold).lineLimit(1)
				Text(sub).font(.ocoreaiText(11)).foregroundStyle(theme.textTertiary)
			}
			Spacer()
			downloadButton
		}
		.padding(10).modifier(theme.cardStyle())
	}

	@ViewBuilder
	private var downloadButton: some View {
		if modelManager.downloadingModelId == modelId {
			ProgressView()
		} else {
			Button {
				Task {
					let ok = await modelManager.load(modelId)
					if ok {
						await modelManager.refreshLocalModels()
					}
				}
			} label: {
				Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(theme.accent)
			}
			.disabled(modelManager.isDownloading)
		}
	}
}

// MARK: - Local Models List (dedicated View to break conditional chain)

private struct ModelLocalListView: View {
	let modelManager: ModelManager
	let onEdit: (String) -> Void

	var body: some View {
		if modelManager.localModels.isEmpty {
			ModelEmptyState()
		} else {
			ModelListContent(modelManager: modelManager, onEdit: onEdit)
		}
	}
}

// MARK: - Local Models Content

private struct ModelListContent: View {
	let modelManager: ModelManager
	let onEdit: (String) -> Void

	var body: some View {
		Text(StringKey.sectionModels.l).font(.ocoreaiText(13)).foregroundStyle(.secondary).bold()
		LazyVStack(spacing: 8) {
			ForEach(modelManager.localModels, id: \.id) { model in
				// Model status: check lifecycle state
				let isCurrentlyLoading = modelManager.downloadingModelId == model.id
				let isCurrentlyServing = modelManager.servingModelIds.contains(model.id)
				LiveModelCard(model: model, isDownloading: isCurrentlyLoading, isServing: isCurrentlyServing, onEdit: {
					onEdit(model.id)
				}, onDelete: {
					Task {
						let ok = await modelManager.deleteModel(model.id)
						if ok {
							await modelManager.refreshLocalModels()
						}
					}
				})
			}
		}
	}
}

// MARK: - Empty State

private struct ModelEmptyState: View {
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: "brain.head.profile").font(.ocoreaiText(36, weight: .light)).foregroundStyle(theme.textTertiary)
			Text(StringKey.noModelsLoaded.l).font(.ocoreaiText(14)).foregroundStyle(theme.textSecondary)
		}
		.frame(maxWidth: .infinity, minHeight: 120).modifier(theme.cardStyle())
	}
}

// MARK: - Live Model Card

private struct LiveModelCard: View {
	let model: ModelID
	let isDownloading: Bool
	let isServing: Bool
	let onEdit: () -> Void
	let onDelete: () -> Void
	@Environment(\.ocoreaiTheme) private var theme
	@State private var showDeleteAlert = false

	var body: some View {
		Button { onEdit() } label: { cardContent }
			.buttonStyle(.plain)
			.confirmationDialog(
				StringKey.modelViewDeleteConfirmTitle.l,
				isPresented: $showDeleteAlert,
				titleVisibility: .visible
			) {
				Button(role: .destructive) {
					onDelete()
				} label: {
					Text(StringKey.modelViewDeleteConfirmAction.l)
				}
				Button(StringKey.modelViewDeleteCancelAction.l, role: .cancel) {}
			} message: {
				Text(String(format: StringKey.modelViewDeleteConfirmMessage.l, model.id))
			}
			.accessibilityLabel(StringKey.modelViewTapToEdit.l)
	}

	/// Determine the appropriate status from the model's lifecycle state.
	private var modelStatus: SPStatus {
		if isDownloading { return .starting }    // Blue = loading
		if isServing { return .running }         // Green = serving
		return .stopped                           // Gray = idle
	}

	/// Accessibility label describing the current status.
	private var statusA11yLabel: String {
		if isDownloading { return StringKey.modelStartingLabel.l }
		if isServing { return StringKey.modelServingLabel.l }
		return StringKey.modelRunningLabel.l
	}

	private var cardContent: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle().fill(theme.accentSoft).frame(width: 32, height: 32)
				Image(systemName: model.isVlm ? "eye" : "cpu")
					.font(.ocoreaiText(13, weight: .medium))
					.foregroundStyle(theme.accent)
			}
			.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 6) {
				// Model name + metadata pills row
				HStack(spacing: 6) {
					Text(model.id)
						.font(.ocoreaiText(15))
						.fontWeight(.semibold)
						.lineLimit(1)

					// VLM badge
					if model.isVlm {
						Text(StringKey.modelInfoVLM.l)
							.font(.ocoreaiMono(9))
							.foregroundStyle(theme.accent)
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
					}

					// Context window badge
					if !model.contextString.isEmpty {
						Text(model.contextString)
							.font(.ocoreaiMono(9))
							.foregroundStyle(theme.textSecondary)
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(theme.textTertiary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
					}
				}

				// Detail row: tokenizer + vocab
				HStack(spacing: 12) {
					if !model.tokenizer.isEmpty {
						Label(model.tokenizer, systemImage: "text.format")
							.font(.ocoreaiText(10))
							.foregroundStyle(theme.textTertiary)
					}
					if !model.vocabString.isEmpty {
						Label(model.vocabString, systemImage: "character.bubble.fill")
							.font(.ocoreaiText(10))
							.foregroundStyle(theme.textTertiary)
					}
				}
			}

			Spacer()

			if model.paramsCustomized {
				Image(systemName: "slider.horizontal.3").font(.ocoreaiText(11))
					.foregroundStyle(theme.accent)
					.accessibilityLabel(StringKey.modelParamTemperature.l)
					.accessibilityHidden(true)
			}

			// Status pill: starting (blue) = loading, stopping (orange) = serving, running (green) = idle
			StatusPill(status: modelStatus, compact: false)
				.accessibilityLabel(statusA11yLabel)

			Button(role: .destructive) {
				showDeleteAlert = true
			} label: {
				Image(systemName: "trash")
					.font(.ocoreaiText(12))
					.foregroundStyle(.red.opacity(0.7))
			}
			.buttonStyle(.plain)
			.accessibilityLabel(StringKey.modelDeleteButton.l)

			Image(systemName: "gearshape").font(.ocoreaiText(12))
				.foregroundStyle(theme.textTertiary)
				.accessibilityHidden(true)
		}
		.padding(8)
		.modifier(theme.cardStyle())
		.accessibilityLabel("\(StringKey.a11yModel.l): \(model.id)")
		.accessibilityAddTraits(.isStaticText)
	}
}
