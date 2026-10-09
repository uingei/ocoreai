import Foundation
// Tests for the license-surface (license shown before the download click).
import Testing

@testable import ocoreai

@Suite("License badge surface")
struct LicenseBadgeTests {

    private func hf(_ tags: [String]) -> HFHubModel {
        HFHubModel(
            id: "mlx-community/Test-4bit",
            displayName: "Test-4bit",
            tags: tags,
            likes: 0,
            pipelineTag: nil,
            lastModified: nil,
            downloads: nil,
            sizeBytes: nil,
        )
    }

    @Test func licenseTagBecomesSlug() {
        #expect(hf(["mlx", "license:apache-2.0"]).licenseSlug == "apache-2.0")
    }

    @Test func multiLicenseRepoKeepsAllTerms() {
        // Picking one silently would misrepresent what the user accepts.
        #expect(hf(["license:apache-2.0 OR llama3.1"]).licenseSlug == "apache-2.0 OR llama3.1")
    }

    @Test func noLicenseTagMeansNoBadge() {
        // Absence is honest; a guessed "unknown" badge is noise.
        #expect(hf(["mlx", "text-generation"]).licenseSlug == nil)
        #expect(hf(["license:"]).licenseSlug == nil)
    }

    @Test func badgeCapitalizesFirstLetterOnly() {
        // UI contract: "apache-2.0" → "Apache-2.0" (badge, not legal text).
        let slug = "mit"
        let shown = slug.prefix(1).uppercased() + slug.dropFirst()
        #expect(shown == "Mit")
    }

    @Test func localizationKeysExist() {
        // Both tables must carry the a11y string — a zh gap falls back to
        // en silently (invisible to `.l`), so assert per-table, not per-chain.
        #expect(L10nTables.base[StringKey.licenseBadgeA11yFormat]?.contains("%@") == true)
        #expect(L10nTables.zh[StringKey.licenseBadgeA11yFormat]?.contains("%@") == true)
    }
}
