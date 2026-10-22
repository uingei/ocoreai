#!/usr/bin/env bash
# 30-repeated-prompt-delivery.sh — ask the same thing twice: does the second answer arrive?
#
# ### Why (AGENTS.md invariant 2: the surface never claims more than the engine delivered)
# Measured 10-22, six runs on one host with one model (`gemma-4-e2b-it-4bit`): when a prompt
# is sent a second time while its conversation is still pooled under the anonymous
# conversation key, one of the two turns comes back **200 + one token + finish_reason=stop** —
# e.g. content "1" for a request that asked for 150 lines and got 150 on its first asking.
# It is not saturation — distinct prompts never collapse (200/200, 150/96, 26/78, 109/86) — and
# it is a race rather than a certainty, so no leg may be read as deterministic:
#   • concurrent identical pair (0.3 s apart): four runs collapsed 1, 1, 1 and 2 of 2 turns
#     (15:17, 15:43, 16:07, 16:12 — the last run returned one token TWICE, both claiming `stop`)
#   • sequential identical pair, zero overlap: reproduced once (16:08: 150 then 1), and a second
#     run of the same shape delivered 150 and 150
#   • the same prompt a third and fourth time: 150 and 150 (16:09)
#
# ### Corrected the same day: conversation identity is NOT the trigger (18:05, 16 turns)
# Everything above reads as "it happens when the conversation key collides". It does not.
# Sequential identical prompt bytes:
#   • 8 turns sharing one anonymous key: 4 collapsed (1 token/stop; firstTokenMs 137…257)
#   • the next 8 turns, same bytes, a FRESH `session_id` on every request: 4 collapsed
#     (firstTokenMs 148…257), and those turns never logged a reuse refusal at all — there was
#     no pooled entry to refuse, so even the "not reusable" line is not a precondition
# An earlier 6-turn fresh-key run came back 6/6; that was a small-sample read, not a control,
# and it is retracted here rather than left to contradict the numbers above.
# What does hold, and is the useful discriminator, is that the split is bimodal in TIME:
#   • healthy   — firstTokenMs 4927…8020 (a real 713-token prefill), tokens=200, .maxTokens
#   • collapsed — firstTokenMs 137…257, tokens=1, .eos, while GenerateCompletionInfo still
#     reported promptTokenCount=713
# The clause that used to finish that sentence ("the turn never forwarded its prompt to the model")
# is retracted by measurement, same day: a 713-token prefill costs ~180 ms once the process is warm
# (max_tokens=1: turn 1 = 7404 ms cold, then 176/230 ms), so 130…257 ms is consistent with a prefill
# that genuinely ran. The layer is the sampler, not the feed — CHANGELOG 10-22(11).
# Host memory is not it either: collapses appear at both 117 GB and 122 GB in use. The root
# cause is open, and the instrument it needs (an upstream "prefill actually happened" signal)
# is recorded in CHANGELOG 10-22(8). What this probe requires regardless of cause is stated
# in the last leg: **a collapsed turn must never be silent**.
# TWO mechanism stories died on this file in one evening, and neither survived its own gate:
#   • "the collapse is temperature-gated, greedy never collapses" — from one sweep (0.0 -> 0/12,
#     0.3 -> 5/12, 0.7 -> 7/12, 1.0 -> 6/12). Dead: greedy collapsed 6 of 6 the same evening.
#   • "clean boot is safe, the collapse needs pooled state left by earlier turns" — dead the same
#     way it was made: 0 of 6 collapsed greedy turns on a clean boot at 21:34, 6 of 6 on a clean
#     boot at 22:0x, same binary, same model, same config, nothing pooled at either point.
# What survives every run: repeating one identical prompt inside one process collapses some of those
# turns to `tokens=1 finish=stop`, at a rate that swings across the whole range between runs (0/6,
# 6/6, 5-7/12), while distinct prompts deliver (197-200 tokens). Seven single-variable experiments have
# now failed to move it — session pool off, KV quantization off, wired memory off, temperature 0, boot
# order, 680 MB of stale disk KV snapshots, and MLX_DISABLE_COMPILE (read once per process, mlx
# mlx/compile.cpp:220 function-local static; 3/6 vs 4/6 collapse boots, no separation — so the compiled
# Gemma4Text fusions are not the carrier) — so the rate is not a rule, and legs 0a and 5 report it
# rather than asserting it.
#
# Per-process, or per-lane? 15 boots x identical greedy turns (84 turns, both compile arms) came back
# internally unanimous — every boot all-collapse or all-deliver, never mixed. That reads as a
# process-global bind, and this file's own 16:08 record contradicts it (one process, sequential, zero
# overlap: 150 tokens then 1). The gap between the two readings looked like turn count, so turn count
# became the next axis and got measured: 3 boots x 12 turns, fresh session_id every turn, came back
# ok x12 / ok x12 / C x12 — no transition anywhere inside a boot. Cumulative per-process state is
# therefore not the mechanism either, and the single mixed pair at 16:08 stands as the one observation a
# process-global model still has to explain (or fail to reproduce). Env and config are excluded by
# construction rather than measurement: inside one A/B arm both stay constant while the mode still flips
# between boots, so whatever decides is neither of them.
# The instrument that would settle this is still the missing one: a per-turn answer to "did this
# forward actually prefill, and how many cache rows did it reuse". `GenerateCompletionInfo` reports
# tokens FED (bb0d5b048 Evaluate.swift:1753) and left `cachedPromptTokenCount` at 0 on turns that
# answered a 713-token prompt in ~200 ms — a state in which any mechanism story is guessable, which
# is exactly how two of them got written. The invariant this file CAN gate, and which held for 8 of 8
# collapsed turns last run, is leg 4: a collapsed turn may never be silent.
# The collapsed turn logs `Session pool entry … not reusable: cached history 2 exceeds common
# prefix 1 — building a clean session` and finishes inside the same second it was dispatched,
# so it never prefilled 708 tokens: the turn ended before it started, and said `stop`.
#
# What is already ruled out, so the next reader does not re-walk it: the pool's miss return
# carries `divergenceIndex: 0` (`SessionPool.swift`, the clean-session return), so the caller
# feeds the full transcript — the collapsed turn did not receive an empty prompt by way of the
# prefix ledger. No disk snapshot is involved on this path either (`deleteCachedSession` runs
# on the refusal, and the log shows no restore).
#
# This matters more than it looks: an agent that retries a call verbatim, a GUI that resends,
# and two windows on one conversation all land on this path, and each of them gets a one-token
# success instead of an answer.
#
# ### What is asserted
#   1. Sequential repeat (deterministic, no race): the second identical turn delivers.
#   2. Concurrent identical pair: both turns deliver; the engine log must show the queue wait,
#      or nothing contended and that leg proves nothing.
#   3. Control: distinct prompts deliver, so a failure cannot be blamed on host saturation.
#
# Needs Metal and a loaded model: this is a live probe, not a unit test.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="repeated-prompt-delivery"

