// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// A platform line a user reads is a claim, so it carries the same duty as `/v1/capabilities`.
///
/// Both READMEs advertised "macOS 14+ · iOS 17+" — a floor declared in `Package.swift` and never
/// executed: the test suite, the live probes and the task scoreboard all run on one macOS 26 host,
/// the iOS leg in CI builds `-destination generic/platform=iOS` and does not run, and this host has
/// no iOS simulator runtime at all (`xcrun simctl list runtimes` answers empty). Invariant 2 says a
/// surface may not promise more than the engine delivered; these scans keep the qualifier attached
/// to the claim, in both languages, with counts pinned so a wording drift goes red.

import Foundation
import Testing

@testable import ocoreai

private func claimRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func read(_ relative: String) throws -> String {
    try String(contentsOf: claimRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

@Suite("Platform claims — declared floors say so next to the measurement")
struct PlatformClaimHonestyTests {

    /// Each README carries the measured-vs-declared paragraph exactly once.
    @Test func bothReadmesCarryTheQualifier() throws {
        let en = try read("README.md")
        let zh = try read("README.zh.md")
        let enMarker = occurrences(of: "Measured vs declared", in: en)
        #expect(enMarker == 1, "README.md qualifies once, saw \(enMarker)")
        let zhMarker = occurrences(of: "测过的 vs 声明的", in: zh)
        #expect(zhMarker == 1, "README.zh.md qualifies once, saw \(zhMarker)")
    }

    /// The declared floors stay, but never alone: the executed host and the compile-only fact
    /// sit in the same document, in both languages, at pinned counts.
    @Test func declaredFloorsTravelWithTheirEvidence() throws {
        for file in ["README.md", "README.zh.md"] {
            let text = try read(file)
            let declared = occurrences(of: "macOS 14+", in: text)
            #expect(declared == 2, "\(file) states the macOS floor twice, saw \(declared)")
            let ios = occurrences(of: "iOS 17+", in: text)
            #expect(ios == 3, "\(file) states the iOS floor three times, saw \(ios)")
            let measured = occurrences(of: "macOS 26", in: text)
            #expect(measured >= 1, "\(file) must name what was actually executed")
            let compileOnly = occurrences(of: "generic/platform=iOS", in: text)
            #expect(compileOnly == 2, "\(file) names the iOS reality twice, saw \(compileOnly)")
            let coreai =
                occurrences(of: "CoreAI-free", in: text) + occurrences(of: "不含 CoreAI", in: text)
            #expect(coreai == 1, "\(file) states the delivery shape once, saw \(coreai)")
            let minos = occurrences(of: "minos", in: text)
            #expect(minos == 1, "\(file) cites the artifact floor once, saw \(minos)")
        }
    }

    /// The numbers belong to the manifest, not to prose: each declared floor appears once there,
    /// so a README edit cannot invent a second truth about the platform.
    @Test func manifestIsTheOneHomeForTheFloors() throws {
        let manifest = try read("Package.swift")
        let mac = occurrences(of: ".macOS(.v14)", in: manifest)
        #expect(mac == 1, "the macOS floor is declared once, saw \(mac)")
        let ios = occurrences(of: ".iOS(.v17)", in: manifest)
        #expect(ios == 1, "the iOS floor is declared once, saw \(ios)")
    }
}
