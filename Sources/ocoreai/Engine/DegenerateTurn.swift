// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// A turn that ends after producing at most one token, under a budget that asked
/// for more, is not an answer — and it must not leave the process as a plain
/// `200 + finish_reason: stop`.
///
/// ### Why (AGENTS.md invariant 2: the surface never claims more than the engine delivered)
/// Measured 10-22 on one host, one model (`gemma-4-e2b-it-4bit`), identical prompt bytes
/// sent sequentially at `max_tokens=200` (16 turns, `scripts/probes/30-repeated-prompt-delivery.sh`
/// reproduces the shape): turns split bimodally.
///   • healthy — `tokens=200`, `reason=maxTokens`, whole-turn 4.7–7.5 s
///   • degenerate — `tokens=1`, `reason=eos`, whole-turn 0.12–0.22 s,
///     yet `GenerateCompletionInfo.promptTokenCount` still reported 713
/// Read those seconds as whole-turn latency, not as time-to-first-token: `firstTokenMs` is
/// stamped at the first output chunk and the standard non-stream path emits that chunk when the
/// generation completes (`EngineInference.swift:4635`; a 200-token turn reported
/// `firstTokenMs=4671.26` with `overallMs=4672.66`). Two points at one 713-token prompt — 1 token
/// at ≈147 ms and 200 tokens at ≈4672 ms — put fixed cost at ≈124 ms and decode at ≈44 tok/s, so
/// the 30x spread is 200 tokens against 1 and says nothing about prefill (corrected 10-23; the
/// clause that used to label those numbers "(a real 713-token prefill)" was an unmeasured reading
/// of a field that cannot support it).
/// 8 of those 16 turns collapsed: 4 of 8 sharing one anonymous conversation key and
/// 4 of 8 under fresh `session_id`s, so conversation identity is not the trigger.
/// The inference that used to sit here — "the collapsed turn never forwarded its prompt
/// to the model" — is retracted, by measurement and same day: a 713-token prefill costs
/// ~180 ms once the process is warm (`max_tokens=1`: turn 1 = 7404 ms cold, then
/// 176/230 ms), so 130…257 ms is consistent with a prefill that genuinely ran. What is
/// measured instead: 15 boots × identical greedy turns (84 turns) came back unanimous
/// inside every boot, and seven single-variable experiments moved nothing — session pool
/// off, KV quantization off, wired memory off, temperature 0, boot order, 680 MB of stale
/// disk KV snapshots, and `MLX_DISABLE_COMPILE` (`scripts/probes/30-repeated-prompt-delivery.sh`
/// carries the numbers and the two mechanism stories that died there).
/// Whatever the eventual root cause, the
/// silence is a defect of its own: an agent that retries a call verbatim, a GUI that
/// resends, and two windows on one conversation all read `stop` as "answered".
///
/// ### What this predicate is, and is not
/// It is a *detector*, not a fix. It cannot distinguish a real model that chose to answer
/// EOS early from a legitimate one-token answer (`OK`, `42`), so it is deliberately
/// conservative about what it claims: it flags the shape and hands over the numbers it actually
/// has (`tokens`, `reason`, the requested budget, `promptTokens`), rather than the engine
/// asserting a verdict it has no measurement for. `firstTokenMs` travels with the line but is not
/// one of those numbers — see the latency note above. What the detector cannot see is *why* the
/// model stopped, and that is measured one level down, per step, by `DegenerateMarginProbe`.
/// A per-model "prefill actually happened" signal from upstream is still the missing instrument,
/// and asking for it is recorded as an open item in `CHANGELOG.md`.
enum DegenerateTurn {

    /// The largest generated-token count that still counts as "essentially nothing".
    ///
    /// `max_tokens > 1` keeps a request that asked for one token out of the verdict:
    /// a caller that set `max_tokens: 1` and got one token received exactly what it
    /// asked for, and `finish_reason: length` already says so.
    static let tokenCeiling = 1

    /// True when this turn's shape is a suspected degenerate generation.
    ///
    /// - Parameters:
    ///   - tokenCount: tokens the engine generated for this turn (not including any
    ///     prompt accounting).
    ///   - stopReason: the reason the generation loop ended. Only `.eos` qualifies:
    ///     `.maxTokens` means the turn ran to the budget, `.stopSequence` means the
    ///     caller's own stop string terminated it, `.cancelled` and `.error` are
    ///     already loud.
    ///   - requestedMaxTokens: the output budget this turn was given, as sent on the
    ///     wire. `nil` (unset) uses the engine default, which is more than one token,
    ///     so it counts as "asked for more".
    static func isSuspected(
        tokenCount: Int,
        stopReason: StopReason?,
        requestedMaxTokens: Int?
    ) -> Bool {
        guard stopReason == .eos else { return false }
        guard tokenCount <= tokenCeiling else { return false }
        // An unset budget means the engine default, which is > 1 token.
        return (requestedMaxTokens ?? Int.max) > tokenCeiling
    }
}
