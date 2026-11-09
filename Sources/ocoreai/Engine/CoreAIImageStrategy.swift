// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
// Provenance: coreai-models (BSD-3-clause, Apple) — verbatim, absorbed.
//   swift/Sources/CoreAIShared/Image/ImagePreprocessor.swift @ coreai-models HEAD 5716935
//   Adjudicated: 7fd2063 — the one commit since (#370) is an access-level change outside this
//   19-line strategy: docs/agent/coreai-fork-adjudication.md
//   Adjudicated: 1c7c71f (#416's single hunk in the source file is the `loadCGImage` helper —
//   outside this 19-line strategy; row: coreai-fork-window-log.md § Window read 11-09)
// Pure Foundation/CoreImage/vDSP value types — no CoreAI dependency, always
// compiled (usable in tests on any Apple OS ≥ the module floor).

import CoreGraphics
import CoreImage
import Foundation

/// Image resize/fit strategy for vision preprocessing.
enum ImageStrategy: String, Codable, Sendable {
    case stretch
    case centerCrop = "center_crop"
    case pad
}
