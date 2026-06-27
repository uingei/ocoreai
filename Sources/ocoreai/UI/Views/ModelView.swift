// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelView — model management: load, switch, quantize with inline search
/// Fast Path: reads directly from EnginePool (no HTTP)
/// @Observable pattern. i18n via StringKey. Accessibility: full VoiceOver.
/// Search/download delegated to shared ModelRepositoryState (see ModelRepositoryState.swift).
/// Local model list still uses ModelsState for sampling-config merging from SettingsStore.

import SwiftUI

struct ModelView: View {
	// Local models — ModelsState handles sampling config merge from SettingsStore
	@State private var modelsState: ModelsState
	@State private var showParamsSheet = false
	@State private var editingModelId: String = ""

	// Search/download — shared ModelRepositoryState replaces the 3 separate implementations
	@State private var repositoryState: ModelRepositoryState

	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_modelsState = State(initialValue: ModelsState())
		_repositoryState = State(initialValue: ModelRepositoryState())
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
				if let error = repositoryState.currentError {
					OcoreaiErrorBanner(error: error) { repositoryState.currentError = nil }
				}

				// 本地模型
				localModelsView
			}
		}
		.formStyle(.grouped)
		.background(theme.windowBg)
		.task {
			await modelsState.fetchModels()
		}
		.sheet(isPresented: $showParamsSheet) {
			ModelParamsView(modelId: editingModelId)
		}
		.accessibilityLabel(StringKey.tabModels.l)
	}

	@ViewBuilder
	private var searchBoxCard: some View {
		// Form 环境下直接放内容，不需要额外 Section（外层已有 Section）
		Picker(StringKey.modelSearchSelectHub.l, selection: $repositoryState.selectedSource) {
			ForEach(HubSource.allCases, id: \.self) { s in
				Text(s.rawValue).tag(s)
			}
		}
		.pickerStyle(.segmented).frame(maxWidth: .infinity)

		TextField(
			repositoryState.selectedSource == .huggingFace
				? StringKey.modelSearchHFHub.l
				: StringKey.modelSearchModelScope.l,
			text: Binding<String>(
				get: { repositoryState.searchQuery },
				set: { repositoryState.searchQuery = $0 },
			),
		)
		.disableAutocorrection(true)
		.onSubmit {
			Task { await repositoryState.search(repositoryState.searchQuery) }
		}

		// macOS Form intercepts .onSubmit for row navigation — use a button as the primary trigger
		Button(action: { Task { await repositoryState.search(repositoryState.searchQuery) } }) {
			Image(systemName: "magnifyingglass").font(.ocoreaiText(12))
		}
		.buttonStyle(.borderedProminent)
		.controlSize(.small)
		.frame(width: 80)
		.accessibilityLabel(StringKey.modelSearchSearching.l)

		if repositoryState.isSearching {
			HStack {
				ProgressView()
				Text(StringKey.modelSearchSearching.l).foregroundStyle(theme.textSecondary)
				Spacer()
			}
		}
	}

	@ViewBuilder
	private var searchResultsView: some View {
		let hasResults = !repositoryState.hfResults.isEmpty || !repositoryState.msResults.isEmpty
		let hasQuery = !repositoryState.searchQuery.isEmpty

		if hasQuery || hasResults {
			if repositoryState.isSearching {
				searchingPlaceholder
			} else if repositoryState.selectedSource == .huggingFace, !repositoryState.hfResults.isEmpty {
				hfResultView
			} else if repositoryState.selectedSource == .modelScope, !repositoryState.msResults.isEmpty {
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
		if !repositoryState.hfResults.isEmpty {
			hfResultView
		} else if !repositoryState.msResults.isEmpty {
			msResultView
		}
	}

	private var hfResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(repositoryState.hfResults.prefix(20).enumerated()), id: \.offset) { _, model in
				resultRow(display: model.id, sub: model.pipelineTag ?? "", modelId: model.id)
			}
		}
	}

	private var msResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(repositoryState.msResults.prefix(20).enumerated()), id: \.offset) { _, model in
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
			if repositoryState.downloadingModelId == modelId {
				ProgressView()
			} else {
				Button {
					Task {
						let ok = await repositoryState.load(modelId)
						if ok {
							await modelsState.fetchModels()
						}
					}
				} label: {
					Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(theme.accent)
				}
				.disabled(repositoryState.isDownloading)
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
		if modelsState.state.isLoading {
			LoadingStateView(message: StringKey.loadingModels.l)
		} else if modelsState.state.data?.isEmpty == true {
			emptyState
		} else if let models = modelsState.state.data {
			Text(StringKey.sectionModels.l).font(.ocoreaiText(13)).foregroundStyle(theme.textTertiary).bold()
			LazyVStack(spacing: 8) {
				ForEach(models, id: \.id) { model in
					LiveModelCard(model: model) {
						editingModelId = model.id
						showParamsSheet = true
					}
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
	let onTap: () -> Void
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		Button { onTap() } label: { cardContent }
			.buttonStyle(.plain)
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

			Image(systemName: "gearshape").font(.ocoreaiText(12))
				.foregroundStyle(theme.textTertiary).accessibilityHidden(true)
		}
		.padding(8).modifier(theme.cardStyle())
		.accessibilityLabel("\(StringKey.a11yModel.l): \(model.id)")
		.accessibilityAddTraits(.isStaticText)
	}
}
