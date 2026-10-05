import Darwin
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Single-instance enforcement — the OS-level guarantee that at most ONE
/// ocoreai engine holds the machine's GPU/memory at a time.
///
/// ## Why this exists (first principles)
/// Each ocoreai instance loads full model weights (tens of GB of GPU
/// memory). A second instance cannot bind the HTTP port (`isPortInUse`
/// degrade in `App.startHTTPServer`) but it STILL boots the engine core,
/// duplicates memory pressure, and races the first instance on caches and
/// session state. Port conflict is a symptom; the disease is two engines.
/// The fix therefore belongs at the engine-boot gate, not at the bind gate.
///
/// ## Mechanism
/// `flock(2)` with `LOCK_EX | LOCK_NB` on a lock file. The kernel owns the
/// lock lifetime: if the process crashes, is SIGKILLed, or exits by any
/// path, the lock is released with the file descriptor — there is no stale
/// lock to reclaim and no PID re-check race. A live holder makes every
/// later acquisition fail immediately with `EWOULDBLOCK`.
///
/// ## Escape hatch
/// `OCOREAI_ALLOW_MULTI_INSTANCE=1` skips enforcement (tests build multiple
/// in-process `Application`s; CI runs suites in parallel). Production
/// defaults stay locked.
import Foundation

/// Result of a lock acquisition attempt — pure, testable.
enum SingleInstanceAcquisition: Equatable {
    /// Lock acquired; this process is the single instance.
    case acquired(lockPath: String)
    /// Another live process holds the lock.
    case busy(holderPID: pid_t?)
    /// Enforcement skipped via `OCOREAI_ALLOW_MULTI_INSTANCE`.
    case skipped
    /// Lock could not be created/opened (e.g. unwritable support dir).
    /// Treated as non-fatal by callers: fail-open beats refusing to boot
    /// over a filesystem quirk, since the port check remains as backstop.
    case unavailable(reason: String)
}

/// Thin wrapper around a held `flock`. Hold the instance for the process
/// lifetime; `unlock()` for orderly shutdown (the kernel would release the
/// fd anyway — explicit unlock just makes intent visible in logs/tests).
final class SingleInstanceLock {
    static let envAllowMulti = "OCOREAI_ALLOW_MULTI_INSTANCE"

    private(set) var fd: Int32 = -1
    let lockPath: String

    init(lockPath: String? = nil) {
        if let lockPath {
            self.lockPath = lockPath
        } else {
            let base =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.lockPath = base.appendingPathComponent("ocoreai.lock").path
        }
    }

    var isHeld: Bool { fd >= 0 }

    /// Non-blocking exclusive acquisition. See `SingleInstanceAcquisition`.
    func tryAcquire(allowMultiEnv: String? = nil) -> SingleInstanceAcquisition {
        let env = allowMultiEnv ?? ProcessInfo.processInfo.environment[Self.envAllowMulti]
        if env == "1" || env?.lowercased() == "true" {
            return .skipped
        }
        if fd >= 0 {
            return .acquired(lockPath: lockPath)  // idempotent re-acquire by same fd
        }
        let newFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard newFD >= 0 else {
            return .unavailable(reason: String(cString: strerror(errno)))
        }
        if flock(newFD, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(newFD)
            if err == EWOULDBLOCK {
                return .busy(holderPID: Self.readHolderPID(from: lockPath))
            }
            return .unavailable(reason: String(cString: strerror(err)))
        }
        fd = newFD
        // Record our PID for diagnostics only — correctness never depends on
        // the file contents (the flock is the authority, kernel-managed).
        ftruncate(newFD, 0)
        let pidLine = Data("\(getpid())\n".utf8)
        _ = pidLine.withUnsafeBytes { buf in
            Darwin.write(newFD, buf.baseAddress, buf.count)
        }
        return .acquired(lockPath: lockPath)
    }

    func unlock() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Best-effort holder PID read (diagnostics; nil if unreadable/stale).
    static func readHolderPID(from path: String) -> pid_t? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8),
            let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    deinit { unlock() }
}