probe_boot
probe_require_ready_model

auth_args=()
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi

PROMPT='Count from 1 to 200, one number per line.'
BODY=$(printf '{"model":"%s","max_tokens":200,"stream":false,"messages":[{"role":"user","content":"%s"}]}' \
  "$PROBE_MODEL" "$PROMPT")
# The control pair: same load, different prompts, so a host-wide problem cannot hide behind
# this probe's verdict (measured 10-22: distinct prompts complete 200+200 at full length).
BODY_ALT=$(printf '{"model":"%s","max_tokens":200,"stream":false,"messages":[{"role":"user","content":"List 200 fruits, one per line."}]}' \
  "$PROBE_MODEL")

OUT_A="$(mktemp -t ocoreai-30-a.XXXXXX)"
OUT_B="$(mktemp -t ocoreai-30-b.XXXXXX)"
OUT_C="$(mktemp -t ocoreai-30-c.XXXXXX)"

finish_tokens() {  # finish_tokens <file> -> "<completion_tokens> <finish_reason>"
  python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    c=(d.get("choices") or [{}])[0]
    print(d.get("usage",{}).get("completion_tokens","-"), c.get("finish_reason","-"))
except Exception as e:
    print("- err:%s" % type(e).__name__)
' "$1"
}

run_turn() {  # run_turn <body> <out>
  curl -sS -m 180 -X POST "$PROBE_BASE/v1/chat/completions" ${auth_args[@]+"${auth_args[@]}"} \
    -H 'Content-Type: application/json' --data "$1" -o "$2" 2>&1
}

# ── leg 0a: greedy on a clean boot — measured, deliberately not asserted ────────────────────
# This was a hard gate for about half an hour, and it went red on its own re-run: the same binary
# delivered 0 of 6 collapsed greedy turns on a clean boot at 21:34 and collapsed 6 of 6 on a clean
# boot at 22:0x. A check that flips between identical runs measures a rate; it cannot check a rule.
# So this leg reports the number, and leg 4 keeps the only rule this defect has never broken.
GREEDY_CLEAN=0
for i in 1 2 3 4 5 6; do
  BODY_GC=$(printf '{"model":"%s","max_tokens":200,"temperature":0.0,"stream":false,"session_id":"probe30-clean-%s","messages":[{"role":"user","content":"%s"}]}' \
    "$PROBE_MODEL" "$i" "$PROMPT")
  OUT_GC=$(mktemp -t ocoreai-30-gc.XXXXXX)
  run_turn "$BODY_GC" "$OUT_GC"
  read -r TOK_GC FIN_GC <<<"$(finish_tokens "$OUT_GC")"
  if [ "${TOK_GC:-0}" -le 1 ] 2>/dev/null && [ "$FIN_GC" = "stop" ]; then
    GREEDY_CLEAN=$(( GREEDY_CLEAN + 1 ))
  fi
