// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatFailureFaceTests — which banner an engine refusal earns in the GUI.
///
/// Sampled against the red this file was written for, read in `ChatViewModel.swift`'s catch before
/// this change: only `.modelNotFound` had a face, so `AppError.modelLoading` — the 503 the engine
/// answers while a cold load runs, 794 s for the shipping default (CHANGELOG 11-01(101)) — fell
/// through to "Generation failed" with Retry as the only exit. The reader whose action it changes:
/// whoever pressed send on a cold machine, was told the turn had failed 120 s in, and had no way to
/// learn that `OcoreaiDownloadProgress` was already counting bytes in — the same store
/// `ModelView.swift:355` draws a bar from.
///
/// Asserted as the exact string the banner renders in each delivered table, plus the flag
/// `InferenceErrorOverlay` branches on. No engine, no Metal, no window: the mapping is
/// `ChatState.failureFace`, and the state a user ends up reading is `ChatState.presentFailure`.

import Testing

@testable import ocoreai

/// A failure the mapping has no face for — what any foreign `Error` looks like at the seam.
private struct unrelatedError: Error {}

/// Byte-exact copy per delivered table. A count of locales would pass while one table
/// rendered the wrong face, so each table is traversed by name.
private let loadingCopy: [(locale: OCALocale, copy: String)] = [
    (.en, "Model is still loading"),
    (.zhHans, "模型仍在加载中"),
]

@Suite("Chat failure faces — the banner a refusal earns")
struct ChatFailureFaceTests {

    /// A cold load is the `loading` state of the five non-happy faces (`UI/AGENTS.md`), not a
    /// failure: the refusal carries what the wait measured, so the banner names the wait and
    /// stays out of the way of the numbers.
    @Test(arguments: loadingCopy)
    func coldLoadSaysTheWaitInItsOwnTable(locale: OCALocale, copy: String) {
        let face = ChatState.failureFace(
            for: AppError.modelLoading("test/model", nil), locale: locale)
        #expect(face.message == copy)
        // The way out is the Models page — where the bar reads the measurement the 503 carried.
        #expect(face.offersModels)
        #expect(face.message != StringKey.generationFailed.localized(for: locale))
        // And it makes no promise about a transfer: `downloading` is false for the map/specialize/
        // warm window (`ModelLoadProgress.measure`), where nothing is being fetched at all.
        #expect(!face.message.lowercased().contains("download"))
        #expect(!face.message.contains("下载"))
    }

    /// The GUI hands the numbers over rather than repeating them: a second spelling of the
    /// disclosure sentence in two tables is one more home for a wording
    /// `ModelLoadProgress.disclosureLine` exists to keep in one place. So the measured and the
    /// unmeasured wait render identically here — and differ, byte for byte, on the wire.
    @Test("a measured wait does not grow a second sentence in the GUI")
    func measuredWaitRendersTheSameFace() {
        let measured = ModelLoadProgress(
            elapsedSeconds: 41, downloading: true, bytesDownload: 1000, bytesTotal: 4000,
            bytesPerSecond: 100, secondsRemainingEstimate: 30)
        for locale in OCALocale.availableLocales {
            let bare = ChatState.failureFace(
                for: AppError.modelLoading("test/model", nil), locale: locale)
            let withNumbers = ChatState.failureFace(
                for: AppError.modelLoading("test/model", measured), locale: locale)
            #expect(withNumbers.message == bare.message)
        }
    }

    /// The two load faces cannot share a sentence: "download one" is false advice while the
    /// weights are landing, and the missing-model copy is the one place the GUI may say it.
    @Test("a missing model keeps its own dead-end copy")
    func missingModelKeepsItsOwnFace() {
        for locale in OCALocale.availableLocales {
            let missing = ChatState.failureFace(
                for: AppError.modelNotFound("test/model"), locale: locale)
            #expect(missing.message == StringKey.modelNotReadyTitle.localized(for: locale))
            #expect(missing.offersModels)
            let loading = ChatState.failureFace(
                for: AppError.modelLoading("test/model", nil), locale: locale)
            #expect(missing.message != loading.message)
        }
    }

    /// Everything else keeps the banner it has always had, with no route attached — the face the
    /// cold load used to wear.
    @Test("every other refusal stays generic and un-routed")
    func otherFailuresStayGeneric() {
        let others: [Error] = [
            AppError.inferenceFailed("boom"),
            AppError.engineUnavailable,
            AppError.memoryExhausted(usedGB: 9, budgetGB: 8),
            unrelatedError(),
        ]
        for locale in OCALocale.availableLocales {
            for error in others {
                let face = ChatState.failureFace(for: error, locale: locale)
                #expect(face.message == StringKey.generationFailed.localized(for: locale))
                #expect(!face.offersModels)
            }
        }
    }

    /// The state a user actually reads, at the seam the catch site calls: the affordance is
    /// re-decided per failure, and a half-streamed answer never survives the banner as a reply.
    @Test("the banner the catch site leaves on screen")
    @MainActor
    func presentFailureSetsTheVisibleState() {
        let state = ChatState()
        state.resetForTesting()
        state.responseText = "half a token stream"
        // Start from a stale route to prove the next face decides it, not the last one.
        state.modelNotReady = true

        state.presentFailure(AppError.modelLoading("test/model", nil))
        // Which key rendered is the claim here; the copy itself is pinned in each table above.
        #expect(state.errorMessage == StringKey.modelLoadingTitle.l)
        #expect(state.modelNotReady)
        #expect(state.responseText.isEmpty, "an unfinished stream is not a reply to keep")

        state.presentFailure(AppError.inferenceFailed("boom"))
        #expect(state.errorMessage == StringKey.generationFailed.l)
        #expect(!state.modelNotReady, "the Models route must not bleed into an unrelated failure")

        state.resetForTesting()
    }
}
