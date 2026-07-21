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
        } catch {
            errorMessage = "\(StringKey.sessionLoadFailed.l): \(error.localizedDescription)"
        }
    }

    func selectSession(_ session: SessionModel) {
        selectedSession = session
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
                self.errorMessage = "\(StringKey.sessionSummaryLoadFailed.l): \(error.localizedDescription)"
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
            }
        } catch {
            errorMessage = "\(StringKey.sessionDeleteFailed.l): \(error.localizedDescription)"
        }
    }

    // MARK: - Memory

    func searchMemory(_ query: String) async {
        guard let compressor, !query.isEmpty else { return }
        do {
            memorySearchResults = try await compressor.searchMemoryEvents(query: query, limit: 50)
        } catch {
            memorySearchResults = []
            errorMessage = "\(StringKey.memorySearchFailed.l): \(error.localizedDescription)"
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
            errorMessage = "\(StringKey.memoryLoadFailed.l): \(error.localizedDescription)"
        }
    }

    // MARK: - Search sessions

    func searchSessions(_ query: String) -> [SessionModel] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.modelId.localizedCaseInsensitiveContains(query) }
    }
}
