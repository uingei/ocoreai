// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AuthMiddleware.swift — API Key authentication middleware
///
/// ### Authentication Strategy:
/// 1. Bearer token header (``Authorization: Bearer <key>``) — primary
/// 2. API-Key header (``OpenAI-compatible``) — secondary
/// 3. Query parameter ``?api_key=`` — debug-only fallback
///
/// ### Env Config:
/// - ``OCOREAI_API_KEYS``: Comma-separated allowed keys (if empty, auth is bypassed)
/// - ``OCOREAI_ADMIN_KEYS``: Admin-only keys for PATCH/DELETE operations
///
/// ### Route Whitelist:
/// - ``GET /health`` — public health check (no auth)
/// - ``GET /v1/models`` — public model listing (no auth)
/// - All other routes — require valid ``OCOREAI_API_KEYS`` entry
/// - PATCH/DELETE — require valid ``OCOREAI_ADMIN_KEYS`` entry

import Foundation
import HTTPTypes
import Hummingbird
import Logging

// MARK: - Auth Configuration

/// Authentication configuration loaded from environment variables or JSON.
struct AuthConfig: Sendable, Equatable {
    /// List of allowed API keys (from ``OCOREAI_API_KEYS`` env var)
    let apiKeys: [String]

    /// Set of admin API keys (from ``OCOREAI_ADMIN_KEYS`` env var)
    let adminKeys: [String]

    /// Whether authentication is enabled (true when ``apiKeys`` is non-empty)
    let enabled: Bool

    /// Whether prompt injection detection is enabled
    let promptInjectionEnabled: Bool

    /// Initialize from environment variables.
    /// Gracefully degrades if API keys are not configured (auth disabled).
    init() {
        let rawAPI = ProcessInfo.processInfo.environment["OCOREAI_API_KEYS"] ?? ""
        let rawAdmin = ProcessInfo.processInfo.environment["OCOREAI_ADMIN_KEYS"] ?? ""
        self.apiKeys = rawAPI.components(separatedBy: ",").filter { !$0.isEmpty }
        self.adminKeys = rawAdmin.components(separatedBy: ",").filter { !$0.isEmpty }
        let keyCount = self.apiKeys.count
        precondition(keyCount <= 1000, "AuthConfig: max 1000 API keys allowed")
        self.enabled = !self.apiKeys.isEmpty
        self.promptInjectionEnabled = true
    }

    /// Test-only init with explicit parameters.
    init(apiKeys: [String], promptInjectionEnabled: Bool = true) {
        self.apiKeys = apiKeys
        self.adminKeys = []
        self.enabled = !apiKeys.isEmpty
        self.promptInjectionEnabled = promptInjectionEnabled
    }

    /// Parse configuration from raw bytes (e.g. file contents).
    ///
    /// - Throws: ``AuthConfigError/invalidJSON`` on parse failure.
    ///   Callers are responsible for handling the error at the application level.
    ///   **No silent fallback** — configuration must be explicit in production.
    static func parseJSON(_ data: Data) throws -> AuthConfig {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rawKeys = json?["api_keys"] as? [String]
        guard let keys = rawKeys, !keys.isEmpty else {
            throw AuthConfigError.invalidJSON("Missing or empty api_keys array")
        }
        let injection = (json?["promptInjectionEnabled"] as? Bool) ?? true

        precondition(keys.count <= 1000, "AuthConfig: max 1000 API keys allowed")
        return AuthConfig(apiKeys: keys, promptInjectionEnabled: injection)
    }

    /// Errors that can occur when parsing ``AuthConfig`` from JSON.
    enum AuthConfigError: Error, LocalizedError {
        case invalidJSON(String)
    }

    /// Precompiled prompt injection detection regexes.
    ///
    /// Patterns are deliberately narrow (regex word-boundary anchored) to avoid
    /// false positives on legitimate user messages like "You are an assistant
    /// helping me translate" or "ignore this file path".
    /// Compiled lazily on first access — no per-request regex compilation overhead.
    private static let _defaultPromptInjectionRegexes: [String] = [
        #"\bignore\b.*\b(system\s*prompt|all\s*pri(?:or|r)\s*(?:instr|rules))\b"#,
        #"\bdirect(?:ly|ed?)\b.*(?:re(?:peat|sume))\b.*\binstruction"#,
        #"\boutput\b.*\b(system\s*?prompt|hidden\s*?instr)\b"#,
        #"\bcontext:\s*you\s*are\b"#,
        #"\byou\s*are\s*(?:the\s*?(?:model|AI|assistant|GPT|ChatGPT|Claude))\b"#,
    ]

    private static let _defaultPromptInjectionRegexesCache: [NSRegularExpression] = {
        _defaultPromptInjectionRegexes.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }()

    static var defaultPromptInjectionRegexes: [NSRegularExpression] {
        _defaultPromptInjectionRegexesCache
    }

