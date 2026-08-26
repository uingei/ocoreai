import Foundation

// scripts/proc-status-cache-probe.swift
//
// Empirical probe (2026-08-26): after `Process.isRunning` flips to false
// — WITHOUT calling `waitUntilExit()` — is `terminationStatus` already
// cached? Covers normal exits (0 / 7) and a SIGKILL-reaped child.
//
// This is the invariant the `ExecSessions` finalize paths rely on: the
// drain poll loop already reaps via `isRunning()`, so a second blocking
// `waitUntilExit()` is a redundant `waitpid` — which wedged the macOS 26
// CI job (2026-08-26 hang) while the cached-status read is instant.
//
// Run:  swift scripts/proc-status-cache-probe.swift
// Expect: `exit7 status=7`, `exit0 status=0`, `sigkill status=9`.

func probe(_ label: String, mutate: (Process) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    mutate(p)
    do { try p.run() } catch {
        print("\(label): spawn error \(error)")
        return
    }
    if label == "sigkill" {
        // Capture the child PID at launch; SIGKILL it shortly after.
        let child = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = Darwin.kill(child, SIGKILL)
        }
    }
    while p.isRunning { Thread.sleep(forTimeInterval: 0.02) }
    // NOTE: `waitUntilExit()` intentionally never called.
    print(
        "\(label): isRunning=\(p.isRunning) status=\(p.terminationStatus) reason=\(p.terminationReason)"
    )
}

probe("exit7", mutate: { $0.arguments = ["-c", "exit 7"] })
probe("exit0", mutate: { $0.arguments = ["-c", "exit 0"] })
probe("sigkill", mutate: { $0.arguments = ["-c", "sleep 300"] })
