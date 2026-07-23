// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatView — streaming chat with model selector, mid-stream interrupt, suggestion chips
/// ViewModel + .task{await vm.load()} + ViewState state machine
/// Theme-driven: all colors resolve through @Environment(\.ocoreaiTheme)
/// @Observable pattern: @State + Observable instead of @StateObject
/// Accessibility: full VoiceOver support, Dynamic Type, reduced motion
/// Accessibility: ChatBubble uses accessibilityGroup() for semantic hierarchy
/// Reduced Motion: all animations respect .accessibilityReduceMotion

import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Stable identity wrapper for chat messages — uses UUID string for deterministic identity
///
/// Mirrors ChatMessage structure: flat `content` for compatibility + optional `parts`
/// for structured rendering (text/reasoning/toolCall/image segments).
///
/// `displayContent` is the rendering source: uses `parts` if available, falls back to `content`.
struct ChatBubbleMessage: Identifiable, Hashable {
    let id: String // stable UUID-based identity
    let role: String
    let content: String /// Flat fallback text (compatibility + streaming)
    let parts: [TranscriptPart]? /// Structured semantic blocks
    let timestamp: Date
    let imageURLs: [String] /// Base64 data URLs for inline image preview

    /// Rendering content: structured parts preferred, flat content as fallback
    var displayContent: String {
        if let parts, !parts.isEmpty {
            return parts.compactMap {
                switch $0 {
                case .text(let t): return t
                case .reasoning(let r): return r
                case .toolCall(let tc): return "[Tool: \(tc.name)]"
                case .image: return nil
                }
            }.joined(separator: "\n")
        }
        return content
    }

    /// Has structured content for rich rendering?
    var hasParts: Bool {
        parts != nil && !(parts?.isEmpty ?? true)
    }

    init(id: String, role: String, content: String, timestamp: Date, imageURLs: [String] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.imageURLs = imageURLs
        self.parts = nil
    }