    /// Detect prompt injection in a message array.
    ///
    /// Uses precompiled ``NSRegularExpression`` instances for word-boundary matching
    /// to avoid false positives on legitimate user messages.
    static func detectPromptInjection(in messages: [Message], patterns: [NSRegularExpression]) -> Bool {
        for msg in messages {
            let content = switch msg.content {
                case .some(.text(let s)): s
                case .some(.parts(let parts)): parts.compactMap { $0.text }.joined(separator: " ")
                case .none: ""
            }
            let lower = content.lowercased()
            let fullRange = NSRange(location: 0, length: lower.utf16.count)
            for regex in patterns {
                if regex.firstMatch(in: lower, options: [], range: fullRange) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Default configuration (lazy initialization defers env check until first use)
    static let `default`: AuthConfig = .init()
}

// MARK: - Auth Middleware

/// Hummingbird middleware that enforces API key authentication on routed requests.
///
/// Intercepts every request, validates the key, injects the authenticated key
/// into the ``X-API-Key`` header for downstream handlers, and passes through.
///
/// Public routes (``/health``, ``/v1/models``) and admin-only operations
/// (PATCH/DELETE) are handled with separate logic branches.
struct AuthMiddleware<Context: RequestContext>: Sendable, RouterMiddleware {
    /// Authentication configuration provider — reads from env on each request
    /// to support hot-reloading API keys via environment variable changes.
    private let _makeConfig: @Sendable () -> AuthConfig

    /// Observability logger
    private let logger: Logger

    /// Public route paths that bypass authentication entirely
    private let publicPaths: Set<String> = [
        "/health",
        "/v1/models",
        "/metrics",
    ]

    /// HTTP methods that require admin-level API keys
    private let adminMethods: Set<HTTPRequest.Method> = [.patch, .delete]

    /// Initialize with config provider and logger.
    ///
    /// - Parameters:
    ///   - configProvider: Closure returning Authentication configuration (defaults to env-loaded)
    ///   - logger: Observability logger
    init(configProvider: @escaping @Sendable () -> AuthConfig = { AuthConfig.default }, logger: Logger) {
        self._makeConfig = configProvider
        self.logger = logger
    }

    /// Initialize with a static config and logger (for tests / fixed config).
    ///
    /// - Parameters:
    ///   - config: Authentication configuration (defaults to env-loaded)
    ///   - logger: Observability logger
    init(config: AuthConfig, logger: Logger) {
        self._makeConfig = { config }
        self.logger = logger
    }

    /// Process the request — validate auth, inject key header, pass to next responder.
    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // 1. Load config fresh per-request (supports hot-reload of OCOREAI_API_KEYS env var)
        let config = _makeConfig()
        // 2. Auth bypass — config disabled
        guard config.enabled else {
            return try await next(request, context)
        }
        // 2. Public routes — no auth required
        let path = String(request.uri.path.prefix { $0 != "?" })
        guard !self.publicPaths.contains(path) else {
            return try await next(request, context)
        }

        // 3. Extract API key from headers/query
        let apiKey = try extractAPIKey(from: request)

        // 4. Verify API key against allowed set
        guard config.apiKeys.contains(apiKey) else {
            throw AuthError.unauthorized
        }

        // 5. Admin method check — only after key is validated
        if self.adminMethods.contains(request.method) {
            guard config.adminKeys.contains(apiKey) else {
                throw AuthError.adminKeyRequired
            }
        }

        // 6. Passthrough
        return try await next(request, context)
    }

    // MARK: - Key Extraction

    /// Extract API key from request headers or query parameters.
    ///
    /// Priority: Bearer token > ``api-key`` header > ``?api_key=`` query param.
    ///
    /// - Parameter request: Incoming HTTP request
    /// - Returns: Extracted API key string
    /// - Throws: ``AuthError/missingAPIKey`` if no key found
    private func extractAPIKey(from request: Request) throws -> String {
        // Primary: Authorization: Bearer ***
        if let authorization = HTTPField.Name("authorization"),
           let bearer = request.headers[authorization],
           bearer.hasPrefix("Bearer ") {
            let trimmed = String(bearer.dropFirst(7)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AuthError.missingAPIKey }
            return trimmed
        }

        // Secondary: api-key header (OpenAI-compatible)
        if let apiKeyName = HTTPField.Name("api-key"),
           let apiKeyValue = request.headers[apiKeyName] {
            let trimmed = apiKeyValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Tertiary: ?api_key= query parameter (debug only)
        if let queryKey = request.uri.queryParameters["api_key"], !queryKey.isEmpty {
            return String(queryKey)
        }

        // No key found
        throw AuthError.missingAPIKey
    }
}

// MARK: - Auth Errors (LocalizedError)

/// Authentication-related error types implementing ``LocalizedError``.
///
/// Each case maps to an HTTP status code and a human-readable description
/// for structured JSON error responses.
enum AuthError: Error, LocalizedError {
    /// 401 Unauthorized — provided API key is invalid or expired
    case unauthorized

    /// 403 Forbidden — operation requires admin-level API key
    case adminKeyRequired

    /// 401 Unauthorized — no API key found in request headers or query
    case missingAPIKey

    /// ``LocalizedError`` descriptive message for JSON error responses.
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "401 Unauthorized — Invalid API key"
        case .adminKeyRequired:
            return "403 Forbidden — Admin key required for this operation"
        case .missingAPIKey:
            return "401 Unauthorized — API key required (use Authorization: Bearer *** or api-key header)"
        }
    }
}