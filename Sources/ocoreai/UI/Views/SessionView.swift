// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Session View — session list, detail, memory search
/// Accessibility: VoiceOver labels, hints, groups

import SwiftUI

struct SessionView: View {
    @State private var viewModel: SessionManager = .shared
    @State private var showingDeleteAlert = false
    @State private var sessionToDelete: SessionModel?

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        Form {
            sessionListSection
            // B11: memory search always visible at bottom
            memorySearchSection
            if viewModel.selectedSession != nil {
                sessionDetailSection()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(StringKey.tabSessions.l)
        .overlay {
            Group {
                if viewModel.isLoading {
                    ProgressView(StringKey.loadingModels.l)
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .accessibilityLabel(StringKey.tabSessions.l)
        .alert(StringKey.sessionDelete.l, isPresented: $showingDeleteAlert) {
            Button(StringKey.sessionDelete.l, role: .destructive) {
                if let session = sessionToDelete {
                    Task { await viewModel.deleteSession(session) }
                }
            }
            Button(StringKey.cancelButton.l, role: .cancel) {}
        } message: {
            Text(StringKey.sessionDeleteConfirm.l)
        }
    }

    // MARK: - Session List

    private var sessionListSection: some View {
        Section {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(StringKey.sessionSearchPlaceholder.l, text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 8))

            if viewModel.sessions.isEmpty {
                ContentUnavailableView(
                    StringKey.sessionListEmpty.l,
                    systemImage: "text.page",
                    description: Text(StringKey.sessionSelectHint.l),
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.searchSessions(viewModel.searchQuery), id: \.id) { session in
                    Button {
                        viewModel.selectSession(session)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.modelId)
                                    .font(.ocoreaiText(15, weight: .medium))
                                    .foregroundStyle(theme.text)
                                Text(session.createdAt, style: .date)
                                    .font(.ocoreaiText(12))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Label(String(session.messageCount), systemImage: "text.bubble")
                                .font(.ocoreaiText(11))
                                .foregroundStyle(theme.accent)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(StringKey.sessionDelete.l, role: .destructive) {
                            sessionToDelete = session
                            showingDeleteAlert = true
                        }
                    }
                }
            }
        } header: {
            Text(StringKey.tabSessions.l)
        } footer: {
            EmptyView()
        }
    }

    // MARK: - Session Detail

    @ViewBuilder
    private func sessionDetailSection() -> some View {
        if let session = viewModel.selectedSession {
            Section {
                LabeledContent(StringKey.sessionModel.l) {
                    Text(session.modelId)
                }
                LabeledContent(StringKey.sessionCreatedAt.l) {
                    Text(session.createdAt, style: .date)
                }
                LabeledContent(StringKey.sessionMessageCount.l) {
                    Text(String(session.messageCount))
                }
                LabeledContent(StringKey.sessionTokenCount.l) {
                    Text(String(session.tokenCount))
                }

                if let summary = viewModel.sessionSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StringKey.sessionSummary.l)
                            .font(.ocoreaiText(12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Text(summary)
                            .font(.ocoreaiText(13))
                            .lineLimit(5)
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    Task { await viewModel.loadMemoryForSession(session) }
                } label: {
                    Label(StringKey.memoryTitle.l, systemImage: "brain.head.profile")
                }
            } header: {
                Text(StringKey.sessionSummary.l)
            } footer: {
                EmptyView()
            }
        }
    }

    // MARK: - Memory Search (B11)

    @ViewBuilder
    private var memorySearchSection: some View {
        Section(StringKey.memoryTitle.l) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.secondary)
                TextField(StringKey.memorySearchPlaceholder.l, text: $viewModel.memorySearchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await viewModel.searchMemory(viewModel.memorySearchQuery) }
                    }
            }
            .padding(8)
            .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 8))

            ForEach(viewModel.memorySearchResults, id: \.id) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.process)
                        .font(.ocoreaiText(13))
                        .lineLimit(3)
                    Text(event.context)
                        .font(.ocoreaiText(10))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
