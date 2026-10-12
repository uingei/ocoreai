// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ContextWindowPolicy — 有效上下文窗口的来源裁决(纯函数,零磁盘零网络)。
///
/// 钉住的缺口(2026-10-12 实证):所有预算面(ChatView 水位 /
/// `get_context_remaining` / 自动压缩 / 400 墙)只读
/// `getSamplingConfig(modelId:).maxContextWindow`,该值在人类发过
/// `PATCH {"max_context_window":N}` 之前恒为 nil,而 GUI 里没有这个入口
/// (grep `maxContextWindow` in `Sources/ocoreai/UI/` = 0)。于是本机
/// `mlx-community/gemma-4-e2b-it-4bit/config.json` 明写
/// `text_config.max_position_embeddings = 131072` 的模型,行为上等于
/// 「容量不可知」。本套件把修正后的裁决逐值钉死。
///
/// 参照:`mlx-swift-lm` `KVCacheLayerStatus.CapacitySource`
/// (`.modelDefined`/`.requested`/`.unbounded`)—同一 provenance 轴上移一层;
/// `RoPEUtils.swift:521` `maxPositionEmbeddings ?? 131072`(131072 是上游自用默认)。
import Foundation
import Testing

@testable import ocoreai

@Suite("ContextWindowPolicy.resolve")
struct ResolveTests {

    /// 无人覆写时,模型自己声明的窗口必须成为预算 —— 这正是修正的那一刀。
    @Test("no override → model-declared window becomes the cap")
    func declaredBecomesCapWithoutOverride() {
        let r = ContextWindowPolicy.resolve(override: nil, declared: 131_072)
        #expect(r.tokens == 131_072)
        #expect(r.source == .modelDefined)
        #expect(r.isKnown)
    }

    /// 显式覆写永远压过声明值(人说了算),且 provenance 记为 requested。
    @Test("override wins over declared")
    func overrideWins() {
        let r = ContextWindowPolicy.resolve(override: 65_536, declared: 131_072)
        #expect(r.tokens == 65_536)
        #expect(r.source == .requested)
    }

    /// 两边都没有 → unknown,绝不编一个数(codex `unknown` 路)。
    @Test("both absent → unknown, never a fabricated budget")
    func bothAbsent() {
        let r = ContextWindowPolicy.resolve(override: nil, declared: nil)
        #expect(r.tokens == nil)
        #expect(r.source == .unknown)
        #expect(!r.isKnown)
        #expect(r.tokensOrZero == 0)
    }

    /// 非正值 = 视为缺失:真实 config.json 不会产生 0/负数
    /// (`ModelStore.contextLength` 已过滤 `> 0`),而覆写成 0 会静默废掉全部预算面。
    @Test("non-positive override falls through to declared")
    func nonPositiveOverrideFallsThrough() {
        let zero = ContextWindowPolicy.resolve(override: 0, declared: 131_072)
        #expect(zero.tokens == 131_072)
        #expect(zero.source == .modelDefined)

        let negative = ContextWindowPolicy.resolve(override: -1, declared: 131_072)
        #expect(negative.tokens == 131_072)
        #expect(negative.source == .modelDefined)
    }

    @Test("non-positive declared is not a window")
    func nonPositiveDeclaredIsUnknown() {
        #expect(ContextWindowPolicy.resolve(override: nil, declared: 0).source == .unknown)
        #expect(ContextWindowPolicy.resolve(override: nil, declared: -5).tokens == nil)
    }

    /// 窗口一旦可知,预算算术与 400 墙必须同时生效(131072 边界逐值钉死)。
    @Test("declared window arms the wall at its exact boundary")
    func wallArmsAtBoundary() {
        let cap = ContextWindowPolicy.resolve(override: nil, declared: 131_072).tokens
        #expect(!promptExceedsContextWindow(promptTokens: 131_072, maxContextWindow: cap))
        #expect(promptExceedsContextWindow(promptTokens: 131_073, maxContextWindow: cap))
        // 修正前 cap == nil → 任何尺寸的 prompt 都不触墙,直撞引擎。
        #expect(!promptExceedsContextWindow(promptTokens: 10_000_000, maxContextWindow: nil))
    }

    /// 水位余量与 `get_context_remaining` 同一函数(单一真源)。
    @Test("declared window yields a real meter remainder")
    func meterRemainder() {
        let cap = ContextWindowPolicy.resolve(override: nil, declared: 131_072).tokens
        #expect(ContextRemaining.tokensRemaining(limit: cap, used: 130_000) == 1_072)
        #expect(ContextRemaining.tokensRemaining(limit: cap, used: 131_072) == 0)
        #expect(ContextRemaining.tokensRemaining(limit: cap, used: 200_000) == 0)
        #expect(ContextRemaining.tokensRemaining(limit: nil, used: 10) == nil)
    }
}

