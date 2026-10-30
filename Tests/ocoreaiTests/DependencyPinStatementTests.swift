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

    // MARK: - What the manifest claims about the code it pins

    /// Direct MLX surface as the code expresses it. Measured 10-20: the manifest's own
    /// consumer-impact audit said "only these two calls" (`Stream.gpu.synchronize`,
    /// `result.eval`) while `Sources` reaches MLX at 10 sites across 5 APIs — `asArray` is
    /// called 4× and `MLXArray` is constructed and stored in the embedding path. The
    /// under-report is not pedantry: 0.32.3→main carries #486 ("Fix asArray crash on
    /// zero-size arrays"), an API the audit did not know we used.
    private static let surfacePattern =
        #"asArray\(|\.eval\(|Stream\.gpu\.synchronize\(|MLXArray\.zeros\(|MLXArray\(|: MLXArray"#

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        struct NoRoot: Error, CustomStringConvertible {
            var description: String { "no package root above \(#filePath)" }
        }
        throw NoRoot()
    }

    private static func swiftFiles(in root: URL) -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        else {
            return []
        }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    private static func apiLabel(_ matched: String) -> String {
        if matched.contains("Stream.gpu.synchronize") { return "Stream.gpu.synchronize" }
        if matched.contains("MLXArray.zeros") { return "MLXArray.zeros" }
        if matched.hasPrefix(": MLXArray") { return "MLXArray-typed" }
        if matched.contains("asArray") { return "asArray" }
        if matched.contains(".eval(") { return "eval" }
        if matched.contains("MLXArray(") { return "MLXArray(" }
        return "unclassified:\(matched)"
    }

    @Test(
        "the manifest's consumer audit is the set Sources actually reach — 10 sites / 5 APIs"
    )
    static func consumerSurfaceIsTheAuditedSet() throws {
        let root = try repoRoot()
        let manifest = try repoFile("Package.swift")
        let regex = try NSRegularExpression(pattern: surfacePattern)
        var sites: [String] = []
        var callApis: Set<String> = []
        var typeSites = 0

        for file in swiftFiles(in: root) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, rawLine) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }
                for hit in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(hit.range, in: line) else { continue }
                    sites.append("\(file.lastPathComponent):\(index + 1)")
                    let label = apiLabel(String(line[range]))
                    if label == "MLXArray-typed" {
                        typeSites += 1
                    } else {
                        callApis.insert(label)
                    }
                }
            }
        }

        // Premise floors: a scan that stopped matching would report a tidy empty surface,
        // which is how this repo's earlier grep-based gates passed vacuously.
        #expect(
            sites.count >= 8,
            "only \(sites.count) direct MLX site(s) found in Sources/ — the scan is not reading the tree (\(sites))"
        )
        #expect(
            callApis.count >= 5,
            "only \(callApis.count) distinct MLX API(s) found: \(callApis.sorted())"
        )

        var unnamed = callApis.filter { !manifest.contains($0) }.sorted()
        if typeSites > 0, !manifest.contains("MLXArray-typed") { unnamed.append("MLXArray-typed") }
        #expect(
            unnamed.isEmpty,
            "Sources/ reaches MLX through \(callApis.count) APIs but Package.swift's audit never names \(unnamed) — the consumer-impact list is not the surface"
        )
        #expect(
            manifest.contains("\(sites.count) sites")
                && manifest.contains("\(callApis.count) APIs"),
            "measured direct MLX surface is \(sites.count) sites / \(callApis.count) APIs (+\(typeSites) typed properties) while the manifest states a different size — re-run the audit, do not edit this assertion to match"
        )
    }

    /// Every lm checkout this host has, in the order a local run would prefer them.
    ///
    /// `.build/out/checkouts` is in the list because it exists on real hosts as an orphan of an
    /// older SwiftPM layout — a resolved tree of a *previous* pin that nothing refreshes. It is
    /// listed so it can be judged, never trusted: only `trustedLmCheckout` decides.
    static func lmCheckoutCandidates() -> [URL] {
        guard let root = try? repoRoot() else { return [] }
        var found: [URL] = []
        func add(_ url: URL) {
            if FileManager.default.fileExists(atPath: url.path),
                !found.contains(where: { $0.path == url.path })
            {
                found.append(url)
            }
        }
        for relative in [
            ".build-clt/checkouts/mlx-swift-lm/Package.swift",
            ".build/checkouts/mlx-swift-lm/Package.swift",
            ".build/out/checkouts/mlx-swift-lm/Package.swift",
        ] {
            add(root.appendingPathComponent(relative))
        }
        if let scratch = ProcessInfo.processInfo.environment["SWIFTPM_BUILD_DIR"] {
            add(
                URL(fileURLWithPath: scratch)
                    .appendingPathComponent("checkouts/mlx-swift-lm/Package.swift"))
        }
        // Xcode — the route `make test-ci` and CI take — resolves into DerivedData, not `.build`.
        // On a runner that is the only tree at the pinned revision, so a gate blind to it can
        // only ever answer "cannot verify".
        let derived = URL(
            fileURLWithPath: "\(NSHomeDirectory())"
                + "/Library/Developer/Xcode/DerivedData")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: derived, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            func modified(_ url: URL) -> Date {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
            for dir in entries.filter({ $0.lastPathComponent.hasPrefix("ocoreai-") }).sorted(by: {
                modified($0) > modified($1)
            }) {
                add(
                    dir.appendingPathComponent(
                        "SourcePackages/checkouts/mlx-swift-lm/Package.swift")
                )
            }
        }
        for base in [
            ProcessInfo.processInfo.environment["OCOREAI_REFS"],
            ProcessInfo.processInfo.environment["HOME"],
            NSHomeDirectory(),
        ].compactMap({ $0 }) {
            add(URL(fileURLWithPath: "\(base)/references/mlx-swift-lm/Package.swift"))
        }
        return found
    }

    /// The revision the repository *declares* — the authority a checkout is judged against, so
    /// the gate never infers its own premise from whichever tree happens to be on disk.
    static func declaredLmRevision() -> String? {
        guard let text = try? repoFile("Package.resolved"),
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pins = root["pins"] as? [[String: Any]]
        else { return nil }
        for pin in pins where (pin["identity"] as? String) == "mlx-swift-lm" {
            return (pin["state"] as? [String: Any])?["revision"] as? String
        }
        return nil
    }

    /// A checkout's HEAD as a full SHA, following a loose symbolic ref; nil when undecidable.
    static func checkoutRevision(_ manifest: URL) -> String? {
        let git = manifest.deletingLastPathComponent().appendingPathComponent(".git")
        guard
            let head = try? String(
                contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8
            )
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !head.isEmpty
        else { return nil }
        guard head.hasPrefix("ref: ") else { return head }
        let ref = head.dropFirst(5)
        guard
            let sha = try? String(
                contentsOf: git.appendingPathComponent(String(ref)), encoding: .utf8
            )
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !sha.isEmpty
        else { return nil }
        return sha
    }

    /// The one checkout that is the declared revision — or nil, which the caller must treat as
    /// "cannot verify", never as "no problem".
    ///
    /// A CI cache restores `.build/checkouts` with a prefix restore-key, so the day a pin moves
    /// the runner holds a resolved tree of the *previous* pin. Measured 10-30 on the 0.33.0 bump:
    /// this gate read that stale tree, saw a floor of 0.32.3, and reported a contradiction that
    /// did not exist in the code it had just linked.
    static func trustedLmCheckout(
        _ candidates: [URL], declared: String?, revisionOf: (URL) -> String?
    ) -> URL? {
        guard let declared, !declared.isEmpty else { return candidates.first }
        return candidates.first { url in
            guard let revision = revisionOf(url) else { return false }
            return revision.hasPrefix(declared) || declared.hasPrefix(revision)
        }
    }

    @Test(
        "this pin satisfies lm's transitive floor, and the manifest names that floor as it now reads",
        .enabled(if: !lmCheckoutCandidates().isEmpty)
    )
    static func pinSatisfiesLmsTransitiveFloor() throws {
        let candidates = lmCheckoutCandidates()
        let declared = declaredLmRevision()
        let found =
            candidates
            .map { "\($0.deletingLastPathComponent().path)@\(checkoutRevision($0) ?? "unknown")" }
            .joined(separator: ", ")
        guard
            let lmManifest = trustedLmCheckout(
                candidates, declared: declared, revisionOf: checkoutRevision(_:)),
            let lmText = try? String(contentsOf: lmManifest, encoding: .utf8)
        else {
            let stated: String = declared ?? "unparsed"
            let why =
                "no mlx-swift-lm checkout at the revision Package.resolved declares ("
                + stated + ") — found [" + found + "] — reading a tree of another revision "
                + "would state a floor the linked code never compiled"
            Issue.record(Comment(rawValue: why))
            return
        }
        let manifest = try repoFile("Package.swift")
        guard
            let exact = manifestConstraint(
                manifest, packageURL: "ml-explore/mlx-swift.git", keyword: "exact")
        else {
            Issue.record(
                "no `exact:` constraint for ml-explore/mlx-swift.git — the pin moved shape, this gate needs re-reading"
            )
            return
        }
        let floorPattern =
            #"ml-explore/mlx-swift"\s*,\s*\.upToNextMinor\(from:\s*"([0-9]+\.[0-9]+\.[0-9]+)"\)"#
        // A `try?` here would fold "this pattern is broken" into "lm changed its constraint",
        // and the two need different answers: one is a bug in this gate.
        let floorRegex: NSRegularExpression
        do {
            floorRegex = try NSRegularExpression(pattern: floorPattern)
        } catch {
            Issue.record(
                "the lm-floor pattern is not a valid regex — that is this gate's bug, not lm's: \(error)"
            )
            return
        }
        guard
            let hit = floorRegex.firstMatch(
                in: lmText, range: NSRange(lmText.startIndex..., in: lmText)),
            let range = Range(hit.range(at: 1), in: lmText)
        else {
            Issue.record(
                "lm's mlx-swift constraint is not `.upToNextMinor(from:)` at \(lmManifest.lastPathComponent) — read it and update this gate, do not let it pass silently"
            )
            return
        }
        let floor = String(lmText[range])

        /// `x.y.z` → one comparable integer, so the gate does not lean on sequence operators.
        func versionKey(_ version: String) -> Int? {
            let numbers = version.split(separator: ".").compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            return numbers[0] * 1_000_000 + numbers[1] * 1_000 + numbers[2]
        }
        func minorLine(_ version: String) -> String? {
            let numbers = version.split(separator: ".").compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            return "\(numbers[0]).\(numbers[1])"
        }
        guard let pinKey = versionKey(exact), let floorKey = versionKey(floor) else {
            Issue.record(
                "pin \(exact) or lm floor \(floor) is not x.y.z — not semver, cannot compare")
            return
        }
        #expect(
            pinKey >= floorKey && minorLine(exact) == minorLine(floor),
            "this package pins mlx-swift \(exact) while mlx-swift-lm (at the resolved revision) requires .upToNextMinor(from: \(floor)) — resolution would fail or the pin is below the floor lm sets"
        )
        // And the prose that justifies the tag has to carry lm's current floor, not the one
        // that was true when the sentence was written (#646 raised it to 0.32.2; at our
        // pinned lm it reads 0.32.3).
        #expect(
            manifest.contains(".upToNextMinor(from: \(floor))")
                || manifest.contains(".upToNextMinor(from: \"\(floor)\")"),
            "lm's floor is \(floor) but Package.swift never states it — the sentence that explains the pin still describes an older contract"
        )
    }

    @Test("a checkout that is not the declared revision is never read for the floor")
    static func staleCheckoutIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("lmpin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        func checkout(named name: String, head: String, symbolicRef: String?) -> URL {
            let dir = base.appendingPathComponent(name)
            let git = dir.appendingPathComponent(".git")
            let headDir = symbolicRef == nil ? git : git.appendingPathComponent("refs/heads")
            try? FileManager.default.createDirectory(
                at: headDir, withIntermediateDirectories: true)
            try? head.write(
                to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
            if let symbolicRef {
                try? symbolicRef.write(
                    to: git.appendingPathComponent("refs/heads/main"), atomically: true,
                    encoding: .utf8)
            }
            let manifest = dir.appendingPathComponent("Package.swift")
            try? "// placeholder".write(to: manifest, atomically: true, encoding: .utf8)
            return manifest
        }

        let declared = "f5b0677f6b52b81d068871611cfcb82d1e7a0005"
        let stale = checkout(
            named: "stale", head: "991266ad300f47a3b9f21e62ff5bdb679215e758", symbolicRef: nil)
        let matching = checkout(named: "matching", head: declared, symbolicRef: nil)
        let mirror = checkout(
            named: "mirror", head: "ref: refs/heads/main", symbolicRef: declared)

        // The declared tree wins even when a resolved tree of the previous pin is listed first —
        // that is exactly the CI shape (a cache restore keyed by prefix).
        #expect(
            trustedLmCheckout(
                [stale, matching], declared: declared, revisionOf: checkoutRevision(_:))?
                .deletingLastPathComponent().lastPathComponent == "matching")
        // Stale-only is "cannot verify", never "no problem".
        #expect(
            trustedLmCheckout([stale], declared: declared, revisionOf: checkoutRevision(_:)) == nil)
        // A mirror on a branch is judged by where that branch points, not by existing.
        #expect(
            trustedLmCheckout([mirror], declared: declared, revisionOf: checkoutRevision(_:))?
                .deletingLastPathComponent().lastPathComponent == "mirror")
        // Premise floor: if the fixtures are not readable, every expectation above is empty.
        #expect(
            checkoutRevision(stale) == "991266ad300f47a3b9f21e62ff5bdb679215e758",
            "the fixture checkout is unreadable — this test proves nothing")
    }

    @Test("the drift instrument watches every pinned upstream, and judges mlx-swift by tags")
    static func driftScriptCoversBothPinnedUpstreams() throws {
        let script = try repoFile("scripts/upstream-drift.sh")
        // Premise floor: the three HEAD axes plus the tag axis must all be present, or a
        // rewritten script could report "clean" having watched nothing.
        let axes = ["mlx-swift-lm", "coreai-models", "codex", "mlx-swift"]
            .filter { script.contains($0) }
        #expect(
            axes.count == 4,
            "scripts/upstream-drift.sh covers \(axes.count)/4 upstream axes (\(axes)) — a dependency with no axis is unmonitored drift"
        )
        #expect(
            script.contains("MLX_REPO=\"ml-explore/mlx-swift\""),
            "mlx-swift has no axis entry in scripts/upstream-drift.sh"
        )
        #expect(
            script.contains("ls-remote --tags") && script.contains("sort -V"),
            "the mlx-swift axis no longer judges releases by tag — `exact:` pins drift against *tags*, not against main's HEAD"
        )
        #expect(
            script.contains("Package.resolved"),
            "the axis reads its pin from somewhere other than Package.resolved — a hand-copied version is a second truth"
        )
    }

    /// `make drift` promises 0 / 10 / 1 and the Makefile says so out loud. Measured 10-29 it
    /// returned **141**: every window truncation was `producer | head -N`, and once a window is
    /// bigger than a pipe buffer (codex, +366 commit subjects) `head` closes the read end, the
    /// writer takes SIGPIPE and `set -o pipefail` aborts the script mid-report — 47 of 78 lines
    /// printed, so the reader lost the largest window, the whole tag axis *and* the verdict line.
    ///
    /// Two halves on purpose: the idiom is banned in the script, and the mechanism is re-run here
    /// so the lock stays explainable. If a future `head` stops closing the pipe early, the second
    /// half goes red first and tells us the ban is no longer priced by a red.
    @Test("the drift instrument's exit code survives a window larger than a pipe buffer")
    static func driftTruncationDoesNotDieOfSigpipe() throws {
        let lines = try repoFile("scripts/upstream-drift.sh")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = lines.filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") }
        #expect(
            code.count >= 250,
            "only \(code.count) non-comment lines read — a scan that reads nothing reports a clean script"
        )
        let pipeHead = code.filter { $0.contains("| head") || $0.contains("|head") }
        #expect(
            pipeHead.isEmpty,
            "scripts/upstream-drift.sh truncates with `| head -N` on \(pipeHead.count) line(s): past a pipe buffer the writer gets SIGPIPE and pipefail exits 141, so the exit code a caller acts on never arrives — truncate with `sed -n '1,Np'`, which drains the pipe"
        )

        // The fixed form must still be there, not merely "no head": a rewrite to `awk … exit`
        // or `sed 'Nq'` closes the pipe too and reads as a pass above.
        #expect(
            lines.contains { $0.contains("sed -n '1,50p'") }
                && lines.contains { $0.contains("sed -n '1,14s/") }
                && lines.contains { $0.contains("sed -n '1p'") },
            "no draining truncation left in scripts/upstream-drift.sh — the fix was reverted, not just reworded"
        )

        // Mechanism, re-measured rather than asserted by comment: one 800 KiB producer, two readers.
        let producer =
            "seq 1 4000 | sed 's/$/ x_pad_pad_pad_pad_pad_pad_pad_pad_pad_pad_pad_pad_pad_x/'"
        let early = try runBash(
            """
            set -euo pipefail
            w=$( { \(producer); } | head -50 )
            echo "lines=$(printf '%s\n' "$w" | grep -c .)"
            echo SURVIVED
            """)
        #expect(
            early.status != 0 && !early.out.contains("SURVIVED"),
            "the pipe-death premise no longer reproduces: `head -50` on an 800 KiB producer exited \(early.status) and printed the tail (\(early.out.prefix(60))) — the `| head` ban above is no longer priced by a measured red, so delete it or re-derive it"
        )

        let drained = try runBash(
            """
            set -euo pipefail
            w=$( { \(producer); } | sed -n '1,50p' )
            echo "lines=$(printf '%s\n' "$w" | grep -c .)"
            echo SURVIVED
            """)
        #expect(
            drained.status == 0 && drained.out.contains("lines=50")
                && drained.out.contains("SURVIVED"),
            "the draining truncation is not intact: exit \(drained.status), output \(drained.out.prefix(60)) — a window of >64 KiB would still abort the drift report"
        )
    }

    /// One bash run, exit code and stdout both returned — the pair is the contract here, since the
    /// 10-29 failure was a wrong *exit code* on an otherwise plausible-looking report.
    private static func runBash(_ script: String) throws -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        // Drain before waiting: a 800 KiB producer deadlocks against a pipe nobody reads.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }
}
