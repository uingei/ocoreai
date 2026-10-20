// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HubPathTraversalTests.swift — a hub-supplied path lands under its root, or nowhere.
///
/// Three floors, ordered by how much they prove:
///   1. the rule itself — `HubRelativePath.components` / `.resolve`, exact values;
///   2. behaviour on the wire — `POST /v1/models/download` answers 400 naming the field and
///      echoing the value, *before* the SSE stream or any filesystem work;
///   3. that both download lanes route through the rule (one real predicate on the HF lane, plus
///      source scans with their own hit-count floors), because a rule nobody calls is a rule that
///      drifts. See CONTRIBUTING → "the three questions" / `V1EndpointCatalogTests` for why a scan
///      that stopped matching must fail rather than pass vacuously.
///
/// What is NOT covered here, stated rather than hidden: the ModelScope lane's manifest refusal
/// sits behind `listRepoFiles`, so it has no hermetic behavioural assertion — probe
/// `scripts/probes/20-download-path-traversal.sh` covers the wire end live, and the scan floors
/// cover the wiring.

import Foundation
import HuggingFace
import Testing

@testable import ocoreai

// MARK: - 1. The rule

@Suite("HubRelativePath — components, exact verdicts")
struct HubRelativePathRuleTests {

    /// Paths a real hub answers with, and the components they must yield.
    private static let legitimate: [(raw: String, components: [String])] = [
        ("mlx-community/gemma-4-e2b-it-4bit", ["mlx-community", "gemma-4-e2b-it-4bit"]),
        ("Qwen/Qwen2.5-7B-Instruct", ["Qwen", "Qwen2.5-7B-Instruct"]),
        (".gitattributes", [".gitattributes"]),
        ("sub/dir/model.safetensors", ["sub", "dir", "model.safetensors"]),
        ("model.safetensors", ["model.safetensors"]),
        ("tokenizer.json", ["tokenizer.json"]),
        // Only an *exact* dot-component walks; a name that merely starts with dots is ordinary.
        ("..hidden/config.json", ["..hidden", "config.json"]),
        ("org/name.d.5", ["org", "name.d.5"]),
    ]

    /// Paths that must be refused, each with the single hazard it hits.
    private static let hazards: [(raw: String, reason: HubRelativePath.Unsafe.Reason)] = [
        ("..", .dotComponent),
        ("../x", .dotComponent),
        ("a/../../b", .dotComponent),
        ("foo/./bar", .dotComponent),
        ("/etc/passwd", .absolutePath),
        ("/", .absolutePath),
        ("~/.ssh", .tildeHome),
        ("~", .tildeHome),
        ("a//b", .emptyComponent),
        ("a/", .emptyComponent),
        ("..\\x", .backslash),
        ("a\\b", .backslash),
        ("", .empty),
        ("\u{0}", .controlCharacter),
        ("a\u{1}b", .controlCharacter),
        (" lead", .surroundingWhitespace),
        ("lead ", .surroundingWhitespace),
    ]

    @Test("legitimate hub paths yield their components verbatim")
    func legitimatePaths() throws {
        for case (let raw, let expected) in Self.legitimate {
            let parts = try HubRelativePath.components(raw, field: "model")
            #expect(parts == expected, "components(\"\(raw)\") → \(parts)")
        }
    }

    @Test("escaping paths are refused, each naming its own hazard")
    func escapingPaths() {
        for case (let raw, let expectedReason) in Self.hazards {
            do {
                _ = try HubRelativePath.components(raw, field: "files[].path")
                Issue.record("expected refusal for \(HubRelativePath.Unsafe.escaped(raw))")
            } catch let rejection as HubRelativePath.Unsafe {
                #expect(rejection.reason == expectedReason, "\(raw) → \(rejection.reason.rawValue)")
                #expect(rejection.field == "files[].path")
                #expect(rejection.value == raw)
            } catch {
                Issue.record("wrong error type for \(raw): \(error)")
            }
        }
    }

    /// A refusal has to be readable *and* inert: control characters escaped, field + reason +
    /// value all present. This is the string a client sees in the 400 body.
    @Test("refusal text names field, reason and value, with control characters escaped")
    func refusalIsReadableAndInert() {
        let rejection = HubRelativePath.Unsafe(
            field: "model", value: "\u{0}evil", reason: .controlCharacter)
        #expect(
            rejection.description
                == "model is not a safe cache-relative path (controlCharacter): \"\\u{00}evil\"")
        #expect(rejection.errorDescription == rejection.description)
    }
}

