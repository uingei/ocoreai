// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Per-Model Settings — omlx `ModelSettings` borrow surface (max_context_window /
/// is_default / is_pinned). Tests the pure decision helpers + Codable round-trip
/// + PATCH-toConfig merge + response echo. No live ChatSession / MLX runtime needed.

import Foundation
import Testing

@testable import ocoreai

// MARK: - Codable round-trip (new fields survive encode/decode with snake_case keys)

@Suite("ModelSamplingConfig — per-model fields Codable")
struct PerModelConfigCodableTests {
    @Test("maxContextWindow defaultModel pinned round-trip via snake_case")
    func roundTrip() throws {
        var cfg = ModelSamplingConfig.default
        cfg.maxContextWindow = 8192
        cfg.defaultModel = true
        cfg.pinned = true
        cfg.temperature = 0.4

        let data = try JSONEncoder().encode(cfg)
        // Assert snake_case wire keys are present (OpenAI/PATCH compat).
        #expect(data.contains(Data("max_context_window".utf8)))
        #expect(data.contains(Data("default_model".utf8)))
        #expect(data.contains(Data("pinned".utf8)))

        let decoded = try JSONDecoder().decode(ModelSamplingConfig.self, from: data)
        #expect(decoded.maxContextWindow == 8192)
        #expect(decoded.defaultModel == true)
        #expect(decoded.pinned == true)
        #expect(decoded.temperature == 0.4)
    }

    @Test("defaults are unset (nil / false) so omitted field = inherit global")
    func defaultsUnset() {
        let cfg = ModelSamplingConfig.default
        #expect(cfg.maxContextWindow == nil)
        #expect(cfg.defaultModel == false)
        #expect(cfg.pinned == false)
        #expect(cfg.reasoningEffort == nil)
    }

    @Test("isDefault becomes false when any per-model flag is set")
    func isDefaultSensitivity() {
        let base = ModelSamplingConfig.default
        #expect(base.isDefault)

        var a = ModelSamplingConfig.default
        a.maxContextWindow = 4096
        #expect(!a.isDefault)

        var b = ModelSamplingConfig.default
        b.defaultModel = true
        #expect(!b.isDefault)

        var c = ModelSamplingConfig.default
        c.pinned = true
        #expect(!c.isDefault)

        // reasoning_effort: word-table stored verbatim (wire-not-brain).
        var d = ModelSamplingConfig.default
        d.reasoningEffort = "xhigh"
        #expect(!d.isDefault)
    }
}

// MARK: - PATCH partial patch merges new fields

@Suite("ModelSamplingPatch.toConfig — merge surface")
struct PerModelPatchMergeTests {
    @Test("partial patch sets only provided fields, rest inherit default")
    func partial() throws {
        let json = #"{"pinned": true, "max_context_window": 4096}"#
        let patch = try JSONDecoder().decode(
            ModelSamplingPatch.self,
            from: Data(json.utf8)
        )
        let cfg = patch.toConfig()
        #expect(cfg.pinned == true)
        #expect(cfg.maxContextWindow == 4096)
        // Not provided → stays default.
        #expect(cfg.defaultModel == false)
        #expect(cfg.temperature == 0.7)
    }

    @Test("default_model can be reset to false via patch")
    func resetDefault() throws {
        // Start from a default-flagged config, then a patch clearing it must clear it.
        let json = #"{"default_model": false, "pinned": false}"#
        let patch = try JSONDecoder().decode(
            ModelSamplingPatch.self,
            from: Data(json.utf8)
        )
        let cfg = patch.toConfig()
        #expect(cfg.defaultModel == false)
        #expect(cfg.pinned == false)
    }
}

// MARK: - GET response echo

@Suite("ModelSamplingResponse — new fields are observable")
struct PerModelResponseEchoTests {
    @Test("response surfaces maxContextWindow/defaultModel/pinned")
    func echo() throws {
        var cfg = ModelSamplingConfig.default
        cfg.maxContextWindow = 32768
        cfg.defaultModel = true
        cfg.pinned = true
        let resp = ModelSamplingResponse(config: cfg)
        let data = try JSONEncoder().encode(resp)
        #expect(data.contains(Data("max_context_window".utf8)))
        #expect(data.contains(Data("\"default_model\":true".utf8)))
        #expect(data.contains(Data("\"pinned\":true".utf8)))
    }
}

