// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MetalShaderLibraryTests — the shader-payload search, pinned against the layout
/// that actually bit this host on 10-14.
///
/// Pure logic: no GPU, no filesystem writes, no MLX call. These therefore run in the
/// sandboxed route too — the case where the payload is missing is exactly when a
/// Metal-touching test would abort the process instead of reporting a failure.
import Foundation
import Testing

@testable import ocoreai

@Suite("MetalShaderLibrary — payload discovery")
struct MetalShaderLibraryTests {

    /// The SwiftPM 6.4 layout measured on 10-14: test executable three levels below the
    /// products dir that holds `mlx-swift_Cmlx.bundle`.
    private static let xctestExecutable =
        "/repo/.build-clt/out/Products/Debug/ocoreaiTests.xctest/Contents/MacOS/ocoreaiTests"
    private static let products = "/repo/.build-clt/out/Products/Debug"

    /// Repo-root-relative file contents, found by walking up. A fixed hop count is what
    /// broke `V1EndpointCatalogTests` the day it first executed, so root discovery here
    /// proves itself by finding the file.
    static func repoFile(_ relative: String) throws -> String {
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

    /// Distinct error type so a discovery failure never masquerades as a scan failure.
    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    @Test("the products-dir payload is reachable from inside the .xctest")
    func findsPayloadAboveTheBundle() {
        let candidates = MetalShaderLibrary.candidatePaths(
            executablePath: Self.xctestExecutable, environment: [:])
        #expect(
            candidates.contains("\(Self.products)/mlx.metallib"),
            "staged copy beside the products dir must be a candidate")
        #expect(
            candidates.contains(
                "\(Self.products)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
            "the Cmlx bundle in the products dir must be a candidate")
    }

    /// MLX's own search is binary-relative first (paths ①/②), and those paths sit inside
    /// the `.xctest`. Reading them is fine; WRITING them is not — a `.metallib` under
    /// `Contents/MacOS` is a nested code object, so the build's CodeSign task dies with
    /// "code object is not signed at all … mlx.metallib" (measured 10-14, when this
    /// target began staging into the bundle SwiftPM 6.4 actually produces). The invariant
    /// therefore lives in the Makefile, and this checks the Makefile: a rule enforced by a
    /// gate rather than remembered in a comment.
    @Test("the Makefile stages outside every signed bundle")
    func stagingNeverWritesIntoASignedBundle() throws {
        let makefile = try Self.repoFile("Makefile")
        var copyLines = 0
        for line in makefile.split(separator: "\n") {
            guard line.contains("cp -f") else { continue }
            copyLines += 1
            #expect(
                !line.contains(".xctest"),
                "staging into a signed .xctest breaks CodeSign: \(line.trimmingCharacters(in: .whitespaces))"
            )
        }
        #expect(copyLines > 0, "no staging step left in the Makefile — the gate is vacuous")
        // The resolved path reaches the test process by env var, not by file location.
        #expect(makefile.contains("OCOREAI_METALLIB"))
    }

    @Test("$OCOREAI_METALLIB wins, and an unset/empty value injects nothing")
    func environmentOverride() {
        let override = "/opt/mlx/custom.metallib"
        let withOverride = MetalShaderLibrary.candidatePaths(
            executablePath: Self.xctestExecutable,
            environment: [MetalShaderLibrary.environmentVariable: override])
        #expect(withOverride.first == override, "explicit override must be tried first")

        for empty in [["OCOREAI_METALLIB": ""], [:]] {
            let paths = MetalShaderLibrary.candidatePaths(
                executablePath: Self.xctestExecutable, environment: empty)
            #expect(!paths.contains(""), "empty override must not become a candidate")
            #expect(!paths.isEmpty)
        }
    }

    @Test("own directory is searched before any ancestor")
    func nearerPathsFirst() {
        let candidates = MetalShaderLibrary.candidatePaths(
            executablePath: Self.xctestExecutable, environment: [:])
        let ownDir = (Self.xctestExecutable as NSString).deletingLastPathComponent
        guard
            let own = candidates.firstIndex(of: "\(ownDir)/mlx.metallib"),
            let above = candidates.firstIndex(of: "\(Self.products)/mlx.metallib")
        else {
            Issue.record("expected both colocated and products-dir candidates")
            return
        }
        #expect(own < above, "a payload next to the binary must outrank one further up")
    }

    /// The walk is ordered nearest-first, so "skips" has to be tested against a
    /// predicate that only the far candidate satisfies: the unusable `$OCOREAI_METALLIB`
    /// must be passed over, the nearer (non-existent) copies too, and the answer must be
    /// the payload three levels above the test binary.
    @Test("unusable candidates are skipped until the products-dir payload")
    func firstExistingSkipsUnusable() {
        let payload =
            "\(Self.products)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        let chosen = MetalShaderLibrary.firstExisting(
            executablePath: Self.xctestExecutable,
            environment: [MetalShaderLibrary.environmentVariable: "/nope/absent.metallib"],
            isUsable: { $0 == payload }
        )
        #expect(chosen == payload, "the walk must reach the products-dir payload")
        // Real usability check, fake tree: nothing on disk here, so the answer is nil —
        // the resolver must not hand back a path it never verified.
        #expect(
            MetalShaderLibrary.firstExisting(
                executablePath: "/no/such/tree/ocoreai",
                environment: [MetalShaderLibrary.environmentVariable: "/nope/absent.metallib"]
            ) == nil,
            "an override that names nothing usable must not be returned as a result")
    }

    @Test("no payload → nil (the override stays unset so MLX still searches)")
    func nothingUsableReturnsNil() {
        let chosen = MetalShaderLibrary.firstExisting(
            executablePath: "/tmp/definitely-not-here/ocoreai",
            environment: [:],
            isUsable: { _ in false }
        )
        #expect(chosen == nil)
    }
}
