// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Logging
import Synchronization
import os
import os.signpost

// MARK: - Unified Profiling Span System

/// Category groups for organizing signpost metrics in output tables
///
/// Groups are sorted in this order: main → decoder → engine
@available(macOS 27.0, iOS 27.0, *)
enum CategoryGroup: String, Comparable {
    case main = "main"  // Top-level lifecycle: model load, tokenizer load, warmup
    case decoder = "decoder"  // Decoding strategy layer: prompt, extend, decode, tokenization
    case engine = "engine"  // Inference engine layer: logits inference, cache, sampling

    /// Sort order for table output (main first, then decoder, then engine)
    var sortOrder: Int {
        switch self {
        case .main: return 0
        case .decoder: return 1
        case .engine: return 2
        }
    }

    static func < (lhs: CategoryGroup, rhs: CategoryGroup) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Standard signpost categories for consistent Instruments visualization
@available(macOS 27.0, iOS 27.0, *)
enum SignpostCategory: String, Sendable {
    case prompt = "Prompt"
    case extend = "Extend"  // Strategy layer: inter-token timing (N-1 spans)
    case decode = "Decode"  // Tokenizer: token ID → text string (N spans)
    case logitsInference = "LogitsInference"  // Engine layer: model forward pass (N spans)
    case warmup = "Warmup"
    case sample = "Sample"
    case sampleEncoding = "SampleEncoding"  // GPU sampler command buffer encoding
    case modelLoad = "ModelLoad"
    case tokenizerLoad = "TokenizerLoad"
    case tokenization = "Tokenization"
    case prepareStep = "PrepareStep"  // Engine layer: tensor reshape, rebind, input writes
    case cacheManagement = "CacheManagement"  // Engine layer: KV cache growth/reallocation
    case reset = "Reset"
    case cleanup = "Cleanup"

    /// Which group this category belongs to for table organization
    var group: CategoryGroup {
        switch self {
        case .modelLoad, .tokenizerLoad, .warmup, .reset, .cleanup:
            return .main
        case .prompt, .extend, .decode, .tokenization:
            return .decoder
        case .logitsInference, .prepareStep, .cacheManagement, .sample, .sampleEncoding:
            return .engine
        }
    }

    var staticString: StaticString {
        switch self {
        case .prompt: return "Prompt"
        case .extend: return "Extend"
        case .decode: return "Decode"
        case .logitsInference: return "LogitsInference"
        case .warmup: return "Warmup"
        case .sample: return "Sample"
        case .sampleEncoding: return "SampleEncoding"
        case .modelLoad: return "ModelLoad"
        case .tokenizerLoad: return "TokenizerLoad"
        case .tokenization: return "Tokenization"
        case .prepareStep: return "PrepareStep"
        case .cacheManagement: return "CacheManagement"
        case .reset: return "Reset"
        case .cleanup: return "Cleanup"
        }
    }
}

/// Move-only profiling span that unifies signposts and wall clock timing
///
/// Example usage:
/// ```swift
/// let span = Instrumentation.beginPrompt(tokens: 10)
/// // ... do work ...
/// span.end()  // Consuming - cannot use span after this
/// ```
@available(macOS 27.0, iOS 27.0, *)
struct ProfileSpan: ~Copyable {
    private let category: SignpostCategory
    private let signpostID: OSSignpostID
    private let log: OSLog
    private let startTime: UInt64
    private let metadata: [String: String]
    private var wasEnded: Bool = false

    /// The duration in nanoseconds.
    var duration: UInt64 {
        let endTime = mach_absolute_time()
        let duration = endTime - startTime

        // Convert to nanoseconds for stats
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        return duration * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }

    internal init(category: SignpostCategory, log: OSLog, metadata: [String: String]) {
        self.category = category
        self.log = log
        self.signpostID = OSSignpostID(log: log)
        self.startTime = mach_absolute_time()
        self.metadata = metadata

        // Begin signpost with metadata
        let metadataStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        os_signpost(
            .begin, log: log, name: category.staticString, signpostID: signpostID,
            "%{public}s", metadataStr)

        if CLILogger.isEnabled(at: 3) {
            CLILogger.log("BEGIN \(metadataStr)", component: category.rawValue)
        }
    }

