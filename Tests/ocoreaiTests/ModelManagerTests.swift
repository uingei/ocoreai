// Copyright © 2026 uingeai.
// Licensed under MIT.
/// ModelManagerTests.swift — Behavioral tests against real ModelManager.
///
/// Extracted from RealStateTests which was merged into ChatStateSessionTests.
/// Tests clearSearch, switchSource, isDownloading, and modelIdStrings.

import Testing
import Foundation
@testable import ocoreai

@Suite("ModelManager — real search state and convenience methods")
struct ModelManagerTests {

    @MainActor func resetModel() {
        let m = ModelManager.shared
        m.searchQuery = ""
        m.hfResults = []
        m.msResults = []
        m.isSearching = false
        m.isDownloading = false
        m.downloadingModelId = ""
        m.localModels = []
        m.servingModelIds = []
        m.currentError = nil
    }

    @MainActor @Test("clearSearch zeroes search query, results, and error")
    func clears() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.searchQuery = "llama"
        m.currentError = .noResults
        m.clearSearch()
        #expect(m.searchQuery.isEmpty)
        #expect(m.hfResults.isEmpty)
        #expect(m.msResults.isEmpty)
        #expect(m.currentError == nil)
    }

    @MainActor @Test("switchSource updates and clears opposite source")
    func switches() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.switchSource(to: .modelScope)
        #expect(m.selectedSource == .modelScope)
        m.switchSource(to: .huggingFace)
        #expect(m.selectedSource == .huggingFace)
        #expect(m.msResults.isEmpty)
    }

    @MainActor @Test("isDownloading checks per-model")
    func perModel() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.isDownloading = true
        m.downloadingModelId = "a"
        #expect(m.isDownloading("a"))
        #expect(!m.isDownloading("b"))
    }

    @MainActor @Test("modelIdStrings returns local model ids")
    func modelIds() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.localModels = [
            ModelID(id: "x", maxContext: 100, vocabSize: 32000, tokenizer: "t"),
            ModelID(id: "y", maxContext: 200, vocabSize: 32000, tokenizer: "t"),
        ]
        #expect(m.modelIdStrings() == ["x", "y"])
    }
}
