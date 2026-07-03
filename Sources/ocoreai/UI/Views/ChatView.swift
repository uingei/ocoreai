// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatView — streaming chat with model selector, mid-stream interrupt, suggestion chips
/// omlx pattern: ViewModel + .task{await vm.load()} + ViewState state machine
/// Theme-driven: all colors resolve through @Environment(\.ocoreaiTheme)
/// @Observable pattern: @State + Observable instead of @StateObject
/// Accessibility: full VoiceOver support, Dynamic Type, reduced motion
/// Accessibility: ChatBubble uses accessibilityGroup() for semantic hierarchy
/// Reduced Motion: all animations respect .accessibilityReduceMotion

import AppKit
import SwiftUI

/// Stable identity wrapper for chat messages — uses UUID string for deterministic identity
struct ChatBubbleMessage: Identifiable, Hashable {
	let id: String // stable UUID-based identity
	let role: String
	let content: String
	let timestamp: Date

	init(id: String, role: String, content: String, timestamp: Date) {
		self.id = id
		self.role = role
		self.content = content
		self.timestamp = timestamp
	}
}

struct ChatView: View {
	@State private var chatState: ChatState
	// Note: ModelManager is accessed via .shared singleton to avoid dual @State binding
	// of the same @Observable instance (SwiftUI observation reader collision → crash)
	@Environment(\.ocoreaiTheme) private var theme
	@State private var inputText = ""
	@State private var currentModel = ""
	@State private var activeTask: Task<Void, Never>? = nil


	// Multimodal controls panel — collapsed by default
	@State private var showMultimodal = false

	init() {
		_chatState = State(initialValue: ChatState.shared)
	}

	private var isStreaming: Bool {
		// Use loading as the primary signal — activeTask is only for cancellation
		chatState.loading
	}

	private var isConnected: Bool {
		chatState.connected
	}

	private var models: [String] {
		ModelManager.shared.modelIdStrings()
	}

	var body: some View {
		VStack(spacing: 0) {
			chatHeader
			Divider().accessibilityHidden(true)
			messageList
			if showMultimodal {
				Divider().accessibilityHidden(true)
				MultimodalControls()
					.padding(.horizontal)
					.padding(.top, 4)
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
			inputBar
		}
		.background(theme.windowBg)
		// omlx .task{} lifecycle: start health polling + load models
		.task {
			chatState.start()
			await ModelManager.shared.loadModels()
			let idStrings = ModelManager.shared.modelIdStrings()
			if idStrings.isEmpty {
				// No local models yet — use configured default model ID
				currentModel = OcoreaiEngine.shared.activeEnginePool?.config.defaultModelId ?? ""
			} else {
				currentModel = idStrings.first ?? ""
			}
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
					// B4: model search/load moved to Models tab
					Divider()
					Button(StringKey.defaultModel.l) { currentModel = "" }
				} label: {
					Label(
						currentModel.isEmpty ? StringKey.noModelSelected.l : currentModel,
						systemImage: "brain",
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
		// P0: Show error banner when chat inference fails
		.overlay(alignment: .bottom) {
			if let errorMsg = chatState.errorMessage {
				HStack(spacing: 8) {
					Text(errorMsg)
						.font(.ocoreaiText(12))
						.foregroundStyle(.red)
						.lineLimit(3)
					Spacer()
					Button {
						chatState.errorMessage = nil
					} label: {
						Image(systemName: "xmark.circle.fill")
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Dismiss error")
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(theme.cardBg.opacity(0.95))
				.clipShape(RoundedRectangle(cornerRadius: 8))
				.padding(.bottom, 8)
				.accessibilityLabel(StringKey.statusError.l)
			}
		}
		// B4 fix: removed .sheet — model search/load already available via Models tab
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
				if chatState.messages.isEmpty, chatState.responseText.isEmpty {
					emptyState
				} else {
					LazyVStack(spacing: 10) {
						ForEach(chatState.messages) { msg in
							ChatBubble(message: ChatBubbleMessage(
								id: msg.id.uuidString,
								role: msg.role,
								content: msg.content,
								timestamp: msg.timestamp,
							))
							.id(msg.id)
						}
						// Streaming preview — show assistant's partial response in real-time
						if !chatState.responseText.isEmpty {
							streamingPreview
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
			id: "_streaming", // stable placeholder identity for streaming preview
			role: "assistant",
			content: chatState.responseText,
			timestamp: Date(),
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
				.padding()

			LazyVStack(spacing: 8) {
				suggestionChip(StringKey.chatSuggestionExplainMlx.l)
				suggestionChip(StringKey.chatSuggestionCompareCoreAi.l)
				suggestionChip(StringKey.chatSuggestionDebugSwiftui.l)
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
				showMultimodal.toggle()
			} label: {
				Image(systemName: "waveform")
					.font(.title3)
					.foregroundStyle(showMultimodal ? theme.accent : theme.textSecondary)
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
						.stroke(theme.inputBorder.opacity(0.5), lineWidth: 0.5),
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
		let modelID = currentModel.isEmpty
			? OcoreaiEngine.shared.activeEnginePool?.config.defaultModelId ?? ""
			: currentModel

		// Use regular Task (not detached) so cancellation propagates
		// and MainActor context is captured for updating chatState
		// Reset activeTask on completion so isStreaming unblocks future sends
		activeTask = Task { @MainActor in
			await chatState.chat(text, model: modelID)
			activeTask = nil
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

	private var isUser: Bool {
		message.role == "user"
	}

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
						isUser ? theme.accentSoft : theme.cardBg,
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
