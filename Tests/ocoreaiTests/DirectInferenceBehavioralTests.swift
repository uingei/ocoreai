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

import Foundation
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - DirectChunkMetadata Codable round-trip

@Suite("DirectChunkMetadata — Codable round-trip")
struct ChunkMetadataTests {

    @Test("toolCall metadata survives encode/decode — name and arguments preserved")
    func toolCallRoundTrip() {
        let meta = DirectChatChunk.DirectChunkMetadata.toolCall(
            DirectChatChunk.ToolCallMeta(
                id: "call_01",
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
            #expect(tc.id == "call_01")
            #expect(tc.name == "weather")
            #expect(tc.arguments == "{\"location\":\"SF\"}")
            #expect(tc.resultSummary == "19°C, partly cloudy")
            #expect(tc.durationMs == 245.0)
        case .toolResult:
            Issue.record("toolCall decoded as toolResult")
        case .reasoningStart:
            Issue.record("toolCall decoded as reasoningStart")
        case .reasoningEnd:
            Issue.record("toolCall decoded as reasoningEnd")
        case .compactionNote:
            Issue.record("toolCall decoded as compactionNote")
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

    @Test("toolResult metadata survives encode/decode — id, outcome, measured duration preserved")
    func toolResultRoundTrip() {
        let meta = DirectChatChunk.DirectChunkMetadata.toolResult(
            ToolResultMeta(
                id: "call_42",
                name: "exec_command",
                resultSummary: "sum=41452631, max=966898",
                durationMs: 127.0,
                failure: nil
            )
        )

        let data = try! JSONEncoder().encode(meta)
        let decoded = try! JSONDecoder().decode(
            DirectChatChunk.DirectChunkMetadata.self, from: data
        )

        switch decoded {
        case .toolResult(let tr):
            #expect(tr.id == "call_42")
            #expect(tr.name == "exec_command")
            #expect(tr.resultSummary == "sum=41452631, max=966898")
            #expect(tr.durationMs == 127.0)
            #expect(tr.failure == nil)
        case .toolCall:
            Issue.record("toolResult decoded as toolCall")
        case .reasoningStart, .reasoningEnd, .compactionNote:
            Issue.record("toolResult decoded as another case")
        }
    }

    @Test("toolResult with failure round-trips — denial is never lost in transit")
    func toolResultFailureRoundTrip() {
        let meta = DirectChatChunk.DirectChunkMetadata.toolResult(
            ToolResultMeta(
                id: "call_43",
                name: "exec_command",
                resultSummary: "[失败] 需要审批 — headless 通道不可交互",
                durationMs: 0.4,
                failure: "需要审批 — headless 通道不可交互"
            )
        )

        let data = try! JSONEncoder().encode(meta)
        let decoded = try! JSONDecoder().decode(
            DirectChatChunk.DirectChunkMetadata.self, from: data
        )

        switch decoded {
        case .toolResult(let tr):
            #expect(tr.failure != nil)
            #expect(tr.failure == "需要审批 — headless 通道不可交互")
            #expect(tr.durationMs == 0.4)
        default:
            Issue.record("toolResult decoded as another case")
        }
    }

    @Test("summary() — ≤200 原样 / 201 截到 200+… / 换行折空格(边界精确)")
    func summaryTruncationExact() {
        // 199 chars: untouched
        let short = String(repeating: "a", count: 199)
        #expect(ToolResultMeta.summary(short) == short)
        // 200 chars: untouched (boundary)
        let atLimit = String(repeating: "b", count: 200)
        #expect(ToolResultMeta.summary(atLimit) == atLimit)
        // 201 chars: truncated to 200 + "…"
        let over = String(repeating: "c", count: 201)
        let s = ToolResultMeta.summary(over)
        #expect(s.hasSuffix("…"))
        #expect(String(s.dropLast()).count == 200)
        // newlines folded to spaces
        #expect(ToolResultMeta.summary("a\nb\nc") == "a b c")
        // explicit larger limit honored
        let big = String(repeating: "d", count: 500)
        let s500 = ToolResultMeta.summary(big, limit: 500)
        #expect(s500 == big)
        let s250 = ToolResultMeta.summary(big, limit: 250)
        #expect(s250.hasSuffix("…"))
        #expect(String(s250.dropLast()).count == 250)
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

extension DirectChatChunk.DirectChunkMetadata {
    fileprivate func caseName() throws -> String {
        let data = try JSONEncoder().encode(self)
        let dict = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
        // Codable enum with associated values encodes case name as a string key
        return String(dict.keys.first!)
    }
}
