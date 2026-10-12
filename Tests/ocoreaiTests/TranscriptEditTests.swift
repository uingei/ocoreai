// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Edit-and-resend (Bionic-parity recoverability): only the user's own messages
/// are editable, an empty edit never fires a turn, the abandoned branch drops
/// from the live transcript AND from SQLite, and a database holding fewer rows
/// than the transcript drops what exists without reaching further back.

import Foundation
import Testing

@testable import ocoreai

private func tempDB() -> String {
    (NSTemporaryDirectory() as NSString).appendingPathComponent(
        "transcript-edit-test-\(UUID().uuidString).sqlite")
}

// MARK: - Pure plan rules

@Suite("TranscriptEdit.plan — every rule by exact value")
struct TranscriptEditPlanTests {

    private let roles = ["user", "assistant", "user", "assistant"]

    @Test("editing the oldest message drops the entire transcript")
    func editOldestDropsEverything() {
        let plan = try? TranscriptEdit.plan(roles: roles, editing: 0, rawText: " rewrite ").get()
        #expect(plan?.index == 0)
        #expect(plan?.dropCount == 4)
        #expect(plan?.newText == "rewrite")
    }

    @Test("editing a middle message drops that turn and nothing earlier")
    func editMiddleDropsItsOwnTurn() {
        let plan = try? TranscriptEdit.plan(
            roles: roles, editing: 2, rawText: "second question, corrected"
        ).get()
        #expect(plan?.index == 2)
        #expect(plan?.dropCount == 2)
    }

    @Test("editing the last message drops exactly one item")
    func editLastDropsOne() {
        // Transcript ends on a user turn here — in `roles` above, index 3 is the
        // assistant's, and the rule under test is notUser rejection instead.
        let plan = try? TranscriptEdit.plan(
            roles: ["user", "assistant", "user"], editing: 2, rawText: "x"
        ).get()
        #expect(plan?.index == 2)
        #expect(plan?.dropCount == 1)
    }

    @Test("a single-turn transcript drops one")
    func editOnlyMessage() {
        let plan = try? TranscriptEdit.plan(roles: ["user"], editing: 0, rawText: "again").get()
        #expect(plan?.dropCount == 1)
        #expect(plan?.newText == "again")
    }

    @Test("the model's words are not editable")
    func assistantTargetIsRejected() {
        #expect(
            TranscriptEdit.plan(roles: roles, editing: 1, rawText: "not mine")
                == .failure(.notUser))
        #expect(
            TranscriptEdit.plan(roles: roles, editing: 3, rawText: "not mine")
                == .failure(.notUser))
    }

    @Test("an unresolved target is reported, never guessed")
    func unresolvedTargetIsNotFound() {
        #expect(
            TranscriptEdit.plan(roles: roles, editing: nil, rawText: "hi") == .failure(.notFound))
        #expect(
            TranscriptEdit.plan(roles: roles, editing: 4, rawText: "hi") == .failure(.notFound))
        #expect(
            TranscriptEdit.plan(roles: roles, editing: -1, rawText: "hi") == .failure(.notFound))
        #expect(
            TranscriptEdit.plan(roles: [], editing: 0, rawText: "hi") == .failure(.notFound))
    }

    @Test("whitespace is not content — a blank edit never fires a turn")
    func blankEditIsRejected() {
        #expect(
            TranscriptEdit.plan(roles: roles, editing: 0, rawText: "") == .failure(.emptyText))
        #expect(
            TranscriptEdit.plan(roles: roles, editing: 0, rawText: "   ")
                == .failure(.emptyText))
        #expect(
            TranscriptEdit.plan(roles: roles, editing: 0, rawText: "\n\t \n")
                == .failure(.emptyText))
    }

    @Test("outer whitespace trims; inner newlines survive")
    func innerStructureSurvivesTrim() {
        let plan = try? TranscriptEdit.plan(
            roles: roles, editing: 0, rawText: "\nline one\nline two\t\n"
        ).get()
        #expect(plan?.newText == "line one\nline two")
    }

    @Test("mirror to SQLite only when there is a session and something to drop")
    func mirrorPreconditions() {
        #expect(TranscriptEdit.shouldMirrorToStore(sessionId: 7, dropCount: 2) == true)
        #expect(TranscriptEdit.shouldMirrorToStore(sessionId: nil, dropCount: 2) == false)
        #expect(TranscriptEdit.shouldMirrorToStore(sessionId: 7, dropCount: 0) == false)
        #expect(TranscriptEdit.shouldMirrorToStore(sessionId: nil, dropCount: 0) == false)
    }
}

