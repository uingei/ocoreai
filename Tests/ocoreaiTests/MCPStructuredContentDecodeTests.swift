// Copyright © 2026 uingei@163.com.
/// MCP tool-result `structuredContent` 解码 — codex 轴铁律缺口.
///
/// Baseline: codex `protocol/src/models.rs:2227-2266` 真值链:
///   1. `content` 中任一 `EncryptedContent`  → 独占(结构化不生效)
///   2. `structuredContent` 非 null           → 序列化**优先于** `content`(整段替代)
///   3. 否则 `content` items 走常规通道
///
/// ocoreai 缺口: 两处解码点(`MCPStdioClient.parseToolCallResponse` 外部 +
/// `MCPBridge` local dispatch 内部)**均只取 `result.content` 数组,`structuredContent`
/// 静默丢弃** — 上游(本地 + 外部)结构化结果面消费为零,违反 codex 轴对齐铁律.
///
/// 修复面:
///   - `MCPBridge.parseToolCallJSON`    (纯函数, 可单测)
///   - `MCPBridge.serializeStructuredContent` (纯字符串序列化)
///   - 2 处解码点统一改走 `MCPBridge.parseToolCallJSON`

import Foundation
import Testing

@testable import ocoreai

@Suite("MCP — structuredContent decode (codex models.rs:2227-2266 baseline)")
struct MCPStructuredContentDecodeTests {

    // MARK: - Codex 优先级链

    @Test("structuredContent 非 null → 序列化后优先于 content 返回")
    static func structuredContentBeatsContent() {
        let json = #"""
            {"jsonrpc":"2.0","id":1,"result":{
              "content":[{"type":"text","text":"human-readable view"}],
              "structuredContent":{"rows":[{"id":1},{"id":2}],"count":2},
              "isError":false
            }}
            """#
        let blocks = MCPBridge.parseToolCallJSON(json)
        let text = blocks.compactMap { $0["text"] }.joined()
        // codex: structured 序列化优先于 content
        #expect(text.contains("\"rows\""))
        #expect(text.contains("\"count\":2"))
        #expect(!text.contains("human-readable view"))
        #expect(blocks.count == 1, "structured 独占 — 不应再追加 content 块")
    }

    @Test("structuredContent 嵌套对象 → 紧凑 JSON 序列化,键排序确定")
    static func nestedStructuredContent() {
        let json = #"""
            {"result":{"content":[],
             "structuredContent":{"b":[1,2],"a":{"c":[{"d":true}]}}}}
            """#
        let blocks = MCPBridge.parseToolCallJSON(json)
        #expect(blocks.count == 1)
        let s = blocks[0]["text"] ?? ""
        #expect(
            s.contains("\"a\"") && s.contains("\"b\"") && s.contains("\"c\"") && s.contains("\"d\"")
        )
        #expect(!s.contains("human") && !s.contains("null"), "无 null 键; 无 content 串入")
    }

    @Test("structuredContent 显式 null → 视同缺失,回退 content 通道")
    static func structuredContentNullFallsBackToContent() {
        let json = #"""
            {"result":{"content":[{"type":"text","text":"plain"}],
             "structuredContent":null,
             "isError":false}}
            """#
        let blocks = MCPBridge.parseToolCallJSON(json)
        let text = blocks.compactMap { $0["text"] }.joined()
        #expect(text == "plain")
        #expect(!text.contains("{"), "null 不应被序列化为字面 'null' 字符串塞进 text")
        #expect(blocks.count == 1)
    }

    @Test("structuredContent 缺失 + content 空 → 空 blocks(MCP 合法: result.content 可为空数组)")
    static func structuredContentAbsentEmptyContent() {
        let json = #"{"result":{"content":[]}}"#
        let blocks = MCPBridge.parseToolCallJSON(json)
        #expect(blocks.isEmpty, "空 content 数组是 MCP 合法结果形态 → 解码为空, 不臆造占位块")
    }

    // MARK: - 值保真红线

    @Test("JSON 整数 1 必须解码为 number(1), 不能失真为 true(NSNumber 桥接陷阱)")
    static func integerOneDoesNotBecomeTrue() {
        // NSNumber(1) as? Bool == true — 若 Bool 判别排在 Int 之前, 1 会编成 true(值失真)
        let json =
            #"{"result":{"structuredContent":{"flag":true,"id":1,"ratio":0.5,"list":[1,2,3]}}}"#
        let blocks = MCPBridge.parseToolCallJSON(json)
        let s = blocks.first?["text"] ?? ""
        // flag(显式 true)保留为 true; id(JSON 1)必须是 number 1, 不是 true
        #expect(s.contains(#""flag":true"#), "显式 true 保留")
        #expect(s.contains(#""id":1"#), "JSON 整数 1 保真为 number(1)")
        #expect(s.contains(#""ratio":0.5"#), "小数 0.5 保真")
        #expect(s.contains(#""list":[1,2,3]"#), "数组内整数全保真")
        #expect(!s.contains(#""id":true"#), "1 不得被编为 true")
    }

    // MARK: - 边界

    @Test("structuredContent 是 JSON 标量(string) → 原样保留,不加引号包装错乱")
    static func structuredScalar() {
        let json =
            #"{"result":{"content":[{"type":"text","text":"t"}],"structuredContent":"raw-string"}}"#
        let blocks = MCPBridge.parseToolCallJSON(json)
        #expect(blocks.count == 1)
        #expect((blocks[0]["text"] ?? "").contains("raw-string"))
    }

    @Test("JSON 语法错 → 不崩溃,返回失败提示")
    static func malformedJSON() {
        let blocks = MCPBridge.parseToolCallJSON("{not-json")
        #expect(!blocks.isEmpty)
        #expect(blocks.allSatisfy { ($0["text"] ?? "").contains("Failed to parse") })
    }

    // MARK: - 序列化纯函数

    @Test("serializeStructuredContent → 合法 JSON(语义等价,键序确定)")
    static func serializeEmpty() {
        let s = MCPBridge.serializeStructuredContent(["a": 1] as [String: Any])
        // beta 工具链 XPCDictionary 桥接下 Optional<Any> == 字面量不可靠 — 用解析后的具体字段精确断言
        guard
            let parsed = try? JSONSerialization.jsonObject(with: s.data(using: .utf8)!)
                as? [String: Any]
        else {
            #expect(s == "{\"a\":1}")
            return
        }
        #expect((parsed["a"] as? Int) == 1)
        #expect(parsed.count == 1)
    }

    @Test("serializeStructuredContent 嵌套 array 含 nil → 合法 JSON")
    static func serializeNested() {
        let v: [String: Any] = ["arr": [1, "two", ["three"]]]
        let s = MCPBridge.serializeStructuredContent(v)
        let data = s.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data)
        #expect(parsed != nil, "序列化结果必须是合法 JSON")
        if let p = parsed as? [String: Any], let a = p["arr"] as? [Any], let i0 = a.first {
            #expect(i0 is Int && (i0 as? Int) == 1)
        }
    }
}
