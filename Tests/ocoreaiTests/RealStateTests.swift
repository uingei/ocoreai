// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Tests against real types — 真实代码的路径验证，不是自循环 fixture
import Testing
import Foundation
@testable import ocoreai

@MainActor
func _resetChat() {
  let s = ChatState.shared
  // undoReset FIRST to consume any pending snapshot (prevents cross-test pollution),
  // then clear all state to known defaults.
  s.undoReset()
  s.messages = []; s.responseText = ""; s.errorMessage = nil; s.loading = false
}

@MainActor
func _resetModel() {
  let m = ModelManager.shared
  m.searchQuery = ""; m.hfResults = []; m.msResults = []
  m.isSearching = false; m.isDownloading = false
  m.downloadingModelId = ""; m.localModels = []; m.currentError = nil
}

@Suite("ChatState — real singleton behavior")
struct RealChatStateTests {
  @MainActor @Test("cancelInference sets loading=false")
  func cancelSetsLoadingFalse() async {
    _resetChat()
    let s = ChatState.shared
    s.loading = true
    s.cancelInference()
    #expect(!s.loading)
    _resetChat()
  }

  @MainActor @Test("cancelInference preserves partial as interrupted message")
  func cancelPreservesPartial() async {
    _resetChat()
    let s = ChatState.shared
    s.responseText = "partial"
    s.cancelInference()
    #expect(s.messages.count == 1)
    let mm = try? s.messages.first
    #expect(mm?.role == "assistant")
    #expect((mm?.interrupted) == true)
    #expect(s.responseText == "")
    _resetChat()
  }

  @MainActor @Test("cancelInference with empty responseText adds nothing")
  func cancelNoPartial() async {
    _resetChat()
    let s = ChatState.shared
    s.messages.append(ChatMessage(role: "user", content: "hi"))
    s.responseText = ""
    s.cancelInference()
    #expect(s.messages.count == 1)
    _resetChat()
  }

  @MainActor @Test("double cancel is safe")
  func doubleCancel() async {
    _resetChat()
    let s = ChatState.shared
    s.cancelInference(); s.cancelInference()
    #expect(!s.loading && s.messages.isEmpty)
    _resetChat()
  }

  @MainActor @Test("resetConversation clears all state")
  func resetsAll() async {
    _resetChat()
    let s = ChatState.shared
    s.messages.append(ChatMessage(role: "user", content: "hi"))
    s.responseText = "x"; s.errorMessage = "e"
    s.resetConversation()
    #expect(s.messages.isEmpty && s.responseText == "" && s.errorMessage == nil)
    _resetChat()
  }

  @MainActor @Test("undoReset restores pre-reset snapshot exactly")
  func undoRestores() async {
    _resetChat()
    let s = ChatState.shared
    s.messages = [ChatMessage(role: "assistant", content: "done")]
    s.responseText = "r"; s.errorMessage = "e"
    s.resetConversation()
    #expect(s.messages.isEmpty)
    s.undoReset()
    let mm = try? s.messages.first
    #expect(mm?.content == "done")
    #expect(s.responseText == "r" && s.errorMessage == "e")
    _resetChat()
  }

  @MainActor @Test("hasUndo tracks snapshot availability")
  func hasUndo() async {
    _resetChat()
    let s = ChatState.shared
    s.messages = [ChatMessage(role: "user", content: "hi")]
    #expect(!s.hasUndo)
    s.resetConversation()
    #expect(s.hasUndo)
    s.undoReset()
    #expect(!s.hasUndo)
    _resetChat()
  }

  @MainActor @Test("onModelChanged calls cancelInference killing loading")
  func cancelsOnSwitch() async {
    _resetChat()
    let s = ChatState.shared
    s.loading = true; s.responseText = "x"
    s.onModelChanged(newModelId: "new")
    #expect(!s.loading)
    _resetChat()
  }

  @MainActor @Test("onModelChanged preserves message history")
  func preservesHistory() async {
    _resetChat()
    let s = ChatState.shared
    s.messages = [ChatMessage(role: "user", content: "Hi")]
    s.onModelChanged(newModelId: "new")
    #expect(s.messages.count == 1)
    _resetChat()
  }
}

@Suite("ModelManager — real search state")
struct RealModelSearchTests {
  @MainActor @Test("clearSearch zeroes search query, results, and error")
  func clears() async {
    _resetModel()
    let m = ModelManager.shared
    m.searchQuery = "llama"
    m.currentError = .noResults
    m.clearSearch()
    // clearSearch resets: searchQuery, hfResults, msResults, currentError
    // It does NOT reset isSearching (production fact, verified in ModelManager.swift:362)
    #expect(m.searchQuery.isEmpty
      && m.hfResults.isEmpty && m.msResults.isEmpty
      && m.currentError == nil)
    _resetModel()
  }

  @MainActor @Test("switchSource updates and clears opposite source")
  func switches() async {
    _resetModel()
    let m = ModelManager.shared
    m.switchSource(to: .modelScope)
    #expect(m.selectedSource == .modelScope)
    m.switchSource(to: .huggingFace)
    #expect(m.selectedSource == .huggingFace && m.msResults.isEmpty)
    _resetModel()
  }

  @MainActor @Test("isDownloading per-model check")
  func perModel() async {
    _resetModel()
    let m = ModelManager.shared
    m.isDownloading = true; m.downloadingModelId = "a"
    #expect(m.isDownloading("a"))
    #expect(!m.isDownloading("b"))
    _resetModel()
  }

  @MainActor @Test("modelIdStrings returns local model ids")
  func modelIds() async {
    _resetModel()
    let m = ModelManager.shared
    m.localModels = [
      ModelID(id: "x", maxContext: 100, tokenizer: "t"),
      ModelID(id: "y", maxContext: 200, tokenizer: "t")
    ]
    #expect(m.modelIdStrings() == ["x", "y"])
    _resetModel()
  }
}
