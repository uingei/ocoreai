// ConfigAndSamplingTests.swift — EnginePoolConfig, ModelConfig, SamplingConfiguration
//
// Tests: default values, boundary validation, normalization, encode/decode
// roundtrips, and hot-swap config correctness.

import Testing
import Foundation
@testable import ocoreai

@Suite("EnginePoolConfig")
struct EnginePoolConfigTests {

    @Test("default config has sensible values")
    func testDefaultConfig() {
        let config = EnginePoolConfig.default
        #expect(config.maxConcurrentSessions > 0)
        #expect(config.maxQueueSize > 0)
        #expect(config.warmupTokens > 0)
        #expect(config.modelConfigPath.contains("config.json"))
    }

    @Test("config is mutable before initialization")
    func testMutableConfig() {
        var config = EnginePoolConfig(
            maxConcurrentSessions: 4,
            maxQueueSize: 16,
            modelConfigPath: "/custom/path/config.json",
            modelDirectory: "/custom/models",
            warmupTokens: 2,
            kvCacheConfig: nil
        )
        #expect(config.maxConcurrentSessions == 4)
        #expect(config.maxQueueSize == 16)
        #expect(config.warmupTokens == 2)
        config.maxConcurrentSessions = 16
        #expect(config.maxConcurrentSessions == 16)
    }
}

@Suite("ModelConfig")
struct ModelConfigTests {

    @Test("valid config passes validation")
    func testValidConfig() throws {
        let json = #"""
        {"name":"test-model","function":"default","vocab_size":32000,
         "max_context_length":8192,"chunk_threshold":256,
         "prefill_chunk_size":128,"serialized_model":["weights.safetensors"],
         "tokenizer":"tokenizer.json"}
        """#
        let data = json.data(using: .utf8)!
        let config = try ModelConfig(parsing: data)
        #expect(config.vocabSize == 32000)
        #expect(config.maxContextLength == 8192)
        try config.validate()
    }

    @Test("zero vocabSize fails validation")
    func testZeroVocabFails() throws {
        let json = #"""
        {"name":"bad","function":"x","vocab_size":0,
         "max_context_length":1024,"chunk_threshold":0,
         "prefill_chunk_size":0,"serialized_model":[],
         "tokenizer":"t.json"}
        """#
        let config = try ModelConfig(parsing: json.data(using: .utf8)!)
        do {
            try config.validate()
            #expect(Bool(false), "Should have thrown for zero vocabSize")
        } catch {
            #expect((error as? AppError) != nil)
        }
    }

    @Test("zero maxContextLength fails validation")
    func testZeroContextFails() throws {
        let json = #"""
        {"name":"bad","function":"x","vocab_size":32000,
         "max_context_length":0,"chunk_threshold":0,
         "prefill_chunk_size":0,"serialized_model":[],
         "tokenizer":"t.json"}
        """#
        let config = try ModelConfig(parsing: json.data(using: .utf8)!)
        do {
            try config.validate()
            #expect(Bool(false), "Should have thrown for zero context")
        } catch {
            #expect((error as? AppError) != nil)
        }
    }

    @Test("optional function defaults to 'default'")
    func testFunctionDefault() throws {
        let json = #"""
        {"vocab_size":32000,"max_context_length":1024,
         "chunk_threshold":0,"prefill_chunk_size":0,
         "serialized_model":[],"tokenizer":"t.json"}
        """#
        let config = try ModelConfig(parsing: json.data(using: .utf8)!)
        #expect(config.function == "default")
    }

    @Test("direct init works for stub KVCache")
    func testDirectInit() {
        let config = ModelConfig(
            name: "stub",
            function: "test",
            vocabSize: 100,
            maxContextLength: 512,
            chunkThreshold: 0,
            prefillChunkSize: 0
        )
        #expect(config.name == "stub")
        #expect(config.vocabSize == 100)
    }
}

@Suite("SamplingConfiguration")
struct SamplingConfigTests {

    @Test("normalization drops topK/topP on zero temperature")
    func testNormalizationZeroTemp() {
        var config = SamplingConfiguration(temperature: 0, topK: 50, topP: 0.9)
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }

    @Test("normalization preserves topK/topP on non-zero temperature")
    func testNormalizationWithTemp() {
        let config = SamplingConfiguration(temperature: 0.7, topK: 50, topP: 0.9)
        let normalized = config.normalized()
        #expect(normalized.topK == 50)
        #expect(normalized.topP == 0.9)
    }

    @Test("normalization preserves topK/topP on nil temperature")
    func testNormalizationNilTemp() {
        let config = SamplingConfiguration(temperature: nil, topK: 50, topP: 0.9)
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }

    @Test("encode/decode roundtrip") throws {
        let config = SamplingConfiguration(
            seed: 42,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            stopSequences: ["\n"],
            combined: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SamplingConfiguration.self, from: data)
        #expect(decoded.seed == 42)
        #expect(decoded.temperature == 0.7)
        #expect(decoded.topK == 40)
    }

    @Test("sampling config default values")
    func testDefaults() {
        let config = SamplingConfiguration()
        #expect(config.seed == nil)
        #expect(config.temperature == nil)
        #expect(config.combined == true)
    }
}

@Suite("InferenceOptions")
struct InferenceOptionsTests {

    @Test("encode/decode roundtrip with options set") throws {
        let opts = InferenceOptions(maxTokens: 4096, includeLogits: true)
        let data = try JSONEncoder().encode(opts)
        let decoded = try JSONDecoder().decode(InferenceOptions.self, from: data)
        #expect(decoded.maxTokens == 4096)
        #expect(decoded.includeLogits == true)
    }

    @Test("default init produces nils")
    func testDefault() {
        let opts = InferenceOptions()
        #expect(opts.maxTokens == nil)
        #expect(opts.includeLogits == false)
    }
}

@Suite("stopReasonToString stub")
struct StopReasonTests {

    @Test("stub stopReasonToString returns 'stop'")
    func testStubStopReason() {
        let result = stopReasonToString(nil)
        #expect(result == "stop")
    }
}
