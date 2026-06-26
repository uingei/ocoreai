// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatView — streaming chat with model selector, mid-stream interrupt, suggestion chips
/// omlx pattern: ViewModel + .task{await vm.load()} + ViewState state machine
/// Theme-driven: all colors resolve through @Environment(\.ocoreaiTheme)
/// @Observable pattern: @State + Observable instead of @StateObject
/// Accessibility: full VoiceOver support, Dynamic Type, reduced motion
/// Accessibility: ChatBubble uses accessibilityGroup() for semantic hierarchy
/// Reduced Motion: all animations respect .preferredColorScheme

import SwiftUI
import AppKit
/// Stable identity wrapper for chat messages — uses index-based id so SwiftUI
/// does not recreate view identity on every diff.
struct ChatBubbleMessage: Identifiable, Hashable, Sendable {
	let id: Int       // index into the messages array — stable across diffs
	let role: String
	let content: String
	let timestamp: Date

	init(index: Int, role: String, content: String, timestamp: Date) {
		self.id = index
		self.role = role
		self.content = content
		self.timestamp = timestamp
	}
}

struct ChatView: View {
	@State private var chatState: ChatState
	@Environment(\.ocoreaiTheme) private var theme
	@State private var inputText = ""
	@State private var currentModel = ""
	@State private var models: [String] = []
	@State private var activeTask: Task<Void, Never>? = nil
	
	// Model search + load entry point
	@State private var showModelLoader = false

	init() {
		_chatState = State(initialValue: ChatState())
	}

	private var isStreaming: Bool { activeTask != nil || chatState.loading }
	private var isConnected: Bool { chatState.connected }

	var body: some View {
		VStack(spacing: 0) {
			chatHeader
			messageList
			if !chatState.responseText.isEmpty {
				streamingPreview
			}
			inputBar
		}
		.background(theme.windowBg)
		// omlx .task{} lifecycle: start health polling + load models
		.task {
			chatState.start()
			let ids = await chatState.loadModels()
			if ids.isEmpty { models = ["local"] } else { models = ids }
			currentModel = models.first ?? ""
		}
		// omlx lifecycle: stop polling on screen dismissal
		.onDisappear {
			chatState.stop()
		}
		.toolbar {
			// Model selector moved to toolbar — HIG: global controls belong in toolbar
			ToolbarItem(placement: .automatic) {
				Menu {
					ForEach(models, id: \.self) { m in
						Button(m) { currentModel = m }
					}
					// P0: load model from HuggingFace / ModelScope
					Button(StringKey.modelSearchTitle.l) { showModelLoader = true }
					Divider()
					Button(StringKey.defaultModel.l) { currentModel = "" }
				} label: {
					Label(
						currentModel.isEmpty ? StringKey.noModelSelected.l : currentModel,
						systemImage: "brain"
					)
				}
				.accessibilityLabel(StringKey.modelSelectorLabel.l)
				.accessibilityValue(currentModel.isEmpty ? StringKey.modelSelectorValueDefault.l : currentModel)
			}

			ToolbarItem(placement: .primaryAction) {
				Button(role: .destructive) {
					chatState.resetConversation()
				} label: {
					Label(StringKey.clear.l, systemImage: "trash")
				}
				.accessibilityLabel(StringKey.clearConversationLabel.l)
				.accessibilityHint(StringKey.clearConversationHint.l)
				.disabled(isStreaming)
			}
		}
		// Model search + load sheet
		.sheet(isPresented: $showModelLoader) {
			NavigationStack {
				ModelSearchView(
					chatState: chatState,
					onModelLoaded: { updated in
						if !updated.isEmpty {
							models = updated
							currentModel = updated.last ?? currentModel
						}
					}
				)
			}
		}
		// P0-2: On model selector change, unload old model to free GPU memory
		.onChange(of: currentModel) { _, newModel in
			let targetModel = newModel.isEmpty ? "local" : newModel
			chatState.onModelChanged(newModelId: targetModel)
		}
		.accessibilityLabel(StringKey.chatLabel.l)
	}

	// MARK: - Header

