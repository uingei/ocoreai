// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelView — model management: load, switch, quantize with inline search
/// Fast Path: reads directly from EnginePool (no HTTP)
/// @Observable pattern. i18n via StringKey. Accessibility: full VoiceOver.

import SwiftUI

struct ModelView: View {
	@State private var modelsState: ModelsState
	@State private var showParamsSheet = false
	@State private var editingModelId: String = ""
	// Inline search state
	@State private var searchQuery = ""
	@State private var selectedSource: HubSource = .huggingFace
	@State private var hfResults: [HFHubModel] = []
	@State private var msResults: [MSHubModel] = []
	@State private var isSearching = false
	@State private var loadingModelId = ""
	@State private var downloadError: String?
	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_modelsState = State(initialValue: ModelsState())
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

				// 错误
				if let err = downloadError {
					Button {
						downloadError = nil
					} label: {
						HStack(spacing: 8) {
							Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
							Text(err).foregroundStyle(.secondary).font(.caption)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
					}
					.buttonStyle(.plain)
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
		Picker(StringKey.modelSearchSelectHub.l, selection: $selectedSource) {
			ForEach(HubSource.allCases, id: \.self) { s in
				Text(s.rawValue).tag(s)
			}
		}
		.pickerStyle(.segmented).frame(maxWidth: .infinity)

		TextField(
			selectedSource == .huggingFace
				? StringKey.modelSearchHFHub.l
				: StringKey.modelSearchModelScope.l,
			text: $searchQuery,
		)
		.disableAutocorrection(true)

		// macOS Form intercepts .onSubmit for row navigation — use a button as the primary trigger
		Button(action: { Task { await doSearch(searchQuery) } }) {
			Image(systemName: "magnifyingglass").font(.ocoreaiText(12))
		}
		.buttonStyle(.borderedProminent)
		.controlSize(.small)
		.frame(width: 80)
		.accessibilityLabel(StringKey.modelSearchSearching.l)

		if isSearching {
			HStack {
				ProgressView()
				Text(StringKey.modelSearchSearching.l).foregroundStyle(.secondary)
				Spacer()
			}
		}
	}

	@ViewBuilder
	private var searchResultsView: some View {
		if !searchQuery.isEmpty || hfResults.isEmpty == false || msResults.isEmpty == false {
			if isSearching {
				searchingPlaceholder
			} else if selectedSource == .huggingFace, !hfResults.isEmpty {
				_hfResultView
			} else if selectedSource == .modelScope, !msResults.isEmpty {
				_msResultView
			} else if !hfResults.isEmpty || !msResults.isEmpty {
				// Results from previous search, show them
				_hfResultView2
			} else {
				emptySearchState
			}
		}
	}

	private var searchingPlaceholder: some View {
		VStack(spacing: 12) {
			ProgressView().scaleEffect(1.2)
			Text(StringKey.modelSearchSearching.l).foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity).padding(.vertical, 20)
	}

	@ViewBuilder
	private var _hfResultView2: some View {
		if !hfResults.isEmpty {
			_hfResultView
		} else if !msResults.isEmpty {
			_msResultView
		}
	}

	private var _hfResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(hfResults.prefix(20).enumerated()), id: \.offset) { _, model in
				_resultRow(display: model.id, sub: model.pipelineTag ?? "", modelId: model.id)
			}
		}
	}

	private var _msResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(msResults.prefix(20).enumerated()), id: \.offset) { _, model in
				_resultRow(display: model.path, sub: String(model.stars), modelId: model.path)
			}
		}
	}

	private func _resultRow(display: String, sub: String, modelId: String) -> some View {
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
			if loadingModelId == modelId {
				ProgressView()
			} else {
				Button { loadModelAndRefresh(modelId) } label: {
					Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(theme.accent)
				}.disabled(!loadingModelId.isEmpty)
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

	func doSearch(_ query: String) async {
		guard !query.isEmpty else { hfResults = []; msResults = []; return }
		isSearching = true
		downloadError = nil
		switch selectedSource {
		case .huggingFace:
		hfResults = await doSearchHub(keyword: query)
			msResults = []
		case .modelScope:
		msResults = await doSearchModelScope(keyword: query)
			hfResults = []
		}
		isSearching = false
	}

	// MARK: - Hub Search (delegated to HuggingFaceSearchClient / ModelScopeSearchClient)

	private func doSearchHub(keyword: String, limit: Int = 15) async -> [HFHubModel] {
		do {
			let client = HuggingFaceSearchClient()
			return try await client.search(query: keyword, limit: limit)
		} catch {
			return []
		}
	}

	private func doSearchModelScope(keyword: String, pageSize: Int = 15) async -> [MSHubModel] {
		do {
			let client = ModelScopeSearchClient()
			let result = try await client.search(keyword: keyword, pageSize: min(pageSize, 100))
			return result.models
		} catch {
			return []
		}
	}

	private func loadModelAndRefresh(_ modelId: String) {
		guard OcoreaiEngine.shared.activeEnginePool != nil else {
			downloadError = "Engine not available"
			return
		}
		let normalizedId = (selectedSource == .modelScope && !modelId.hasPrefix("mscope:")) ? "mscope:\(modelId)" : modelId
		loadingModelId = modelId
		Task {
			guard let pool = OcoreaiEngine.shared.activeEnginePool else { return }
			do {
				_ = try await pool.acquire(model: normalizedId)
				await pool.releaseSession(modelId: normalizedId, sessionId: "init")
				await modelsState.fetchModels()
				loadingModelId = ""
			} catch {
				downloadError = error.localizedDescription
				loadingModelId = ""
			}
		}
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
