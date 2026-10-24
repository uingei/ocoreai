// EnvKeysDocumentationTests.swift
//
// Locks the env-var documentation surface (.env.example) against code drift.
//
// ocoreai reads 30 environment variables: 22 static `environment["KEY"]`
// literals + 8 read through a constant, an accessor, or an interpolated prefix
// (`HttpBridgePolicy.envVar`, `HF_ENDPOINT_MIRROR` via operatorEnvironment,
// and `\(...)HOST/PORT/BACKEND/...` in ConfigSystem.applyEnvOverrides).
// 10-21: `HF_TOKEN` / `MODELSCOPE_TOKEN` stopped being literals at their read sites —
// `Models/HubCredential.swift` names them once (`HubSource.envVar`) and reads them only
// through `precedence(source:stored:)`. Assertion 5 unions the accessor's own names rather
// than letting the floor drop: a key that moves behind an accessor must stay visible to the
// contract, not age out of it.
// Every count here is re-derived by set analysis, not remembered — a stale
// count in a doc comment is the drift this file was born from (22→23 found
// live: README said 22, expectedKeys held 23). 10-12: the native web_search
// path added OCRE_SEARCH_MODE / _ENGINES / _MAX_HITS / _DIRECT_TIMEOUT to
// Sources/, and this suite stayed green with all four absent from BOTH the
// contract and .env.example — a remembered key list cannot see code-side
// additions. Assertion 5 derives the literal key set from Sources/ and fails
// on any key the contract does not carry, so the list can no longer lag code.
//
// This test set pins the EXPECTED 30-key set as the single source of truth.
// Assertions 1-4 compare two declared lists (no re-derivation, which is itself
// drift-prone); assertion 5 adds one deliberately dumb derivation over Sources/
// so a declared list cannot silently omit a key the code reads. Asserts:
//   1. no phantom:   no `.env.example` key outside the expected set
//   2. no omission:  no expected key missing from `.env.example`
//   3. no stale row: every expected key is actually read in Sources/
//   4. no dupes:     `.env.example` has no repeated key
//   5. no blind spot: every env key Sources/ can produce — a literal `environment["KEY"]`
//      read, or a name declared by the accessor that reads on its behalf — is carried by the
//      contract; a key added in code cannot skip this file
//   6. no stale prose: the human-facing README says this same count, split the same way —
//      measured 10-24: both READMEs still claimed "23 (17 static + 6)" while the contract and
//      `.env.example` carried 27, drift nothing had read since the 10-12 key group landed
//
// ADD a new env var in code → add it to expectedKeys AND to .env.example;
// test 3 will fail until both are done.
import Foundation
import Testing

@testable import ocoreai

struct EnvKeysDocumentationTests {

    /// The 30 env-var keys ocoreai reads. This list IS the contract.
    private static let expectedKeys: [String] = [
        // Server
        "OCOREAI_HOST", "OCOREAI_PORT", "OCOREAI_ENABLE_HTTP",
        // Auth
        "OCOREAI_API_KEYS", "OCOREAI_ADMIN_KEYS",
        // Backend (ConfigSystem.applyEnvOverrides)
        "OCOREAI_BACKEND", "OCOREAI_MAX_SESSIONS",
        "OCOREAI_DEFAULT_MODEL", "OCOREAI_MEMORY_ENABLED",
        // Agent (统一审批 — 单源真值,跨 GUI / headless 两入口)
        "OCOREAI_APPROVAL_POLICY",
        // Model 存储 / 工作树
        "OCOREAI_MODELS_DIR", "OCOREAI_WORKTREE_ROOT", "OCOREAI_PROJECT_DIR",
        // HuggingFace
        "HF_TOKEN", "HF_ENDPOINT", "HF_ENDPOINT_MIRROR",
        // ModelScope
        "MODELSCOPE_TOKEN", "MODELSCOPE_ENDPOINT",
        // web_search — native direct SERP (the default path, needs no backend)
        "OCRE_SEARCH_MODE", "OCRE_SEARCH_ENGINES", "OCRE_SEARCH_MAX_HITS",
        "OCRE_SEARCH_DIRECT_TIMEOUT",
        // web_search / web_fetch (local ollama backend — opt-in via MODE)
        "OCRE_SEARCH_BASE_URL", "OCRE_SEARCH_MODEL", "OCRE_SEARCH_TIMEOUT",
        "OCRE_SEARCH_PROBE_TIMEOUT", "OCRE_FETCH_TIMEOUT",
        // degeneration probe (diagnostics — all three default off, healthy turns pay nothing)
        "OCOREAI_MARGIN_PROBE", "OCOREAI_MARGIN_NO_KV", "OCOREAI_MARGIN_DUMP",
    ]