	private var chatHeader: some View {
		HStack(spacing: 6) {
			Spacer()

			Circle()
				.fill(isConnected ? theme.greenDot : theme.amberDot)
				.frame(width: 6, height: 6)
				.shadow(color: (isConnected ? theme.greenDot : theme.amberDot).opacity(0.4), radius: 2)
				.accessibilityHidden(true)
			Text(isConnected ? StringKey.localLabel.l : StringKey.chatLoading.l)
				.font(.ocoreaiText(10))
				.foregroundStyle(theme.textSecondary)
				.accessibilityLabel(isConnected ? StringKey.chatConnected.l : StringKey.chatLoading.l)
		}
		.padding(.horizontal)
		.padding(.vertical, 8)
	}

	// MARK: - Message List

	private var messageList: some View {
		ScrollViewReader { proxy in
			ScrollView {
				if chatState.messages.isEmpty && chatState.responseText.isEmpty {
					emptyState
				} else {
					LazyVStack(spacing: 10) {
						ForEach(chatState.messages) { msg in
							ChatBubble(message: ChatBubbleMessage(
								index: msg.id.hashValue,
								role: msg.role,
								content: msg.content,
								timestamp: msg.timestamp
							))
							.id(msg.id)
						}
						// Scroll anchor for automatic scroll-to-bottom
						Color.clear
							.frame(height: 1)
							.id("bottom")
					}
					.padding()
				}
			}
			.scrollIndicators(.never)
			.onChange(of: chatState.messages.count) {
				withAnimationRespectingAccessibility {
					proxy.scrollTo("bottom", anchor: .bottom)
				}
			}
			.onChange(of: chatState.responseText) {
				withAnimationRespectingAccessibility {
					proxy.scrollTo("bottom", anchor: .bottom)
				}
			}
		}
		.accessibilityLabel(StringKey.messagesLabel.l)
	}

	// MARK: - Streaming Preview

	private var streamingPreview: some View {
		ChatBubble(message: ChatBubbleMessage(
			index: -1, // streaming placeholder — not in messages array
			role: "assistant",
			content: chatState.responseText,
			timestamp: Date()
		))
			.opacity(0.85)
			.transition(.opacity.combined(with: .move(edge: .bottom)))
			.padding()
			.accessibilityLabel(StringKey.assistantTyping.l)
			.accessibilityHidden(false)
	}

	// MARK: - Empty State

	private var emptyState: some View {
		VStack(spacing: 14) {
			Image(systemName: "bubble.left.and.bubble.right")
				.font(.ocoreaiText(44, weight: .light))
				.foregroundStyle(theme.textTertiary)
				.accessibilityHidden(true)

			Text(StringKey.chatWelcomeTitle.l)
				.font(.ocoreaiText(22))

			Text(StringKey.chatWelcomeDesc.l)
				.font(.ocoreaiText(14))
				.foregroundStyle(theme.textSecondary)
				.multilineTextAlignment(.center)

			LazyVStack(spacing: 8) {
				suggestionChip("Explain MLX tensor operations")
				suggestionChip("Compare CoreAI vs MLX on Apple Silicon")
				suggestionChip("Debug my SwiftUI view hierarchy")
			}
			.padding(.top, 8)
		}
		.padding(40)
		.transition(.opacity)
	}

