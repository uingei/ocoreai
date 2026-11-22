// Copyright © 2026 uingei@163.com.
// Licensed under MIT.

import Foundation

/// Sanitised environment for child processes spawned by ocoreai.
///
/// Child processes must not inherit server secrets (`OCOREAI_API_KEYS`,
/// `OCOREAI_ADMIN_KEYS`) or any other credential variables. This module
/// provides a minimal, auditable environment that is safe to hand to
/// `Process.environment`.
///
/// Design:
/// - Only the variables listed in `safeKeys` are allowed through.
/// - All other keys are stripped, including every `OCOREAI_*` secret.
/// - The set is intentionally small — if a child needs something new,
///   it must be added explicitly here with a reason.

@_spi(ChildProcessEnv)
public enum ChildProcessEnv {

    /// Variables allowed in child processes. Add new entries here with a reason.
    private static let safeKeys: Set<String> = [
        "PATH",  // executable lookup for every child
        "HOME",  // user config lookup (git, ssh, pip, …)
        "SHELL",  // shells read it; some tools depend on it
        "TERM",  // colour/ANSI output decisions
        "LANG",  // locale / encoding fallback
        "LC_ALL",  // explicit locale override
        "TMPDIR",  // temp directory for file creation
        "USER",  // username used by many CLI tools
        "LOGNAME",  // login name (may differ from USER)
        "XDG_RUNTIME_DIR",  // XDG runtime socket dir
        "OCOREAI_METALLIB",  // Metal shader library path (used by probes)
        "OCOREAI_PORT",  // HTTP bridge port (used by App bootstrap)
        "OCOREAI_HOST",  // HTTP bridge bind address
        "OCOREAI_ENABLE_HTTP",  // HTTP bridge toggle
        "OCOREAI_APPROVAL_POLICY",  // approval gate policy
        "OCOREAI_KV_REWIND_RESERVE_TOKENS",  // kv-cache rewind tuning
        "OCOREAI_EVAL_TOOLS",  // eval board tool set (scripts/eval reads it in the child)
        "HF_ENDPOINT",  // HuggingFace mirror URL
    ]

    /// Keys that are NEVER allowed, even if listed above — explicit deny list.
    private static let deniedKeys: Set<String> = [
        "OCOREAI_API_KEYS",
        "OCOREAI_ADMIN_KEYS",
        "OCOREAI_BEARER",
        "OCOREAI_TOKEN",
    ]

    /// Strip only the named secrets and keep everything else. For launchers that
    /// must carry the operator's own environment by design — `ocoreai connect`
    /// hands a harness the caller's config, so a full whitelist would break its
    /// contract; the secrets are what must never ride. The secret list has one
    /// home: `deniedKeys`, which both this and `sanitized` read.
    public static func removingSecrets(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        source.filter { !deniedKeys.contains($0.key) }
    }

    /// Return a sanitised environment dictionary for child processes.
    ///
    /// - Parameter source: the source environment (default: `ProcessInfo.processInfo.environment`).
    /// - Returns: a dictionary containing only safe variables.
    public static func sanitized(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        env.reserveCapacity(source.count)
        for (key, value) in source {
            // Denied keys are always stripped
            guard !deniedKeys.contains(key) else { continue }
            // Only whitelisted keys pass through
            guard safeKeys.contains(key) else { continue }
            env[key] = value
        }
        return env
    }
}
