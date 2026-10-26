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
    ///
    /// The margin is arithmetic, not taste: `open()` may spend the whole 5 s busy timeout
    /// before it gives up, so committing at 6.5 s left 1.5 s for the checkpoint to overrun
    /// into the commit and *succeed* — which makes `busy == false` pass for the wrong
    /// reason. CI measured an `open()` that ran 6.60 s against that 5 s timeout, so the
    /// overrun is not hypothetical. At 12 s a late success needs a 7 s overrun of a handler
    /// that sleeps in millisecond steps.
    private static let commitPastTimeout: UInt64 = 12_000_000_000

    private func dbPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_busy_\(UUID().uuidString.prefix(8)).sqlite").path
    }

    private func removeDB(_ path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
    }

    /// The WAL file's size in bytes, or -1 when it is absent. One home for the quantity that
    /// decided this suite's CI-vs-host disagreement.
    private func walBytes(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? Int ?? -1
    }

    /// Leaves `writer` holding a `BEGIN IMMEDIATE` transaction it releases `delay` ns from now,
    /// with **committed frames already in the WAL**.
    ///
    /// CI is what found the premise missing: the runners reached `open()` where this host had 79
    /// pages to copy and they had none (`walAtRead=0 logPages=0`). Frames belonging to an
    /// *uncommitted* transaction are invisible to a checkpoint, so the old helper left copyable
    /// pages only when the writer's own startup truncation happened to skip them. Committing
    /// first is what makes "there is a truncation to refuse" true by construction, not by host
    /// luck — and it is the premise the whole suite's `busy == true` rests on.
    private func holdWriteLock(on writer: SQLiteStore, delay: UInt64) async throws
        -> (epoch: DispatchTime, commit: Task<Int, any Error>)
    {
        try await writer.execute(sql: "CREATE TABLE busy_probe(x INTEGER);")
        try await writer.execute(sql: "BEGIN IMMEDIATE;")
        try await writer.execute(sql: "INSERT INTO busy_probe VALUES (1);")
        try await writer.execute(sql: "COMMIT;")
        try await writer.execute(sql: "BEGIN IMMEDIATE;")
        try await writer.execute(sql: "INSERT INTO busy_probe VALUES (2);")
        // The epoch is taken here, before the task exists, so every number the tests compare
        // shares one origin: the commit lands `delay` ms from `epoch`.
        let epoch = DispatchTime.now()
        let commit = Task<Int, any Error> {
            try await Task.sleep(nanoseconds: delay)
            try await writer.execute(sql: "COMMIT;")
            return Self.msSince(epoch)
        }
        return (epoch, commit)
    }

    private static func msSince(_ epoch: DispatchTime) -> Int {
        Int(
            (epoch.uptimeNanoseconds.distance(to: DispatchTime.now().uptimeNanoseconds))
                / 1_000_000)
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
        let (_, commit) = try await holdWriteLock(on: writer, delay: Self.commitInsideTimeout)

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
        let (epoch, commit) = try await holdWriteLock(
            on: writer, delay: Self.commitPastTimeout)

        // Premise, floored before the challenger can change anything: with no committed frames
        // there is no truncation to refuse and busy=0 is the honest answer, so this suite would
        // be asserting a bug that does not exist (which is exactly what it did on CI).
        let framesAtStart = walBytes(path)
        #expect(
            framesAtStart > 0,
            """
            premise broken: the WAL held no committed frames (\(framesAtStart) B) before \
            `open()`, so this run did not create the contention it claims to measure
            """)

        let challenger = SQLiteStore(path: path)
        let openStartMs = Self.msSince(epoch)
        try await challenger.open()
        let openEndMs = Self.msSince(epoch)
        let waitedMs = openEndMs - openStartMs
        let commitMs = try await commit.value

        let reported = await challenger.lastOpenWALCheckpoint
        // CI reproduces this red on both matrix legs and this host does not, and the job log
        // needs a token to read. So a failing run names the quantity that broke instead of
        // leaving a bare `busy == false` behind: `logPages` separates "sqlite refused the
        // truncation and nobody read it" from "there was nothing to truncate" — and only one
        // of those is a bug in `open()`. Tagged EVIDENCE so CI publishes the line.
        if reported?.busy != true {
            let timeout = try? await challenger.scalarQuery(sql: "PRAGMA busy_timeout;")
            print(
                """
                EVIDENCE sqlite-open-busy: waitedMs=\(waitedMs) openEndMs=\(openEndMs) \
                commitMs=\(commitMs) busy=\(String(describing: reported?.busy)) \
                logPages=\(String(describing: reported?.logPages)) \
                ckptPages=\(String(describing: reported?.checkpointedPages)) \
                busyTimeout=\(String(describing: timeout?.asInt64)) \
                statementMs=\(String(describing: reported?.statementMs)) \
                walAtOpen=\(framesAtStart) \
                walAtRead=\(walBytes(path))
                """
            )
        }
        #expect(
            reported?.busy == true, "the busy column was not read — contention would be swallowed")
        // The wait was the knob, not the machine. SQLite reports contention as a *value*, so a
        // timeout that never took effect looks identical to success unless the wait is measured:
        // pre-fix this statement returned busy=1 in ~4 ms (pinned by the lower bound), and a wait
        // that runs past the configured window means the refusal was actually dictated by the
        // other connection's schedule (the upper bound sits at 2x the timeout, above the CI
        // reading where a saturated runner's sleep steps each land a little late).
        let statementMs = reported?.statementMs ?? -1
        #expect(
            statementMs >= 4_500 && statementMs <= 10_000,
            """
            busy_timeout is \(String(describing: reported?.busy)) with the statement waiting \
            \(statementMs)ms — expected between ~5s (the knob) and 2x that \
            (the other side's schedule)
            """)
        // Ordering, pinned by measurement rather than a guessed constant: `busy == true` is
        // only evidence about contention if `open()` finished before the writer committed. CI's
        // first reading (`waited=6.60s` against a 6.5 s commit) was indistinguishable from "it
        // ran afterwards and succeeded"; the first cut of this guard then used a hand-picked 8 s
        // ceiling and CI broke *that* at 8.30 s while the ordering itself held, because the
        // runner was slow rather than wrong. So the bound is the commit instant on one clock,
        // with 50 ms of slack for the two measurements' own skew.
        #expect(
            openEndMs + 50 < commitMs,
            """
            open() returned at \(openEndMs)ms and the writer committed at \(commitMs)ms \
            (open took \(waitedMs)ms) — a refusal landing after the commit cannot be \
            attributed to contention
            """)
        // A refused truncation is a degraded start, not a fatal one: SQLite auto-checkpoints later.
        #expect((try await challenger.scalarQuery(sql: "PRAGMA journal_mode;"))?.asString == "wal")
        await challenger.close()
        await writer.close()
    }

    /// The CI start, manufactured instead of hoped for.
    ///
    /// This suite passed on one host and failed on the runners from the same code, and the
    /// difference was a file's size: 79 pages to copy here, none there, because the writer's own
    /// startup checkpoint truncated cleanly over there. Truncating on purpose reproduces that
    /// beginning on any host, which leaves exactly one variable: the frames. With a 0-byte WAL
    /// and a *committed* transaction behind it, a refused truncation must still be reported —
    /// that is the property this test pins, and it fails if `holdWriteLock` stops committing.
    @Test("a WAL the writer already truncated still produces a refused truncation")
    func truncatedStartStillRefusesTruncation() async throws {
        let path = dbPath()
        defer { removeDB(path) }

        let writer = SQLiteStore(path: path)
        try await writer.open()
        _ = try await writer.scalarQuery(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        #expect(
            walBytes(path) == 0, "this run did not reproduce the empty-WAL start CI reported")

        let (_, commit) = try await holdWriteLock(
            on: writer, delay: Self.commitPastTimeout)
        let frames = walBytes(path)
        #expect(frames > 0, "a committed transaction must reach the WAL, got \(frames) bytes")

        let challenger = SQLiteStore(path: path)
        try await challenger.open()
        try await commit.value

        let reported = await challenger.lastOpenWALCheckpoint
        #expect(
            reported?.busy == true,
            "with frames to copy (\(frames) bytes) contention must still be reported")
        await challenger.close()
        await writer.close()
    }
}
