// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatState session ID clearing and lifecycle — opaque identifier cleanup,
/// cancel/inference interrupt, undo semantics, and model-switch safety.

import Testing
import Foundation
@testable import ocoreai
import ocoreaiTestUtilities

@Suite("ChatState: sessionId and activeModelId lifecycle")
struct ChatStateSessionTests {

    @MainActor @Test("resetConversation clears messages, responseText, errorMessage")
    func resetClearsState() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.messages = [ChatMessage(role: "user", content: "test")]
        s.resetConversation()
        #expect(s.messages.isEmpty)
        #expect(s.responseText.isEmpty)
        #expect(s.errorMessage == nil)
    }

    @MainActor @Test("resetConversation registers undo action")
    func resetRegistersUndo() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.messages = [ChatMessage(role: "user", content: "test")]
        s.resetConversation()
        #expect(s.hasUndo)
    }

    @MainActor @Test("undoReset restores messages after reset")
    func undoRestoresAfterReset() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.messages = [ChatMessage(role: "user", content: "hello")]
        s.resetConversation()
        #expect(s.messages.isEmpty)
        s.undoReset()
        #expect(s.messages.count == 1)
        #expect(s.messages[0].content == "hello")
    }

    @MainActor @Test("undoReset consumes snapshot — double undo is a no-op")
    func doubleUndoIsNoOp() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.messages = [ChatMessage(role: "user", content: "hello")]
        s.resetConversation()
        s.undoReset()
        #expect(s.messages.count == 1)
        s.undoReset()
        #expect(!s.hasUndo)
    }

    @MainActor @Test("cancelInference preserves partial as interrupted message")
    func cancelPreservesPartial() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let countBefore = s.messages.count
        s.loading = true
        s.responseText = "partial response"
        s.cancelInference()
        // cancelInference appends interrupted assistant message when responseText is non-empty
        #expect(s.messages.count == countBefore + 1)
        #expect(s.messages.last?.interrupted == true)
        #expect(!s.loading)
    }

    @MainActor @Test("cancelInference with empty responseText does nothing to messages")
    func cancelEmptyPreservesNothing() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.messages = [ChatMessage(role: "user", content: "hi")]
        s.loading = true
        s.responseText = ""
        s.cancelInference()
        // No interrupted message appended when responseText is empty
        #expect(s.messages.count == 1)
        #expect(!s.loading)
    }

    @MainActor @Test("cancelInference is idempotent — double cancel is safe")
    func doubleCancelSafe() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.cancelInference()
        s.cancelInference()
        #expect(!s.loading)
        #expect(s.messages.isEmpty)
    }

    @MainActor @Test("onModelChanged cancels inference and preserves message history")
    func modelChangeCancelsAndPreserves() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let countBefore = s.messages.count
        let userMsg = ChatMessage(role: "user", content: "keep me")
        s.messages.append(userMsg)
        s.loading = true
        s.responseText = "partial"
        s.onModelChanged(newModelId: "new-model")
        // cancelInference inside onModelChanged appends interrupted message, user msg preserved
        #expect(s.messages.count == countBefore + 2)
        #expect(!s.loading)
    }

    @MainActor @Test("onModelChanged with no active inference is safe")
    func modelChangeNoInferenceSafe() throws {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        s.messages = [ChatMessage(role: "user", content: "keep")]
        s.loading = false
        s.onModelChanged(newModelId: "new-model")
        #expect(!s.loading)
        #expect(s.messages.count == 1)
    }
}
