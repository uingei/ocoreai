// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatState session ID clearing and lifecycle — opaque identifier cleanup,
/// cancel/inference interrupt, undo semantics, and model-switch safety.

import Testing
import Foundation
@testable import ocoreai

@Suite("ChatState: sessionId and activeModelId lifecycle")
struct ChatStateSessionTests {

    // Use production resetForTesting() — clears all mutable state including
    // pendingUnloadTask, currentCancellation, sessionId, undo snapshot, AppState link.
    @MainActor func fullReset() {
        ChatState.shared.resetForTesting()
    }

    @MainActor @Test("resetConversation clears messages, responseText, errorMessage")
    func resetClearsState() {
        let s = ChatState.shared
        s.messages = [ChatMessage(role: "user", content: "test")]
        s.resetConversation()
        #expect(s.messages.isEmpty)
        #expect(s.responseText.isEmpty)
        #expect(s.errorMessage == nil)
        fullReset()
    }

    @MainActor @Test("resetConversation registers undo action")
    func resetRegistersUndo() {
        let s = ChatState.shared
        s.messages = [ChatMessage(role: "user", content: "test")]
        s.resetConversation()
        #expect(s.hasUndo)
        fullReset()
    }

    @MainActor @Test("undoReset restores messages after reset")
    func undoRestoresAfterReset() {
        let s = ChatState.shared
        s.messages = [ChatMessage(role: "user", content: "hello")]
        s.resetConversation()
        #expect(s.messages.isEmpty)
        s.undoReset()
        #expect(s.messages.count == 1)
        #expect(s.messages[0].content == "hello")
        fullReset()
    }

    @MainActor @Test("undoReset consumes snapshot — double undo is a no-op")
    func doubleUndoIsNoOp() {
        let s = ChatState.shared
        s.messages = [ChatMessage(role: "user", content: "hello")]
        s.resetConversation()
        s.undoReset()
        #expect(s.messages.count == 1)
        s.undoReset()
        #expect(!s.hasUndo)
        fullReset()
    }

    @MainActor @Test("cancelInference preserves partial as interrupted message")
    func cancelPreservesPartial() {
        let s = ChatState.shared
        let countBefore = s.messages.count
        s.loading = true
        s.responseText = "partial response"
        s.cancelInference()
        // cancelInference appends interrupted assistant message when responseText is non-empty
        #expect(s.messages.count == countBefore + 1)
        #expect(s.messages.last?.interrupted == true)
        #expect(!s.loading)
        fullReset()
    }

    @MainActor @Test("cancelInference with empty responseText does nothing to messages")
    func cancelEmptyPreservesNothing() {
        let s = ChatState.shared
        s.messages = [ChatMessage(role: "user", content: "hi")]
        s.loading = true
        s.responseText = ""
        s.cancelInference()
        // No interrupted message appended when responseText is empty
        #expect(s.messages.count == 1)
        #expect(!s.loading)
        fullReset()
    }

    @MainActor @Test("cancelInference is idempotent — double cancel is safe")
    func doubleCancelSafe() {
        let s = ChatState.shared
        s.cancelInference()
        s.cancelInference()
        #expect(!s.loading)
        #expect(s.messages.isEmpty)
        fullReset()
    }

    @MainActor @Test("onModelChanged cancels inference and preserves message history")
    func modelChangeCancelsAndPreserves() {
        let s = ChatState.shared
        let countBefore = s.messages.count
        let userMsg = ChatMessage(role: "user", content: "keep me")
        s.messages.append(userMsg)
        s.loading = true
        s.responseText = "partial"
        s.onModelChanged(newModelId: "new-model")
        // cancelInference inside onModelChanged appends interrupted message, user msg preserved
        #expect(s.messages.count == countBefore + 2)
        #expect(!s.loading)
        fullReset()
    }

    @MainActor @Test("onModelChanged with no active inference is safe")
    func modelChangeNoInferenceSafe() {
        let s = ChatState.shared
        s.messages = [ChatMessage(role: "user", content: "keep")]
        s.loading = false
        s.onModelChanged(newModelId: "new-model")
        #expect(!s.loading)
        #expect(s.messages.count == 1)
        fullReset()
    }
}
