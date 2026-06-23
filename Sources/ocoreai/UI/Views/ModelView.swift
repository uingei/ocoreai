// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelView — model management: load, switch, quantize
/// omlx pattern: ViewModel + .task{await vm.load()} + ViewState state machine
/// @Observable pattern: @State + Observable instead of @StateObject
/// Accessibility: full VoiceOver labels, hidden decorative elements

import SwiftUI

struct ModelView: View {
	@State private var modelsState: ModelsState
	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_modelsState = State(initialValue: ModelsState())
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				SectionHeader("Model Management", subtitle: "Load, switch, and monitor models") {
					Button("≡ Refresh") {
						Task { await modelsState.fetchModels() }
					}
					.ocoreaiButton(.normal, size: .small)
					.accessibilityLabel("Refresh Model List")
					.accessibilityHint("Fetch the latest model list from the backend")
				}

				if modelsState.state.isLoading {
					LoadingStateView(message: "Loading models...")
				} else if let err = modelsState.state.error {
					ErrorStateView(error: err) {
						Task { await modelsState.fetchModels() }
					}
				} else if let models = modelsState.state.data, models.isEmpty {
					emptyState
				} else if let models = modelsState.state.data {
					LazyVStack(spacing: 8) {
						ForEach(models, id: \.id) { model in
							LiveModelCard(model: model)
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
		.accessibilityLabel("Models")
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
		.accessibilityLabel("No models available")
		.accessibilityAddTraits(.isStaticText)
	}
}

private struct LiveModelCard: View {
	let model: APIClient.ModelEntry
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
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
				Label(model.object, systemImage: "cpu")
					.font(.ocoreaiText(11))
					.foregroundStyle(theme.textSecondary)
			}

			Spacer()

			StatusPill(status: .running, compact: false)
				.accessibilityLabel("Model is running")
		}
		.modifier(theme.cardStyle())
		.accessibilityLabel("Model: \(model.id), \(model.object)")
		.accessibilityAddTraits(.isStaticText)
	}
}
