// Copyright © 2026 uingei@163.com.
/// ConfigRecoveryTests.swift — Last-known-good config recovery (hermes `de2d6a1b93` pattern)
///
/// Exact-value assertions (test-quality rule — no count>N):
///   * good-path layout is exactly `<dir>/backups/config/config.yaml.good`,
///   * snapshot round-trips decode to the EXACT same AppConfig,
///   * corrupt main file + usable snapshot → restored EXACT config, corrupt file
///     left on disk byte-for-byte (inspectable, NOT clobbered),
///   * no snapshot → nil; corrupt snapshot → nil,
///   * unverified (corrupt) write does NOT refresh the good snapshot (stale value kept),
///   * verified write DOES refresh the good snapshot (new exact value visible).
///
/// All paths are injected — tests never touch `~/.ocoreai`.

import Foundation
import Logging
import Testing
import Yams

@testable import ocoreai

@Suite("ConfigRecovery — last-known-good config recovery")
struct ConfigRecoveryTests {
    // MARK: - Fixture

    private static let logger = Logger(label: "test.config-recovery")

    /// A valid config with EXACT, distinguishable values (round-trip fingerprint).
    private static func exactConfig() -> AppConfig {
        var c = AppConfig()
        c.server.port = 18092
        c.server.host = "127.0.0.9"
        if var m = c.models["default"] {
            m.modelId = "fixture-model-0"
            c.models["default"] = m
        }
        return c
    }

