// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineLifecycleState.swift — 6-state lifecycle machine + circuit breaker for EnginePool host
///
/// Replaces the fragile `isRunning` + `engineReady` boolean pair with a proper
/// state machine that tracks what the engine is actually doing, not just
/// "up or down".
///
/// ### State transitions:
///
/// ```
///    ┌──────────────────────────────────────────────────┐
///    │                                                  │
///    │   ┌───────┐    ┌───────┐                        │
///    │   │  IDLE │───>│STARTING│                        │
///    │   └───────┘    └───┬───┘                        │
///    │                    │                             │
///    │              ┌─────┴─────┐                       │
///    │              │  Success  │  Failure              │
///    │              ▼           │                       │
///    │          ┌──────┐  ┌────▼────┐                   │
///    │          │ READY │  │  ERROR  │                   │
///    │          └──┬───┘  └────┬────┘                   │
///    │             │           │ Retry OK                │
///    │             │ Degraded  ├────────> STARTING       │
///    │             ▼           │                         │
///    │          ┌───────┐     │                         │
///    │          │DEGRADED│    │                         │
///    │          └───┬───┘    │                         │
///    │              │        │                         │
///    │              │ Stop   │ Stop                    │
///    │              ▼        ▼                         │
///    │         ┌─────────┐                            │
///    │         │ STOPPING│──> IDLE (on cleanup done)  │
///    │         │         │──> ERROR (on timeout)      │
///    │         └─────────┘                            │
///    └─────────────────────────────────────────────────┘
/// ```
///
/// ### Circuit Breaker:
/// Tracks consecutive startup failures. After `maxConsecutiveFailures` (default 3),
/// the circuit opens — subsequent `start()` calls return immediately without
/// attempting to bootstrap. Manual `resetCircuit()` closes it again.

import Foundation

/// Engine lifecycle state — implicitly Sendable (all stored properties are Sendable).
public enum EngineLifecycleState: String, Codable, Sendable {
	/// Engine is not running, no pending initialization in flight.
	case idle = "idle"
	
	/// Initialization in progress — components are being bootstrapped.
	case starting = "starting"
	
	/// All core components running and accepting inference requests.
	case ready = "ready"
	
	/// Core running but at least one subsystem degraded (e.g. HTTP server failed).
	case degraded = "degraded"

	/// Engine is shutting down — cancelling tasks, releasing resources.
	case stopping = "stopping"

	/// Startup failed and circuit breaker is open.
	/// Subsequent start() calls block until resetCircuit() is called.
	case error = "error"

	/// Whether the engine can accept inference requests.
	public var isHealthy: Bool {
		switch self {
		case .ready, .degraded: return true
		default: return false
		}
	}

	/// Whether the engine is in a starting/stopping transitional state.
	public var isTransitioning: Bool {
		switch self {
		case .starting, .stopping: return true
		default: return false
		}
	}

	/// Human-readable status label for UI display.
	public var displayLabel: String {
		switch self {
		case .idle:       "Idle"
		case .starting:   "Starting..."
		case .ready:      "Ready"
		case .degraded:   "Degraded"
		case .stopping:   "Stopping..."
		case .error:      "Circuit Open"
		}
	}

	/// System icon for UI status indicators.
	public var statusIcon: String {
		switch self {
		case .idle:       "circle.dashed"
		case .starting:   "arrow.triangle.2.circlepath"
		case .ready:      "checkmark.circle.fill"
		case .degraded:   "exclamationmark.triangle.fill"
		case .stopping:   "pause.circle.fill"
		case .error:      "xmark.octagon.fill"
		}
	}
}

/// Circuit breaker for engine startup — prevents crash-loop by tracking
/// consecutive failures and enforcing a cooldown period.
///
/// Default: 3 consecutive failures before circuit opens.
/// Once open, start() refuses to attempt bootstrap until resetCircuit().
/// Runs on MainActor via OcoreaiEngine — no @Sendable needed.
final class EngineCircuitBreaker {

	/// Maximum consecutive failures before opening the circuit.
	let maxFailures: Int

	/// Minimum cooldown period (seconds) after circuit opens.
	private let cooldownSeconds: Int

	/// Track individual failure timestamps for sliding window.
	private var failureTimestamps: [UInt64] = []

	/// Whether the circuit is currently open (blocking starts).
	private var _isOpen: Bool = false

	/// Current failure count within the window.
	private var _failureCount: Int = 0

	/// Last failure timestamp (nanoseconds since process start).
	private var _lastFailureNano: UInt64 = 0

	/// Create a circuit breaker with the given parameters.
	init(
		maxConsecutiveFailures: Int = 3,
		cooldownSeconds: Int = 60
	) {
		precondition(maxConsecutiveFailures >= 1, "Must allow at least 1 failure")
		self.maxFailures = maxConsecutiveFailures
		self.cooldownSeconds = cooldownSeconds
	}

	/// Check if the circuit is open (blocking new starts).
	/// - Returns: `true` if the circuit should block attempts.
	public var isCircuitOpen: Bool {
		_isOpen
	}

	/// Current number of consecutive failures (for UI display / diagnostics).
	public var failureCount: Int {
		_failureCount
	}

	/// Record a successful startup — resets the failure counter.
	public func recordSuccess() {
		_failureCount = 0
		self.failureTimestamps.removeAll()
	}

	/// Record a startup failure.
	/// If the failure count reaches `maxFailures`, the circuit opens.
	public func recordFailure() {
		let nano = UInt64(DispatchTime.now().uptimeNanoseconds)
		self.failureTimestamps.append(nano)
		_lastFailureNano = nano
		_failureCount += 1

		if _failureCount >= maxFailures {
			_isOpen = true
		}
	}

	/// Ask whether a new start attempt should be allowed.
	/// - Returns: `true` if the caller should proceed with bootstrap.
	///
	/// If the circuit already failed and the cooldown has NOT elapsed,
	/// this returns `false` to prevent a crash-loop.
	public func allowStart() -> Bool {
		guard _isOpen else { return true }

		let elapsed = UInt64(DispatchTime.now().uptimeNanoseconds - _lastFailureNano) / 1_000_000_000
		if elapsed >= cooldownSeconds {
			// Cool down expired — allow one more attempt
			return true
		}

		// Still in cooldown — block the attempt
		return false
	}

	/// Manually reset the circuit breaker — closes the circuit, clears failure count.
	/// Call this after the user fixes the environment (e.g. frees up GPU memory).
	public func resetCircuit() {
		_isOpen = false
		_failureCount = 0
		self.failureTimestamps.removeAll()
	}

	/// Seconds remaining before the cooldown expires (0 if not open).
	public func cooldownRemaining() -> Int {
		guard _isOpen else { return 0 }
		let elapsed = UInt64(DispatchTime.now().uptimeNanoseconds - _lastFailureNano) / 1_000_000_000
		return max(0, cooldownSeconds - Int(elapsed))
	}
}
