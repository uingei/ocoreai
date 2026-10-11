// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ProjectStore — Bionic-parity project container tests: schema migrates on
/// an existing DB, CRUD round-trips, folder inheritance lands on sessions,
/// delete never destroys sessions, listing is bounded and never fabricated.

import Foundation
import Testing

@testable import ocoreai

private func tempDB() -> String {
    let path =
        (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "projects-test-\(UUID().uuidString).sqlite")
    return path
}

@Suite("ProjectStore — container CRUD")
struct ProjectStoreTests {

    @Test func schemaMigratesOnExistingDatabase() async throws {
        let path = tempDB()
        let store = SQLiteStore(path: path)
        try await store.open()
        defer { Task { await store.close() } }
        // projects table must exist after open() even on a brand-new DB,
        // and sessions must carry project_id (probe, don't assume).
        let cols = try await store.query("PRAGMA table_info(sessions);")
        #expect(cols.contains {
            if case .text(let n)? = $0["name"] { return n == "project_id" }
            return false
        })
        let t = try await store.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='projects';")
        #expect(!t.isEmpty)
    }

    @Test func insertAndListRoundTrip() async throws {
        let store = SQLiteStore(path: tempDB())
        try await store.open()
        defer { Task { await store.close() } }

        let p = try await ProjectStore.insert(
            store: store, name: "ocoreai", folderPath: "/tmp/ocoreai", allowCoding: true)
        #expect(p.id > 0)
        #expect(p.allowCoding)

        let list = try await ProjectStore.list(store: store)
        #expect(list.count == 1)
        #expect(list[0].name == "ocoreai")
        #expect(list[0].folderPath == "/tmp/ocoreai")
        #expect(list[0].sessionCount == 0)
    }

    @Test func assignSessionCountsAndInheritsFolder() async throws {
        let store = SQLiteStore(path: tempDB())
        try await store.open()
        defer { Task { await store.close() } }

        let p = try await ProjectStore.insert(
            store: store, name: "proj", folderPath: "/tmp/projroot", allowCoding: true)
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let sid = try await compressor.createSession(modelId: "test-model")
        try await compressor.bindWorkspace("/tmp/projroot", for: sid)
        try await ProjectStore.assignSession(
            store: store, sessionID: sid, projectID: p.id, folderPath: "/tmp/projroot")

        let listed = try await ProjectStore.list(store: store)
        #expect(listed[0].sessionCount == 1)

        let inProject = try await ProjectStore.sessions(store: store, projectID: p.id)
        #expect(inProject.count == 1)
        #expect(inProject[0].workspaceDirectory == "/tmp/projroot")
    }

    @Test func unfiledSessionsNeverLeakIntoProject() async throws {
        let store = SQLiteStore(path: tempDB())
        try await store.open()
        defer { Task { await store.close() } }

        let p = try await ProjectStore.insert(
            store: store, name: "proj", folderPath: nil, allowCoding: false)
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        _ = try await compressor.createSession(modelId: "m") // no project bind

        let inProject = try await ProjectStore.sessions(store: store, projectID: p.id)
        #expect(inProject.isEmpty)
    }

    @Test func deleteProjectKeepsSessionsUnfiled() async throws {
        let store = SQLiteStore(path: tempDB())
        try await store.open()
        defer { Task { await store.close() } }

        let p = try await ProjectStore.insert(
            store: store, name: "proj", folderPath: "/tmp/x", allowCoding: true)
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let sid = try await compressor.createSession(modelId: "m")
        try await ProjectStore.assignSession(
            store: store, sessionID: sid, projectID: p.id, folderPath: "/tmp/x")

        try await ProjectStore.deleteRow(store: store, projectID: p.id)

        // Container gone…
        let projects = try await ProjectStore.list(store: store)
        #expect(projects.isEmpty)
        // …session survives, unfiled (project_id NULL), not deleted.
        let orphans = try await store.query(
            "SELECT id FROM sessions WHERE project_id IS NULL;")
        #expect(orphans.count == 1)
    }

    @Test func listFilesSkipsNoiseDirsAndIsBounded() throws {
        let root = NSTemporaryDirectory() + "projfiles-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.git/objects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/node_modules/pkg", withIntermediateDirectories: true)
        try "hello".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try "code".write(toFile: root + "/src/main.swift", atomically: true, encoding: .utf8)

        let files = ProjectStore.listFiles(root: root)
        let rels = files.map(\.relativePath)
        #expect(rels.contains("README.md"))
        #expect(rels.contains("src/main.swift"))
        // Noise dirs must never surface (Bionic sidebar = signal, not flood).
        #expect(!rels.contains { $0.hasPrefix(".git") })
        #expect(!rels.contains { $0.hasPrefix("node_modules") })
        // Missing folder → empty, never a crash and never a fabricated list.
        #expect(ProjectStore.listFiles(root: root + "/nope").isEmpty)
        try? fm.removeItem(atPath: root)
    }
}
