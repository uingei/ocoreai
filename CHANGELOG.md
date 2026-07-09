# Changelog

All notable changes to **ocoreai**. This project adheres to [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased] — 2026-07-09

### Features

- **Typed tool factory** — `Codable` argument decoding, following the `Tool<Args, Output>` pattern
- **Task-aware prompt engineering** — P0 optimization for prompt quality
- **Gap analysis P0/P1/P2 fixes** — xet disable, cancel cleanup, config TTL cache, parameter estimation, adapter block, mtime stall detection
- **HardwareRouter** — Adaptive GPU/ANE/CPU routing with agent loop token budget 2× compensation and broken-chain repair
- **WiredMemory GPU isolation** — Real-time GPU telemetry and memory isolation
- **WiredMemory** — Policy ID stability and cancel-safe ticket lifecycle
- **Vision multimodal** — OCR + VLM dataURL→CIImage inference path
- **Voice-to-voice loop** — 16 kHz STT + i18n TTS voice + camera integration

### Bug Fixes

- **Request pipeline** — Scoping guard chain to tool path only; non-tool requests no longer blocked
- **Compute channel** — Wired computeChannel to session pool + speculative decoding
- **HardwareRouter data flow** — Wired HardwareRouter → inference pipeline (P0 disconnect fix); wired submitAndDispatch to activate admission gate + hardware router
- **Download pipeline resilience** — Retry logic, stall detection, endpoint config, HF progress, cache integrity; ModelScope temp-file-before-handle and 'blob' type acceptance
- **Scheduler** — Fixed state leak in ChatHandler + AnthropicMessagesHandler
- **EnginePool** — Eliminated force unwrap; tightened CI crash-risk gate; removed leftover `source:` param from `mlxModelLoader.load()`
- **Error mapping** — Wired SchedulerError → AppError in handlers
- **Security** — Closed 2 P0 vulnerabilities from code review
- **Build fixes** — Resolved build break, release warning, and release-mode crash
- **Miscellaneous** — Removed dead HF_ENDPOINT check and dead firstError variable in MCP routeParallel

### Refactoring

- **Engine load API** — Removed `source` parameter; `defaultHub` property is sufficient; eliminated prefix-based routing

### Documentation

- Synced README with recent changes (HardwareRouter, AdmissionGate, ThinkingBudget, VLM/OCR, Profiling, 6-language i18n)
- Added tuning-knob documentation for admission gate abort margin fraction
- Fixed misleading comment about per-request device switching

### Chores

- Added complete code review infrastructure (governance)
- Ran SwiftLint: errors → 0, hardened config thresholds, fixed style violations
- Resolved deprecations and renamed symbols

---

*Generated from git history: v0.1.0..6a601f4 (35 commits, 2026-07-05 → 2026-07-09).*
