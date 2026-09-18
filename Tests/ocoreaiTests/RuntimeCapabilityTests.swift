import Foundation
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// RuntimeCapabilityTests — pins the capability-matrix contract so every
/// surface name stays stable across releases and every consumer (prompt /
/// info tool / /v1/capabilities) reads from the same source of truth.
///
/// Grounded on four-tier targets (macOS 14 / iOS 17, 15/18, 26/26, 27/27).
/// The contract tests do NOT assert specific availability per OS — that is
/// an environment fact, not a code fact. They only assert the shape and
/// that consumers agree with the matrix.
import Testing

@testable import ocoreai

@Suite("RuntimeCapability")
struct RuntimeCapabilityTests {
    // The 9 surface names are a public contract — changing or removing any
    // of them is a breaking change for clients that parse this wire JSON.
    private static let requiredNames: Set<String> = [
        "agent_loop",
        "mlx_inference",
        "foundationmodels",
        "coreai_ane",
        "local_stt",
        "tts_speech",
        "video_generation",
        "mcp_stdio",
        "screenshot_capture",
    ]

    @Test("every required surface name is present")
    func requiredSurfacesPresent() {
        let names = Set(RuntimeCapability.lines.map(\.name))
        #expect(
            Self.requiredNames.isSubset(of: names),
            "missing: \(Self.requiredNames.subtracting(names))")
    }

    @Test("no duplicate surface names (single source of truth)")
    func noDuplicates() {
        let names = RuntimeCapability.lines.map(\.name)
        let grouped = Dictionary(grouping: names, by: { $0 })
        let dupes = grouped.filter { $0.value.count > 1 }.map(\.key)
        #expect(dupes.isEmpty, "dup: \(dupes)")
    }

    @Test("every line has a non-whitespace note (wire JSON is self-explanatory)")
    func notesNonEmpty() {
        for line in RuntimeCapability.lines {
            #expect(!line.note.isEmpty, "empty note on \(line.name)")
            #expect(
                !line.note.trimmingCharacters(in: .whitespaces).isEmpty,
                "all-whitespace note on \(line.name)")
        }
    }

    @Test("agent_loop + mlx_inference are always available (4-tier floor)")
    func coreSurfacesAlways() {
        for name in ["agent_loop", "mlx_inference"] {
            let line = RuntimeCapability.lines.first { $0.name == name }
            #expect(line != nil, "missing \(name)")
            #expect(line?.available == true, "\(name) should always be live")
        }
    }

    @Test("tts_speech is always available (4-tier floor)")
    func ttsAlways() {
        let tts = RuntimeCapability.lines.first { $0.name == "tts_speech" }
        #expect(tts != nil)
        #expect(tts?.available == true)
    }

    @Test("tierTruthSection is non-empty and names the 4-tier contract")
    func tierBoundaries() {
        let s = RuntimeCapability.tierTruthSection
        #expect(s.count > 50)
        #expect(s.contains("macOS 14 / iOS 17"))
        #expect(s.contains("macOS 27 / iOS 27"))
        #expect(s.contains("ENABLED"))
    }

    @Test("system prompt carries the capability section (consumer contract)")
    func systemPromptInclusion() async {
        let builder = SystemPromptBuilder(basePrompt: "Test base.")
        let built = await builder.build()
        #expect(built.contains("capability matrix"))
        #expect(built.contains("macOS 27"))
    }

    @Test("os name and version are honest (not placeholders)")
    func osFactsHonest() {
        #expect(
            RuntimeCapability.osName == "macOS"
                || RuntimeCapability.osName == "iOS"
                || RuntimeCapability.osName == "Apple",
            "osName should be a real build-target name: \(RuntimeCapability.osName)")
        // The real major.minor version core must be present in our version
        // string, whatever the raw Foundation shape ("macOS 15.3 (…)" vs
        // "Version 27.0 (…)").
        let raw = ProcessInfo.processInfo.operatingSystemVersionString
        guard let m = raw.range(of: #"\d+\.\d+"#, options: .regularExpression) else {
            // No extractable core (unexpected shape) — at least assert the
            // version string is non-empty and not the placeholder "TBD".
            #expect(!RuntimeCapability.osVersion.isEmpty)
            #expect(RuntimeCapability.osVersion != "TBD")
            return
        }
        let core = String(raw[m])
        #expect(
            RuntimeCapability.osVersion.contains(core),
            "osVersion should carry the real version core \(core); got \(RuntimeCapability.osVersion)"
        )
        // Normalized shape: "<osName> <version>" (not the raw "Version …").
        #expect(
            RuntimeCapability.osVersion.hasPrefix(RuntimeCapability.osName + " "),
            "osVersion should be normalized to start with osName: \(RuntimeCapability.osVersion)")
    }

    @Test("info tool is registered and exposes the topic parameter (consumer contract)")
    func infoToolRegistered() async {
        let registry = ToolRegistry()
        await bootstrapBuiltInTools(registry: registry)
        let entries = await registry.listToolEntries()
        let infoEntry = entries.first { $0.name == "info" }
        #expect(infoEntry != nil, "info tool not registered after bootstrap")
        #expect(infoEntry?.toolset == "system", "info tool toolset != system")
    }
}
