// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CacheKeyInvalidationTests.swift. Two caches reused a compiled artifact on a partial key.
///
/// Both are the same defect shape, ported from coreai-models this window read. A cache keyed on
/// fewer fields than the artifact was compiled from hands one request another request's artifact.
/// * The pipelined engine keyed its sampler cache on temperature (upstream #537, 25af63c). A later
///   request changing `top_p` silently kept the old graph, and a greedy flip threw demanding a
///   `reset()` the engine never runs between requests. Our key is the fields the factory compiles
///   from. It is deliberately not the whole `SamplingConfiguration`, whose seed, stop sequence and
///   KV fields must not recompile an MPSGraph per request.
/// * The grammar-session cache matched on schema alone (upstream #522, 783fa1a). A request with
///   different `stop` strings reused a session whose grammar ends elsewhere. The key compares stop
///   ids as a set and the vocabulary size; nil stop ids (xgrammar's defaults) differ from empty.
///
/// The key types hold no CoreAI or Metal type, so these assertions run on every route. The padded
/// logits mask sits in the macOS 27-gated suite like the other GuidedGeneration runtime tests.

import Foundation
import Testing

@testable import ocoreai

@Suite("Sampler graph key: rebuild exactly when the compiled graph would differ")
struct SamplerGraphKeyTests {

    private static func config(
        temperature: Double? = 0.7, topP: Double? = nil, topK: Int? = nil, minP: Double? = nil,
        repetitionPenalty: Double? = nil, stopSequences: [String]? = nil, seed: Int64? = nil
    ) -> SamplingConfiguration {
        SamplingConfiguration(
            seed: seed, temperature: temperature, topP: topP, topK: topK, minP: minP,
            repetitionPenalty: repetitionPenalty, stopSequences: stopSequences)
    }

    @Test("equal compiled fields reuse; each compiled change rebuilds")
    func compiledFieldsSetKey() {
        let base = MPSGraphSamplerGraphKey(Self.config())
        #expect(base == MPSGraphSamplerGraphKey(Self.config()))
        #expect(base != MPSGraphSamplerGraphKey(Self.config(topP: 0.5)))
        #expect(base != MPSGraphSamplerGraphKey(Self.config(topK: 41)))
        #expect(base != MPSGraphSamplerGraphKey(Self.config(minP: 0.05)))
        #expect(base != MPSGraphSamplerGraphKey(Self.config(repetitionPenalty: 1.2)))
        #expect(base != MPSGraphSamplerGraphKey(Self.config(temperature: 0.8)))
    }

    @Test("fields the sampler graph never reads must not invalidate the cache")
    func uncompiledFieldsDoNotKey() {
        let base = MPSGraphSamplerGraphKey(Self.config())
        #expect(base == MPSGraphSamplerGraphKey(Self.config(stopSequences: ["\n"])))
        #expect(base == MPSGraphSamplerGraphKey(Self.config(seed: 7)))
        // Greedy drops top_p/top_k in `normalized()`, so a value there is not a graph change.
        #expect(
            MPSGraphSamplerGraphKey(Self.config(temperature: 0, topP: 0.9))
                == MPSGraphSamplerGraphKey(Self.config(temperature: 0)))
        // Greedy and non-greedy compile different samplers (argmax vs composite).
        #expect(
            MPSGraphSamplerGraphKey(Self.config(temperature: 0))
                != MPSGraphSamplerGraphKey(Self.config(temperature: nil)))
    }
}

@Suite(
    "Grammar session key: stop tokens and vocabulary are part of what the grammar was built from")
struct ConstrainedSessionKeyTests {

    private static func key(
        schema: String = "{}", stopTokenIds: [Int32]? = nil, vocab: Int = 32_000
    ) -> ConstrainedSessionKey {
        ConstrainedSessionKey(schema: schema, stopTokenIds: stopTokenIds, vocabularySize: vocab)
    }

    @Test("stop ids compare as a set; nil differs from the empty set")
    func stopTokenSemantics() {
        #expect(Self.key(stopTokenIds: [1, 2]) == Self.key(stopTokenIds: [2, 1, 1]))
        #expect(Self.key(stopTokenIds: [1]) != Self.key(stopTokenIds: [2]))
        #expect(Self.key(stopTokenIds: nil) != Self.key(stopTokenIds: []))
        #expect(Self.key(stopTokenIds: nil) == Self.key(stopTokenIds: nil))
    }

    @Test("schema and vocabulary size key the cache")
    func schemaAndVocab() {
        #expect(Self.key(schema: "{}") != Self.key(schema: "{\"type\":\"object\"}"))
        #expect(Self.key(vocab: 32_000) != Self.key(vocab: 32_001))
    }
}

#if canImport(CoreAI)

@Suite(
    "Padded logits: ids past the grammar's vocabulary are masked like any disallowed token",
    .enabled(if: PlatformPremise.hasMacOS27)
)
struct PaddedLogitsMaskTests {

    /// A byte-level vocabulary, with logits wider than it. Ids past the vocabulary belong to a
    /// padded output layer and no grammar could accept them (coreai-models #522).
    private static let vocabulary: [String] = [
        "{", "}", "[", "]", ":", ",", "\"", " ", "\n", "a", "1",
    ]

    @Test("masking a wider logits vector zeroes the pad past the vocabulary", arguments: [8])
    @available(macOS 27.0, *)
    func padIsMasked(padWidth: Int) throws {
        var session = try ConstrainedGenerationSession(
            jsonSchema: "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"}},"
                + "\"required\":[\"a\"]}",
            vocabulary: Self.vocabulary,
            vocabType: .byteLevel,
            stopTokenIds: nil
        )
        var logits = [Float](repeating: 0, count: Self.vocabulary.count + padWidth)
        // `session` is ~Copyable, so the mask verdict leaves the expression before `#expect`.
        let applied = session.applyMask(to: &logits)
        #expect(applied)
        for i in Self.vocabulary.count ..< logits.count {
            #expect(logits[i] == -.infinity, "padded id \(i) survived the grammar mask")
        }
        #expect(logits[..<Self.vocabulary.count].contains { $0 != -.infinity })
    }
}

#endif
