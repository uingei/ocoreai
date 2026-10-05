import Darwin
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Single-instance enforcement contract tests.
///
/// The flock is the authority: a live holder blocks every later acquisition,
/// release re-opens the gate, and the env escape hatch never blocks tests.
/// Cross-process semantics (crash release) are kernel-guaranteed by
/// flock(2)'s fd lifetime — the in-process tests below cover the API
/// contract; the child-process test covers real second-instance refusal.
import Foundation
import Testing

@testable import ocoreai

@Suite("SingleInstanceLock — one engine per machine")
struct SingleInstanceLockTests {
    private func tempLockPath(_ name: String = #function) -> String {
        let dir = FileManager.default.temporaryDirectory
        let safe = name.filter { $0.isLetter || $0.isNumber }
        return dir.appendingPathComponent("ocoreai-test-\(safe)-\(UUID().uuidString).lock").path
    }

    @Test("first acquire wins; holder PID is recorded")
    func firstAcquireWins() {
        let path = tempLockPath()
        let lock = SingleInstanceLock(lockPath: path)
        let result = lock.tryAcquire()
        #expect(result == .acquired(lockPath: path))
        #expect(lock.isHeld)
        #expect(SingleInstanceLock.readHolderPID(from: path) == getpid())
        lock.unlock()
        #expect(!lock.isHeld)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("second acquire while held → busy with holder PID")
    func secondAcquireBusy() {
        let path = tempLockPath()
        let first = SingleInstanceLock(lockPath: path)
        let second = SingleInstanceLock(lockPath: path)
        #expect(first.tryAcquire() == .acquired(lockPath: path))
        let blocked = second.tryAcquire()
        if case .busy(let pid) = blocked {
            #expect(pid == getpid())  // same-process holder, diagnostics path
        } else {
            Issue.record("expected .busy, got \(blocked)")
        }
        #expect(!second.isHeld)
        first.unlock()
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("unlock releases the gate — reacquire succeeds")
    func unlockReacquire() {
        let path = tempLockPath()
        let lock = SingleInstanceLock(lockPath: path)
        #expect(lock.tryAcquire() == .acquired(lockPath: path))
        lock.unlock()
        #expect(lock.tryAcquire() == .acquired(lockPath: path))
        lock.unlock()
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("OCOREAI_ALLOW_MULTI_INSTANCE=1 skips enforcement")
    func envEscapeHatch() {
        let path = tempLockPath()
        let lock = SingleInstanceLock(lockPath: path)
        #expect(lock.tryAcquire(allowMultiEnv: "1") == .skipped)
        #expect(lock.tryAcquire(allowMultiEnv: "true") == .skipped)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("holder death releases the lock (kernel fd lifetime)")
    func childProcessCrashReleases() throws {
        // Real cross-process proof: spawn a child that acquires the lock and
        // waits; the parent must see .busy while it lives, and win after it
        // dies (kernel auto-releases the flock with the child's fd table).
        let path = tempLockPath()
        // macOS ships no flock(1) util — use python's fcntl (POSIX flock).
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [
            "python3", "-c",
            "import fcntl,time\nf=open('\(path)','a')\nfcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('LOCKED', flush=True)\ntime.sleep(30)",
        ]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        // Non-blocking-ish: child prints LOCKED immediately (flush=True);
        // readDataToEndOfFile would block until the child's 30s sleep ends
        // and the kernel had already released the flock — defeating the test.
        Thread.sleep(forTimeInterval: 1.5)
        let outData = pipe.fileHandleForReading.availableData
        let out = String(data: outData, encoding: .utf8) ?? ""
        let locked = out.contains("LOCKED")
        guard locked else {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            let desc = out.isEmpty ? "<empty>" : out
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: desc])
        }
        // While the child lives, our acquire must be busy.
        let parent = SingleInstanceLock(lockPath: path)
        let blocked = parent.tryAcquire()
        if case .busy = blocked {
            // expected
        } else {
            Issue.record("expected .busy while child holds lock, got \(blocked)")
        }
        // Kill the holder — kernel releases; our reacquire must now win.
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(parent.tryAcquire() == .acquired(lockPath: path))
        parent.unlock()
        try? FileManager.default.removeItem(atPath: path)
    }
}
