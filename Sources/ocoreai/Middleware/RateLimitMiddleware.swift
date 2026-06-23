// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// RateLimitMiddleware — Token bucket rate limiter
///
/// ### Purpose:
/// Prevent per-IP or per-model burst traffic from overwhelming the engine pool.
///
/// ### Strategy:
/// - **Global rate limit**: All requests share one bucket (N requests/second)
/// - **Per-model rate limit**: Each model gets an independent bucket (anti-abuse)
/// - **Per-IP rate limit**: Each client IP gets an independent bucket (anti-abuse)
///
/// ### Algorithm:
/// Standard token bucket based on monotonic clock, thread-safe via ``actor`` mailbox serialization.
import Foundation
import HTTPTypes
import Hummingbird
import Logging

// MARK: - TokenBucket

/// Classic token bucket rate limiter implementation.
///
/// Tokens refill at a steady rate up to a maximum capacity.
/// Requests consume tokens; when depleted, requests are rejected.
/// Thread safety via `actor` mailbox serialization (no @MainActor — server-side pattern).
actor TokenBucket {
    /// Current available tokens
    private var available: Double

    /// Last refill timestamp
    private var lastRefill: ContinuousClock.Instant

    /// Token refill rate (tokens per second)
    private let rate: Double

    /// Maximum bucket capacity (burst limit)
    private let capacity: Double

    /// Initialize the bucket with the given rate and capacity.
    ///
    /// - Parameters:
    ///   - rate: Tokens added per second
    ///   - capacity: Maximum burst size
    init(rate: Double, capacity: Double) {
        precondition(rate > 0, "rate must be positive, got \(rate)")
        precondition(capacity > 0, "capacity must be positive, got \(capacity)")
        self.available = capacity // Start full
        self.lastRefill = .now
        self.rate = rate
        self.capacity = capacity
    }

    /// Try to acquire a single token (non-blocking).
    ///
    /// - Returns: `true` if token acquired, `false` if bucket empty
    @discardableResult
    func tryAcquire() -> Bool {
        refill()
        guard available >= 1.0 else { return false }
        available -= 1.0
        return true
    }

    /// Try to acquire the specified number of tokens (non-blocking).
    ///
    /// - Parameter count: Number of tokens to consume
    /// - Returns: `true` if all tokens acquired, `false` if insufficient
    @discardableResult
    func tryAcquire(count: Int) -> Bool {
        precondition(count > 0, "count must be positive")
        refill()
        guard available >= Double(count) else { return false }
        available -= Double(count)
        return true
    }

    /// Refill tokens based on elapsed time since last refill.
    private func refill() {
        let now = ContinuousClock.now
        let elapsed = Double(lastRefill.duration(to: now).components.seconds)
        guard elapsed > 0 else { return }
        available = Swift.min(capacity, available + elapsed * rate)
        lastRefill = now
    }

    /// Calculate seconds until at least one token is available.
    ///
    /// - Returns: Seconds until the next token, 0 if already available
    func timeUntilAvailable() -> Double {
        refill()
        guard available < 1.0 else { return 0 }
        let needed = 1.0 - available
        return needed / rate
    }
}

// MARK: - RateLimitProvider