    deinit {
        // deinit is called after consuming operations complete
        // Only warn if end() was never explicitly called
        if !wasEnded {
            let metaStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            let logger = Logger(label: "ocoreai.coreai.profiler")
            logger.error(
                "⚠️ PROFILING ERROR: ProfileSpan[\(category.rawValue)] was not explicitly ended! This indicates a programming error. Always call span.end() Metadata: \(metaStr)"
            )

            // End signpost to avoid leaving it open, but DO NOT record stats
            // (stats would be inaccurate since we don't know when work actually ended)
            endSignpost()
        }
    }

    /// End the profiling span
    consuming func end() {
        // Capture duration up-front
        let duration = self.duration

        wasEnded = true
        endSignpost()
        record(duration: duration)
    }

    func endSignpost() {
        os_signpost(.end, log: log, name: category.staticString, signpostID: signpostID)
    }

    consuming func record(duration: UInt64) {
        let category = self.category
        let metadata = self.metadata

        Task {
            await StatsStorage.shared.recordSpan(
                category: category,
                durationNanoseconds: duration,
                metadata: metadata
            )
        }

        if CLILogger.isEnabled(at: 3) {
            CLILogger.log(
                "END \(metadata) - \(duration / 1_000_000)ms", component: category.rawValue)
        }
    }

    /// End the profiling span with an explicit storage.
    ///
    /// Used for testing and for when the span can't be consumed.
    @MainActor
    mutating func end(storingInto storage: StatsStorage) {
        // Capture duration up-front
        let duration = self.duration

        endSignpost()
        recordSync(duration: duration, storage)
        wasEnded = true
    }

    @MainActor
    func recordSync(duration: UInt64, _ storage: StatsStorage) {
        storage.recordSpan(
            category: category,
            durationNanoseconds: duration,
            metadata: metadata
        )

        if CLILogger.isEnabled(at: 3) {
            CLILogger.log(
                "END \(metadata) - \(duration / 1_000_000)ms", component: category.rawValue)
        }
    }
}

/// Thread-safe storage for profiling statistics
@MainActor
@available(macOS 27.0, iOS 27.0, *)
final class StatsStorage {
    static let shared = StatsStorage()

    private var stats = [SignpostCategory: CategoryStats]()

    private init() {}

    /// Internal initializer for testing (creates isolated instance not connected to ProfileSpan)
    /// Use this in tests to avoid shared state conflicts between parallel test suites
    internal init(forTesting: Void) {}

    internal func recordSpan(
        category: SignpostCategory,
        durationNanoseconds: UInt64,
        metadata: [String: String]
    ) {
        stats[category, default: CategoryStats()].record(
            durationNanoseconds: durationNanoseconds
        )
    }

    /// Aggregate statistics for a category
    struct AggregateStats: Sendable {
        let count: Int
        let totalSeconds: TimeInterval
        let minSeconds: TimeInterval
        let maxSeconds: TimeInterval
        let avgSeconds: TimeInterval
    }

    func stats(for category: SignpostCategory) -> AggregateStats? {
        guard let catStats = stats[category], catStats.hasSample else { return nil }

        let nanosecondsToSeconds = { (nanoseconds: UInt64) -> TimeInterval in
            Double(nanoseconds) / 1_000_000_000.0
        }

        return AggregateStats(
            count: catStats.count,
            totalSeconds: nanosecondsToSeconds(catStats.totalNanoseconds),
            minSeconds: nanosecondsToSeconds(catStats.minNanoseconds),
            maxSeconds: nanosecondsToSeconds(catStats.maxNanoseconds),
            avgSeconds: nanosecondsToSeconds(catStats.totalNanoseconds) / Double(catStats.count)
        )
    }

    /// Total duration for a specific category
    func totalDuration(for category: SignpostCategory) -> TimeInterval {
        return stats(for: category)?.totalSeconds ?? 0.0
    }

    /// Count of spans for a specific category
    func count(for category: SignpostCategory) -> Int {
        return stats(for: category)?.count ?? 0
    }

    /// Reset all stored statistics
    func reset() {
        stats.removeAll()
    }

    /// All categories that have recorded data
    var allCategories: [SignpostCategory] {
        stats.keys.sorted(by: { $0.rawValue < $1.rawValue })
    }
}

@available(macOS 27.0, iOS 27.0, *)
extension StatsStorage {
    private struct CategoryStats {
        var count: Int = 0
        var hasSample = false
        var totalNanoseconds: UInt64 = 0
        var minNanoseconds: UInt64 = .max
        var maxNanoseconds: UInt64 = 0

