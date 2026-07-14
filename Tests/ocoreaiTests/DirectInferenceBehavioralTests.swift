// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DirectInference behavioral tests — DirectChunkMetadata Codable fidelity,
/// InferenceCancellation propagation, and InferenceRequest param wiring.
///
/// Replaced pure-DTO self-assertion tests: DirectChatChunk has only stored
/// properties, so constructing and checking fields is tautological.
/// These tests focus on actual runtime behavior:
///   1. DirectChunkMetadata Codable round-trip (toolCall carries data intact)
///   2. InferenceCancellation cancel() → isCancelled state transition
///   3. InferenceRequest default vs explicit sampling params

import Testing
import Foundation
@testable import ocoreai
import ocoreaiTestUtilities

// MARK: - DirectChunkMetadata Codable round-trip

@Suite("DirectChunkMetadata — Codable round-trip")
struct ChunkMetadataTests {

    @Test("toolCall metadata survives encode/decode — name and arguments preserved")
    func toolCallRoundTrip() {
        let meta = DirectChatChunk.DirectChunkMetadata.toolCall(
            DirectChatChunk.ToolCallMeta(
                name: "weather",
                arguments: "{\"location\":\"SF\"}",
                resultSummary: "19°C, partly cloudy",
                durationMs: 245.0
            )
        )

        let data = try! JSONEncoder().encode(meta)
        let decoded = try! JSONDecoder().decode(
            DirectChatChunk.DirectChunkMetadata.self,
            from: data
        )

        switch decoded {
        case .toolCall(let tc):
            #expect(tc.name == "weather")
            #expect(tc.arguments == "{\"location\":\"SF\"}")
            #expect(tc.resultSummary == "19°C, partly cloudy")
            #expect(tc.durationMs == 245.0)
        case .reasoningStart:
            Issue.record("toolCall decoded as reasoningStart")
        case .reasoningEnd:
            Issue.record("toolCall decoded as reasoningEnd")
        }
    }

    @Test("reasoningStart distinct from reasoningEnd — different JSON payloads")
    func reasoningMarkersDistinct() {
        let start = DirectChatChunk.DirectChunkMetadata.reasoningStart
        let end = DirectChatChunk.DirectChunkMetadata.reasoningEnd

        // Same encoder → different JSON = different events
        let dataStart = try! JSONEncoder().encode(start)
        let dataEnd = try! JSONEncoder().encode(end)
        #expect(dataStart != dataEnd)

        // And each decodes back to itself
        let decodedStart = try! JSONDecoder().decode(
            DirectChatChunk.DirectChunkMetadata.self, from: dataStart
        )
        let decodedEnd = try! JSONDecoder().decode(
            DirectChatChunk.DirectChunkMetadata.self, from: dataEnd
        )
        #expect(try! decodedStart.caseName() == "reasoningStart")
        #expect(try! decodedEnd.caseName() == "reasoningEnd")
    }
}

// MARK: - InferenceCancellation state machine

@Suite("InferenceCancellation — cancel propagation")
struct DirectInferenceCancellationTests {

    @Test("fresh token is not cancelled")
    func freshNotCancelled() {
        let token = InferenceCancellation.cancellable()
        #expect(token.isCancelled == false)
    }

    @Test("cancel() sets isCancelled to true")
    func cancelPropagates() {
        let token = InferenceCancellation.cancellable()
        #expect(token.isCancelled == false)
        token.cancel()
        #expect(token.isCancelled == true)
    }

    @Test(".none token never reports cancelled")
    func noneNeverCancelled() {
        let token = InferenceCancellation.none
        #expect(token.isCancelled == false)
        token.cancel() // no-op on none
        #expect(token.isCancelled == false)
    }

    @Test("cancel() idempotent — calling twice has same result")
    func cancelIdempotent() {
        let token = InferenceCancellation.cancellable()
        token.cancel()
        #expect(token.isCancelled == true)
        token.cancel()
        #expect(token.isCancelled == true)
    }
}

// MARK: - InferenceRequest default vs explicit params

@Suite("InferenceRequest — sampling defaults and explicit overrides")
struct InferenceRequestTests {

    @Test("default request: sampling params nil, cancellation nil")
    func allDefaultsNil() {
        let req = InferenceRequest(
            modelId: "test-model",
            messages: [Message(role: "user", content: "hello")],
            systemPrompt: nil,
            tools: nil,
            sessionId: nil
        )
        #expect(req.temperature == nil)
        #expect(req.topP == nil)
        #expect(req.topK == nil)
        #expect(req.maxTokens == nil)
        #expect(req.cancellation == nil)
        #expect(req.stopSequences == nil)
        #expect(req.logitBias == nil)
    }

    @Test("explicit params preserved — no mutation between construct and read")
    func explicitPreserved() {
        let req = InferenceRequest(
            modelId: "test-model",
            messages: [Message(role: "user", content: "hello")],
            systemPrompt: nil,
            tools: nil,
            temperature: 0.8,
            topP: 0.95,
            topK: 40,
            maxTokens: 2048,
            sessionId: "s1",
            cancellation: nil
        )
        #expect(req.temperature == 0.8)
        #expect(req.topP == 0.95)
        #expect(req.topK == 40)
        #expect(req.maxTokens == 2048)
    }

    @Test("cancellation token wired and functional through request")
    func cancellationWired() {
        let token = InferenceCancellation.cancellable()
        let req = InferenceRequest(
            modelId: "test-model",
            messages: [Message(role: "user", content: "hello")],
            systemPrompt: nil,
            tools: nil,
            temperature: 0.7,
            sessionId: nil,
            cancellation: token
        )
        #expect(req.cancellation != nil)
        #expect(req.cancellation?.isCancelled == false)
        token.cancel()
        #expect(req.cancellation?.isCancelled == true)
    }
}

// MARK: - Helper: enum case introspection for Codable verification

private extension DirectChatChunk.DirectChunkMetadata {
    func caseName() throws -> String {
        let data = try JSONEncoder().encode(self)
        let dict = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
        // Codable enum with associated values encodes case name as a string key
        return String(dict.keys.first!)
    }
}
