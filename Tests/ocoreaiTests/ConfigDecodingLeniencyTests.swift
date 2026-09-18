// Copyright © 2026 uingei@163.com.
/// Exact-value guards for lenient config decoding: partial hand-authored
/// `config.yaml` (12-factor) decodes with owner keys honored and un-written
/// keys defaulted; no-recognized-key documents are rejected by the single
/// funnel (`decodeVerifiedConfig`); full config round-trips exactly.

import Foundation
import Testing
import Yams

@testable import ocoreai

@Suite("Config decoding — partial hand-authored yaml (12-factor)")
struct ConfigDecodingLeniencyTests {
    private static func decode(_ yaml: String) throws -> AppConfig {
        try YAMLDecoder().decode(AppConfig.self, from: Data(yaml.utf8))
    }

    @Test("minimal yaml (agent-only) decodes; owner value honored; rest default")
    func minimalAgentOnlyYamlDecodes() throws {
        let c = try Self.decode(
            """
            agent:
              approvalPolicy: auto
            """)
        #expect(c.agent.approvalPolicy == "auto", "owner's value must be honored")
        #expect(c.server.port == 8080, "un-written keys resolve to documented defaults")
        #expect(c.backend.preference == ["coreai", "mlx"])
        #expect(c.models["default"] != nil, "default model entry present")
    }

    @Test("partial server block: owner's port honored, rest default")
    func partialServerBlockHonored() throws {
        let c = try Self.decode(
            """
            server:
              port: 9100
            """)
        #expect(c.server.port == 9100)
        #expect(c.server.host == "127.0.0.1")
    }

    @Test("model entry missing modelId degrades models block, not the whole file")
    func modelEntryMissingModelIdDegradesModelsOnly() throws {
        let c = try Self.decode(
            """
            agent:
              approvalPolicy: never
            models:
              default:
                enabled: false
            """)
        #expect(c.agent.approvalPolicy == "never", "the owner's agent line survives")
        #expect(
            c.models["default"]?.modelId == ModelConfigEntry.defaultEntry.modelId,
            "entry without its identity falls back to the documented default entry")
    }

    @Test("full-config sentinel round-trips EXACTLY (no field silently dropped)")
    func fullConfigSentinelRoundTrips() throws {
        var cfg = AppConfig()
        cfg.server.host = "127.0.0.7"
        cfg.server.port = 7077
        cfg.server.corsOrigin = "http://loopback.test"
        cfg.server.bindInterface = "lan"
        cfg.server.workers = 3
        cfg.backend.preference = ["mlx"]
        cfg.backend.maxConcurrentSessions = 2
        cfg.backend.kvCacheGB = 9.5
        cfg.backend.kvCacheQuantization.enabled = false
        cfg.backend.kvCacheQuantization.bits = 8
        cfg.backend.kvCacheQuantization.kvScheme = "affine8"
        cfg.backend.wiredMemory.policy = "fixed"
        cfg.backend.wiredMemory.fixedLimit = 12_345_678
        cfg.backend.specDecoding.enabled = true
        cfg.backend.specDecoding.draftModelId = "org/draft-1b"
        cfg.memory.sessionTTL = 4321
        cfg.metrics.retentionDays = 7
        cfg.safety.enabled = true
        cfg.safety.categoryModes = ["weapons": "strict"]
        cfg.safety.minMatchesRequired = 4
        if var m = cfg.models["default"] {
            m.modelId = "org/sentinel-2bit"
            m.version = "v9"
            m.maxSessionTokens = 1000
            m.sampling.temperature = 0.7
            m.sampling.stopSequences = ["<END>", "FIN"]
            m.sampling.prefill.chunking = .remainder
            cfg.models["default"] = m
        }
        cfg.agent.approvalPolicy = "never"

        let yaml = try YAMLEncoder().encode(cfg)
        let back = try Self.decode(yaml)
        #expect(back == cfg, "full-config sentinel must round-trip to the identical value")
    }

    @Test("validation stays a separate step after lenient decode")
    func validationStillEnforcedAfterLenientDecode() throws {
        let c = try Self.decode(
            """
            server:
              port: 999999
            """)
        #expect(c.server.port == 999999, "decode is permissive about RANGE")
        var threw = false
        do {
            try c.validate()
        } catch {
            threw = true
        }
        #expect(threw, "port 999999 must throw in validate() — leniency never relaxes validation")
    }

    @Test(
        "document with NO recognized key is rejected by the single funnel (never default-adopted)")
    func noKeyDocumentIsRejectedByFunnel() {
        for garbage in ["broken:", "42", "", "# only a comment\n"] {
            var threw = false
            do {
                _ = try decodeVerifiedConfig(from: Data(garbage.utf8))
            } catch {
                threw = true
            }
            #expect(
                threw,
                "no-recognized-key document must be rejected, got decoded: \(garbage.debugDescription)"
            )
        }
    }
}
