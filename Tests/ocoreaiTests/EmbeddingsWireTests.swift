// Wire-contract tests for POST /v1/embeddings (OpenAI-compatible surface).
// Covers the decode contracts and truthful-identity rule — the parts that
// are pure (no live embedder required). The live embed path is covered
// end-to-end in the manual harness; breaker behavior lives in
// EmbeddingCircuitBreakerTests.

import Foundation
import Testing

@testable import ocoreai

@Suite("Embeddings wire contract")
struct EmbeddingsWireTests {

    @Test("input decodes single string")
    func singleStringInput() throws {
        let req = try JSONDecoder().decode(
            EmbeddingsRequest.self,
            from: Data(#"{"model":"x","input":"hello"}"#.utf8))
        #expect(req.input.texts == ["hello"])
    }

    @Test("input decodes string array")
    func arrayInput() throws {
        let req = try JSONDecoder().decode(
            EmbeddingsRequest.self,
            from: Data(#"{"model":"x","input":["a","b"]}"#.utf8))
        #expect(req.input.texts == ["a", "b"])
    }

    @Test("token-id arrays are rejected, not re-tokenized")
    func tokenIdArraysRejected() {
        // Pre-tokenized ids from a foreign tokenizer would produce garbage
        // vectors against the LFM embedding tokenizer — decode must reject.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                EmbeddingsRequest.self,
                from: Data(#"{"input":[1,2,3]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                EmbeddingsRequest.self,
                from: Data(#"{"input":[[1,2],[3,4]]}"#.utf8))
        }
    }

    @Test("model is optional on the wire; user passthrough tolerated")
    func optionalFields() throws {
        let req = try JSONDecoder().decode(
            EmbeddingsRequest.self,
            from: Data(#"{"input":"hi","user":"u1"}"#.utf8))
        #expect(req.model == nil)
        #expect(req.user == "u1")
    }

    @Test("response carries the ACTUAL embedder identity, not an echo")
    func truthfulModelIdentity() throws {
        // A client that requests "text-embedding-ada-002" must be told the
        // truth: what ran is the local LFM embedder.
        let resp = EmbeddingsResponse(
            object: "list",
            data: [],
            model: EmbeddingService.canonicalModelId,
            usage: EmbeddingsUsage(promptTokens: 7, totalTokens: 7)
        )
        let json = try JSONEncoder().encode(resp)
        let str = String(decoding: json, as: UTF8.self)
        #expect(str.contains("LFM2.5-Embedding-350M-4bit"))
        #expect(!str.contains("ada-002"))
        #expect(str.contains("\"prompt_tokens\":7"))
    }

    @Test("float round-trip: float32 LE blob -> embedding datum")
    func floatBlobRoundTrip() {
        let floats: [Float] = [0.5, -0.25, 1.0, 3.14159]
        let blob = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.size)
        let recovered = blob.withUnsafeBytes { [Float]($0.bindMemory(to: Float.self)) }
        #expect(recovered == floats)
        let datum = EmbeddingDatum(object: "embedding", index: 2, embedding: recovered)
        #expect(datum.index == 2)
        #expect(datum.embedding.count == 4)
    }
}
