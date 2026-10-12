// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProjectsView — Bionic-parity project container (CHANGELOG 4c1b4ad).
///
/// Mirrors the reference flow 1:1: name → "Allow coding" toggle → choose a
/// folder → Create; the open project shows its sessions (left) and a
/// Project Files listing that reads straight from the bound folder — the
/// folder IS the truth, there is no parallel file bookkeeping to drift.
/// Keyboard shortcuts + VoiceOver labels per Apple HIG; folder enumeration is
/// offloaded off the main actor (ProjectStore.files).
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct ProjectsView: View {
    @State private var store: ProjectStore = .shared
    @State private var showingNewProject = false
    @State private var projectToDelete: ProjectModel?
    @State private var projectFiles: [ProjectFileEntry] = []
    @State private var projectSessions: [SessionModel] = []

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        HSplitView {
            projectList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            detailPane
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .navigationTitle(StringKey.tabProjects.l)
        .task {
            await store.load()
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(store: store)
        }
        .alert(StringKey.tabProjects.l, isPresented: .constant(projectToDelete != nil)) {
            Button(StringKey.cancelButton.l, role: .cancel) { projectToDelete = nil }
            Button(StringKey.modelDeleteButton.l, role: .destructive) {
                if let project = projectToDelete {
                    Task {
                        await store.delete(project)
                        await refreshDetail()
                    }
                }
                projectToDelete = nil
            }
        } message: {
            Text(StringKey.projectDeleteConfirm.l)
        }
        // Refresh files/sessions whenever the open project changes.
        .onChange(of: store.selectedProject?.id) { _, _ in
            Task { await refreshDetail() }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewProject = true
                } label: {
                    Label(StringKey.projectNew.l, systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityHint(StringKey.projectNew.l)
            }
        }
        .overlay {
            if store.isLoading && store.projects.isEmpty {
                ProgressView(StringKey.loadingSessions.l)
            }
        }
    }

    // MARK: - Project list

    private var projectList: some View {
        List(
            selection: Binding(
                get: { store.selectedProject?.id },
                set: { id in
                    if let id {
                        store.select(store.projects.first { $0.id == id })
                    } else {
                        store.select(nil)
                    }
                }
            )
        ) {
            ForEach(store.projects) { project in
                HStack(spacing: 8) {
                    Image(systemName: project.allowCoding ? "folder" : "folder.badge.questionmark")
                        .foregroundStyle(theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.ocoreaiText(13, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(project.sessionCount) \(StringKey.projectSessions.l)")
                            if let folder = project.folderPath {
                                Text((folder as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                            } else {
                                Text(StringKey.projectNoFolder.l)
                            }
                        }
                        .font(.ocoreaiText(11))
                        .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .tag(project.id)
                .contextMenu {
                    Button {
                        showingNewProject = true
                    } label: {
                        Label(StringKey.projectNew.l, systemImage: "plus")
                    }
                    Button(role: .destructive) {
                        Task {
                            await store.delete(project)
                            await refreshDetail()
                        }
                    } label: {
                        Label(StringKey.modelDeleteButton.l, systemImage: "trash")
                    }
                }
            }
        }
        .navigationSubtitle("\(store.projects.count) \(StringKey.tabProjects.l)")
    }

    // MARK: - Detail: sessions + Project Files (Bionic right sidebar)

    @ViewBuilder private var detailPane: some View {
        if let project = store.selectedProject {
            List {
                Section(StringKey.projectSessions.l) {
                    if projectSessions.isEmpty {
                        Text(StringKey.projectNoFolder.l)
                            .foregroundStyle(theme.textTertiary)
                    }
                    ForEach(projectSessions, id: \.id) { session in
                        HStack {
                            Image(systemName: "bubble.right")
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.summary ?? session.modelId)
                                    .font(.ocoreaiText(13))
                                    .lineLimit(1)
                                Text(session.updatedAt, style: .relative)
                                    .font(.ocoreaiText(11))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section(StringKey.projectFiles.l) {
                    if project.folderPath == nil {
                        Text(StringKey.projectNoFolder.l)
                            .foregroundStyle(theme.textTertiary)
                    } else if projectFiles.isEmpty {
                        Text(StringKey.projectEmptyFiles.l)
                            .foregroundStyle(theme.textTertiary)
                    }
                    ForEach(projectFiles.prefix(100)) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isDirectory ? "folder" : docIcon(file.path))
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityHidden(true)
                            Text(file.relativePath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.modifiedAt, style: .relative)
                                .font(.ocoreaiText(11))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .task {
                await refreshDetail()
            }
            .refreshable {
                await refreshDetail()
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.plus")
                    .font(.ocoreaiText(44, weight: .light))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                Text(StringKey.projectNew.l)
                    .font(.ocoreaiText(18, weight: .medium))
                Text(StringKey.projectChooseFolder.l)
                    .font(.ocoreaiText(13))
                    .foregroundStyle(theme.textSecondary)
                Button(StringKey.projectNew.l) { showingNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func docIcon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "md", "txt": "doc.text"
        case "png", "jpg", "jpeg", "heic", "webp": "photo"
        case "json", "yaml", "yml", "toml": "curlybraces"
        default: "doc"
        }
    }

    private func refreshDetail() async {
        guard let project = store.selectedProject else {
            projectFiles = []
            projectSessions = []
            return
        }
        // Read both surfaces independently: a failed session query must never
        // empty the files listing (and vice versa) — no fabricated blanks.
        projectFiles = await store.files(in: project)
        projectSessions = (try? await store.sessions(in: project)) ?? []
    }
}

// MARK: - New project sheet (Bionic quick-start 1→4: name, Allow coding, folder)

struct NewProjectSheet: View {
    @Bindable var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var allowCoding = false
    @State private var folderPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(StringKey.projectNew.l)
                .font(.ocoreaiText(18, weight: .semibold))

            TextField(StringKey.projectNamePlaceholder.l, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)

            Toggle(isOn: $allowCoding) {
                Label(
                    StringKey.projectAllowCoding.l,
                    systemImage: "chevron.left.forwardslash.chevron.right")
            }

            if allowCoding {
                HStack {
                    Button(StringKey.projectChooseFolder.l) { pickFolder() }
                    if let folderPath {
                        Text((folderPath as NSString).abbreviatingWithTildeInPath)
                            .font(.ocoreaiText(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let err = store.errorMessage {
                Text(err)
                    .font(.ocoreaiText(12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(StringKey.cancelButton.l) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(StringKey.projectNew.l) {
                    Task {
                        let created = await store.create(
                            name: name, folderPath: allowCoding ? folderPath : nil,
                            allowCoding: allowCoding)
                        if created != nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (allowCoding && folderPath == nil))
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
        #endif
    }
}