    private static func writeConfig(_ config: AppConfig, to path: String) throws {
        let yaml = try YAMLEncoder().encode(config)
        try yaml.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// Fresh temp dir + valid config at `configPath`; yields (configPath, goodPath).
    private static func fixture() throws -> (String, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfgrec_\(UUID().uuidString.prefix(8))")
        let configPath = dir.appendingPathComponent("config.yaml").path
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        try writeConfig(exactConfig(), to: configPath)
        return (configPath, ConfigRecovery.goodPath(forConfigPath: configPath))
    }

    private static func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Path layout (exact)

    @Test("goodPath is <configDir>/backups/config/config.yaml.good (exact layout)")
    func goodPathLayoutExact() {
        let cfg = "/home/u/.ocoreai/config.yaml"
        #expect(
            ConfigRecovery.goodPath(forConfigPath: cfg)
                == "/home/u/.ocoreai/backups/config/config.yaml.good",
            "got \(ConfigRecovery.goodPath(forConfigPath: cfg))"
        )
        let bare = "/tmp/x"
        #expect(
            ConfigRecovery.goodPath(forConfigPath: bare) == "/tmp/backups/config/config.yaml.good")
    }

    // MARK: - Decode (valid / invalid)

    @Test("decode: valid YAML round-trips to the EXACT same AppConfig")
    func decodeRoundTripExact() throws {
        let (cfg, _) = try Self.fixture()
        defer { Self.cleanup(((cfg as NSString).deletingLastPathComponent)) }

        let decoded = try ConfigRecovery.decode(at: cfg)
        #expect(decoded == Self.exactConfig(), "decoded config must equal the exact fixture")
        #expect(decoded.server.port == 18092)
    }

    @Test("decode: corrupt YAML throws (does NOT silently return defaults)")
    func decodeCorruptThrows() throws {
        let (cfg, dir) = try Self.fixture()
        defer { Self.cleanup(dir) }
        try Data("this: is: not: valid: yaml: [[[".utf8).write(to: URL(fileURLWithPath: cfg))

        var threw = false
        do {
            _ = try ConfigRecovery.decode(at: cfg)
        } catch {
            threw = true
        }
        #expect(threw, "corrupt YAML must throw, not decode to defaults")
    }

    @Test("decode: valid YAML failing validation throws (e.g. port out of range)")
    func decodeInvalidConfigThrows() throws {
        var c = Self.exactConfig()
        c.server.port = 999999  // > 65535 → ConfigValidationError
        let (cfg, dir) = try Self.fixture()
        defer { Self.cleanup(dir) }
        try Self.writeConfig(c, to: cfg)

        var threw = false
        do {
            _ = try ConfigRecovery.decode(at: cfg)
        } catch {
            threw = true
        }
        #expect(threw, "port 999999 must fail validation in decode")
    }

    // MARK: - Snapshot

    @Test("snapshotGood: exact file at good-path, mode 0600, decodes to the exact fixture")
    func snapshotExact() throws {
        let (cfg, good) = try Self.fixture()
        defer { Self.cleanup(((cfg as NSString).deletingLastPathComponent)) }

        try ConfigRecovery.snapshotGood(fileAt: cfg, logger: Self.logger)

        #expect(FileManager.default.fileExists(atPath: good))
        let perms =
            try FileManager.default.attributesOfItem(atPath: good)[.posixPermissions] as? NSNumber
        #expect(
            perms?.int16Value == 0o600,
            "good snapshot must be 0600, got \(String(describing: perms))")
        let decoded = try ConfigRecovery.decode(at: good)
        #expect(decoded == Self.exactConfig())
    }

    // MARK: - Restore (the core recovery guarantees)

    @Test(
        "restore: corrupt main + good snapshot → EXACT restored config, corrupt file NOT clobbered")
    func restoreKeepsCorruptFileAndRecoversExact() throws {
        let (cfg, good) = try Self.fixture()
        defer { Self.cleanup(((cfg as NSString).deletingLastPathComponent)) }

        try ConfigRecovery.snapshotGood(fileAt: cfg, logger: Self.logger)
        let corruptBytes = "***"
        try corruptBytes.data(using: .utf8)?.write(to: URL(fileURLWithPath: cfg))

        let restored = ConfigRecovery.restoreLastGood(forCorruptFileAt: cfg, logger: Self.logger)
        #expect(restored != nil, "usable snapshot must restore")
        #expect(restored == Self.exactConfig(), "restored config must be the EXACT snapped fixture")
        #expect(restored?.server.port == 18092)

        // Corrupt user file untouched — user can inspect/diff it.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: cfg))
        guard let corruptData = corruptBytes.data(using: .utf8) else {
            #expect(false, "fixture string must be UTF-8 representable")
            return
        }
        #expect(onDisk == corruptData, "corrupt user file must NOT be overwritten")
    }

    @Test("restore: no snapshot → nil (fresh install path, caller generates defaults)")
    func restoreNoSnapshotNil() throws {
        let (cfg, dir) = try Self.fixture()
        defer { Self.cleanup(dir) }
        try Data("!!!not yaml!!!".utf8).write(to: URL(fileURLWithPath: cfg))

        #expect(ConfigRecovery.restoreLastGood(forCorruptFileAt: cfg, logger: Self.logger) == nil)
    }

    @Test("restore: snapshot itself corrupt → nil (never restores an invalid good copy)")
    func restoreCorruptSnapshotNil() throws {
        let (cfg, good) = try Self.fixture()
        defer { Self.cleanup(((cfg as NSString).deletingLastPathComponent)) }

        try ConfigRecovery.snapshotGood(fileAt: cfg, logger: Self.logger)
        // Corrupt the snapshot itself.
        try Data(":::::".utf8).write(to: URL(fileURLWithPath: good))
        try Data("###".utf8).write(to: URL(fileURLWithPath: cfg))

        #expect(ConfigRecovery.restoreLastGood(forCorruptFileAt: cfg, logger: Self.logger) == nil)
    }

    // MARK: - verifyAndSnapshot (save path)

    @Test("verifyAndSnapshot: verified write refreshes good with the NEW exact value")
    func verifiedWriteRefreshesGood() throws {
        let (cfg, good) = try Self.fixture()
        defer { Self.cleanup(((cfg as NSString).deletingLastPathComponent)) }

        // First good = fixture.
        try ConfigRecovery.snapshotGood(fileAt: cfg, logger: Self.logger)

        // Save a NEW config to the main path, then verify+snapshot.
        var updated = Self.exactConfig()
        updated.server.port = 19199
        try Self.writeConfig(updated, to: cfg)

        let ok = ConfigRecovery.verifyAndSnapshot(newFileAt: cfg, logger: Self.logger)
        #expect(ok == true)
        let redecoded = try ConfigRecovery.decode(at: good)
        #expect(
            redecoded.server.port == 19199,
            "good must reflect the new verified value, got \(String(redecoded.server.port))")
    }

    @Test(
        "verifyAndSnapshot: corrupt write returns false AND does NOT clobber the known-good value")
    func unverifiedWriteKeepsStaleGood() throws {
        let (cfg, good) = try Self.fixture()
        defer { Self.cleanup(((cfg as NSString).deletingLastPathComponent)) }

        try ConfigRecovery.snapshotGood(fileAt: cfg, logger: Self.logger)  // good = fixture (port 18092)

        // Simulate a failed save: main file is now corrupt.
        try Data("broken:".utf8).write(to: URL(fileURLWithPath: cfg))
        let ok = ConfigRecovery.verifyAndSnapshot(newFileAt: cfg, logger: Self.logger)
        #expect(ok == false, "round-trip verification of a corrupt file must fail")

        let goodNow = try ConfigRecovery.decode(at: good)
        #expect(
            goodNow.server.port == 18092,
            "good snapshot must keep the last KNOWN-GOOD value (18092), got \(String(goodNow.server.port))"
        )
        // And it must still be recoverable from the corrupt main file.
        #expect(
            ConfigRecovery.restoreLastGood(forCorruptFileAt: cfg, logger: Self.logger)
                == Self.exactConfig())
    }
}

// MARK: - ConfigSystem failure-order (create path) — integration-level, exact

@Suite("ConfigSystem — corrupt config never clobbers the user file")
struct ConfigSystemCorruptionTests {
    // ConfigSystem's paths are process-global (`~/.ocoreai`), so this suite
    // verifies the GUARANTEE at the ConfigRecovery boundary that `create()` relies
    // on: [corrupt main] + [good snapshot] → `restoreLastGood` returns the exact
    // original and leaves the corrupt file intact; without a snapshot → nil.
    private static let logger = Logger(label: "test.config-system")

    @Test(
        "no-snapshot corrupt main → nil (create() would then saveDefault WITHOUT touching the corrupt file first)"
    )
    func freshInstallCorruptGoesToDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfgsys_\(UUID().uuidString.prefix(8))").path
        let cfg = dir + "/config.yaml"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let corrupt = "nope: [corrupt"
        try corrupt.data(using: .utf8)?.write(to: URL(fileURLWithPath: cfg))
        #expect(ConfigRecovery.restoreLastGood(forCorruptFileAt: cfg, logger: Self.logger) == nil)
    }
}
