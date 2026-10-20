// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! HubCredential.swift — one home for "may this request carry credentials, and exactly what
//! does the header say".
//!
//! ### Why this exists
//! Borrowed from codex #55607 (`f29d55ff06`, adjudicated 10-21), whose stated reason is
//! verbatim transferable: *"Synchronous auth header construction could silently return no
//! credentials when managed authentication became unavailable. Callers need an error to avoid
//! sending requests with missing or partial authentication."* codex made `add_auth_headers`
//! fallible; ocoreai's equivalent surface had three sites (`HubConfigFetcher`,
//! `ModelScopeSearchClient`, `ModelScopeDownloader`) each writing
//! `if let token { "Bearer \(token)" }`, which is a nil-check and not a validity check:
//!
//! - a token pasted with a trailing newline (`MODELSCOPE_TOKEN="$(cat token.txt)"`) produced a
//!   header value containing a control character. A CR/LF inside a field value is a
//!   request-splitting primitive, never part of a token;
//! - a blank/whitespace-only stored value produced `Authorization: Bearer ` — a request that
//!   *claims* to be authenticated while carrying no credentials, and comes back 401;
//! - when the hub refused, the user-facing text said `ModelScope API error (401)` and the gated
//!   hint said the repo *may* require a token (AGENTS.md invariant 2: speculate where the
//!   engine knows). This process knows whether it offered a credential, and whether the value
//!   it stored was usable — so it says that instead.
//!
//! ### Deliberate limits
//! Not anonymous-by-default: a hub call with no credential is legitimate (public repos answer
//! anonymously), so `.absent` still sends an unauthenticated request — with the state named in
//! any refusal. What is never legitimate is a *partial* credential on the wire. And nothing
//! here retries anything: `isRetryable(statusCode:)` is already that home; `HubRejection` only
//! decides what to **tell** the caller, and `HubCredentialTests` traverses both so they cannot
//! disagree about a status code.

import Foundation

// MARK: - Provider identity

/// Which hub a request goes to — the identity every credential decision is keyed on.
///
/// Declared here rather than in the UI file that first used it: `Engine/HubConfigFetcher`,
/// `Models/ModelIdentity` and `Models/ModelScopeDownloader` all key on it, so a type declared
/// under `UI/` made the engine depend on the surface above it. Its env variable and its
/// persisted key are declared two lines below, which is the whole point of that pairing.
enum HubSource: String, CaseIterable {
    case huggingFace = "HuggingFace"
    case modelScope = "ModelScope"
}

extension HubSource {
    /// The environment variable that carries this hub's access token. Part of the provider's
    /// identity, and named in advice text so the user can act on a refusal without guessing
    /// where the token came from (env or Settings).
    var envVar: String {
        switch self {
        case .huggingFace: return "HF_TOKEN"
        case .modelScope: return "MODELSCOPE_TOKEN"
        }
    }

    /// Where the user-saved (non-env) half of this provider's token lives on disk. The name is
    /// quoted in advice and read by `SettingsStore`, so it belongs next to `envVar` rather than
    /// in two files that can drift apart — `HubSourceCredentialIdentityTests` pins it against
    /// the `SettingsStore.Key` raw values.
    var userDefaultsKey: String {
        switch self {
        case .huggingFace: return "settings.hub.hfToken"
        case .modelScope: return "settings.hub.modelScopeToken"
        }
    }
}

// MARK: - Credential

/// A hub access token that has been checked well enough to put on the wire.
///
/// Invariant (the reason the type exists rather than a `String?`): `token` is non-empty,
/// contains only printable ASCII, and is within `maxTokenCharacters` — so `headerValue`
/// can never emit a partial credential or split a header.
struct HubCredential: Hashable, Sendable {
    /// Ceiling for a token value. Fine-grained HuggingFace tokens are JWTs (hundreds of
    /// characters); anything past this is a pasted blob, not a credential, and a request must
    /// not carry a megabyte-sized header because a Settings field got pasted into twice.
    static let maxTokenCharacters = 4096

    let token: String

    /// The complete `Authorization` field value. Built here, and nowhere else.
    var headerValue: String { "Bearer \(token)" }

