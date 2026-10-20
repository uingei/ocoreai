// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! DependencyPinStatementTests.swift — the manifest's own sentences about its pins must say
//! what the pins say.
//!
//! `Package.swift` is the contract (AGENTS.md § Upstream Audit Dependencies: "the pin in
//! `Package.swift` is the contract"), and the prose above the pins is the only place a human
//! learns *why* a version is pinned. It had no reader. Measured 10-20: the comment over the
//! mlx-swift pin read "pin to the 0.32.2 tag (main HEAD 2b5e877)" while the pin itself said
//! `exact: "0.32.3"` — the bump landed in `0401256` with its reason in CHANGELOG, and the
//! sentence that states the pin kept stating the old one. Same pass found its two consumer
//! cites 214 and 124 lines off. Every version check in this repo compares *names*
//! (`ThirdPartyNoticesTests`), so both drifted through CI green.
//!
//! So the manifest is now read three ways: prose ↔ pin (`exact:` / `revision:`), pin ↔
//! `Package.resolved`, and its file:line cites by `make anchor-check` (which gained
//! `Package.swift` in its scan set). Each assertion floors its own premises, because a regex
//! that stopped matching would otherwise report a clean bill of health for a file it read
//! nothing of.

import Foundation
import Testing

@testable import ocoreai

@Suite("Package.swift says what it pins — prose, pin, and resolution in one voice")
struct DependencyPinStatementTests {

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

    private static func resolvedPins() throws -> [String: [String: String]] {
        let text = try repoFile("Package.resolved")
        guard let data = text.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pins = root["pins"] as? [[String: Any]]
        else {
            struct Unreadable: Error, CustomStringConvertible {
                var description: String { "Package.resolved has no parsable `pins` array" }
            }
            throw Unreadable()
        }
        var byIdentity: [String: [String: String]] = [:]
        for pin in pins {
            guard let identity = pin["identity"] as? String else { continue }
            var state: [String: String] = [:]
            // v3 nests the pin under `state`; older formats keep it flat. Read both, so a
            // format change cannot make this gate "pass" by reading nothing.
            let source = (pin["state"] as? [String: Any]) ?? pin
            for key in ["revision", "version", "branch"] {
                if let value = source[key] as? String { state[key] = value }
            }
            byIdentity[identity] = state
        }
        return byIdentity
    }

    /// The constraint value declared for a repo: the first `keyword: "…"` after that repo's
    /// URL. The prose sits *above* the declaration and never writes `exact: "` / `revision: "`,
    /// so a comment cannot satisfy this by quoting a version — it has to move to read the pin.
    private static func manifestConstraint(_ manifest: String, packageURL: String, keyword: String)
        -> String?
    {
        guard let urlRange = manifest.range(of: packageURL) else { return nil }
        let tail = manifest[urlRange.upperBound...]
        guard let keywordRange = tail.range(of: "\(keyword): \"") else { return nil }
        let after = tail[keywordRange.upperBound...]
        guard let quote = after.firstIndex(of: "\"") else { return nil }
        return String(tail[keywordRange.upperBound ..< quote])
    }

