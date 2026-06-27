// Copyright © 2026 uingei@163.com.
// SessionModelTests.swift — Session model serialization roundtrips
//
// Tests: SessionModel, MessageModel, FTSSearchResult encode/decode.

import Testing
import Foundation
@testable import ocoreai

@Suite("SessionModel")
struct SessionModelTests {

    @Test("SessionModel roundtrip via JSON")
    func testSessionModelRoundtrip() throws {
        let now = Date()
        let model = SessionModel(
            id: 1,
            modelId: "llama-3.1-8b",
            createdAt: now,
            updatedAt: now,
            messageCount: 42,
            tokenCount: 1000,
            summary: nil,
            ttlDays: 30
        )

        let encoder = JSONEncoder()
        let json = try encoder.encode(model)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SessionModel.self, from: json)

        #expect(decoded.id == 1)
        #expect(decoded.modelId == "llama-3.1-8b")
        #expect(decoded.messageCount == 42)
        #expect(decoded.tokenCount == 1000)
        #expect(decoded.summary == nil)
        #expect(decoded.ttlDays == 30)
    }
}

@Suite("MessageModel")
struct MessageModelTests {

    @Test("MessageModel roundtrip via JSON")
    func testMessageModelRoundtrip() throws {
        let now = Date()
        let msg = MessageModel(
            id: 1,
            sessionId: 100,
            role: "user",
            content: "Hello",
            createdAt: now,
            tokenCount: 5,
            toolCalls: nil,
            embedVector: nil
        )

        let encoder = JSONEncoder()
        let json = try encoder.encode(msg)
        let decoded = try JSONDecoder().decode(MessageModel.self, from: json)

        #expect(decoded.id == 1)
        #expect(decoded.sessionId == 100)
        #expect(decoded.role == "user")
        #expect(decoded.content == "Hello")
        #expect(decoded.tokenCount == 5)
    }
}

@Suite("FTSSearchResult")
struct FTSSearchResultTests {

    @Test("FTSSearchResult roundtrip via JSON")
    func testFTSSearchResultRoundtrip() throws {
        let result = FTSSearchResult(
            messageIds: [1, 2, 3],
            snippet: "hello world",
            score: 0.95,
            sessionId: 100
        )

        let json = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(FTSSearchResult.self, from: json)

        #expect(decoded.messageIds == [1, 2, 3])
        #expect(decoded.snippet == "hello world")
        #expect(decoded.score == 0.95)
        #expect(decoded.sessionId == 100)
    }
}

@Suite("SessionDeleteResponse")
struct SessionDeleteResponseTests {

    @Test("SessionDeleteResponse roundtrip")
    func testDeleteResponseRoundtrip() throws {
        let resp = SessionDeleteResponse(deleted: true, id: 7)
        let json = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(SessionDeleteResponse.self, from: json)

        #expect(decoded.deleted == true)
        #expect(decoded.id == 7)
    }
}

@Suite("EngineSummary")
struct EngineSummaryTests {

    @Test("EngineSummary init with defaults")
    func testEngineSummaryDefault() {
        let summary = EngineSummary(
            loadedModels: 3,
            activeSessions: 10,
            gpuCacheGB: 4.2,
            specializedModels: 1
        )

        #expect(summary.loadedModels == 3)
        #expect(summary.activeSessions == 10)
        #expect(summary.gpuCacheGB == 4.2)
        #expect(summary.specializedModels == 1)
        #expect(summary.modelIds.isEmpty) // default empty array
    }
}

