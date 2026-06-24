// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Chat ViewModel — manages streaming, loading/error states, and message history.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
/// Fast Path: SwiftUI → DirectInferenceClient → EnginePool (zero HTTP).
/// Single source of truth for engine readiness: OcoreaiEngine.shared.engineReady.

import Foundation
import SwiftUI
import Observation

// MARK: - Chat Message

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
    
    // MARK: - Undo support
    
    /// Snapshot capture before destructive operations (max one level).
    private var undoSnapshot: [ChatMessage]?
    private var undoResponseText: String?
    private var undoError: Error?
    
    /// Returns true if there is an undoable action available.
    var hasUndo: Bool { undoSnapshot != nil }
    
    // MARK: - Lifecycle
    
    /// No-op: engine readiness is now a computed property from OcoreaiEngine.shared.
    func start() {}
    func stop() {}
    
    // MARK: - Chat (Fast Path)
    
    /// Send chat message via Fast Path — bypasses HTTP entirely.
    ///
    /// Flow: ChatMessage → Message (typed) → DirectInferenceClient.stream()
    ///       → EnginePool.acquire() → generateFromMessages()
    ///       → AsyncStream<InferenceEvent> → UI update
    func chat(_ text: String, model: String) async {
        // Push user message
        messages.append(ChatMessage(role: "user", content: text))
        responseText = ""
        loading = true
        error = nil
        
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
                sessionId: "chat-\(UUID().uuidString.prefix(8))"
            )
            
            // Stream via Fast Path
            for try await chunk in try await DirectInferenceClient.shared.stream(request: request) {
                if !chunk.text.isEmpty {
                    responseText += chunk.text
                }
                if chunk.isComplete {
                    // Conversation complete — append to history
                    if !responseText.isEmpty {
                        messages.append(ChatMessage(role: "assistant", content: responseText))
                    }
                }
            }
        } catch {
            self.error = error
            responseText = error.localizedDescription
        }
        loading = false
    }
    
    func loadModels() async -> [String] {
        guard let pool = OcoreaiEngine.shared.activeEnginePool else { return [] }
        let models = await pool.listModels()
        return models.map { $0["id"] ?? "unknown" }
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
