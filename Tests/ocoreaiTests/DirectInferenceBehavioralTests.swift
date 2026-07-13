// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DirectInference behavioral tests — cancellation state machine, streaming
/// completion semantics, sampling defaults. Only tests that exercise real
/// stateful logic.

import Testing
import Foundation
@testable import ocoreai

// MARK: - Cancellation state machine

@Suite("InferenceCancellation — actual state machine (create → cancel → irreversible)")
struct InferenceCancellationStateTests {

    @Test("cancellable starts uncancelled")
    func startsUncancelled() async {
        let token = InferenceCancellation.cancellable()
        #expect(!token.isCancelled)
    }

    @Test("cancel() transitions to cancelled state")
    func transitionToCancelled() async {
        let token = InferenceCancellation.cancellable()
        token.cancel()
        #expect(token.isCancelled)
    }

    @Test("cancelled state is irreversible")
    func irreversible() async {
        let token = InferenceCancellation.cancellable()
        token.cancel()
        token.cancel()  // second cancel — state stays cancelled
        #expect(token.isCancelled)
    }

    @Test(".none handle never reports cancelled")
    func noneNeverCancelled() async {
        #expect(!InferenceCancellation.none.isCancelled)
    }
}

// MARK: - Streaming completion semantics

@Suite("DirectChatChunk — streaming completion state")
struct StreamingCompletionTests {

    @Test("final chunk: isComplete + stopReason present")
    func completeChunk() async {
        let chunk = DirectChatChunk(
            text: "",
            isComplete: true,
            stopReason: "eos",
            outputTokens: 42
        )
        #expect(chunk.isComplete)
        #expect(chunk.stopReason == "eos")
        #expect(chunk.outputTokens == 42)
    }

    @Test("intermediate chunk: isComplete=false, no stopReason")
    func intermediateChunk() async {
        let chunk = DirectChatChunk(text: "Hello", isComplete: false)
        #expect(!chunk.isComplete)
        #expect(chunk.stopReason == nil)
    }

    @Test("error chunk: isComplete=true with 'error' stopReason")
    func errorChunk() async {
        let chunk = DirectChatChunk(
            text: "",
            isComplete: true,
            stopReason: "error",
            outputTokens: 0
        )
        #expect(chunk.isComplete)
        #expect(chunk.stopReason == "error")
    }
}

// MARK: - Sampling defaults

@Suite("InferenceRequest — sampling parameter defaults")
struct SamplingDefaultTests {

    @Test("sampling params default to nil (engine overrides)")
    func paramsDefaultToNil() async {
        let req = InferenceRequest(
            modelId: "test-model",
            messages: [Message(role: "user", content: "hello")]
        )
        #expect(req.temperature == nil)
        #expect(req.topP == nil)
        #expect(req.topK == nil)
        #expect(req.maxTokens == nil)
    }

    @Test("explicit params are preserved")
    func explicitParamsPreserved() async {
        let req = InferenceRequest(
            modelId: "test-model",
            messages: [Message(role: "user", content: "hello")],
            temperature: 0.8,
            maxTokens: 2048
        )
        #expect(req.temperature == 0.8)
        #expect(req.maxTokens == 2048)
    }
}
