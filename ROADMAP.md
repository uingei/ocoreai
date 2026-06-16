# ocoreai Defense Map

> 标注自研中间层 → 对应 CoreAI 原生能力 → 迁移策略
> 更新: 2026-06-15

## Status: Shield Mode

CoreAI 生态尚新（macOS 27 / CoreAI v1），防御性中间层保留。等 Apple 补齐能力后逐层迁移。

---

## Layer Inventory

| Layer | File | Lines | Defensiveness | Trigger to Remove |
|-------|------|-------|---------------|-------------------|
| KV Cold Store | `KVCacheManager.swift` § AsyncKVState | ~130 | ⚡ **High** — 自研 binary 序列化 | CoreAI 原生 session persistence |
| Tokenizer Abstract | `TokenizerManager.swift` § Protocol | ~80 | 🟡 Medium — 单实现包装 | 多 tokenizer 后端需求出现 |
| Cache Manager Stub | `CoreAIBridge.swift` § CoreAICacheManager | ~30 | ⚡ **High** — TODO stub | macOS 27 SDK released |
| Error Re-definition | `CoreAIBridge.swift` § CoreAIBridgeError | ~30 | 🟡 Medium — 可透传 AssetError | 无需提前迁移 |
| ChatHandler | `ChatHandler.swift` | ~590 | 🟢 Low — 业务逻辑 | 核心推理路径，保留 |
| OpenAI API Layer | Router + Models + Middleware | ~400 | 🟡 Medium — 标准接口复刻 | CoreAI 内置 OpenAI-compatible server |
| KV GPU Tracker | `KVCacheManager.swift` § activeCaches | ~100 | 🟢 Low — 内存管理通用 | 保留 |

## Migration Plan

### Phase A: Low Risk (anytime, no functionality lost)
- [ ] `CoreAICacheManager` → 删除 stub，留 TODO placeholder
- [ ] `CoreAIBridgeError` → 透传 `AssetError`，外层包一层即可
- [ ] Tokenizer 协议 → 保留接口，移除内部 adapter 绕路（`StreamingDetokenizerProtocol` 可用 actor 替代）

### Phase B: Medium Risk (wait for CoreAI v2 signal)
- [ ] `AsyncKVState` serialize/deserialize → 替换为 CoreAI 原生 session persistence
- [ ] `coldStore`/`warmBack` → 替换为 CoreAI session save/load
- [ ] KV 驱逐策略 → 评估 CoreAI 是否自带 session 生命周期管理

### Phase C: High Risk (only when CoreAI ships OpenAI-compatible server)
- [ ] ChatHandler + Router + Models → 评估是否用 CoreAI 官方 server replacement
- [ ] OpenAI SSE format → 如果是 Apple 标准实现，直接替换

---

## Notes

- **Shield strategy**: 在框架不成熟时，自研中间层 = 工程防御，不是技术债务
- **Migration trigger**: 看到 CoreAI v2 release notes / WWDC session 提到对应能力，再启动迁移
- **Do not cut working code**: 能跑的代码 > 干净的代码，直到替代方案经过生产验证
