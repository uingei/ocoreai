import Foundation

/// VLMTokenizerOperations — VLM prompt 装配的注入面(注入,使装配成为纯函数)。
///
/// 闭包面与上游 coreai-models llm-runner 用的 `Tokenizer`(swift-transformers)
/// API 1:1 对应:
///   - `encode(text:addSpecialTokens:)`  → `encode(_: Bool)`
///   - `applyChatTemplate(messages:)`    → `applyChatTemplate(String)`(可失败)
///
/// 抽成闭包后,装配逻辑不依赖 CoreAI 运行时 / VLM `.aimodelc` 资产——
/// 活体 LLM tokenizer(经 `DirectTokenizer._tokenizer`)或确定性 mock 都可驱动。
public struct VLMTokenizerOperations: Sendable {
    /// 编码文本 → token 序列。
    /// 第二参数对齐 swift-transformers `encode(text:addSpecialTokens:)`:
    /// `true` 前导 special tokens(BOS 等);`false` 纯 content。
    public let encode: @Sendable (String, Bool) -> [Int32]

    /// 渲染 chat template → token 序列;无模板/失败返回 nil(触发 fallback)。
    public let applyChatTemplate: @Sendable (String) -> [Int32]?

    /// 构造。`encode` 必填;`applyChatTemplate` 缺省恒 nil(始终走 fallback)。
    public init(
        encode: @escaping @Sendable (String, Bool) -> [Int32],
        applyChatTemplate: @escaping @Sendable (String) -> [Int32]? = { _ in nil }
    ) {
        self.encode = encode
        self.applyChatTemplate = applyChatTemplate
    }
}

/// 将单图像 placeholder token 序列展开为指定数量。
///
/// 对齐上游 coreai-models llm-runner `buildVLMPromptFromChatTemplate`(L1263-1282):
///   - 首个 `imageTokenId` → 展开为 `imageTokenCount` 份;
///   - 后续出现的 `imageTokenId` → 跳过(多图模板的防重复展开);
///   - 其他 token → 原样保留。
///
/// - Returns: `(tokens, foundPlaceholder)` — `foundPlaceholder` 指示序列里
///   是否真的含 `imageTokenId`。上游用 `guard foundPlaceholder else { return nil }`
///   (L1280-1281)把"模板没渲染出占位符"判为失败降级 fallback;本层把该判定
///   显式返回给 `assembleVLMPrompt` 消费,而不是吞掉后静默走 chat 路。
public func expandImagePlaceholders(
    in templateTokens: [Int32],
    imageTokenId: Int32,
    imageTokenCount: Int
) -> (tokens: [Int32], foundPlaceholder: Bool) {
    var result: [Int32] = []
    result.reserveCapacity(templateTokens.count + imageTokenCount - 1)
    var found = false
    for t in templateTokens {
        if t == imageTokenId && !found {
            result.append(contentsOf: [Int32](repeating: imageTokenId, count: imageTokenCount))
            found = true
        } else if t == imageTokenId {
            continue
        } else {
            result.append(t)
        }
    }
    return (result, found)
}

/// 构建 VLM prompt token 序列(chat template 优先,否则 fallback)。
///
/// 严格对齐上游 llm-runner `runVLMGeneration`(L1126-1144)+
/// `buildVLMPromptFromChatTemplate`(L1245-1283),降级触发条件**两条**:
///   - `applyChatTemplate(prompt)` 返回 nil(无模板/渲染失败);**或**
///   - 模板渲染出的 token 序列不含 `imageTokenId`(占位符未产生,上游 L1280-1281 `guard foundPlaceholder`)。
/// 其余情况:在模板序列上就地展开占位符后返回。
///
/// fallback 格式(上游 L1138-1143,字符串字面逐段保真):
///   `encode("USER: ", true)` + N×`imageTokenId` + encode("\n"+prompt+"\nASSISTANT:", false)
///
/// - Parameters:
///   - prompt: 渲染进 chat template 的用户消息文本(上游 `displayPrompt`)。
///   - imageTokenCount: 图像占位 token 数(= `InputEmbeddings.tokenCount`,
///     来自 `VisionConfig.imageTokenCount`,与 `encodeImage` 输出对齐)。
///   - imageTokenId: 图像占位符 token id(来自 `VisionConfig.imageTokenId`)。
///   - tokenizer: tokenizer 操作面(`encode` + `applyChatTemplate`)。
/// - Returns: 最终 prompt token 序列,恰含 N 个连续 `imageTokenId` 占位,
///   供 `encodeImage` → `generate(with: InputEmbeddings, tokens:)` 消费。
public func assembleVLMPrompt(
    prompt: String,
    imageTokenCount: Int,
    imageTokenId: Int32,
    tokenizer: VLMTokenizerOperations
) -> [Int32] {
    if let templated = tokenizer.applyChatTemplate(prompt) {
        let (expanded, found) = expandImagePlaceholders(
            in: templated, imageTokenId: imageTokenId, imageTokenCount: imageTokenCount)
        if found {
            return expanded
        }
    }
    // fallback:USER:/ASSISTANT: 字面拼接,与上游 L1138-1143 逐段一致。
    var tokens = tokenizer.encode("USER: ", true)
    tokens.append(contentsOf: [Int32](repeating: imageTokenId, count: imageTokenCount))
    let suffix = "\n" + prompt + "\nASSISTANT:"
    tokens.append(contentsOf: tokenizer.encode(suffix, false))
    return tokens
}
