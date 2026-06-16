# ocoreai 多模态架构提案

## 能力矩阵

| 模态 | CoreAI | MLXLLM |
|------|--------|--------|
| **视觉** | 👁️ 图像理解/目标检测 | 🖼️ 图像生成（Diffusion） |
| **文字** | ⚡ 轻量分类/路由 | 🧠 深度推理/对话 |
| **语音** | 🎤 ASR/TTS | ❌ |

## "自行交流"的四种玩法

### 1. 视觉→思考→语音 (完整感知闭环)
```
用户拍照 → CoreAI 视觉提取 → MLX 理解+推理 → CoreAI TTS 语音播报
```

### 2. 语音→思考→创作 (语音驱动生成)
```
用户说话 → CoreAI ASR → MLX 提炼提示词 → CoreAI 图像生成 → SSE 推送
```

### 3. 自主迭代循环 (Self-Play)
```
MLX 生成描述 → CoreAI 生成图像 → CoreAI 视觉验证 → 
MLX 修正描述 → ... → 直到满足约束
```

### 4. 路由+思考 (效率模式)
```
CoreAI 3B 分类意图 → 简单→CoreAI 直出 / 复杂→MLX 推理
```

---

## 核心架构协议

```swift
/// 模态类型
public enum Modality: String, Codable, Sendable {
    case text, image, audio, visionFeatures
}

/// 多模态消息（双脑之间的通信单位）
public struct MultiModalMessage: Sendable, Codable {
    public let timestamp: Date
    public let source: ModalitySource    // .coreai / .mlx
    public let modality: Modality
    public let payload: ModalityPayload
}

public enum ModalityPayload: Sendable, Codable {
    case text(String)
    case imageData(Data)
    case audioSamples(Float32)
    case visionFeatures(VisionFeatures)
}

/// 编排管道（声明式定义推理流程）
public struct MultiModalPipeline: Sendable {
    let stages: [PipelineStage]
    let maxIterations: Int
    let convergence: ConvergenceCriteria
}

public struct PipelineStage: Sendable {
    let name: String
    let backend: Backend              // .coreai / .mlx / .both
    let input: [Modality]            // 需要哪些输入
    let output: Modality             // 产出什么
    let dependsOn: [String]          // 依赖前置阶段
}
```

---

## API 设计示例

### 多模态聊天端点
```
POST /v1/chat/multimodal

{
    "pipeline": "vision_question",
    "messages": [
        {"role": "user", "content": {"type": "image", "url": "photo.jpg"}},
        {"role": "system", "content": "用语音回答"}
    ],
    "iterations": 3,
    "timeout_ms": 30000
}
```

### 自主创作端点
```
POST /v1/generate

{
    "prompt": "戴眼镜的猫钓鱼",
    "style": "impressionist",
    "iterations": 2,          // 迭代直到满意
    "validate_with": "vision" // CoreAI 视觉验证
}
```

---

## 实施路径

| 阶段 | 内容 | 优先级 |
|------|------|--------|
| P0 | 修复 HB 2.25 CI 编译 | 🔴 阻塞 |
| P1 | MultiModalBus + 消息协议 | 高 |
| P2 | CoreAI 视觉 API 封装 | 高 |
| P3 | Pipeline 编排器 | 中 |
| P4 | SSE 多模态推送 | 中 |
| P5 | Apple 搜索增强 | 低 |
