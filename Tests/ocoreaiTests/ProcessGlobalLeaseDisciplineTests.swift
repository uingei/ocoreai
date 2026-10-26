// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ProcessGlobalLeaseDisciplineTests — no test may mutate a process-global without leasing it.
//!
//! `ProcessGlobalLease` exists because the active `SessionWorkspace` directory,
//! `OCOREAI_WORKSPACE`, `OCOREAI_MODELS_DIR`, `OCOREAI_MARGIN_PROBE` and `HF_ENDPOINT` have no
//! per-test scope, and `.serialized` orders a suite's *own* tests, never suites against each
//! other. The mechanism was written; adoption is what makes it true, and adoption decays the
//! moment a new suite forgets it — which is exactly what happened on 10-26:
//! `ExecCwdContractTests` set `SessionWorkspace` with no lease while `LoopGuardRemedyTests`
//! held the lease, and that suite read `sum100.py` from the repo root instead of its own temp
//! dir. So adoption is scanned here, the scan floors its own premises, and the repo root is
//! found by searching rather than by fixed parent hops (§ Testing Quality).
import Foundation
import Testing

@testable import ocoreai

@Suite("process globals — lease discipline, measured over Tests/")
struct ProcessGlobalLeaseDisciplineTests {

    private enum ScanError: Error {
        case rootNotFound
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let marker = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: marker.path),
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("Sources").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw ScanError.rootNotFound
    }

    /// Every `.swift` file under `Tests/`, deterministic order, repo-relative paths.
    private static func testFiles() throws -> [String] {
        let root = try repoRoot()
        let tests = root.appendingPathComponent("Tests")
        guard
            let enumerator = FileManager.default.enumerator(
                at: tests, includingPropertiesForKeys: nil)
        else { throw ScanError.rootNotFound }
        var found: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        found.sort()
        return found
    }

    /// Comment lines carry the prose names of these globals (`OCOREAI_MODELS_DIR` is discussed in
    /// several doc comments), and a scan that counts prose would name files that touch nothing.
    private static func codeOnly(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line -> Bool in
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
        }
        return
            kept
            .joined(separator: "\n")
            // `unsetenv(key)` contains `setenv(` — restoring a value is not a mutation.
            .replacingOccurrences(of: "unsetenv(", with: "unSETENV(")
    }

    /// The lease *implementation* restores keys with `setenv`; it is the one file allowed to
    /// mutate a global without holding a lease, and the exemption is asserted by name so an
    /// unnoted second exemption goes red instead of silently widening the hole.
    private static let leaseImplementation = "Tests/ocoreaiTests/ProcessGlobalLease.swift"

    @Test("every Tests file that mutates a process-global also takes a lease")
    func mutatorsAllTakeTheLease() throws {
        let files = try Self.testFiles()
        #expect(files.count >= 300, "the scan walked Tests/ (floor 300, measured \(files.count))")

        var mutators: [String] = []
        var offenders: [String] = []
        for path in files {
            guard
                let text = try? String(
                    contentsOf: Self.repoRoot().appendingPathComponent(path), encoding: .utf8)
            else { continue }
            let code = Self.codeOnly(text)
            // Bare `setenv(`, not `setenv("`: a key held in a constant mutates the global just
            // the same, and a gate that only sees literals teaches people to bind a constant.
            let mutates =
                code.contains("SessionWorkspace.setDirectory(") || code.contains("setenv(")
                || code.contains("putenv(")
            if mutates {
                mutators.append(path)
                if !text.contains("ProcessGlobalLease("), path != Self.leaseImplementation {
                    offenders.append(path)
                }
            }
        }
        let exemptions = mutators.filter { $0 == Self.leaseImplementation }
        #expect(
            exemptions.count == 1,
            "exactly the lease implementation may mutate without leasing (measured \(exemptions.count))"
        )
        // Floor the mutator count: if these patterns stop matching anything, "no offenders"
        // would be vacuously true — the failure mode this repo keeps tripping over.
        #expect(
            mutators.count >= 15,
            "the mutator patterns still see the suites that mutate (floor 15, measured \(mutators.count))"
        )
        #expect(
            offenders.isEmpty,
            "unleased process-global mutation races another suite: \(offenders.joined(separator: ", "))"
        )
    }

    @Test("release hands back the value the process already had")
    func releaseRestoresThePriorValue() {
        let key = "OCOREAI_LEASE_DISCIPLINE_PROBE"
        setenv(key, "outer", 1)
        defer { unsetenv(key) }

        let lease = ProcessGlobalLease(envKeys: [key])
        setenv(key, "inner", 1)
        #expect(
            ProcessInfo.processInfo.environment[key] == "inner", "the lease does not block writes")
        lease.release()
        #expect(
            ProcessInfo.processInfo.environment[key] == "outer",
            "a value the process came in with survives the suite that borrowed the key")
    }

    @Test("a key the process did not have is not left behind")
    func releaseClearsAnInventedKey() {
        let key = "OCOREAI_LEASE_DISCIPLINE_PROBE_2"
        unsetenv(key)

        let lease = ProcessGlobalLease(envKeys: [key])
        setenv(key, "invented", 1)
        lease.release()
        #expect(
            ProcessInfo.processInfo.environment[key] == nil,
            "what a test invented must not outlive it — that is how a temp MODELS_DIR leaked")
    }
}
