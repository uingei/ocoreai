import Foundation
import Testing

@testable import ocoreai

/// Pins the single HF_ENDPOINT precedence for all three startup entries
/// (App / Application.init / HeadlessServer) and the GUI Toggle setter.
/// The pre-fix behavior was three divergent rules — one reading a phantom
/// UserDefaults key, two clobbering an explicit HF_ENDPOINT — so every
/// precedence edge below is a regression gate, not decoration.
struct HFMirrorPolicyTests {

    // MARK: - resolve: pure precedence matrix (verbatim)

    @Test func explicitEndpointEnvBeatsEverything() {
        #expect(
            HFMirrorPolicy.resolve(
                explicitEndpoint: "https://proxy.example", mirrorEnv: "1", useMirror: true)
                == "https://proxy.example")
        #expect(
            HFMirrorPolicy.resolve(
                explicitEndpoint: "https://proxy.example", mirrorEnv: nil, useMirror: true)
                == "https://proxy.example")
        #expect(
            HFMirrorPolicy.resolve(
                explicitEndpoint: "https://proxy.example", mirrorEnv: nil, useMirror: false)
                == "https://proxy.example")
    }

    @Test func whitespaceExplicitEndpointCountsAsAbsent() {
        #expect(
            HFMirrorPolicy.resolve(explicitEndpoint: "   ", mirrorEnv: "1", useMirror: false)
                == HFMirrorPolicy.mirror)
        #expect(
            HFMirrorPolicy.resolve(explicitEndpoint: "\n", mirrorEnv: nil, useMirror: false)
                == HFMirrorPolicy.canonical)
    }

    @Test func mirrorEnvTruthyValuesAllEnableMirror() {
        for truthy in ["1", "true", "TRUE", "Yes", "on", " true "] {
            #expect(
                HFMirrorPolicy.resolve(explicitEndpoint: nil, mirrorEnv: truthy, useMirror: false)
                    == HFMirrorPolicy.mirror, "truthy mirrorEnv must select mirror: \(truthy)")
        }
    }

    @Test func mirrorEnvNonTruthyDoesNotEnableMirror() {
        for falsy in ["0", "false", "no", "off", "", "maybe"] {
            #expect(
                HFMirrorPolicy.resolve(explicitEndpoint: nil, mirrorEnv: falsy, useMirror: false)
                    == HFMirrorPolicy.canonical, "falsy mirrorEnv must stay canonical: \(falsy)")
        }
    }

    @Test func persistedToggleEnablesMirrorWhenNoEnv() {
        // THE regression gate: GUI toggle ON + no env → mirror. Pre-fix, the
        // startup paths read only env / a phantom String key and lost this.
        #expect(
            HFMirrorPolicy.resolve(explicitEndpoint: nil, mirrorEnv: nil, useMirror: true)
                == HFMirrorPolicy.mirror)
        #expect(
            HFMirrorPolicy.resolve(explicitEndpoint: nil, mirrorEnv: "0", useMirror: true)
                == HFMirrorPolicy.mirror)
    }

    @Test func allAbsentStaysCanonical() {
        #expect(
            HFMirrorPolicy.resolve(explicitEndpoint: nil, mirrorEnv: nil, useMirror: false)
                == HFMirrorPolicy.canonical)
    }

    // MARK: - persisted key contract

    @Test func persistedKeyMatchesStoreKey() {
        // SettingsStore.Key.useHFMirror.rawValue is the ONLY persisted mirror
        // key; a rename on either side without the other breaks relaunch.
        #expect(HFMirrorPolicy.persistedKey == "settings.hub.useHFMirror")
    }

    @Test(
        .disabled(
            "apply mutates the real HF_ENDPOINT process env; resolution itself is fully pinned by the resolve() matrix above"
        )) func applyWritesResolvedEndpointToProcessEnv()
    {
        let suiteName = "hfmirror.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: HFMirrorPolicy.persistedKey)
        // Fresh process: no operator env → persisted toggle wins → mirror.
        // NOTE: this pollutes the process-global HF_ENDPOINT for the test
        // runner; kept disabled by default, re-run standalone when touching
        // apply()'s precedence logic.
        let endpoint = HFMirrorPolicy.apply(env: [:], defaults: suite)
        #expect(endpoint == HFMirrorPolicy.mirror)
        #expect(ProcessInfo.processInfo.environment["HF_ENDPOINT"] == HFMirrorPolicy.mirror)
    }

    @Test func endpointsAreHTTPSNoPath() {
        // Consumers concatenate "/api/…" — a trailing slash would double it.
        for endpoint in [HFMirrorPolicy.canonical, HFMirrorPolicy.mirror] {
            #expect(endpoint.hasPrefix("https://"))
            #expect(!endpoint.hasSuffix("/"))
        }
    }
}
