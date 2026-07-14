// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DirectInference behavioral tests — streaming completion semantics and sampling defaults.
///
/// Cancellation state machine tests moved to ChatPipelineBehavioralTests to avoid duplication.

import Testing
import Foundation
@testable import ocoreai

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
