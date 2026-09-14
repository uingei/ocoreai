// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Session Manager — bridges SessionCompressor with SwiftUI

import Foundation
import Logging
import Observation

@Observable
@MainActor
final class SessionManager {
    /// Shared singleton — survives view recreation (tab switch, NavigationSplitView).
    static let shared = SessionManager()
    private init() {}

    // MARK: - Session data

    private(set) var sessions: [SessionModel] = []
    private(set) var selectedSession: SessionModel?
    private(set) var sessionSummary: String?

    // MARK: - Memory data

    private(set) var memoryEvents: [MemoryEvent] = []
    private(set) var memorySearchResults: [MemoryEvent] = []

    // MARK: - UI state

    var searchQuery: String = ""
    var memorySearchQuery: String = ""
    var isLoading: Bool = false
    var errorMessage: String?

    // MARK: - Engine access
    private var compressor: SessionCompressor? {
        OcoreaiEngine.shared.activeSessionCompressor
    }

    /// Summary fetch task — cancel on rapid switch to prevent stale summary overwriting.
    private var _summaryTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func load() async {
        guard let compressor else {
            errorMessage = StringKey.sessionCompressorUnavailable.l
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            sessions = try await compressor.listSessions(limit: 200)
            // P8: auto-restore previously selected session
            restoreLastSelectedSession()
        } catch {
            errorMessage = StringKey.sessionLoadFailed.l
        }
    }

    func selectSession(_ session: SessionModel) {
        selectedSession = session
        // P8: persist selected session ID for restore on next app launch
        SettingsStore.shared.lastSessionId = session.id
        // Clear stale error when user selects a session
        errorMessage = nil
        // Cancel previous summary fetch — rapid session switching would otherwise
        // let stale results overwrite the current session's summary.
        _summaryTask?.cancel()
        _summaryTask = Task { @MainActor [weak self] in
            guard let self, let compressor else { return }
            do {
                sessionSummary = try await compressor.getSessionSummary(session.id)
            } catch {
                sessionSummary = nil
                self.errorMessage = StringKey.sessionSummaryLoadFailed.l
            }
        }
    }

    func deleteSession(_ session: SessionModel) async {
        guard let compressor else { return }
        do {
            try await compressor.deleteSession(session.id)
            sessions.removeAll { $0.id == session.id }
            if selectedSession?.id == session.id {
                selectedSession = nil
                sessionSummary = nil
                // P8: clear persisted selection if deleted session was the last selected
                if SettingsStore.shared.lastSessionId == session.id {
                    SettingsStore.shared.lastSessionId = nil
                }
            }
        } catch {
            errorMessage = StringKey.sessionDeleteFailed.l
        }
    }

    // MARK: - Worktree session (codex Agent axis)

    /// Create a new blank session bound to a git worktree of the configured
    /// workspace (codex `new_worktree` / `worktree_startup`: cached default branch,
    /// no fetch, blank session bound to the new tree; retain the checkout + report
    /// the path on failure so it can be `git worktree remove`d by hand). On success
    /// the worktree is bound to the active session, selected, and the chat tab is
    /// reloaded into the blank session so `exec_command` / file tools land there.
    func createWorktreeSession() async {
        guard let compressor else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Source repo = configured workspace directory (else the server cwd).
            let source = WorkspaceContext.configuredDirectory()
            let created = try await SessionWorkspace.createWorktreeSession(repoRoot: source)
            // Blank session bound to the new worktree (codex: no initial turn).
            let modelId =
                OcoreaiEngine.shared.activeEnginePool?.config.defaultModelId ?? "default"
            let newId = try await compressor.createSession(modelId: modelId)
            // Bind the new (blank) session to the worktree; promote + select.
            if let fresh = try await compressor.getSession(newId) {
                sessions.removeAll { $0.id == newId }
                sessions.insert(fresh, at: 0)
                selectedSession = fresh
            }
            SessionWorkspace.setDirectory(created.root)
            let m = selectedSession
            Task { @MainActor in
                if let m { await ChatState.shared.reloadSession(for: m) }
            }
        } catch let SessionWorkspace.WorktreeError.notARepository(path) {
            errorMessage = String(format: StringKey.worktreeNotRepo.l, path)
        } catch let SessionWorkspace.WorktreeError.noDefaultBranch(path) {
            errorMessage = String(format: StringKey.worktreeNoBranch.l, path)
        } catch let SessionWorkspace.WorktreeError.gitFailed(step, detail) {
            errorMessage = String(format: StringKey.worktreeGitFailed.l, step, detail)
        } catch {
            errorMessage = StringKey.worktreeCreateFailed.l
        }
    }

    // MARK: - Memory

    func searchMemory(_ query: String) async {
        guard let compressor, !query.isEmpty else { return }
        do {
            memorySearchResults = try await compressor.searchMemoryEvents(query: query, limit: 50)
        } catch {
            memorySearchResults = []
            errorMessage = StringKey.memorySearchFailed.l
        }
    }

    func loadMemoryForSession(_ session: SessionModel) async {
        guard let compressor else { return }
        do {
            memoryEvents = try await compressor.searchMemoryEvents(
                query: session.modelId,
                sessionId: session.id,
                limit: 30,
            )
        } catch {
            memoryEvents = []
            errorMessage = StringKey.memoryLoadFailed.l
        }
    }

    // MARK: - Search sessions

    func searchSessions(_ query: String) -> [SessionModel] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.modelId.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Session Restore

    /// P8: Auto-restore the previously selected session after listSessions loads.
    /// Selects the persisted session if it still exists and reloads its messages
    /// into ChatState so the chat tab is ready on app launch.
    private func restoreLastSelectedSession() {
        guard let persistedId = SettingsStore.shared.lastSessionId else { return }
        guard let session = sessions.first(where: { $0.id == persistedId }) else {
            // Persisted session was deleted or expired — clean up
            SettingsStore.shared.lastSessionId = nil
            return
        }
        selectedSession = session
        // Load messages into ChatState synchronously so the chat tab has content
        Task { @MainActor in
            await ChatState.shared.reloadSession(for: session)
        }
    }
}