// MARK: - SQLite mirror

private func makeCompressor() async throws -> (SQLiteStore, SessionCompressor, Int64) {
    let store = SQLiteStore(path: tempDB())
    try await store.open()
    let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
    let sid = try await compressor.createSession(modelId: "test/model")
    return (store, compressor, sid)
}

private func contents(_ store: SQLiteStore, _ sid: Int64) async throws -> [String] {
    let rows = try await store.query(
        "SELECT content FROM messages WHERE session_id = ? ORDER BY id ASC", parameters: [sid])
    return rows.compactMap { row -> String? in
        if case .text(let s)? = row["content"] { return s }
        return nil
    }
}

@Suite("dropTranscriptTail — the abandoned branch leaves the database too")
struct DropTranscriptTailTests {

    @Test("dropping two removes the newest two and reports exactly two")
    func dropNewestTwo() async throws {
        let (store, compressor, sid) = try await makeCompressor()
        defer { Task { await store.close() } }
        for (role, text) in [
            ("user", "first question"), ("assistant", "first answer"),
            ("user", "second question"), ("assistant", "second answer"),
        ] {
            _ = try await compressor.addMessage(
                sessionId: sid, role: role, content: text, tokenCount: 4)
        }

        let dropped = try await compressor.dropTranscriptTail(sessionId: sid, count: 2)

        #expect(dropped == 2)
        #expect(try await compressor.countMessages(sid) == 2)
        #expect(try await contents(store, sid) == ["first question", "first answer"])
    }

    @Test("a shorter database drops what exists and reports the honest number")
    func dropBeyondEndIsBounded() async throws {
        let (store, compressor, sid) = try await makeCompressor()
        defer { Task { await store.close() } }
        _ = try await compressor.addMessage(
            sessionId: sid, role: "user", content: "only turn", tokenCount: 3)

        let dropped = try await compressor.dropTranscriptTail(sessionId: sid, count: 5)

        #expect(dropped == 1)
        #expect(try await compressor.countMessages(sid) == 0)
    }

    @Test("zero is a no-op, not a wipe")
    func dropZeroKeepsEverything() async throws {
        let (store, compressor, sid) = try await makeCompressor()
        defer { Task { await store.close() } }
        _ = try await compressor.addMessage(
            sessionId: sid, role: "user", content: "keep me", tokenCount: 3)
        _ = try await compressor.addMessage(
            sessionId: sid, role: "assistant", content: "kept too", tokenCount: 3)

        #expect(try await compressor.dropTranscriptTail(sessionId: sid, count: 0) == 0)
        #expect(try await compressor.countMessages(sid) == 2)
        #expect(try await contents(store, sid) == ["keep me", "kept too"])
    }

    @Test("the drop never reaches into another session")
    func dropIsSessionScoped() async throws {
        let (store, compressor, sidA) = try await makeCompressor()
        defer { Task { await store.close() } }
        let sidB = try await compressor.createSession(modelId: "test/other")
        for text in ["A keep", "A drop"] {
            _ = try await compressor.addMessage(
                sessionId: sidA, role: "user", content: text, tokenCount: 2)
        }
        for text in ["B keep 1", "B keep 2"] {
            _ = try await compressor.addMessage(
                sessionId: sidB, role: "user", content: text, tokenCount: 2)
        }

        #expect(try await compressor.dropTranscriptTail(sessionId: sidA, count: 1) == 1)
        #expect(try await contents(store, sidA) == ["A keep"])
        #expect(try await contents(store, sidB) == ["B keep 1", "B keep 2"])
    }

