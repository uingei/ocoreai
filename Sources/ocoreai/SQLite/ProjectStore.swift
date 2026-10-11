// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProjectStore — the Bionic-parity project container store.
///
/// Bionic IA (docs/bionic/quick-start, verified 2026-10-11): "A project keeps
/// related sessions and files together" — projects own an opt-in coding
/// folder; sessions inherit it as their working directory (the verified
/// `SessionWorkspace.currentDirectory()` → `ExecTools.effectiveCwd` /
/// `FileTools.resolve` chain), and produced files surface in a Project Files
/// sidebar straight from the folder listing (no parallel bookkeeping to
/// drift — the folder IS the truth).
///
/// Wiring mirrors `PlanTaskStore` (App boot → `attach(store:)`, MainActor
/// observable UI read surface, static SQLite helpers for offline testing).
import Foundation
import Observation
import Logging

@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()

    /// Sidebar read surface, most recently used first.
    private(set) var projects: [ProjectModel] = []
    /// The open project (Bionic: the project whose sessions/files the UI shows).
    var selectedProject: ProjectModel?
    var isLoading: Bool = false
    var errorMessage: String?

    @ObservationIgnored private var backing: SQLiteStore?
    @ObservationIgnored private let logger = Logger(label: "ocoreai.projects")

    nonisolated init() {}

    /// App boot binding (same seam as PlanTaskStore). Unattached = reads and
    /// writes are skipped with a log, never silently fabricated.
    func attach(store: SQLiteStore) {
        backing = store
        logger.debug("project store attached")
    }

    // MARK: - Queries

    func load() async {
        guard let backing else {
            errorMessage = StringKey.sessionCompressorUnavailable.l
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await Self.list(store: backing)
        } catch {
            errorMessage = StringKey.sessionLoadFailed.l
        }
    }

    func select(_ project: ProjectModel?) {
        selectedProject = project
        errorMessage = nil
    }

    /// Sessions belonging to a project (project_id equality — the container
    /// JOIN; unfiled sessions keep project_id NULL and never leak in).
    func sessions(in project: ProjectModel) async throws -> [SessionModel] {
        guard let backing else { return [] }
        return try await Self.sessions(store: backing, projectID: project.id)
    }

    // MARK: - Mutations

    /// Create a project. `allowCoding` is only honored with a folder bound —
    /// Bionic's flow exactly: the toggle precedes the folder pick, a coding
    /// project without a folder would promise work with no place to work.
    @discardableResult
    func create(
        name: String, folderPath: String?, allowCoding: Bool
    ) async -> ProjectModel? {
        guard let backing else {
            errorMessage = StringKey.sessionCompressorUnavailable.l
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = StringKey.projectNameRequired.l
            return nil
        }
        let coding = allowCoding && folderPath != nil
        do {
            let project = try await Self.insert(
                store: backing, name: trimmed, folderPath: folderPath, allowCoding: coding)
            projects.insert(project, at: 0)
            selectedProject = project
            return project
        } catch {
            errorMessage = StringKey.projectCreateFailed.l
            return nil
        }
    }

    /// Delete a project container. Its sessions are NOT deleted (they revert
    /// to unfiled — deleting a folder never silently destroys chat history);
    /// the bound folder on disk is never touched.
    func delete(_ project: ProjectModel) async {
        guard let backing else { return }
        do {
            try await Self.deleteRow(store: backing, projectID: project.id)
            projects.removeAll { $0.id == project.id }
            if selectedProject?.id == project.id { selectedProject = nil }
        } catch {
            errorMessage = StringKey.projectDeleteFailed.l
        }
    }

    /// Bind a new session into the project and inherit its folder (the one
    /// line that makes the container real: `workspace_directory` lands in
    /// `ExecTools.effectiveCwd` / `FileTools.resolve` via SessionWorkspace).
    func addSession(_ sessionID: Int64, to project: ProjectModel) async {
        guard let backing else { return }
        do {
            try await Self.assignSession(
                store: backing, sessionID: sessionID, projectID: project.id,
                folderPath: project.allowCoding ? project.folderPath : nil)
        } catch {
            logger.warning("project session bind failed: \(error)")
        }
    }

    /// Project Files sidebar listing (Bionic: "Files Bionic creates appear in
    /// the right sidebar under Project Files"). Directory enumeration runs
    /// detached — never on the main actor — with bounded depth/count so a
    /// huge checkout cannot flood the UI or the main thread.
    func files(in project: ProjectModel) async -> [ProjectFileEntry] {
        guard let folder = project.folderPath else { return [] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Self.listFiles(root: folder))
            }
        }
    }

    // MARK: - SQLite (static, offline-testable)

    nonisolated static func insert(
        store: SQLiteStore, name: String, folderPath: String?, allowCoding: Bool
    ) async throws -> ProjectModel {
        let now = Date().timeIntervalSince1970
        if let folderPath {
            try await store.execute(
                sql: """
                    INSERT INTO projects (name, folder_path, allow_coding, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                parameters: [
                    name as AnyHashable, folderPath as AnyHashable, allowCoding ? 1 : 0
                ] + [now as AnyHashable, now as AnyHashable])
        } else {
            try await store.execute(
                sql: """
                    INSERT INTO projects (name, folder_path, allow_coding, created_at, updated_at)
                    VALUES (?, NULL, 0, ?, ?)
                    """,
                parameters: [name as AnyHashable, now as AnyHashable, now as AnyHashable])
        }
        let rowID = try await store.scalarQuery(sql: "SELECT last_insert_rowid();")
        guard case .integer(let id)? = rowID else {
            throw SQLiteError.queryFailed(detail: "projects insert returned no rowid")
        }
        return ProjectModel(
            id: id, name: name, folderPath: folderPath, allowCoding: allowCoding,
            createdAt: Date(timeIntervalSince1970: now),
            updatedAt: Date(timeIntervalSince1970: now), sessionCount: 0)
    }

    nonisolated static func list(store: SQLiteStore) async throws -> [ProjectModel] {
        let rows = try await store.query(
            """
            SELECT p.id, p.name, p.folder_path, p.allow_coding, p.created_at, p.updated_at,
                   (SELECT COUNT(*) FROM sessions s WHERE s.project_id = p.id) AS session_count
            FROM projects p
            ORDER BY p.updated_at DESC LIMIT 200
            """)
        return rows.compactMap { row -> ProjectModel? in
            guard
                case .integer(let id)? = row["id"],
                case .text(let name)? = row["name"],
                case .float(let createdAt)? = row["created_at"],
                case .float(let updatedAt)? = row["updated_at"]
            else { return nil }
            let folder: String? = {
                if case .text(let f)? = row["folder_path"] { return f }
                return nil
            }()
            let coding: Bool = {
                if case .integer(let c)? = row["allow_coding"] { return c != 0 }
                return false
            }()
            var count = 0
            if case .integer(let c)? = row["session_count"] { count = Int(c) }
            return ProjectModel(
                id: id, name: name, folderPath: folder, allowCoding: coding,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt), sessionCount: count)
        }
    }

    nonisolated static func sessions(
        store: SQLiteStore, projectID: Int64
    ) async throws -> [SessionModel] {
        try await store.query(
            """
            SELECT id, model_id, created_at, updated_at, message_count, token_count, summary,
                   ttl_days, workspace_directory
            FROM sessions WHERE project_id = ?
            ORDER BY updated_at DESC LIMIT 100
            """,
            parameters: [projectID as AnyHashable])
            .compactMap(Self.session(from:))
    }

    nonisolated static func session(from row: [String: SendableValue]) -> SessionModel? {
        // MUST match SessionModel.init(from:) (SessionCompressor.swift:1121):
        // sessions timestamps are written as INTEGER microseconds — a .float
        // guard here silently drops every row (verified by raw probe).
        guard
            let id = row["id"]?.asInt64,
            let modelId = row["model_id"]?.asString,
            let createdAtTs = row["created_at"]?.asInt64,
            let updatedAtTs = row["updated_at"]?.asInt64
        else { return nil }
        return SessionModel(
            id: id, modelId: modelId,
            createdAt: Date(timeIntervalSince1970: Double(createdAtTs) / 1_000_000),
            updatedAt: Date(timeIntervalSince1970: Double(updatedAtTs) / 1_000_000),
            messageCount: row["message_count"]?.asInt64.map(Int.init) ?? 0,
            tokenCount: row["token_count"]?.asInt64.map(Int.init) ?? 0,
            summary: row["summary"]?.asString,
            ttlDays: row["ttl_days"]?.asInt64.map(Int.init) ?? 180,
            workspaceDirectory: row["workspace_directory"]?.asString)
    }

    nonisolated static func deleteRow(store: SQLiteStore, projectID: Int64) async throws {
        // Unfile the sessions first, then drop the container row — sessions
        // survive as ordinary (unfiled) sessions, never silently deleted.
        try await store.execute(
            sql: "UPDATE sessions SET project_id = NULL WHERE project_id = ?;",
            parameters: [projectID as AnyHashable])
        try await store.execute(
            sql: "DELETE FROM projects WHERE id = ?;",
            parameters: [projectID as AnyHashable])
    }

    nonisolated static func assignSession(
        store: SQLiteStore, sessionID: Int64, projectID: Int64, folderPath: String?
    ) async throws {
        // Optional-free bindings (PlanTaskStore idiom): the [AnyHashable]
        // bind surface has no nil semantics — NULL goes through literal SQL.
        if let folderPath {
            try await store.execute(
                sql:
                    "UPDATE sessions SET project_id = ?, workspace_directory = ? WHERE id = ?;",
                parameters: [
                    projectID as AnyHashable, folderPath as AnyHashable,
                    sessionID as AnyHashable,
                ])
        } else {
            try await store.execute(
                sql: "UPDATE sessions SET project_id = ? WHERE id = ?;",
                parameters: [projectID as AnyHashable, sessionID as AnyHashable])
        }
    }

    // MARK: - File listing (background queue, bounded)

    /// Bounded one-level-below-root listing: skip dotfiles, cap depth/entries,
    /// sort by modified desc. The folder listing IS the Project Files truth —
    /// anything the agent wrote shows up here because it wrote into this folder.
    nonisolated static func listFiles(
        root: String, maxDepth: Int = 3, maxEntries: Int = 300
    ) -> [ProjectFileEntry] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        guard fm.fileExists(atPath: root) else { return [] }
        var out: [ProjectFileEntry] = []
        guard
            let en = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        // Canonicalize BOTH sides: the enumerator returns /private/var/… while
        // the caller's root is /var/… — resolving symlinks on both makes the
        // prefix math exact (root-cause probe: raw hasPrefix was false for
        // every entry, which silently disabled the noise filter below).
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in en {
            let fullPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard fullPath.hasPrefix(rootPath) else { continue }
            let rel = String(fullPath.dropFirst(rootPath.count + 1))
            // Heavy dev dirs: flooding the sidebar with noise is anti-pattern.
            let top = rel.split(separator: "/").first.map(String.init) ?? rel
            if [".git", "node_modules", ".build", "build", "DerivedData", "dist", "__pycache__"]
                .contains(top)
            {
                en.skipDescendants()
                continue
            }
            let depth = rel.split(separator: "/").count
            if depth > maxDepth {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    en.skipDescendants()
                }
                continue
            }
            let vals = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            out.append(
                ProjectFileEntry(
                    path: url.path,
                    relativePath: rel,
                    size: Int64(vals?.fileSize ?? 0),
                    modifiedAt: vals?.contentModificationDate ?? .distantPast,
                    isDirectory: vals?.isDirectory ?? false))
            if out.count >= maxEntries { break }
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
