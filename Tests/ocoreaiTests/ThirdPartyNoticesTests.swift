// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Distribution-license gate.
///
/// ocoreai ships source derived from apple/coreai-models (BSD-3-Clause) plus 30+
/// SPM dependencies. BSD-3 clause 2 / Apache-2.0 section 4 oblige the license
/// texts to travel with the binary, and before this gate existed the texts lived
/// only in the git repo while the product went out as .app/.dmg — a silent
/// violation nobody could see. These tests pin the contract that
/// scripts/collect-third-party-licenses.sh and scripts/bundle-licenses.sh keep,
/// so adding a dependency without collecting its text fails CI instead of
/// shipping.
///
/// Exact-value assertions only: sets, counts and substrings, never "some file
/// exists somewhere".
import Foundation
import Testing

@testable import ocoreai

@Suite("Third-party license texts travel with the product")
struct ThirdPartyNoticesTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/ocoreaiTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private let folder: URL
    private let manifest: ThirdPartyNoticesManifest
    private let resolved: [ResolvedPin]

    init() throws {
        folder = Self.repoRoot
            .appendingPathComponent(ThirdPartyNotices.folderName, isDirectory: true)
        // Content is pinned against the repo folder (authoritative for the gate);
        // the runtime resolver gets its own dedicated test below, so a resolver
        // regression surfaces once instead of failing every case here.
        let data = try Data(
            contentsOf: folder.appendingPathComponent("manifest.json"))
        manifest = try JSONDecoder().decode(ThirdPartyNoticesManifest.self, from: data)
        resolved = try ThirdPartyNoticesTests.loadResolvedPins()
    }

    // MARK: - Resolved pins

    private struct ResolvedPin: Decodable {
        struct State: Decodable {
            let version: String?
            let revision: String?
        }
        let identity: String
        let location: String
        let state: State

        var pinLabel: String {
            if let version = state.version { return version }
            return "rev " + String((state.revision ?? "").prefix(12))
        }
    }

    private static func loadResolvedPins() throws -> [ResolvedPin] {
        let url = repoRoot.appendingPathComponent("Package.resolved")
        struct Resolved: Decodable { let pins: [ResolvedPin] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Resolved.self, from: data).pins
    }

    // MARK: - Contract with the packaging scripts

    @Test("folder name matches what bundle-licenses.sh copies into the app")
    func folderNameIsThePackagingContract() {
        #expect(ThirdPartyNotices.folderName == "THIRD-PARTY-LICENSES")
    }

    @Test("index, manifest and Apple text are all present")
    func coreFilesExist() throws {
        let manager = FileManager.default
        #expect(
            manager.fileExists(atPath: folder.appendingPathComponent("NOTICES.md").path))
        #expect(
            manager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        #expect(
            manager.fileExists(
                atPath: folder.appendingPathComponent(manifest.apple.licenseFile).path))
    }

    @Test("runtime lookup finds the notices even with no .app bundle around")
    func unbundledRuntimeLookupResolves() throws {
        // Dev/test hosts have no Contents/Resources; the executable walk-up must
        // still resolve, otherwise the GUI row would lie about availability.
        let dir = ThirdPartyNotices.directoryURL
        #expect(
            dir != nil,
            "resolver found nothing — cwd=\(FileManager.default.currentDirectoryPath) argv0=\(CommandLine.arguments.first ?? "nil") resourceURL=\(Bundle.main.resourceURL?.path ?? "nil")"
        )
        #expect(dir?.lastPathComponent == ThirdPartyNotices.folderName)
        #expect(ThirdPartyNotices.manifest?.dependencies.count == manifest.dependencies.count)
        #expect(ThirdPartyNotices.noticesText?.isEmpty == false)
        #expect(ThirdPartyNotices.appleLicenseText?.isEmpty == false)
    }

    // MARK: - Apple-derived code

    @Test("Apple block names the real upstream and its real license")
    func appleBlockIsAccurate() {
        #expect(manifest.apple.upstream == "apple/coreai-models")
        #expect(manifest.apple.license == "BSD-3-Clause")
        #expect(manifest.schemaVersion == 1)
    }

    @Test("Apple text is the BSD-3-Clause conditions, not MIT and not truncated")
    func appleTextIsBsd3() throws {
        let text = try String(
            contentsOf: folder.appendingPathComponent(manifest.apple.licenseFile),
            encoding: .utf8)
        #expect(text.contains("Copyright 2026 Apple Inc."))
        #expect(text.contains("Redistribution and use in source and binary forms"))
        #expect(text.contains("Neither the name of the copyright holder"))
        #expect(text.contains("THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS"))
        // The repo's own LICENSE is MIT; shipping MIT in Apple's slot would be a
        // mislabelled grant, so assert the MIT grant wording is absent here.
        #expect(!text.contains("Permission is hereby granted, free of charge"))
    }

    @Test("index tells the user where the texts live inside the shipped app")
    func indexStatesTheBundlePath() throws {
        let notices = try String(
            contentsOf: folder.appendingPathComponent("NOTICES.md"), encoding: .utf8)
        #expect(notices.contains("ocoreai.app/Contents/Resources/THIRD-PARTY-LICENSES/"))
        #expect(notices.contains("apple/coreai-models"))
        #expect(notices.contains("openai/codex"))
    }

    // MARK: - Dependencies

    @Test("every resolved dependency has a pin, license and text — exact set equality")
    func dependencyTextsMatchPackageResolved() throws {
        let expected = Set(resolved.map(\.identity))
        let shipped = Set(manifest.dependencies.map(\.name))
        #expect(
            expected == shipped,
            "missing: \(expected.subtracting(shipped).sorted()), unexplained: \(shipped.subtracting(expected).sorted())"
        )
        #expect(manifest.dependencies.count == resolved.count)

        let pinsByDependency = Dictionary(
            uniqueKeysWithValues: manifest.dependencies.map { ($0.name, $0.pin) })
        for pin in resolved {
            #expect(
                pinsByDependency[pin.identity] == pin.pinLabel,
                "pin drift for \(pin.identity)")
            let entry = manifest.dependencies.first { $0.name == pin.identity }
            let text = try #require(
                entry?.textFile, "no text recorded for \(pin.identity)")
            #expect(text != "(not collected)")
            #expect(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(text).path),
                "license text file missing: \(text)")
            let license = entry?.license ?? ""
            #expect(
                license == "Apache-2.0" || license == "MIT" || license == "BSD-3-Clause"
                    || license == "ISC",
                "unidentified license for \(pin.identity): \(license)")
        }
    }

    @Test("no copyleft text ships in the notices folder")
    func noCopyleftTexts() throws {
        // GPL/LGPL would reach past this folder into the whole binary; if one ever
        // appears, that is a product decision, not a NOTICEs.md edit.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".txt") }
        #expect(!names.isEmpty)
        for name in names {
            let text = try String(
                contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("GNU GENERAL PUBLIC LICENSE"), "copyleft in \(name)")
            #expect(!text.contains("GNU LESSER GENERAL PUBLIC LICENSE"), "copyleft in \(name)")
            #expect(!text.contains("Mozilla Public License"), "MPL in \(name)")
        }
    }

    /// BSD-3 clause 1: redistributed Apple code must carry the copyright notice
    /// *and* the conditions pointer. A file that copies Apple source without the
    /// license line is the failure mode this pins — a scan of the tree, not a
    /// count, so it cannot be satisfied by editing a number.
    @Test("every Apple-copyrighted source file declares the BSD-3 notice")
    func appleCopyrightedFilesCarryBsdNotice() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let walked = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil,
            options: [])
        let swiftFiles = (walked?.compactMap { $0 as? URL } ?? []).filter {
            $0.pathExtension == "swift" || $0.pathExtension == "h" || $0.pathExtension == "cpp"
        }
        #expect(!swiftFiles.isEmpty)
        var appleFiles = 0
        for url in swiftFiles {
            guard let head = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let header = String(head.prefix(1200))
            guard header.contains("Apple Inc.") else { continue }
            appleFiles += 1
            #expect(
                header.lowercased().contains("bsd-3"),
                "Apple copyright without a BSD-3 notice: \(url.path)")
        }
        // The population is pinned at a floor so an accidentally narrowed scan
        // (wrong root, wrong extensions) cannot look like a pass.
        #expect(
            appleFiles >= 44, "scan regressed: only \(appleFiles) Apple-copyrighted files found")
    }

    /// A header vendored under `Sources/lib/` is neither ocoreai's MIT code nor
    /// Apple's BSD-3 code — it carries somebody else's copyright into the product,
    /// so it needs its own attribution and text. dlpack.h is the one case today;
    /// the exact count is the point: a second one must land here deliberately.
    @Test("vendored third-party headers are attributed, with their text bundled")
    func vendoredHeadersAreAttributed() throws {
        let notices = try String(
            contentsOf: folder.appendingPathComponent("NOTICES.md"), encoding: .utf8)
        let lib = Self.repoRoot.appendingPathComponent("Sources/lib", isDirectory: true)
        let walked = FileManager.default.enumerator(
            at: lib, includingPropertiesForKeys: nil, options: [])
        let extensions: [String] = ["h", "hpp", "c", "cpp", "mm"]
        let headers = (walked?.compactMap { $0 as? URL } ?? []).filter {
            extensions.contains($0.pathExtension)
        }
        #expect(!headers.isEmpty)

        let repoPrefix = Self.repoRoot.path + "/"
        var vendored: [String] = []
        for url in headers {
            guard let head = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard head.contains("Copyright") else { continue }
            if head.contains("Apple Inc.") || head.contains("uingei") { continue }
            let relative =
                url.path.hasPrefix(repoPrefix)
                ? String(url.path.dropFirst(repoPrefix.count))
                : url.lastPathComponent
            vendored.append(relative)
            #expect(notices.contains(relative), "not attributed in NOTICES.md: \(relative)")
        }
        #expect(vendored == ["Sources/lib/CXGrammar/include/dlpack/dlpack.h"])
        let apacheText = try String(
            contentsOf: folder.appendingPathComponent("Vendored-dlpack-Apache-2.0.txt"),
            encoding: .utf8)
        #expect(apacheText.contains("Apache License"))
        #expect(
            apacheText.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        // Body only: the appendix is guidance, and its template line names whoever
        // wrote the file the text was taken from — that must not travel under a
        // dlpack filename. ("Appendix below" is legitimate section-4 prose, so the
        // heading/template is what gets asserted, not the word itself.)
        #expect(apacheText.contains("END OF TERMS AND CONDITIONS"))
        #expect(!apacheText.contains("Copyright [yyyy]"))
        #expect(!apacheText.contains("APPENDIX: How to apply"))
    }

    /// Two shipped lines read `Copyright ? 2026 …` (mojibake of the sign) and
    /// `uigei@163.com` (a missing letter) — notices that name the right holder
    /// incorrectly. Both classes fail here.
    @Test("no malformed rightsholder marker in any source header")
    func rightsholderMarkersAreIntact() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let walked = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [])
        let scanned = (walked?.compactMap { $0 as? URL } ?? []).filter {
            ["swift", "h", "hpp", "c", "cpp", "mm"].contains($0.pathExtension)
        }
        // Floor from the measured tree (267 tracked files under Sources/, 264 Swift):
        // a narrowed scan (wrong root / wrong extensions) must not look like a pass.
        #expect(scanned.count >= 250, "scan regressed: only \(scanned.count) files")
        for url in scanned {
            guard let head = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let header = String(head.prefix(1200))
            #expect(!header.contains("Copyright ?"), "mojibake copyright: \(url.path)")
            #expect(!header.contains("uigei@"), "misspelled rightsholder: \(url.path)")
        }
    }
}