    @Test("an edited-out turn leaves no search ghost")
    func droppedTurnIsNotSearchable() async throws {
        let (store, compressor, sid) = try await makeCompressor()
        defer { Task { await store.close() } }
        _ = try await compressor.addMessage(
            sessionId: sid, role: "user", content: "keptinstruction", tokenCount: 3)
        _ = try await compressor.addMessage(
            sessionId: sid, role: "assistant", content: "wrongdirection", tokenCount: 3)

        #expect(try await compressor.dropTranscriptTail(sessionId: sid, count: 1) == 1)

        let ghosts = try await compressor.searchFTS5(
            query: "wrongdirection", sessionId: sid, limit: 10)
        #expect(ghosts.isEmpty)
        let hits = try await compressor.searchFTS5(
            query: "keptinstruction", sessionId: sid, limit: 10)
        #expect(hits.count == 1)
    }
}

// MARK: - Edit-mode state transitions

@Suite("ChatState edit mode — open, cancel, refuse")
struct ChatStateEditTests {

    @MainActor @Test("beginEdit targets a user message and preloads its text")
    func beginEditOnUserMessage() {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let user = ChatMessage(role: "user", content: "make it faster")
        s.messages = [user, ChatMessage(role: "assistant", content: "done")]

        s.beginEdit(id: user.id, text: user.content)

        #expect(s.editingMessageID == user.id)
        #expect(s.editingText == "make it faster")
    }

    @MainActor @Test("the model's message cannot be opened for editing")
    func beginEditOnAssistantIsIgnored() {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let assistant = ChatMessage(role: "assistant", content: "not yours to edit")
        s.messages = [ChatMessage(role: "user", content: "hi"), assistant]

        s.beginEdit(id: assistant.id, text: assistant.content)

        #expect(s.editingMessageID == nil)
        #expect(s.editingText.isEmpty)
    }

    @MainActor @Test("cancel leaves the transcript exactly as it was")
    func cancelEditChangesNothing() {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let user = ChatMessage(role: "user", content: "original wording")
        s.messages = [user]
        s.beginEdit(id: user.id, text: "half-typed correction")

        s.cancelEdit()

        #expect(s.editingMessageID == nil)
        #expect(s.editingText.isEmpty)
        #expect(s.messages.count == 1)
        #expect(s.messages[0].content == "original wording")
    }

    @MainActor @Test("a blank commit says why and destroys nothing")
    func blankCommitRefuses() async {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let user = ChatMessage(role: "user", content: "original wording")
        s.messages = [user]
        s.beginEdit(id: user.id, text: "   ")

        await s.commitEdit(of: user.id)

        #expect(s.errorMessage == StringKey.editNothingToSend.l)
        #expect(s.editingMessageID == user.id)
        #expect(s.messages.count == 1)
        #expect(s.messages[0].content == "original wording")
    }

    @MainActor @Test("a vanished target closes the editor without touching the transcript")
    func vanishedTargetClosesEditor() async {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let gone = UUID()
        s.messages = [ChatMessage(role: "user", content: "still here")]
        s.editingMessageID = gone
        s.editingText = "text for a message that no longer exists"

        await s.commitEdit(of: gone)

        #expect(s.editingMessageID == nil)
        #expect(s.messages.count == 1)
    }

    @MainActor @Test("opening another conversation closes a stale editor")
    func resetConversationClearsEditor() {
        let s = ChatState.shared
        defer { s.resetForTesting() }
        let user = ChatMessage(role: "user", content: "wording")
        s.messages = [user]
        s.beginEdit(id: user.id, text: "correction in progress")

        s.resetConversation()

        #expect(s.editingMessageID == nil)
        #expect(s.editingText.isEmpty)
    }
}
