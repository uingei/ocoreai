// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Chat ViewModel — manages streaming, loading/error states, and message history.
///
/// @Observable: property-level change tracking.
/// Fast Path: SwiftUI → DirectInferenceClient → EnginePool (zero HTTP).
/// Single source of truth for engine readiness: OcoreaiEngine.shared.engineReady.
///
/// ### Persistence (Phase 1 P0-1 fix):
/// - Every user/assistant message is persisted to SQLite via SessionCompressor.
/// - Session is created/reused per (modelId) pair.
/// - On `start()`, historical messages for the last-used session are loaded from SQLite.
/// - On `resetConversation()`, the session is cleared and a new one is created.

import Foundation
import Logging
import Observation
import SwiftUI

// MARK: - Chat Message

/// Unified hub source for model search (HF vs ModelScope)
enum HubSource: String, CaseIterable {
    case huggingFace = "HuggingFace"
    case modelScope = "ModelScope"
}

// Note: HFModelInfo and MSModelInfo have been replaced by HFHubModel and MSHubModel
// from HuggingFaceSearchClient and ModelScopeSearchClient respectively.

/// ChatMessage — UI-layer message type with optional structured content.
///
/// Design:
/// - `content: String` — flat text (legacy, SQLite-compatible, streaming accumulation)
/// - `parts: [TranscriptPart]?` — structured semantic blocks (text/reasoning/toolCall/image)
///   When present, `parts` is the source of truth for rendering; `content` is a fallback.
///
/// Backward compat: messages from DB restore or legacy code still set `content` only.
/// New code should populate `parts` when available (e.g., AgentLoop tool call logs,
/// reasoning traces). The `textContent` computed property joins parts into a flat
/// string for persistence and fallback rendering.
struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let role: String
    let content: String /// Flat text — legacy + SQLite-compatible + streaming fallback
    let parts: [TranscriptPart]? /// Structured content — source of truth when present
    let timestamp: Date
    let imageURLs: [String] /// Base64 data URLs for inline preview
    let interrupted: Bool /// true when truncated by user cancel — used for context filtering, not string suffix check

    /// Plain-text representation joining all parts for persistence and fallback.
    /// Uses the same logic as TranscriptPartMessage.flatText so textContent == content
    /// when only text-only parts are present — the behavioral invariant from 2026-07-13.
    var textContent: String {
        if let partsParts = parts {
            return TranscriptPartMessage(texts: partsParts).flatText
        }
        return content
    }

    /// Whether this message has structured semantic parts for rich rendering.
    var hasParts: Bool {
        parts != nil && !(parts?.isEmpty ?? true)
    }

    /// Legacy initializer — sets flat content only (for SQLite restore, streaming)
    init(role: String, content: String, timestamp: Date = .now, imageURLs: [String] = []) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.imageURLs = imageURLs
        parts = nil
        self.interrupted = false
    }

    /// Structured initializer — builds parts from semantic blocks
    init(role: String, parts: [TranscriptPart], timestamp: Date = .now) {
        self.role = role
        self.content = TranscriptPartMessage(texts: parts).flatText // fallback for persistence
        self.parts = parts
        self.timestamp = timestamp
        self.imageURLs = []
        self.interrupted = false
    }

    /// Interrupted initializer — for truncated assistant messages
    init(role: String, content: String, interrupted: Bool) {
        self.role = role
        self.content = content
        self.timestamp = .now
        self.imageURLs = []
        parts = nil
        self.interrupted = interrupted
    }
}

/// Helper to flatten TranscriptPart array into a plain string for compatibility.
private struct TranscriptPartMessage {
    let texts: [TranscriptPart]

    var flatText: String {
        texts.compactMap {
            switch $0 {
            case .text(let t): return t
            case .reasoning(let r): return r
            case .toolCall(let tc): return "[Tool: \(tc.name): \(tc.resultSummary ?? "")]"
            case .image: return nil
            }
        }.joined(separator: " ")
    }
}

// MARK: - Chat State

@Observable
@MainActor
final class ChatState {
    /// Logger for persistence operations
    private static let logger = Logger(label: "ocoreai.chat")

    /// Shared singleton — survives view recreation (tab switch, NavigationSplitView).
    /// Accessed as `@State initial: ChatState.shared` in ChatView to hold the
    /// @Observable reference — mutation tracking works through the singleton's identity.
    static let shared = ChatState()
    private init() {}

