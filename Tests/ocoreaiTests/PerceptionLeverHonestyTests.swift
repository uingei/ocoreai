// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PerceptionLeverHonestyTests — every perception channel flag the settings
/// surface composes must be the value the runtime actually honors.
///
/// Bugs this kills (all live before this slice):
///   1. `PerceptionEngine.start()` hardcoded `channels.network = true`,
///      silently overwriting the user's persisted choice on every restart.
///   2. `SettingsViewModel.applyPerceptionSettings()` hardcoded
///      `network: true` — no lever existed for the network channel at all.
///   3. `perceptionSystemEnabled` / `perceptionSpeakerEnabled` persisted but
///      `load()` never restored them and SettingsView rendered no row —
///      phantom levers: the store implied a setting the user could never
///      reach.
///
/// The source-scan locks are not style lint: they fail on any reintroduced
/// unconditional overwrite of these flags (grep the patched files for the
/// exact overwrite shapes).

import Foundation
import Testing

@testable import ocoreai

@MainActor
@Suite("Perception levers — persisted value is the runtime value")
struct PerceptionLeverHonestyTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ocoreai.\(UUID().uuidString)")!
    }

    private func store() -> SettingsStore {
        SettingsStore(defaults: freshDefaults())
    }

    // MARK: - Store contract

    @Test("network lever defaults ON (shipped behavior preserved)")
    func networkDefaultOn() {
        #expect(store().perceptionNetworkEnabled == true)
    }

    @Test("network lever OFF persists and survives reload")
    func networkOffPersists() {
        let d = freshDefaults()
        SettingsStore(defaults: d).perceptionNetworkEnabled = false
        #expect(SettingsStore(defaults: d).perceptionNetworkEnabled == false)
        // OFF must be distinguishable from "never voted" at the raw layer.
        #expect(d.object(forKey: SettingsStore.Key.perceptionNetworkEnabled.rawValue) != nil)
    }

    // MARK: - Engine: user flags survive start() resync

    @Test("start() does not overwrite user-set channel flags")
    func startPreservesUserFlags() async {
        let engine = PerceptionEngine()
        let flags = ChannelFlags(
            camera: false,
            screen: false,
            network: false,
            filesystem: false,
            internet: false,
            system: false,
            speaker: false,
            audio: false
        )
        engine.setChannels(flags)
        await engine.start()
        // Resync may only touch camera/screen (live permission truth).
        #expect(engine.channels.network == false, "network must stay user-set")
        #expect(engine.channels.system == false, "system must stay user-set")
        #expect(engine.channels.speaker == false, "speaker must stay user-set")
        #expect(engine.channels.filesystem == false)
        #expect(engine.channels.internet == false)
        #expect(engine.channels.audio == false)
        engine.stop()
    }

    @Test("engine respects OFF at first start when network voted OFF")
    func firstStartRespectsNetworkOff() async {
        let engine = PerceptionEngine()
        let flags = ChannelFlags(
            camera: false,
            screen: false,
            network: false,
            filesystem: true,
            internet: false,
            system: false,
            speaker: false,
            audio: false
        )
        engine.setChannels(flags)
        await engine.start()
        #expect(engine.channels.network == false)
        // .network channel context must not be advertised as active.
        #expect(!engine.activeChannels.contains(.network))
        engine.stop()
    }

    @Test("resync honors camera/screen authority of MultimodalState at compose time")
    func resyncCameraScreen() throws {
        // The VM composes camera/screen from MultimodalState (live permission
        // truth) — locked at the source choke so a future refactor cannot
        // silently freeze them false while the store says otherwise.
        let src = try Self.source("Sources/ocoreai/UI/ViewModels/SettingsViewModel.swift")
        #expect(src.contains("camera: MultimodalState.shared.cameraEnabled"))
        #expect(src.contains("screen: MultimodalState.shared.screenCaptureEnabled"))
        // And start()'s resync must not clobber network/system/speaker.
        let engineSrc = try Self.source("Sources/ocoreai/Multimodal/PerceptionEngine.swift")
        #expect(engineSrc.contains("channels.camera = mmState.cameraEnabled"))
        #expect(!engineSrc.contains("channels.network = true"))
    }

    // MARK: - Source-scan: no re-poison

    private static func repoRoot() -> String {
        var dir = FileManager.default.currentDirectoryPath
        while true {
            if FileManager.default.fileExists(atPath: dir + "/.env.example") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return FileManager.default.currentDirectoryPath
    }

    private static func source(_ relative: String) throws -> String {
        let raw = try String(contentsOfFile: repoRoot() + "/" + relative, encoding: .utf8)
        // Strip line comments before scanning: honest history comments may
        // QUOTE the forbidden token; only executable text may contain it.
        return
            raw
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    /// Remove ALL whitespace (not just spaces) — swift-format legally wraps
    /// conditions across lines, so scanners must match logical, not textual,
    /// shape.
    private static func compact(_ s: Substring) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    @Test("PerceptionEngine.start() never hardcodes channels/network sensor ON")
    func noEngineOverwrite() throws {
        let src = try Self.source("Sources/ocoreai/Multimodal/PerceptionEngine.swift")
        // Extract start()'s body by brace matching.
        guard let startRange = src.range(of: "func start() async") else {
            Issue.record("start() not found")
            return
        }
        let after = src[startRange.upperBound...]
        var depth = 0
        var body = ""
        for ch in after {
            if ch == "{" { depth += 1 }
            if depth > 0 { body.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        let compact = Self.compact(body[body.index(body.startIndex, offsetBy: 1)...])
        #expect(
            !compact.contains("channels.network=true"),
            "start() must not overwrite the network lever"
        )
        // NetworkSensor.startMonitoring must sit inside the honest gate.
        #expect(
            !compact.contains("_=NetworkSensor.shared.startMonitoring()")
                || compact.contains("ifchannels.network||channels.internet{"),
            "NetworkSensor.startMonitoring() must stay gated by network||internet"
        )
    }

    @Test("SettingsViewModel composes the network lever, not a literal true")
    func noViewModelHardcode() throws {
        let src = try Self.source("Sources/ocoreai/UI/ViewModels/SettingsViewModel.swift")
        guard let fnRange = src.range(of: "func applyPerceptionSettings()") else {
            Issue.record("applyPerceptionSettings() not found")
            return
        }
        let after = src[fnRange.upperBound...]
        var depth = 0
        var body = ""
        for ch in after {
            if ch == "{" { depth += 1 }
            if depth > 0 { body.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        #expect(
            !body.contains("network: true"),
            "applyPerceptionSettings() must read the persisted lever"
        )
        #expect(body.contains("network: perceptionNetworkEnabled"))
    }

    // MARK: - Phantom-lever locks: persisted keys surface in UI + load()

    @Test("every perception Store key has a StringKey with en+zh text")
    func perceptionKeysHaveLocalizedRows() {
        let pairs: [(SettingsStore.Key, StringKey)] = [
            (.perceptionEnabled, .perceptionToggle),
            (.perceptionFilesystemEnabled, .perceptionFilesystem),
            (.perceptionInternetEnabled, .perceptionInternet),
            (.perceptionNetworkEnabled, .perceptionNetwork),
            (.perceptionSystemEnabled, .perceptionSystem),
            (.perceptionSpeakerEnabled, .perceptionSpeaker),
            (.perceptionAudioEnabled, .perceptionAudio),
        ]
        for (sk, lk) in pairs {
            #expect(
                L10nTables.base[lk]?.isEmpty == false,
                "en table missing row for \(sk.rawValue)"
            )
            #expect(
                L10nTables.zh[lk]?.isEmpty == false,
                "zh table missing row for \(sk.rawValue)"
            )
        }
    }

    @Test("SettingsView renders a Toggle binding for every perception lever")
    func settingsViewBindsEveryLever() throws {
        let src = try Self.source("Sources/ocoreai/UI/Views/SettingsView.swift")
        for lever in [
            "perceptionNetworkEnabled",
            "perceptionSystemEnabled",
            "perceptionSpeakerEnabled",
            "perceptionFilesystemEnabled",
            "perceptionInternetEnabled",
            "perceptionAudioEnabled",
        ] {
            #expect(
                src.contains("$settingsState.\(lever)"),
                "SettingsView must bind \(lever) — persisted without UI = phantom lever"
            )
        }
    }

    @Test("cold boot wires persisted perception into the live engine")
    func coldBootWiresPerception() throws {
        // Live-observed 10-10: persisted perception=true NEVER started the
        // engine because applyPerceptionSettings was reachable only from
        // toggle didSet. The fix is a boot hook; this lock ensures the
        // hook stays wired at BOTH ends (definition + launch call site).
        let vmSrc = try Self.source("Sources/ocoreai/UI/ViewModels/SettingsViewModel.swift")
        let appSrc = try Self.source("Sources/ocoreai/UI/Models/AppState.swift")
        let compactVM = Self.compact(vmSrc[...])
        let compactApp = Self.compact(appSrc[...])
        #expect(
            compactVM.contains("funcbootPerceptionFromStore()"),
            "boot hook must exist on SettingsState"
        )
        #expect(
            compactVM.contains("reloadFromStore()") && compactVM.contains("applyPerceptionSettings()"),
            "boot hook must restore persisted truth AND apply it to the engine"
        )
        #expect(
            compactApp.contains("SettingsState.shared.bootPerceptionFromStore()"),
            "AppState.initialize() must call the boot hook — persisted settings boot the engine"
        )
    }

    @Test("SettingsViewModel.load() restores every perception lever")
    func loadRestoresEveryLever() throws {
        let src = try Self.source("Sources/ocoreai/UI/ViewModels/SettingsViewModel.swift")
        for lever in [
            "perceptionNetworkEnabled",
            "perceptionSystemEnabled",
            "perceptionSpeakerEnabled",
            "perceptionFilesystemEnabled",
            "perceptionInternetEnabled",
            "perceptionAudioEnabled",
        ] {
            #expect(
                src.contains("\(lever) = SettingsStore.shared.\(lever)"),
                "load() must restore \(lever) from persisted truth"
            )
        }
    }
}
