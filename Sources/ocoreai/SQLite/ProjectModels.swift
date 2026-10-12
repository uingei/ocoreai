// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProjectModel / ProjectFileEntry — the Bionic-parity project container DTOs.
///
/// Bionic IA (observed on the reference app 2026-10-11, landed in 4c1b4ad):
/// "A project keeps
/// related sessions and files together. Create one project for work that
/// should share the same goal, source files, or codebase." ocoreai mirrors
/// that container exactly: project = name + bound folder (optional, opt-in
/// "Allow coding") + many sessions + produced files.
///
/// The bound folder is NOT decorative: sessions inside a project inherit it
/// as their `workspaceDirectory`, which `SessionWorkspace.currentDirectory()`
/// already feeds into `ExecTools.effectiveCwd` / `FileTools.resolve` — the
/// isolation is behavioral (proven chain), not a prompt line.
import Foundation

struct ProjectModel: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    /// Root folder of the codebase the agent may work in, or nil = no
    /// coding folder bound (chat/documents only — Bionic's "Allow coding"
    /// toggle maps directly onto this field).
    var folderPath: String?
    var allowCoding: Bool
    let createdAt: Date
    var updatedAt: Date
    /// Denormalized for the sidebar: session count per project (one JOIN).
    var sessionCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case folderPath = "folder_path"
        case allowCoding = "allow_coding"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sessionCount = "session_count"
    }
}

/// One entry of the Bionic "Project Files" sidebar: a file the agent (or the
/// user) placed inside the project folder. Produced files surface here
/// because the write/edit tools operate on `SessionWorkspace`'s directory,
/// which equals the project folder — no extra bookkeeping, no fabricated
/// metadata. `isOutput` distinguishes "changed recently" (agent's working
/// set) from the rest of the codebase, so the sidebar never floods.
struct ProjectFileEntry: Identifiable, Hashable, Sendable {
    let path: String  // absolute path (stable id)
    let relativePath: String  // display path relative to the project root
    let size: Int64
    let modifiedAt: Date
    let isDirectory: Bool

    var id: String {
        path
    }
}