@Suite("ContextWindowPolicy.overrideTokens")
struct OverrideLookupTests {

    /// 覆写表以 bare canonical 为键,请求带 `hf:`/`mscope:` 前缀也必须命中
    /// —— 否则人设的覆写对他自己都不生效。
    @Test("prefixed request finds bare-canonical override")
    func prefixedRequestFindsBareOverride() {
        let table: [String: ModelSamplingConfig] = [
            "mlx-community/Qwen3.6-27B-oQ4e-mtp": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 32_768
                return c
            }()
        ]
        #expect(
            ContextWindowPolicy.overrideTokens(
                in: table, for: "hf:mlx-community/Qwen3.6-27B-oQ4e-mtp"
            ) {
                $0.maxContextWindow
            } == 32_768)
        #expect(
            ContextWindowPolicy.overrideTokens(
                in: table, for: "mscope:mlx-community/Qwen3.6-27B-oQ4e-mtp"
            ) {
                $0.maxContextWindow
            } == 32_768)
    }

    /// 反向:表里存的是带前缀的键,裸请求同样命中。
    @Test("bare request finds prefixed override")
    func bareRequestFindsPrefixedOverride() {
        let table: [String: ModelSamplingConfig] = [
            "hf:mlx-community/LFM2.5-Embedding-350M-4bit": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 128_000
                return c
            }()
        ]
        #expect(
            ContextWindowPolicy.overrideTokens(
                in: table, for: "mlx-community/LFM2.5-Embedding-350M-4bit"
            ) {
                $0.maxContextWindow
            } == 128_000)
    }

    /// 同一方向必须对 ModelScope 前缀同样成立,否则修好的只是 HF 半边。
    @Test("bare request finds mscope-prefixed override")
    func bareRequestFindsMscopeOverride() {
        let table: [String: ModelSamplingConfig] = [
            "mscope:Qwen/Qwen2.5-7B-Instruct": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 32_768
                return c
            }()
        ]
        #expect(
            ContextWindowPolicy.overrideTokens(
                in: table, for: "Qwen/Qwen2.5-7B-Instruct"
            ) { $0.maxContextWindow } == 32_768)
    }

    /// 旧拼写 `huggingface:` 是仓库承认的历史前缀(`ModelStore.normalizeModelId`
    /// 会剥它),覆写表里存旧拼写也必须命中。
    @Test("legacy huggingface prefix resolves")
    func legacyPrefixResolves() {
        let table: [String: ModelSamplingConfig] = [
            "huggingface:org/model": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 8_192
                return c
            }()
        ]
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "org/model") { $0.maxContextWindow }
                == 8_192)
    }

    /// 跨 hub 歧义是 id 空间固有的:同名 repo 在两个 hub 上是两个模型。
    /// 契约 = 固定次序命中第一个,可复核、可复核后故意改;不是随机字典序。
    @Test("cross-hub collision resolves by documented precedence")
    func crossHubCollisionIsDeterministic() {
        let table: [String: ModelSamplingConfig] = [
            "hf:shared/name": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 4_096
                return c
            }(),
            "mscope:shared/name": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 16_384
                return c
            }(),
        ]
        // 次序钉: candidateKeys 的顺序就是裁决顺序。
        #expect(
            ContextWindowPolicy.candidateKeys(for: "shared/name")
                == [
                    "shared/name", "hf:shared/name", "huggingface:shared/name",
                    "mscope:shared/name",
                ])
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "shared/name") {
                $0.maxContextWindow
            }
                == 4_096)
        // 显式带前缀的请求不受歧义影响,各命中自己的值。
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "mscope:shared/name") {
                $0.maxContextWindow
            } == 16_384)
    }

    /// 完全没命中的 id 仍然返回 nil,不能因为候选键变多就撞上邻居配置。
    @Test("unmatched id still yields nil, never a neighbour's window")
    func unmatchedIdYieldsNil() {
        let table: [String: ModelSamplingConfig] = [
            "hf:other/name": {
                var c = ModelSamplingConfig()
                c.maxContextWindow = 2_048
                return c
            }()
        ]
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "unrelated/name") {
                $0.maxContextWindow
            } == nil)
    }

    /// 覆写字段为 nil(从未设置)→ nil,交回声明值;不是命中一个 0。
    @Test("unset override yields nil")
    func unsetOverrideYieldsNil() {
        let table: [String: ModelSamplingConfig] = ["org/name": .default]
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "org/name") { $0.maxContextWindow }
                == nil)
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "hf:org/name") {
                $0.maxContextWindow
            }
                == nil)
        // 完全不认识的 id → nil
        #expect(
            ContextWindowPolicy.overrideTokens(in: table, for: "other/name") { $0.maxContextWindow }
                == nil)
    }
}