// MARK: - Pure decision helpers

@Suite("resolveModel — omits model → default; explicit wins")
struct ResolveModelTests {
    @Test("explicit non-empty model wins over default")
    func explicitWins() {
        #expect(resolveModel(requested: "gemma", defaultModelId: "qwen") == "gemma")
    }

    @Test("empty-string model falls back to default")
    func emptyFallsBack() {
        #expect(resolveModel(requested: "", defaultModelId: "qwen") == "qwen")
    }

    @Test("nil model falls back to default")
    func nilFallsBack() {
        #expect(resolveModel(requested: nil, defaultModelId: "qwen") == "qwen")
    }

    @Test("nil model + no default → nil (caller 400s)")
    func bothNil() {
        #expect(resolveModel(requested: nil, defaultModelId: nil) == nil)
    }

    @Test("empty-string model + no default → nil")
    func bothEmpty() {
        #expect(resolveModel(requested: "", defaultModelId: nil) == nil)
    }
}

@Suite("promptExceedsContextWindow — optional cap only tightens")
struct PromptExceedsContextTests {
    @Test("nil cap never rejects (inherit global limit)")
    func nilCap() {
        #expect(!promptExceedsContextWindow(promptTokens: 1_000_000, maxContextWindow: nil))
    }

    @Test("zero/negative cap never rejects")
    func nonpositiveCap() {
        #expect(!promptExceedsContextWindow(promptTokens: 100, maxContextWindow: 0))
        #expect(!promptExceedsContextWindow(promptTokens: 100, maxContextWindow: -5))
    }

    @Test("prompt over cap rejects")
    func overCap() {
        #expect(promptExceedsContextWindow(promptTokens: 4097, maxContextWindow: 4096))
    }

    @Test("prompt equal to cap does not reject (boundary)")
    func equalCap() {
        #expect(!promptExceedsContextWindow(promptTokens: 4096, maxContextWindow: 4096))
    }

    @Test("prompt under cap does not reject")
    func underCap() {
        #expect(!promptExceedsContextWindow(promptTokens: 4095, maxContextWindow: 4096))
    }
}

@Suite("pureDefaultModelId — deterministic first-flagged")
struct PureDefaultModelIdTests {
    @Test("returns first (lexicographic) defaultModel-flagged id")
    func firstFlagged() {
        var a = ModelSamplingConfig.default
        a.defaultModel = true
        var b = ModelSamplingConfig.default
        b.defaultModel = true
        let defaults = ["bbb": b, "aaa": a, "ccc": ModelSamplingConfig.default]
        #expect(pureDefaultModelId(defaults: defaults) == "aaa")
    }

    @Test("nil when no model flagged")
    func noneFlagged() {
        let defaults = ["a": ModelSamplingConfig.default, "b": ModelSamplingConfig.default]
        #expect(pureDefaultModelId(defaults: defaults) == nil)
    }

    @Test("nil when empty")
    func empty() {
        #expect(pureDefaultModelId(defaults: [:]) == nil)
    }
}

@Suite("isPinnedExempt — key model vs pinned set")
struct IsPinnedExemptTests {
    @Test("pinned model id is exempt")
    func pinnedHit() {
        #expect(isPinnedExempt(poolKey: "gemma:conv-1", pinnedIDs: ["gemma"]))
    }

    @Test("non-pinned model id is not exempt")
    func pinnedMiss() {
        #expect(!isPinnedExempt(poolKey: "qwen:conv-1", pinnedIDs: ["gemma"]))
    }

    @Test("multiple pinned ids only match listed ones")
    func multiHit() {
        let ids: Set<String> = ["gemma", "llama"]
        #expect(isPinnedExempt(poolKey: "llama:conv-1", pinnedIDs: ids))
        #expect(!isPinnedExempt(poolKey: "mistral:conv-1", pinnedIDs: ids))
    }

    @Test("empty pinned set exempts nothing")
    func emptySet() {
        #expect(!isPinnedExempt(poolKey: "gemma:conv-1", pinnedIDs: []))
    }

