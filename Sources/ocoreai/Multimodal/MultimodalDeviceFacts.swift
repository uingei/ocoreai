// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Measured multimodal device facts — what macOS currently grants and what hardware is
/// actually present, as distinct from what the user's toggles wish.
///
/// Why this exists: `POST /v1/multimodal/status` is indexed as the multimodal
/// *permission + device* status and published only three UI toggles. A toggle is an
/// intent; permission and device presence are facts, and the two disagree constantly —
/// `cameraEnabled: true` on a box where TCC denies the camera, or where no camera is
/// attached, or with zero voices installed for TTS. AGENTS.md invariant 2 (the surface
/// never claims more than the engine delivered) means the wire has to say which.
///
/// Two rules govern everything in this file, both learned from the defects it replaces:
///
///   1. **Never prompt.** `AVCaptureDevice.requestAccess(for:)` and
///      `SFSpeechRecognizer.requestAuthorization` put a modal TCC dialog in front of the
///      user. A status read must be a read. `authorizationStatus` /
///      `SFSpeechRecognizer.authorizationStatus()` / `CGPreflightScreenCaptureAccess()`
///      answer the same question silently — the pattern `PersonalVoiceTTS.isAuthorized`
///      already uses for Personal Voice.
///   2. **Unknown is not zero, and unsupported is not denied.** Device enumeration and
///      the Speech framework do not exist on every tier, and a count of `0` means "looked,
///      found none" — a different claim from "cannot tell here". Counts are therefore
///      Optional (the key is omitted when the count could not be taken, same convention as
///      `ModelObject`), and the vocabularies below carry explicit `unknown` /
///      `unsupported` members instead of collapsing them into a verdict.
///
/// Measured on this host (2026-10-14, unsandboxed CLI reading of the same APIs):
/// camera/microphone `.denied`, 0 video and 0 audio devices visible, 180 installed voices,
/// speech recognition `.denied` — i.e. every claim of "can see / can hear" here would have
/// been false while the toggles alone said nothing either way.

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#endif
#if canImport(Speech)
import Speech
#endif

/// One OS permission axis, from a closed vocabulary a client can switch on.
enum DevicePermission: String, Codable, CaseIterable, Sendable {
    /// The user granted this to the app.
    case authorized
    /// The user explicitly refused.
    case denied
    /// Not obtainable by this user (MDM / parental controls / missing entitlement).
    case restricted
    /// Never asked; the first real use will prompt.
    case notDetermined
    /// The API reports permitted vs not-permitted only, so the specific TCC state is not
    /// readable — `CGPreflightScreenCaptureAccess()` is the one surface here like that.
    case notGranted
    /// This axis does not exist on the compiled target (no camera on a watchOS build).
    case unsupported
    /// Present on this target but the value could not be determined.
    case unknown

    /// The closed set a probe can assert published values against.
    static var vocabulary: [String] { allCases.map(\.rawValue) }
}

/// Whether one channel can deliver *right now*, from the measured facts.
enum ChannelReadiness: String, Codable, CaseIterable, Sendable {
    /// Every fact needed to deliver is present.
    case ready
    /// A fact is verifiably absent: refused, restricted, or no device / no voice. Fixable
    /// by the user (grant it, plug it in), but not working now.
    case blocked
    /// A fact could not be measured, so delivery is unverified either way.
    case unknown
    /// The channel is not part of this build's platform — not fixable by the user.
    case unsupported

    /// The closed set a probe can assert published values against.
    static var vocabulary: [String] { allCases.map(\.rawValue) }
}

