// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// GUI 模型页去重回归 — 旧代码的 id 空间撕裂。
///
/// 根因：`refreshLocalModels` 早版本用 **字符串精确匹配**去重
///   - loaded id = 已加载（canonical bare `org/repo`，如 `mlx-community/Qwen3.5-4B-MLX-4bit`）
///   - ready  id = `discoverReady()`（hub 模型带 `mscope:`/`hf:` 前缀）
/// 两者精确匹配永不命中 → 同一物理模型在 GUI 出现 2 次 + unload/delete 对带前缀那条 no-op。
///
/// 新代码 canonical（剥 `mscope:`/`hf:`/`huggingface:` 前缀）去重。本测试精确锁定：
///   - 已加载 bare vs ready `mscope:` 前缀  → 同 canonical → 去重（出现 1 次，保留 canonical id）
///   - 已加载 bare vs ready `hf:` 前缀      → 同 canonical → 去重
///   - ready 独有（`mscope:org/name`）      → 出现 1 次，id 归一为 bare
///
/// 纯函数 `mergeLocalModels`，不碰 EnginePool / 磁盘，任何环境可跑；
/// CI 不受本机 MLX metallib 噪声影响。
import Foundation
import Testing

@testable import ocoreai

final class ModelManagerMergeTests {
    private let ready = {
        // 已加载模型的 ready 副本（带 mscope 前缀）
        ModelStore.ReadyModel(
            id: "mscope:mlx-community/Qwen3.5-4B-MLX-4bit",
            weightsDir: URL(
                fileURLWithPath: "/Users/x/.ocoreai/models/mlx-community/Qwen3.5-4B-MLX-4bit"),
            isVlm: false
        )
    }()

    /// 已加载 bare + 同物理模型的 ready `mscope:`/`hf:`/`huggingface:` 副本
    /// → 三副本塌缩为一条 canonical bare id（旧 code 会留 3 条）。
    @Test
    @MainActor
    func mergeLoadedBareDedupsPrefixVariantsToCanonical() async {
        let loaded = [ModelID(id: "mlx-community/Qwen3.5-4B-MLX-4bit", isVlm: false)]
        let readyAll = [
            ready,  // mscope: 前缀
            ModelStore.ReadyModel(
                id: "hf:mlx-community/Qwen3.5-4B-MLX-4bit",
                weightsDir: URL(fileURLWithPath: "/x"), isVlm: false),
            ModelStore.ReadyModel(
                id: "huggingface:mlx-community/Qwen3.5-4B-MLX-4bit",
                weightsDir: URL(fileURLWithPath: "/x"), isVlm: false),
        ]
        let out = ModelManager.mergeLocalModels(
            loaded: loaded, ready: readyAll,
            samplingConfig: { _ in .default })
        #expect(out.0.count == 1, "三种前缀副本必须塌成 1 条, got \(out.0.count): \(out.0.map(\.id))")
        #expect(out.0.first?.id == "mlx-community/Qwen3.5-4B-MLX-4bit")
    }

    /// ready 独有（无已加载）→ 出现 1 次 + id 归一为 bare canonical（可被 EnginePool 用）。
    @Test
    @MainActor
    func readyOnlyStripsPrefixToCanonicalBareId() async {
        let out = ModelManager.mergeLocalModels(
            loaded: [], ready: [ready],
            samplingConfig: { _ in .default })
        #expect(out.0.count == 1)
        #expect(out.0.first?.id == "mlx-community/Qwen3.5-4B-MLX-4bit", "ready 独有必须剥前缀")
        // samplingConfig 收到的是 canonical key，GUI 侧能用它去 EnginePool 取值
        #expect(out.1["mlx-community/Qwen3.5-4B-MLX-4bit"] != nil)
    }

    /// 两个不同物理模型 → 全保留（canonical 去重不能误杀不同 repo）。
    @Test
    @MainActor
    func distinctReposAllSurvive() async {
        let loaded = [
            ModelID(id: "mlx-community/Qwen3.5-4B-MLX-4bit", isVlm: false)
        ]
        let readyAll = [
            ModelStore.ReadyModel(
                id: "mscope:Qwen2.5-1.5B-CoreAI/qwen2_5_1_5b",
                weightsDir: URL(fileURLWithPath: "/x"), isVlm: false)
        ]
        let out = ModelManager.mergeLocalModels(
            loaded: loaded, ready: readyAll, samplingConfig: { _ in .default })
        #expect(out.0.count == 2, "不同 repo 必须全保留, got \(out.0.map(\.id))")
        #expect(out.0.contains { $0.id == "mlx-community/Qwen3.5-4B-MLX-4bit" })
        #expect(out.0.contains { $0.id == "Qwen2.5-1.5B-CoreAI/qwen2_5_1_5b" })
    }

    /// 全空 → 空数组（旧 code guard !loaded.isEmpty || !ready.isEmpty）。
    @Test
    @MainActor
    func bothEmptyReturnsEmpty() async {
        let out = ModelManager.mergeLocalModels(
            loaded: [], ready: [], samplingConfig: { _ in .default })
        #expect(out.0.isEmpty)
    }

    /// 自定义采样配置 → paramsCustomized 标记 true(GUI 排序锚点)。
    /// 注意:`temperature: 0.7` 是**默认值**(ModelSamplingConfig 的 isDefault 锚点),
    /// 用 topK 这种非默认字段做真自定义锚点。
    @Test
    @MainActor
    func readyWithCustomSamplingFlagged() async {
        let custom = ModelSamplingConfig(temperature: 0.7, topK: 5)
        #expect(!custom.isDefault, "前提: 这个 config 必须真非默认")
        let out = ModelManager.mergeLocalModels(
            loaded: [], ready: [ready],
            samplingConfig: { _ in custom })
        #expect(out.0.count == 1)
        #expect(out.0.first?.paramsCustomized == true, "非默认采样 → paramsCustomized=true")
    }

    /// 默认采样配置 → paramsCustomized 保持 false(不误标)。
    @Test
    @MainActor
    func readyWithDefaultSamplingNotFlagged() async {
        let out = ModelManager.mergeLocalModels(
            loaded: [], ready: [ready],
            samplingConfig: { _ in .default })
        #expect(out.0.first?.paramsCustomized == false)
    }
}
