// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// ToolSurfaceReachabilityTests. The pure half of the reachable tool surface: the tokenizer, the
// BM25 rank over deferred tools, the resident composition, and the compact listing. Everything here
// is an exact value because the ranking is a contract with the model: the same query must return
// the same list every run, or a turn's behaviour cannot be reproduced.
//
// The economics the file's header cites (23 997 B full / 4 302 B core / 9 060 B listing, measured
// 11-24 against a live GET /v1/tools) are restated here only as a byte *direction* on a fixture the
// test owns, never re-measured against the registry.
import Foundation
import Testing

@testable import ocoreai

private func def(name: String, description: String, properties: [String: String] = [:]) -> ToolDef {
    return ToolDef(
        function: FunctionDef(
            name: name, description: description,
            parameters: [
                "type": .wrap("object"),
                "properties": .wrap(
                    properties.mapValues { ["type": "string", "description": $0] as [String: Any] }),
            ]))
}

struct ToolSurfaceReachabilityTests {

    @Test("tokens split snake_case, camelCase and prose, drop stop words and single letters")
    func tokenizing() {
        #expect(
            ToolSurfaceReachability.tokens("read_file") == ["read", "file"])
        #expect(
            ToolSurfaceReachability.tokens("generateVideo") == ["generate", "video"])
        #expect(
            ToolSurfaceReachability.tokens("Take a screenshot of the UI") == [
                "take", "screenshot", "ui",
            ])
        #expect(ToolSurfaceReachability.tokens("aspect_ratio") == ["aspect", "ratio"])
    }

    @Test("the searchable document carries the schema's own words")
    func searchableDocument() {
        let tool = def(
            name: "generate_video", description: "Render a video clip",
            properties: ["aspect_ratio": "frame aspect ratio"])
        let text = ToolSurfaceReachability.searchableText(tool)
        #expect(text.contains("generate_video"))
        #expect(text.contains("Render a video clip"))
        // Parameter names and descriptions are what a small model's query matches on.
        #expect(text.contains("aspect ratio"))
        #expect(text.contains("frame aspect ratio"))
    }

    @Test("a query ranks the right tool first, and ranks deterministically by name on a tie")
    func ranking() {
        let defs = [
            def(
                name: "generate_video", description: "Render a video clip",
                properties: ["prompt": "text description", "aspect_ratio": "frame shape"]),
            def(
                name: "read_file", description: "Read a file from disk",
                properties: ["path": "file path"]),
            def(
                name: "capture_screenshot", description: "Capture the screen",
                properties: ["display": "which display"]),
        ]
        // Only generate_video's document holds these words, so it is the only match — first, and alone.
        let video = ToolSurfaceReachability.rank(query: "render a video clip", in: defs)
        #expect(video.map(\.name) == ["generate_video"])
        let screen = ToolSurfaceReachability.rank(query: "capture the screen display", in: defs)
        #expect(screen.first?.name == "capture_screenshot")
        // Scores are reproducible digit-for-digit, twice running.
        #expect(video == ToolSurfaceReachability.rank(query: "render a video clip", in: defs))
    }

    @Test("equal scores come back name-ascending, not in registry order")
    func tieBreakIsByName() {
        let defs = [
            def(name: "zeta_tool", description: "Capture the display"),
            def(name: "alpha_tool", description: "Capture the display"),
        ]
        let ranked = ToolSurfaceReachability.rank(query: "capture display", in: defs)
        #expect(ranked.map(\.name) == ["alpha_tool", "zeta_tool"])
        #expect(ranked[0].score == ranked[1].score)
        // Registry order is the inverse, so the order below can only come from the name tie-break.
        #expect(defs.map(\.function.name) == ["zeta_tool", "alpha_tool"])
    }

    @Test("already-declared tools are never returned, and the limit is the limit")
    func excludingAndLimiting() {
        let defs = (1 ... 12).map {
            def(name: "tool_\($0)", description: "does a thing number \($0)")
        }
        let all = ToolSurfaceReachability.rank(query: "thing", in: defs, limit: 3)
        #expect(all.count == 3)
        let names = Set(all.map(\.name))
        let skipped = ToolSurfaceReachability.rank(
            query: "thing", in: defs, excluding: names, limit: 3)
        #expect(Set(skipped.map(\.name)).isDisjoint(with: names))
        // A query with no stop-word-surviving tokens searches nothing and says so by returning none.
        #expect(ToolSurfaceReachability.rank(query: "the a of", in: defs).isEmpty)
    }

    @Test("resident surface is core plus discovered, in registry order, nothing dangling")
    func residentComposition() {
        let defs = [
            def(name: "read_file", description: "Read"),
            def(name: "generate_video", description: "Render"),
            def(name: "exec_command", description: "Run"),
        ]
        let surface = ToolSurfaceReachability.residentSurface(
            all: defs, core: ["read_file", "exec_command"], discovered: ["generate_video"])
        #expect(surface.map(\.function.name) == ["read_file", "generate_video", "exec_command"])
        // A discovered name the registry no longer has simply is not declared.
        let stale = ToolSurfaceReachability.residentSurface(
            all: defs, core: ["read_file"], discovered: ["gone_tool"])
        #expect(stale.map(\.function.name) == ["read_file"])
    }

    @Test("the listing names each deferred tool once, and costs one line per tool")
    func listing() {
        let defs = [
            def(name: "read_file", description: "Read a file"),
            def(name: "generate_video", description: "Render a\nvideo clip"),
        ]
        let listing = ToolSurfaceReachability.compactListing(
            all: defs, core: ["read_file"], discovered: [])
        // A newline inside a description would break the one-line-per-tool shape the byte claim rests on.
        #expect(listing == "- generate_video: Render a video clip")
        let withDiscovered = ToolSurfaceReachability.compactListing(
            all: defs, core: ["read_file"], discovered: ["generate_video"])
        #expect(withDiscovered.isEmpty)
    }

    @Test("listing beats schemas on bytes for the same tools, on this file's own fixture")
    func byteDirection() {
        let defs = (1 ... 10).map {
            def(
                name: "tool_number_\($0)",
                description: "A tool with a description long enough to be realistic in bytes",
                properties: ["first_argument": "what it touches", "second_argument": "how much"])
        }
        let full = defs.reduce(0) { total, tool in
            total + ((try? JSONEncoder().encode(tool).count) ?? 0)
        }
        let listing = ToolSurfaceReachability.compactListing(
            all: defs, core: [], discovered: []
        ).utf8.count
        #expect(listing > 0)
        #expect(listing < full / 2)
    }
}
