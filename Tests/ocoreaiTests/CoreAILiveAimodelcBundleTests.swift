// CoreAI live generate — production surface: the model BUNDLE directory
// (metadata.json + tokenizer/ + <name>.aimodel + N× <name>.hXX.aimodelc).
//
// CoreAILiveGenerateTests drives the raw .aimodel dir. Upstream llm-runner
// (206.1 tok/s on the same bundle, hardware-specialized) drives the bundle
// directory — that is the surface ocrei's `resolveCoreAIModelURL` (no-op)
// forwards to `AIModel(contentsOf:)`. This test closes that gap: ocrei's own
// EngineFactory + real metadata.json config + bundle-dir load.
//
// Skips cleanly when the bundle (incl. its .aimodelc variants) is not on disk.

import Foundation
import Hub
import Testing
import Tokenizers

#if canImport(CoreAI)
@testable import ocoreai
@Suite("CoreAI live generate — bundle directory (metadata + specialized assets)")
struct CoreAILiveBundleDirTests {
    private static var bundleRoot: URL {
        let root =
            ProcessInfo.processInfo.environment["OCOREAI_COREAI_LIVE_ASSET_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("qwen3-0.6b") }
            ?? URL(fileURLWithPath: "/tmp/agent_test/coreai_assets/qwen3-0.6b")
        return root.appendingPathComponent("qwen3_0_6b_4bit_dynamic")
    }

    private static func bundleAlive() -> Bool {
        let fm = FileManager.default
        let root = bundleRoot
        for name in ["metadata.json", "tokenizer/tokenizer.json"] {
            if !fm.fileExists(atPath: root.appendingPathComponent(name).path) {
                return false
            }
        }
        return (try? fm.contentsOfDirectory(atPath: root.path))?.contains {
            $0 == "qwen3_0_6b_4bit_dynamic.aimodel" || $0.hasSuffix(".aimodelc")
        } ?? false
    }

    /// ocrei `parseModelConfig` keys: top-level snake_case
    /// (name / vocab_size / max_context_length / function). The export pipeline's
    /// metadata.json nests those under `language.*` — lift them to the top level
    /// the engine expects.
    private static func configJSON(from metaURL: URL) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))
        guard let dict = obj as? [String: Any] else {
            return
                #"{"name":"qwen3-0.6b","vocab_size":151936,"max_context_length":8192,"function":"main"}"#
        }
        let lang = (dict["language"] as? [String: Any]) ?? [:]
        let name = dict["name"] as? String ?? "qwen3-0.6b"
        let vocab = (lang["vocab_size"] as? Int) ?? 151936
        let ctx = (lang["max_context_length"] as? Int) ?? 8192
        return
            #"{"name":"\#(name)","vocab_size":\#(vocab),"max_context_length":\#(ctx),"function":"main"}"#
    }

    @Test("EngineFactory over bundle dir (raw .aimodel + hardware-specialized .aimodelc)")
    func generateFromBundleDirectory() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            print("[COREAI-BUNDLE-DIR] SKIP — requires macOS 27")
            return
        }
        guard Self.bundleAlive() else {
            print("[COREAI-BUNDLE-DIR] SKIP — bundle dir with .aimodelc assets not on disk")
            return
        }

        // Config from the bundle's REAL metadata.json (not "{}" defaults):
        // ocrei parseModelConfig snake_case keys (name / vocab_size /
        // max_context_length / function).
        let metaURL = Self.bundleRoot.appendingPathComponent("metadata.json")
        let configJSON = (try? Self.configJSON(from: metaURL)) ?? #""#
        print("[COREAI-BUNDLE-DIR] config=\(configJSON) bundle=\(Self.bundleRoot.path)")

        // Tokenize with the bundle's own tokenizer.
        let tokenizerDir = Self.bundleRoot.appendingPathComponent("tokenizer")
        let tokenizer: any Tokenizers.Tokenizer = try await AutoTokenizer.from(
            modelFolder: tokenizerDir,
            hubApi: HubApi.shared
        )
        let messages: [[String: any Sendable]] = [
            [
                "role": "user",
                "content": "Answer with a single word: what is the capital of France?",
            ]
        ]
        let promptTokens = try tokenizer.applyChatTemplate(messages: messages).map(Int32.init)

        // Engine through ocrei's OWN factory — production surface = bundle dir.
        let engine: any InferenceEngine = try await EngineFactory.createEngine(
            config: configJSON.data(using: .utf8)!,
            modelURL: Self.bundleRoot,
            options: EngineOptions()
        )
        print("[COREAI-BUNDLE-DIR] engine=\(type(of: engine))")

        var generated: [Int32] = []
        let seq: any InferenceOutputSequence = try await engine.generate(
            with: promptTokens,
            samplingConfiguration: SamplingConfiguration(temperature: 0, topK: 1, mode: .greedy),
            inferenceOptions: InferenceOptions()
        )
        for try await out in seq {
            generated.append(out.tokenId)
            if generated.count >= 48 { break }
            if let reason = seq.stopReason, reason != .error { break }
        }
        let text = tokenizer.decode(tokens: generated.map(Int.init)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        print("[COREAI-BUNDLE-DIR] prompt=\(promptTokens.count)t generated=\(generated.count)t")
        print("[COREAI-BUNDLE-DIR] output=\(text.prefix(200))")
        #expect(generated.count > 0, "bundle-directory engine produced no tokens")
        #expect(
            text.contains("Paris") || text.lowercased().contains("paris"),
            "expected 'Paris' — got '\(text.prefix(80))'")
        try await engine.reset()
    }
}
#endif