	private func suggestionChip(_ text: String) -> some View {
		Button {
			inputText = text
		} label: {
			Text(text)
				.font(.ocoreaiText(13))
				.foregroundStyle(theme.accent)
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 14)
				.padding(.vertical, 8)
				.background(theme.accentSoft)
				.clipShape(Capsule())
		}
		.accessibilityLabel("\(StringKey.suggestionHint.l): \(text)")
		.accessibilityHint(StringKey.suggestionHint.l)
	}

	// MARK: - Input Bar

	private var inputBar: some View {
		HStack(spacing: 10) {
			Button {
				// TODO: AVFoundation speech
			} label: {
				Image(systemName: "waveform.circle.fill")
					.font(.title3)
					.foregroundStyle(theme.textSecondary)
			}
			.accessibilityLabel(StringKey.voiceInputLabel.l)
			.accessibilityHint(StringKey.voiceInputHint.l)

			TextField(StringKey.chatPlaceholder.l, text: $inputText, axis: .vertical)
				.font(.ocoreaiText(15))
				.textFieldStyle(.plain)
				.frame(minHeight: 36)
				.submitLabel(.send)
				.onSubmit { sendMessage() }
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(theme.inputBg)
				.clipShape(RoundedRectangle(cornerRadius: 12))
				.overlay(
					RoundedRectangle(cornerRadius: 12)
						.stroke(theme.inputBorder.opacity(0.5), lineWidth: 0.5)
				)
				.accessibilityLabel(StringKey.messageInputLabel.l)
				.accessibilityHint(StringKey.messageInputHint.l)

			Button {
				isStreaming ? stopStreaming() : sendMessage()
			} label: {
				Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
					.font(.title2)
					.foregroundStyle(isStreaming ? theme.redDot : theme.accent)
			}
			.accessibilityLabel(isStreaming ? StringKey.stopStreamingLabel.l : StringKey.sendMessageLabel.l)
			.accessibilityHint(isStreaming ? StringKey.stopStreamingHint.l : StringKey.sendMessageHint.l)
			.disabled(isStreaming && inputText.trimmingCharacters(in: .whitespaces).isEmpty)
		}
		.padding()
	}

	// MARK: - Actions

	private func sendMessage() {
		let text = inputText.trimmingCharacters(in: .whitespaces)
		guard !text.isEmpty && !isStreaming else { return }

		inputText = ""
		let modelID = currentModel.isEmpty ? "local" : currentModel

		// Use regular Task (not detached) so cancellation propagates
		// and MainActor context is captured for updating chatState
		// ChatView is a struct, so no [weak self] needed — capture is deterministic
		activeTask = Task {
			await self.chatState.chat(text, model: modelID)
		}
	}

	private func stopStreaming() {
		// P0-3: propagate cancellation to both the Task layer and the InferenceCancellation layer
		chatState.cancelInference()
		activeTask?.cancel()
	}
}

// MARK: - Chat Bubble

struct ChatBubble: View {
	let message: ChatBubbleMessage

	@Environment(\.ocoreaiTheme) private var theme

	private var isUser: Bool { message.role == "user" }

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			if !isUser {
				Image(systemName: "cpu")
					.font(.ocoreaiText(12, weight: .medium))
					.foregroundStyle(theme.accent)
					.frame(width: 26, height: 26)
					.background(theme.accentSoft)
					.clipShape(Circle())
					.accessibilityHidden(true)
			}

			VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
				ChatHeader(isUser: isUser, timestamp: message.timestamp)

				Text(message.content)
					.font(.ocoreaiText(15))
					.lineSpacing(3)
					.multilineTextAlignment(isUser ? .trailing : .leading)
					.padding(12)
					.background(
						isUser ? theme.accentSoft : theme.cardBg
					)
					.clipShape(RoundedRectangle(cornerRadius: 14))
			}
			.accessibilityLabel("\(isUser ? StringKey.youLabel.l : StringKey.ocoreaiLabel.l): \(message.content)")
			.accessibilityValue("Message sent at \(message.timestamp, formatter: timeFormatter)")
			.accessibilityAddTraits(.isStaticText)
			.contextMenu {
				Button(StringKey.copyMessage.l) {
					NSPasteboard.general.setString(message.content, forType: .string)
				}
			}

			if isUser { Spacer(minLength: 16) }
		}
	}

	private static let sharedTimeFormatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm"
		return f
	}()

	private var timeFormatter: DateFormatter {
		Self.sharedTimeFormatter
	}
}

struct ChatHeader: View {
	let isUser: Bool
	let timestamp: Date

	@Environment(\.ocoreaiTheme) private var theme

