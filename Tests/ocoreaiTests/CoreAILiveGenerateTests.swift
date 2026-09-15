// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// CoreAI live generation — end‑to‑end proof that ocreai's vendored CoreAI
// engine pipeline (`EngineFactory` → `PreparedModel` → `CoreAI*Engine`)
// produces real tokens from a real `.aimodel` bundle on macOS 27.
//
// Complements EngineVariantRoutingTests.swift (routing only, no asset).
//
// Uses an on‑disk bundle produced by `uv run coreai.llm.export qwen3-0.6b`
// + `coreai-build compile --preferred-compute neural-engine`. Skipped
// cleanly if the bundle is not on disk (live‑asset proof, not a unit
// test).
//
import Foundation
import Testing

#if canImport(CoreAI) && canImport(Tokenizers) && canImport(Hub)

@testable import ocoreai
import CoreAI
import CoreML
import Tokenizers  // AutoTokenizer / Tokenizers.Tokenizer
import Hub  // HubApi.shared (same path TokenizerManager uses)

@Suite("CoreAI live generate (bundle on disk)")
struct CoreAILiveGenerateTests {

    // Bundle produced locally by `uv run coreai.llm.export qwen3-0.6b --platform macOS`
    // (+ `coreai-build compile --preferred-compute neural-engine`) at the default
    // scratch path. Override via OCOREAI_COREAI_LIVE_ASSET_DIR on machines/CI
    // where the .aimodel bundle lives elsewhere; if neither is present the test
    // SKIPs quietly — live-asset proof, not a unit gate. metadata.json on disk
    // confirms vocab=151936 / ctx=8192 / function=main.
    private static var bundlePath: String {
        (ProcessInfo.processInfo.environment["OCOREAI_COREAI_LIVE_ASSET_DIR"]
            .map { $0 + "/qwen3-0.6b/qwen3_0_6b_4bit_dynamic" })
            ?? "/tmp/agent_test/coreai_assets/qwen3-0.6b/qwen3_0_6b_4bit_dynamic"
    }
    private let metadataJSON = """
        {"name": "qwen3-0.6b", "vocab_size": 151936, "max_context_length": 8192, "function": "main"}
        """

    private var bundleRoot: URL { URL(fileURLWithPath: Self.bundlePath) }
    private var aimodelDir: URL {
        bundleRoot.appendingPathComponent("qwen3_0_6b_4bit_dynamic.aimodel")
    }
    private var tokenizerDir: URL { bundleRoot.appendingPathComponent("tokenizer") }

    private func isLive() -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let hashExists = fm.fileExists(atPath: aimodelDir.appendingPathComponent("main.hash").path)
        let mlirbExists = fm.fileExists(
            atPath: aimodelDir.appendingPathComponent("main.mlirb").path)
        return hashExists && mlirbExists
            && fm.fileExists(
                atPath: tokenizerDir.appendingPathComponent("tokenizer.json").path,
                isDirectory: &isDir)
    }

    @Test("EngineFactory + vendored CoreAI engine → real tokens from .aimodel bundle")
    func liveGenerateFromRealBundle() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            Issue.record("requires macOS 27")
            return
        }
        guard isLive() else {
            // Live‑asset proof: skip quietly when the bundle is not on disk.
            print("[COREAI-LIVE-GEN] SKIP — bundle not on disk at \(bundleRoot.path)")
            return
        }

        // 1. Tokenize with the bundle's own tokenizer (same AutoTokenizer path
        //    TokenizerManager.swift:110 uses). Native swift-transformers API.
        let tokenizer: any Tokenizers.Tokenizer = try await AutoTokenizer.from(
            modelFolder: tokenizerDir,
            hubApi: HubApi.shared
        )
        let messages: [[String: any Sendable]] = [
            [
                "role": "user",
                "content":
                    "Say the single word 'banana'. Reply with exactly the word 'banana' and nothing else.",
            ]
        ]
        let promptTokens = try tokenizer.applyChatTemplate(messages: messages).map(Int32.init)
        #expect(promptTokens.count > 4, "prompt should tokenize to several tokens")
        let _ = tokenizer  // keep tokenizer alive till after decode

        // 2. Build the engine via ocreai's own factory. Point at the .aimodel
        //    dir (metadata.json → assets.main), NOT bundleRoot — the same
        //    "blind try on wrong dir" footgun as the prewarm 09‑15 fix.
        print(
            "[COREAI-LIVE-GEN] step=2a about-to-EngineFactory.createEngine url=\(aimodelDir.path)")
        let engine: any InferenceEngine = try await EngineFactory.createEngine(
            config: metadataJSON.data(using: .utf8)!,
            modelURL: aimodelDir,
            options: EngineOptions()
        )
        print("[COREAI-LIVE-GEN] step=2b engine-created \(type(of: engine))")

        // 3. Generate (greedy, max 32 tokens) and stop on any terminal
        //    stopReason (eos / maxTokens / stopSequence / cancelled / error).
        var generated: [Int32] = []
        print("[COREAI-LIVE-GEN] step=3a about-to-generate prompt=\(promptTokens.count)t")
        let seq: any InferenceOutputSequence =
            try await engine.generate(
                with: promptTokens,
                samplingConfiguration: SamplingConfiguration(
                    temperature: 0, topK: 1, mode: .greedy
                ),
                inferenceOptions: InferenceOptions()
            )
        print("[COREAI-LIVE-GEN] step=3b generator-created \(type(of: seq))")
        for try await out in seq {
            generated.append(out.tokenId)
            if generated.count >= 32 { break }
            if let reason = seq.stopReason, reason != .error { break }
        }
        print(
            "[COREAI-LIVE-GEN] step=3c loop-ended generated=\(generated.count) stop=\(String(describing: seq.stopReason))"
        )

        #expect(!generated.isEmpty, "expected at least one generated token from ANE")

        // 4. Detokenize — confirms decodable text and gives us a readable
        //    assertion artifact.
        let text = tokenizer.decode(tokens: generated.map(Int.init)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        print("[COREAI-LIVE-GEN] prompt=\(promptTokens.count)t → generated=\(generated.count)t")
        print("[COREAI-LIVE-GEN] output=\(text.prefix(160))")

        // 5. Release the model + KV cache cleanly.
        try await engine.reset()
    }
}

#endif
