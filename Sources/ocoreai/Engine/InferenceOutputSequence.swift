// CoreAI shared sequence & token types — aligned with coreai-models HEAD a5ece33
//
// Scalar types (LogitsScalarType, InferenceOutput) and strategy enums live in
// CoreAIEngine.swift or InferenceStubs.swift. This file only provides the
// InferenceOutputSequence protocol and GenerationToken when the old definitions
// are superseded by the new engine family.

import Foundation
import Synchronization
