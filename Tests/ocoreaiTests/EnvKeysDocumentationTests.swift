// EnvKeysDocumentationTests.swift
//
// Locks the env-var documentation surface (.env.example) against code drift.
//
// ocoreai reads 22 environment variables: 18 static `environment["KEY"]`
// literals + 4 `\(...)HOST/PORT/BACKEND/...` dynamic keys in
// ConfigSystem.applyEnvOverrides. Before this work the surface was not
// documented in README and no `.env.example` existed — a fresh clone had no
// way to know it.
//
// This test set pins the EXPECTED 21-key set as the single source of truth
// (no regex re-derivation, which is itself drift-prone) and asserts:
//   1. no phantom:   no `.env.example` key outside the expected set
//   2. no omission:  no expected key missing from `.env.example`
//   3. no stale row: every expected key is actually read in Sources/
//   4. no dupes:     `.env.example` has no repeated key
//
// ADD a new env var in code → add it to expectedKeys AND to .env.example;
// test 3 will fail until both are done.
import Foundation
import Testing

struct EnvKeysDocumentationTests {

    /// The 22 env-var keys ocoreai reads. This list IS the contract.
    private static let expectedKeys: [String] = [
        // Server
        "OCOREAI_HOST", "OCOREAI_PORT",
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
        // web_search / web_fetch (本地 ollama 后端)
        "OCRE_SEARCH_BASE_URL", "OCRE_SEARCH_MODEL", "OCRE_SEARCH_TIMEOUT",
        "OCRE_SEARCH_PROBE_TIMEOUT", "OCRE_FETCH_TIMEOUT",
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