/// Whether a wire-initiated capture may be attempted at all.
///
/// Why this exists (measured 10-14 by `scripts/probes/04-multimodal-honesty.sh`):
/// `POST /v1/multimodal/capture {"type":"camera"}` parked the request for ≥45 s, because
/// `CaptureService.startCapture()` calls `AVCaptureDevice.requestAccess(for:)`, which opens
/// a modal TCC dialog that a *wire* client has no way to answer. Accepting a request and
/// then blocking on a human at the keyboard is AGENTS.md invariant 2 wearing a different
/// hat: the endpoint took a call it had no route to deliver.
///
/// So the HTTP path decides from the measured permission and never prompts. The GUI keeps
/// prompting — flipping the camera toggle *is* the user asking to be asked (see
/// `MultimodalState.wireCamera`) — and a channel already streaming skips the check, since
/// it could only have started with a grant. `.unknown` still attempts: refusing on an
/// unreadable value would block paths that work, and the honest direction to err is the
/// loud refusal, not the quiet one.
enum CaptureAttempt: Equatable, Sendable {
    case attempt
    /// Refused before touching the hardware, with the fix the caller has to apply.
    case refuse(reason: String)
}

/// The System Settings ▸ Privacy & Security pane a channel lives in.
func privacyPane(forChannel channel: String) -> String {
    switch channel {
    case "camera": return "Camera"
    case "microphone": return "Microphone"
    case "screen": return "Screen Recording"
    case "transcription": return "Speech Recognition"
    default: return channel
    }
}

/// Decide a capture attempt from the permission alone — the seam that keeps `requestAccess`
/// out of the request path (`MultimodalStatusHonestyTests` pins every row).
func captureAttempt(channel: String, permission: DevicePermission) -> CaptureAttempt {
    let pane = privacyPane(forChannel: channel)
    switch permission {
    case .authorized, .unknown:
        return .attempt
    case .denied:
        return .refuse(
            reason:
                "\(channel): permission denied — allow it in System Settings ▸ Privacy & Security ▸ \(pane)"
        )
    case .restricted:
        return .refuse(
            reason: "\(channel): permission restricted by policy — not obtainable for this user"
        )
    case .notDetermined:
        return .refuse(
            reason:
                "\(channel): not authorized yet — this endpoint does not open the permission dialog; flip the \(channel) toggle in ocoreai Settings or allow it in System Settings ▸ Privacy & Security ▸ \(pane), then capture again"
        )
    case .notGranted:
        return .refuse(
            reason:
                "\(channel): screen recording not granted — allow it in System Settings ▸ Privacy & Security ▸ \(pane)"
        )
    case .unsupported:
        return .refuse(reason: "\(channel): not available on this platform")
    }
}

/// Point-in-time device/permission facts for the capture-and-speak channels.
struct MultimodalDeviceFacts: Codable, Equatable, Sendable {
    var cameraPermission: DevicePermission
    var microphonePermission: DevicePermission
    var speechRecognitionPermission: DevicePermission
    /// Screen recording is a single preflight Bool on macOS (see `DevicePermission.notGranted`).
    var screenPermission: DevicePermission

    /// `nil` = not enumerable on this target. `0` = enumerated, found none.
    var cameraDeviceCount: Int?
    var microphoneDeviceCount: Int?
    /// `nil` = AVFoundation unavailable; `0` = no installed speech voices.
    var speechVoiceCount: Int?

    /// The permission axis behind a channel name (`camera` / `microphone` / `screen` /
    /// `transcription`) — the lookup the capture gate and the limitation lines share.
    func permission(forChannel channel: String) -> DevicePermission {
        switch channel {
        case "camera": return cameraPermission
        case "microphone": return microphonePermission
        case "screen": return screenPermission
        case "transcription": return speechRecognitionPermission
        default: return .unknown
        }
    }

    // MARK: - Per-channel verdicts (computed: excluded from the Codable shape)

    var cameraStatus: ChannelReadiness { Self.readiness(cameraPermission, cameraDeviceCount) }

    var microphoneStatus: ChannelReadiness {
        Self.readiness(microphonePermission, microphoneDeviceCount)
    }

    /// TTS needs no permission and no enumeration — only an installed voice to speak with.
    var speakerStatus: ChannelReadiness { Self.speakerReadiness(speechVoiceCount) }

