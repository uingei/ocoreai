import Foundation

/// Single source of truth for the Hugging Face endpoint lever.
///
/// Why this exists: the GUI mirror toggle, the CLI/headless startup path, and
/// the SwiftUI `Application.init` each resolved `HF_ENDPOINT` on their own —
/// with three different, mutually inconsistent rules. Consequences observed:
///
///   • The GUI toggle persisted `settings.hub.useHFMirror` (Bool) but every
///     startup re-applied a *phantom* `settings.hub.hfEndpointMirror` (String)
///     that no code ever wrote — so a user who enabled the mirror, quit, and
///     relaunched silently fell back to canonical huggingface.co and stalled on
///     a wall-blocked download with no signal.
///   • `HF_ENDPOINT_MIRROR` startup paths applied `setenv(..., 1)` unconditionally,
///     clobbering an explicit `HF_ENDPOINT` the operator had exported.
///
/// This type collapses all three entry points onto one pure, testable resolution
/// with a pinned precedence, and is deliberately NOT `@MainActor` so App.swift,
/// HeadlessServer, Application, and the SettingsStore setter can all call it.
enum HFMirrorPolicy {
    static let canonical = "https://huggingface.co"
    static let mirror = "https://hf-mirror.com"

    /// Persisted GUI toggle key (the *only* mirror key the store writes).
    static let persistedKey = "settings.hub.useHFMirror"

    /// Which lever produced the live endpoint — drives status display and
    /// Toggle enablement (HIG: visibility of system status; never offer a
    /// control that does nothing). Precedence is fixed; the GUI renders
    /// exactly this, bound to the same single criterion the tests pin.
    enum Source: Equatable {
        /// Operator exported HF_ENDPOINT explicitly — the Toggle is inert.
        case environment
        /// HF_ENDPOINT_MIRROR truthy env — the Toggle is inert.
        case mirrorEnv
        /// The persisted GUI toggle decides.
        case persistedToggle
        /// Nothing set; canonical default.
        case `default`
    }

    struct EndpointDecision: Equatable {
        let endpoint: String
        let source: Source

        /// True when env levers pin the endpoint and the GUI Toggle cannot
        /// change it — bind `.disabled()` to exactly this.
        var lockedByEnvironment: Bool {
            source == .environment || source == .mirrorEnv
        }
    }

    /// Pure precedence — pinned, no side effects, unit-testable:
    ///   1. explicit `HF_ENDPOINT` env var (operator overrides everything),
    ///   2. `HF_ENDPOINT_MIRROR` env var (headless/ops lever) when truthy,
    ///   3. the persisted GUI toggle,
    ///   4. canonical.
    ///
    /// An empty/whitespace value is treated as absent (a shell that exports
    /// `HF_ENDPOINT=""` is "unset", not "point here").
    static func resolveDecision(
        explicitEndpoint: String?,
        mirrorEnv: String?,
        useMirror: Bool
    ) -> EndpointDecision {
        if let explicit = explicitEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
            !explicit.isEmpty
        {
            return EndpointDecision(endpoint: explicit, source: .environment)
        }
        let truthy: (String?) -> Bool = { raw in
            guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            return ["1", "true", "yes", "on"].contains(v)
        }
        if truthy(mirrorEnv) { return EndpointDecision(endpoint: mirror, source: .mirrorEnv) }
        if useMirror { return EndpointDecision(endpoint: mirror, source: .persistedToggle) }
        return EndpointDecision(endpoint: canonical, source: .default)
    }

    /// Back-compat shim — the existing pinned matrix targets this signature.
    static func resolve(
        explicitEndpoint: String?,
        mirrorEnv: String?,
        useMirror: Bool
    ) -> String {
        resolveDecision(
            explicitEndpoint: explicitEndpoint,
            mirrorEnv: mirrorEnv,
            useMirror: useMirror
        ).endpoint
    }

    /// Operator env snapshot, captured exactly once.
    ///
    /// `ProcessInfo.environment` DOES reflect our own `setenv` on this macOS —
    /// live proof: the disable-mirror test read back `hf-mirror.com` that the
    /// enable test had just written (SettingsStoreTests.swift:205), so
    /// re-reading process env on every Toggle flip mistakes *our own derived
    /// value* for operator intent and sticks the mirror on forever. Swift
    /// static-let init is `dispatch_once` thread-safe, so one immutable
    /// snapshot is concurrency-clean without a mutable global: the startup
    /// entries take it before any of our setenv writes, and a mid-session
    /// Toggle flip resolves against that snapshot + the fresh persisted Bool.
    static let operatorEnvironment: [String: String] = ProcessInfo.processInfo.environment

    /// Read-only truth probe for the GUI: which endpoint is live and which
    /// lever owns it. Does NOT setenv — safe on view refresh. Resolves
    /// against `defaults` (the store's own suite, not `.standard`).
    static func current(defaults: UserDefaults = .standard) -> EndpointDecision {
        resolveDecision(
            explicitEndpoint: operatorEnvironment["HF_ENDPOINT"],
            mirrorEnv: operatorEnvironment["HF_ENDPOINT_MIRROR"],
            useMirror: defaults.bool(forKey: persistedKey)
        )
    }

    /// Read env + persisted defaults, then apply the decision to the process
    /// environment. Pass `env` explicitly in tests to stay hermetic.
    @discardableResult
    static func apply(
        env: [String: String]? = nil,
        defaults: UserDefaults = .standard
    ) -> EndpointDecision {
        let source = env ?? operatorEnvironment
        let decision = resolveDecision(
            explicitEndpoint: source["HF_ENDPOINT"],
            mirrorEnv: source["HF_ENDPOINT_MIRROR"],
            useMirror: defaults.bool(forKey: persistedKey)
        )
        setenv("HF_ENDPOINT", decision.endpoint, 1)
        return decision
    }
}

extension HFMirrorPolicy.Source {
    /// Localization handle for the status row (rendered via `.l`).
    var displayName: StringKey {
        switch self {
        case .environment: return .hfEndpointSourceEnvironment
        case .mirrorEnv: return .hfEndpointSourceMirrorEnv
        case .persistedToggle: return .hfEndpointSourcePersistedToggle
        case .default: return .hfEndpointSourceDefault
        }
    }
}
