// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Standalone model search sheet — reusable from ModelView and ChatView.
/// Directly interacts with OcoreaiEngine, no ChatState dependency.
/// Features: HuggingFace / ModelScope hub search, direct model ID loading, progress indicator.

import SwiftUI
import Observation

// MARK: - ViewModel

@Observable
@MainActor
final class ModelSearchState {
	var searchQuery = ""
	var hfResults: [HFModelInfo] = []
	var msResults: [MSModelInfo] = []
	var isSearching = false
	var loadingModelId = ""
	var loadingProgress: String? = nil
	var directModelId = ""
	var selectedSource: HubSource = .huggingFace
	var localError: String? = nil
	
	func performSearch(_ query: String) async {
		guard !query.isEmpty else {
			hfResults = []
			msResults = []
			return
		}
		isSearching = true
		localError = nil
		
		switch selectedSource {
		case .huggingFace:
			let results = await searchHub(keyword: query)
			hfResults = results
			if results.isEmpty && query.count > 1 {
				localError = "No models found for \"\(query)\""
			}
		case .modelScope:
			let results = await searchModelScope(keyword: query)
			msResults = results
			if results.isEmpty && query.count > 1 {
				localError = "No models found for \"\(query)\""
			}
		}
		isSearching = false
	}
	
	@MainActor
	func loadModel(_ modelId: String, onSuccess: (() -> Void)?) {
		guard let pool = OcoreaiEngine.shared.activeEnginePool else {
			localError = "Engine not available"
			return
		}
			
		let normalizedId: String
		if selectedSource == .modelScope && !modelId.hasPrefix("mscope:") {
			normalizedId = "mscope:\(modelId)"
		} else {
			normalizedId = modelId
		}
			
		loadingModelId = modelId
		loadingProgress = "Downloading…"
			
		Task {
			do {
				let _ = try await pool.acquire(model: normalizedId)
				await pool.releaseSession(modelId: normalizedId, sessionId: "init")
				loadingModelId = ""
				loadingProgress = nil
				onSuccess?()
			} catch {
				localError = error.localizedDescription
				loadingModelId = ""
				loadingProgress = nil
			}
		}
	}
	
	// MARK: - Hub Search (mirrors ChatState methods)
	
	private func searchHub(keyword: String, limit: Int = 15) async -> [HFModelInfo] {
		guard let url = URL(string: "https://huggingface.co/api/models?search=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)&limit=\(limit)&sort=likes")
		else { return [] }
		
		do {
			let (data, response) = try await URLSession.shared.data(from: url)
			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
				return []
			}
			return try JSONDecoder().decode([HFModelInfo].self, from: data)
		} catch {
			return []
		}
	}
	
	private func searchModelScope(keyword: String, pageSize: Int = 15) async -> [MSModelInfo] {
		guard let url = URL(string: "https://modelscope.cn/api/v1/models/") else { return [] }
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		
		let body: [String: Any] = [
			"Path": keyword,
			"PageNumber": 1,
			"PageSize": min(pageSize, 100),
		]
		request.httpBody = try? JSONSerialization.data(withJSONObject: body)
		
		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
				return []
			}
			let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
			var dataObj = json ?? [:]
			if let nested = json?["Data"] as? [String: Any] {
				dataObj = nested
			}
			guard let modelsRaw = dataObj["Models"] as? [[String: Any]] else { return [] }
			let modelData = modelsRaw.map { try? JSONDecoder().decode(MSModelInfo.self, from: try JSONSerialization.data(withJSONObject: $0, options: [])) }
			return modelData.compactMap { $0 }
		} catch {
			return []
		}
	}
}

// MARK: - View

struct ModelSearchSheetView: View {
	@State private var searchState = ModelSearchState()
	@Environment(\.dismiss) private var dismiss
	@Environment(\.ocoreaiTheme) private var theme
	
	var body: some View {
		NavigationStack {
			Form {
				// Quick entry — direct model ID
				Section(StringKey.modelSearchQuickLoad.l) {
					HStack {
						TextField(StringKey.modelSearchExample.l, text: $searchState.directModelId)
						if !searchState.directModelId.isEmpty {
							Button(StringKey.modelSearchLoad.l) {
								searchState.loadModel(searchState.directModelId, onSuccess: { dismiss() })
							}
						}
					}
				}
				
				// Hub source selector
				Section(StringKey.modelSearchHubSource.l) {
					Picker(StringKey.modelSearchSelectHub.l, selection: $searchState.selectedSource) {
						ForEach(HubSource.allCases, id: \.self) { source in
							Text(source.rawValue).tag(source)
						}
					}
					.pickerStyle(.segmented)
				}
				
				// Search section
				Section {
					SearchBar(
						text: $searchState.searchQuery,
						// swiftlint:disable:next identifier_name
						placeholder: searchState.selectedSource == .huggingFace
							? StringKey.modelSearchHFHub.l
							: StringKey.modelSearchModelScope.l
					) { query in
						Task {
							await searchState.performSearch(query)
						}
					}
					
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
				
				// HF Results
				if !searchState.hfResults.isEmpty, searchState.selectedSource == .huggingFace {
					Section(StringKey.modelSearchResults.l) {
						List(searchState.hfResults) { model in
							HFModelRow(model: model)
								.onTapGesture {
								searchState.loadModel(model.id, onSuccess: { dismiss() })
							}
						}
						.listStyle(.plain)
					}
				}
				
				// MS Results
				if !searchState.msResults.isEmpty, searchState.selectedSource == .modelScope {
					Section(StringKey.modelSearchResults.l) {
						List(searchState.msResults) { model in
							MSModelRow(model: model)
								.onTapGesture {
									searchState.loadModel(model.path, onSuccess: { dismiss() })
								}
						}
						.listStyle(.plain)
					}
				}
				
				// Currently loading
				if !searchState.loadingModelId.isEmpty {
					Section(StringKey.modelSearchLoading.l) {
						HStack {
							ProgressView()
							Text(searchState.loadingModelId)
								.foregroundStyle(.secondary)
								.lineLimit(1)
							Spacer()
						}
						if let progress = searchState.loadingProgress {
							Text(progress)
								.foregroundStyle(.secondary)
								.font(.ocoreaiText(11))
						}
					}
				}
				
				// Error
				if let error = searchState.localError {
					Section {
						HStack {
							Image(systemName: "exclamationmark.triangle")
								.foregroundStyle(.red)
							Text(error)
								.foregroundStyle(.secondary)
								.font(.ocoreaiText(12))
						}
					}
				}
			}
			.navigationTitle(StringKey.modelSearchTitle.l)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(StringKey.modelSearchDismiss.l) {
						dismiss()
					}
					.disabled(!searchState.loadingModelId.isEmpty)
				}
			}
		}
	}
}

// MARK: - Search Bar (macOS-compatible TextField)

private struct SearchBar: View {
	@Binding var text: String
	let placeholder: String
	let onCommit: (String) -> Void
	
	var body: some View {
		TextField(placeholder, text: $text)
			.onSubmit { onCommit(text) }
	}
}
