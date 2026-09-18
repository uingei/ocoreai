// Copyright © 2026 uingei@163.com.
/// ConfigRecovery.swift — Last-known-good config recovery (config corruption guard)
///
/// Consume pattern from hermes-agent `de2d6a1b93` ("a fresh process recovers the
/// last good config.yaml instead of running on defaults"): every successful
/// parse leaves a `good` copy under `backups/config/`; a fresh process whose
/// on-disk config is corrupt restores that copy instead of silently running on
/// defaults — and never clobbers the user's file.
///
/// The flaw this guards against: `ConfigSystem.create()` running `saveDefault()` on
/// ANY load failure (corrupt YAML, decode error, validation error) overwrites
/// the user's `~/.ocoreai/config.yaml` — including their `safety:` approval
/// rules and per-model settings — with `AppConfig()` defaults. Data loss, not
/// degradation.
///
/// Exact-value testable: all entry points take explicit paths (no NSHomeDirectory
/// coupling) so tests run in a temp directory and never touch the real config.

import Foundation
import Logging
import Yams

enum ConfigRecovery {
    /// Last-known-good snapshot location for a given config path:
    /// `<configDir>/backups/config/config.yaml.good`
    /// (hermes layout: "leaves a `good` copy in backups/config/").
    static func goodPath(forConfigPath configPath: String) -> String {
        let dir = (configPath as NSString).deletingLastPathComponent
        return "\(dir)/backups/config/config.yaml.good"
    }

    /// Decode + validate a config file. Throws on read, YAML syntax error, a
    /// document carrying no recognized top-level key, or validation failure.
    static func decode(at path: String) throws -> AppConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let loaded = try decodeVerifiedConfig(from: data)
        try loaded.validate()
        return loaded
    }

    /// Snapshot a config file we just parsed+validated (success path) into the
    /// last-known-good location. Atomic write, file mode 0600, parents 0700.
    ///
    /// The good copy is **semantically verified BEFORE it is copied** (not
    /// just byte-duplicated): `decode(at:)` — decode + `validate()` — must
    /// succeed, otherwise the corrupt/invalid file is REJECTED and the
    /// previous good snapshot survives untouched. A plain raw byte copy is not
    /// a guard: a syntactically-parseable-but-invalid file (or a partially
    /// parsed corrupt one) becomes "valid" the moment it lands at the good
    /// path, and `restoreLastGood` would hand it back next startup.
    /// Callers: `ConfigSystem.load()` (startup), `ConfigSystem.save()` (after a
    /// round-trip-verified write), `ConfigSystem.saveDefault()` (first run).
    static func snapshotGood(fileAt path: String, logger: Logger) throws {
        // Verification gate — decode + validation must both succeed before any
        // byte of `path` is allowed to replace the last-known-good copy.
        try decode(at: path)
        let fm = FileManager.default
        let good = goodPath(forConfigPath: path)
        let goodDir = (good as NSString).deletingLastPathComponent
        try fm.createDirectory(
            atPath: goodDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try data.write(to: URL(fileURLWithPath: good), options: .atomic)
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: good)
        } catch {
            logger.warning("Could not set 0600 on \(good): \(error)")
        }
    }

    /// Restore the last-known-good copy for a corrupt `path`.
    /// - Returns the decoded good config if the snapshot exists, decodes, and
    ///   validates — leaving the corrupt file on disk untouched (inspectable,
    ///   user can diff against the restored content).
    /// - Returns nil when no usable snapshot exists (fresh install, or the
    ///   snapshot itself is corrupt) — caller decides (saveDefault, etc.).
    static func restoreLastGood(
        forCorruptFileAt path: String,
        logger: Logger
    ) -> AppConfig? {
        let good = goodPath(forConfigPath: path)
        guard FileManager.default.fileExists(atPath: good) else { return nil }
        do {
            let restored = try decode(at: good)
            logger.warning(
                "Config \(path) is unreadable/invalid — restored last-known-good from \(good)"
            )
            return restored
        } catch {
            logger.warning(
                "Last-known-good snapshot at \(good) is itself invalid — no recovery: \(error)"
            )
            return nil
        }
    }

    /// After `save()` writes a new config, verify the on-disk file round-trips
    /// (decode + validate). Refreshes the good snapshot when it does.
    /// Returns false when the round-trip fails — caller surfaces the failure;
    /// the good snapshot is NOT updated from an unverified write.
    @discardableResult
    static func verifyAndSnapshot(
        newFileAt path: String,
        logger: Logger
    ) -> Bool {
        do {
            _ = try decode(at: path)
        } catch {
            logger.warning("Config round-trip verification failed after save: \(error)")
            return false
        }
        do {
            try snapshotGood(fileAt: path, logger: logger)
            return true
        } catch {
            logger.warning("Could not refresh last-known-good snapshot: \(error)")
            return false
        }
    }
}
