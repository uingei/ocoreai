import Foundation
// GrammarSchemaRegressionTests.swift — locks buildGrammarSchema JSON serializability.
// Regression: toAny 只剥一层 AnyCodable, 嵌套 schema(深度>=2)
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

    // `response_format:{"type":"json_object"}` carries no schema (OpenAI's spec says so),
    // so THIS function's fallback decides what "give me JSON" constrains. It used to be
    // `{"type":"object","properties":{}}`, which tells the grammar that no key is legal:
    // the only generatable answer is the empty object. Measured 10-18 on this host at
    // temp 0 — `json_object` → `'{}'` (2 completion tokens) for a prompt that names two
    // keys, while `json_schema` carrying `{"type":"object"}` → `{"answer":8,...}` (20).
    // vllm and sglang both map this mode to `{"type":"object"}`:
    // vllm/parser/abstract_parser.py:277, sglang/srt/entrypoints/openai/protocol.py:1191.
    @Test("json_object maps to an OPEN object — naming zero keys used to pin the answer to {}")
    func jsonObjectMapsToOpenObject() throws {
        let rf = try JSONDecoder().decode(
            ResponseFormat.self, from: Data(#"{"type":"json_object"}"#.utf8))
        let out = buildGrammarSchema(from: nil, responseFormat: rf)
        #expect(out == #"{"type":"object"}"#, "json_object must stay open, got \(out ?? "nil")")
        #expect(
            !(out?.contains("properties") ?? false),
            "the fallback pins a key list again — an empty list means only {} is legal")
    }

    /// Same fallback serves a `json_schema` that arrived without a schema body, so the
    /// same pin would silently empty those replies too.
    @Test("json_schema without a schema body stays open")
    func jsonSchemaWithoutSchemaStaysOpen() throws {
        let rf = try JSONDecoder().decode(
            ResponseFormat.self, from: Data(#"{"type":"json_schema"}"#.utf8))
        let out = buildGrammarSchema(from: nil, responseFormat: rf)
        #expect(
            out == #"{"type":"object"}"#,
            "schema-less json_schema must stay open, got \(out ?? "nil")")
    }

    /// One home, enforced mechanically: the zero-key literal must not come back anywhere
    /// in Sources — it had four copies (handler fallback + three constrained-decoding
    /// paths), and four copies is four chances to silently return `{}`.
    @Test("no second copy of the zero-key object schema survives in Sources")
    func zeroKeyLiteralAbsentFromSources() throws {
        var url = URL(fileURLWithPath: #filePath)
        var root: URL?
        for _ in 0 ..< 8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                root = url
                break
            }
        }
        guard let root else { throw CocoaError(.fileReadNoSuchFile) }
        let needle = #"{"type":"object","properties":{}}"#
        var scanned = 0
        var offenders: [String] = []
        guard
            let walk = FileManager.default.enumerator(
                at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        else { throw CocoaError(.fileReadNoSuchFile) }
        for case let file as URL in walk {
            guard file.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scanned += 1
            // Comments are dropped first (same convention as the `git grep` claim markers):
            // the schema's own doc comment quotes the defective literal to explain why it
            // is gone, and prose is not a second copy of it.
            let code =
                text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
                    {
                        return ""
                    }
                    guard let cut = line.range(of: "//") else { return String(line) }
                    return String(line[..<cut.lowerBound])
                }
                .joined(separator: "\n")
            // Backslashes stripped so an escaped Swift literal matches as well as raw text.
            if code.replacingOccurrences(of: "\\", with: "").contains(needle) {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(
            scanned >= 200,
            "the scan saw only \(scanned) Swift files — it is not looking at the tree")
        #expect(
            offenders.isEmpty,
            "the zero-key object schema is back in \(offenders) — that schema means only {} is legal"
        )
    }

    /// The shape a client really sends when it wants both: `tools[]` + `response_format` in
    /// one turn, `tool_choice` unset. Four shapes were run on this engine and this is the
    /// only one that keeps a decidable promise: envelope-first delivered the caller's JSON
    /// 0/3 with every turn ending `finish: tool_calls` (one of them a schema-valid but
    /// semantically absurd `edit_file{oldString:"read_file",…}`); an `anyOf` of both members
    /// compiled and then reported the document finished after one brace
    /// (`grammarTerm=true tokens=1`, content `'{'` / `'}'`); and no grammar at all fenced the
    /// answer in ```json, so nothing downstream could parse it (3/3). sglang installs a tool
    /// grammar only for a demand (`serving_chat.py:1488-1501`) and calls the schema response
    /// data (`serving_chat.py:1349-1353`). What JSON-first still cannot do is ground a turn
    /// that must call a tool before answering — probe 12 §7 holds that open.
    @Test("tools + json_object: the caller's JSON wins, the envelope must not")
    func jsonObjectBeatsToolEnvelope() throws {
        let tools = try decodeTools(
            """
            [{"type":"function","function":{"name":"echo","description":"Echo back.",
              "parameters":{"type":"object",
                 "properties":{"text":{"type":"string"}}, "required":["text"]}}}]
            """)
        let rf = try JSONDecoder().decode(
            ResponseFormat.self, from: Data(#"{"type":"json_object"}"#.utf8))
        let out = try #require(buildGrammarSchema(from: tools, responseFormat: rf, toolChoice: nil))
        #expect(out == jsonObjectSchema, "json_object must be the open object here, got \(out)")
        #expect(!out.contains("oneOf"), "the tool envelope is back on the wire")
        #expect(!out.contains("echo"), "tool names leaked into the answer grammar")
    }

    @Test("tools + json_schema: the caller's schema is the grammar")
    func jsonSchemaBeatsToolEnvelope() throws {
        let tools = try decodeTools(
            """
            [{"type":"function","function":{"name":"edit_file","description":"Edit a file.",
              "parameters":{"type":"object","properties":{"path":{"type":"string"}},
               "required":["path"]}}}]
            """)
        let rf = try JSONDecoder().decode(
            ResponseFormat.self,
            from: Data(
                #"""
                {"type":"json_schema","json_schema":{"name":"answer",
                 "schema":{"type":"object","properties":{"n":{"type":"integer"}},
                          "required":["n"]}}}
                """#.utf8))
        let out = try #require(
            buildGrammarSchema(from: tools, responseFormat: rf, toolChoice: "auto"))
        let parsed = try JSONDecoder().decode([String: AnyCodable].self, from: Data(out.utf8))
        #expect(parsed["type"]?.value as? String == "object")
        #expect(
            (parsed["properties"]?.value as? [String: Any])?["n"] != nil,
            "the caller's key vanished: \(out)")
        #expect(parsed["oneOf"] == nil, "the tool envelope is back on the wire")
        #expect(!out.contains("edit_file"), "tool names leaked into the answer grammar")
    }

    /// A demand IS the answer shape: `tool_choice: "required"`/pinned function means the
    /// caller asked for a call, so the envelope constrains alone even with a JSON
    /// `response_format` alongside it — sglang's `required`-only rule, same direction.
    @Test("tool_choice required keeps the envelope alone, and constrains")
    func demandKeepsEnvelopeAlone() throws {
        let tools = try decodeTools(
            """
            [{"type":"function","function":{"name":"echo","description":"Echo back.",
              "parameters":{"type":"object","properties":{"text":{"type":"string"}},
               "required":["text"]}}}]
            """)
        let rf = try JSONDecoder().decode(
            ResponseFormat.self, from: Data(#"{"type":"json_object"}"#.utf8))
        let out = try #require(
            buildGrammarSchema(from: tools, responseFormat: rf, toolChoice: "required"))
        #expect(out.contains("\"oneOf\""), "a demand must produce the envelope")
        #expect(out.contains("\"const\":\"echo\""), "the demanded tool is missing")
        #expect(out.contains("\"arguments\""), "the envelope lost its arguments key")
        #expect(
            shouldConstrainOutput(declaredTools: tools, responseFormat: rf, toolChoice: "required"),
            "a demand is the case the grammar exists for")
    }

    /// JSON with no tools on the wire is the grammar's own job and stays constrained.
    @Test("json alone stays just the caller's schema")
    func jsonAloneStaysConstrained() throws {
        let rf = try JSONDecoder().decode(
            ResponseFormat.self,
            from: Data(
                #"""
                {"type":"json_schema","json_schema":{"name":"answer",
                 "schema":{"type":"object","properties":{"n":{"type":"integer"}},
                          "required":["n"]}}}
                """#.utf8))
        let out = try #require(buildGrammarSchema(from: nil, responseFormat: rf, toolChoice: nil))
        let root = try JSONDecoder().decode([String: AnyCodable].self, from: Data(out.utf8))
        #expect(root["type"]?.value as? String == "object")
        #expect((root["properties"]?.value as? [String: Any])?["n"] != nil)
        #expect(
            shouldConstrainOutput(declaredTools: nil, responseFormat: rf, toolChoice: nil),
            "a JSON-only turn must stay grammar-constrained — that shape is decidable")
    }

    @Test("the open-object string and the open-object dict form are one decision")
    func openObjectFormsAgree() throws {
        #expect(grammarSchemaString(["type": "object"]) == jsonObjectSchema)
    }
}

private func decodeTools(_ json: String) throws -> [ToolDef] {
    try JSONDecoder().decode([ToolDef].self, from: Data(json.utf8))
}
