// ToolDeclarationSurfaceTests.swift — a client-declared tool stays declared.
//
// The defect these tests exist for (measured live 10-18): the handler intersected
// the caller's `tools[]` with the local registry and dropped what did not survive,
// so `tools:[get_weather]` produced a prompt with NO tool block, no grammar, no
// `hasNativeTools`, and an answer that was prose with `finish_reason: stop`. The
// client could not execute a call it never received. The invariant these tests hold:
// the declaration IS the surface; the registry only decides who executes.

import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("Tool declaration surface (10-18 caller-owned tools)")
struct ToolDeclarationSurfaceTests {

    private func registrySpecs() async -> [[String: any Sendable]] {
        let registry = ToolRegistry(log: Logger(label: "test.declsurface"))
        for (name, param) in [("read_file", "path"), ("exec_command", "command")] {
            try? await registry.register(
                ToolEntry(
                    name: name, toolset: "t", schema: .init(parameters: [param: .string]),
                    handler: { _ in "ok" }))
        }
        return await registry.toToolSpecs()
    }

    private func names(_ specs: [[String: any Sendable]]) -> [String] {
        specs.compactMap {
            (($0["function"] as? [String: any Sendable])?["name"]) as? String
        }
    }

    /// A caller-declared `get_weather` ToolDef, as the wire would send it.
    private func weatherDef() -> ToolDef {
        ToolDef(
            function: FunctionDef(
                name: "get_weather",
                description: "Current weather for a city",
                parameters: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "city": AnyCodable(["type": "string", "description": "City name"])
                    ]),
                    "required": AnyCodable(["city"]),
                ]))
    }

    // MARK: - resolveToolSurface

    @Test("declared-but-unregistered name is declared from the caller's own spec")
    func callerOnlyNameIsStillDeclared() async {
        let specs = await registrySpecs()
        let json = openAIToolSpecsJSON(from: [weatherDef()])
        let (surface, localNames, route) = resolveToolSurface(
            specs: specs,
            declaredNames: ["get_weather"],
            declaredSpecsJSON: json)
        #expect(names(surface) == ["get_weather"], "the declaration must reach the model")
        #expect(localNames.isEmpty, "we cannot execute a tool the caller owns")
        #expect(route.contains("caller-only"), "the log must name the split: \(route)")
    }

    @Test("mixed declaration keeps declared order and reports who owns what")
    func mixedSurfaceKeepsDeclaredOrder() async {
        let specs = await registrySpecs()
        let json = openAIToolSpecsJSON(
            from: [
                weatherDef(),
                ToolDef(
                    function: FunctionDef(name: "read_file", description: nil, parameters: nil)),
            ])
        let (surface, localNames, route) = resolveToolSurface(
            specs: specs,
            declaredNames: ["get_weather", "read_file"],
            declaredSpecsJSON: json)
        #expect(names(surface) == ["get_weather", "read_file"])
        #expect(localNames == ["read_file"] as Set<String>)
        #expect(route.contains("1 local + 1 caller-only of 2"), "route was \(route)")
    }

    @Test("registry schema wins over the caller's for a name we own")
    func registrySchemaWins() async {
        let specs = await registrySpecs()
        // Caller lies about the description of a tool we register.
        let lying = ToolDef(
            function: FunctionDef(
                name: "read_file", description: "NOT the real description",
                parameters: ["type": AnyCodable("object")]))
        let (surface, localNames, _) = resolveToolSurface(
            specs: specs, declaredNames: ["read_file"],
            declaredSpecsJSON: openAIToolSpecsJSON(from: [lying]))
        #expect(localNames == ["read_file"] as Set<String>)
        let function = surface.first?["function"] as? [String: any Sendable]
        #expect((function?["description"] as? String) != "NOT the real description")
    }

    @Test("no declaration still means zero tools (10-06 flip preserved)")
    func nilAndEmptyStillZero() async {
        let specs = await registrySpecs()
        let json = openAIToolSpecsJSON(from: [weatherDef()])
        let (nilSurface, nilLocal, nilRoute) = resolveToolSurface(
            specs: specs, declaredNames: nil, declaredSpecsJSON: json)
        #expect(nilSurface.isEmpty)
        #expect(nilLocal.isEmpty)
        #expect(nilRoute.contains("no-tools route"))
        let (emptySurface, _, emptyRoute) = resolveToolSurface(
            specs: specs, declaredNames: [], declaredSpecsJSON: json)
        #expect(emptySurface.isEmpty)
        #expect(emptyRoute.contains("no-tools route"))
    }

    @Test("without caller specs the old whitelist behaviour is preserved (GUI path)")
    func absentSpecsDegradeToRegistryWhitelist() async {
        let specs = await registrySpecs()
        let (surface, localNames, route) = resolveToolSurface(
            specs: specs, declaredNames: ["read_file", "no_such_tool"])
        #expect(names(surface) == ["read_file"])
        #expect(localNames == ["read_file"] as Set<String>)
        #expect(route.contains("0 caller-only"), "route was \(route)")
    }

    @Test("duplicate declared names declare the tool once")
    func duplicateDeclarationDedupes() async {
        let specs = await registrySpecs()
        let (surface, _, _) = resolveToolSurface(
            specs: specs,
            declaredNames: ["get_weather", "get_weather"],
            declaredSpecsJSON: openAIToolSpecsJSON(from: [weatherDef(), weatherDef()]))
        #expect(names(surface) == ["get_weather"])
    }

    // MARK: - spec JSON carrier

    @Test("spec JSON carries name, description and a nested parameter schema")
    func specCarriesFullDeclaration() throws {
        guard let json = openAIToolSpecsJSON(from: [weatherDef()]) else {
            Issue.record("expected spec JSON")
            return
        }
        guard let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let array = parsed as? [[String: Any]],
            let first = array.first,
            let function = first["function"] as? [String: Any]
        else {
            Issue.record("spec JSON is not the tool array shape")
            return
        }
        #expect(first["type"] as? String == "function")
        #expect(function["name"] as? String == "get_weather")
        #expect(function["description"] as? String == "Current weather for a city")
        let params = function["parameters"] as? [String: Any]
        #expect(params?["type"] as? String == "object")
        let props = params?["properties"] as? [String: Any]
        #expect((props?["city"] as? [String: Any])?["type"] as? String == "string")
        #expect(params?["required"] as? [String] == ["city"])
    }

    @Test("no tools declared → no spec JSON (nil is not an empty array)")
    func specJSONNilForNoTools() {
        #expect(openAIToolSpecsJSON(from: nil) == nil)
        #expect(openAIToolSpecsJSON(from: []) == nil)
    }

    @Test("round trip JSON → specs keeps the declaration intact")
    func jsonRoundTripKeepsDeclaration() {
        guard let json = openAIToolSpecsJSON(from: [weatherDef()]) else {
            Issue.record("expected spec JSON")
            return
        }
        let specs = declaredToolSpecs(fromJSON: json)
        #expect(names(specs) == ["get_weather"])
        let function = specs.first?["function"] as? [String: any Sendable]
        let params = function?["parameters"] as? [String: any Sendable]
        #expect(params?["required"] as? [any Sendable] != nil)
    }

    @Test("malformed spec JSON yields zero specs, never a partial declaration")
    func malformedSpecJSONYieldsNothing() {
        #expect(declaredToolSpecs(fromJSON: nil).isEmpty)
        #expect(declaredToolSpecs(fromJSON: "not json").isEmpty)
        #expect(declaredToolSpecs(fromJSON: "{\"type\":\"function\"}").isEmpty, "object, not array")
    }

    @Test("surface resolves a declaration carried as JSON end to end")
    func endToEndSurfaceFromJSON() {
        // No registry specs at all: the caller's declaration is the whole surface.
        let (surface, localNames, route) = resolveToolSurface(
            specs: [], declaredNames: ["get_weather"],
            declaredSpecsJSON: openAIToolSpecsJSON(from: [weatherDef()]))
        #expect(names(surface) == ["get_weather"])
        #expect(localNames.isEmpty)
        #expect(route.contains("1 caller-only"), "route was \(route)")
    }

    @Test(arguments: forcingCases)
    func forcingFollowsToolChoice(choice: String?, expectsCall: Bool) {
        #expect(
            toolChoiceDemandsCall(choice) == expectsCall,
            "tool_choice=\(choice ?? "<absent>") → \(expectsCall ? "forced" : "optional")")
    }

    @Test("guided forcing reads tool_choice, not the presence of tools[]")
    func handlerGatesForcingOnToolChoice() throws {
        let src = try repoFile("Sources/ocoreai/Handlers/ChatHandler.swift")
        #expect(src.count > 20_000, "handler read looks truncated (\(src.count) chars)")
        #expect(
            src.contains("hasTools && toolChoiceDemandsCall(request.toolChoice)"),
            "guidance no longer follows tool_choice — declaring a tool would force a call again")
        #expect(
            !src.contains("return hasTools || hasJsonSchema"),
            "the old declaration-forces-grammar line is back: an auto turn loses its answer")
    }

    @Test("the non-stream wire takes the engine's calls, not only a re-parse of text")
    func nonStreamPrefersStructuredCalls() throws {
        let src = try repoFile("Sources/ocoreai/Handlers/ChatHandler.swift")
        #expect(
            src.contains("if let detected = detectedToolCalls, !detected.isEmpty {"),
            "non-stream must take the engine's calls: upstream strips the dialect off finalContent")
    }
}

/// OpenAI's `tool_choice` vocabulary, plus the pinned-function shape the decoder
/// normalizes to `function:<name>`. Absent and "auto" both mean "the model may
/// answer"; only "required" and a pinned name demand a call.
private let forcingCases: [(choice: String?, expectsCall: Bool)] = [
    (nil, false), ("auto", false), ("none", false), ("required", true),
    ("function:get_weather", true), ("REQUIRED", false),
]

/// Find the repo by searching for `Package.swift`, never by fixed parent hops — a fixed
/// hop lands outside the tree and an ENOENT reads as a pass.
private func repoFile(_ relative: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 8 {
        url.deleteLastPathComponent()
        let root = url.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: root.path) {
            return try String(contentsOf: root, encoding: .utf8)
        }
    }
    throw CocoaError(.fileReadNoSuchFile)
}