    /// Screen capture has no device axis here (there is always a display); the gate is
    /// purely the screen-recording grant.
    var screenStatus: ChannelReadiness {
        switch screenPermission {
        case .authorized: return .ready
        case .denied, .restricted: return .blocked
        case .unsupported: return .unsupported
        case .notGranted, .notDetermined, .unknown: return .unknown
        }
    }

    /// Transcription needs both axes: a working microphone *and* Speech authorization.
    var transcriptionStatus: ChannelReadiness {
        switch speechRecognitionPermission {
        case .denied, .restricted: return .blocked
        case .unsupported: return .unsupported
        case .notGranted, .notDetermined, .unknown: return .unknown
        case .authorized:
            switch microphoneStatus {
            case .ready: return .ready
            case .blocked: return .blocked
            case .unknown, .unsupported: return .unknown
            }
        }
    }

    /// Plain-language reason for every channel that is not `ready`, in a fixed order.
    /// Empty means every channel measured ready — never a silent "all good".
    var limitations: [String] {
        var out: [String] = []
        Self.appendLimit(
            &out, channel: "camera", status: cameraStatus, permission: cameraPermission,
            count: cameraDeviceCount)
        Self.appendLimit(
            &out, channel: "microphone", status: microphoneStatus, permission: microphonePermission,
            count: microphoneDeviceCount)
        Self.appendVoiceLimit(&out, status: speakerStatus, voiceCount: speechVoiceCount)
        Self.appendScreenLimit(&out, status: screenStatus, permission: screenPermission)
        Self.appendTranscriptionLimit(
            &out, status: transcriptionStatus, permission: speechRecognitionPermission)
        return out
    }

