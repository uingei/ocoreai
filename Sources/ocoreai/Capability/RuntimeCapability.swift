// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// RuntimeCapability — capability matrix single source of truth (4-target OS: 14/17, 15/18, 26/26, 27/27).
///
/// Every capability surface in this runtime is already gated at the right
/// layer in its own module:
///
///   - compile-time:     `#if canImport(FoundationModels)`, `#if canImport(CoreAI)`,
///                       `#if FoundationModelsIntegration`, `#if os(macOS)`
///   - runtime:          `#available(macOS 26.0, iOS 26.0, *)`, `#available(macOS 27.0, iOS 27.0, *)`
///
/// What those #if gates do NOT do: give the model, the UI, and HTTP clients
/// a single readout of which surfaces are live on *this* hardware and *this*
/// OS version. That readout is what `RuntimeCapability` is.
///
/// Design invariants:
///   - One truth for every surface name. Consumers (prompt / info tool /
///     /v1/capabilities) never diverge from this matrix.
///   - `available` reflects *this* process's actual compile + runtime state.
///     A macOS 15 box reports `UNAVAILABLE` on FM/coreai/video even though
///     the same binary source compiles it (because the #if gates compiled
///     it out). That is exactly what the model needs to know so it does
///     not fabricate results for surfaces it does not have.
///   - Notes are short, factual, and in the prompt-facing language (English).
///     The note explains *why* so a reader of the wire JSON understands.

import Foundation

public enum RuntimeCapability {

    /// One surface in the capability matrix.
    public struct Line: Encodable, Equatable, Sendable {
        public let name: String  // snake_case, stable ID
        public let available: Bool  // live on this process?
        public let note: String  // one-line reason (English)

        /// Display-form label ("MLX", "CoreAI", "Local STT", …).
        ///
        /// Computed (not stored): excluded from the Encodable wire shape by
        /// Codable synthesis, so `GET /v1/capabilities` output is byte-unchanged.
        /// Single source for the label too — UI, prompt and wire all render the
        /// same name, never a second hand-rolled mapping in a view.
        public var label: String {
            switch name {
            case "agent_loop": return "Agent Loop"
            case "mlx_inference": return "MLX"
            case "foundationmodels": return "FoundationModels"
            case "coreai_ane": return "CoreAI"
            case "local_stt": return "Local STT"
            case "tts_speech": return "Speech TTS"
            case "video_generation": return "Video"
            case "mcp_stdio": return "MCP stdio"
            case "screenshot_capture": return "Screenshot"
            case "model_fidelity": return "Fidelity"
            default: return name
            }
        }
    }

    /// Static process facts computed once.
    ///
    /// `osName` uses `#if os()` at compile time — this is a fact about the
    /// build target, not a runtime observation. Parsing
    /// `operatingSystemVersionString` for the name is fragile (Foundation
    /// has changed the string shape across releases; on some versions the
    /// string starts with "Version …" rather than "macOS …"). `#if os()`
    /// is the only honest signal.
    public static let osName: String = {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "Apple"
        #endif
    }()

    /// OS version, normalized to "<osName> <major.minor> (Build …)" — a stable
    /// human/wire shape regardless of the raw Foundation string form
    /// ("macOS 15.3 (Build 24D60)" on older SDKs, "Version 27.0 (Build …)"
    /// on newer ones).
    public static let osVersion: String = {
        let raw = ProcessInfo.processInfo.operatingSystemVersionString
        var core: String?
        if let m = raw.range(of: #"(\d+\.\d+)"#, options: .regularExpression) {
            core = String(raw[m])
        }
        var build: String?
        if let b = raw.range(of: #"Build\s+([A-Za-z0-9]+)"#, options: .regularExpression) {
            let frag = String(raw[b])
            if let t = frag.range(of: #"[A-Za-z0-9]+$"#, options: .regularExpression) {
                build = String(frag[t])
            }
        }
        if let c = core, let bl = build {
            return "\(osName) \(c) (Build \(bl))"
        }
        if let c = core {
            return "\(osName) \(c)"
        }
        return osName
    }()

    public static let arch: String = {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }()

    /// The four-target ladder every ocoreai deployment must cover.
    public static let tierBoundaries: String =
        "Tier boundaries in this codebase: macOS 14 / iOS 17, macOS 15 / iOS 18, "
        + "macOS 26 / iOS 26, macOS 27 / iOS 27. "
        + "Surfaces marked UNAVAILABLE below are hard limits of this hardware, OS version, "
        + "or the default model in use — do not claim, request, fabricate, or work around them. "
        + "The remaining surfaces are live on this process."

