// Copyright © 2026 uingeai.
// Licensed under MIT.
/// ModelManagerTests.swift — Behavioral tests against real ModelManager.
///
/// Extracted from RealStateTests which was merged into ChatStateSessionTests.
/// Tests the search-state rules (an emptied query, a hub switch), isDownloading, modelIdStrings.

import Foundation
import Testing

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

    private func hf(_ id: String = "mlx-community/Test-4bit") -> HFHubModel {
        HFHubModel(
            id: id, displayName: "Test-4bit", tags: ["mlx"], likes: 0,
            pipelineTag: nil, lastModified: nil, downloads: nil, sizeBytes: nil)
    }

    private func ms(_ path: String = "Qwen/Test-Instruct") -> MSHubModel {
        MSHubModel(
            id: 1, path: path, displayName: "Test-Instruct", chineseName: nil, downloads: 0,
            stars: 0, tasks: ["text-generation"], frameworks: [], description: nil,
            modelType: [], license: nil, storageSize: nil, createdTime: nil, isHot: false)
    }

    @MainActor @Test("an emptied query drops the results and the error it produced")
    func empties() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.searchQuery = "llama"
        m.hfResults = [hf()]
        m.msResults = [ms()]
        m.currentError = .noResults
        m.searchQuery = ""
        #expect(m.searchQuery.isEmpty)
        #expect(m.hfResults.isEmpty)
        #expect(m.msResults.isEmpty)
        #expect(m.currentError == nil)
    }

    @MainActor @Test("typing on keeps the list — emptiness, not change, is the trigger")
    func keepsWhileTyping() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.searchQuery = "llama"
        m.hfResults = [hf()]
        m.searchQuery = "llama 3.1"
        #expect(m.hfResults.count == 1)
    }

    @MainActor @Test("leaving a hub drops its list; the hub arrived at keeps its own")
    func switches() {
        let m = ModelManager.shared
        resetModel()
        defer { resetModel() }

        m.selectedSource = .huggingFace
        m.hfResults = [hf()]
        m.msResults = [ms()]
        m.selectedSource = .modelScope
        #expect(m.selectedSource == .modelScope)
        #expect(m.hfResults.isEmpty)
        #expect(m.msResults.count == 1)

        m.selectedSource = .huggingFace
        #expect(m.selectedSource == .huggingFace)
        #expect(m.msResults.isEmpty)
        // Arriving at HF does not resurrect the list dropped when HF was left.
        #expect(m.hfResults.isEmpty)
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