// MARK: - 2. Containment

@Suite("HubRelativePath.resolve — containment, including symlinks")
struct HubRelativePathResolveTests {

    /// Isolated pair of directories: `root` is the cache root, `outside` is anywhere else.
    private static func makeSandbox() throws -> (root: URL, outside: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubpath-\(UUID().uuidString)")
        let root = base.appendingPathComponent("models")
        let outside = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (root, outside, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("a legitimate nested path resolves inside the root")
    func legitResolvesUnderRoot() throws {
        let (root, outside, cleanup) = try Self.makeSandbox()
        defer { cleanup() }
        _ = outside

        let out = try HubRelativePath.resolve(
            under: root, "mlx-community/tiny/config.json", field: "model")
        #expect(
            out.path
                == root.appendingPathComponent("mlx-community").appendingPathComponent("tiny")
                .appendingPathComponent("config.json").path)
    }

    /// The write-side attack: the cache dir contains a symlink to somewhere else, and the manifest
    /// names a path *through* it. The tail does not exist yet — that is precisely the case a
    /// lexical check passes and a real filesystem obeys.
    @Test("a symlink inside the root cannot carry a write outside it")
    func symlinkEscapeIsRefused() throws {
        let (root, outside, cleanup) = try Self.makeSandbox()
        defer { cleanup() }
        let fm = FileManager.default
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: outside.path)

        for raw in ["link/payload.safetensors", "link/nested/deeper.bin"] {
            do {
                let out = try HubRelativePath.resolve(under: root, raw, field: "files[].path")
                Issue.record("expected escapedRoot for \(raw), got \(out.path)")
            } catch let rejection as HubRelativePath.Unsafe {
                #expect(rejection.reason == .escapedRoot, "\(raw) → \(rejection.reason.rawValue)")
            }
        }

        // Positive control: the rule refuses the escape, not the directory.
        try fm.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let ok = try HubRelativePath.resolve(under: root, "sub/payload.bin", field: "files[].path")
        #expect(ok.path == root.appendingPathComponent("sub/payload.bin").path)
    }

    /// A dangling symlink has no target to escape to (creating through it fails at the syscall),
    /// so it stays contained — asserted so the resolution rule's ancestor walk is pinned, too.
    @Test("a dangling symlink tail stays contained")
    func danglingSymlinkStaysContained() throws {
        let (root, outside, cleanup) = try Self.makeSandbox()
        defer { cleanup() }
        _ = outside
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dangling").path,
            withDestinationPath: "/nonexistent-ocoreai-target-\(UUID().uuidString)")

        let out = try HubRelativePath.resolve(under: root, "dangling/x.bin", field: "files[].path")
        #expect(out.path == root.appendingPathComponent("dangling/x.bin").path)
    }
}

// MARK: - 3. Wire behaviour

@Suite("POST /v1/models/download — traversal refused as a 400 naming the field")
struct DownloadRequestTraversalTests {

    /// Resolves `param`/`value` out of the refusal so the assertion is about the wire shape
    /// (vllm's `param`, the field an SDK branches on), not just about "some error happened".
    private static func paramAndValue(of error: AppError) -> (String, String?)? {
        guard case .invalidParameter(let param, _, let value) = error else { return nil }
        return (param, value)
    }

    @Test("model ids that walk are refused before the stream opens")
    func escapingModelIdsAreRefused() {
        for raw in ["../../../../tmp/ocoreai-traversal-probe", "..", "/etc/passwd", "a/../../b"] {
            do {
                try DownloadModelRequest(model: raw, provider: "mscope").validate()
                Issue.record("expected a refusal for model=\(raw)")
            } catch let error as AppError {
                guard case .invalidParameter(let param, let message, let value) = error else {
                    Issue.record("expected invalidParameter for \(raw), got \(error)")
                    continue
                }
                #expect(param == "model")
                #expect(value == raw)
                #expect(message.contains("absolutePath") || message.contains("dotComponent"))
            } catch {
                Issue.record("wrong error type for \(raw): \(error)")
            }
        }
    }

