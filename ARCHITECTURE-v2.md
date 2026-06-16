# ocoreai v2 Architecture

## Design Goals

| Goal | Target |
|------|--------|
| 双后端可选 | CoreAI (macOS 27+) ↔ MLX (macOS 15+) 编译/运行时可选 |
| 双 Hub 可选 | HuggingFace ↔ ModelScope 自动路由 |
| 默认负载 | `mlx-community/Qwen3.5-4B-OptiQ-4bit` (4bit 量化 ~2.5GB) |
| 未来扩展 | StableDiffusion / 任意 MLX 模型零代码侵入 |
| 架构约束 | 同一代码库，不 fork，不维护分支 |

---

## 现状诊断

### 代码结构

```
Sources/ocoreai/
├── Engine/
│   ├── EngineManager.swift      967 lines — ⚠️ 过于臃肿，双路径代码重复
│   ├── MLXBridge.swift          328 lines — ✅ Hub 路由骨架已建
│   ├── KVCacheManager.swift     621 lines — ❌ GPU↔SSD cold-store 不适合 UMA
│   └── InferenceStubs.swift      73 lines — ✅ none-trait stub 已就位
├── Models/
│   ├── ModelScopeDownloader.swift 333 lines — ✅ ModelScope downloader 完整
│   ├── HuggingFaceDownloader.swift 305 lines — ❌ 刚创建，待集成到 MLXBridge
│   └── OpenAIModels.swift       607 lines — ✅ DTO/模型定义完整
├── Handlers/
│   └── ChatHandler.swift        442 lines — ✅ SSE streaming 已实现
├── Middleware/
│   ├── AuthMiddleware.swift     169 lines — ✅
│   └── RateLimitMiddleware.swift 361 lines — ✅
├── Router/
│   └── ChatCompletionsRouter.swift 183 lines — ✅
├── Tokenizer/
│   └── TokenizerManager.swift   227 lines — ✅
├── Profiling/
│   └── TimingHooks.swift        108 lines — ✅
└── App.swift                    163 lines — ✅
```

### 核心问题

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| P1 | `EngineManager._runInference` 里 CoreAI 和 MLX 各写一遍 token 消费循环（~50行×2） | EngineManager.swift | 代码重复，维护成本翻倍 |
| P2 | MLX 推理路径 double-tokenization bug：先 tokenize→detokenize 再传给 ChatSession（内部又 tokenize） | EngineManager.swift:448 | 精度损失 + 延迟 |
| P3 | `loadModelFromHub` 不管 provider 是什么都只走 `ModelScopeDownloader` | MLXBridge.swift:202 | **HF 路径是死代码** |
| P4 | `switch source` 没有 explicit `.huggingFace` 分支 | MLXBridge.swift:130 | **HF 模型无法加载** |
| P5 | KV Cache SSD cold-store 在 UMA 上是 200× 延迟惩罚 | KVCacheManager.swift | 浪费资源，OOM 路径不清晰 |
| P6 | CAS 锁 `inferenceGuard` 串行化同一模型所有推理 | EngineManager.swift | 吞吐量瓶颈 |

---

## 方案：三层解耦架构

### Layer 1: Backend Abstraction (编译期解耦)

```
              EngineManager
                   │
          ┌────────┴────────┐
          ▼                 ▼
   ┌─────────────┐  ┌─────────────┐
   │ CoreAI 路径  │  │   MLX 路径   │
   │ (trait:core)│  │ (trait:mlx)  │
   └──────┬──────┘  └──────┬──────┘
          │                │
   ┌──────┴────────────────┴──────┐
   │     InferenceBackend         │
   │   (protocol, shared)         │
   │                              │
   │ - runInference(messages:)    │
   │ - runInferenceStream(...)    │
   │ - tokenize(text:)            │
   │ - detokenize(tokens:)        │
   │ - stopInference()            │
   │ - release()                  │
   └──────────────────────────────┘
```

**目标**：`EngineManager` 只与 `InferenceBackend` protocol 交互，不再写 `#if coreai` / `#if mlx` 分支。每个 trait 各提供一个 `InferenceBackendImpl`。

**工作量**：~450 行重构。收益：消除 50% 重复代码路径。

### Layer 2: Model Source Router (运行时解耦)

```swift
// 模型标识符格式
//   hf:org/model              → HuggingFace Hub
//   ms:org/model              → ModelScope Hub
//   /path/to/local/model      → 本地路径
//   org/model                 → 默认 Hub (配置 default_hub)

public enum ModelSource: Sendable {
    case huggingFace(repoId: String)
    case modelScope(repoId: String)
    case local(path: String)
}

public struct ModelConfig: Sendable, Codable {
    /// 模型标识，支持 hf:/ms:/local 前缀
    public var modelId: String
    
    /// Hub 访问 token（可选，gated model 需要）
    public var hfToken: String?
    public var modelScopeToken: String?
    
    /// 解析源
    public var source: ModelSource { parse(modelId) }
    
    /// 模型加载后实际目录（HF/MS 下载后路径）
    public var resolvedPath: URL?
}
```

**当前实现**：`MLXBridge.parseSource` 已识别 hf:/huggingface:/mscope: prefix → **只需补上路由逻辑**

### Layer 3: Runtime Configuration

