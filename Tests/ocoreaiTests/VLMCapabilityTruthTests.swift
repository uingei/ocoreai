// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// VLM capability truth — one predicate, every surface agrees.
///
/// Bug class this pins: two partial predicates for one fact. Discovery
/// (`ModelStore.discoverReady`) tested `preprocessor_config.json` only; the loader
/// (`MLXModelLoader.isVLMModel`) tested `processor_config.json` only. On the
/// installed default model (gemma-4-e2b-it-4bit — ships `processor_config.json`,
/// not `preprocessor_config.json`) the engine loaded a working VLM and answered an
/// image correctly ("Red"), while `GET /v1/models` published `vlm:false`. Older
/// checkpoints flip the direction: advertised as VLM, loaded as text-only LLM.

import Foundation
import Testing

@testable import ocoreai

private func makeDir(files: [String]) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vlm_truth_\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in files {
        let url = dir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
    }
    return dir
}

@Suite("ModelStore.hasVisionProcessor — canonical predicate")
struct HasVisionProcessorTests {

    @Test("neither config present is not a VLM")
    func neitherFile() throws {
        let dir = try makeDir(files: ["config.json", "tokenizer.json"])
        #expect(!ModelStore.hasVisionProcessor(at: dir))
    }

    @Test("legacy preprocessor_config.json is a VLM")
    func legacyOnly() throws {
        let dir = try makeDir(files: ["config.json", "preprocessor_config.json"])
        #expect(ModelStore.hasVisionProcessor(at: dir))
    }

    @Test("modern processor_config.json is a VLM (gemma-4 / qwen3.5 shape)")
    func modernOnly() throws {
        let dir = try makeDir(files: ["config.json", "processor_config.json"])
        #expect(ModelStore.hasVisionProcessor(at: dir))
    }

    @Test("both configs present is a VLM")
    func bothFiles() throws {
        let dir = try makeDir(files: ["preprocessor_config.json", "processor_config.json"])
        #expect(ModelStore.hasVisionProcessor(at: dir))
    }

    @Test("loader and discovery agree — one truth source, not two")
    func loaderAndDiscoveryAgree() throws {
        for files in [
            [String](),
            ["preprocessor_config.json"],
            ["processor_config.json"],
            ["preprocessor_config.json", "processor_config.json"],
        ] {
            let dir = try makeDir(files: files)
            #expect(
                MLXModelLoader.isVLMModel(at: dir) == ModelStore.hasVisionProcessor(at: dir),
                "loader and discovery disagreed for \(files)"
            )
        }
    }
}

@Suite("VLM flag survives the list-models wire parse")
struct VLMWireParseTests {

    @Test("reads the key the pool writes (\"vlm\"), not \"specialized\"")
    func readsVlmKey() {
        // EnginePool.listModels() publishes `entry["vlm"]`; "specialized" is the
        // CoreAI ANE flag and is absent on macOS 26, so parsers reading it
        // reported every MLX vision model as text-only. `ModelID.fromListModels` is
        // the one UI-side parse of that fact (ModelManager refreshes the list
        // through it), so the pin sits on the path that ships.
        let entry = ["id": "mlx-community/gemma-4-e2b-it-4bit", "vlm": "true"]
        #expect(ModelID.fromListModels(entry).isVlm)
    }

    @Test("absent vlm key reports false, never guesses true")
    func absentMeansFalse() {
        let entry = ["id": "some/text-model"]
        #expect(!ModelID.fromListModels(entry).isVlm)
    }
}
