// Copyright © 2026 uingei@163.com.
/// TestTags.swift — Shared test classification tags for filtering.
///
/// Usage:
///   @Suite("My suite", .testTags.scope.unit) struct MyTests { ... }
///   @Test("my test", .testTags.duration.fast) { ... }
///
/// CI configuration:
///   Unit tests run on every push:  swift test --filter .scope/.unit
///   Integration/slow tests run nightly or on merge to main.
///   GPU/network tests require developer discretion.
///
/// Reference: Swift Testing docs — custom tags via nested struct members.

import Testing

/// Test classification tags for ocoreai test suite.
///
/// Nested structs become accessible as `.testTags.scope.unit` in attribute syntax.
/// This mirrors the `pytest.mark` / `@pytest.fixture` pattern from omlx's conftest.py
/// and coreai-models' TestUtilities tag conventions.
enum testTags {
    // MARK: - Scope

    struct scope {
        /// Pure unit test — no I/O, no actors, no GPU.
        struct unit {}

        /// Integration test — multiple components, actors, or shared state.
        struct integration {}
    }

    // MARK: - Requirements

    struct requires {
        /// Test requires GPU access (MLX inference, Metal).
        struct gpu {}

        /// Test requires network access (HTTP, ModelScope, Hub).
        struct network {}

        /// Test reads/writes disk (model cache, config file).
        struct disk {}
    }

    // MARK: - Duration

    struct duration {
        /// Test typically takes > 1s (benchmark, large fixture).
        struct slow {}

        /// Test typically takes < 10ms (pure computation).
        struct fast {}
    }

    // MARK: - Domain

    struct domain {
        /// Tests related to the inference pipeline.
        struct inference {}

        /// Tests related to model management (download, load, unload).
        struct modelManagement {}

        /// Tests related to the HTTP server layer.
        struct http {}

        /// Tests related to UI/ViewModel state machines.
        struct ui {}

        /// Tests related to the MCP bridge.
        struct mcp {}

        /// Tests related to security (ContentGuard, auth, audit).
        struct security {}

        /// Tests related to reasoning/adaptation (ThinkingBudget, ComplexityAnalyzer).
        struct reasoning {}

        /// Tests related to the multimodal pipeline.
        struct multimodal {}
    }
}
