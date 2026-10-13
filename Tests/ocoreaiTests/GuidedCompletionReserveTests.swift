// GuidedCompletionReserveTests.swift — Regression gate for the guided-generation
// completion zones. Upstream's ×3/×8 recipe lets `hardReserve` reach or exceed a
// small `max_tokens`, which puts every sampled step in the force-closing zone and
// corrupts structured output (live 10-13, gemma-4-e2b-it-4bit, json_schema
// {"answer": integer}: max_tokens 24/32 → `{"answer"\n  \n:1111…` never closing;
// 48/64/128 → valid `{ "answer": 7 }`).

import Testing

@testable import ocoreai

@Suite("guidedCompletionReserves — zones stay inside the budget")
struct GuidedCompletionReserveTests {

    /// The recipe, pinned per budget for a schema whose minimal instance is 7 tokens.
    @Test(
        "exact reserves across budgets",
        arguments: [
            (maxTokens: 24, completion: 21, hard: 7),
            (maxTokens: 32, completion: 21, hard: 7),
            (maxTokens: 48, completion: 21, hard: 7),
            (maxTokens: 128, completion: 32, hard: 7),
            (maxTokens: 4096, completion: 1024, hard: 7),
        ])
    func exactReserves(maxTokens: Int, completion: Int, hard: Int) {
        let r = guidedCompletionReserves(maxTokens: maxTokens, structuralReserve: 7)
        #expect(r.completion == completion)
        #expect(r.hard == hard)
    }

    /// The invariant the corruption violated: the hard zone must be a tail of the
    /// run, never the whole run, whenever the budget exceeds the structure.
    @Test("hard zone is a tail, not the whole budget", arguments: 1 ..< 200)
    func hardZoneIsTail(maxTokens: Int) {
        let structural = 7
        let r = guidedCompletionReserves(maxTokens: maxTokens, structuralReserve: structural)
        #expect(r.hard <= r.completion, "hard zone must not swallow the soft zone")
        #expect(r.completion <= maxTokens, "soft reserve may not exceed the budget")
        if structural < maxTokens {
            #expect(
                r.hard < maxTokens,
                "max_tokens=\(maxTokens): hard zone covers the whole run → force-close from step 0")
        }
    }

    /// Degenerate inputs stay sane (no negative zones).
    @Test("zero and negative inputs clamp to zero", arguments: [0, -1, -512])
    func degenerate(maxTokens: Int) {
        let r = guidedCompletionReserves(maxTokens: maxTokens, structuralReserve: 7)
        #expect(r.completion == 0)
        #expect(r.hard == 0)
    }

    /// A schema that needs the whole budget still gets a hard zone equal to the
    /// budget — there is no other sane reading when nothing else fits.
    @Test("budget below the minimal structure forces closing")
    func budgetSmallerThanStructure() {
        let r = guidedCompletionReserves(maxTokens: 5, structuralReserve: 7)
        #expect(r.completion == 5)
        #expect(r.hard == 5)
    }
}
