// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Exact-value verification that the MTP drafter-type registry (shared with
/// upstream `MTPDrafterModelFactory`) covers:
///   - Gemma-4 assistant drafter (separate assistant checkpoint)
///   - Qwen3.5 / Qwen3.6 / Qwen3.8 self-spec drafter (mtp.* weights in the main model's checkpoint)
///
/// These are the ONLY MTP-drafter families the ocoreai EnginePool id-whitelist
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

@Suite("MTP self-spec admission gate (pureMTPDrafterSelection)")
struct MTPAdmissionGateTests {
    // Exact-value pinning of the pure admission + drafter-model-id decision that
    // `EnginePool.loadModel`'s self-spec guard calls (`if mode == "mtp" && !hasMTPDrafter`).
    // This is the single source of the generation whitelist, so a regression of the
    // Qwen3.8 self-spec path (the bug this round fixed) is caught here, not just documented.
    //
    // Note: the `mode == "mtp"` gate lives at the call site (loadModel), not in this pure
    // function — the function only decides "which family is admitted, and which draft id".

    @Test
    func qwen35IsAdmittedAndSelfSpecs() {
        let sel = pureMTPDrafterSelection(modelId: "qwen3.5-4b")
        #expect(sel.admit == true, "Qwen3.5 must be admitted to self-spec MTP")
        #expect(
            sel.drafterModelId == "qwen3.5-4b", "Qwen3.5 must self-spec from its own checkpoint")
    }

    @Test
    func qwen36IsAdmittedAndSelfSpecs() {
        let sel = pureMTPDrafterSelection(modelId: "qwen3.6-4b")
        #expect(sel.admit == true, "Qwen3.6 must be admitted to self-spec MTP")
        #expect(
            sel.drafterModelId == "qwen3.6-4b", "Qwen3.6 must self-spec from its own checkpoint")
    }

    /// The regression this fix exists for: Qwen3.8-27B's config.json carries
    /// `model_type: "qwen3_5"` + `mtp_num_hidden_layers: 1` (the qwen3.5 MTP arch).
    /// The old guard was `contains("qwen3.5") || contains("qwen3.6")` → "qwen3.8-27b"
    /// matched NEITHER → MTP was silently dropped on ocoreai's flagship model.
    @Test
    func qwen38IsAdmittedAndSelfSpecs() {
        let sel = pureMTPDrafterSelection(modelId: "qwen3.8-27b")
        #expect(
            sel.admit == true,
            "Qwen3.8 (model_type qwen3_5, mtp_num_hidden_layers 1) must be admitted to self-spec MTP"
        )
        #expect(
            sel.drafterModelId == "qwen3.8-27b", "Qwen3.8 must self-spec from its own checkpoint")
    }

    @Test
    func qwen38UppercasedRepoNameIsStillAdmitted() {
        // model id is compared case-insensitively (lowercased before the guard).
        let sel = pureMTPDrafterSelection(modelId: "Qwen3.8-27B-4bit")
        #expect(sel.admit == true, "case must not affect admission")
        #expect(sel.drafterModelId == "Qwen3.8-27B-4bit")
    }

    // MARK: - Gemma-4: separate assistant checkpoint, selected by size marker
    // (the seam returns the real upstream HuggingFace assistant asset id)

    @Test
    func gemma4_12BIsAdmittedAndLoads12BAssistantAsset() {
        let sel = pureMTPDrafterSelection(modelId: "gemma-4-12b-it")
        #expect(sel.admit == true)
        #expect(sel.drafterModelId == "mlx-community/gemma-4-12B-it-assistant-bf16")
    }

    @Test
    func gemma4_31BIsAdmittedAndLoads31BAssistantAsset() {
        let sel = pureMTPDrafterSelection(modelId: "gemma-4-31b-it")
        #expect(sel.admit == true)
        #expect(sel.drafterModelId == "mlx-community/gemma-4-31B-it-assistant-bf16")
    }

    @Test
    func gemma4_26BDefaultIsAdmittedAndLoads26BA4BAssistantAsset() {
        // Neither "12" nor "31" → the 26B-A4B default assistant asset.
        let sel = pureMTPDrafterSelection(modelId: "gemma-4-26b-a4b-it")
        #expect(sel.admit == true)
        #expect(
            sel.drafterModelId == "mlx-community/gemma-4-26B-A4B-it-assistant-bf16",
            "Gemma-4 uses a separate assistant checkpoint for the drafter")
    }

    // MARK: - Negative: non-MTP families are NOT admitted (guard stays a guard)

    @Test
    func llamaIsNotAdmitted() {
        let sel = pureMTPDrafterSelection(modelId: "llama4-8b")
        #expect(
            sel.admit == false,
            "unknown family → no known drafter → skip to prevent token-table mismatch")
        #expect(sel.drafterModelId == nil)
    }

    @Test
    func gptIsNotAdmitted() {
        let sel = pureMTPDrafterSelection(modelId: "gpt-4-turbo")
        #expect(sel.admit == false)
        #expect(sel.drafterModelId == nil)
    }

    @Test
    func qwen25IsNotAdmitted() {
        let sel = pureMTPDrafterSelection(modelId: "qwen2.5-32b")
        #expect(sel.admit == false, "pre-3.5 generation is not in the self-spec family")
        #expect(sel.drafterModelId == nil)
    }
}