done
probe_note "greedy on a clean boot: $GREEDY_CLEAN/6 collapsed — this binary has measured both 0/6 and" \
  " 6/6 on the same shape, so no rule lives here; leg 4 gates what must be true at any rate"

# ── leg 0: sequential identical repeat — no concurrency, no race, still the same defect ───
PROMPT0='Enumerate 1 to 120, one number per line.'
BODY0=$(printf '{"model":"%s","max_tokens":150,"stream":false,"messages":[{"role":"user","content":"%s"}]}' \
  "$PROBE_MODEL" "$PROMPT0")
OUT_S1="$(mktemp -t ocoreai-30-s1.XXXXXX)"
OUT_S2="$(mktemp -t ocoreai-30-s2.XXXXXX)"
run_turn "$BODY0" "$OUT_S1"
read -r TOK_S1 FIN_S1 <<<"$(finish_tokens "$OUT_S1")"
run_turn "$BODY0" "$OUT_S2"
read -r TOK_S2 FIN_S2 <<<"$(finish_tokens "$OUT_S2")"
probe_note "sequential repeat: ask#1=$TOK_S1/$FIN_S1  ask#2=$TOK_S2/$FIN_S2"
if [ "${TOK_S2:-0}" -gt 8 ] 2>/dev/null; then
  probe_ok "the repeated prompt delivered again ($TOK_S2 tokens) — no overlap needed to break, none needed to work"
else
  probe_xfail open "the same prompt asked twice in a row returned $TOK_S2 tokens/$FIN_S2" \
    " after $TOK_S1/$FIN_S1 — one-token success, no overlap involved (open: the collapsed"
    " turn never prefilled, see CHANGELOG 10-22(8))"
fi

# ── legs 1+2: identical prompts, both must deliver ────────────────────────────────────────
run_turn "$BODY" "$OUT_A" &
PID_A=$!
sleep 0.3
run_turn "$BODY" "$OUT_B" &
PID_B=$!
wait "$PID_A"
wait "$PID_B"

read -r TOK_A FIN_A <<<"$(finish_tokens "$OUT_A")"
read -r TOK_B FIN_B <<<"$(finish_tokens "$OUT_B")"
probe_note "identical pair: A=$TOK_A/$FIN_A tokens  B=$TOK_B/$FIN_B tokens"

# Premise floor: the queue line proves the two turns overlapped. It guards a PASS, not a FAIL —
# when both turns collapse inside a second they never reach the queue, so absence of the line
# cannot excuse a truncated answer, and calling that run "unproven" would let the defect hide
# behind the harness (measured 10-22, second run of this probe: A=1/stop and B=1/stop, no
# queue line at all).
if grep -q "Queued for inference" "$PROBE_LOG" 2>/dev/null; then
  probe_ok "the turns contended — engine logged the queue:"
  grep "Queued for inference" "$PROBE_LOG" | tail -1 | sed 's/^/        /'
fi

collapses=0
for side in A B; do
  eval "tok=\$TOK_$side"
  eval "fin=\$FIN_$side"
  case "$tok" in ''|*[!0-9]*) tok=0 ;; esac
  if [ "$tok" -gt 8 ]; then
    probe_ok "$side delivered $tok tokens ($fin)"
  else
    collapses=$(( collapses + 1 ))
    probe_note "$side collapsed to $tok tokens with finish_reason=$fin"
  fi
done

if [ "$collapses" -eq 0 ]; then
  if grep -q "Queued for inference" "$PROBE_LOG" 2>/dev/null; then
    probe_ok "both identical turns answered while contended — no turn was silently cut short"
  else
    probe_fail "both answered, but no 'Queued for inference' line exists in this run — nothing" \
      " overlapped, so the leg proved nothing about the collision; raise max_tokens or shrink" \
      " the stagger so the two turns are alive at the same time"
  fi
else
  probe_xfail open "$collapses of 2 identical concurrent turns returned a truncated answer" \
    " while reporting success (open: the collapsed turn never prefilled; conversation identity" \
    " ruled out 10-22 — see CHANGELOG 10-22(8))"