    @Test("the manifest declares pins, and the resolution exists to be compared with")
    static func premisesArePresent() throws {
        let manifest = try repoFile("Package.swift")
        #expect(
            manifest.count > 3_000, "Package.swift read looks truncated (\(manifest.count) chars)")
        #expect(
            manifest.components(separatedBy: ".package(").count - 1 >= 8,
            "only \(manifest.components(separatedBy: ".package(").count - 1) dependency declarations found — the scan is not reading the manifest"
        )
        let pins = try resolvedPins()
        #expect(
            pins.count >= 8, "Package.resolved has \(pins.count) pins — resolution read is broken")
        for identity in ["mlx-swift", "mlx-swift-lm"] {
            #expect(
                pins[identity]?["revision"] != nil,
                "\(identity) resolved without a revision — a gate that reads nothing cannot compare anything"
            )
        }
    }

    @Test("the sentence that states the mlx-swift pin names the version actually pinned")
    static func proseMatchesPin() throws {
        let manifest = try repoFile("Package.swift")
        guard
            let pinned = manifestConstraint(
                manifest, packageURL: "ml-explore/mlx-swift.git", keyword: "exact")
        else {
            Issue.record(
                "no `exact:` constraint for ml-explore/mlx-swift.git — the pin moved shape, this gate needs re-reading"
            )
            return
        }
        // Prose forms this repo uses to state a pin: "pinned exact X" and "resolved revision Y".
        let statements = [
            ("pinned exact (\\d+\\.\\d+\\.\\d+)", pinned),
            (
                "resolved revision ([0-9a-f]{7,40})",
                try resolvedPins()["mlx-swift"]?["revision"].map { String($0.prefix(9)) } ?? ""
            ),
        ]
        for (pattern, expected) in statements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(
                in: manifest, range: NSRange(manifest.startIndex..., in: manifest))
            #expect(
                !matches.isEmpty,
                "the manifest no longer states \(pattern) — the prose that explains this pin was deleted or rewritten out of the gate's reach"
            )
            for match in matches {
                guard let range = Range(match.range(at: 1), in: manifest) else { continue }
                let said = String(manifest[range])
                #expect(
                    expected.hasPrefix(said) || said.hasPrefix(expected),
                    "Package.swift prose says \(said) while the pin/resolution says \(expected) — a statement about the contract that contradicts it"
                )
            }
        }
        // The exact regression: a phrase naming some *other* tag as the pin.
        if let regex = try? NSRegularExpression(pattern: "pin to the (\\d+\\.\\d+\\.\\d+) tag") {
            let matches = regex.matches(
                in: manifest, range: NSRange(manifest.startIndex..., in: manifest))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: manifest) else { continue }
                #expect(
                    String(manifest[range]) == pinned,
                    "\"pin to the \(manifest[range]) tag\" while the pin is exact \"\(pinned)\" — the 0.32.2/0.32.3 drift this gate was written for"
                )
            }
        }
    }

    @Test("both upstream pins agree with what the resolver recorded")
    static func pinsAgreeWithResolved() throws {
        let manifest = try repoFile("Package.swift")
        let pins = try resolvedPins()

        let mlxVersion = manifestConstraint(
            manifest, packageURL: "ml-explore/mlx-swift.git", keyword: "exact")

        guard let mlx = pins["mlx-swift"], let mlxRevision = mlx["revision"],
            let mlxResolvedVersion = mlx["version"]
        else {
            Issue.record("mlx-swift is absent from Package.resolved: \(pins.keys.sorted())")
            return
        }
        #expect(
            mlxRevision.count >= 7 && mlxResolvedVersion.count >= 5,
            "mlx-swift resolved to version \(mlxResolvedVersion) revision \(mlxRevision) — neither is a real value"
        )

        guard let lm = pins["mlx-swift-lm"], let lmRevision = lm["revision"] else {
            Issue.record("mlx-swift-lm is absent from Package.resolved: \(pins.keys.sorted())")
            return
        }
        #expect(
            lmRevision.count >= 7,
            "mlx-swift-lm resolved revision \(lmRevision) is not a real revision")
        if let mlxVersion {
            #expect(
                mlxResolvedVersion == mlxVersion,
                "resolved mlx-swift \(mlxResolvedVersion) != manifest exact \"\(mlxVersion)\"")
        }
        guard
            let manifestLmRevision = manifestConstraint(
                manifest, packageURL: "ml-explore/mlx-swift-lm.git", keyword: "revision")
        else {
            Issue.record(
                "no `revision:` constraint for ml-explore/mlx-swift-lm.git — the pin moved shape, this gate needs re-reading"
            )
            return
        }
        #expect(
            lmRevision.hasPrefix(manifestLmRevision),
            "resolved mlx-swift-lm \(lmRevision) does not start with the manifest revision \"\(manifestLmRevision)\""
        )

        // SwiftPM records this revision pin together with the ref it resolved from. That ref
        // has to be the same fixed point the manifest names, or the "fixed point" moves.
        #expect(
            lm["branch"] == nil || lm["branch"] == manifestLmRevision,
            "mlx-swift-lm resolved by branch \(lm["branch"] ?? "?") while the manifest pins revision \"\(manifestLmRevision)\" — the pin is no longer the fixed point it claims to be"
        )
    }

    @Test("the manifest's own file:line cites are anchored, not hand-counted")
    static func consumerCitesAreAnchored() throws {
        let manifest = try repoFile("Package.swift")
        let citePattern = try NSRegularExpression(pattern: #"\.swift:\d{3,}"#)
        var cites = 0
        var unanchored: [String] = []
        for rawLine in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let hits = citePattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard !hits.isEmpty else { continue }
            cites += hits.count
            if !line.contains("// anchor:.") {
                unanchored.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        // Premise floor: a manifest with no cites at all would pass "all cites are anchored".
        #expect(
            cites >= 2,
            "only \(cites) file:line cite(s) in Package.swift — the audit trail this gate protects is gone"
        )
        #expect(
            unanchored.isEmpty,
            "\(unanchored.count) hand-counted cite(s) in Package.swift, which no gate re-reads: \(unanchored)"
        )
    }
}
