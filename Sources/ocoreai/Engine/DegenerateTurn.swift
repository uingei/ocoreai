/// A turn that ends after producing at most one token, under a budget that asked
/// for more, is not an answer — and it must not leave the process as a plain
/// `200 + finish_reason: stop`.
///
/// ### Why (AGENTS.md invariant 2: the surface never claims more than the engine delivered)
/// Measured 10-22 on one host, one model (`gemma-4-e2b-it-4bit`), identical prompt bytes
/// sent sequentially at `max_tokens=200` (16 turns, `scripts/probes/30-repeated-prompt-delivery.sh`
/// reproduces the shape): turns split bimodally.
///   • healthy — `firstTokenMs` 4927…8020 (a real 713-token prefill), `tokens=200`,
///     `reason=maxTokens`
///   • degenerate — `firstTokenMs` 137…257, `tokens=1`, `reason=eos`,
///     yet `GenerateCompletionInfo.promptTokenCount` still reported 713
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
/// conservative about what it claims: it flags the shape, and the log line carries the two
/// numbers that let a reader make the prefill call (`firstTokenMs` against `promptTokens`)
/// rather than the engine asserting a verdict it has no measurement for. A per-model
/// "prefill actually happened" signal from upstream is the missing instrument, and
/// asking for it is recorded as an open item in `CHANGELOG.md`.
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