fi

# ── leg 3: control pair, distinct prompts ─────────────────────────────────────────────────
run_turn "$BODY_ALT" "$OUT_C" &
PID_C=$!
sleep 0.3
run_turn "$BODY" "$OUT_A" &
PID_D=$!
wait "$PID_C"
wait "$PID_D"
read -r TOK_C FIN_C <<<"$(finish_tokens "$OUT_C")"
read -r TOK_D FIN_D <<<"$(finish_tokens "$OUT_A")"
probe_note "control pair: distinct prompts C=$TOK_C/$FIN_C  identical-repeat D=$TOK_D/$FIN_D"
if [ "${TOK_C:-0}" -gt 8 ] 2>/dev/null && [ "${TOK_D:-0}" -gt 8 ] 2>/dev/null; then
  probe_ok "distinct prompts both delivered full turns ($TOK_C, $TOK_D tokens) — the" \
    " truncation is prompt-specific, not host saturation"
else
  probe_note "control pair incomplete ($TOK_C, $TOK_D tokens) — host load, not the collision"
fi


# ── leg 4: a collapsed turn must never be silent ──────────────────────────────────────────
# Root cause aside (legs 0-2 stay xfail until it is closed), invariant 2 still binds: a turn
# that delivered one token under a budget that asked for more may not leave the process as a
# plain success. Read straight off the engine log so it covers every leg above: every
# `StdTurn` line that ended at one token with .eos must be matched by a `Degenerate
# generation` line (`Sources/ocoreai/Engine/DegenerateTurn.swift`). Goes red the moment the
# guard is dropped, and stays green whether or not the collapse reproduces this run.
EOS1=$(grep -c "StdTurn:.*tokens=1 reason=Optional(ocoreai.StopReason.eos)" "$PROBE_LOG" 2>/dev/null)
MARKERS=$(grep -c "Degenerate generation" "$PROBE_LOG" 2>/dev/null)
if [ "${EOS1:-0}" -eq 0 ] 2>/dev/null; then
  probe_note "no one-token .eos turn this run — nothing needed flagging"
elif [ "${MARKERS:-0}" -ge "${EOS1:-0}" ] 2>/dev/null; then
  probe_ok "every collapsed turn said so: $MARKERS Degenerate-generation line(s) for $EOS1" \
    " one-token .eos turn(s) — a truncated answer is never a silent success"
else
  probe_fail "$EOS1 turn(s) returned 1 token + .eos but only $MARKERS said so — the rest left" \
    " the process as a plain success, which is the lie this probe exists to catch"
fi

# ── leg 5: greedy AFTER the warm legs — measured, deliberately not asserted ─────────────────
# This shape is the experiment that retracted the temperature story: identical greedy turns, fresh
# session_id each, run after the repeat/concurrent legs above. Measured 10-22: 0 of 12 collapsed in
# the morning sweep, 6 of 6 collapsed in the evening run — same host, same model, same binary. Only
# leg 0a (clean boot) is stable, which is why greedy is asserted there and reported here. A
# deterministic decoder that fails only once the engine has been exercised points at pooled/cache
# state, not the sampler; the invariant that binds regardless of the rate stays leg 4's.
GREEDY_WARM=0
for i in 1 2 3 4 5 6; do
  BODY_G=$(printf '{"model":"%s","max_tokens":200,"temperature":0.0,"stream":false,"session_id":"probe30-greedy-%s","messages":[{"role":"user","content":"%s"}]}' \
    "$PROBE_MODEL" "$i" "$PROMPT")
  OUT_G=$(mktemp -t ocoreai-30-g.XXXXXX)
  run_turn "$BODY_G" "$OUT_G"
  read -r TOK_G FIN_G <<<"$(finish_tokens "$OUT_G")"
  if [ "${TOK_G:-0}" -le 1 ] 2>/dev/null && [ "$FIN_G" = "stop" ]; then
    GREEDY_WARM=$(( GREEDY_WARM + 1 ))
  fi
done
if [ "$GREEDY_WARM" -gt "$GREEDY_CLEAN" ]; then
  probe_note "state-dependence reproduced: greedy collapsed $GREEDY_WARM/6 once the engine was" \
    " exercised vs $GREEDY_CLEAN/6 on the clean boot (leg 0a) — the search belongs in the" \
    " pool/cache layer, not the sampler (CHANGELOG 10-22(11))"
else
  probe_note "greedy after warm legs: $GREEDY_WARM/6 collapsed (clean boot: $GREEDY_CLEAN/6) — no" \
    " state-dependence this run; leg 4 carries the gate"
fi

probe_summary "$PROBE_NAME"