    /// Full capability matrix (evaluated once, immutable here).
    public static let lines: [Line] = {
        var result: [Line] = []
        // Core agent loop — OS-independent, always present (14/17 → 27/27).
        result.append(
            .init(
                name: "agent_loop", available: true,
                note: "Tool + turn + recover loop, all 4 OS tiers"))
        result.append(
            .init(
                name: "mlx_inference", available: true,
                note: "MLX (Metal GPU) on all 4 OS tiers (14/17, 15/18, 26/26, 27/27)"))
        // FoundationModels adapter: compile-gated by the FoundationModelsIntegration
        // trait AND the macOS 27 SDK. On macOS 15/26 SDKs this #if is false → the
        // whole FM path is compiled out, which is the honest "NOT present on this
        // process" signal.
        #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
        result.append(
            .init(
                name: "foundationmodels", available: true,
                note: "Apple FoundationModels adapter (FM session + tools)"))
        #else
        result.append(
            .init(
                name: "foundationmodels", available: false,
                note:
                    "Requires macOS 26+ / iOS 26+ with FoundationModelsIntegration trait — not on this build"
            ))
        #endif
        // CoreAI (Apple Neural Engine) inference — compile-gated by canImport(CoreAI),
        // runtime-gated by #available(macOS 27.0, iOS 27.0, *).
        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, *) {
            result.append(
                .init(
                    name: "coreai_ane", available: true,
                    note: "Apple Neural Engine backend (CoreAI framework, #avail 27)"))
        } else {
            result.append(
                .init(
                    name: "coreai_ane", available: false,
                    note: "Requires macOS 27 / iOS 27 (ANE / CoreAI framework unavailable before)"))
        }
        #else
        result.append(
            .init(
                name: "coreai_ane", available: false,
                note: "canImport(CoreAI) false on this target (framework not in SDK)"))
        #endif
        // Local STT (Speech framework) — runtime-gated to macOS 26+ / iOS 26+,
        // with cloud fallback on <26 (so speech itself is live on all tiers,
        // but local-only STT is 26+).
        #if !os(watchOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            result.append(
                .init(
                    name: "local_stt", available: true,
                    note: "On-device Speech framework transcription (26+)"))
        } else {
            result.append(
                .init(
                    name: "local_stt", available: false,
                    note:
                        "Requires macOS 26 / iOS 26 for on-device Speech; older OS falls back to cloud STT"
                ))
        }
        #endif
        // TTS (AVSpeechSynthesizer) — live on all 4 OS tiers.
        result.append(
            .init(
                name: "tts_speech", available: true,
                note: "AVSpeechSynthesizer speech output, all tiers"))
        // Video generation (Wan pipeline) — 27 only.
        #if !os(watchOS)
        if #available(macOS 27.0, iOS 27.0, *) {
            result.append(
                .init(
                    name: "video_generation", available: true,
                    note: "Wan 2.1 video pipeline, #avail macOS 27 / iOS 27"))
        } else {
            result.append(
                .init(
                    name: "video_generation", available: false,
                    note: "Requires macOS 27 / iOS 27"))
        }
        #endif
        // MCP stdio — macOS only (iOS has no `Process`).
        #if os(macOS)
        result.append(
            .init(
                name: "mcp_stdio", available: true,
                note: "Subprocess MCP stdio transport — macOS only (no Process on iOS)"))
        #else
        result.append(
            .init(
                name: "mcp_stdio", available: false,
                note: "Not on iOS (Foundation.Process unavailable on iOS)"))
        #endif
        // Screenshot perception — macOS only (AppKit screen capture).
        #if os(macOS)
        result.append(
            .init(
                name: "screenshot_capture", available: true,
                note: "Screen capture via AppKit (macOS only)"))
        #else
        result.append(
            .init(
                name: "screenshot_capture", available: false,
                note: "Not on iOS (AppKit screen capture unavailable)"))
        #endif
        // Fidelity — a model property, not an OS/hardware limit. Live-verified
        // 2026-09-19 (gemma-4-e2b default): tool layer executed faithfully
        // (exec/write success, server-logged) but the model misreported a
        // 6746-byte file as 24582 bytes and claimed 3/3 success with no
        // recovery. So the default ≤2B load cannot be trusted for
        // report-faithful multi-step values. Honesty directive, not a wall.
        result.append(
            .init(
                name: "model_fidelity", available: false,
                note:
                    "Model-summarized numbers are NOT trustworthy on default small models (live-verified 0919): "
                    + "1.8B reported 24582 B for a 6746 B file and claimed full success; "
                    + "4B reported a real value (9917 B, that file exists) but picked the wrong 'largest' file (true max 254974 B) from a mis-sorted sort. "
                    + "Treat every number you compute or pick out of tool output as unverified: re-derive it with a second independent command and cross-check before stating it; if a check fails, say so rather than reporting success."
            ))
        return result
    }()

    private static let enabledLines: [Line] = lines.filter(\.available)
    private static let unavailableLines: [Line] = lines.filter { !$0.available }

    /// Prompt-facing section: tier boundaries first (so the model reads the
    /// 4-OS ladder contract BEFORE the ENABLED/UNAVAILABLE lists), then the
    /// two lists. Kept deliberately short — the model reads line-by-line.
    public static var tierTruthSection: String {
        guard !unavailableLines.isEmpty else {
            return "This process's live capabilities:\n"
                + "  ENABLED (all live on this hardware + OS):\n"
                + enabledLines.map { " " + $0.name }.joined(separator: ", ") + "\n" + tierBoundaries
        }
        let enabled = enabledLines.map { " " + $0.name }.joined(separator: ", ")
        let disabled = unavailableLines.map { " " + $0.name + "  —  " + $0.note }.joined(
            separator: "\n")
        return tierBoundaries
            + "\nThis process's live capabilities (evaluated at boot, not configurable):\n"
            + "  ENABLED (all live):\n" + "    \(enabled)\n"
            + "  UNAVAILABLE (hard limits — do not claim or pretend to have these):\n" + disabled
    }

    /// Wire-facing JSON payload for `GET /v1/capabilities`.
    public static let wirePayload: [Line] = lines
}
