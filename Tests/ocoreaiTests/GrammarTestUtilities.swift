// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — consumed from coreai-models TestUtilities.swift:68-79 at 6a6bb0e (#374). The
// helper body is upstream's. It is a free function here rather than a member because this tree consumes
// the test file without upstream's helper file.

#if canImport(CoreAI)

import Foundation

@testable import ocoreai

/// The ids a session's next mask allows. A nil mask — the session's own "nothing left to generate" —
/// decodes to the empty set, which is why the case in `GrammarStopTokenPlumbingTests` asserts nil
/// directly: through this helper an emptied mask and a blocked token look the same.
@available(macOS 27.0, *)
func allowedTokenIDs(session: inout ConstrainedGenerationSession) -> Set<Int32> {
    guard let bitmask = session.nextTokenBitmask() else { return Set() }
    var allowed = Set<Int32>()
    for tokenId in 0 ..< session.vocabularySize {
        let (wordIndex, bitIndex) = tokenId.quotientAndRemainder(dividingBy: 32)
        if wordIndex < bitmask.count && (bitmask[wordIndex] & (1 << bitIndex)) != 0 {
            allowed.insert(Int32(tokenId))
        }
    }
    return allowed
}

#endif
