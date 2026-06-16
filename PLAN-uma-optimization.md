# Apple Silicon UMA 架构优化的正确方案

## 当前硬伤诊断

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| 1 | KVCacheManager 假设 GPU↔SSD 两层 | KVCacheManager.swift L1-2 `#if coreai` | 整个 coldStore/warmBack 在 UMA 上无效 |
| 2 | 每次推理 `EngineFactory.createEngine()` | EngineManager.swift L389 | 模型重新加载，浪费秒级时间 |
| 3 | CAS 锁禁止同模型并发 | EngineManager.swift L378 `tryAcquireInference()` | 零 continuous batching |
| 4 | 硬编码 `maxConcurrentSessions: 8` | EngineManager.swift L77 | 不知道硬件能力的盲目数字 |
| 5 | mlx 路径无 KV cache 管理 | 整个 KVCacheManager 被 `#if coreai` 包裹 | MLX 后端完全缺少内存管理 |

## Apple Silicon 硬件规格（已验证）

| Chip | Mem BW | Max RAM | NPU | GPU | CPU | Mem 通道 |
|------|--------|---------|-----|-----|-----|---------|
| M4 | 120 GB/s | 32 GB | 38 TOPS | 10 | 4P+4E | 8 |
| M4 Pro | 273 GB/s | 48 GB | 45 TOPS | 20 | 10P+2E | 16 |
| M4 Max | 560 GB/s | 192 GB | 45 TOPS | 40 | 12P+2E | 32 |
| M3 Ultra | 800 GB/s | 192 GB | 36 TOPS | 80 | 20P+2E | dual-Max |

## UMA 正确模型

Apple Silicon 只有一级内存（RAM），所有加速引擎共享同一物理地址空间：

```
RAM (120~800 GB/s) ← 所有 CPU/GPU/NPU/模型权重/KV cache 都在这里
SSD (~3 GB/s)      ← 只作为安全网（OOM 时的最后防线，慢 200×）
```

**结论**：KV cache 不应该设计为 "swap to disk"。应该设计为 "在 RAM 内做内存会计 + LRU 淘汰"。

## 正确方案：三级分层

### Level 1: HardwareProfile Detection (新增)

```swift
enum HardwareProfile {
    case base   // M4 base, ≤32GB
    case pro    // M4/M3 Pro, 32-64GB
    case max    // M4/M3 Max/Ultra, 64-192GB+
}

extension HardwareProfile {
    static func detect() -> Self {
        let ram = SystemMemory.availableMB()
        let bw = SystemMemory.bandwidthMBps()
        if ram >= 65536 || bw >= 500_000 { return .max }
        if ram >= 32768 || bw >= 250_000 { return .pro }
        return .base
    }
}
```

### Level 2: 分级 KV Cache 策略

| Profile | KV Cache 上限 | 淘汰策略 | 前缀共享 | 并发推理 |
|---------|-------------|---------|---------|---------|
| base | RAM × 0.35 | 激进 LRU (30s idle) | ❌ | 1 |
| pro | RAM × 0.50 | 适度 LRU (5min idle) | ✅ prefix cache | 2-4 |
| max | RAM × 0.65 | 宽松 LRU (15min idle) | ✅ prefix cache | 4-8 |

### Level 3: 具体优化清单

#### A. KVCacheManager 重写（核心）

**删除**：
- `coldStore()` / `warmBack()` — 整个 GPU↔SSD 两层模型
- `AsyncKVState.serialize/deserialize` — 不再序列化到磁盘
- `ssdIndex` / `ssdCachePath` / `ssdCacheLimitGB`
- `#if coreai` 守卫 — mlx 路径也需 KV cache 管理

**改写为**（内存内 LRU cache）：
```swift
// 核心数据结构 — page-aligned block tracking (借鉴 vLLM PagedAttention)
struct KVBlock: Sendable {
    let blockId: UInt64
    var refCount: Int
    var lastAccessed: ContinuousClock.Instant
}

actor KVCacheManager {
    // 内存池 — 固定 page size (16KB) 分配
    private var freeBlocks: [UInt64] = []
    private var activeBlocks: [UInt64: KVBlock] = [:]
    private let totalPages: Int
    private let pageSize: Int = 16 * 1024
    
    // Session → [blockIds] mapping
    private var sessionBlocks: [String: [UInt64]] = [:]
    
    // Session → prefix prefix tree (借鉴 SGlang RadixCache)
    private var prefixTree: RadixTree<String, UInt64>?  // nil on base profile
    
    func allocateBlocks(sessionId: String, count: Int) -> [UInt64]
    func freeBlocks(sessionId: String)
    func evictIfPressure()  // RAM 内 LRU, 不 touch disk
}
```

#### B. EngineManager 重写

**删除**：
- CAS 推理锁（`inferenceGuard` / `tryAcquireInference` / `releaseInference`）
- 每次创建 `EngineFactory.createEngine()`

**改写为**：
- Engine 在 `loadModel()` 时创建一次
- 用队列调度器替代 CAS 锁，实现 concurrent inference dispatch
- Continuous batching: 累积等待中的 request → 一次性 dispatch

```swift
actor EnginePool {
    // Engine reuse
    private var engineHandle: EngineHandle?  // one per model, created at load time
    
    // Request queue for continuous batching
    private var pendingRequests: [InferenceRequest] = []
    private var schedulerTask: Task<Void, Never>?
    
    func enqueue(_ request: InferenceRequest)
    private func scheduleBatch() async  // 累积 N 个请求或超时后 batch dispatch
}
```

#### C. EnginePoolConfig 自动生成

```swift
extension EnginePoolConfig {
    static func fromHardwareProfile() -> Self {
        let profile = HardwareProfile.detect()
        switch profile {
        case .base:
            return .init(maxConcurrentSessions: 1, maxQueueSize: 4, warmupTokens: 4, ...)
        case .pro:
            return .init(maxConcurrentSessions: 4, maxQueueSize: 16, warmupTokens: 8, ...)
        case .max:
            return .init(maxConcurrentSessions: 8, maxQueueSize: 32, warmupTokens: 16, ...)
        }
    }
}
```

### 渐进实施路线图

| Phase | 内容 | 风险 | 收益 |
|-------|------|------|------|
| P0 | HardwareProfile detection + 分级 config | 低 | 立即可适配不同硬件 |
| P1 | KVCacheManager 改为纯内存 LRU | 中 | 修复 UMA 架构假设错误 |
| P2 | Engine reuse (loadModel 时创建) | 中 | 消除每次推理的模型重载延迟 |
| P3 | Continuous batching scheduler | 高 | 真正的并发推理 |
| P4 | Prefix caching (pro/max only) | 高 | 对话场景大幅节省 compute |

### 借鉴来源

| 机制 | 来源 | Apple Silicon 适用性 |
|------|------|-------------------|
| PagedAttention block 分配 | vLLM | ✅ 内存 accounting 核心，但不用 GPU→CPU swap |
| Radix prefix tree | SGlang | ✅ 前缀共享在长上下文对话场景收益巨大 |
| Continuous batching | vLLM Scheduler | ✅ UMA 上连续批次效率更高 |
| Memory accounting | oMLX | ✅ page-aligned 分配适配 UMA |
