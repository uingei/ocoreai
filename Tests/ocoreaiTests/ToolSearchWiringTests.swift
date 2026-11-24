// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// ToolSearchWiringTests. The reachable tool surface's wired half: `tool_search` registers only
// behind the boot flag (off build = today's surface), the arm choice makes a `tool_search` hit
// declare itself on the next turn, and the search result claims only what actually happened —
// a recorded set with an owner, or none (AGENTS.md invariant 2). The pure ranking is
// `ToolSurfaceReachabilityTests`; nothing here re-tests it.
import Foundation
import Logging
import Testing

@testable import ocoreai

private func fixtureDef(_ name: String, _ description: String) -> ToolDef {
    ToolDef(function: FunctionDef(name: name, description: description, parameters: nil))
}

private func fixtureEntry(_ name: String, _ description: String) -> ToolEntry {
    ToolEntry(
        name: name, toolset: "test",
        schema: ToolSchema(parameters: ["prompt": .string]),
        description: description,
        handler: { _ in "ok" })
}

@Suite(
    "tool_search landing (boot-gated registration, arm choice, honest recording)",
    .serialized)
struct ToolSearchWiringTests {

    // MARK: - the knob

    @Test("the knob is settings.toolSurface.reachable.enabled, default OFF")
    @MainActor
    func knobDefaultsOff() throws {
        #expect(
            SettingsStore.Key.toolSurfaceReachableEnabled.rawValue
                == "settings.toolSurface.reachable.enabled")
        let suite = try #require(
            UserDefaults(suiteName: "test.ocoreai.\(UUID().uuidString)"),
            "the fresh suite must exist for the default-OFF assertion")
        let store = SettingsStore(defaults: suite)
        #expect(store.toolSurfaceReachableEnabled == false, "OFF means today")
        store.toolSurfaceReachableEnabled = true
        #expect(SettingsStore(defaults: suite).toolSurfaceReachableEnabled == true, "it persists")
    }

    // MARK: - registration is boot-gated

    @Test("tool_search registers only while the flag was on at boot; off is today, byte for byte")
    func registrationIsBootGated() async {
        let off = ToolRegistry(log: Logger(label: "test.search.off"))
        await bootstrapBuiltInTools(registry: off)
        let on = ToolRegistry(log: Logger(label: "test.search.on"))
        await bootstrapBuiltInTools(registry: on, toolSurfaceReachableEnabled: true)

        let offNames = Set(await off.toToolDefs().map(\.function.name))
        let onNames = Set(await on.toToolDefs().map(\.function.name))
        #expect(!offNames.contains("tool_search"))
        #expect(onNames.subtracting(offNames) == ["tool_search"], "exactly the one name is added")
        // The registered entry: non-destructive, and query is the only required key.
        let entry = await on.schema(for: "tool_search")
        #expect(entry?.required == ["query"])
        #expect(Set((entry?.parameters ?? [:]).keys) == ["limit", "query"])
    }

    // MARK: - the arm choice

    @Test("off hands the surface untouched, order included")
    func offIsUntouched() {
        let defs = ["clock", "exec_command", "tool_search", "generate_video"].map {
            fixtureDef($0, "d")
        }
        let applied = ToolSurfaceCuration.apply(defs, enabled: false)
        #expect(applied?.map(\.function.name) == defs.map(\.function.name))
    }

    @Test("reachable ON hands core + tool_search + discovered; deferred tools leave")
    func reachableArmComposition() {
        let names = [
            "read_file", "exec_command", "tool_search", "generate_video", "clock", "speak",
        ]
        let defs = names.map { fixtureDef($0, "d") }
        let applied = ToolSurfaceCuration.apply(
            defs, enabled: false, reachable: true, discovered: ["generate_video"])
        #expect(
            applied?.map(\.function.name)
                == ["read_file", "exec_command", "tool_search", "generate_video"])
        // Nothing discovered: the arm is the core six plus the one door.
        let bare = ToolSurfaceCuration.apply(defs, enabled: false, reachable: true)
        #expect(bare?.map(\.function.name) == ["read_file", "exec_command", "tool_search"])
    }

    @Test("reachable wins over curation when both are on")
    func reachableWins() {
        let defs = ["read_file", "tool_search", "generate_video"].map { fixtureDef($0, "d") }
        let both = ToolSurfaceCuration.apply(
            defs, enabled: true, reachable: true, discovered: ["generate_video"])
        #expect(both?.map(\.function.name) == ["read_file", "tool_search", "generate_video"])
    }

    @Test("reachable declines to engage when tool_search is not in the surface")
    func reachableNeedsItsDoor() {
        // Tool registered only at boot; a runtime flip must not narrow a turn with no way back.
        let defs = ["read_file", "exec_command", "generate_video"].map { fixtureDef($0, "d") }
        let withCuration = ToolSurfaceCuration.apply(defs, enabled: true, reachable: true)
        #expect(withCuration?.map(\.function.name) == ["read_file", "exec_command"])
        let withoutCuration = ToolSurfaceCuration.apply(defs, enabled: false, reachable: true)
        #expect(withoutCuration?.map(\.function.name) == defs.map(\.function.name))
        // The no-tools route survives every combination.
        #expect(ToolSurfaceCuration.apply(nil, enabled: true, reachable: true) == nil)
    }

    // MARK: - the search and the record

    private func makeRegistry(label: String) async -> ToolRegistry {
        let registry = ToolRegistry(log: Logger(label: label))
        try? await registry.register(fixtureEntry("generate_video", "Render a video clip"))
        try? await registry.register(fixtureEntry("capture_screenshot", "Capture the screen"))
        try? await registry.register(
            ToolSearchTool.toolEntry(registry: registry))
        return registry
    }

    @Test("a hit returns the tool verbatim and records it for the conversation that owns the call")
    func searchRecordsForConversation() async throws {
        let registry = await makeRegistry(label: "test.search.record")
        let key = "chat-search-record-\(UUID().uuidString.prefix(8))"
        let result = try await registry.call(
            "tool_search", arguments: "{\"query\":\"render a video clip\"}",
            conversationKey: key)
        #expect(
            result
                == """
                - generate_video: Render a video clip
                Recorded 1 match into this conversation's discovered set; a turn built from the registry declares them next turn.
                """)
        #expect(await ToolSurfaceDiscovery.shared.names(for: key) == ["generate_video"])

        // The recorded name leaves the search space: the next search says so by name.
        let again = try await registry.call(
            "tool_search", arguments: "{\"query\":\"video\"}",
            conversationKey: key, turnToken: "t2")
        #expect(again == "No undiscovered tool matches \"video\".")
        await ToolSurfaceDiscovery.shared.clear(key)
    }

    @Test("a call owned by no conversation records nothing and says exactly that")
    func searchWithoutConversation() async throws {
        let registry = await makeRegistry(label: "test.search.nokey")
        let result = try await registry.call(
            "tool_search", arguments: "{\"query\":\"capture the screen\"}")
        #expect(
            result
                == """
                - capture_screenshot: Capture the screen
                Nothing recorded: this call is owned by no conversation, so no discovered set exists to extend.
                """)
        #expect(await ToolSurfaceDiscovery.shared.names(for: nil).isEmpty)
    }

    @Test("the limit is the limit, ties come back name-ascending, and the record follows the page")
    func limitAndPage() async throws {
        let registry = ToolRegistry(log: Logger(label: "test.search.limit"))
        for name in ["delta_thing", "alpha_thing", "gamma_thing", "beta_thing"] {
            try? await registry.register(fixtureEntry(name, "does a thing"))
        }
        try? await registry.register(ToolSearchTool.toolEntry(registry: registry))
        let key = "chat-search-limit-\(UUID().uuidString.prefix(8))"
        let result = try await registry.call(
            "tool_search", arguments: "{\"query\":\"thing\",\"limit\":2}",
            conversationKey: key)
        // Equal scores, so the page is alpha and beta, and only the page is recorded.
        #expect(
            result
                == """
                - alpha_thing: does a thing
                - beta_thing: does a thing
                Recorded 2 matches into this conversation's discovered set; a turn built from the registry declares them next turn.
                """)
        #expect(await ToolSurfaceDiscovery.shared.names(for: key) == ["alpha_thing", "beta_thing"])
        await ToolSurfaceDiscovery.shared.clear(key)
    }

    // MARK: - the discovered store's own bounds

    @Test("the store keeps the newest conversations and forgets the oldest past the cap")
    func storeEviction() async {
        let store = ToolSurfaceDiscovery()
        for index in 0 ..< (ToolSurfaceDiscovery.maxConversations + 8) {
            await store.record(["n\(index)"], for: "conv-\(index)")
        }
        #expect(await store.names(for: "conv-0").isEmpty, "the oldest conversation is gone")
        #expect(
            await store.names(for: "conv-\(ToolSurfaceDiscovery.maxConversations + 7)")
                == ["n\(ToolSurfaceDiscovery.maxConversations + 7)"])
        // A second search unions; a clear removes the conversation whole.
        await store.record(["second"], for: "conv-\(ToolSurfaceDiscovery.maxConversations + 7)")
        #expect(
            await store.names(for: "conv-\(ToolSurfaceDiscovery.maxConversations + 7)")
                == ["n\(ToolSurfaceDiscovery.maxConversations + 7)", "second"])
        await store.clear("conv-\(ToolSurfaceDiscovery.maxConversations + 7)")
        #expect(
            await store.names(for: "conv-\(ToolSurfaceDiscovery.maxConversations + 7)").isEmpty)
    }

    // MARK: - the wiring, scanned with its own floors

    private static func source(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    private static func count(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).count
    }

    /// The flag is read exactly where the surface is built or registered: boot once, each
    /// lane-building seam once. A lane that starts narrowing without the flag, or a third
    /// reader, reddens here. Floors run first so a rename cannot pass vacuously.
    @Test("the flag has one boot seat and one seat per registry-building lane")
    func flagHasOneSeatPerLane() throws {
        let app = try Self.source("Sources/ocoreai/App.swift")
        let gui = try Self.source("Sources/ocoreai/UI/ViewModels/ChatViewModel.swift")
        let acp = try Self.source("Sources/ocoreai/ACP/ACPAgent.swift")
        // Floors: the seams exist before anything counts.
        #expect(app.contains("await bootstrapBuiltInTools("))
        #expect(gui.contains("ToolSurfaceCuration.apply("))
        #expect(acp.contains("ToolSurfaceCuration.apply("))
        #expect(
            try Self.count(#"SettingsStore\.shared\.toolSurfaceReachableEnabled"#, in: app) == 1)
        #expect(
            try Self.count(#"SettingsStore\.shared\.toolSurfaceReachableEnabled"#, in: gui) == 1)
        #expect(
            try Self.count(#"SettingsStore\.shared\.toolSurfaceReachableEnabled"#, in: acp) == 1)
        // Registration lives in exactly one place.
        let boot = try Self.source("Sources/ocoreai/Tools/BuiltInTools.swift")
        #expect(
            try Self.count(#"ToolSearchTool\.toolEntry\("#, in: boot) == 1,
            "one registration seat, and it is behind the boot flag")
    }
}
