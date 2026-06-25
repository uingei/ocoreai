// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Chat ViewModel — manages streaming, loading/error states, and message history.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
/// Fast Path: SwiftUI → DirectInferenceClient → EnginePool (zero HTTP).
/// Single source of truth for engine readiness: OcoreaiEngine.shared.engineReady.
///
/// ### Persistence (Phase 1 P0-1 fix):
/// - Every user/assistant message is persisted to SQLite via SessionCompressor.
/// - Session is created/reused per (modelId) pair.
/// - On `start()`, historical messages for the last-used session are loaded from SQLite.
/// - On `resetConversation()`, the session is cleared and a new one is created.

import Foundation
import SwiftUI
import Observation

// MARK: - Chat Message

// MARK: - HF Hub Model Info

/// Minimal model metadata from HuggingFace Hub search API.
/// Decode via CodingKeys because "private" is a Swift reserved keyword.
struct HFModelInfo: Codable, Identifiable, Sendable {
    let id: String
    var likes: Int
    
    var tags: [String]?
    var pipelineTag: String?
    
    private let isPrivate: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, likes, tags, pipelineTag
        case isPrivate = "private"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
    }
    
    /// Whether this model ships in MLX format (has "mlx" tag)
    var isMLX: Bool { tags?.contains("mlx") ?? false }
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let role: String
    let content: String
    let timestamp: Date
    
    init(role: String, content: String, timestamp: Date = .now) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Chat State

@Observable
@MainActor
final class ChatState {
    var messages: [ChatMessage] = []
    var responseText: String = ""
    var error: Error?
    var loading: Bool = false
    
    // Single source of truth — no separate health polling task
    var connected: Bool { OcoreaiEngine.shared.engineReady }
    var engineReady: Bool { OcoreaiEngine.shared.engineReady }
    
    // MARK: - Persistence state
    
    /// SQLite-backed session ID for the current conversation.
    /// nil means no session yet (will be created on first chat).
    private var sessionId: Int64? = nil
    
    /// Current model for session scoping.
    private var activeModelId: String? = nil
    
    /// SessionCompressor accessor — nil when engine not booted.
    private var compressor: SessionCompressor? { OcoreaiEngine.shared.activeSessionCompressor }
    
    // MARK: - Cancellation (P0-3: mid-stream interrupt)
    
    /// Cancellation token for the active inference stream.
    /// When non-nil, a stream is in progress and can be cancelled.
    private var currentCancellation: InferenceCancellation? = nil
    
    /// Cancel the current inference stream immediately.
    /// Safe to call multiple times and when no stream is active.
    func cancelInference() {
        currentCancellation?.cancel()
        currentCancellation = nil
        loading = false
        
        // P0-3 UX: Preserve the partial response instead of instantly blanking the screen.
        // The user can still see what was generated before interruption.
        if !responseText.isEmpty {
            messages.append(ChatMessage(role: "assistant", content: responseText + " [Interrupted]"))
            responseText = ""
        }
    }
    
    // MARK: - Model lifecycle (P0-2: hot-switch)
    
    /// Called when the user switches the model selector.
    /// Unloads the old model from EnginePool to free GPU memory.
    func onModelChanged(newModelId: String) {
        // Cancel any in-flight inference before switching
        cancelInference()
        
        // Unload the old model if it differs from the new one
        if let oldModel = activeModelId, oldModel != newModelId {
            Task {
                guard let pool = OcoreaiEngine.shared.activeEnginePool else { return }
                await pool.unloadModel(oldModel)
            }
        }
    }
    
    // MARK: - Undo support
    
    /// Snapshot capture before destructive operations (max one level).
    private var undoSnapshot: [ChatMessage]?
    private var undoResponseText: String?
    private var undoError: Error?
    
    /// Returns true if there is an undoable action available.
    var hasUndo: Bool { undoSnapshot != nil }
    
    // MARK: - Lifecycle
    