    /// `nil` unless `rawValue` survives validation. The reason is reported by
    /// ``HubCredentialResolution/classify(rawValue:)``, which is what callers use.
    fileprivate init?(validated rawValue: String?) {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: Self.edgeWhitespace)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= Self.maxTokenCharacters else { return nil }
        guard Self.firstIllegalCharacter(in: trimmed) == nil else { return nil }
        self.token = trimmed
    }

    /// Whitespace at the edges is a paste artifact (`"$(cat token.txt)"`, a SecureField where
    /// Return was pressed); inside the value it is not a token character at all.
    static let edgeWhitespace = CharacterSet.whitespacesAndNewlines

    /// The first character that may never appear in a credential, or `nil`. Anything outside
    /// printable ASCII qualifies: non-ASCII cannot be sent in a field value without encoding,
    /// a space splits the value from its scheme, and CR/LF ends the header.
    static func firstIllegalCharacter(in value: String) -> Character? {
        value.first { character in
            guard let byte = character.asciiValue else { return true }
            return byte < 0x21 || byte > 0x7E
        }
    }
}

// MARK: - Resolution

/// Why a hub call carries no credential, when that is the case.
enum HubCredentialIssue: String, Equatable, Sendable {
    /// Something was stored, but nothing but whitespace survived: there are no credentials.
    case blank
    /// The stored value holds a space, CR, LF, or a non-ASCII character. A CR/LF would split a
    /// header, so this value is refused outright rather than sanitised into something the user
    /// never saved.
    case malformed
    /// Longer than ``HubCredential/maxTokenCharacters`` — a blob, not a token.
    case oversized
}

/// The result of asking "what credentials may this request offer?".
enum HubCredentialResolution: Equatable, Sendable {
    case available(HubCredential)
    /// Nothing was configured. An anonymous request is the honest answer, not a failure.
    case absent
    /// Something was configured and this process refused to send it. Named, because "the hub
    /// rejected you" and "we never asked with your token" are different fixes.
    case unusable(HubCredentialIssue)

    /// Classifies a raw stored/env value. Never mutates it into something else.
    static func classify(rawValue: String?) -> HubCredentialResolution {
        guard let rawValue else { return .absent }
        if let credential = HubCredential(validated: rawValue) { return .available(credential) }
        let trimmed = rawValue.trimmingCharacters(in: HubCredential.edgeWhitespace)
        if trimmed.isEmpty { return .unusable(.blank) }
        if trimmed.count > HubCredential.maxTokenCharacters { return .unusable(.oversized) }
        return .unusable(.malformed)
    }

    /// The precedence rule as its own function: of the two configured values, which one is the
    /// caller's intent. Spelled here and nowhere else — `SettingsStore` and the startup path in
    /// `App.swift` both need those same two lines, and a third copy is how "env vars take
    /// precedence" (a promise the Settings UI makes in its own label text) starts meaning
    /// different things on different surfaces. `HubSourceCredentialIdentityTests` pins that this
    /// is the only file in `Sources/` that reads the variable.
    ///
    /// Returns the *raw* value with validity unjudged: the Settings field must display whatever
    /// the user saved, including a value this process will refuse to send.
    static func precedence(
        source: HubSource,
        env: [String: String] = ProcessInfo.processInfo.environment,
        stored: String?,
    ) -> String? {
        env[source.envVar] ?? stored
    }

    /// Precedence, then validity: what this request may offer, given what is configured.
    /// The sites that put bytes on the wire use this rather than ``classify(rawValue:)``
    /// directly, so the env half of the answer cannot be dropped by a caller that read only
    /// Settings on its way down the constructor chain.
    static func resolve(
        source: HubSource,
        env: [String: String] = ProcessInfo.processInfo.environment,
        stored: String?,
    ) -> HubCredentialResolution {
        classify(rawValue: precedence(source: source, env: env, stored: stored))
    }

    var credential: HubCredential? {
        if case .available(let credential) = self { return credential }
        return nil
    }

