// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// The scheduler's consumed surface, pinned by scanning rather than by memory.
///
/// Why this exists: the actor once carried a whole lifecycle API — `submitAll`,
/// `dispatchBatch`, `interruptAll`, `status(of:)`, `snapshot()`, `RequestState`,
/// `avgQueueTimeMs` — and no production call site ever used any of it. Unevidenced surface is
/// how the per-request leak got written in the first place: a table whose only reader was its
/// own sibling method. This scan goes red when a fourth member enters production use without a
/// decision, and its floor goes red when the scan itself stops matching (invariant 1).
import Foundation
import Testing

@testable import ocoreai

@Suite("Scheduler consumed surface")
struct SchedulerConsumedSurfaceTests {

    /// Every `SchedulerActor` member production code may reach. `submit`, `dispatch` and
    /// `interrupt` also exist on the actor — internal/test use and the reserved mid-flight
    /// release seam — and none of them reaches outside `Sources/ocoreai/Scheduler/`.
    private static let consumedMembers: Set<String> = [
        "complete", "fail", "submitAndDispatch",
    ]

    /// Floor for the scan's own hit count. Measured 26 sites (14 `fail`, 7 `complete`,
    /// 5 `submitAndDispatch`): low enough for routine handler refactors, high enough that a
    /// regex which stopped matching cannot pass as "nothing else is consumed".
    private static let siteFloor = 20

    private enum MissingError: Error {
        case repoRootNotFound(String)
        case sourceNotFound(String)
    }

    /// Find the repo by searching, never by fixed parent hops.
    private static func repoRoot() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                return url.path
            }
        }
        throw MissingError.repoRootNotFound(url.path)
    }

    private static func sourceFiles() throws -> [(path: String, text: String)] {
        let root = try repoRoot()
        let sourcesURL = URL(fileURLWithPath: root).appendingPathComponent("Sources")
        let walked = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var out: [(String, String)] = []
        while case let url as URL = walked?.nextObject() {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((String(url.path.dropFirst(root.count + 1)), text))
        }
        return out
    }

    /// Comments name identifiers too — a doc reference to `scheduler.snapshot()` must not be
    /// counted as a call site, or this gate reports a consumer that does not exist.
    private static func isCodeLine(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("/*") && !trimmed.hasPrefix("*")
    }

    @Test("production consumes exactly submitAndDispatch / complete / fail")
    func consumedSurfaceIsThreeMethods() throws {
        let pattern = try NSRegularExpression(
            pattern: "[a-zA-Z]*[sS]cheduler\\??\\.([a-zA-Z]+)")
        var members: Set<String> = []
        var sites = 0
        var filesWithActor = 0

        for (path, text) in try Self.sourceFiles() {
            if path.hasPrefix("Sources/ocoreai/Scheduler/") { continue }
            guard text.contains("SchedulerActor") else { continue }
            filesWithActor += 1
            for line in text.split(separator: "\n") where Self.isCodeLine(line) {
                let nsLine = line as NSString
                let found = pattern.matches(
                    in: String(line), range: NSRange(location: 0, length: nsLine.length))
                for match in found {
                    guard match.numberOfRanges == 2 else { continue }
                    let raw = match.range(at: 1)
                    guard raw.location != NSNotFound else { continue }
                    members.insert(nsLine.substring(with: raw))
                    sites += 1
                }
            }
        }

        #expect(filesWithActor >= 5, "handlers and App own a SchedulerActor: \(filesWithActor)")
        #expect(
            sites >= Self.siteFloor,
            "scan matched only \(sites) call sites — floor is \(Self.siteFloor)")
        let extras = members.subtracting(Self.consumedMembers)
        #expect(members == Self.consumedMembers, "new scheduler consumer in production: \(extras)")
    }

    @Test("the actor declares no lifecycle API without a consumer")
    func noUnconsumedLifecycleApi() throws {
        let root = try Self.repoRoot()
        let lifecycle: [String] = [
            "func submit(", "func submitAndDispatch(", "func dispatch(",
            "func interrupt(", "func complete(", "func fail(",
        ]
        let removed: [String] = [
            "func submitAll(", "func dispatchBatch(", "func interruptAll(",
            "func status(of", "func snapshot()", "RequestState", "avgQueueTimeMs",
        ]
        var declarations = 0
        var forbidden: [String] = []
        for name in ["SchedulerActor.swift", "SchedulerModels.swift"] {
            let url = URL(fileURLWithPath: root)
                .appendingPathComponent("Sources/ocoreai/Scheduler/\(name)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw MissingError.sourceNotFound(url.path)
            }
            // Declarations live in code; a comment naming a removed API is documentation,
            // not its return.
            let code = text.split(separator: "\n")
                .filter { Self.isCodeLine($0) }
                .joined(separator: "\n")
            for needle in lifecycle where code.contains(needle) { declarations += 1 }
            for needle in removed where code.contains(needle) {
                forbidden.append("\(name): \(needle)")
            }
        }
        #expect(declarations == 6, "six lifecycle entry points must exist: got \(declarations)")
        #expect(forbidden.isEmpty, "unconsumed lifecycle API is back: \(forbidden)")
    }
}
