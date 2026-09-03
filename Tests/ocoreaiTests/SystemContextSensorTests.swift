// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SystemContextSensor tests — memory-pressure classification (pure) +
/// live read path on macOS (real kernel values, no stubbing).
///
/// Regression root cause: the previous `sysctlbyname("vm.page_count")`
/// source (a) does not exist on macOS 27 ("unknown oid"), and (b) returned
/// the TOTAL page count, so used-fraction was stuck at 0.0 → `.none`.
/// The fixed path uses `host_statistics64` free pages.
///
/// 09-03 live-machine evidence: old path => memory=unknown (always);
/// fixed path => real used% (1040MB free on 16GB → critical, matching vm_stat).

#if os(macOS)
import Testing
@testable import ocoreai

@Suite("SystemContextSensor — classify() thresholds")
struct SystemContextSensorClassifyTests {
    @Test("threshold boundaries half-open")
    func thresholds() {
        // Boundaries are half-open: [0,0.6)→none, [0.6,0.75)→light,
        // [0.75,0.85)→moderate, [0.85,0.92)→serious, [0.92,+]→critical
        #expect(MemoryPressureLevel.classify(usedFraction: 0.0) == .none)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.3) == .none)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.59) == .none)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.6) == .light)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.74) == .light)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.75) == .moderate)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.84) == .moderate)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.85) == .serious)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.91) == .serious)
        #expect(MemoryPressureLevel.classify(usedFraction: 0.92) == .critical)
        #expect(MemoryPressureLevel.classify(usedFraction: 1.0) == .critical)
    }
}

@Suite("SystemContextSensor — live read path")
struct SystemContextSensorLiveTests {
    @Test("sensor up => real fields, not 'no context'")
    @MainActor
    func liveSmoke() async throws {
        // Real L2: start the sensor, let a poll land, read contextText().
        // Without start() the read returns "[system] no context" — this is
        // the "closed vs. powered-on" distinction made testable.
        SystemContextSensor.shared.start()
        try await Task.sleep(for: .milliseconds(200))
        let text = SystemContextSensor.shared.contextText()
        #expect(text.hasPrefix("[system]"), "expected [system] prefix, got: \(text)")
        #expect(text.contains("thermal="), "thermal field missing: \(text)")
        #expect(text.contains("cpu="), "cpu field missing: \(text)")
        #expect(!text.contains("no context"), "sensor produced no data: \(text)")
    }
}
#endif
