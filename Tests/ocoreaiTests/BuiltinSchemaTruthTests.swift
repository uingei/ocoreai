// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// BuiltinSchemaTruthTests — the schema-lie regression gate on the REAL
// production registry (same bootstrap as boot). Live proof (2026-10-11,
// official v0.1.12 DMG /v1/tools): info / skills_lookup / skills_view /
// echo advertised `properties: {}` while their argsType carries stored
// members — the model cannot call them correctly without knowing the keys.
// Discipline (mirrors ToolSpecFullRegistryTests): production bootstrap,
// exact per-key asserts, no count>0 softness. Zero-parameter tools
// (curr_time, system_info, observe_state, get_context_remaining) legitimately
// advertise empty properties — that is truth, not the lie; the lie is
// "argsType has members AND advertised properties is empty".
import Foundation
import Logging
import Testing

@testable import ocoreai

struct BuiltinSchemaTruthTests {

    static func registry() async -> ToolRegistry {
        let r = ToolRegistry(log: Logger(label: "test.schema-truth"))
        await bootstrapBuiltInTools(registry: r, skillRegistry: SkillRegistry())
        return r
    }

    /// Advertised OpenAI wire properties for a tool (nil if absent).
    static func properties(
        for tool: String, in defs: [ToolDef]
    ) throws -> [String: Any] {
        let def = try #require(defs.first { $0.function.name == tool })
        let params = try #require(def.function.parameters)
        let props = params["properties"]?.value as? [String: Any]
        return props ?? [:]
    }

    @Test("the 5 fixed liars advertise their real parameter keys")
    func fixedLiarsCarryRealKeys() async throws {
        let defs = await Self.registry().toToolDefs()
        let info = try Self.properties(for: "info", in: defs)
        #expect(info.keys.sorted() == ["topic"])
        let skillsList = try Self.properties(for: "skills_list", in: defs)
        #expect(skillsList.keys.sorted() == ["category"])
        let lookup = try Self.properties(for: "skills_lookup", in: defs)
        #expect(lookup.keys.sorted() == ["name"])
        let view = try Self.properties(for: "skills_view", in: defs)
        #expect(view.keys.sorted() == ["file", "name"])
        let echo = try Self.properties(for: "echo", in: defs)
        #expect(echo.keys.sorted() == ["message"])
    }

    @Test("required subsets are honest: only skills_view.name is mandatory")
    func requiredSubsets() async throws {
        let defs = await Self.registry().toToolDefs()
        func required(_ tool: String) throws -> [String] {
            let def = try #require(defs.first { $0.function.name == tool })
            return (def.function.parameters?["required"]?.value as? [String]) ?? []
        }
        #expect(try required("info") == [])
        #expect(try required("echo") == [])
        #expect(try required("skills_lookup") == ["name"])
        #expect(try required("skills_view") == ["name"])
    }

    @Test("every advertised built-in: schema empty ⇔ argsType truly parameterless")
    func noNewLiars() async throws {
        // Exhaustive invariant over the production registry. A tool may
        // advertise empty properties ONLY if its handler ignores arguments.
        // The four parameterless ones are enumerated with exact names so a
        // future registration with a silent empty schema trips THIS gate.
        let defs = await Self.registry().toToolDefs()
        let parameterless: Set<String> = [
            "curr_time", "system_info", "observe_state", "get_context_remaining",
            "get_plan",
        ]
        for def in defs {
            let name = def.function.name
            let props = (def.function.parameters?["properties"]?.value as? [String: Any]) ?? [:]
            if props.isEmpty {
                let truthful = parameterless.contains(name)
                #expect(truthful, "empty-properties liar: \(name) must declare schema")
            }
        }
    }
}
