// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Exact-value verification that the MTP drafter-type registry (shared with
/// upstream `MTPDrafterModelFactory`) covers:
///   - Gemma-4 assistant drafter (separate assistant checkpoint)
///   - Qwen3.5 / Qwen3.6 self-spec drafter (mtp.* weights in the main model's checkpoint)
///
/// These are the ONLY two MTP-drafter families the ocreai EnginePool guard
/// (`config.specDecoding.mode == "mtp"`) accepts. The guard at
/// `EnginePool.swift:643` branches on model-id substrings but relies on the
/// registry's creator entries (`MTPDrafterTypeRegistry.shared`) to actually
/// resolve a `model_type` → drafter. A missing registration means the
/// guard passes but the load throws `ModelFactoryError.unsupportedModelType`.
///
/// Upstream registration surface (mlx-swift-lm #351):
///   - `Gemma4AssistantRegistration.register()` → "gemma4_assistant", "gemma4_unified_assistant"
///   - `Qwen35TextMTPRegistration.register()` → "qwen3_5", "qwen3_5_text", "qwen3_5_mtp", "qwen3_5_moe"
///   - `Qwen35VLMMTPRegistration.register()`  → "qwen3_5" (VLM match), "qwen3_5_mtp", "qwen3_5_moe"
///
/// Qwen3.6 rides the same "qwen3_5*" type-string family in the upstream
/// registration comments — one registration covers both 3.5 and 3.6.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@testable import ocoreai

@Suite("MTP DrafterType Registration surface")
struct MTPDrafterRegistrationSurfaceTests {

    /// Ensure the registration Task in `EnginePool.init` has been exercised
    /// for the three upstream registration families. Idempotent (actor-isolated,
    /// first write wins; `registerModelType` appends `matches`-tagged entries).
    private static func ensureRegistered() async {
        // Text + VLM Qwen3.5/3.6, plus Gemma-4 assistant. Order does not matter —
        // each registration family owns a distinct model_type string and, for the
        // shared "qwen3_5", the config-shape predicate (`matches:`) disambiguates.
        await Gemma4AssistantRegistration.register()
        await Qwen35TextMTPRegistration.register()
        await Qwen35VLMMTPRegistration.register()
    }

    // MARK: - Qwen3.5 (dense text)

    @Test
    func qwen35DenseTextIsRegistered() async {
        await Self.ensureRegistered()
        // "qwen3_5" is the model_type of mlx-community/Qwen3.5-4B-… (dense text).
        #expect(
            await MTPDrafterTypeRegistry.shared.contains("qwen3_5") == true,
            "Qwen3.5 dense-text drafter must be in the registry")
    }

    @Test
    func qwen35TextAliasIsRegistered() async {
        await Self.ensureRegistered()
        // "qwen3_5_text" — text-alias registration (no vision_config in config.json).
        #expect(await MTPDrafterTypeRegistry.shared.contains("qwen3_5_text") == true)
    }

    // MARK: - Qwen3.5 (MoE text)

    @Test
    func qwen35MoEIsRegistered() async {
        await Self.ensureRegistered()
        #expect(await MTPDrafterTypeRegistry.shared.contains("qwen3_5_moe") == true)
    }

    // MARK: - Qwen3.5 (standalone-MTP checkpoint)

    @Test
    func qwen35StandaloneMtpIsRegistered() async {
        await Self.ensureRegistered()
        // "qwen3_5_mtp" — preconvertedNorms drafter (separate checkpoint with mtp.* keys).
        #expect(await MTPDrafterTypeRegistry.shared.contains("qwen3_5_mtp") == true)
    }

    // MARK: - Gemma-4 assistant drafter (separate checkpoint)

    @Test
    func gemma4AssistantIsRegistered() async {
        await Self.ensureRegistered()
        // "gemma4_assistant" — the drafter type for gemma-4-26B/31B assistant repos.
        let present = await MTPDrafterTypeRegistry.shared.contains("gemma4_assistant")
        #expect(
            present == true,
            "Gemma-4 assistant drafter must be registered (EnginePool depends on it)")
    }

    // MARK: - Negative: families NOT in ocreai's guard must be unregistered

    @Test
    func qwen34IsNotRegistered() async {
        await Self.ensureRegistered()
        // Qwen3.4 is the preceding generation — not in the Qwen3.5/3.6 self-spec family.
        // If this ever flips to true, the upstream registration surface changed and
        // our EnginePool guard (which keys off "qwen3.5" / "qwen3.6") is still correct,
        // but we should re-audit which families ocreai advertises.
        #expect(await MTPDrafterTypeRegistry.shared.contains("qwen3_4") == false)
    }

    @Test
    func llama4IsNotRegistered() async {
        await Self.ensureRegistered()
        // Llama-4 does not have an upstream MTP drafter — negative sentinel.
        #expect(await MTPDrafterTypeRegistry.shared.contains("llama4") == false)
    }
}
