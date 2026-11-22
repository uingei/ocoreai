// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// CoreAI shared sequence & token types — aligned with coreai-models HEAD a5ece33
// Adjudicated: 60e8605 — #509's one hunk here (internal TokenCountStore for DecodeOutcomeReporting)
//   read 11-22: inert for this slice, zero consumers of TokenCountStore/tokensGenerated in Sources.
//   #509's strategy-side hunks land in VanillaDecodingStrategy.swift's unread window (queued).
//
// Scalar types (LogitsScalarType, InferenceOutput) and strategy enums live in
// CoreAIEngine.swift or InferenceStubs.swift. This file only provides the
// InferenceOutputSequence protocol and GenerationToken when the old definitions
// are superseded by the new engine family.

import Foundation
import Synchronization