```yaml
# ocoreai.yaml (配置化，YAML)
backend: mlx              # coreai | mlx | auto (根据 macOS version)
default_model: hf:mlx-community/Qwen3.5-4B-OptiQ-4bit
default_hub: huggingface  # huggingface | modelscope

hub:
  hf_token: ""            # 环境变量 HF_TOKEN 优先
  ms_token: ""            # 环境变量 MODELSCOPE_TOKEN 优先
  cache_base: ""          # 默认 ~/Library/Caches/ocoreai/

engine:
  max_concurrent_sessions: 8
  queue_size: 32
  inference_timeout: 180
  warmup_tokens: 4

hardware:
  profile: auto           # auto | base | pro | max | ultra
  kv_cache_budget_gb: ""  # 自动计算 (RAM * 0.4~0.65)
```

---

## StableDiffusion 扩展方案

### 当前限制
`ChatHandler` 硬编码为 chat completion 语义。SD 需要的是 image generation API。

### 解法：插件化 Handler + Model Type Discriminator

```swift
/// 运行时模型类型（从模型配置推断）
public enum ModelKind: String, Sendable, Codable {
    case llm           // 语言模型 (GPT, Qwen, LLaMA...)
    case imagegen      // 图像生成 (StableDiffusion, Flux...)
    case multimodal    // 多模态 (GPT-4o, LLaVA, Qwen-VL...)
}

/// Handler dispatch table
let handlerTable: [RoutePattern: ModelHandler] = [
    "/v1/chat/completions": ChatCompletionHandler(),
    "/v1/images/generations": ImageGenerationHandler(),
    // 注册新 handler 只需添加到 table
]
```

**SD 接入路径**：
1. MLX 已经有 `MLXStableDiffusion`（mlx-swift-examples）
2. 只需新建 `SDBackendImpl: InferenceBackend` + `ImageGenerationHandler`
3. 0 改现有 `ChatHandler` 代码

---

## 实施计划

### Phase 1: 基础修复（本周）
- [x] 实现 `HuggingFaceDownloader` ✅ (已创建)
- [ ] 修复 `MLXBridge.loadModelFromHub` provider 路由（当前是死代码）
- [ ] 修复 `switch source` 补全 `.huggingFace` explicit 分支
- [ ] `defaultModelId` 已正确设为 `hf:mlx-community/Qwen3.5-4B-OptiQ-4bit` ✅
- [ ] CI 编译验证通过
- [ ] 解决 CI 中 `Logging` import 缺失、`ContinuousClock.now.value`、`ResponseBody.init(data:)` 等 HB 2.x API 变更问题

### Phase 2: EngineManager 瘦身（下一周）
- [ ] 提取 `InferenceBackend` protocol
- [ ] 拆分 `_runInference` 为 `CoreAIInferenceImpl` + `MLXInferenceImpl`
- [ ] 修复 double-tokenization bug
- [ ] `ChatSession` 改为 per-model 长驻
- [ ] CAS 锁改为 MLX 的 `ModelContainer` 自身 thread-safe

### Phase 3: UMA 原生 KV Cache
- [ ] 重构 `KVCacheManager` 去磁盘路径
- [ ] `HardwareProfile` 自动检测 (Base/Pro/Max/Ultra)
- [ ] 纯内存 LRU eviction + 内存压力阈值
- [ ] 权重 mmap 按需分页

### Phase 4: 配置化 + SD 扩展
- [ ] YAML 配置加载
- [ ] `ModelKind` 运行时类型推断
- [ ] `ImageGenerationHandler` + SDBackend
- [ ] 多模型并行加载

---

## 依赖关系图

```
App.swift
  ├── EnginePool
  │     ├── CoreAIModelLoader  [trait:coreai]
  │     ├── MLXModelLoader     [trait:mlx]
  │     │     ├── HuggingFaceDownloader  ← 刚创建
  │     │     └── ModelScopeDownloader   ← 已有
  │     ├── TokenizerManager
  │     └── KVCacheManager     [重构 Phase 3]
  ├── MetricsRegistry
  ├── AuthMiddleware
  ├── RateLimitMiddleware
  └── Handlers/Router
        ├── ChatHandler        [llm]
        └── ImageGenHandler    [sd, Phase 4]
```

## CI/CD

| 环境 | Trait | 用途 |
|------|-------|------|
| `macos-26` / `coreai+mlx` | coreai + mlx | 完整功能测试 |
| `macos-26` / `coreai` | coreai only | CoreAI 路径验证 |
| `macos-26` / `mlx` | mlx only | MLX 路径验证 |
| `macos-26` / `none-trait` | none | Stub 隔离验证（当前 CI） |

**建议**：增加 `mlx-only` CI 矩阵，实际跑 Qwen 4bit 冒烟测试。

---

## 关键决策

| 决策 | 理由 |
|------|------|
| MLX 作为默认后端 | macOS 15+ 覆盖最广，社区生态成熟 |
| HF 作为默认 Hub | Qwen3.5-4B 在 HF 的下载量/镜像/缓存机制更优 |
| YAML 配置而非环境变量 | 结构化的 `models[]` 数组更清晰 |
| InferenceBackend protocol | 彻底消除双路径重复代码 |
| 去磁盘 KV Cache | UMA 架构下 GPU↔SSD 是无意义的零值操作 |
| SD 走 ImageGenerationHandler | 不与 ChatHandler 耦合，零侵入现有推理管线 |