    @Test("conversation id in tail does not spoof the model segment")
    func noSpoofing() {
        // A model whose id literally contains ":" is not a realistic case, but the
        // first-segment split must not be fooled by a coincidental "gemma" in the
        // conversation id of a different model.
        #expect(!isPinnedExempt(poolKey: "other:gemma-conv", pinnedIDs: ["gemma"]))
    }
}

// MARK: - Fast Path cascade (fastPathDefaults) — single source of truth

@Suite("SamplingConfiguration.fastPathDefaults — per-model cascade")
struct FastPathCascadeTests {
    private func fullyCustom() -> ModelSamplingConfig {
        var d = ModelSamplingConfig.default
        d.seed = 42
        d.mode = .topK(25)
        d.minP = 0.1
        d.repetitionPenalty = 1.2
        d.repetitionPenaltyWindow = 64
        d.presencePenalty = 0.6
        d.frequencyPenalty = 0.3
        d.prefill = PrefillConfig(stepSize: 1024, chunking: .remainder)
        d.maxKVSize = 8192
        d.repetitionContextSize = 40
        d.presenceContextSize = 50
        d.frequencyContextSize = 60
        return d
    }

    @Test("request-surface only → all 10 per-model fields cascade from runtime")
    func fullCascade() {
        let s = SamplingConfiguration(temperature: 0.9, topP: 0.9, topK: 40)
            .fastPathDefaults(fullyCustom())
        #expect(s.seed == 42)
        #expect(s.mode == .topK(25))
        #expect(abs(s.minP! - 0.1) < 1e-6)  // minP sourced from Float → tolerance assert
        #expect(s.repetitionPenalty == 1.2)
        #expect(s.repetitionPenaltyWindow == 64)
        #expect(abs(s.presencePenalty! - 0.6) < 1e-6)
        #expect(abs(s.frequencyPenalty! - 0.3) < 1e-6)
        #expect(s.prefill == PrefillConfig(stepSize: 1024, chunking: .remainder))
        #expect(s.maxKVSize == 8192)
        #expect(s.repetitionContextSize == 40)
        #expect(s.presenceContextSize == 50)
        #expect(s.frequencyContextSize == 60)
        // Request-level surface preserved untouched.
        #expect(s.temperature == 0.9)
        #expect(s.topP == 0.9)
        #expect(s.topK == 40)
    }

    @Test("request-level value already set → not overridden by runtime")
    func requestWins() {
        let s = SamplingConfiguration(seed: 7, mode: .greedy, minP: 0.5)
            .fastPathDefaults(fullyCustom())
        #expect(s.seed == 7)
        #expect(s.mode == .greedy)
        #expect(s.minP == 0.5)
    }

    @Test("presence/frequency penalty 0 sentinel → nil (not explicit 0.0)")
    func penaltyZeroIsNil() {
        var d = ModelSamplingConfig.default
        d.presencePenalty = 0
        d.frequencyPenalty = 0
        let s = SamplingConfiguration().fastPathDefaults(d)
        #expect(s.presencePenalty == nil)
        #expect(s.frequencyPenalty == nil)
    }

    @Test("presence/frequency penalty non-zero → applied")
    func penaltyApplied() {
        var d = ModelSamplingConfig.default
        d.presencePenalty = 0.8
        d.frequencyPenalty = 0.4
        let s = SamplingConfiguration().fastPathDefaults(d)
        #expect(abs(s.presencePenalty! - 0.8) < 1e-6)
        #expect(abs(s.frequencyPenalty! - 0.4) < 1e-6)
    }

    @Test("defaults config → no field forced (request surface stays as-is)")
    func defaultsNoOp() {
        let s = SamplingConfiguration(temperature: 1.0)
            .fastPathDefaults(ModelSamplingConfig.default)
            .normalized()
        #expect(s.temperature == 1.0)
        #expect(s.seed == nil)
        #expect(s.mode == nil)
        #expect(s.minP == nil)
        #expect(s.presencePenalty == nil)
        #expect(s.frequencyPenalty == nil)
        #expect(s.maxKVSize == nil)
        #expect(s.prefill == .default)
    }
}