/// Manages multiple token buckets for global, per-model, and per-IP rate limiting.
///
/// Automatically creates new buckets on first access and cleans up stale ones.
/// Thread safety via `actor` mailbox serialization.
actor RateLimitProvider {
    /// Configuration for rate limiting behavior
    struct Config: Sendable {
        /// Global requests-per-second limit
        var globalRate: Double = 100

        /// Global burst size limit
        var globalBurst: Int = 150

        /// Per-model requests-per-second limit
        var perModelRate: Double = 20

        /// Per-model burst size limit
        var perModelBurst: Int = 30

        /// Per-IP requests-per-second limit
        var perIPRate: Double = 10

        /// Per-IP burst size limit
        var perIPBurst: Int = 20

        /// Whether rate limiting is enabled (bypass when false)
        var enabled: Bool = true
    }

    /// Immutable configuration reference
    private let config: Config

    /// Global token bucket for all requests
    private let globalBucket: TokenBucket

    /// Timestamped bucket wrapper — enables time-based eviction
    private struct BucketEntry: Sendable {
        let bucket: TokenBucket
        var lastUsed: ContinuousClock.Instant
    }

    /// Per-model token buckets keyed by model ID, with lastUsed for eviction
    private var modelBucketEntries: [String: BucketEntry] = [:]

    /// Per-IP token buckets keyed by client IP string
    private var ipBuckets: [String: BucketEntry] = [:]

    /// Stale bucket eviction timeout (seconds)
    private static var staleTimeoutSeconds: Double { 600 } // 10 minutes

    /// Logger for observability
    private let logger: Logger

    /// Initialize the rate limit provider.
    ///
    /// - Parameters:
    ///   - config: Rate limiting configuration
    ///   - logger: Logger instance
    init(config: Config = Config(), logger: Logger) {
        self.config = config
        self.globalBucket = TokenBucket(rate: config.globalRate, capacity: Double(config.globalBurst))
        self.logger = logger
        precondition(config.globalRate > 0, "globalRate must be positive")
        precondition(config.perModelRate > 0, "perModelRate must be positive")
        precondition(config.perIPRate > 0, "perIPRate must be positive")
    }

    /// Get or create a model-bound token bucket, tracking last-used timestamp for eviction.
    ///
    /// Guarantees the returned bucket is persisted in ``modelBucketEntries``,
    /// so subsequent calls reuse the same actor instance.
    ///
    /// - Parameters:
    ///   - key: Bucket identifier (model ID)
    ///   - rate: Token refill rate for new buckets
    ///   - capacity: Bucket capacity for new buckets
    /// - Returns: Existing or newly created ``TokenBucket`` actor reference
    @discardableResult
    private func getOrCreateModelBucket(
        key: String,
        rate: Double,
        capacity: Double
    ) -> TokenBucket {
        let now = ContinuousClock.now
        if var entry = modelBucketEntries[key] {
            entry.lastUsed = now
            modelBucketEntries[key] = entry
            return entry.bucket
        }
        let newBucket = TokenBucket(rate: rate, capacity: capacity)
        modelBucketEntries[key] = BucketEntry(bucket: newBucket, lastUsed: now)
        return newBucket
    }

    /// Get or create an IP-bound token bucket, tracking last-used timestamp for eviction.
    ///
    /// - Parameters:
    ///   - key: IP address string
        ///   - rate: Token refill rate for new buckets
    ///   - capacity: Bucket capacity for new buckets
    /// - Returns: Existing or newly created ``TokenBucket`` actor reference
    @discardableResult
    private func getOrCreateIPBucket(
        key: String,
        rate: Double,
        capacity: Double
    ) -> TokenBucket {
        let now = ContinuousClock.now
        if var entry = ipBuckets[key] {
            entry.lastUsed = now
            ipBuckets[key] = entry
            return entry.bucket
        }
        let newBucket = TokenBucket(rate: rate, capacity: capacity)
        ipBuckets[key] = BucketEntry(bucket: newBucket, lastUsed: now)
        return newBucket
    }

    /// Extract client IP address from request headers.
    ///
    /// Tries in order:
    /// 1. ``X-Forwarded-For`` header (first entry) — for reverse proxy / load balancer
    /// 2. ``X-Real-IP`` header — for nginx-style frontends
    /// 3. ``uri.host`` as last fallback (only reliable when directly connected)
    ///
    /// - Parameter request: Incoming HTTP request
    /// - Returns: Client IP address string, never nil
    private func extractClientIP(from request: Request) -> String {
        // Reverse proxy: X-Forwarded-For: client, proxy1, proxy2
        if let xffName = HTTPField.Name("x-forwarded-for"),
           let xff = request.headers[xffName] {
            let first = xff.split(separator: ",", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? xff
            guard !first.isEmpty else { return "unknown" }
            return String(first)
        }

        // nginx-style: X-Real-IP: client
        if let xriName = HTTPField.Name("x-real-ip"),
           let xri = request.headers[xriName] {
            if !xri.isEmpty {
                return String(xri)
            }
        }

        // Direct connection fallback
        return request.uri.host ?? "unknown"
    }

    /// Check if a request should be allowed through rate limiting.
    ///
    /// Checks all three bucket dimensions (global, per-model, per-IP).
    /// All must pass for the request to be allowed.
    ///
    /// - Parameter request: HTTP request to evaluate
    /// - Returns: Tuple of `(allowed: Bool, retryAfter: Double?)`
    func check(_ request: Request) async -> (allowed: Bool, retryAfter: Double?) {
        guard config.enabled else { return (true, nil) }

        // 1. Global check
        guard await globalBucket.tryAcquire() else {
            let retryAfter = await globalBucket.timeUntilAvailable()
            return (false, retryAfter)
        }

        // 2. Per-endpoint check
        if let rateLimitKey = extractRateLimitKey(from: request) {
            let bucket = getOrCreateModelBucket(
                key: rateLimitKey,
                rate: config.perModelRate,
                capacity: Double(config.perModelBurst)
            )
            guard await bucket.tryAcquire() else {
                let retryAfter = await bucket.timeUntilAvailable()
                return (false, retryAfter)
            }
        }

        // 3. Per-IP check — use proper client IP extraction, not uri.host
        let ip = extractClientIP(from: request)
        let bucket = getOrCreateIPBucket(
            key: ip,
            rate: config.perIPRate,
            capacity: Double(config.perIPBurst)
        )
        guard await bucket.tryAcquire() else {
            let retryAfter = await bucket.timeUntilAvailable()
            return (false, retryAfter)
        }

        return (true, nil)
    }

    /// Extract a rate-limit key from the request path or query string.
    ///
    /// IMPORTANT: In OpenAI-compatible APIs, the model ID lives in the request body.
    /// Because reading the body in middleware consumes the stream, we cannot reliably
    /// extract the model ID here. Instead we derive a per-path key (e.g. `/v1/chat/completions`)
    /// so inference-heavy endpoints still get individualized rate limits.
    ///
    /// - Parameter request: Incoming HTTP request
    /// - Returns: Path-based rate limit key, or nil
    private func extractRateLimitKey(from request: Request) -> String? {
        // 1. Query parameters (for endpoints that do pass model in query)
        if let model = request.uri.queryParameters["model"] {
            return String(model)
        }

        // 2. Fallback: use request path as the rate-limit key
        //    (e.g. /v1/chat/completions, /v1/messages, /v1/count-tokens)
        //    This gives per-endpoint rate limiting even though we can't read the body.
        let path = request.uri.path
        guard !path.isEmpty, path != "/" else { return nil }
        return path
    }

    /// Generic stale entry eviction for any ``BucketEntry`` dictionary.
    ///
    /// - Parameters:
    ///   - dict: In-out dictionary of buckets to scan
    ///   - now: Current time for age calculation
    ///   - label: Label for logging (e.g. "model", "ip")
    /// - Returns: Number of entries evicted
    @discardableResult
    private func removeStaleEntries(
        in dict: inout [String: BucketEntry],
        now: ContinuousClock.Instant,
        label: String
    ) -> Int {
        let threshold = Self.staleTimeoutSeconds
        var stale: [String] = []
        for (key, entry) in dict where Double(entry.lastUsed.duration(to: now).components.seconds) > threshold {
            stale.append(key)
        }
        for key in stale {
            dict.removeValue(forKey: key)
        }
        logger.debug(
            "Rate limit cleanup: \(stale.count) \(label) bucket(s) evicted, \(dict.count) remaining",
            metadata: ["label": .string(label), "evicted": .string(String(stale.count))]
        )
        return stale.count
    }

    /// Clean up stale buckets (both IP and model) based on last-used timestamp.
    ///
    /// Entries older than 10 minutes (``staleTimeoutSeconds``) are evicted.
    /// Called periodically via ``cleanupPeriodically()``.
    private func cleanupStaleBuckets() {
        let now = ContinuousClock.now
        var modelBucketEntries = self.modelBucketEntries
        var ipBuckets = self.ipBuckets

        let modelEvicted = removeStaleEntries(in: &modelBucketEntries, now: now, label: "model")
        let ipEvicted = removeStaleEntries(in: &ipBuckets, now: now, label: "ip")

        self.modelBucketEntries = modelBucketEntries
        self.ipBuckets = ipBuckets

        guard modelEvicted > 0 || ipEvicted > 0 else { return }
        logger.info(
            "Rate limit: evicted \(modelEvicted) model + \(ipEvicted) IP buckets, \(self.ipBuckets.count) IP + \(self.modelBucketEntries.count) model remaining",
            metadata: [
                "model_stale": .string(String(modelEvicted)),
                "ip_stale": .string(String(ipEvicted)),
            ]
        )
    }

    /// Periodically clean up stale buckets to prevent unbounded memory growth.
    ///
    /// Returns a ``Task`` so the caller can cancel it during shutdown.
    /// The task captures ``self`` via ``TaskDetacher`` so the provider's
    /// lifetime is not extended by the cleanup loop.
    func cleanupPeriodically() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled, let _ = self {
                try? await Task.sleep(for: .seconds(Self.staleTimeoutSeconds / 2))
                await self?.cleanupStaleBuckets()
            }
        }
    }
}

