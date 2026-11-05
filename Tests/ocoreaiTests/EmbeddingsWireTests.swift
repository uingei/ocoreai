// Wire-contract tests for POST /v1/embeddings (OpenAI-compatible surface).
// Covers the decode contracts, the encoding_format/dimensions refusals and the
// truthful-identity rule — the parts that are pure (no live embedder required).
// The live half is scripts/probes/51-embeddings-encoding-format.sh; breaker
// behavior lives in EmbeddingCircuitBreakerTests.

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
        #expect(datum.payload == .floats(floats))
    }

    // MARK: - encoding_format / dimensions (the two fields the wire used to accept and ignore)

    @Test("encoding_format decodes; absent is nil, dimensions decodes")
    func newFieldsDecode() throws {
        let absent = try JSONDecoder().decode(
            EmbeddingsRequest.self,
            from: Data(#"{"input":"hi"}"#.utf8))
        #expect(absent.encodingFormat == nil)
        #expect(absent.dimensions == nil)
        let b64 = try JSONDecoder().decode(
            EmbeddingsRequest.self,
            from: Data(#"{"input":"hi","encoding_format":"base64","dimensions":1024}"#.utf8))
        #expect(b64.encodingFormat == "base64")
        #expect(b64.dimensions == 1024)
    }

    /// Every arm below is the pure gate, so it decides with no embedder resident; the live
    /// envelope is probe 51's job. A request field the endpoint accepts and reinterprets is the
    /// surface promising a shape it never delivered, so each one owes a named refusal or a real
    /// answer — never a silent third thing.
    private static let native = EmbeddingService.embeddingDimension
    private static let model = EmbeddingService.canonicalModelId

    private func refusal(_ body: () throws -> EmbeddingsEncoding) -> String? {
        do {
            _ = try body()
            return nil
        } catch let AppError.invalidRequest(message) {
            return message
        } catch {
            Issue.record("expected AppError.invalidRequest, got \(error)")
            return nil
        }
    }

    @Test("absent and float keep the float array; base64 selects the base64 shape")
    func acceptedFormats() throws {
        for accepted in [nil, "float"] {
            #expect(
                try embeddingsWireEncoding(
                    encodingFormat: accepted, dimensions: nil,
                    nativeDimension: Self.native, modelName: Self.model) == .float)
        }
        #expect(
            try embeddingsWireEncoding(
                encodingFormat: "base64", dimensions: nil,
                nativeDimension: Self.native, modelName: Self.model) == .base64)
    }

    @Test("an unknown encoding_format is refused by name, not answered with floats")
    func unknownFormatRefused() throws {
        let message = try #require(
            refusal {
                try embeddingsWireEncoding(
                    encodingFormat: "msgpack", dimensions: nil,
                    nativeDimension: Self.native, modelName: Self.model)
            })
        #expect(message.contains("encoding_format"))
        #expect(message.contains("msgpack"))
        #expect(message.contains("'float'"))
        #expect(message.contains("'base64'"))
        // The caller's observable face is a 400, same family as the decisions contract.
        #expect(AppError.invalidRequest(message).status == .badRequest)
    }

    @Test("dimensions this embedder cannot answer is refused naming the width and the exit")
    func dimensionsRefused() throws {
        let message = try #require(
            refusal {
                try embeddingsWireEncoding(
                    encodingFormat: nil, dimensions: 256,
                    nativeDimension: Self.native, modelName: Self.model)
            })
        #expect(message.contains("dimensions=256"))
        #expect(message.contains(Self.model))
        #expect(message.contains("\(Self.native)"))
        #expect(message.contains("Omit 'dimensions'"))
        // Spec floor: `minimum: 1` (openai-openapi encoding_format-adjacent `dimensions`).
        let zero = try #require(
            refusal {
                try embeddingsWireEncoding(
                    encodingFormat: nil, dimensions: 0,
                    nativeDimension: Self.native, modelName: Self.model)
            })
        #expect(zero.contains("dimensions"))
        #expect(zero.contains(">= 1"))
        // The native width is a no-op, not a refusal.
        #expect(
            try embeddingsWireEncoding(
                encodingFormat: nil, dimensions: Self.native,
                nativeDimension: Self.native, modelName: Self.model) == .float)
    }

    /// The `embedding` value byte-for-byte: still a JSON array, still the encoder's own float
    /// rendering (`1.0` prints as `1` — a wire fact a caller parses). Key order inside the object
    /// is not pinned, because JSON key order is not a promise any client may depend on.
    @Test("the float shape on the wire is unchanged")
    func floatShapeUnchanged() throws {
        let json = try JSONEncoder().encode(
            EmbeddingDatum(object: "embedding", index: 0, embedding: [0.5, -0.25, 1.0]))
        let body = String(decoding: json, as: UTF8.self)
        #expect(body.contains(#""embedding":[0.5,-0.25,1]"#))
        #expect(!body.contains("\"embedding\":\""))
    }

    /// Pinned against `struct.pack('<2f', 1.0, 2.0)` → hex `0000803f 00000040` →
    /// `AACAPwAAAEA=`: base64 of contiguous little-endian float32, riding the `embedding`
    /// key (spec + ollama/vllm/sglang/Rapid-MLX agree; `b64_json` is images-only).
    @Test("the base64 shape is LE float32 packed, under the embedding key")
    func base64ShapeExact() throws {
        #expect(EmbeddingDatum.base64Embedding(of: [1.0, 2.0]) == "AACAPwAAAEA=")
        let json = try JSONEncoder().encode(
            EmbeddingDatum(object: "embedding", index: 1, base64: "AACAPwAAAEA="))
        let body = String(decoding: json, as: UTF8.self)
        #expect(body.contains("\"embedding\":\"AACAPwAAAEA=\""))
        #expect(body.contains("\"index\":1"))
        #expect(!body.contains("b64_json"))
    }

    @Test("both response shapes decode — a vllm-style and an ollama-style datum round-trip")
    func bothShapesDecode() throws {
        let fromFloats = try JSONDecoder().decode(
            EmbeddingDatum.self,
            from: Data(#"{"object":"embedding","index":0,"embedding":[1.0,2.0]}"#.utf8))
        #expect(fromFloats.payload == .floats([1.0, 2.0]))
        let fromString = try JSONDecoder().decode(
            EmbeddingDatum.self,
            from: Data(#"{"object":"embedding","index":0,"embedding":"AACAPwAAAEA="}"#.utf8))
        #expect(fromString.payload == .base64("AACAPwAAAEA="))
    }
}
