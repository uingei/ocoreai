import Testing

@testable import ocoreai

/// #130 ANE-VLM 装配层纯函数测试
///
/// 测试对象:`VLMTokenAssembly`(assembleVLMPrompt + expandImagePlaceholders)
/// — 上游 coreai-models llm-runner `buildVLMPromptFromChatTemplate`(L1245-1283)
/// + `runVLMGeneration`(L1126-1144)的 in-tree 对位。
///
/// 纯 token 序列计算 — 不依赖 CoreAI / 活体 VLM bundle / GPU,全 OS 可跑。
/// 每 token 映射确定(unicode scalar value + special 偏移),全部用 `#expect(==)` 精确值。

@Suite("VLMTokenAssembly — ANE-VLM 装配层")
struct VLMTokenAssemblyTests {

    /// 确定性 tokenizer:encode = unicode scalar value + (special ? 10000 : 0)。
    private static func enc(_ text: String, _ special: Bool) -> [Int32] {
        text.unicodeScalars.map { Int32($0.value) + (special ? 10000 : 0) }
    }

    // ── expandImagePlaceholders ──────────────────────────────────────────

    @Test("Expand — single placeholder → N copies, surrounding tokens preserved")
    func expandSingle() {
        let r = expandImagePlaceholders(in: [10, 88, 20, 30], imageTokenId: 88, imageTokenCount: 4)
        #expect(r.foundPlaceholder == true)
        #expect(r.tokens == [10, 88, 88, 88, 88, 20, 30])
    }

    @Test("Expand — multiple placeholders → only first expanded, rest skipped")
    func expandMultiple() {
        let r = expandImagePlaceholders(in: [88, 9, 88, 88], imageTokenId: 88, imageTokenCount: 6)
        #expect(r.foundPlaceholder == true)
        #expect(r.tokens == [88, 88, 88, 88, 88, 88, 9])
    }

    @Test("Expand — zero placeholders → foundPlaceholder false, sequence unchanged")
    func expandNone() {
        let r = expandImagePlaceholders(in: [1, 2, 3], imageTokenId: 88, imageTokenCount: 5)
        #expect(r.foundPlaceholder == false)
        #expect(r.tokens == [1, 2, 3])
    }

    @Test("Expand — count 0 → placeholder removed")
    func expandZero() {
        let r = expandImagePlaceholders(in: [1, 88, 2], imageTokenId: 88, imageTokenCount: 0)
        #expect(r.foundPlaceholder == true)
        #expect(r.tokens == [1, 2])
    }

    // ── assembleVLMPrompt ────────────────────────────────────────────────

    @Test("Chat template path — template with 1 placeholder → N expanded, prefix kept")
    func chatTemplateExpands() {
        let prompt = "hi"
        let imageTokenId: Int32 = 880
        let N = 3
        let ops = VLMTokenizerOperations(
            encode: Self.enc,
            applyChatTemplate: { p in [10, 20, imageTokenId] + Self.enc(p, false) }
        )

        let result = assembleVLMPrompt(
            prompt: prompt, imageTokenCount: N, imageTokenId: imageTokenId, tokenizer: ops)

        let expected: [Int32] =
            [10, 20] + Array(repeating: imageTokenId, count: N) + Self.enc(prompt, false)
        #expect(result == expected)
        #expect(result.filter { $0 == imageTokenId }.count == N)
    }

    @Test("Fallback path — applyChatTemplate nil → USER:/ASSISTANT: literal shape")
    func fallbackNil() {
        let prompt = "describe"
        let imageTokenId: Int32 = 77
        let N = 4
        let ops = VLMTokenizerOperations(encode: Self.enc)  // 默认 applyChatTemplate 恒 nil

        let result = assembleVLMPrompt(
            prompt: prompt, imageTokenCount: N, imageTokenId: imageTokenId, tokenizer: ops)

        let head = Self.enc("USER: ", true)
        let suffix = Self.enc("\ndescribe\nASSISTANT:", false)
        let expected: [Int32] = head + Array(repeating: imageTokenId, count: N) + suffix
        #expect(result == expected)
        #expect(result.count == head.count + N + suffix.count)
    }

    @Test("Fallback path — template exists BUT no placeholder → guard foundPlaceholder → fallback")
    func fallbackWhenTemplateLacksPlaceholder() {
        // 上游 L1280-1281: 模板没产生 image token → return nil → 降级 fallback。
        let prompt = "abc"
        let imageTokenId: Int32 = 5
        let N = 2
        // 模板渲染: 返回不含 imageTokenId 的序列
        let ops = VLMTokenizerOperations(
            encode: Self.enc,
            applyChatTemplate: { p in Self.enc(p, false) }
        )

        let result = assembleVLMPrompt(
            prompt: prompt, imageTokenCount: N, imageTokenId: imageTokenId, tokenizer: ops)

        let head = Self.enc("USER: ", true)
        let suffix = Self.enc("\nabc\nASSISTANT:", false)
        let expected: [Int32] = head + Array(repeating: imageTokenId, count: N) + suffix
        #expect(result == expected)
    }

    @Test("Chat path — multiple placeholders in template → only first expanded")
    func chatMultiPlaceholder() {
        let prompt = "multi"
        let imageTokenId: Int32 = 99
        let N = 5
        let ops = VLMTokenizerOperations(
            encode: Self.enc,
            applyChatTemplate: { p in [imageTokenId, 1, imageTokenId] + Self.enc(p, false) }
        )

        let result = assembleVLMPrompt(
            prompt: prompt, imageTokenCount: N, imageTokenId: imageTokenId, tokenizer: ops)

        // [N×99] + [1] + enc("multi",false)
        let expected: [Int32] =
            Array(repeating: imageTokenId, count: N) + [1] + Self.enc(prompt, false)
        #expect(result == expected)
        #expect(result.filter { $0 == imageTokenId }.count == N)
    }
}
