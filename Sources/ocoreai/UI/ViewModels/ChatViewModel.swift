// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Chat ViewModel — manages streaming, loading/error states, and message history.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
/// Fast Path: SwiftUI → DirectInferenceClient → EnginePool (zero HTTP).
/// APIClient retained only as Opt-in fallback for external Agent access.

import Foundation
import SwiftUI

// MARK: - Chat Message

/// Lightweight chat message — used across UI layer.
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

@MainActor
final class ChatState: Observable {
    var messages: [ChatMessage] = []
    var responseText: String = ""
    var error: Error?
    var loading: Bool = false
    var connected: Bool = false
    var engineReady: Bool = false
    
    private var healthTask: Task<Void, Never>?
    
    // MARK: - Lifecycle
    
    /// Start health monitoring — Fast Path polls OcoreaiEngine directly.
    ///
    /// No more HTTP polling — we check whether the engine pool, scheduler,
    /// and message builder are all wired up.
    func start() {
        healthTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let isReady = Self.checkEngineReady()
                if self.engineReady != isReady {
                    self.engineReady = isReady
                    self.connected = isReady  // alias for backward compat
                }
                if !isReady {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    
    /// Stop health polling
    func stop() {
        healthTask?.cancel()
        healthTask = nil
    }
    
    deinit {
        healthTask?.cancel()
    }
    
    /// Check if the inference engine is ready (all components wired up)
    private static func checkEngineReady() -> Bool {
        let engine = OcoreaiEngine.shared
        return engine.activeEnginePool != nil
            && engine.activeScheduler != nil
            && engine.activeMessageBuilder != nil
    }
    
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
    
    func resetConversation() {
        messages = []
        responseText = ""
        error = nil
    }
}