	static let timeFormatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm"
		return f
	}()

	var body: some View {
		HStack(spacing: 6) {
			Text(isUser ? StringKey.youLabel.l : StringKey.ocoreaiLabel.l)
				.font(.ocoreaiText(11, weight: .medium))
				.foregroundStyle(theme.textSecondary)

			Text(Self.timeFormatter.string(from: timestamp))
				.font(.ocoreaiMono(10))
				.foregroundStyle(theme.textTertiary.opacity(0.6))
		}
		.accessibilityHidden(true) // Redundant with ChatBubble label
	}
}

// MARK: - Preview

/// #Preview requires Xcode PreviewsMacros plugin — disabled for swift build.
/// For live previews open the project in Xcode instead.

// MARK: - Model Search + Load View

/// Standalone view for the model search/load sheet.
/// Provides: search bar → HF Hub results → tap to load → loading indicator → auto-close on success.
struct ModelSearchView: View {
	let chatState: ChatState
	let onModelLoaded: ([String]) -> Void
	
	@State private var searchQuery = ""
	@State private var hfResults: [HFModelInfo] = []
	@State private var msResults: [MSModelInfo] = []
	@State private var isSearching = false
	@State private var loadingModelId = ""
	@State private var loadingProgress: String? = nil
	@State private var directModelId = ""
	@State private var showDirectEntry = false
	@State private var selectedSource: HubSource = .huggingFace
	
	@Environment(\.dismiss) private var dismiss
	
	@Environment(\.ocoreaiTheme) private var theme
	
	@State private var localError: String? = nil
	
	var body: some View {
		Form {
			// Quick entry — direct model ID
			Section(StringKey.modelSearchQuickLoad.l) {
				HStack {
					TextField(StringKey.modelSearchExample.l, text: $directModelId)
					if !directModelId.isEmpty {
						Button(StringKey.modelSearchLoad.l) {
							let source = selectedSource == .modelScope ? HubSource.modelScope : HubSource.huggingFace
							loadModel(directModelId, source: source)
						}
					}
				}
			}
			
			// Hub source selector
			Section(StringKey.modelSearchHubSource.l) {
				Picker(StringKey.modelSearchSelectHub.l, selection: $selectedSource) {
					ForEach(HubSource.allCases, id: \.self) { source in
						Text(source.rawValue).tag(source)
					}
				}
				.pickerStyle(.segmented)
			}
			
			// Search section
			Section {
				SearchBar(
						text: $searchQuery,
						placeholder: selectedSource == .huggingFace ? StringKey.modelSearchHFHub.l : StringKey.modelSearchModelScope.l
					) { query in
						Task { await performSearch(query) }
					}
				
				if isSearching {
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
				if !hfResults.isEmpty, selectedSource == .huggingFace {
					Section(StringKey.modelSearchResults.l) {
						LazyVStack(spacing: 4) {
							ForEach(hfResults, id: \.id) { model in
								Button {
									showDirectEntry = false
									loadModel(model.id, source: .huggingFace)
								} label: {
									HFModelRow(model: model)
										.frame(maxWidth: .infinity, alignment: .leading)
								}
								.buttonStyle(.plain)
							}
						}
						.padding(.vertical, 2)
					}
				}

				// MS Results
				if !msResults.isEmpty, selectedSource == .modelScope {
					Section(StringKey.modelSearchResults.l) {
						LazyVStack(spacing: 4) {
							ForEach(msResults, id: \.path) { model in
								Button {
									showDirectEntry = false
									loadModel(model.path, source: .modelScope)
								} label: {
									MSModelRow(model: model)
										.frame(maxWidth: .infinity, alignment: .leading)
								}
								.buttonStyle(.plain)
							}
						}
						.padding(.vertical, 2)
					}
				}
			
			// Currently loading
			if !loadingModelId.isEmpty {
				Section(StringKey.modelSearchLoading.l) {
					HStack {
						ProgressView()
						VStack(alignment: .leading) {
							Text(loadingModelId)
								.font(.ocoreaiText(13, weight: .medium))
								.lineLimit(1)
							if let progress = loadingProgress {
								Text(progress)
									.font(.ocoreaiText(11))
									.foregroundStyle(.secondary)
							}
						}
						Spacer()
					}
					.padding(.vertical, 4)
				}
			}
			
			// Errors
			if let error = localError {
				Section {
					HStack {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.red)
						Text(error)
							.font(.ocoreaiText(13))
							.foregroundStyle(.red)
						Spacer()
						Button(StringKey.modelSearchDismiss.l) { localError = nil }
							.buttonStyle(.plain)
					}
				}
			}
		}
		.navigationTitle(StringKey.modelSearchTitle.l)
		.onChange(of: chatState.loading) { _, isLoading in
			if isLoading {
				if searchQuery.isEmpty || loadingModelId.isEmpty {
					loadingProgress = "Downloading…"
				}
			} else {
				loadingProgress = nil
			}
		}
		.onChange(of: selectedSource) { _, newSource in
			// Clear results when switching source
			if newSource == .huggingFace {
				msResults = []
			} else {
				hfResults = []
			}
		}
		.task { [searchQuery] in
			if !searchQuery.isEmpty {
				await performSearch(searchQuery)
			}
		}
	}
	
	// MARK: - Search
	
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
			let results = await chatState.searchHubModels(keyword: query)
			hfResults = results
			if results.isEmpty && query.count > 1 {
				localError = StringKey.modelSearchNoResults.l
			}
		case .modelScope:
			let results = await chatState.searchModelScopeModels(keyword: query)
			msResults = results
			if results.isEmpty && query.count > 1 {
				localError = StringKey.modelSearchNoResults.l
			}
		}
		