// MARK: - RateLimitMiddleware

/// Hummingbird middleware that enforces rate limits on incoming requests.
///
/// Returns HTTP 429 with Retry-After header when rate limit is exceeded.
struct RateLimitMiddleware<Context: RequestContext>: Sendable, RouterMiddleware {
    /// Rate limit provider that manages token buckets
    private let provider: RateLimitProvider

    /// Logger for observability
    private let logger: Logger

    /// Initialize the middleware.
    ///
    /// - Parameters:
    ///   - provider: Rate limit provider instance
    ///   - logger: Logger instance
    init(provider: RateLimitProvider, logger: Logger) {
        self.provider = provider
        self.logger = logger
    }

    /// Process the request through rate limiting before passing to next responder.
    ///
    /// - Parameters:
    ///   - request: Incoming HTTP request
    ///   - context: Request context
    ///   - next: Closure to pass the request to the next responder
    /// - Returns: HTTP Response (200 passthrough or 429 rate limit error)
    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let result = await provider.check(request)

        guard !result.allowed else {
            return try await next(request, context)
        }

        // 429 Too Many Requests
        let bodyData = #"{"error":{"message":"Rate limit exceeded","type":"rate_limit","code":429}}"#.data(using: .utf8) ?? .init()
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/json"
        if let retryAfter = result.retryAfter {
            if let retryName = HTTPField.Name("Retry-After") {
                headers[retryName] = String(format: "%.0f", retryAfter)
            }
        }
        if let rateLimitName = HTTPField.Name("X-RateLimit-Limit") {
            headers[rateLimitName] = "exceeded"
        }

        return Response(status: .tooManyRequests, headers: headers, body: .init { writer in
            try await writer.write(ByteBuffer(data: bodyData))
        })
    }
}
