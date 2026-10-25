// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// A calibration input must be measured, never defaulted.
///
/// Measured before this suite: the fast path's post-stream quality signal passed
/// `toolCallCount: 0` while the very same stream forwarded every tool call to the UI, and
/// `DirectInferenceResult.toolCallParts` was documented as "Populated when AgentLoop ran
/// multiple iterations" after that coordinator had been deleted for having zero callers —
/// a condition that can no longer occur. Both fed the thinking-budget loop a picture of the
/// turn that was not the turn, and the loop that tunes the budget steers on it.
///
/// Scans floor their own premises so a regex that stopped matching fails the run.

import Foundation
import Testing

@testable import ocoreai

private func telemetryRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func readSource(_ relative: String) throws -> String {
    try String(
        contentsOf: telemetryRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

@Suite("Telemetry inputs — measured, never defaulted")
struct TelemetryTruthfulnessTests {

    @Test("the fast-path quality signal counts the tool calls it forwarded")
    func qualitySignalCountsToolCalls() throws {
        let src = try readSource("Sources/ocoreai/Client/DirectInferenceClient.swift")
        // A literal zero in a turn-scoped signal is the defect: this stream does run tools.
        #expect(occurrences(of: "toolCallCount: 0", in: src) == 0, "a defaulted count is a lie")
        #expect(occurrences(of: "toolCallCount: toolCallCount", in: src) == 1)
        #expect(occurrences(of: "toolCallCount += 1", in: src) == 1)
        // Premises: the counter sits where tool calls are seen, and this file really does
        // forward them (if that ever stops being true, the pin above is meaningless).
        #expect(occurrences(of: "case .toolCall(let tc):", in: src) >= 2)
    }

    @Test("no contract names an iteration coordinator that no longer exists")
    func noDeadCoordinatorClaim() throws {
        let client = try readSource("Sources/ocoreai/Client/DirectInferenceClient.swift")
        #expect(occurrences(of: "AgentLoop ran multiple iterations", in: client) == 0)

        // The runner is gone; only the value types remain, and the header says so. Scan every
        // source file for a producer claim, and floor the scan so a moved directory fails here.
        let fm = FileManager.default
        let root = telemetryRoot().appendingPathComponent("Sources/ocoreai")
        var scanned = 0
        var offenders: [String] = []
        if let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walk {
                guard url.pathExtension == "swift" else { continue }
                scanned += 1
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains("AgentLoop.run(") || text.contains("AgentLoop.iterate") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        #expect(scanned >= 200, "scan matched only \(scanned) files — premises moved")
        #expect(offenders.isEmpty, "callers of a deleted coordinator: \(offenders)")
    }
}