    /// Start session: load historical messages from SQLite for the last-used session.
    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadHistory()
        }
    }
    func stop() {}
    
    // MARK: - Persistence
    
    /// Load messages from SQLite for the current session (if any).
    private func loadHistory() async {
        guard let compressor, let sid = sessionId else { return }
        do {
            let dbMessages = try await compressor.getMessages(sid, limit: nil, offset: 0)
            // Messages come in reverse chronological order from DB — reverse for display
            let chronMessages = dbMessages.reversed().map { fromMessageModel($0) }
            messages = chronMessages
        } catch {
            // Non-fatal: fall back to empty in-memory state
        }
    }
    
    /// Create or reuse a persistent session for the given model.
    /// Reuses existing session if the model hasn't changed.
    private func ensureSession(for modelId: String) async {
        guard let compressor else { return }
        if sessionId != nil && activeModelId == modelId {
            return // Session already exists for this model
        }
        do {
            // Clean up old session model association before creating new one
            activeModelId = modelId
            sessionId = try await compressor.createSession(modelId: modelId)
        } catch {
            // Non-fatal: continue with in-memory mode
        }
    }
    
    /// Persist a single message to SQLite.
    private func persistMessage(role: String, content: String) async {
        guard let compressor, let sid = sessionId else { return }
        do {
            try await compressor.addMessage(
                sessionId: sid,
                role: role,
                content: content,
                tokenCount: estimateTokens(content)
            )
        } catch {
            // Non-fatal: message still exists in memory
        }
    }
    
    /// Rough token estimate: ~4 chars per token for English, ~2 for CJK.
    private nonisolated func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 3)
    }
    
    /// Convert DB MessageModel to our ChatMessage.
    private nonisolated func fromMessageModel(_ mm: MessageModel) -> ChatMessage {
        ChatMessage(role: mm.role, content: mm.content, timestamp: mm.createdAt)
    }
    
    // MARK: - Chat (Fast Path)
    
    /// Send chat message via Fast Path — bypasses HTTP entirely.
    ///
    /// Flow: ChatMessage → Message (typed) → DirectInferenceClient.stream()
    ///       → EnginePool.acquire() → generateFromMessages()
    ///       → AsyncStream<InferenceEvent> → UI update
    func chat(_ text: String, model: String) async {
        // Ensure persistent session exists
        await ensureSession(for: model)
        
        // Push and persist user message
        let userMsg = ChatMessage(role: "user", content: text)
        messages.append(userMsg)
        await persistMessage(role: "user", content: text)
        
        responseText = ""
        loading = true
        error = nil
        
        // P0-3: Create cancellable token for mid-stream interrupt
        let cancellation = InferenceCancellation.cancellable()
        currentCancellation = cancellation
        
        do {
            // Build InferenceRequest from our ChatMessage array
            let typedMessages = messages
                .filter { $0.role != "system" }
                .map { msg -> Message in
                    Message(role: msg.role, content: .text(msg.content))
                }
            
            let request = InferenceRequest(
                modelId: model,
                messages: typedMessages,
                sessionId: "chat-\(UUID().uuidString.prefix(8))",
                cancellation: cancellation
            )
            
            // Stream via Fast Path
            for await chunk in try await DirectInferenceClient.shared.stream(request: request) {
                // P0-3: respect cancellation from both the token and outer Task
                guard !cancellation.isCancelled, !Task.isCancelled else { break }
                if !chunk.text.isEmpty {
                    responseText += chunk.text
                }
                if chunk.isComplete {
                    // Conversation complete — append and persist to history
                    if !responseText.isEmpty {
                        let assistantMsg = ChatMessage(role: "assistant", content: responseText)
                        messages.append(assistantMsg)
                        await persistMessage(role: "assistant", content: responseText)
                    }
                }
            }
            // Finalize cancellation handle
            currentCancellation = nil
        } catch {
            self.error = error
            responseText = error.localizedDescription
            currentCancellation = nil
        }
        loading = false
    }
    
    func loadModels() async -> [String] {
        guard let pool = OcoreaiEngine.shared.activeEnginePool else { return [] }
        let models = await pool.listModels()
        return models.map { $0["id"] ?? "unknown" }
    }
    
    /// Search HuggingFace Hub for models.
    /// Returns matching model IDs, sorted by likes.
    func searchHubModels(keyword: String, limit: Int = 15) async -> [HFModelInfo] {
        guard let url = URL(string: "https://huggingface.co/api/models?search=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)&limit=\(limit)&sort=likes")
        else { return [] }
    
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.error = NSError(domain: "ChatState", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models from Hub"])
                return []
            }
            let models = try JSONDecoder().decode([HFModelInfo].self, from: data)
            return models
        } catch {
            self.error = error
            return []
        }
    }

    /// Load a model into the pool (triggers download if hub model like hf:...),
    /// then return the updated list of loaded model IDs.
    func loadNewModel(_ modelId: String) async -> [String] {
        guard let pool = OcoreaiEngine.shared.activeEnginePool else { return [] }
        do {
            // Acquire triggers lazy-load; immediately release so we don't hold a session
            let _ = try await pool.acquire(model: modelId)
            await pool.releaseSession(modelId: modelId, sessionId: "init")
        } catch {
            self.error = error
            return []
        }
        // Return refreshed model list for ChatView to update its @State
        return await loadModels()
    }
    
    /// Snapshot current state, then clear the conversation.
    func resetConversation() {
        undoSnapshot = messages
        undoResponseText = responseText
        undoError = error
        messages = []
        responseText = ""
        error = nil
        // Register undo with AppState for Cmd+Z access
        AppState.shared.undoAction = { [weak self] in self?.undoReset() }
    }
    
    /// Restore from the last snapshot if one exists.
    func undoReset() {
        guard let snapshot = undoSnapshot else { return }
        messages = snapshot
        responseText = undoResponseText ?? ""
        error = undoError
        undoSnapshot = nil
        undoResponseText = nil
        undoError = nil
    }
}
