// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// PerceptionEngine — unified scheduler for all perception channels.
///
/// Architecture:
///   Channels (camera/screen/network/filesystem/internet)
///     -> PerceptionEngine (scheduler + adaptive sampling)
///     -> PerceptionBuffer (RingBuffer + TTL + budget)
///     -> ChatViewModel (injection via snapshot() / contentParts())
///
/// Properties:
/// - Zero blocking on inference path (snapshot is lock-free read)
/// - Adaptive sampling degrades during inference / low-battery states
/// - Token budget hard cap prevents context overflow
/// - Cross-platform: screen capture macOS-only, filesystem all platforms
///
/// @Observable per Apple API Design Guidelines (SE-0403)

import Foundation
import os.log

private let perceptionLogger = Logger(subsystem: "ocoreai", category: "perception_engine")

// MARK: - Inference state actor

@preconcurrency actor InferenceFlag {
    private var _active = false
    var active: Bool { _active }
    func activate() { _active = true }
    func deactivate() { _active = false }
}

// MARK: - Power Profile

public enum PowerProfile: String, Codable, Sendable {
    case normal
    case reduced
    case minimal
    case halted
}

// MARK: - Channel configuration

public struct ChannelConfig: Codable, Sendable {
    var cameraInterval: TimeInterval
    var screenInterval: TimeInterval
    var networkInterval: TimeInterval
    var filesystemInterval: TimeInterval
    var internetInterval: TimeInterval
    var systemInterval: TimeInterval
    var speakerInterval: TimeInterval

    static let `default` = ChannelConfig(
        cameraInterval: 5.0,
        screenInterval: 10.0,
        networkInterval: 15.0,
        filesystemInterval: 30.0,
        internetInterval: 300.0,
        systemInterval: 60.0,
        speakerInterval: 30.0
    )
    static let reduced = ChannelConfig(
        cameraInterval: 15.0,
        screenInterval: 30.0,
        networkInterval: 45.0,
        filesystemInterval: 90.0,
        internetInterval: 600.0,
        systemInterval: 120.0,
        speakerInterval: 60.0
    )
    static let minimal = ChannelConfig(
        cameraInterval: 0,
        screenInterval: 0,
        networkInterval: 60.0,
        filesystemInterval: 120.0,
        internetInterval: 0,
        systemInterval: 300.0,
        speakerInterval: 0
    )
    static let halted = ChannelConfig(
        cameraInterval: 0,
        screenInterval: 0,
        networkInterval: 0,
        filesystemInterval: 0,
        internetInterval: 0,
        systemInterval: 0,
        speakerInterval: 0
    )
}

// MARK: - Channel state flags

public struct ChannelFlags: Codable, Sendable {
    var camera: Bool = false
    var screen: Bool = false
    var network: Bool = true
    var filesystem: Bool = false
    var internet: Bool = false
    var system: Bool = true
    var speaker: Bool = false

    static let allOn = ChannelFlags(
        camera: true, screen: true, network: true,
        filesystem: true, internet: true,
        system: true, speaker: true
    )
    static let `default` = ChannelFlags(camera: false, screen: false, network: true, system: true)
    static let allOff = ChannelFlags(
        camera: false, screen: false, network: false,
        filesystem: false, internet: false,
        system: false, speaker: false
    )
}

// MARK: - Engine

@Observable
@MainActor
final class PerceptionEngine: Sendable {
    static let shared = PerceptionEngine()

    // MARK: - Public state

    var isRunning: Bool = false
    var powerProfile: PowerProfile = .normal
    var channels = ChannelFlags.default
    var budget = PerceptionBudget.default
    var bufferCount: Int = 0

    var activeChannels: [PerceptionChannel] {
        var list: [PerceptionChannel] = []
        if channels.camera { list.append(.camera) }
        if channels.network { list.append(.network) }
        if channels.filesystem || channels.internet { list.append(.environment) }
        if channels.system { list.append(.system) }
        if channels.speaker { list.append(.speaker) }
        #if os(macOS)
        if channels.screen { list.append(.screen) }
        #endif
        return list
    }

    // MARK: - Internal

    private let buffer = PerceptionBuffer(capacity: 32, defaultTTL: 60)
    private var _samplingTasks: [String: Task<Void, Never>] = [:]
    private let _inferenceFlag = InferenceFlag()