        mutating func record(durationNanoseconds: UInt64) {
            count += 1
            hasSample = true
            totalNanoseconds += durationNanoseconds
            minNanoseconds = min(minNanoseconds, durationNanoseconds)
            maxNanoseconds = max(maxNanoseconds, durationNanoseconds)
        }
    }
}

/// Enhanced profiling system that integrates with Instruments
@available(macOS 27.0, iOS 27.0, *)
struct InstrumentsProfiler {
    private static let log = OSLog(
        subsystem: "com.apple.coreai-models.performance", category: "performance")

    // MARK: - Unified Profiling Span API (New)

    /// Begin profiling prompt processing (first token, processes all input tokens at once)
    static func beginPrompt(tokens: Int, engine: String? = nil) -> ProfileSpan {
        var metadata: [String: String] = ["tokens": "\(tokens)"]
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .prompt, log: Self.log, metadata: metadata)
    }

    /// Begin profiling decode step (token→text conversion)
    static func beginDecode(step: Int) -> ProfileSpan {
        let metadata: [String: String] = ["step": "\(step)"]
        return ProfileSpan(category: .decode, log: Self.log, metadata: metadata)
    }

    /// Begin profiling warmup step (kernel compilation)
    static func beginWarmup(step: Int? = nil) -> ProfileSpan {
        var metadata: [String: String] = [:]
        if let step = step {
            metadata["step"] = "\(step)"
        }
        return ProfileSpan(category: .warmup, log: Self.log, metadata: metadata)
    }

    /// Begin profiling sampling operation
    static func beginSample(strategy: String? = nil, temperature: Double? = nil) -> ProfileSpan {
        var metadata: [String: String] = [:]
        if let strategy = strategy {
            metadata["strategy"] = strategy
        }
        if let temperature = temperature {
            metadata["temperature"] = String(format: "%.3f", temperature)
        }
        return ProfileSpan(category: .sample, log: Self.log, metadata: metadata)
    }

    /// Begin profiling GPU sample encoding (command buffer submission)
    ///
    /// Used by pipelined engines that encode GPU sampling commands asynchronously.
    /// Measures CPU time to encode the sampler command buffer, not GPU execution time.
    ///
    /// - Parameters:
    ///   - step: Generation step number (optional, enables timeline tracking when provided)
    ///   - strategy: Sampling strategy name (e.g., "greedy", "temperature")
    ///   - temperature: Temperature value for sampling
    static func beginSampleEncoding(step: Int? = nil, strategy: String, temperature: Double)
        -> ProfileSpan
    {
        var metadata: [String: String] = [
            "strategy": strategy,
            "temperature": String(format: "%.3f", temperature),
        ]
        if let step = step {
            metadata["step"] = "\(step)"
        }
        return ProfileSpan(category: .sampleEncoding, log: Self.log, metadata: metadata)
    }

    /// Begin profiling GPU sampling operation (tracks time from submission to GPU completion)
    ///
    /// Used by pipelined engines to measure actual GPU sampling duration.
    /// Create before runAsync(), end in completion handler.
    ///
    /// - Parameters:
    ///   - step: Generation step number (required for timeline tracking)
    ///   - strategy: Sampling strategy name (e.g., "argmax", "temperature")
    ///   - temperature: Temperature value for sampling
    static func beginSample(step: Int, strategy: String, temperature: Double) -> ProfileSpan {
        let metadata: [String: String] = [
            "step": "\(step)",
            "strategy": strategy,
            "temperature": String(format: "%.3f", temperature),
        ]
        return ProfileSpan(category: .sample, log: Self.log, metadata: metadata)
    }

    /// Begin profiling model loading
    static func beginModelLoad(name: String) -> ProfileSpan {
        let metadata: [String: String] = [
            "model": name
        ]
        return ProfileSpan(category: .modelLoad, log: Self.log, metadata: metadata)
    }

    /// Begin profiling tokenizer loading
    static func beginTokenizerLoad(id: String) -> ProfileSpan {
        let metadata: [String: String] = ["tokenizer": id]
        return ProfileSpan(category: .tokenizerLoad, log: Self.log, metadata: metadata)
    }

    /// Begin profiling tokenization
    static func beginTokenization(inputLength: Int) -> ProfileSpan {
        let metadata: [String: String] = ["inputLength": "\(inputLength)"]
        return ProfileSpan(category: .tokenization, log: Self.log, metadata: metadata)
    }