/// 磁盘 → 预算 的端到端钉:这段之前没有任何测试覆盖,而它正是修正的那一刀——
/// 窗口的真值一直躺在 `config.json` 上,只是没有进预算面。这里用 fixture 复现
/// 真实形状(顶层 / `text_config` 嵌套 / 三键优先级),把
/// `ModelStore.contextLength` → `ContextWindowPolicy.resolve` 这条链钉死,
/// CI 干净机可跑,不依赖本机已下载的模型。
@Suite("ContextWindowPolicy — disk config → effective budget")
struct DiskToBudgetTests {

    private func weightsDir(named name: String, configJSON: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-window-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(configJSON.utf8).write(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    /// 真机形状:`text_config.max_position_embeddings = 131072`
    /// (`~/.ocoreai/models/mlx-community/gemma-4-e2b-it-4bit/config.json`)。
    /// 无人覆写 → 该值必须成为预算,provenance = modelDefined。
    @Test("nested text_config window becomes the effective cap")
    func nestedTextConfigResolves() throws {
        let dir = try weightsDir(
            named: "nested",
            configJSON: """
                {"model_type":"mm_gemma","text_config":{"hidden_size":2880,\
                "max_position_embeddings":131072,"num_hidden_layers":46}}
                """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let declared = ModelStore.contextLength(weightsDir: dir)
        #expect(declared == 131_072)
        let resolved = ContextWindowPolicy.resolve(override: nil, declared: declared)
        #expect(resolved.tokens == 131_072)
        #expect(resolved.source == .modelDefined)
    }

    /// 键优先级与 `HubConfigFetcher` 同序:top-level `max_context_length` 压过
    /// `max_position_embeddings` / `n_ctx`。
    @Test("key precedence matches the fetcher order")
    func keyPrecedence() throws {
        let dir = try weightsDir(
            named: "precedence",
            configJSON: """
                {"max_context_length":262144,"max_position_embeddings":131072,"n_ctx":4096}
                """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelStore.contextLength(weightsDir: dir) == 262_144)

        let noTop = try weightsDir(
            named: "no-top",
            configJSON: """
                {"max_position_embeddings":131072,"n_ctx":4096}
                """)
        defer { try? FileManager.default.removeItem(at: noTop) }
        #expect(ModelStore.contextLength(weightsDir: noTop) == 131_072)

        let onlyCtx = try weightsDir(
            named: "only-nctx",
            configJSON: """
                {"n_ctx":8192}
                """)
        defer { try? FileManager.default.removeItem(at: onlyCtx) }
        #expect(ModelStore.contextLength(weightsDir: onlyCtx) == 8_192)
    }

    /// 诚实契约:缺键 / 无 config / 非正值 → nil(未知),绝不落到 131072 默认。
    /// 上游 `RoPEUtils` 的 `?? 131072` 是它自己建 ModelConfig 用的默认,
    /// 能力发现面不许继承那个默认。
    @Test("absent or non-positive keys report unknown, never a fabricated default")
    func absentKeysStayUnknown() throws {
        let empty = try weightsDir(
            named: "empty",
            configJSON: """
                {"model_type":"llama","vocab_size":151643}
                """)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(ModelStore.contextLength(weightsDir: empty) == nil)
        let resolved = ContextWindowPolicy.resolve(override: nil, declared: nil)
        #expect(resolved.tokens == nil && resolved.source == .unknown)

        let zero = try weightsDir(
            named: "zero",
            configJSON: """
                {"max_position_embeddings":0,"n_ctx":-1}
                """)
        defer { try? FileManager.default.removeItem(at: zero) }
        #expect(ModelStore.contextLength(weightsDir: zero) == nil)

        let missing = URL(
            fileURLWithPath: "/tmp/ctx-window-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(ModelStore.contextLength(weightsDir: missing) == nil)
    }

    /// 覆写与声明同时在场:人说了算,但日志/UI 必须能看出这是 requested。
    @Test("override wins on disk-resolved values and keeps provenance")
    func overrideWinsFromDisk() throws {
        let dir = try weightsDir(
            named: "override",
            configJSON: """
                {"text_config":{"max_position_embeddings":131072}}
                """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let declared = ModelStore.contextLength(weightsDir: dir)
        let resolved = ContextWindowPolicy.resolve(override: 32_768, declared: declared)
        #expect(resolved.tokens == 32_768)
        #expect(resolved.source == .requested)
        #expect(resolved.source.rawValue == "requested")
    }
}

@Suite("ContextWindowPolicy — human-typed window and provenance label")
struct HumanSurfaceTests {

    /// GUI 里手打的窗口必须逐值精确:K/M 后缀是模型页渲染
    /// ("131K")的逆运算,用户看到的和打进去的是同一套记法。
    @Test("typed windows parse exactly, K/M suffixes included")
    func typedWindowsParseExactly() {
        #expect(ContextWindowPolicy.parseOverride("32768") == 32_768)
        #expect(ContextWindowPolicy.parseOverride("32k") == 32_768)
        #expect(ContextWindowPolicy.parseOverride("32K") == 32_768)
        #expect(ContextWindowPolicy.parseOverride(" 8 K ") == 8_192)
        #expect(ContextWindowPolicy.parseOverride("1m") == 1_048_576)
        #expect(ContextWindowPolicy.parseOverride("1,024") == 1_024)
        #expect(ContextWindowPolicy.parseOverride("131072") == 131_072)
    }

    /// 空 / 垃圾 / 非正数一律 nil = 「继承模型声明」。把 0 当成合法上限
    /// 会让所有预算面看起来已配置、实则全关 —— 那是谎,不是预算。
    @Test("empty, garbage, and non-positive input mean inherit, never zero")
    func invalidInputMeansInherit() {
        for text in ["", "   ", "0", "-1", "abc", "k", "1kk", "1.5", "0k"] {
            #expect(
                ContextWindowPolicy.parseOverride(text) == nil,
                "input \"\(text)\" must not mint a cap")
        }
    }

    /// 边界钉在 Int64:能表示的照收(≈1.05e18),不能表示的拒掉而不是
    /// trap 成崩溃。是否要再按本机内存夹一刀 = 本文件标注的未决拍板项,
    /// 这里不静默替用户决定。
    @Test("overflow boundary is exactly Int64, and never traps")
    func overflowBoundaryIsInt64() {
        // 999999999999 * 1024 * 1024 ≈ 1.05e18 — representable, honoured as typed.
        #expect(
            ContextWindowPolicy.parseOverride("999999999999m") == 999_999_999_999 * 1_024 * 1_024)
        // One more digit overflows Int64 (≈1.05e19) — refused, not trapped.
        #expect(ContextWindowPolicy.parseOverride("9999999999999m") == nil)
        #expect(ContextWindowPolicy.parseOverride("99999999999999999999") == nil)
    }

    /// 渲染记法与模型页一致(`ModelID.contextString`):同一个数在不同屏
    /// 幕上不能长成两个样子。
    @Test("short token rendering matches the models page")
    func shortTokensRendering() {
        #expect(ContextWindowPolicy.shortTokens(131_072) == "131K")
        #expect(ContextWindowPolicy.shortTokens(128_000) == "128K")
        #expect(ContextWindowPolicy.shortTokens(1_000) == "1K")
        #expect(ContextWindowPolicy.shortTokens(512) == "512")
    }

    /// 「模型声明的 131K」和「你手动设的 32K」是两句不同的话,必须可分辨;
    /// 窗口未知时标签一起消失(不给不存在的预算配说明)。
    @Test("provenance separates model-declared from hand-set and vanishes when unknown")
    func provenanceSeparatesModelFromHandSet() {
        let fromModel = ContextWindowPolicy.resolve(override: nil, declared: 131_072)
        let handSet = ContextWindowPolicy.resolve(override: 32_768, declared: 131_072)
        let unknown = ContextWindowPolicy.resolve(override: nil, declared: nil)
        let modelLabel = ContextWindowPolicy.provenanceLabel(for: fromModel)
        let manualLabel = ContextWindowPolicy.provenanceLabel(for: handSet)
        #expect(modelLabel != nil && manualLabel != nil)
        #expect(modelLabel != manualLabel, "model-declared and hand-set must read differently")
        #expect(ContextWindowPolicy.provenanceLabel(for: unknown) == nil)
    }

    /// 覆写赢的时候仍要带着模型自己的声明,否则 params 卡片只能含糊说
    /// 「留空继承」而报不出继承的具体数字。
    @Test("declared window survives an override so the hint can name it")
    func declaredSurvivesOverride() {
        #expect(
            ContextWindowPolicy.resolve(override: 32_768, declared: 131_072).declared == 131_072)
        #expect(
            ContextWindowPolicy.resolve(override: nil, declared: 131_072).declared == 131_072)
        #expect(ContextWindowPolicy.resolve(override: nil, declared: nil).declared == nil)
    }
}
