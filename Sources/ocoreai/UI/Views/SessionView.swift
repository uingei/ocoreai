// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Session View — session list, detail, memory search

import SwiftUI

struct SessionView: View {
    @State private var viewModel = SessionManager()
    @State private var showingDeleteAlert = false
    @State private var sessionToDelete: SessionModel?

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        Form {
            sessionListSection
            if viewModel.selectedSession != nil {
                sessionDetailSection()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(StringKey.tabSessions.l)
        .overlay {
            if viewModel.isLoading {
                ProgressView(StringKey.loadingModels.l)
            }
        }
        .onAppear {
            Task { await viewModel.load() }
        }
        .alert(StringKey.sessionDelete.l, isPresented: $showingDeleteAlert) {
            Button(StringKey.sessionDelete.l, role: .destructive) {
                if let session = sessionToDelete {
                    Task { await viewModel.deleteSession(session) }
                }
            }
            Button(StringKey.tryAgain.l, role: .cancel) {}
        } message: {
            Text(StringKey.sessionDeleteConfirm.l)
        }
    }

    // MARK: - Session List

    @ViewBuilder
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
                    description: Text(StringKey.sessionSelectHint.l)
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.searchSessions(viewModel.searchQuery), id: \.id) { session in
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
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.selectSession(session) }
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
}