    var messages: [ChatMessage] = []
    var responseText: String = ""
    /// Display version — strips <thinking> tags so the live streaming preview
    /// doesn't render raw reasoning markup. Raw responseText kept for completion-time structured parsing.
    var responseTextDisplay: String {
        Self.stripThinkingTags(from: responseText)
    }
    var errorMessage: String?
    var loading: Bool = false
    /// Live streaming throughput — estimated tokens/second. Updated per chunk.
    var currentTokPerSec: Double?
    /// Live streaming time-to-first-token (ms). Set on first chunk.
    var currentTTFTMs: Double?

    // Single source of truth — no separate health polling task
    var connected: Bool {
        OcoreaiEngine.shared.engineReady
    }



    /// Strip `<thinking>...</thinking>` blocks so they don't appear in the live preview.
    /// Raw text retained for completion-time structured parsing.
    private nonisolated static func stripThinkingTags(from text: String) -> String {
        guard text.contains("<thinking>") else { return text }
        let pattern = "<thinking>.*?</thinking>"
        return (try? NSRegularExpression(
            pattern: pattern,
            options: .dotMatchesLineSeparators
        ).stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )) ?? text
    }

    /// Extract reasoning text from `<thinking>` tags and remaining text.
    /// Returns (reasoning, remainingText). If no tags found, returns (nil, text).
    private nonisolated static func splitThinkingTags(from text: String) -> (reasoning: String?, remaining: String) {
        guard text.contains("<thinking>") else { return (nil, text) }
        var reasoningPieces: [String] = []
        let pattern = "<thinking>(.*?)</thinking>"
        if let regex = try? NSRegularExpression(
            pattern: pattern,
            options: .dotMatchesLineSeparators
        ) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            // Extract reasoning content
            for match in matches {
                if let range = Range(match.range(at: 1), in: text) {
                    reasoningPieces.append(String(text[range]))
                }
            }
            // Remove thinking tags for remaining text
            let cleaned = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
            return (reasoningPieces.joined(separator: "\n"), cleaned)
        }
        return (nil, text)
    }

    // MARK: - Persistence state

    /// SQLite-backed session ID for the current conversation.
    /// nil means no session yet (will be created on first chat).
    private var sessionId: Int64?

    /// Stable UUID string passed to InferenceRequest.sessionId.
    /// P0-fix: persists across multiple chat() calls within the same conversation,
    /// so ThinkingBudget adaptive calibration and ComplexityAnalyzer tracking actually work.
    private var inferenceSessionId: String?

    /// Current model for session scoping.
    private var activeModelId: String?

    /// SessionCompressor accessor — nil when engine not booted.
    private var compressor: SessionCompressor? {
        OcoreaiEngine.shared.activeSessionCompressor
    }

    // MARK: - Cancellation (P0-3: mid-stream interrupt)

    /// Cancellation token for the active inference stream.
    /// When non-nil, a stream is in progress and can be cancelled.
    private var currentCancellation: InferenceCancellation?

    /// P0-fix: Idempotency barrier — `cancelInference()` appends the interrupted message
    /// and clears it; the stream tail check must NOT append again.
    /// internal (not private) so @testable import can reset it for test isolation.
    internal var _cancelledByUI = false
    
    // MARK: - Message filtering (exposed for test coverage)

    /// Filter out system messages and interrupted assistant messages.
    /// Same predicate used by `chat()` before sending to inference engine.
    /// internal (not private) so @testable import can exercise the real predicate.
    internal func cleanMessages(_ msgs: [ChatMessage]) -> [ChatMessage] {
        msgs.filter {
            $0.role != "system"
            && !($0.role == "assistant" && $0.interrupted)
        }
    }

    /// Cancel the current inference stream immediately.
    /// Safe to call multiple times and when no stream is active.
    func cancelInference() {
        guard !_cancelledByUI else { return }  // idempotent — prevents double-appended interrupted messages
        _cancelledByUI = true
        currentCancellation?.cancel()
        currentCancellation = nil
        loading = false

        // P0-3 UX: Preserve the partial response instead of instantly blanking the screen.
        // The user can still see what was generated before interruption.
        if !responseText.isEmpty {
            messages.append(ChatMessage(role: "assistant", content: responseText, interrupted: true))
            responseText = ""
        }
    }

    // MARK: - Model lifecycle (P0-2: hot-switch)

    /// Called when the user switches the model selector.
    /// Unloads the old model from EnginePool to free GPU memory.
    ///
    /// P1-fix: Serialize unload tasks — rapid model switching spawned orphan Tasks
    /// that could concurrently modify EnginePool.loadedModels.
    private var pendingUnloadTask: Task<Void, Error>?
    
    func onModelChanged(newModelId: String) {
        // Cancel any in-flight inference before switching
        cancelInference()
        
        // Cancel previous unload that hasn't finished yet
        pendingUnloadTask?.cancel()
        pendingUnloadTask = nil
        
        // Unload the old model if it differs from the new one
        if let oldModel = activeModelId, oldModel != newModelId {
            // P1-fix: Asynchronous model cleanup — unload old model, reset session
            // for new model, but preserve UI message history for conversation continuity.
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                // Unload old model from GPU
                if let pool = OcoreaiEngine.shared.activeEnginePool {
                    await pool.unloadModel(oldModel)
                }
                // Create new SQLite session for the new model
                if let sc = OcoreaiEngine.shared.activeSessionCompressor {
                    do {
                        self.sessionId = try await sc.createSession(modelId: newModelId)
                    } catch {
                        Self.logger.warning("Model switch: failed to create session: \(error.localizedDescription)")
                    }
                }
                self.activeModelId = newModelId
                self.inferenceSessionId = "chat-\(UUID().uuidString.prefix(8))"
                // P1-fix: Clear only the streaming response text — preserve messages
                self.responseText = ""
            }
        }
    }

    // MARK: - Undo support

    /// Snapshot capture before destructive operations (max one level).
    private var undoSnapshot: [ChatMessage]?
    private var undoResponseText: String?
    /// Undo snapshot: error message text
    private var undoErrorMessage: String?
    /// Undo snapshot: session state
    private var undoSessionId: Int64?
    private var undoActiveModelId: String?

    /// Returns true if there is an undoable action available.
    var hasUndo: Bool {
        undoSnapshot != nil
    }

    // MARK: - Lifecycle

    /// Start session: load historical messages from SQLite for the last-used session.
    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await loadHistory()
        }
    }

    /// Stop streaming inference and cancel in-flight work.
    /// Called from ChatView.onDisappear to clean up resources on tab switch.
    func stop() {
        cancelInference()
    }

    // MARK: - Persistence

    /// Load messages from SQLite for the current session (if any).
    /// Idempotent — skips if messages already present (singleton survived view recreation).
    private func loadHistory() async {
        // Skip reload if messages already in memory
        guard messages.isEmpty else { return }
        guard let compressor, let sid = sessionId else { return }
        do {
            // P0-fix: cap at hotWindow to prevent loading entire session into UI memory
            let hotWindowLimit = compressor.hotWindow
            let dbMessages = try await compressor.getMessages(sid, limit: hotWindowLimit, offset: 0)
            // Messages come in reverse chronological order from DB — reverse for display
            let chronMessages = dbMessages.reversed().map { fromMessageModel($0) }
            messages = chronMessages
        } catch {
            // Non-fatal: fall back to empty in-memory state
            Self.logger.warning("Failed to load chat history: \(error.localizedDescription)")
        }
    }

    /// Create or reuse a persistent session for the given model.
    /// Reuses existing session if the model hasn't changed.
    private func ensureSession(for modelId: String) async {
        guard let compressor else { return }
        if sessionId != nil, activeModelId == modelId {
            return // Session already exists for this model
        }
        do {
            // Clean up old session model association before creating new one
            activeModelId = modelId
            sessionId = try await compressor.createSession(modelId: modelId)
            // P0-fix: Create a stable inference session UUID that persists across
            // multiple chat() calls — ThinkingBudget adaptive calibration requires
            // a consistent key to accumulate quality multipliers.
            inferenceSessionId = "chat-\(UUID().uuidString.prefix(8))"
        } catch {
            // Non-fatal: continue with in-memory mode
            Self.logger.warning("Failed to create session: \(error.localizedDescription)")
        }
    }

    /// Persist a single message to SQLite.
    /// - Parameter parts: Optional structured parts — reasoning text and tool call records
    ///   are stored alongside the flat content for faithful round-trip persistence.
    private func persistMessage(
        role: String,
        content: String,
        toolCalls: [ToolCallRecord]? = nil
    ) async {
        guard let compressor, let sid = sessionId else { return }
        do {
            _ = try await compressor.addMessage(
                sessionId: sid,
                role: role,
                content: content,
                tokenCount: estimateTokens(content),
                toolCalls: toolCalls
            )
        } catch {
            // Non-fatal: message still exists in memory
            Self.logger.warning("Failed to persist \(role) message: \(error.localizedDescription)")
        }
    }

    /// Rough token estimate: ~4 chars per token for English, ~2 for CJK.
    /// Internal (not private) so @testable import can exercise the real formula.
    /// P2-fix: CJK-aware estimation — Chinese/Japanese/Korean chars are 3 bytes in UTF-8
    /// but represent ~1.5-2 chars per token, not 4 bytes per token like English.
    internal nonisolated func estimateTokens(_ text: String) -> Int {
        let utf16Count = text.utf16.count
        // Swift String indexing uses UTF-16 code units, which maps closely to
        // grapheme clusters for CJK (1 UTF-16 per CJK char) and handles emoji.
        // ~3.5 UTF-16 units per token is a reasonable heuristic across EN/CJK mix
        return max(1, utf16Count / 3)
    }

    /// Convert DB MessageModel to our ChatMessage.
    private nonisolated func fromMessageModel(_ mm: MessageModel) -> ChatMessage {
        ChatMessage(role: mm.role, content: mm.content, timestamp: mm.createdAt)
    }

    // MARK: - Chat (Fast Path)

    /// User-provided image attachment for multimodal input.
    struct AttachedImage: Identifiable {
        let id = UUID()
        let dataURL: String /// Base64 data URL (data:image/png;base64,...)
    }

    /// Send chat message via Fast Path — bypasses HTTP entirely.
    ///
    /// Flow: ChatMessage → multimodal context capture → Message (typed, may include
    ///       image parts) → DirectInferenceClient.stream()
    ///       → EnginePool.acquire() → generateFromMessages()
    ///       → AsyncStream<InferenceEvent> → UI update → TTS (if speaker enabled)
    ///
    /// Multimodal integration:
    /// - If camera/screen capture is enabled, visual context is captured before inference
    ///   and injected as ContentPart.imageUrl parts in the user message.
    /// - If speaker is enabled, the final response is spoken via AudioIO TTS.
    /// - User-provided image attachments (via attach button) are merged as ContentPart.imageUrl
    ///
    /// Fix: Filter out interrupted assistant messages from the inference context.
    /// Interrupted messages (truncated by user cancel) are kept in UI history
    /// for display but excluded from the model's conversation context to prevent
    /// degraded inference quality from partial responses.
    ///
    /// FIX: Use structured .interrupted flag instead of string suffix matching
    /// — avoids collision when the model legitimately outputs " [Interrupted]".
    func chat(_ text: String, model: String, attachments: [AttachedImage] = []) async {
        // Ensure persistent session exists
        await ensureSession(for: model)

        // MARK: - Multimodal context capture
        // Capture visual context (camera + screen) if enabled before inference
        // OCR bridge: camera frames with significant OCR text are sent as structured
        // text (~20 tokens) instead of images (~800 tokens), saving ~97% VLM tokens.
        let mmState = MultimodalState.shared
        let mmContext = await mmState.captureContext()

        // Merge user attachment images into multimodal context
        var allContext = mmContext
        for att in attachments {
            allContext.append(MultimodalState.MMContextEntry(
                name: "attachment", dataURL: att.dataURL, ocrText: nil
            ))
        }

        // Push and persist user message (text only for persistence)
        // Store attachment data URLs for inline preview
        let attachmentURLs = attachments.map { $0.dataURL }
        let userMsg = ChatMessage(role: "user", content: text, imageURLs: attachmentURLs)
        messages.append(userMsg)
        await persistMessage(role: "user", content: text)

        responseText = ""
        loading = true
        errorMessage = nil
        // P0-fix: reset idempotency barrier so cancelInference can fire clean this turn
        _cancelledByUI = false

        // P0-3: Create cancellable token for mid-stream interrupt
        let cancellation = InferenceCancellation.cancellable()
        currentCancellation = cancellation

        do {
        // Build InferenceRequest — exclude interrupted assistant messages and system messages.
        // cleanMessages delegates to the same predicate exposed for test coverage.
        let cleanMsgs = cleanMessages(messages)

        // P1-fix: Extract system messages from cleanMessages so they reach the engine
        // via the systemPrompt path (MessageBuilderContext.userSystemPrompt).
        // cleanMessages strips them, but they still carry the conversation's system instructions.
        let systemMessages = messages.filter { $0.role == "system" }
        let systemPrompt = systemMessages.map { $0.content }.joined(separator: "\n")

        // Convert to typed Messages — last user message gets multimodal parts if available
        // OCR bridge: mmContext entries with OCR text are injected as text parts,
        // image entries as image_url parts, saving ~97% tokens for text-rich frames.
        let typedMessages: [Message] = {
            var result: [Message] = []
            let count = cleanMsgs.count
            for (idx, msg) in cleanMsgs.enumerated() {
                // If this is the last user message AND we have multimodal context,
                // inject context as ContentPart text/image parts
                let isLastUserMsg = (msg.role == "user") && (idx == count - 1) && !allContext.isEmpty
                if isLastUserMsg {
                    var parts: [ContentPart] = [ContentPart(type: "text", text: msg.content, imageUrl: nil)]
                    for ctx in allContext {
                        // OCR bridge: if OCR text exists, send as text part
                        if let ocrText = ctx.ocrText, !ocrText.isEmpty {
                            parts.append(ContentPart(
                                type: "text",
                                text: "[Camera OCR: \(ocrText)]",
                                imageUrl: nil
                            ))
                        } else if let url = ctx.dataURL {
                            parts.append(ContentPart(
                                type: "image_url",
                                text: nil,
                                imageUrl: ContentPart.ImageURL(url: url)
                            ))
                        }
                    }
                    result.append(Message(role: "user", content: .parts(parts)))
                } else {
                    result.append(Message(role: msg.role, content: .text(msg.content)))
                }
            }
            return result
        }()

            let request = InferenceRequest(
                modelId: model,
                messages: typedMessages,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                sessionId: inferenceSessionId ?? "chat-\(UUID().uuidString.prefix(8))",
                cancellation: cancellation,
            )

            // Stream via Fast Path
            for await chunk in try await DirectInferenceClient.shared.stream(request: request) {
                // P0-3: respect cancellation from both the token and outer Task
                guard !cancellation.isCancelled, !Task.isCancelled else { break }
                // Wire live metrics to ChatState so the UI can display them
                if let ttft = chunk.ttftMs {
                    currentTTFTMs = ttft
                }
                if let tokPerSec = chunk.tokPerSec {
                    currentTokPerSec = tokPerSec
                }
                if !chunk.text.isEmpty {
                    responseText += chunk.text
                }
                if chunk.isComplete {
                    // FIX: distinguish error terminal chunks from successful completion.
                    // Do not persist error-truncated responses as normal assistant messages.
                    if chunk.stopReason == "error" {
                        Self.logger.warning("Inference ended with error after accumulating \(responseText.utf8.count) bytes")
                        // D1 fix: surface actual error from inference layer instead of generic placeholder
                        errorMessage = chunk.error ?? StringKey.generationFailed.l
                        responseText = ""
                    } else {
                        // Conversation complete — build structured parts from responseText.
                        // P0-1 fix: Always enter this branch (even when responseText is empty)
                        // so tool-call-only models and empty outputs still get an assistant message.
                        // P0-2 fix: Split <thinking> tags into structured .reasoning parts.

                        let (reasoning, cleanedText) = Self.splitThinkingTags(from: responseText)
                        var parts: [TranscriptPart] = []

                        // Append reasoning part if thinking tags were present
                        if let reasoningText = reasoning, !reasoningText.isEmpty {
                            parts.append(.reasoning(reasoningText))
                        }

                        // Append text body (with thinking tags removed)
                        if !cleanedText.trimmingCharacters(in: .whitespaces).isEmpty {
                            parts.append(.text(cleanedText))
                        }

                        // Detect tool calls in raw response
                        let detectedToolCalls = parseToolCalls(from: responseText)
                        if let tcs = detectedToolCalls {
                            for tc in tcs {
                                parts.append(.toolCall(ToolCallPart(
                                    callId: tc.id,
                                    name: tc.function.name,
                                    resultSummary: tc.function.arguments.isEmpty ? "executed" : "\(tc.function.arguments.utf8.count) bytes args",
                                    durationMs: nil
                                )))
                            }
                        }

                        // Build assistant message — use structured parts when available,
                        // fallback to flat content (including empty messages for tool-use models)
                        if !parts.isEmpty {
                            let assistantMsg = ChatMessage(role: "assistant", parts: parts)
                            messages.append(assistantMsg)
                        } else {
                            // Tool-use model returned empty — still create the message
                            // so the conversation state is correct
                            let assistantMsg = ChatMessage(role: "assistant", content: "")
                            messages.append(assistantMsg)
                        }

                        // Persist cleaned text (without thinking tags) for readability.
                        // Include structured tool call records when available.
                        if !cleanedText.trimmingCharacters(in: .whitespaces).isEmpty {
                            // Convert detected ToolCall → ToolCallRecord for persistence
                            let persistToolCalls: [ToolCallRecord]? = detectedToolCalls?.compactMap { tc in
                                ToolCallRecord(
                                    callId: tc.id,
                                    toolName: tc.function.name,
                                    arguments: [String: String](),
                                    resultSummary: tc.function.arguments.isEmpty ? "executed" : "\(tc.function.arguments.utf8.count) bytes args",
                                    durationMs: nil
                                )
                            }
                            await persistMessage(role: "assistant", content: cleanedText, toolCalls: persistToolCalls)
                        }

                        // MARK: - Post-inference TTS
                        // If speaker is enabled, speak the cleaned response (no thinking tags)
                        if !cleanedText.trimmingCharacters(in: .whitespaces).isEmpty {
                            mmState.speakIfEnabled(cleanedText)
                        }
                    }
                }
            }
            // If interrupted mid-stream but accumulated text exists, save it.
            // P0-fix: skip if cancelInference() already ran — it appends the interrupted message
            // itself; we only reach here when the stream was cancelled without UI intervention.
            if !self._cancelledByUI && (Task.isCancelled || cancellation.isCancelled) {
                if !responseText.isEmpty {
                    let assistantMsg = ChatMessage(role: "assistant", content: responseText, interrupted: true)
                    messages.append(assistantMsg)
                    await persistMessage(role: "assistant", content: assistantMsg.content)
                }
            }
            // Finalize cancellation handle
            currentCancellation = nil
        } catch {
            self.errorMessage = error.localizedDescription
            // Clear streaming preview on error — the error banner shows the message
            responseText = ""
            currentCancellation = nil
        }
        loading = false
        currentTokPerSec = nil
        currentTTFTMs = nil
    }

    func loadModels() async -> [String] {
        guard let pool = OcoreaiEngine.shared.activeEnginePool else { return [] }
        let models = await pool.listModels()
        return models.map { $0["id"] ?? "unknown" }
    }
    /// Snapshot current state, then clear the conversation.
    /// Also resets SQLite session ID to prevent new messages bleeding
    /// into the old session's database record.
    func resetConversation() {
        // P2-fix: cap undo snapshot to last 50 messages — prevents holding entire
        // conversation in memory when user clears a long-running session
        let maxUndoMessages = 50
        undoSnapshot = Array(messages.suffix(maxUndoMessages))
        undoResponseText = responseText
        undoErrorMessage = errorMessage
        // Save session state for undo
        undoSessionId = sessionId
        undoActiveModelId = activeModelId
        messages = []
        responseText = ""
        errorMessage = nil
        // FIX: clear session state to prevent DB session bleed
        sessionId = nil
        activeModelId = nil
        // P0-fix: reset idempotency barrier so cancelInference can fire clean this turn
        _cancelledByUI = false
        // Register undo with AppState for Cmd+Z access
        AppState.shared.undoAction = { [weak self] in self?.undoReset() }
    }

    /// Restore from the last snapshot if one exists.
    func undoReset() {
        guard let snapshot = undoSnapshot else { return }
        messages = snapshot
        responseText = undoResponseText ?? ""
        errorMessage = undoErrorMessage
        // Restore session state
        sessionId = undoSessionId
        activeModelId = undoActiveModelId
        undoSnapshot = nil
        undoResponseText = nil
        undoErrorMessage = nil
        undoSessionId = nil
        undoActiveModelId = nil
    }
    
    /// Reset all internal state to initial values — exhaustive cleanup for test isolation.
    /// Internal (not private) so @testable import in tests can use it.
    internal func resetForTesting() {
        // Cancel any in-flight operations
        pendingUnloadTask?.cancel()
        pendingUnloadTask = nil
        currentCancellation = nil
        // Clear all mutable state
        messages = []
        responseText = ""
        errorMessage = nil
        loading = false
        _cancelledByUI = false
        // Persistence state
        sessionId = nil
        activeModelId = nil
        // Undo state
        undoSnapshot = nil
        undoResponseText = nil
        undoErrorMessage = nil
        undoSessionId = nil
        undoActiveModelId = nil
        // Disconnect undo from AppState to prevent stale captures
        AppState.shared.undoAction = nil
    }
}
