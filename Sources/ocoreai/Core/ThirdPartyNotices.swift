// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThirdPartyNotices — the GUI's access to the third-party license texts that
/// ship inside the product bundle.
///
/// First principles: BSD-3 clause 2 and Apache-2.0 section 4 oblige us to ship
/// the license texts *with* the distribution, and ocoreai additionally carries
/// source derived from apple/coreai-models whose header points at "the LICENSE
/// file" while this repo's LICENSE is MIT. `scripts/bundle-licenses.sh` puts
/// `THIRD-PARTY-LICENSES/` into Contents/Resources; this type reads it back so
/// the notices are reachable by a person, not only by a filesystem.
///
/// Honest about absence: a bare `swift build` binary carries no bundle, so
/// `manifest` is nil and the UI says so instead of rendering an empty panel.
/// (Same rule as `TokenizerManager.isRealTokenizerBackend`: a substitution or a
/// gap must be visible at runtime, not only at compile time.)
import Foundation

/// One linked SwiftPM dependency, as recorded by the collector script.
public struct ThirdPartyLicenseEntry: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let pin: String
    public let license: String
    public let textFile: String
    public let repository: String

    public var id: String { name }
}

/// `THIRD-PARTY-LICENSES/manifest.json`.
public struct ThirdPartyNoticesManifest: Codable, Sendable {
    public struct Apple: Codable, Sendable {
        public let upstream: String
        public let license: String
        public let licenseFile: String
        /// sha256 of `licenseFile` as committed — the bytes the product ships.
        public let licenseSha256: String?
        /// Upstream revision the shipped text was byte-compared against. Nil when the
        /// reference clone was not present at collection time: it is host-local, so the
        /// collector records the absence instead of guessing a SHA.
        public let pin: String?
        /// Did upstream's `LICENSE` at `pin` hash to the same bytes we ship?
        public let verifiedAgainstPin: Bool?
    }

    /// A third-party file vendored into the source tree — redistributed, but not a
    /// SwiftPM dependency, so no pin or checkout exists to re-resolve it against.
    public struct Vendored: Codable, Sendable, Hashable {
        public let file: String
        public let upstream: String
        public let license: String
        public let holder: String
        public let textFile: String
        public let sha256: String?
    }

    public let schemaVersion: Int
    public let apple: Apple
    public let dependencies: [ThirdPartyLicenseEntry]
    /// Empty when the manifest predates schema 2. Absent must not read as "this build
    /// ships no vendored code" — that is the same absence-vs-falsehood distinction the
    /// encode side of `toolProse` had to get right.
    public let vendored: [Vendored]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, apple, dependencies, vendored
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        apple = try container.decode(Apple.self, forKey: .apple)
        dependencies = try container.decode([ThirdPartyLicenseEntry].self, forKey: .dependencies)
        vendored = try container.decodeIfPresent([Vendored].self, forKey: .vendored) ?? []
    }
}

public enum ThirdPartyNotices {
    /// Folder name inside the bundle / repo root.
    public static let folderName = "THIRD-PARTY-LICENSES"

    /// Directory holding `manifest.json`, or nil when this binary carries none.
    public static let directoryURL: URL? = findDirectory()

    public static let manifest: ThirdPartyNoticesManifest? = loadManifest()

    /// Human-readable index (`NOTICES.md`), nil when absent.
    public static var noticesText: String? {
        guard let dir = directoryURL else { return nil }
        return try? String(
            contentsOf: dir.appendingPathComponent("NOTICES.md"), encoding: .utf8)
    }

    /// Full license text for one dependency, nil when the file was not bundled.
    public static func licenseText(for entry: ThirdPartyLicenseEntry) -> String? {
        text(named: entry.textFile)
    }

    /// Verbatim Apple BSD-3 text (the coreai-models upstream LICENSE).
    public static var appleLicenseText: String? {
        guard let apple = manifest?.apple else { return nil }
        return text(named: apple.licenseFile)
    }

    /// Verbatim upstream license text for one vendored file, nil when not bundled.
    public static func vendoredLicenseText(
        for entry: ThirdPartyNoticesManifest.Vendored
    ) -> String? {
        text(named: entry.textFile)
    }

    private static func text(named file: String) -> String? {
        guard let dir = directoryURL, !file.isEmpty, file != "(not collected)" else {
            return nil
        }
        return try? String(
            contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    private static func findDirectory() -> URL? {
        let manager = FileManager.default
        // Search roots, in order of "how shipped is this": the bundle's own
        // Resources, then the ancestors of the bundle, of the working directory
        // and of argv[0] — the last two are what make an un-bundled host (SPM
        // test runner, `swift run ocoreai serve`, a binary invoked from a shell)
        // find the committed folder instead of reporting it as absent.
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(contentsOf: ancestors(of: Bundle.main.bundleURL, depth: 8))
        roots.append(
            contentsOf: ancestors(of: URL(fileURLWithPath: manager.currentDirectoryPath), depth: 8))
        if let argv0 = CommandLine.arguments.first, argv0.hasPrefix("/") {
            roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: argv0), depth: 8))
        }
        for root in roots {
            let manifest =
                root
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent("manifest.json")
            if manager.fileExists(atPath: manifest.path) {
                return manifest.deletingLastPathComponent()
            }
        }
        return nil
    }

    private static func ancestors(of url: URL, depth: Int) -> [URL] {
        var out: [URL] = []
        var dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        for _ in 0 ..< depth {
            out.append(dir)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return out
    }

    private static func loadManifest() -> ThirdPartyNoticesManifest? {
        guard let dir = directoryURL else { return nil }
        guard
            let data = try? Data(
                contentsOf: dir.appendingPathComponent("manifest.json"))
        else {
            return nil
        }
        return try? JSONDecoder().decode(ThirdPartyNoticesManifest.self, from: data)
    }
}
