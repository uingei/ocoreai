import Foundation
// Guards the honest hub-search failure surface: the user must be able to
// tell WHICH hub broke, WHY it broke, and WHAT lever fixes it — and a
// failure banner must never be overwritten by "nothing found".
import Testing

@testable import ocoreai

@Suite("Hub search failure honesty")
struct HubSearchFailureTests {

    /// Resolve a key against the EN table explicitly — `.l` follows the
    /// host locale (this host runs zh), so content assertions on English
    /// substrings must pin the table, not the chain.
    private func en(_ key: StringKey) -> String { L10nTables.base[key] ?? "" }

    @Test("failure names the hub, carries the reason, offers the lever")
    func failureNamesHubReasonLever() {
        let hf =
            RepositoryError.hubSearchFailed(hub: .huggingFace, reason: "timed out").errorDescription
            ?? ""
        // Host-locale-independent shape assertions: en-table substrings,
        // checked case-insensitively against the resolved string.
        #expect(hf.contains("Hugging Face"))
        #expect(hf.contains("timed out"))
        let hfHint = en(.modelSearchFailedHFHint).lowercased()
        #expect(hfHint.contains("mirror"), "HF failure must name the mirror lever")
        #expect(hfHint.contains("settings"), "HF failure must point at Settings")

        let ms =
            RepositoryError.hubSearchFailed(hub: .modelScope, reason: "502").errorDescription ?? ""
        #expect(ms.contains("ModelScope"))
        #expect(ms.contains("502"))
        #expect(en(.modelSearchFailedMSHint).lowercased().contains("switch"))
    }

    @Test("failure and empty-results are distinct states")
    func failureDistinctFromNoResults() {
        // The old lie: failure rendered as "No models found: x" — the user
        // could not distinguish a broken network from an empty query.
        let failPrefix = en(.modelSearchFailedFormat).lowercased()
        let emptyEn = en(.modelSearchNoResults).lowercased()
        #expect(failPrefix.contains("failed"))
        #expect(emptyEn.contains("no models found"))
        #expect(
            !failPrefix.contains("no models found"),
            "failure wording must never fall back to empty-results wording")
    }

    @Test("both locale tables carry all three keys")
    func localizationComplete() {
        for key in [
            StringKey.modelSearchFailedFormat, .modelSearchFailedHFHint, .modelSearchFailedMSHint,
        ] {
            #expect(L10nTables.base[key] != nil, "\(key.rawValue) missing in en")
            #expect(L10nTables.zh[key] != nil, "\(key.rawValue) missing in zh")
        }
        #expect(L10nTables.base[.modelSearchFailedFormat]?.contains("%1$@") == true)
        #expect(L10nTables.zh[.modelSearchFailedFormat]?.contains("%1$@") == true)
    }
}
