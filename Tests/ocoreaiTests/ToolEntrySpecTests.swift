// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolEntrySpecTests — pins the OpenAI function-calling JSON Schema surface.
///
/// Upstream basis: `Sources/ocoreai/Tools/ToolEntry.swift:161-219`
/// (extension `ToolDef bridge` — `toToolDef()` + `buildParametersJSON()`).
///
/// Pattern: codex `apply_patch_spec_tests.rs` (`create_apply_patch_freeform_tool_matches_expected_spec`).
/// ocoreai is the consumer of this surface — the LLM sees the `ToolDef` JSON,
/// so a regression that renames a key, drops `required`, or loses the `items`
/// sub-schema will silently break model tool-calls at runtime. Pinning here
/// surfaces it at test time. Zero new source surface — pure assertion on
/// the existing pure functions.
///
/// Conventions: swift-testing (`@Suite`/`@Test`) + `#expect`, aligned with
/// existing `ToolRegistryTests.swift`.

import Foundation
import Testing

@testable import ocoreai

@Suite("ToolEntry spec (OpenAI function-calling schema pinned)")
struct ToolEntrySpecTests {

    // MARK: - Helpers

    private func typedEntry(
        _ name: String, _ toolset: String = "t",
        _ params: [String: ToolParameter]
    ) -> ToolEntry {
        ToolEntry(
            name: name, toolset: toolset,
            schema: ToolSchema(parameters: params),
            handler: { _ in "" }
        )
    }

    /// Unwrap one `AnyCodable.value` (`Any`) into a concrete value.
    private func unwrap(_ ac: AnyCodable?) -> Any? { ac?.value }

    private func paramsOf(_ entry: ToolEntry) -> [String: AnyCodable]? {
        entry.toToolDef().function.parameters
    }

    private func propsOf(_ entry: ToolEntry) -> [String: [String: Any]]? {
        let p = paramsOf(entry)
        guard let raw = p?["properties"]?.value as? [String: AnyCodable] else { return nil }
        var out: [String: [String: Any]] = [:]
        for (k, v) in raw {
            out[k] = v.value as? [String: Any]
        }
        return out
    }

    private func stringParam(_ desc: String = "") -> ToolParameter {
        ToolParameter(type: .string, description: desc)
    }

    // MARK: - Top-level ToolDef shape

    @Test("ToolDef.type == 'function' and function.name round-trips")
    func typeAndNameRoundTrip() {
        let entry = typedEntry("read_file", "fs", ["path": stringParam("file path")])
        let def = entry.toToolDef()
        #expect(def.type == "function")
        #expect(def.function.name == "read_file")
    }

    @Test("FunctionDef.description encodes name, toolset, and param summary")
    func descriptionEncodesNameToolsetAndParams() {
        let entry = typedEntry(
            "web_search", "net",
            [
                "query": stringParam("search terms"),
                "count": ToolParameter(type: .integer, description: "max results"),
            ])
        let desc = entry.toToolDef().function.description
        #expect(desc != nil)
        #expect(desc!.contains("web_search"))
        #expect(desc!.contains("net"))
        #expect(desc!.contains("query:string"))
        #expect(desc!.contains("count:integer"))
    }

    // MARK: - parameters JSON (the model-facing contract)

    @Test("parameters.type == object and properties are keyed by param name")
    func parametersTopLevelShape() {
        let entry = typedEntry(
            "write_file", "fs",
            [
                "path": stringParam("target path"),
                "content": stringParam("file contents"),
            ])
        let params = paramsOf(entry)
        #expect(params != nil)

        #expect(unwrap(params!["type"]) as? String == "object")

        let props = propsOf(entry)
        #expect(props?.count == 2)
        #expect(props?["path"]?["type"] as? String == "string")
        #expect(props?["path"]?["description"] as? String == "target path")
        #expect(props?["content"]?["type"] as? String == "string")
    }

    @Test("parameters.required contains exactly the declared param names")
    func requiredContainsAllDeclared() {
        let entry = typedEntry(
            "exec_command", "shell",
            [
                "command": stringParam("shell command"),
                "workdir": stringParam("working directory"),
                "timeout": ToolParameter(type: .integer, description: "seconds"),
            ])
        let required = unwrap(paramsOf(entry)!["required"]) as? [String]
        #expect(Set(required ?? []) == Set(["command", "workdir", "timeout"]))
    }

    @Test("array parameter carries items sub-schema (JSON Schema 'items' key)")
    func arrayItemsPropagate() {
        let arr = ToolParameter(
            type: .array, description: "list of paths",
            items: ToolParameter(type: .string, description: "a path")
        )
        let entry = typedEntry("read_files", "fs", ["paths": arr])
        let props = propsOf(entry)
        #expect(props?["paths"]?["type"] as? String == "array")
        let items = props?["paths"]?["items"] as? [String: Any]
        #expect(items?["type"] as? String == "string")
        #expect(items?["description"] as? String == "a path")
    }

    @Test("object parameter carries element-level required keys")
    func objectRequiredKeys() {
        let step = ToolParameter(type: .object, description: "step", required: ["step"])
        let steps = ToolParameter(
            type: .array, description: "plan steps", items: step
        )
        let entry = typedEntry("plan", "agent", ["steps": steps])
        let item = propsOf(entry)?["steps"]?["items"] as? [String: Any]
        #expect(item?["type"] as? String == "object")
        #expect(item?["required"] as? [String] == ["step"])
    }

    @Test("empty schema → parameters is nil (no empty object sent to model)")
    func emptySchemaYieldsNilParameters() {
        let entry = typedEntry("noargs", "t", [:])
        let def = entry.toToolDef()
        #expect(def.function.parameters == nil)
    }
}