    /// Repo root = nearest ancestor of cwd that contains `.env.example`.
    private static var repoRoot: String {
        var dir = FileManager.default.currentDirectoryPath
        while true {
            if FileManager.default.fileExists(atPath: dir + "/.env.example") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return FileManager.default.currentDirectoryPath
    }

    private static func docKeys() -> Set<String> {
        guard
            let content = try? String(
                contentsOfFile: Self.repoRoot + "/.env.example",
                encoding: .utf8)
        else { return [] }
        var keys = Set<String>()
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                let eq = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                keys.insert(key)
            }
        }
        return keys
    }

    private static func sourceBlob() -> String {
        let sources = Self.repoRoot + "/Sources"
        var blob = ""
        guard let e = FileManager.default.enumerator(atPath: sources) else { return blob }
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let full = (sources as NSString).appendingPathComponent(rel)
            if let c = try? String(contentsOfFile: full, encoding: .utf8) {
                blob += c + "\n"
            }
        }
        return blob
    }

    @Test func docMatchesExpectedSet() {
        let docs = Self.docKeys()
        let expected = Set(Self.expectedKeys)
        let phantom = docs.subtracting(expected).sorted()
        let missing = expected.subtracting(docs).sorted()
        #expect(
            phantom.isEmpty && missing.isEmpty,
            "phantom keys in .env.example: \(phantom) | expected-but-documented-none: \(missing)")
    }

    @Test func everyExpectedKeyReadInSources() {
        let blob = Self.sourceBlob()
        // OCOREAI_* keys are read two ways:
        //   1. static literal  environment["OCOREAI_API_KEYS"]
        //   2. envPrefix concat  environment["\(...)BACKEND"]   (ConfigSystem)
        //    for case 2 the source never contains the full "OCOREAI_" literal,
        //    so a naive `blob.contains(key)` would false-fail them.  Accept either
        //    form: full literal, OR a line that mentions `envPrefix` and the
        //    suffix (i.e. prefix+suffix read on that line).
        let dynamicPrefix = "OCOREAI_"
        let lines = blob.components(separatedBy: "\n")
        for key in Self.expectedKeys {
            let viaLiteral = blob.contains(key)
            let viaEnvPrefix: Bool
            if key.hasPrefix(dynamicPrefix) {
                let suffix = String(key.dropFirst(dynamicPrefix.count))
                viaEnvPrefix = lines.contains {
                    $0.contains("envPrefix") && $0.contains(suffix)
                }
            } else {
                viaEnvPrefix = false
            }
            #expect(
                viaLiteral || viaEnvPrefix,
                "env key `\(key)` not read in Sources/ as a literal or an envPrefix concat")
        }
    }

    /// Literal keys the code reads, as `environment["UPPER_CASE"]`.
    ///
    /// Deliberately dumb: a substring scan, no regex. Interpolated reads such as
    /// `environment["\(envPrefix)BACKEND"]` yield a token containing a backslash
    /// and are skipped here on purpose — their prefix lives in a constant, and
    /// assertion 3 already covers that direction.
    private static func derivedLiteralKeys() -> Set<String> {
        let prefixes = ["OCOREAI_", "OCRE_", "HF_", "MODELSCOPE_"]
        var keys = Set<String>()
        for line in Self.sourceBlob().components(separatedBy: "\n") {
            var cursor = line.startIndex
            while let open = line.range(of: "environment[\"", range: cursor ..< line.endIndex),
                let close = line.range(of: "\"]", range: open.upperBound ..< line.endIndex)
            {
                let token = String(line[open.upperBound ..< close.lowerBound])
                cursor = close.upperBound
                guard token.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else {
                    continue
                }
                if prefixes.contains(where: { token.hasPrefix($0) }) {
                    keys.insert(token)
                }
            }
        }
        return keys
    }

    /// The env names the code reads *through* its single accessor instead of spelling at the
    /// read site: `HubSource.envVar` (`Models/HubCredential.swift`) is the one home for the
    /// two hub-token names, and `precedence(source:stored:)` the only expression that reads
    /// them. Taken from the compiled type rather than a remembered list, so this still sees a
    /// provider added to the enum — the direction assertion 5 exists to cover.
    private static var keysDeclaredByAccessor: Set<String> {
        Set(HubSource.allCases.map(\.envVar))
    }

    /// Assertion 5 — closes the hole this suite was blind to: keys that exist in
    /// code but were never added to the contract (and therefore never documented).
    @Test func noLiteralReadIsMissingFromContract() {
        let literal = Self.derivedLiteralKeys()
        let viaAccessor = Self.keysDeclaredByAccessor
        let derived = literal.union(viaAccessor)
        // Guard the guard, in parts, because the union alone would hide a collapsed half:
        // 22 = the literal reads left in the tree today (19 before the three margin-probe keys
        // landed, 21 before the two hub tokens moved behind `HubSource.envVar`); the accessor
        // must name one distinct variable per
        // provider, or a duplicated/blank `envVar` would shrink the set unnoticed.
        // If a key is legitimately REMOVED from code, lower the matching floor in the same
        // commit that removes it from expectedKeys.
        #expect(literal.count >= 22, "literal-key scan regressed: \(literal.sorted())")
        #expect(
            viaAccessor.count == HubSource.allCases.count,
            "the hub accessor named \(viaAccessor.sorted()) for \(HubSource.allCases.count) providers — each provider must name one distinct env var"
        )
        #expect(derived.count >= 24, "derived key set regressed: \(derived.sorted())")
        let unlisted = derived.subtracting(Set(Self.expectedKeys)).sorted()
        #expect(
            unlisted.isEmpty,
            "Sources/ reads env keys the contract does not carry: \(unlisted)")
    }

    /// Assertion 6 — the README's own number is a claim about this set, so this file reads it.
    /// Measured 10-24: both READMEs still said "23 environment variables (17 static literals +
    /// 6)" while the contract and `.env.example` carried 27 — two key groups landed since, and
    /// no gate ever re-grepped the prose (invariant 1: a doc whose numbers nobody re-greps
    /// drifts). The scan floors its own hit count — a rotted pattern finds nothing and must
    /// go red, not report parity vacuously.
    @Test func readmeStatesThePinnedSurfaceCount() throws {
        let surface: [(file: String, pattern: String)] = [
            ("README.md", "\\*\\*(\\d+) environment variables\\*\\* \\((\\d+) static.*?(\\d+) read through"),
            ("README.zh.md", "\\*\\*(\\d+) 个环境变量\\*\\*（(\\d+) 个静态.*?(\\d+) 个经常量"),
        ]
        let literal = Self.derivedLiteralKeys().count
        for entry in surface {
            let text = try String(
                contentsOfFile: Self.repoRoot + "/" + entry.file, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: entry.pattern)
            guard let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ),
                let totalRange = Range(match.range(at: 1), in: text),
                let staticRange = Range(match.range(at: 2), in: text),
                let viaRange = Range(match.range(at: 3), in: text)
            else {
                Issue.record(
                    "\(entry.file) no longer states its env-var surface in the pinned shape — this gate cannot read the claim it guards"
                )
                continue
            }
            let statedTotal = Int(text[totalRange]) ?? -1
            let statedStatic = Int(text[staticRange]) ?? -1
            let statedVia = Int(text[viaRange]) ?? -1
            #expect(
                statedTotal == Self.expectedKeys.count,
                "\(entry.file) states \(statedTotal) environment variables; the contract carries \(Self.expectedKeys.count) — fix the prose, not this assertion")
            #expect(
                statedStatic == literal && statedVia == Self.expectedKeys.count - literal,
                "\(entry.file) splits the surface \(statedStatic) static + \(statedVia) indirect, Sources/ splits it \(literal) + \(Self.expectedKeys.count - literal)")
        }
    }

    @Test func noDuplicateKeysInEnvExample() {
        guard
            let content = try? String(
                contentsOfFile: Self.repoRoot + "/.env.example",
                encoding: .utf8)
        else { return }
        var counts = [String: Int]()
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                let eq = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            counts[key, default: 0] += 1
        }
        let dupes = counts.filter { $0.value > 1 }.keys.sorted()
        #expect(dupes.isEmpty, "duplicate env keys in .env.example: \(dupes)")
    }
}