    /// Convert ChatViewModel.ChatMessage → ChatBubbleMessage (preserves parts)
    init(from cm: ChatMessage) {
        self.id = cm.id.uuidString
        self.role = cm.role
        self.content = cm.content
        self.parts = cm.parts
        self.timestamp = cm.timestamp
        self.imageURLs = cm.imageURLs
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

    // P1-fix: NSEvent monitor handle — disposed on .onDisappear to prevent leak
    #if os(macOS)
        @State private var _keyboardMonitor: Any? = nil
    #endif

    // Multimodal controls panel — collapsed by default
    @State private var showMultimodal = false

    // P2-fix: confirmation dialog for destructive operations (HIG requirement)
    @State private var showClearConfirmation = false

    // Image attachments for multimodal input
    @State private var attachments: [ChatState.AttachedImage] = []

    init() {
        _chatState = State(initialValue: ChatState.shared)
    }

    /// Dispose NSEvent monitor handle — cancels DispatchSource to break RC cycle on tab switch
    private func disposeKeyboardMonitor() {
        #if os(macOS)
            if let monitor = self._keyboardMonitor as? DispatchSource {
                monitor.cancel()
            }
            self._keyboardMonitor = nil
        #endif
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
        // .task{} lifecycle: start health polling + load models
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
        // P1-fix: dispose keyboard monitor on disappear to prevent event monitor leak
        .onDisappear {
            disposeKeyboardMonitor()
            chatState.stop()
        }
        // P1-fix: dispose-before-register — rapid tab switching spawns duplicate monitors
        // that outlive the view because onDisappear never fires for the replaced view
        #if os(macOS)
        .onAppear {
            disposeKeyboardMonitor()
            _keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let cmd = event.modifierFlags.contains(.command)
                let opt = event.modifierFlags.contains(.option)
                // ⌘+Return — send message (even when TextField not focused).
                // P2 fix: use keyEquivalent instead of hardcoded keyCode (keyCode varies by layout).
                if cmd && event.characters == "\r" {
                    guard !isStreaming else { return event }
                    guard inputText.trimmingCharacters(in: .whitespaces).isEmpty else {
                        sendMessage()
                        return NSEvent()
                    }
                    return event
                }
                // ⌘+Option+M — toggle multimodal panel
                if cmd && opt, let c = event.characters {
                    if c.lowercased() == "m" {
                        showMultimodal.toggle()
                        return NSEvent()
                    }
                }
                return event
            }
        }
        #endif
        // P1-fix: observe session selection from Session tab — reload chat when user switches
        .onChange(of: SessionManager.shared.selectedSession?.id) { _, newSessionId in
            if let newId = newSessionId {
                if let session = SessionManager.shared.sessions.first(where: { $0.id == newId }) {
                    Task { @MainActor in
                        await chatState.reloadSession(for: session)
                    }
                }
            }
        }
        // Voice loop: observe MultimodalState.pendingVoiceTranscript via @Observable —
        // replaces NotificationCenter (P0-fix: cross-module coupling through @Observable singleton)
        #if os(macOS)
        .onChange(of: MultimodalState.shared.pendingVoiceTranscript) { _, transcript in
            if let transcript, !transcript.isEmpty {
                sendVoiceMessage(transcript)
            }
        }
        #endif
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

            // HIG-02: destructive non-modal operations shouldn't be in .primaryAction —
            // .automatic is the neutral placement for secondary/destructive toolbar items
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label(StringKey.clear.l, systemImage: "trash")
                }
                .accessibilityLabel(StringKey.clearConversationLabel.l)
                .accessibilityHint(StringKey.clearConversationHint.l)
                .disabled(isStreaming)
            }
        }
        // P2-fix: confirmation dialog for clear conversation (HIG: destructive actions must confirm)
        .confirmationDialog(StringKey.clearConversationTitle.l,
                           isPresented: $showClearConfirmation,
                           titleVisibility: .visible) {
            Button(StringKey.clearAllAction.l, role: .destructive) {
                chatState.resetConversation()
            }
            Button(StringKey.cancelButton.l, role: .cancel) {}
        } message: {
            Text(StringKey.clearConversationMessage.l)
        }
        // P0: Show error banner when chat inference fails
        .overlay(alignment: .bottom) {
            if let errorMsg = chatState.errorMessage {
                HStack(spacing: 8) {
                    Text(errorMsg)
                        .font(.ocoreaiText(12))
                        .foregroundStyle(theme.redDot)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        chatState.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(StringKey.dismissError.l)
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
            let targetModel = newModel.isEmpty
                ? OcoreaiEngine.shared.activeEnginePool?.config.defaultModelId ?? ""
                : newModel
            guard !targetModel.isEmpty else { return }
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
                            ChatBubble(message: ChatBubbleMessage(from: msg))
                                .id(msg.id)
                        }
                        // Streaming preview — show assistant's partial response in real-time.
                        // P0-2 fix: use responseTextDisplay (strips <thinking> tags) so raw
                        // reasoning markup doesn't render in the live preview.
                        if !chatState.responseTextDisplay.isEmpty {
                            VStack(spacing: 4) {
                                ChatHeader(isUser: false, timestamp: Date())
                                MarkdownMessage(content: chatState.responseTextDisplay)
                                    .opacity(0.85)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                // Live streaming metrics indicator
                                if isStreaming {
                                    HStack(spacing: 8) {
                                        if let tok = chatState.currentTokPerSec {
                                            Text("\(String(format: "%.1f", tok)) tok/s")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(theme.textTertiary)
                                        }
                                        Divider().frame(height: 12)
                                        if let ttft = chatState.currentTTFTMs {
                                            Text("TTFT \(String(format: "%.0f", ttft))ms")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(theme.textTertiary)
                                        }
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .padding()
                            .accessibilityLabel(StringKey.assistantTyping.l)
                            .accessibilityHidden(false)
                        } else if isStreaming {
                            // No text yet — show typing indicator dots
                            HStack {
                                Spacer(minLength: 26) // Align with assistant avatar
                                TypingIndicator()
                            }
                            .padding()
                            .transition(.opacity)
                            .accessibilityLabel(StringKey.assistantTyping.l)
                        }
                        // Scroll anchor for automatic scroll-to-bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
            }
            // HIG: keep scroll indicators visible so users can manually scroll
            // when not at the bottom of the chat.
            // .scrollIndicators(.automatic) is the default; we do not force .never.
            // .defaultScrollAnchor is the native SwiftUI mechanism for chat auto-scroll.
            // Applied here so the framework keeps bottom-aligned during token-by-token growth.
            // The two .onChange handlers below handle explicit state transitions
            // (new message added / responseText cleared) where the anchor alone is insufficient.
            .defaultScrollAnchor(.bottom)
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

    // P2-fix: streamingPreview dead code removed — messageList renders inline (lines 290–310)

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
        VStack(spacing: 8) {
            // Attachment preview strip — shows thumbnails of attached images
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ZStack(alignment: .topTrailing) {
                            InlineImagePreview(dataURL: attachment.dataURL)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .background(theme.inputBg)

                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.ocoreaiText(10))
                                    .foregroundStyle(theme.redDot)
                                    .background(theme.cardBg, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: 4)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .frame(height: 56)
            }

            // Main input row
            HStack(spacing: 10) {
                // Attachment button
                Button {
                    pickImages()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityLabel(StringKey.attachFiles.l)
                .accessibilityHint(StringKey.attachFilesHint.l)

                Button {
                    showMultimodal.toggle()
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                        .foregroundStyle(showMultimodal ? theme.accent : theme.textSecondary)
                }
                .accessibilityLabel(StringKey.multimodalToggleLabel.l)
                .accessibilityHint(StringKey.multimodalToggleHint.l)

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
        }
        .padding()
    }

    // MARK: - Image Picker

/// Image picker — disk I/O and compression offloaded to background to avoid main-thread blocking
    @MainActor
    private func pickImages() {
    #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK else { return }
            // P0-fix: capture URLs on main actor before detaching (panel.urls is @MainActor-isolated)
            // then offload disk I/O + CPU compression to background
            // to keep main-thread response < 100ms per Apple HIG
            let selectedURLs = panel.urls
            Task.detached(priority: .utility) {
                // P1-fix: check file size before loading — prevents OOM on large files
                // 10 MB limit: after compression this yields ~500KB per image, well within budget
                let maxFileSize = 10 * 1024 * 1024
                var attachmentsToAppend: [ChatState.AttachedImage] = []
                for url in selectedURLs {
                    do {
                        // Pre-check size without loading into memory
                        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                              let size = attrs[.size] as? Int,
                              size <= maxFileSize else {
                            // Report oversized files back on main thread
                            await MainActor.run {
                                chatState.errorMessage = String(
                                    format: StringKey.fileTooLarge.l,
                                    url.lastPathComponent
                                )
                            }
                            continue
                        }
                        let data = try Data(contentsOf: url)
                        // P1-fix: compress before base64 — keeps per-image memory under 500KB
                        // (was: raw 20MB file → 27MB base64; now: compressed ~300KB → ~400KB base64)
                        let compressed = compressImage(data)
                        attachmentsToAppend.append(ChatState.AttachedImage(
                            dataURL: "data:image/jpeg;base64,\(compressed.base64EncodedString())"
                        ))
                    } catch {
                        // Skip files that fail to read
                    }
                }
                // Batch result back to main thread
                await MainActor.run {
                    attachments.append(contentsOf: attachmentsToAppend)
                }
            }
        }
#else
        // iOS: UIImagePickerController via sheet — stub for now
#endif
    }

    // MARK: - Actions

    private func sendMessage() {
        sendVoiceMessage(inputText.trimmingCharacters(in: .whitespaces))
    }

    // Voice-to-voice: send transcript from STT — skips setting inputText
    // so the user can still type while voice loop is active
    private func sendVoiceMessage(_ text: String) {
        let hasText = !text.isEmpty
        guard (hasText || !attachments.isEmpty) && !isStreaming else { return }
        inputText = ""
        let currentAttachments = attachments
        attachments.removeAll()
        let modelID = currentModel.isEmpty
            ? OcoreaiEngine.shared.activeEnginePool?.config.defaultModelId ?? ""
            : currentModel

        // Use regular Task (not detached) so cancellation propagates
        // and MainActor context is captured for updating chatState
        // Reset activeTask on completion so isStreaming unblocks future sends
        // Pure-image send: pass empty text (no hard-coded English placeholder into
        // the user bubble / SQLite); attachment thumbnails render inline instead.
        activeTask = Task { @MainActor in
            await chatState.chat(text.isEmpty ? "" : text, model: modelID, attachments: currentAttachments)
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

                // Inline image previews (from user attachments)
                if !message.imageURLs.isEmpty {
                    imagePreview
                }

                // Structured content takes precedence over flat content
                if let parts = message.parts, !parts.isEmpty, !isUser {
                    TranscriptContentView(parts: parts, isUser: isUser)
                } else {
                    // Fallback: flat content (legacy messages + user input)
                    ChatMessageInner(text: message.displayContent, isUser: isUser)
                }
            }
            .accessibilityLabel("\(isUser ? StringKey.youLabel.l : StringKey.ocoreaiLabel.l)")
            .accessibilityValue(
                "\(message.content.prefix(200))\(message.content.count > 200 ? "…" : "") — \(message.timestamp, formatter: timeFormatter)"
            )
            .accessibilityAddTraits(.isStaticText)
            .contextMenu {
            #if os(macOS)
                Button(StringKey.copyMessage.l) {
                    NSPasteboard.general.setString(message.content, forType: .string)
                }
                if message.role == "user" {
                    Divider()
                    Button(StringKey.regenerateMessage.l) {
                        guard let uuid = UUID(uuidString: message.id) else { return }
                        ChatState.shared.resendFromMessage(with: uuid)
                    }
                }
            #else
                Button(StringKey.copyMessage.l) {
                    copyToPasteboard(message.content)
                }
                if message.role == "user" {
                    Divider()
                    Button(StringKey.regenerateMessage.l) {
                        guard let uuid = UUID(uuidString: message.id) else { return }
                        ChatState.shared.resendFromMessage(with: uuid)
                    }
                }
            #endif
            }

            if isUser { Spacer(minLength: 16) }
        }
    }

    private static let sharedTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var timeFormatter: DateFormatter {
        Self.sharedTimeFormatter
    }

    /// Inline image preview strip for data URL images
    private var imagePreview: some View {
        HStack(spacing: 6) {
            ForEach(message.imageURLs.indices, id: \.self) { index in
                let dataURL = message.imageURLs[index]
                InlineImagePreview(dataURL: dataURL)
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.textTertiary.opacity(0.3), lineWidth: 0.5),
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(false)
    }
}

/// Non-binding image preview for static data URLs (used in chat bubbles)
private struct InlineImagePreview: View {
    let dataURL: String

    var body: some View {
        Group {
            if let nsImage = dataURL.dataURLImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ChatHeader: View {
    let isUser: Bool
    let timestamp: Date

    @Environment(\.ocoreaiTheme) private var theme

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
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

// MARK: - Transcript Content View

/// Renders structured TranscriptPart messages with semantic-aware layout:
/// - `.text` → Markdown rendering (existing MarkdownMessage)
/// - `.reasoning` → Collapsible section with "thinking" label
/// - `.toolCall` → Compact badge/chip showing tool name + result
/// - `.image` → Inline image display
///
/// Matches Apple FM Transcript presentation patterns: reasoning is collapsible,
/// tool calls are informational badges, text flows through markdown rendering.
struct TranscriptContentView: View {
    let parts: [TranscriptPart]
    let isUser: Bool

    @Environment(\.ocoreaiTheme) private var theme
    @State private var expandedReasoning: Set<Int> = []

    private func toggleReasoning(_ index: Int) {
        if expandedReasoning.contains(index) {
            expandedReasoning.remove(index)
        } else {
            expandedReasoning.insert(index)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                switch part {
                case .text(let text):
                    MarkdownMessage(content: text)
                        .padding(12)
                        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 14))

                case .reasoning(let text):
                    reasoningSection(text: text, index: idx)

                case .toolCall(let tc):
                    toolCallBadge(tc)

                case .image(let url):
                    InlineImagePreview(dataURL: url)
                        .frame(height: 96)
                        .padding(.horizontal, 12)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .background(theme.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    // MARK: - Reasoning Section (Collapsible)

    @ViewBuilder
    private func reasoningSection(text: String, index: Int) -> some View {
        let isExpanded = expandedReasoning.contains(index)
        Button {
            withAnimationRespectingAccessibility { toggleReasoning(index) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Header row — always visible
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.ocoreaiText(10))
                        .foregroundStyle(theme.textTertiary)
                    Text(StringKey.systemReasoningSection.l)
                        .font(.ocoreaiText(11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.ocoreaiText(10))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(isExpanded ? .degrees(180) : .degrees(0))
                }
                // Expanded reasoning body
                if isExpanded {
                    Text(text)
                        .font(.ocoreaiText(13))
                        .foregroundStyle(theme.textSecondary)
                        .lineSpacing(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Tool Call Badge

    @ViewBuilder
    private func toolCallBadge(_ tc: ToolCallPart) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.ocoreaiText(10))
                .foregroundStyle(theme.accent)
                .frame(width: 20, height: 20)
                .background(theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(tc.name)
                    .font(.ocoreaiText(11, weight: .medium))
                    .foregroundStyle(theme.accent)
                if let summary = tc.resultSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.ocoreaiText(10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }

            if let dur = tc.durationMs, dur > 0 {
                Spacer()
                Text(String(format: "%.0fms", dur))
                    .font(.ocoreaiMono(9))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.cardBg, in: Capsule())
    }
}

// MARK: - Preview

/// #Preview requires Xcode PreviewsMacros plugin — disabled for swift build.
/// For live previews open the project in Xcode instead.