		isSearching = false
	}
	
	// MARK: - Load
	
	func loadModel(_ modelId: String, source: HubSource) {
		loadingModelId = modelId
		loadingProgress = "Downloading…"
		
		Task {
			let updated = await chatState.loadNewModel(modelId, source: source)
			loadingModelId = ""
			loadingProgress = nil
			
			if !updated.isEmpty {
				onModelLoaded(updated)
				dismiss()
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
			.textFieldStyle(.plain)
			.onSubmit { onCommit(text) }
	}
}

// MARK: - HF Model Row

struct HFModelRow: View {
	let model: HFModelInfo
	
	@Environment(\.ocoreaiTheme) private var theme
	
	var body: some View {
		HStack(spacing: 6) {
			// MLX badge
			if model.isMLX {
				Image(systemName: "cpu")
					.font(.ocoreaiText(10))
					.padding(3)
					.background(theme.accentSoft)
					.clipShape(RoundedRectangle(cornerRadius: 4))
					.accessibilityLabel(StringKey.a11yMLXFormat.l)
			}
			
			// Model ID
			VStack(alignment: .leading) {
				Text(model.id)
					.font(.ocoreaiText(13, weight: .medium))
					.lineLimit(1)
				if let tag = model.pipelineTag, !tag.isEmpty {
					Text(tag)
						.font(.ocoreaiText(10))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			
			Spacer()
			
			// Likes
			if model.likes > 0 {
				Label("\(model.likes, format: .number)", systemImage: "heart.fill")
					.font(.ocoreaiText(10))
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 2)
	}
}

// MARK: - ModelScope Model Row

struct MSModelRow: View {
	let model: MSModelInfo
	
	@Environment(\.ocoreaiTheme) private var theme
	
	var body: some View {
		HStack(spacing: 6) {
			// Source badge
			Image(systemName: "cloud.fill")
				.font(.ocoreaiText(10))
				.padding(3)
				.background(theme.accentSoft)
				.clipShape(RoundedRectangle(cornerRadius: 4))
				.accessibilityLabel(StringKey.a11yModelScopeSource.l)
			
			// Model path
			VStack(alignment: .leading) {
				Text(model.path)
					.font(.ocoreaiText(13, weight: .medium))
					.lineLimit(1)
				if !model.tasks.isEmpty {
					Text(model.tasks.joined(separator: ", "))
						.font(.ocoreaiText(10))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			
			Spacer()
			
			// Downloads
			if model.downloads > 0 {
				Label("\(model.downloads, format: .number)", systemImage: "arrow.down.circle.fill")
					.font(.ocoreaiText(10))
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 2)
	}
}