    // MARK: - Control

    @MainActor
    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // Sync with MultimodalState
        let mmState = MultimodalState.shared
        channels.camera = mmState.cameraEnabled
        #if os(macOS)
        channels.screen = mmState.screenCaptureEnabled
        #endif
        channels.network = true

        let config = configForProfile(powerProfile)

        // Start video channels
        if channels.camera, config.cameraInterval > 0 {
            _samplingTasks["camera"] = Task.detached(priority: .utility) {
                await Self.shared.sampleCamera(every: config.cameraInterval)
            }
        }

        #if os(macOS)
        if channels.screen, config.screenInterval > 0 {
            _samplingTasks["screen"] = Task.detached(priority: .utility) {
                await Self.shared.sampleScreen(every: config.screenInterval)
            }
        }
        #endif

        // Network channel (always active when engine runs)
        if channels.network, config.networkInterval > 0 {
            _samplingTasks["network"] = Task.detached(priority: .utility) {
                await Self.shared.sampleNetwork(every: config.networkInterval)
            }
        }

        // Filesystem channel
        if channels.filesystem, config.filesystemInterval > 0 {
            _samplingTasks["filesystem"] = Task.detached(priority: .utility) {
                await Self.shared.sampleFilesystem(every: config.filesystemInterval)
            }
        }

        // Internet channel
        if channels.internet, config.internetInterval > 0 {
            _samplingTasks["internet"] = Task.detached(priority: .utility) {
                await Self.shared.sampleInternet(every: config.internetInterval)
            }
        }

        // System context channel
        if channels.system, config.systemInterval > 0 {
            _samplingTasks["system"] = Task.detached(priority: .utility) {
                await Self.shared.sampleSystem(every: config.systemInterval)
            }
        }

        // Speaker feedback channel
        if channels.speaker, config.speakerInterval > 0 {
            _samplingTasks["speaker"] = Task.detached(priority: .utility) {
                await Self.shared.sampleSpeaker(every: config.speakerInterval)
            }
        }

        // Start external monitors
        _ = await NetworkSensor.shared.startMonitoring()

        if channels.filesystem {
            FileSystemSensor.shared.start(watching: nil)
        }

        if channels.internet {
            InternetSensor.shared.start(with: InternetFeedConfig.tech)
        }

        if channels.system {
            SystemContextSensor.shared.start()
        }

        if channels.speaker {
            SpeakerFeedbackSensor.shared.start()
        }