    @Test("a revision is validated on the same rule, and blames `revision`")
    func escapingRevisionIsRefused() {
        do {
            try DownloadModelRequest(
                model: "mlx-community/tiny", provider: "mscope", revision: "../evil"
            ).validate()
            Issue.record("expected a refusal for revision=../evil")
        } catch let error as AppError {
            guard let (param, value) = Self.paramAndValue(of: error) else {
                Issue.record("expected invalidParameter, got \(error)")
                return
            }
            #expect(param == "revision")
            #expect(value == "../evil")
        } catch {
            Issue.record("wrong error type for revision=../evil: \(error)")
        }
    }

    @Test("legitimate requests still validate — the fix must not eat real downloads")
    func legitimateRequestsStillValidate() throws {
        try DownloadModelRequest(
            model: "mlx-community/gemma-4-e2b-it-4bit", provider: "hf", revision: "main",
            useLatest: false
        ).validate()
        try DownloadModelRequest(model: "Qwen/Qwen2.5-7B-Instruct", provider: "mscope").validate()
        // The pre-existing refusals are untouched.
        #expect(throws: AppError.self) {
            try DownloadModelRequest(model: "").validate()
        }
        #expect(throws: AppError.self) {
            try DownloadModelRequest(model: "a/b", provider: "modelscope").validate()
        }
    }
}

// MARK: - 4. The lanes actually call the rule

@Suite("Download lanes route through HubRelativePath")
struct HubPathWiringTests {

    /// Repo root found by walking up until the file exists — never a fixed hop count
    /// (`V1EndpointCatalogTests`: hardcoded hops landed on `Tests/` and every scan threw ENOENT).
    private static func source(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent("Sources/ocoreai/\(relative)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "Sources/ocoreai/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "not found walking up from \(#filePath): \(path)" }
    }

    private static func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The ModelScope lane: every join of a remote string goes through the rule, and the one raw
    /// join left is the temp-name helper, whose separators are flattened before the join.
    @Test("ModelScope lane: guarded joins only, and the scan proves it looked")
    func modelScopeLaneIsGuarded() throws {
        let source = try Self.source("Models/ModelScopeDownloader.swift")

        // Premise of the scan itself: this file still joins paths (if it stopped, the
        // assertions below would be vacuous).
        #expect(Self.count("appendingPathComponent", in: source) >= 4)
        // And it really does route through the one home.
        #expect(Self.count("HubRelativePath", in: source) >= 5)

        let rawJoins = source.split(separator: "\n").filter {
            $0.contains("cacheDir.appendingPathComponent(")
        }
        #expect(rawJoins.count >= 1, "expected the flattened temp join to still exist")
        for line in rawJoins {
            #expect(
                line.contains("flattened"),
                "unguarded cacheDir join: \(line.trimmingCharacters(in: .whitespaces))")
        }
        // `..` can never appear in the temp name because separators are gone before the join.
        #expect(source.contains("replacingOccurrences(of: \"/\", with: \"__\")"))
    }

    /// The HF lane: `flatTarget` is the write destination for `downloadSnapshot(to:)`, so the
    /// predicate is exercised directly rather than trusted to a grep.
    @Test("HF lane: flatTarget refuses ids that walk")
    func hfLaneRefusesEscapingIds() throws {
        let bridge = try Self.source("Engine/MLXBridge.swift")
        #expect(Self.count("HubRelativePath", in: bridge) >= 1)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-flat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dl = ReadyHubDownloader(hub: ModelStore.readyHubClient(), flatRoot: root)
        for raw in ["../../evil", "..", "org/../../evil", "/etc/passwd", "a//b", "a/./b"] {
            #expect(dl.flatTarget(for: raw) == nil, "flatTarget accepted \(raw)")
        }
        #expect(
            dl.flatTarget(for: "mlx-community/tiny")?.path
                == root.path + "/mlx-community/tiny")
        // A single-component id is not flat-layout — legacy cache path (unchanged behaviour).
        #expect(dl.flatTarget(for: "just-a-name") == nil)
    }

    @Test("the DTO validates both wire fields that reach a path")
    func dtoValidatesBothFields() throws {
        let source = try Self.source("Models/ModelDownloadDTO.swift")
        #expect(Self.count("HubRelativePath.components", in: source) >= 2)
        #expect(source.contains("field: \"model\""))
        #expect(source.contains("field: \"revision\""))
    }
}
