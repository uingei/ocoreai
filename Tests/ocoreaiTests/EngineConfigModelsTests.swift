import Foundation
import Testing

@testable import ocoreai

@Suite("EnginePoolConfig models.<id> parsing (09-09: enabled gate)")
struct EngineConfigModelsTests {
    private func makeApp(
        modelId: String? = nil,
        source: String? = nil,
        enabled: Bool? = nil
    ) -> AppConfig {
        var app = AppConfig()
        if let modelId {
            var e = ModelConfigEntry.defaultEntry
            e.modelId = modelId
            e.source = source ?? "huggingface"
            e.enabled = enabled ?? true
            app.models["default"] = e
        }
        return app
    }

    @Test func defaultEntryEnabledHfPrefixesHf() {
        let cfg = EnginePoolConfig(
            from: makeApp(modelId: "org/repo", source: "huggingface", enabled: true),
            logger: .init(label: "t")
        )
        #expect(cfg.defaultModelId == "hf:org/repo")
    }

    @Test func defaultEntryEnabledNonHfKeepsRaw() {
        let cfg = EnginePoolConfig(
            from: makeApp(
                modelId: "mlx-community/gemma-4-e2b-it-4bit", source: "modelscope", enabled: true),
            logger: .init(label: "t")
        )
        #expect(cfg.defaultModelId == "mlx-community/gemma-4-e2b-it-4bit")
    }

    @Test func defaultEntryDisabledFallsBackToBuiltin() {
        let cfg = EnginePoolConfig(
            from: makeApp(modelId: "org/repo", source: "huggingface", enabled: false),
            logger: .init(label: "t")
        )
        #expect(cfg.defaultModelId == EnginePoolConfig.default.defaultModelId)
        #expect(cfg.defaultModelId == "mlx-community/gemma-4-e2b-it-4bit")
    }

    @Test func noDefaultEntryFallsBackToBuiltin() {
        var app = AppConfig()
        app.models = [:]
        let cfg = EnginePoolConfig(from: app, logger: .init(label: "t"))
        #expect(cfg.defaultModelId == EnginePoolConfig.default.defaultModelId)
    }
}