        perceptionLogger.info(
            "[PerceptionEngine] started (\(self.activeChannels.count) channels, \(self.powerProfile.rawValue))"
        )
    }

    @MainActor
    func stop() {
        for (_, task) in _samplingTasks {
            task.cancel()
        }
        _samplingTasks.removeAll()

        Task.detached {
            await CaptureService.shared.stopCapture()
            #if os(macOS)
            await ScreenshotService.shared.stopCapture()
            #endif
            await NetworkSensor.shared.stopMonitoring()
            await FileSystemSensor.shared.stop()
            await InternetSensor.shared.stop()
            await SystemContextSensor.shared.stop()
            await SpeakerFeedbackSensor.shared.stop()
        }

        buffer.clear()
        isRunning = false
        perceptionLogger.info("[PerceptionEngine] stopped")
    }

    // MARK: - Sampling loops

    private func sampleCamera(every interval: TimeInterval) async {
        let cs = CaptureService.shared
        guard await cs.startCapture() else {
            perceptionLogger.warning("[PerceptionEngine] camera: unavailable")
            return
        }

        defer { await cs.stopCapture() }

        while !Task.isCancelled {
            let inferring = await _inferenceFlag.active
            if inferring {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            guard let frameDataURL = await cs.captureFrame() else {
                try? await Task.sleep(for: .seconds(interval))
                continue
            }

            let base64Prefix = "data:image/jpeg;base64,"
            if frameDataURL.hasPrefix(base64Prefix) {
                let base64Str = String(frameDataURL.dropFirst(base64Prefix.count))
                if let data = Data(base64Encoded: base64Str) {
                    let ocrText = await VisionOCR.extractText(from: data)
                    let frame = PerceptionFrame(
                        channel: .camera,
                        imageURL: ocrText == nil ? frameDataURL : nil,
                        ocrText: ocrText,
                        estimatedTokens: ocrText != nil
                            ? min(20, max(5, ocrText!.count / 4))
                            : 800
                    )
                    Task { @MainActor in
                        Self.shared.pushFrame(frame)
                    }
                }
            }

            try? await Task.sleep(for: .seconds(interval))
        }
    }

    #if os(macOS)
    private func sampleScreen(every interval: TimeInterval) async {
        let ss = ScreenshotService.shared

        defer { await ss.stopCapture() }

        while !Task.isCancelled {
            let inferring = await _inferenceFlag.active
            if inferring {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            guard let frameDataURL = await ss.captureScreen() else {
                try? await Task.sleep(for: .seconds(interval))
                continue
            }

            let base64Prefix = "data:image/jpeg;base64,"
            if frameDataURL.hasPrefix(base64Prefix) {
                let base64Str = String(frameDataURL.dropFirst(base64Prefix.count))
                if let data = Data(base64Encoded: base64Str) {
                    let ocrText = await VisionOCR.extractText(from: data)
                    let frame = PerceptionFrame(
                        channel: .screen,
                        imageURL: ocrText == nil ? frameDataURL : nil,
                        ocrText: ocrText,
                        estimatedTokens: ocrText != nil
                            ? min(20, max(5, ocrText!.count / 4))
                            : 800
                    )
                    Task { @MainActor in
                        Self.shared.pushFrame(frame)
                    }
                }
            }

            try? await Task.sleep(for: .seconds(interval))
        }
    }
    #endif

    private func sampleNetwork(every interval: TimeInterval) async {
        while !Task.isCancelled {
            let text = await NetworkSensor.shared.contextText()
            let frame = PerceptionFrame(
                channel: .network,
                textContext: text,
                estimatedTokens: max(3, text.count / 4)
            )
            Task { @MainActor in
                Self.shared.pushFrame(frame)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func sampleFilesystem(every interval: TimeInterval) async {
        while !Task.isCancelled {
            let inferring = await _inferenceFlag.active
            if inferring {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let text = await FileSystemSensor.shared.contextText()
            let frame = PerceptionFrame(
                channel: .environment,
                textContext: text,
                estimatedTokens: max(3, text.count / 4)
            )
            Task { @MainActor in
                Self.shared.pushFrame(frame)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func sampleInternet(every interval: TimeInterval) async {
        while !Task.isCancelled {
            // Check connectivity before polling
            let reachable = await NetworkSensor.shared.isReachable
            guard reachable else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }

            let text = await InternetSensor.shared.contextText()
            let frame = PerceptionFrame(
                channel: .environment,
                textContext: text,
                estimatedTokens: max(5, text.count / 4)
            )
            Task { @MainActor in
                Self.shared.pushFrame(frame)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private nonisolated func sampleSystem(every interval: TimeInterval) async {
        while !Task.isCancelled {
            let text = await SystemContextSensor.shared.contextText()
            let frame = PerceptionFrame(
                channel: .system,
                textContext: text,
                estimatedTokens: max(3, text.count / 4)
            )
            Task { @MainActor in
                Self.shared.pushFrame(frame)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private nonisolated func sampleSpeaker(every interval: TimeInterval) async {
        while !Task.isCancelled {
            let text = await SpeakerFeedbackSensor.shared.contextText()
            guard !text.isEmpty else {
                try? await Task.sleep(for: .seconds(interval))
                continue
            }
            let frame = PerceptionFrame(
                channel: .speaker,
                textContext: text,
                estimatedTokens: max(3, text.count / 4)
            )
            Task { @MainActor in
                Self.shared.pushFrame(frame)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    // MARK: - Frame management

    @MainActor
    func pushFrame(_ frame: PerceptionFrame) {
        buffer.push(frame)
        bufferCount = buffer.count
    }

    @MainActor
    func snapshot(budget: PerceptionBudget? = nil) -> [PerceptionChannel: PerceptionFrame] {
        let b = budget ?? self.budget
        let result = self.buffer.snapshot(budget: b)
        bufferCount = buffer.count
        return result
    }

    /// Produce ContentPart array for ChatViewModel injection.
    @MainActor
    func contentParts(budget: PerceptionBudget? = nil) -> [ContentPart] {
        let snaps = snapshot(budget: budget)
        var parts: [ContentPart] = []

        for (_, frame) in snaps {
            if let ocr = frame.ocrText, !ocr.isEmpty {
                let prefix: String
                switch frame.channel {
                case .camera: prefix = "[Camera Perception]"
                case .screen: prefix = "[Screen Perception]"
                case .network: prefix = "[Network Context]"
                case .audio: prefix = "[Audio]"
                case .environment: prefix = "[Environment]"
                case .system: prefix = "[System Context]"
                case .speaker: prefix = "[Speaker Feedback]"
                }
                parts.append(
                    ContentPart(
                        type: "text",
                        text: "\(prefix) \(ocr)",
                        imageUrl: nil
                    )
                )
            } else if let url = frame.imageURL {
                parts.append(
                    ContentPart(
                        type: "image_url",
                        text: nil,
                        imageUrl: ContentPart.ImageURL(url: url)
                    )
                )
            } else if let ctx = frame.textContext, !ctx.isEmpty {
                parts.append(
                    ContentPart(
                        type: "text",
                        text: "[\(frame.channel.rawValue)] \(ctx)",
                        imageUrl: nil
                    )
                )
            } else if let audio = frame.audioURL {
                parts.append(
                    ContentPart(
                        type: "text",
                        text: "[Audio recording context]",
                        imageUrl: nil
                    )
                )
            }
        }

        return parts
    }

    // MARK: - System context text

    /// Produce a compact perception summary string suitable for system prompt
    /// augmentation. Format: "[System Perception] channel=value ..."
    ///
    /// nonisolated instance method — underlying PerceptionBuffer is
    /// @unchecked Sendable (mutex-protected), so reads are safe off MainActor.
    ///
    /// IMPORTANT: To call from @Sendable closures (toolDispatch, MTP loop),
    /// capture the PerceptionEngine instance reference OUTSIDE the closure
    /// (`let pe = PerceptionEngine.shared`) then call `pe.contextText()` inside.
    /// This avoids the MainActor static property isolation trap.
    nonisolated func contextText() -> String {
        // Snapshot latest frames from all channels — safe off MainActor.
        // self.buffer is @unchecked Sendable (mutex-protected), so direct
        // access from nonisolated context is safe.
        let snaps = self.buffer.snapshot(budget: PerceptionBudget.default)
        var parts: [String] = ["[System Perception]"]

        for (_, frame) in snaps {
            let label: String
            let value: String

            if let ocr = frame.ocrText, !ocr.isEmpty {
                label = "\(frame.channel.rawValue):ocr"
                value = String(ocr.prefix(500))  // cap to prevent context overflow
            } else if frame.imageURL != nil {
                label = "\(frame.channel.rawValue)"
                value = "[image frame available]"
            } else if let ctx = frame.textContext, !ctx.isEmpty {
                label = "\(frame.channel.rawValue)"
                value = ctx
            } else if frame.audioURL != nil {
                label = "\(frame.channel.rawValue)"
                value = "[audio frame available]"
            } else {
                continue
            }

            parts.append("\(label)=\(value)")
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Inference lifecycle

    @MainActor
    public func inferenceStarted() {
        Task {
            await _inferenceFlag.activate()
        }
    }

    @MainActor
    public func inferenceEnded() {
        Task {
            await _inferenceFlag.deactivate()
        }
    }

    // MARK: - Config

    @MainActor
    private func configForProfile(_ profile: PowerProfile) -> ChannelConfig {
        switch profile {
        case .normal: return .default
        case .reduced: return .reduced
        case .minimal: return .minimal
        case .halted: return .halted
        }
    }

    @MainActor
    public func setBudget(_ budget: PerceptionBudget) {
        self.budget = budget
    }

    @MainActor
    public func setChannels(_ flags: ChannelFlags) {
        self.channels = flags
        if isRunning {
            stop()
            Task { await start() }
        }
    }

    @MainActor
    public func setPowerProfile(_ profile: PowerProfile) {
        self.powerProfile = profile
    }
}
