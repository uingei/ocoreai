import Foundation
// GrammarSchemaRegressionTests.swift — locks buildGrammarSchema JSON serializability.
// Regression: 2026-09-08 E2E — toAny 只剥一层 AnyCodable, 嵌套 schema(深度>=2)
// 导致 JSONSerialization "Invalid type in JSON write (__SwiftValue)" NSException,
// ObjC 异常 try? 接不住 → 进程死(带 tools 的 HTTP 请求全崩)。旧实现上 test1 的
// 嵌套 wire 即复现崩溃形态。
import Testing

@testable import ocoreai

@Suite("grammar schema JSON serializability (E2E crash regression)")
struct GrammarSchemaRegressionTests {

    // 探针原形: echo 工具, properties 内嵌 type/description(深度 2)+ required 数组。
    @Test("nested echo schema serializes (old code: NSException crash)")
    func nestedEchoSchemaSerializes() throws {
        let wire = """
            [{"type":"function","function":{"name":"echo","description":"Echo back EXACTLY the text.",
              "parameters":{"type":"object",
                 "properties":{"text":{"type":"string","description":"Text to echo verbatim."}},
                 "required":["text"]}}}]
            """
        let tools = try JSONDecoder().decode([ToolDef].self, from: Data(wire.utf8))
        let out = buildGrammarSchema(from: tools)
        #expect(out != nil, "expected grammar schema, got nil")
        guard let out else { return }
        #expect(out.contains("\"oneOf\""))
        #expect(out.contains("\"const\":\"echo\""))
        #expect(out.contains("\"arguments\""))
        // 深度 2 的 type/description 必须存活
        #expect(out.contains("\"text\""))
        #expect(out.contains("verbatim"))
        #expect(out.contains("\"required\":[\"name\",\"arguments\"]"))
    }

    // 多工具 + 数组 items 参数: 全深度可序列化。
    @Test("two tools with array items serialize")
    func twoToolsArrayItemsSerialize() throws {
        let wire = """
            [
             {"type":"function","function":{"name":"curr_time","description":"Get UTC time.",
              "parameters":{"type":"object","properties":{},"required":[]}}},
             {"type":"function","function":{"name":"list","description":"List files.",
              "parameters":{"type":"object","properties":
                 {"paths":{"type":"array","items":{"type":"string"}}},
                 "required":["paths"]}}}
            ]
            """
        let tools = try JSONDecoder().decode([ToolDef].self, from: Data(wire.utf8))
        let out = buildGrammarSchema(from: tools)
        #expect(out != nil, "expected grammar schema, got nil")
        guard let out else { return }
        #expect(out.contains("curr_time"))
        #expect(out.contains("list"))
        #expect(out.contains("items"))
    }

    // 空/nil tools → nil(契约, 不产出空 oneOf)。
    @Test("empty or nil tools gives nil")
    func emptyToolsNil() {
        #expect(buildGrammarSchema(from: nil) == nil)
        #expect(buildGrammarSchema(from: []) == nil)
    }
}
