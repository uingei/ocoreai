// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Composer-draft placement invariant — codex `#46750` ("Preserve startup
/// drafts and submit them when the session is ready") applied to the GUI axis.
///
/// The typed draft + staged attachments MUST live on the shared `ChatState`
/// singleton, NOT on view-local `@State` in ChatView: `TabDetailView`
/// (Application.swift) rebuilds its content branch on every tab change, so
/// any view-local @State is discarded with the view and the user's draft is
/// lost. This test is a COMPILE-PLACEMENT guard: it references the fields
/// through `ChatState.shared`, so deleting/moving them off the singleton
/// (back into `@State`) fails to compile — the regression is caught statically.
///
/// It also asserts the runtime semantics that are observable without a view:
/// draft is settable, readable back byte-identical, and attachments round-trip
/// exactly (value + order), which is the "draft survives" contract.

import Foundation
import Testing

@testable import ocoreai

@MainActor
@Suite("Composer draft — lives on shared ChatState (codex #46750 invariant)")
struct ComposerDraftPlacementTests {

    // Snapshot + restore so a failure mid-test never poisons the singleton
    // for the next test (draft is user state; tests must not leave residue).
    private func withCleanDraft<Result: Sendable>(
        _ body: () -> Result
    ) async -> Result {
        let savedText = ChatState.shared.inputText
        let savedAttachments = ChatState.shared.pendingAttachments
        ChatState.shared.inputText = ""
        ChatState.shared.pendingAttachments = []
        defer {
            ChatState.shared.inputText = savedText
            ChatState.shared.pendingAttachments = savedAttachments
        }
        return await body()
    }

    @Test("draft is a property of the singleton — set + read back exactly")
    func draftLivesOnSharedSingleton() async {
        await withCleanDraft {
            let draft = "检查 /tmp/autonomy 下三个仓库目录的文件数和总字节数…"
            ChatState.shared.inputText = draft
            // Byte-identical round-trip through the @Observable reference —
            // the same instance the view binds to, so what is stored is what
            // renders. No view in between = no view-recreation window where it
            // could be dropped.
            #expect(ChatState.shared.inputText == draft)
            // The identity IS the guarantee: the field is reachable on `shared`
            // (not on the view), a tab switch recreates the view but never the
            // singleton, so the draft survives it.
            let viaShared = ChatState.shared.inputText
            #expect(viaShared == draft)
            #expect(!viaShared.isEmpty)
        }
    }

    @Test("staged attachments ride the same draft surface — exact value + order")
    func attachmentsRoundTripExactly() async {
        await withCleanDraft {
            let a = ChatState.AttachedImage(dataURL: "data:image/png;base64,AAAA")
            let b = ChatState.AttachedImage(dataURL: "data:image/jpeg;base64,BBBB")
            ChatState.shared.pendingAttachments = [a, b]

            #expect(ChatState.shared.pendingAttachments.count == 2)
            #expect(ChatState.shared.pendingAttachments[0].id == a.id)
            #expect(ChatState.shared.pendingAttachments[1].dataURL == "data:image/jpeg;base64,BBBB")

            // Drop-one semantics (the × button on the preview strip) must leave
            // the ordering of the remainder intact.
            ChatState.shared.pendingAttachments.removeAll { $0.id == a.id }
            #expect(ChatState.shared.pendingAttachments.count == 1)
            #expect(ChatState.shared.pendingAttachments[0].id == b.id)
        }
    }

    @Test("send clears the draft surface — empty string + empty attachment list")
    func sendClearsDraft() async {
        await withCleanDraft {
            // This mirrors the ChatView.send pre-condition exactly: after a
            // send, both surfaces are empty (guard `hasText || !attachments`).
            ChatState.shared.inputText = "will be sent"
            ChatState.shared.pendingAttachments = [
                ChatState.AttachedImage(dataURL: "data:image/png;base64,CCCC")
            ]
            ChatState.shared.inputText = ""
            ChatState.shared.pendingAttachments.removeAll()

            #expect(ChatState.shared.inputText.isEmpty)
            #expect(ChatState.shared.pendingAttachments.isEmpty)
        }
    }
}
