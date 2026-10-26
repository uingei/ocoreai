// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SQLiteOpenBusyTimeoutTests.swift — `open()` must wait out another connection, and a WAL
/// truncation it could not perform must be reported rather than called a success.
///
/// Why the ladder order is the bug: `PRAGMA busy_timeout` used to be the fourth statement in
/// `SQLiteStore.open()`, so every pragma above it ran under SQLite's default 0 ms timeout.
/// Measured 10-20 against macOS' system libsqlite3 (two connections on one file; the writer holds
/// `BEGIN IMMEDIATE` and commits 300 ms later):
///   * `PRAGMA wal_checkpoint(TRUNCATE)` answers `busy=1 log=2` in ~4 ms and leaves the WAL to
///     grow — and because it reports contention in **column 0 of a returned row** instead of as an
///     error code, `exec` (which accepts SQLITE_ROW) called the skipped truncation a success.
///     With `busy_timeout` first, the same call waits for the writer and truncates: `busy=0`.
///   * `journal_mode=WAL` on an already-WAL database (the steady state) is a no-op row, so the
///     ordering above is what decides whether the startup truncation happens at all.
///
/// The premise floor is in the suite, not in a comment: `busy` has to be able to come back **true**
/// (the long-held-lock test drives it there by holding past the timeout), so deleting the column
/// read — or the ladder fix — turns this suite red instead of silently passing.
///
/// What this suite does NOT claim, stated because the measurement found it and the fix does not
/// paper over it: a database that is **not** in WAL mode refuses `journal_mode=WAL` with
/// SQLITE_BUSY *immediately* while another connection holds a transaction — the busy timeout does
/// not turn that refusal into a wait (measured 10-20, both `BEGIN IMMEDIATE` and the pragma vs.
/// `sqlite3_busy_timeout()` routes; `PRAGMA busy_timeout` reads back 5000 either way). That case
/// needs an external tool to have flipped the journal mode off WAL, and it ends in `failStartup`,
/// so it is registered as an owner decision in CHANGELOG 10-20(续21) rather than fixed by guesswork.

import Foundation
import Testing

@testable import ocoreai

@Suite("SQLiteStore open() — contention with another connection")
struct SQLiteOpenBusyTimeoutTests {

    /// The writer commits this long after `open()` starts: inside the 5 s timeout.
    private static let commitInsideTimeout: UInt64 = 300_000_000
    /// …and this long after: past the timeout, so the truncation must be reported as refused.
    private static let commitPastTimeout: UInt64 = 6_500_000_000

    private func dbPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_busy_\(UUID().uuidString.prefix(8)).sqlite").path
    }

    private func removeDB(_ path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
    }

    /// Opens a `BEGIN IMMEDIATE` transaction on `writer` and releases it `delay` ns from now.
    private func holdWriteLock(on writer: SQLiteStore, delay: UInt64) async throws
        -> Task<Void, any Error>
    {
        try await writer.execute(sql: "CREATE TABLE busy_probe(x INTEGER);")
        try await writer.execute(sql: "BEGIN IMMEDIATE;")
        try await writer.execute(sql: "INSERT INTO busy_probe VALUES (1);")
        return Task {
            try await Task.sleep(nanoseconds: delay)
            try await writer.execute(sql: "COMMIT;")
        }
    }

    @Test("uncontended open: WAL, timeout in force, checkpoint not busy")
    func uncontendedBaseline() async throws {
        let path = dbPath()
        defer { removeDB(path) }

        let store = SQLiteStore(path: path)
        let started = ContinuousClock.now
        try await store.open()
        let elapsed = started.duration(to: .now)

        #expect((try await store.scalarQuery(sql: "PRAGMA journal_mode;"))?.asString == "wal")
        #expect(
            (try await store.scalarQuery(sql: "PRAGMA busy_timeout;"))?.asInt64
                == Int64(SQLiteStore.walBusyTimeoutMilliseconds))
        let reported = await store.lastOpenWALCheckpoint
        #expect(reported?.busy == false)
        // Calibration for the contended test: an uncontended open does not wait for anybody.
        #expect(elapsed < .milliseconds(1000), "uncontended open took \(elapsed)")
        await store.close()
    }

    @Test("open() under a held write lock waits for the writer and truncates anyway")
    func openWaitsOutTheWriter() async throws {
        let path = dbPath()
        defer { removeDB(path) }

        let writer = SQLiteStore(path: path)
        try await writer.open()
        let commit = try await holdWriteLock(on: writer, delay: Self.commitInsideTimeout)

        let challenger = SQLiteStore(path: path)
        let started = ContinuousClock.now
        try await challenger.open()
        let elapsed = started.duration(to: .now)
        try await commit.value

        let reported = await challenger.lastOpenWALCheckpoint
        // Pre-fix this came back busy=true: the checkpoint was skipped in ~4 ms and nobody read it.
        #expect(reported?.busy == false, "truncation was refused — busy_timeout was not in force")
        #expect(
            elapsed >= .milliseconds(150),
            "open() did not wait for the writer at all (\(elapsed)) — the timeout ran after the pragma it guards"
        )
        await challenger.close()
        await writer.close()
    }

    @Test("a truncation the timeout could not win is reported, and open() still succeeds")
    func refusedTruncationIsReported() async throws {
        let path = dbPath()
        defer { removeDB(path) }

        let writer = SQLiteStore(path: path)
        try await writer.open()
        let commit = try await holdWriteLock(on: writer, delay: Self.commitPastTimeout)

        let challenger = SQLiteStore(path: path)
        let openedAt = ContinuousClock.now
        try await challenger.open()
        let waited = openedAt.duration(to: .now)
        try await commit.value

        let reported = await challenger.lastOpenWALCheckpoint
        // CI reproduces this red on both matrix legs and this host does not, and the job log
        // needs a token to read. So a failing run names the quantity that broke instead of
        // leaving a bare `busy == false` behind: `logPages` separates "sqlite refused the
        // truncation and nobody read it" from "there was nothing to truncate" — and only one
        // of those is a bug in `open()`. Tagged EVIDENCE so CI publishes the line.
        if reported?.busy != true {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path + "-wal")
            let walBytes = attrs?[.size] as? Int ?? -1
            let timeout = try? await challenger.scalarQuery(sql: "PRAGMA busy_timeout;")
            print(
                """
                EVIDENCE sqlite-open-busy: waited=\(waited) busy=\(String(describing: reported?.busy)) \
                logPages=\(String(describing: reported?.logPages)) \
                ckptPages=\(String(describing: reported?.checkpointedPages)) \
                busyTimeout=\(String(describing: timeout?.asInt64)) walBytes=\(walBytes)
                """
            )
        }
        #expect(
            reported?.busy == true, "the busy column was not read — contention would be swallowed")
        // A refused truncation is a degraded start, not a fatal one: SQLite auto-checkpoints later.
        #expect((try await challenger.scalarQuery(sql: "PRAGMA journal_mode;"))?.asString == "wal")
        await challenger.close()
        await writer.close()
    }
}
