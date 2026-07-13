// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatState session ID clearing and lifecycle — opaque identifier cleanup,
/// cancel/inference interrupt, undo semantics, and model-switch safety.

import Testing
import Foundation
@testable import ocoreai

@Suite("ChatState: sessionId and activeModelId lifecycle")
struct ChatStateSessionTests {

    // Helper: full reset including undo snapshot (accessible properties only)
    @MainActor func fullReset() {
        let s = ChatState.shared
        s.messages = []
        s.responseText = ""
        s.errorMessage = nil
        s.loading = false
        // Clear undo snapshot — the private undoSessionId/undoActiveModelId
        // are cleared automatically by resetConversation/undoReset, so we
        // only need to consume any pending undo before our next test.
        if s.hasUndo { s.undoReset() }
        // If undoReset left a message, consume it again.
        if s.hasUndo { s.undoReset() }
        s.messages = []
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
        s.loading = true
        s.responseText = "partial response"
        s.cancelInference()
        #expect(!s.loading)
        #expect(s.messages.count == 1)
        #expect(s.messages[0].interrupted == true)
        #expect(s.messages[0].content == "partial response")
        #expect(s.responseText.isEmpty)
        fullReset()
    }

    @MainActor @Test("cancelInference with empty responseText does nothing to messages")
    func cancelEmptyPreservesNothing() {
        let s = ChatState.shared
        s.loading = true
        s.messages = [ChatMessage(role: "user", content: "hi")]
        s.responseText = ""
        s.cancelInference()
        #expect(!s.loading)
        #expect(s.messages.count == 1)
        #expect(s.messages[0].role == "user")
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
        s.messages = [ChatMessage(role: "user", content: "keep me")]
        s.loading = true
        s.responseText = "partial"
        s.onModelChanged(newModelId: "new-model")
        #expect(!s.loading)
        #expect(s.messages.count >= 1)
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