    /// The measured reason for one channel, with its `"<channel>: "` prefix removed, or nil
    /// when nothing measured blocks it (which for a capture means "no fact explains the
    /// miss" — e.g. a frame refused by the sampler's rate limit).
    func limitation(forChannel channel: String) -> String? {
        let prefix = "\(channel): "
        for line in limitations where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    // MARK: - Derivation (pure)

    /// Permission × device-count → verdict. Precedence: a refusal is decisive, then a
    /// verified-empty device list, and anything unmeasurable stays `unknown`.
    static func readiness(_ permission: DevicePermission, _ deviceCount: Int?) -> ChannelReadiness {
        switch permission {
        case .denied, .restricted:
            return .blocked
        case .authorized:
            guard let deviceCount else { return .unknown }
            return deviceCount > 0 ? .ready : .blocked
        case .unsupported:
            return .unsupported
        case .notGranted, .notDetermined, .unknown:
            return .unknown
        }
    }

    static func speakerReadiness(_ voiceCount: Int?) -> ChannelReadiness {
        guard let voiceCount else { return .unknown }
        return voiceCount > 0 ? .ready : .blocked
    }

    private static func appendLimit(
        _ out: inout [String],
        channel: String,
        status: ChannelReadiness,
        permission: DevicePermission,
        count: Int?,
    ) {
        switch status {
        case .ready:
            return
        case .blocked:
            switch permission {
            case .denied:
                out.append(
                    "\(channel): permission denied — grant it in System Settings ▸ Privacy & Security"
                )
            case .restricted:
                out.append(
                    "\(channel): permission restricted by policy — not obtainable for this user")
            default:
                out.append("\(channel): permission granted but no device is visible")
            }
        case .unknown:
            if permission == .authorized {
                out.append("\(channel): permission granted, device enumeration unavailable here")
            } else {
                out.append("\(channel): permission not determined — a capture attempt will prompt")
            }
        case .unsupported:
            out.append("\(channel): capture API unavailable on this platform")
        }
    }

    private static func appendVoiceLimit(
        _ out: inout [String],
        status: ChannelReadiness,
        voiceCount: Int?,
    ) {
        switch status {
        case .ready:
            return
        case .blocked:
            out.append("speaker: no installed speech voices — cannot synthesize")
        case .unknown:
            out.append("speaker: voice inventory unavailable on this platform")
        case .unsupported:
            out.append("speaker: AVFoundation unavailable on this platform")
        }
    }

    private static func appendScreenLimit(
        _ out: inout [String],
        status: ChannelReadiness,
        permission: DevicePermission,
    ) {
        switch status {
        case .ready:
            return
        case .blocked:
            out.append(
                "screen: screen-recording permission denied — System Settings ▸ Privacy & Security ▸ Screen Recording"
            )
        case .unknown:
            out.append(
                "screen: screen-recording permission not granted (macOS reports permitted vs not only — here: \(permission.rawValue))"
            )
        case .unsupported:
            out.append("screen: screen capture unavailable on this platform")
        }
    }

    private static func appendTranscriptionLimit(
        _ out: inout [String],
        status: ChannelReadiness,
        permission: DevicePermission,
    ) {
        switch status {
        case .ready:
            return
        case .blocked:
            if permission == .authorized {
                out.append("transcription: speech authorized but the microphone is not usable")
            } else {
                out.append("transcription: speech recognition \(permission.rawValue)")
            }
        case .unknown:
            out.append("transcription: speech recognition state unverifiable here")
        case .unsupported:
            out.append("transcription: Speech framework unavailable on this platform")
        }
    }

    /// The all-unknown fact set: what every axis degrades to before anything is measured,
    /// and what a target without AVFoundation/Speech reports.
    static let unmeasured = MultimodalDeviceFacts(
        cameraPermission: .unsupported,
        microphonePermission: .unsupported,
        speechRecognitionPermission: .unsupported,
        screenPermission: .unsupported,
        cameraDeviceCount: nil,
        microphoneDeviceCount: nil,
        speechVoiceCount: nil,
    )
}

extension MultimodalDeviceFacts {
    /// Read every axis that can be read silently. Never prompts.
    ///
    /// Deliberately does *not* reuse `CaptureService.availableCameras`: that list is
    /// discovered once at service init, so a grant given after launch would report
    /// `0 devices` forever — a false "blocked". A status read answers for now.
    /// Installed speech voices — the asset TTS needs, and the one axis the speak path can
    /// check without enumerating cameras. `nil` = AVFoundation not on this target.
    @MainActor
    static func voiceCount() -> Int? {
        #if canImport(AVFoundation)
        return AVSpeechSynthesisVoice.speechVoices().count
        #else
        return nil
        #endif
    }

    /// The four permission axes only — what a capture decision needs, with no device
    /// enumeration and no voice inventory (the paths that cost hundreds of ms).
    @MainActor
    static func permissionsOnly() -> MultimodalDeviceFacts {
        var facts = MultimodalDeviceFacts.unmeasured
        #if canImport(AVFoundation)
        facts.cameraPermission = DevicePermission(AVCaptureDevice.authorizationStatus(for: .video))
        facts.microphonePermission = DevicePermission(
            AVCaptureDevice.authorizationStatus(for: .audio))
        #endif
        #if canImport(Speech)
        facts.speechRecognitionPermission = DevicePermission(
            SFSpeechRecognizer.authorizationStatus())
        #endif
        #if os(macOS)
        facts.screenPermission = CGPreflightScreenCaptureAccess() ? .authorized : .notGranted
        #endif
        return facts
    }

    @MainActor
    static func gather() -> MultimodalDeviceFacts {
        var facts = permissionsOnly()
        #if canImport(AVFoundation)
        facts.cameraDeviceCount =
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified,
            ).devices.count
        facts.microphoneDeviceCount =
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified,
            ).devices.count
        facts.speechVoiceCount = voiceCount()
        #endif
        return facts
    }
}

extension DevicePermission {
    #if canImport(AVFoundation)
    /// Map TCC's camera/microphone status. Silent — no prompt.
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        default: self = .unknown
        }
    }
    #endif

    #if canImport(Speech)
    /// Map Speech-recognition authorization. Silent — no prompt.
    init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        default: self = .unknown
        }
    }
    #endif
}
