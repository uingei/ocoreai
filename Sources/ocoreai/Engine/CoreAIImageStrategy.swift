// Provenance: coreai-models (BSD-3-clause, Apple) — verbatim, absorbed 2026-09-12.
//   swift/Sources/CoreAIShared/Image/ImagePreprocessor.swift @ coreai-models HEAD 5716935
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