    /// The complete header value, or `nil` when nothing may be sent. Call sites write
    /// `if let value = resolution.headerValue` — one spelling for "this request is authenticated".
    var headerValue: String? { credential?.headerValue }

    var offersCredential: Bool { credential != nil }

    /// Whether a credential went on the request, in one clause, as a measured fact. The
    /// gated-repository hint used to tell a user who *had* a token configured that the repo
    /// "may require MODELSCOPE_TOKEN", because the state never reached the message; this is
    /// the half of that sentence this process actually knows.
    func stateText(source: HubSource) -> String {
        switch self {
        case .available:
            return "an access token was offered"
        case .absent:
            return
                "no credential was offered (neither \(source.envVar) nor the Settings token is set)"
        case .unusable:
            return
                "no credential was offered (\(unusableReasonText ?? "the configured value was refused"))"
        }
    }

    /// One wording home for "we refused to send what was stored". Used by advice text so the
    /// diagnosis cannot read differently on two surfaces.
    var unusableReasonText: String? {
        switch self {
        case .available, .absent: return nil
        case .unusable(.blank):
            return "the configured value is blank (whitespace only)"
        case .unusable(.malformed):
            return "the configured value contains whitespace or non-printable characters and was "
                + "not sent (a CR/LF inside a header value would split the request)"
        case .unusable(.oversized):
            return "the configured value is longer than \(HubCredential.maxTokenCharacters) "
                + "characters and was not sent"
        }
    }
}

// MARK: - Refusal

/// What a hub's non-2xx answer means for the caller, and what to say about it.
struct HubRejection: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// The hub refused the credential that was on the request.
        case credentialRefused
        /// The hub accepted who the caller is but refused this repository.
        case accessDenied
        /// Worth another attempt (`isRetryable`).
        case transient
        /// Not retryable, not about credentials.
        case terminal
    }

    let source: HubSource
    let statusCode: Int
    let kind: Kind
    let credential: HubCredentialResolution

    /// `nil` for a 2xx — nothing happened. Retryability comes from `isRetryable(statusCode:)`,
    /// the existing home, so this cannot call a code transient while the retry loop sits on it
    /// (pinned by `HubRejectionAgreesWithRetryClassifier`).
    static func classify(
        statusCode: Int,
        credential: HubCredentialResolution,
        source: HubSource
    ) -> HubRejection? {
        guard !(200 ... 299).contains(statusCode) else { return nil }
        let kind: Kind
        switch statusCode {
        case 401: kind = .credentialRefused
        case 403: kind = .accessDenied
        default: kind = isRetryable(statusCode: statusCode) ? .transient : .terminal
        }
        return HubRejection(
            source: source, statusCode: statusCode, kind: kind, credential: credential)
    }

    /// Named `isTransient`, not `isRetryable`: inside this type a member with that
    /// name would shadow the free `isRetryable(statusCode:)` whose verdict this mirrors.
    var isTransient: Bool { kind == .transient }

    /// Actionable text for whatever surface reports this failure. States the measured fact —
    /// whether a credential was on the request at all — before any speculation about the
    /// repository.
    var advice: String {
        switch kind {
        case .credentialRefused:
            return
                "\(source.rawValue) refused authentication (HTTP \(statusCode)) — \(credentialClause)."
        case .accessDenied:
            return "\(source.rawValue) denied access (HTTP \(statusCode)) — \(credentialClause)."
        case .transient:
            return "\(source.rawValue) is temporarily unavailable (HTTP \(statusCode))."
        case .terminal:
            return "\(source.rawValue) returned HTTP \(statusCode)."
        }
    }

    /// The credential half of `advice`. `advice` names it for every refusal, because "we sent
    /// nothing" and "we sent what you configured" are different fixes even when the status is
    /// a 403 the hub gave for the repository rather than the token.
    private var credentialClause: String {
        switch credential {
        case .available:
            return "an access token was offered and refused — re-paste it in Settings → Model Hub, "
                + "or unset \(source.envVar) to go anonymous"
        case .unusable, .absent:
            return "\(credential.stateText(source: source)) — set a token in Settings → Model Hub "
                + "or \(source.envVar)"
        }
    }
}
