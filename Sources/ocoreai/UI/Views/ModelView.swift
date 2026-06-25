// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelView — model management: load, switch, quantize
/// Fast Path: reads directly from EnginePool (no HTTP)
/// @Observable pattern. i18n via StringKey. Accessibility: full VoiceOver.

import SwiftUI

struct ModelView: View {
	@State private var modelsState: ModelsState
	@State private var showParamsSheet = false
	@State private var editingModelId: String = ""
	@State private var showModelSearch = false
	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_modelsState = State(initialValue: ModelsState())
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				SectionHeader(StringKey.tabModels.l, subtitle: StringKey.loadingModels.l) {
					Button(StringKey.modelSearchTitle.l) {
						showModelSearch = true
					}
					.ocoreaiButton(.normal, size: .small)
					.accessibilityLabel(StringKey.modelSearchLabel.l)
					.accessibilityHint(StringKey.modelSearchHint.l)
					Spacer(minLength: 8)
					Button(StringKey.refreshButton.l) {
						Task { await modelsState.fetchModels() }
					}
					.ocoreaiButton(.normal, size: .small)
					.accessibilityLabel(StringKey.refreshModelLabel.l)
					.accessibilityHint(StringKey.refreshModelHint.l)
				}

				if modelsState.state.isLoading {
					LoadingStateView(message: StringKey.loadingModels.l)
				} else if modelsState.state.data?.isEmpty == true {
					emptyState
				} else if let models = modelsState.state.data {
					LazyVStack(spacing: 8) {
						ForEach(models, id: \.id) { model in
							LiveModelCard(model: model) {
								editingModelId = model.id
								showParamsSheet = true
							}
						}
					}
				}
				Spacer(minLength: 16)
			}
			.padding(20)
		}
		.background(theme.windowBg)
		.task {
			await modelsState.fetchModels()
		}
		.sheet(isPresented: $showParamsSheet) {
			ModelParamsView(modelId: editingModelId)
		}
		.sheet(isPresented: $showModelSearch) {
			ModelSearchSheetView()
		}
		.accessibilityLabel(StringKey.tabModels.l)
	}

	private var emptyState: some View {
		VStack(spacing: 10) {
			Image(systemName: "brain.head.profile")
				.font(.ocoreaiText(36, weight: .light))
				.foregroundStyle(theme.textTertiary)
				.accessibilityHidden(true)
			Text(StringKey.noModelsLoaded.l)
				.font(.ocoreaiText(14))
				.foregroundStyle(theme.textSecondary)
		}
		.frame(maxWidth: .infinity, minHeight: 120)
		.modifier(theme.cardStyle())
		.accessibilityLabel(StringKey.noModelsLoaded.l)
		.accessibilityAddTraits(.isStaticText)
	}
}

private struct LiveModelCard: View {
	let model: ModelID
	let onTap: () -> Void
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		Button { onTap() } label: {
			cardContent
		}
		.buttonStyle(.plain)
		.accessibilityLabel(StringKey.modelViewTapToEdit.l)
	}

	@ViewBuilder
	private var cardContent: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle()
					.fill(theme.accentSoft)
					.frame(width: 32, height: 32)
				Image(systemName: "cpu")
					.font(.ocoreaiText(13, weight: .medium))
					.foregroundStyle(theme.accent)
			}
			.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 4) {
				Text(model.id)
					.font(.ocoreaiText(15))
					.fontWeight(.semibold)
				if model.maxContext > 0 {
					Text("\(StringKey.modelInfoContext.l): \(model.maxContext)")
						.font(.ocoreaiText(11))
						.foregroundStyle(theme.textSecondary)
				}
				if !model.tokenizer.isEmpty {
					Text("\(StringKey.modelInfoTokenizer.l): \(model.tokenizer)")
						.font(.ocoreaiText(11))
						.foregroundStyle(theme.textTertiary)
				}
			}

			Spacer()

			// Params indicator dot — shows when model has custom params
			if model.paramsCustomized {
				Image(systemName: "slider.horizontal.3")
					.font(.ocoreaiText(11))
					.foregroundStyle(theme.accent)
					.accessibilityLabel(StringKey.modelParamTemperature.l)
					.accessibilityHidden(true)
			}

			StatusPill(status: .running, compact: false)
				.accessibilityLabel(StringKey.modelRunningLabel.l)

			// Gear icon hint
			Image(systemName: "gearshape")
				.font(.ocoreaiText(12))
				.foregroundStyle(theme.textTertiary)
				.accessibilityHidden(true)
		}
		.padding(8)
		.modifier(theme.cardStyle())
		.accessibilityLabel("\(StringKey.a11yModel.l): \(model.id)")
		.accessibilityAddTraits(.isStaticText)
	}
}
