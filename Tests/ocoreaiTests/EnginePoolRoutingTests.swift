// EnginePoolRoutingTests.swift — Regression gate for load-model routing
import Foundation
import Testing

@testable import ocoreai

// Regression guard: the CoreAI-specialization branch in EnginePool.loadModel
// must only fire for a real local file path. Hub repo ids ("hf:org/model",
// "mscope:org/model", "org/model") are downloads — they must route to the MLX
// leg. Before the fix they were misdetected, tried CoreAI on a bogus path,
// and silently fell back to an empty stub (no download, no load happened).
@Suite("EnginePool — local-vs-hub routing decision (isHubModelIdentifier)")
struct EnginePoolRoutingTests {

    @Test("Hub identifiers are never local files")
    func hubIdsAreNotLocal() {
        #expect(isHubModelIdentifier("hf:Qwen/Qwen2.5-0.5B-Instruct") == true)
        #expect(isHubModelIdentifier("mscope:Qwen/Qwen2.5-7B-Instruct") == true)
        #expect(isHubModelIdentifier("Qwen/Qwen2.5-7B-Instruct") == true)
        #expect(isHubModelIdentifier("meta-llama/Llama-3.2-1B") == true)
    }

    @Test("Local file paths are never hub identifiers")
    func localPathsAreNotHubIds() {
        #expect(isHubModelIdentifier("/Users/t/models/my.safetensors") == false)
        #expect(isHubModelIdentifier("/Users/t/.ocoreai/models/Qwen2.5-0.5B-Instruct") == false)
        #expect(isHubModelIdentifier("/Users/t/Models/aimodel/my.aimodel") == false)
        #expect(isHubModelIdentifier("relative/dir/model.aimodel") == false)
        #expect(isHubModelIdentifier("a/b/c") == false)  // >1 segment ⇒ path, not org/model
        #expect(isHubModelIdentifier("org/deep/nested/repo") == false)
        #expect(isHubModelIdentifier("no-slash-here") == false)
    }

    @Test("Empty string is not a hub identifier")
    func emptyString() {
        #expect(isHubModelIdentifier("") == false)
    }

    // Regression guard (live 09-14): a bare model id like "gemma-4e2b" is not
    // a valid hub repo id (hubs require org/name) and is not a local model
    // either, so EnginePool.loadModel must 404 it up-front rather than burn
    // config+download attempts and surface the eventual failure as 503
    // "Engine unavailable".
    @Test("structurallyUnresolvableModelId — bare hub names 404, org/model names don't")
    func structural404() {
        // Bare name, never a hub repo (exists on no hub): unresolvable → 404
        #expect(structurallyUnresolvableModelId("gemma-4e2b") == true)
        #expect(structurallyUnresolvableModelId("mistral-7b") == true)
        // Org/model: a valid hub id — allowed through (404 only if the download
        // also fails later, which is an independent failure)
        #expect(structurallyUnresolvableModelId("Qwen/Qwen2.5-0.5B-Instruct") == false)
        #expect(structurallyUnresolvableModelId("mlx-community/gemma-4-e2b-it-4bit") == false)
        #expect(structurallyUnresolvableModelId("hf:Qwen/Qwen2.5-0.5B-Instruct") == false)
        #expect(structurallyUnresolvableModelId("mscope:Qwen/Qwen2.5-0.5B-Instruct") == false)
        // A real local file path that exists: never a 404 (local model)
        #expect(structurallyUnresolvableModelId("/dev/null") == false)
        // A real existing file: never a 404
        #expect(structurallyUnresolvableModelId("/etc/hosts") == false)
        // A non-existent local file: still a 404 — we don't have the weights
        #expect(structurallyUnresolvableModelId("/Users/t/does/not/exist/my.aimodel") == true)
        // Multi-segment path (a/b/c): treated as a file path, not a hub id
        #expect(structurallyUnresolvableModelId("some/relative/path/to/safetensors") == true)
        // Empty string: not a hub id, no local file, no ready dir — 404
        #expect(structurallyUnresolvableModelId("") == true)
    }

    @Test("structurallyUnresolvableModelId — existing local file is never unresolvable")
    func resolvesExistingLocalFile() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_struct_\(UUID().uuidString).safetensors")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(structurallyUnresolvableModelId(tmp.path) == false)
    }

    @Test("structurallyUnresolvableModelId — tilde expansion resolves existing files")
    func tildeExpansion() {
        // Nonexistent path under ~ : unresolvable → 404
        #expect(structurallyUnresolvableModelId("~/.ocoreai/nonexistent.aimodel") == true)
        // Tilde expands to a real existing file → NOT a 404 (the guard must
        // expand before checking existence). Place/remove a temp file under
        // an existing directory that the bare "~" expansion reaches.
        let tmp = ("~" as NSString).expandingTildeInPath + "/.ocoreai_struct_tidetest.aimodel"
        FileManager.default.createFile(atPath: tmp, contents: Data([0]))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        #expect(structurallyUnresolvableModelId("~/.ocoreai_struct_tidetest.aimodel") == false)
    }
}
