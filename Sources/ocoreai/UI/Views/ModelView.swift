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
	@State private var hfResults: [HFModelInfo] = []
	@State private var msResults: [MSModelInfo] = []
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
			text: $searchQuery
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

	@ViewBuilder
	private var _hfResultView: some View {
		LazyVStack(spacing: 8) {
			ForEach(Array(hfResults.prefix(20).enumerated()), id: \.offset) { _, model in
				_resultRow(display: model.id, sub: model.pipelineTag ?? "", modelId: model.id)
			}
		}
	}

	@ViewBuilder
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
			hfResults = await _searchHub(keyword: query)
			msResults = []
		case .modelScope:
			msResults = await _searchModelScope(keyword: query)
			hfResults = []
		}
		isSearching = false
	}

	func _searchHub(keyword: String, limit: Int = 15) async -> [HFModelInfo] {
		guard let url = URL(string: "https://huggingface.co/api/models?search=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)&limit=\(limit)&sort=likes") else { return [] }
		do {
			let (data, response) = try await URLSession.shared.data(from: url)
			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
			return try JSONDecoder().decode([HFModelInfo].self, from: data)
		} catch { return [] }
	}

	func _searchModelScope(keyword: String, pageSize: Int = 15) async -> [MSModelInfo] {
		guard let url = URL(string: "https://modelscope.cn/api/v1/models") else { return [] }
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let body: [String: Any] = ["Path": keyword, "PageNumber": 1, "PageSize": min(pageSize, 100)]
		request.httpBody = try? JSONSerialization.data(withJSONObject: body)
		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
			let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
			var dataObj = json ?? [:]
			if let nested = json?["Data"] as? [String: Any] { dataObj = nested }
			guard let modelsRaw = dataObj["Models"] as? [[String: Any]] else { return [] }
			let modelData = modelsRaw.map { try? JSONDecoder().decode(MSModelInfo.self, from: try JSONSerialization.data(withJSONObject: $0, options: [])) }
			return modelData.compactMap { $0 }
		} catch { return [] }
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
				let _ = try await pool.acquire(model: normalizedId)
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

	@ViewBuilder
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
