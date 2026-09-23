// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Work tool schema-type round-trip regression — pins the contract that the
/// parameter type exposed to the model in the wire schema must match the
/// declared type of the corresponding Codable `Args` field on the receiving
/// side, for every numeric field on the work surface (`computer` toolset).
///
/// Why it matters: a live probe on 2026-09-24 showed `list_apps` — and by
/// inspection the same pattern across 12 numeric fields (list_apps.limit,
/// read_clipboard.max_chars, inspect_ui.depth/max_nodes,
/// move_mouse.x/y, click.x/y, drag.x1/y1/x2/y2) — declaring `type: "string"`
/// in the schema while the `Args` struct field is `Int?` / `Int`. A model
/// that honours the declared type (emitting strings) decodes straight into
/// `The data couldn't be read because it isn't in the correct format.` on
/// the ocoreai side — not a model-capability gap. Reproduced with two
/// different models (Qwen3.5-0.8B-4bit VLM + gemma-4-e2b-it-4bit, both
/// routed through the same tool call loop with loopDetected retries).
///
/// The fix (2026-09-24, commit pending): changed the schema declaration to
/// `.integer` for all 12 numeric fields. This test pins that contract so
/// neither the Args field nor the schema declaration may be independently
/// changed to a type whose JSON representation is incompatible, without an
/// update to the other side and a deliberate update to this test.
import Foundation
import Logging
import Testing

#if os(macOS)
@testable import ocoreai

@Suite("Work tool numeric-field schema type round-trip")
struct WorkToolSchemaTypeRoundTripTests {
    /// Verify that the schema-declared parameter type for `param` in tool
    /// `toolName` matches `expected` (the type we pin for Args-field
    /// compatibility — Int? fields must be .integer, Int fields must be
    /// .integer, and so on). Returns the observed type on failure.
    private static func assertNumericFieldType(
        _ registry: ToolRegistry,
        _ toolName: String,
        _ param: String,
        expected: ParameterType
    ) async -> Bool {
        guard let schema = await registry.schema(for: toolName),
            let observed = schema.parameters[param]?.type
        else {
            return false
        }
        return observed == expected
    }

    /// All 12 numeric fields on the work surface must declare a type whose
    /// JSON payload decodes into the corresponding `Args` field type.
    @Test("schema-declared type for each numeric field decodes into the Args type")
    func allNumericFieldsAreIntegerTyped() async throws {
        let registry = ToolRegistry(log: Logger(label: "test.schematype"))
        await bootstrapBuiltInTools(registry: registry)

        // list_apps.limit — Int? — live-reproduced
        #expect(
            await Self.assertNumericFieldType(registry, "list_apps", "limit", expected: .integer),
            "list_apps.limit must be .integer (Args field is Int?; a .string declaration breaks decode)"
        )
        // read_clipboard.max_chars — Int?
        #expect(
            await Self.assertNumericFieldType(
                registry, "read_clipboard", "max_chars", expected: .integer))
        // inspect_ui.depth / max_nodes — Int?
        #expect(
            await Self.assertNumericFieldType(registry, "inspect_ui", "depth", expected: .integer))
        #expect(
            await Self.assertNumericFieldType(
                registry, "inspect_ui", "max_nodes", expected: .integer))
        // move_mouse.x / y — Int
        #expect(
            await Self.assertNumericFieldType(registry, "move_mouse", "x", expected: .integer))
        #expect(
            await Self.assertNumericFieldType(registry, "move_mouse", "y", expected: .integer))
        // click.x / y — Int
        #expect(
            await Self.assertNumericFieldType(registry, "click", "x", expected: .integer))
        #expect(
            await Self.assertNumericFieldType(registry, "click", "y", expected: .integer))
        // drag.x1 / y1 / x2 / y2 — Int
        #expect(
            await Self.assertNumericFieldType(registry, "drag", "x1", expected: .integer))
        #expect(
            await Self.assertNumericFieldType(registry, "drag", "y1", expected: .integer))
        #expect(
            await Self.assertNumericFieldType(registry, "drag", "x2", expected: .integer))
        #expect(
            await Self.assertNumericFieldType(registry, "drag", "y2", expected: .integer))
    }

    /// The live-reproduced tool end-to-end: decode the schema-declared JSON
    /// payload for `list_apps` through the registry dispatch path, and
    /// verify the call succeeds with the correct limit applied.
    @Test(
        "list_apps: an integer-typed payload per the declared schema decodes and dispatches successfully"
    )
    func listAppsIntegerPayloadRoundTrip() async throws {
        let registry = ToolRegistry(log: Logger(label: "test.schematype.rt"))
        await bootstrapBuiltInTools(registry: registry)

        // The wire payload the model will produce once the schema says "integer":
        // a JSON number, the exact value the Args field (Int?) decodes cleanly to.
        let argsJSON = #"""
            {"limit": 5}
            """#

        let out = try await registry.call("list_apps", arguments: argsJSON, caller: "test")
        #expect(
            out.contains("# apps"),
            "list_apps with integer limit must execute and report its header")
        #expect(
            out.split(whereSeparator: { $0 == "\n" }).dropFirst().count <= 6,
            "limit:5 should produce at most 5 data rows + 1 header (or fewer if fewer apps are running)"
        )
    }
}
#endif
