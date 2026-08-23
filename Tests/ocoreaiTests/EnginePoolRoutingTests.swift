// EnginePoolRoutingTests.swift — Regression gate for load-model routing
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
}
