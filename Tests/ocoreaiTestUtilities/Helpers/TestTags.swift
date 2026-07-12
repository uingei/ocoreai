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
public enum testTags {
    // MARK: - Scope

    public struct scope {
        /// Pure unit test — no I/O, no actors, no GPU.
        public struct unit {}

        /// Integration test — multiple components, actors, or shared state.
        public struct integration {}
    }

    // MARK: - Requirements

    public struct requires {
        /// Test requires GPU access (MLX inference, Metal).
        public struct gpu {}

        /// Test requires network access (HTTP, ModelScope, Hub).
        public struct network {}

        /// Test reads/writes disk (model cache, config file).
        public struct disk {}
    }

    // MARK: - Duration

    public struct duration {
        /// Test typically takes > 1s (benchmark, large fixture).
        public struct slow {}

        /// Test typically takes < 10ms (pure computation).
        public struct fast {}
    }

    // MARK: - Domain

    public struct domain {
        /// Tests related to the inference pipeline.
        public struct inference {}

        /// Tests related to model management (download, load, unload).
        public struct modelManagement {}

        /// Tests related to the HTTP server layer.
        public struct http {}

        /// Tests related to UI/ViewModel state machines.
        public struct ui {}

        /// Tests related to the MCP bridge.
        public struct mcp {}

        /// Tests related to security (ContentGuard, auth, audit).
        public struct security {}

        /// Tests related to reasoning/adaptation (ThinkingBudget, ComplexityAnalyzer).
        public struct reasoning {}

        /// Tests related to the multimodal pipeline.
        public struct multimodal {}
    }
}
