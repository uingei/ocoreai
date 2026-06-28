// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelView — model management: load, switch, quantize with inline search
/// Fast Path: reads directly from EnginePool (no HTTP)
/// @Observable pattern. i18n via StringKey. Accessibility: full VoiceOver.
/// Search/download + local model list delegated to shared ModelManager (see ModelManager.swift).

import SwiftUI

struct ModelView: View {
	// Unified model manager — search/download + local models + sampling config merge
	@State private var modelManager: ModelManager
	@State private var showParamsSheet = false
	@State private var editingModelId: String = ""

	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_modelManager = State(initialValue: ModelManager())
	}

	var body: some View {
		// macOS: TextField keyboard input requires Form for proper responder chain
		// Without Form, keyboard chars are swallowed but pasteboard (Cmd+V) still works
		Form {
			Section(StringKey.tabModels.l) {
				// 搜索框
				searchBoxCard

				// 搜索结果
				searchResultsView

				// 错误 — unified OcoreaiErrorBanner
				if let error = modelManager.currentError {
					OcoreaiErrorBanner(error: error) { modelManager.currentError = nil }
				}

				// 本地模型
				localModelsView
			}
		}
		.formStyle(.grouped)
		.background(theme.windowBg)
		.task {
			await modelManager.loadModels()
		}
		.sheet(isPresented: $showParamsSheet) {
			ModelParamsView(modelId: editingModelId)
		}
		.accessibilityLabel(StringKey.tabModels.l)
	}

	@ViewBuilder
	private var searchBoxCard: some View {
		// Form 环境下直接放内容，不需要额外 Section（外层已有 Section）
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

	@ViewBuilder
	private var searchResultsView: some View {
		let hasResults = !modelManager.hfResults.isEmpty || !modelManager.msResults.isEmpty
		let hasQuery = !modelManager.searchQuery.isEmpty

		if hasQuery || hasResults {
			if modelManager.isSearching {
				searchingPlaceholder
			} else if modelManager.selectedSource == .huggingFace, !modelManager.hfResults.isEmpty {
				hfResultView
			} else if modelManager.selectedSource == .modelScope, !modelManager.msResults.isEmpty {
				msResultView
			} else if hasResults {
				// Results from previous search, show them
				fallbackResultView
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

	@ViewBuilder
	private var fallbackResultView: some View {
		if !modelManager.hfResults.isEmpty {
			hfResultView
		} else if !modelManager.msResults.isEmpty {
			msResultView
		}
	}

	private var hfResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(modelManager.hfResults.prefix(20).enumerated()), id: \.offset) { _, model in
				resultRow(display: model.id, sub: model.pipelineTag ?? "", modelId: model.id)
			}
		}
	}

	private var msResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(modelManager.msResults.prefix(20).enumerated()), id: \.offset) { _, model in
				resultRow(display: model.path, sub: String(model.stars), modelId: model.path)
			}
		}
	}

	private func resultRow(display: String, sub: String, modelId: String) -> some View {
		HStack(spacing: 10) {
			ZStack {
				Circle().fill(theme.accentSoft).frame(width: 28, height: 28)
				Image(systemName: "cloud").font(.ocoreaiText(11)).foregroundStyle(theme.accent)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(display).font(.ocoreaiText(14)).fontWeight(.semibold).lineLimit(1)
				Text(sub).font(.caption).foregroundStyle(theme.textTertiary)
			}
			Spacer()
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
		.padding(10).modifier(theme.cardStyle())
	}

	private var emptySearchState: some View {
		VStack(spacing: 10) {
			Image(systemName: "magnifyingglass").font(.ocoreaiText(28, weight: .light)).foregroundStyle(theme.textTertiary)
			Text(StringKey.modelSearchEmpty.l).font(.ocoreaiText(13)).foregroundStyle(theme.textSecondary)
		}
		.frame(maxWidth: .infinity).padding(.vertical, 24)
	}

	@ViewBuilder
	private var localModelsView: some View {
		if modelManager.localModels.isEmpty {
			emptyState
		} else {
			Text(StringKey.sectionModels.l).font(.ocoreaiText(13)).foregroundStyle(theme.textTertiary).bold()
			LazyVStack(spacing: 8) {
				ForEach(modelManager.localModels, id: \.id) { model in
					LiveModelCard(model: model, onEdit: {
						editingModelId = model.id
						showParamsSheet = true
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

	private var emptyState: some View {
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

	private var cardContent: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle().fill(theme.accentSoft).frame(width: 32, height: 32)
				Image(systemName: "cpu").font(.ocoreaiText(13, weight: .medium)).foregroundStyle(theme.accent)
			}.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 4) {
				Text(model.id).font(.ocoreaiText(15)).fontWeight(.semibold)
				if model.maxContext > 0 {
					Text("\(StringKey.modelInfoContext.l): \(model.maxContext)")
						.font(.ocoreaiText(11)).foregroundStyle(theme.textSecondary)
				}
				if !model.tokenizer.isEmpty {
					Text("\(StringKey.modelInfoTokenizer.l): \(model.tokenizer)")
						.font(.ocoreaiText(11)).foregroundStyle(theme.textTertiary)
				}
			}

			Spacer()

			if model.paramsCustomized {
				Image(systemName: "slider.horizontal.3").font(.ocoreaiText(11))
					.foregroundStyle(theme.accent)
					.accessibilityLabel(StringKey.modelParamTemperature.l)
					.accessibilityHidden(true)
			}

			StatusPill(status: .running, compact: false).accessibilityLabel(StringKey.modelRunningLabel.l)

			// Delete button — destructive action with confirmation
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
				.foregroundStyle(theme.textTertiary).accessibilityHidden(true)
		}
		.padding(8).modifier(theme.cardStyle())
		.accessibilityLabel("\(StringKey.a11yModel.l): \(model.id)")
		.accessibilityAddTraits(.isStaticText)
	}
}