    /// Begin profiling a logits inference step (engine layer: model forward pass)
    ///
    /// Measures the time for the model to process input tokens and produce logits.
    ///
    /// - Parameters:
    ///   - step: Generation step number (optional, enables timeline tracking when provided)
    ///   - tokens: Number of tokens being processed
    ///   - processedCount: Total tokens processed so far
    ///   - engine: Engine identifier
    static func beginLogitsInference(
        step: Int? = nil, tokens: Int, processedCount: Int, engine: String? = nil
    )
        -> ProfileSpan
    {
        var metadata: [String: String] = [
            "tokens": "\(tokens)",
            "processed": "\(processedCount)",
        ]
        if let step = step {
            metadata["step"] = "\(step)"
        }
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .logitsInference, log: Self.log, metadata: metadata)
    }

    /// Begin profiling a logits inference step (for engines with GPU callbacks)
    ///
    /// Measures the time for the model to process input tokens and produce logits.
    /// Used by pipelined inference engines with completion handlers.
    ///
    /// - Parameters:
    ///   - step: Generation step number (required for timeline tracking)
    ///   - tokens: Number of tokens being processed
    ///   - engine: Engine identifier
    static func beginLogitsInference(step: Int, tokens: Int? = nil, engine: String? = nil)
        -> ProfileSpan
    {
        var metadata: [String: String] = ["step": "\(step)"]
        if let tokens = tokens {
            metadata["tokens"] = "\(tokens)"
        }
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .logitsInference, log: Self.log, metadata: metadata)
    }

    /// Begin profiling an extend step (strategy layer: inter-token timing)
    ///
    /// Measures the wall-clock time between receiving one token and the next.
    /// Used by VanillaDecodingStrategy to track autoregressive generation timing.
    /// Includes: engine inference + sampling + any overhead.
    /// NOTE: Use beginPrompt() for step 0 (prefill phase).
    static func beginExtend(step: Int, tokens: Int? = nil) -> ProfileSpan {
        var metadata: [String: String] = ["step": "\(step)"]
        if let tokens = tokens {
            metadata["tokens"] = "\(tokens)"
        }
        return ProfileSpan(category: .extend, log: Self.log, metadata: metadata)
    }

    /// Begin profiling step preparation (tensor reshape, rebind, input writes)
    ///
    /// Measures CPU time to prepare inputs for the next inference step.
    /// Includes: tensor layout reshape, executable rebind, and writing tokens/cache positions.
    ///
    /// - Parameters:
    ///   - step: Generation step number (optional, enables timeline tracking when provided)
    ///   - operation: Description of operation (e.g., "reshape+write", "rebind")
    ///   - engine: Engine identifier (e.g., "Core AI-Pipelined")
    static func beginPrepareStep(step: Int? = nil, operation: String, engine: String? = nil)
        -> ProfileSpan
    {
        var metadata: [String: String] = ["operation": operation]
        if let step = step {
            metadata["step"] = "\(step)"
        }
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .prepareStep, log: Self.log, metadata: metadata)
    }

    /// Begin profiling cache management operations (KV cache growth, reallocation)
    ///
    /// Measures time for actual KV cache operations like growth and data copying.
    /// Used when cache capacity is insufficient and needs to be expanded.
    ///
    /// - Parameters:
    ///   - step: Generation step number (optional, enables timeline tracking when provided)
    ///   - operation: Description of cache operation (e.g., "grow", "rebind", "init")
    ///   - engine: Engine identifier
    static func beginCacheManagement(step: Int? = nil, operation: String, engine: String? = nil)
        -> ProfileSpan
    {
        var metadata: [String: String] = ["operation": operation]
        if let step = step {
            metadata["step"] = "\(step)"
        }
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .cacheManagement, log: Self.log, metadata: metadata)
    }

    /// Begin profiling engine reset operations
    static func beginReset(engine: String? = nil) -> ProfileSpan {
        var metadata: [String: String] = [:]
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .reset, log: Self.log, metadata: metadata)
    }

    /// Begin profiling engine cleanup operations
    static func beginCleanup(engine: String? = nil) -> ProfileSpan {
        var metadata: [String: String] = [:]
        if let engine = engine {
            metadata["engine"] = engine
        }
        return ProfileSpan(category: .cleanup, log: Self.log, metadata: metadata)
    }

    // MARK: - Legacy Bracket Signposts (for Instruments visualization)
    //
    // These are intentional visual markers in Instruments, not for timing aggregation.
    // They bracket the entire inference/decoding operation for easy visual identification.

    private static let tokenizationName = StaticString("Tokenization")
    private static let inferenceName = StaticString("Inference")
    private static let decodingName = StaticString("DecodingStrategy")
    private static let tokenGenerationName = StaticString("TokenGeneration")
    private static let memoryUsageName = StaticString("MemoryUsage")
    private static let customIntervalName = StaticString("CustomInterval")

    private init() {}

    /// Log tokenizer completion event - marks end of all tokenizer work
    static func logTokenizerComplete(tokenCount: Int) {
        os_signpost(
            .event,
            log: Self.log,
            name: Self.tokenizationName,
            "Tokenizer complete: %{public}d prompt tokens ready",
            tokenCount
        )
    }

    // MARK: - Inference Bracket (visual marker in Instruments)

    static func beginInference(promptTokens: Int, maxTokens: Int) -> OSSignpostID {
        let inferenceSignpost = OSSignpostID(log: Self.log)
        os_signpost(
            .begin,
            log: Self.log,
            name: Self.inferenceName,
            signpostID: inferenceSignpost,
            "Starting inference: %{public}d prompt tokens, max %{public}d generation tokens",
            promptTokens,
            maxTokens
        )
        return inferenceSignpost
    }

    static func endInference(generatedTokens: Int, signpostID: OSSignpostID) {
        os_signpost(
            .end,
            log: Self.log,
            name: Self.inferenceName,
            signpostID: signpostID,
            "Generated %{public}d tokens",
            generatedTokens
        )
    }

    // MARK: - Decoding Bracket (visual marker in Instruments)

    static func beginDecoding(strategy: String) -> OSSignpostID {
        let decodingSignpost = OSSignpostID(log: Self.log)
        os_signpost(
            .begin,
            log: Self.log,
            name: Self.decodingName,
            signpostID: decodingSignpost,
            "Using %{public}s decoding",
            strategy
        )
        return decodingSignpost
    }

    static func endDecoding(signpostID: OSSignpostID) {
        os_signpost(.end, log: Self.log, name: Self.decodingName, signpostID: signpostID)
    }

    // MARK: - Event Logging

    static func logTokenGeneration(tokenIndex: Int, token: String) {
        os_signpost(
            .event,
            log: Self.log,
            name: Self.tokenGenerationName,
            "Token %{public}d: %{public}s",
            tokenIndex,
            token
        )
    }

    static func logMemoryUsage(phase: String) {
        var memoryInfo = MachTaskBasicInfo()
        var count = mach_msg_type_number_t(MemoryLayout<MachTaskBasicInfo>.size) / 4

        let result = withUnsafeMutablePointer(to: &memoryInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(machTaskBasicInfo), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let memoryMB = Double(memoryInfo.residentSize) / (1024 * 1024)
            os_signpost(
                .event, log: Self.log, name: Self.memoryUsageName,
                "%{public}s: %.1f MB", phase, memoryMB)
        }
    }

    // MARK: - Custom Intervals (for Core AI pipelined engine async spans)

    static func beginCustomInterval(name: String, details: String = "") -> OSSignpostID {
        let signpostID = OSSignpostID(log: Self.log)
        if details.isEmpty {
            os_signpost(
                .begin,
                log: Self.log,
                name: Self.customIntervalName,
                signpostID: signpostID,
                "%{public}s",
                name
            )
        } else {
            os_signpost(
                .begin,
                log: Self.log,
                name: Self.customIntervalName,
                signpostID: signpostID,
                "%{public}s: %{public}s",
                name,
                details
            )
        }
        return signpostID
    }

    static func endCustomInterval(name: String, signpostID: OSSignpostID, details: String = "") {
        if details.isEmpty {
            os_signpost(
                .end,
                log: Self.log,
                name: Self.customIntervalName,
                signpostID: signpostID,
                "%{public}s",
                name
            )
        } else {
            os_signpost(
                .end,
                log: Self.log,
                name: Self.customIntervalName,
                signpostID: signpostID,
                "%{public}s: %{public}s",
                name,
                details
            )
        }
    }
}

// MARK: - Mach Task Info Structure

// swiftformat:disable all
@available(macOS 27.0, iOS 27.0, *)
private struct MachTaskBasicInfo {
    var virtualSize: mach_vm_size_t = 0
    var residentSize: mach_vm_size_t = 0
    var residentSizeMax: mach_vm_size_t = 0
    var userTime: time_value_t = time_value_t()
    var systemTime: time_value_t = time_value_t()
    var policy: policy_t = 0
    var suspendCount: integer_t = 0
}

private let machTaskBasicInfo: Int32 = 20
