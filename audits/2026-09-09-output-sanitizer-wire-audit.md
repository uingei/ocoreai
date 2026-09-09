# OutputSanitizer 接线审计 — 非流式 wire 输出净化(2026-09-09)

## 结论(证据基:od/hexdump 字节级,非目视)

非流式 `message.content` 在到达 OpenAI 兼容 wire 前经 `OutputSanitizer.strip()` 单点净化。
三个 artifact 全部以**字节级实证**定标,修正此前 10+ 次迭代的方向性错误:

| artifact | 模型 | 真实字节 | 此前误判 |
|---|---|---|---|
| gemma thinking span | gemma-4 2B | open `3C 7C "channel" 3E` / close `3C "channel" 7C 3E`(**pipe 0x7C**) | 误读成 slash 0x2F → 全部匹配失败 |
| Qwen thinking closer | Qwen3.5 4B | `3C 2F "think" 3E`(**forward slash 0x2F**) | 误读成 backslash 0x5C → 全部匹配失败 |
| fake tool-plan array | 两者 | 顶层 `[{\"name\":...,\"arguments\":...}]` 混在 prose 里 | 方向正确,但匹配器曾误伤 `[Double]` 等合法 Swift/JSON |

关键发现:
1. **Qwen 的 6 个 marker 全部是 closer,opener 为 0**(count "think"=6,hex 全是 `3C 2F` 形式)。
   → 语义规则 = 保留**最后一个 closer 之后**的文本(即最终答案),不能按 open-close span 匹配。
2. **gemma 的 4 个 channel 词 = 2 open + 2 close,成对**。→ open-close span 移除 + 未闭合 open 砍到末尾。
3. QWEN fixture 里 24 个 byte-seq `5C 6E` 全部位于被移除的 tool-array 内(Swift `new_string` 里的代码转义),
   合法 prose 全是真换行 `0A` → **不存在**需要全局 `\\n` 归一化的通道,故不做(避免误伤)。
4. 传输层会破坏特定字节序列(反斜杠+字母、heredoc 里的 slash 上下文)。
   纪律:marker 一律用 `Character(UnicodeScalar(0x..))` 拼装,禁止手写裸序列字面量;验证一律 `od`/hex,禁目视。

## 实现不变量(Tests/ocoreaiTests/OutputSanitizerTests.swift,16 测试全绿)

- tool-array 判定:顶层括号配对(串/转义感知,`'a]b'`、`printf '['` 不脱同步)+ 解析为 `[[String:Any]]` 且含 `name`。
  → 非 tool 的 `[Double]`、`["a","b"]`、单 `[` 逐字节保留。
- **零空白归一化**:删 `compressSpaceRuns`(曾把 `[Double]` 代码块 8 空格缩进压成 6 空格,被 exact-value 测试逮住)。
  合法缩进/换行必须 byte-exact 通过;数组删除后相邻的真换行保留(单空行分隔)。
- Qwen:最后一个 closer 后取尾;无 closer → 原样保留(仅 trim 首尾空白)。
- gemma:平衡 span 移除;尾部未闭合 open → 砍到末尾;残留孤立 closer/open → 清掉。
- 幂等:`strip(strip(x)) == strip(x)`。

## ChatHandler 集成(Sources/ocoreai/Handlers/ChatHandler.swift:832)

非流式成功路径:`content: toolCalls != nil ? "" : OutputSanitizer.strip(finalContent)`。
- toolCalls 解析成功 → content 置空,结构化通道唯一(无重复)。
- 解析失败 → content 走净化(数组/markers 已剥离),不再把伪 tool JSON 当 prose 回吐。
- 流式路径不受影响(E2E 走非流)。

## 验证链(本 session,全实证)

1. 两个真实 E2E fixture(/tmp/decoded_qwen4b.txt 3962B、/tmp/decoded_gemma2b.txt 3322B)
   跑 12 项程序化断言:**12/12 PASS**(gemma 输出="The tool execution failed because…";
   Qwen 输出="## Summary Bug Found: Line 8 in MathUtils.swift…",thinking 全剥离,0 残留 marker)。
2. `swift build --target ocoreai` → **exit 0**。
3. `swift test --filter OutputSanitizerTests` → **16/16 绿**
   (tool-array×4、prose-preserve×4、gemma×4、qwen×3、composed×1、幂等×1、clean-prose×1)。
4. 回归:`ChatPipelineBehavioralTests`+`ChatCompletionRequestWireCompletenessTests` → **23/23 绿**。
5. 活体测试纪律:lsof :8092 / pgrep `debug/ocoreai` → 0 残留。

## 遗留(非本审计范围)

- 流式路径未挂 sanitizer(当前 E2E/agent 面走非流;若后续开放流式,需在同点加增量净化)。
- Qwen opener 缺失是**模型侧**行为(fixture 实证 0 opener),净化层按"最后 closer 取尾"兼容,
  不依赖 opener;若上游 mlx-swift-lm / coreai-models 后续在模板里补 opener,本规则仍然成立。
- 活体 ollama E2E 复测(起单实例→跑→kill)待本 commit push 后的 CI 窗内排期,
  不阻塞:fixture 即该 E2E 的原始解码产物,程序化断言已覆盖同一路径。