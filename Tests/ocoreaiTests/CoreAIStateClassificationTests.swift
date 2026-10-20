// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! CoreAIStateClassificationTests.swift — pin the three shapes that keep ocoreai out of the
//! failure modes coreai-models fixed in `82c3488` (#354, 10-19).
//!
//! Upstream fixed three things at once: a static-shape KV cache was classified sliding because
//! its name merely contained "cache", which switched the sequential engine to compact
//! position_ids so every write landed at offset 0 (silent garbage, no error); the pipelined
//! constrained-encode path built its async state views without `additionalStates`, so bundles
//! with more than two states died on the first constrained encode; and a sliding ring wrote
//! before it attended, destroying Q−1 positions of a prefill chunk's own history.
//!
//! ocoreai's derivation does not carry those shapes — but nothing said so. Every file involved
//! is `#if canImport(CoreAI)` + `@available(macOS 27, *)`, so none of it compiles on the CLT
//! SDK and none of it can be exercised here: a static gate is the only instrument available on
//! this host, and it is textual on purpose, so it runs whether or not the SDK has CoreAI. Each
//! assertion floors its own scan, because a regex that stopped matching would otherwise certify
//! a decision it never read (AGENTS.md invariant 1).

import Foundation
import Testing

@testable import ocoreai

@Suite("CoreAI derivation keeps the shapes that avoid upstream's KV-state failures")
struct CoreAIStateClassificationTests {

    private static func repoFile(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        struct Missing: Error, CustomStringConvertible {
            var path: String
            var description: String { "no repo file at \(path)" }
        }
        throw Missing(path: relative)
    }

    private static func engineSwiftFiles() throws -> [(path: String, text: String)] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path)
            {
                break
            }
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { break }
            root = parent
        }
        let sources = root.appendingPathComponent("Sources/ocoreai/Engine")
        guard
            let walker = FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: nil)
        else {
            return []
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((String(url.path.dropFirst(root.path.count + 1)), text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    @Test(
        "async state views are built at one seam, and that seam binds additionalStates")
    static func stateViewSeamBindsAdditionalStates() throws {
        let files = try engineSwiftFiles()
        // Premise floor: the scan must see the seam it is certifying.
        #expect(
            files.count >= 20,
            "only \(files.count) files found under Sources/ocoreai/Engine — the scan is not reading the tree"
        )

        let containerPattern = try NSRegularExpression(
            pattern: #"var\s+\w*[Ss]tates\w*\s*=\s*InferenceFunction\.AsyncMutableViews\(\)"#)
        var containers: [(file: String, line: Int)] = []
        for (path, text) in files {
            for (index, rawLine) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let line = String(rawLine)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if containerPattern.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line))
                    != nil
                {
                    containers.append((path, index + 1))
                }
            }
        }
        #expect(
            containers.count >= 2,
            "found \(containers.count) async state-view container(s) in Engine/ — expected at least the two in StateHandler+Encode.swift, so this scan has stopped seeing its own subject"
        )
        #expect(
            containers.allSatisfy { $0.file.hasSuffix("StateHandler+Encode.swift") },
            "async state views are constructed outside the encode seam: \(containers) — every new inline container is another chance to forget additionalStates, which is exactly upstream's #354 bug"
        )

        let encode = try repoFile("Sources/ocoreai/Engine/StateHandler+Encode.swift")
        let binds = encode.components(separatedBy: "additionalStates?.bind(into:").count - 1
        #expect(
            binds >= containers.count,
            "\(containers.count) state container(s) but only \(binds) additionalStates bind(s) in the seam — a container without a bind is the 'Missing state view' failure, silently reintroduced"
        )
    }

    @Test(
        "compact position ids stay off in the sequential and pipelined engines until a ring path exists"
    )
    static func compactPositionIdsStayDisabled() throws {
        let files = try engineSwiftFiles()
        // A decision is a call site that binds the flag. Parameter declarations (`: Bool`) are
        // not decisions; anything else that is not literally `false` — including a variable —
        // is, because that is how a ring path would sneak compact ids in without a review.
        let callPattern = try NSRegularExpression(pattern: #"useCompactPositionIds:\s*([\w.]+)"#)
        var decisions = 0
        var enabled: [String] = []
        var literals = 0
        for (path, text) in files {
            let isEngine =
                path.hasSuffix("CoreAIPipelinedEngine.swift")
                || path.hasSuffix("CoreAISequentialEngine.swift")
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                for hit in callPattern.matches(
                    in: line, range: NSRange(line.startIndex..., in: line))
                {
                    guard let arg = Range(hit.range(at: 1), in: line) else { continue }
                    let value = String(line[arg])
                    literals += 1
                    // Parameter declarations (`: Bool`) and a forward of the same parameter name
                    // inside InputLayout are plumbing. An engine's call is the decision.
                    if value == "Bool" || value == "useCompactPositionIds" { continue }
                    guard isEngine else { continue }
                    decisions += 1
                    if value != "false" { enabled.append("\(path): \(value)") }
                }
            }
        }
        #expect(
            literals >= 4,
            "only \(literals) `useCompactPositionIds:` mention(s) found — the scan no longer reads the plumbing and decisions it pins"
        )
        #expect(
            decisions >= 2,
            "only \(decisions) engine call site(s) bind the flag — expected the pipelined and sequential engines, so this gate has stopped reading its subject"
        )
        #expect(
            enabled.isEmpty,
            "compact position ids are enabled at \(enabled): the sliding-ring cache that has to exist before that is safe is still not in this tree (#202 pending), so compact ids would write every chunk at offset 0 — upstream's #354 corruption, verbatim"
        )
        #expect(
            enabled.isEmpty,
            "compact position ids are enabled at \(enabled): the sliding-ring cache that has to exist before that is safe is still not in this tree (#202 pending), so compact ids would write every chunk at offset 0 — upstream's #354 corruption, verbatim"
        )
    }

    @Test(
        "a bundle with no growing KV pair is refused by name, not run")
    static func missingGrowingKVRefusesLoudly() throws {
        let pipelined = try repoFile("Sources/ocoreai/Engine/CoreAIPipelinedEngine.swift")
        #expect(
            pipelined.contains("guard growingNames.count >= 2 else"),
            "the pipelined engine no longer refuses a bundle with <2 kvCache-classified states — without this guard a misclassified static-shape cache would run instead of naming itself"
        )
        #expect(
            pipelined.contains("Expected at least 2 growing KV cache states"),
            "the refusal no longer says what it wanted — a refusal the caller cannot read is not degradation"
        )
        // And the classification that feeds it must never call a static cache sliding by
        // accident: sliding comes from the name, and a static shape falls through to .fixed.
        let handler = try repoFile("Sources/ocoreai/Engine/StateHandler.swift")
        #expect(
            handler.contains("if lower.contains(\"sliding\")"),
            "state-kind inference no longer derives sliding from the name — upstream's #354 fix is that a static cache is sliding only when its name says so"
        )
    }
}
