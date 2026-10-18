#!/usr/bin/env bash
# 10-sampling-knob-delivery.sh — does the engine actually do what the sampling knobs say?
#
# ### Why (AGENTS.md invariant 2: the surface never claims more than the engine delivered)
# Every knob below is accepted by the wire. Accepting is the cheap half: a field can be
# decoded, cascaded, logged — and still die on the last hop into the engine, where the
# client gets a full generation whose behaviour came from something else, with no signal.
#
# Measured 10-18, before the fix: `stop:["2"]` returned the full `1 2 3 … 20` with
# `finish_reason:"stop"`, while the engine's own log said `stopmatch=2 len=3`. Two causes
# at the shared seam: `break` inside a `switch` left the switch and not the generation loop,
# and the match test was `hasSuffix`, which misses a stop arriving mid-chunk and dropped a
# whole chunk when the stop landed at offset 0 (`stop:["banana"]` lost one banana against
# its own control). Fixed in EngineInference (`firstStopOccurrence` + labeled loop breaks),
# and OpenAI's finish_reason word for stop-string termination is `"stop"`.
#
# ### What is measured (assertions only where the measurement can settle the question)
#   1. STOP           — a single-token stop must cut the reply and end generation, a stop
#                       that never occurs must cut nothing, and streaming must agree with
#                       non-streaming. Decisive: token counts, not vibes.
#   2. SEED           — the same seed at temperature 1.0 twice must give identical text;
#                       that is the reproducibility claim the engine publishes (#265/#377).
#   3. MAX_TOKENS     — usage.completion_tokens must not exceed the requested cap.
#   4. PENALTIES      — recorded, NOT asserted. A ±2.0 penalty on a repetition task can
#                       legitimately leave greedy output untouched: the penalty is uniform
#                       across the tokens in the context window, so their relative order —
#                       and therefore the argmax — does not change. Identical text here is
#                       a fact about this prompt, not proof of an inert knob (the sign
#                       itself is pinned where it can be pinned: PenaltySignDeliveryTests,
#                       against the upstream condition at the pin).
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 10`). Bodies are
# built with single-quoted JSON — macOS bash 3.2 mis-parses nested quoted command
# substitution (see probe 09), and each compared turn gets its OWN session so a growing
# history cannot change the answer on its own.
#
# Run: bash scripts/probes/10-sampling-knob-delivery.sh
PROBE_NAME="10-sampling-knob-delivery"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SESSION_SEQ=0
# A fresh session per turn. Sharing one session across the compared turns would let the
# growing history change the answer on its own, so a *dropped* knob could still produce
# three different bodies and the check would pass without measuring anything.
fresh_session() {
  SESSION_SEQ=$(( SESSION_SEQ + 1 ))
  printf 'probe10-%s-%s' "$$" "$SESSION_SEQ"
}

REPEAT_PROMPT="Repeat this sentence three times, one per line, with no other text: the quick brown fox jumps over the lazy dog"
BANANA_PROMPT="Say the word banana five times, separated by single spaces, nothing else."
COUNT_PROMPT="Count from 1 to 20 separated by single spaces, and stop after 20."

ANSWER=""
ANSWER_STATUS=""
ANSWER_FINISH=""
ANSWER_TOKENS=""

# ask EXTRA_JSON PROMPT MAX_TOKENS [TEMPERATURE] — one non-streaming turn.
ask() {
  local body session temp="${4:-0}"
  session="$(fresh_session)"
  body='{"model":"'"$PROBE_MODEL"'","session_id":"'"$session"'","temperature":'"$temp"',"max_tokens":'"$3"',"messages":[{"role":"user","content":"'"$2"'"}]'"$1"'}'
  probe_chat "$session" "$body" || true
  ANSWER="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  ANSWER_STATUS="$PROBE_STATUS"
  ANSWER_FINISH="$(probe_json "$PROBE_BODY" 'choices.0.finish_reason')"
  ANSWER_TOKENS="$(probe_json "$PROBE_BODY" 'usage.completion_tokens')"
}

probe_boot
probe_require_ready_model

# ── 1. stop sequences must cut the reply AND end generation ─────────────────
probe_section "1 — stop:[...] truncates, and the word for it is \"stop\""

ask '' "$COUNT_PROMPT" 64
COUNT_BASE="$ANSWER"; COUNT_BASE_TOK="$ANSWER_TOKENS"; COUNT_BASE_FINISH="$ANSWER_FINISH"
if [ "$ANSWER_STATUS" != "200" ]; then
  probe_fail "baseline counting turn -> $ANSWER_STATUS: $(printf %.200s "$PROBE_BODY")"
elif [ -z "$COUNT_BASE" ]; then
  probe_fail "baseline counting turn returned no content — every stop check below would be vacuous"
else
  probe_ok "baseline (no stop) answered 200, $(printf %.60s "$COUNT_BASE" | tr '\n' '~') tokens=$COUNT_BASE_TOK finish=$COUNT_BASE_FINISH"
fi

ask ',"stop":["2"]' "$COUNT_PROMPT" 64
STOP2="$ANSWER"; STOP2_TOK="$ANSWER_TOKENS"; STOP2_FINISH="$ANSWER_FINISH"
if [ -z "$STOP2" ]; then
  probe_fail "stop:[\"2\"] returned no content at all — expected the text before the stop (\"1\")"
else
  case "$STOP2" in
    *2*) probe_fail "stop:[\"2\"] was ignored — reply still contains 2: $(printf %.80s "$STOP2")" ;;
    *)   probe_ok "stop:[\"2\"] cut the reply to $(printf %.20s "$STOP2")" ;;
  esac
fi
if [ -n "$STOP2_TOK" ] && [ -n "$COUNT_BASE_TOK" ] && [ "$COUNT_BASE_TOK" -gt 0 ]; then
  if [ "$STOP2_TOK" -lt "$COUNT_BASE_TOK" ]; then
    probe_ok "generation actually ended early: completion_tokens $STOP2_TOK vs $COUNT_BASE_TOK uncut"
  else
    probe_fail "stop matched but generation did not end: completion_tokens $STOP2_TOK == uncut $COUNT_BASE_TOK"
  fi
else
  probe_fail "completion_tokens missing on the stop runs ($STOP2_TOK / $COUNT_BASE_TOK) — cannot tell truncation from a stalled stream"
fi
if [ "$STOP2_FINISH" = "stop" ]; then
  probe_ok "finish_reason is \"stop\" (OpenAI's enum: stop|length|tool_calls|content_filter)"
else
  probe_fail "finish_reason for stop-string termination was \"$STOP2_FINISH\" — must be \"stop\""
fi

# A stop at offset 0 must cut everything, and must not eat a whole chunk on the way.
ask ',"stop":["banana"]' "$BANANA_PROMPT" 40
BANANA_STOP="$ANSWER"; BANANA_STOP_TOK="$ANSWER_TOKENS"
ask '' "$BANANA_PROMPT" 40
BANANA_BASE="$ANSWER"; BANANA_BASE_TOK="$ANSWER_TOKENS"
if [ "$BANANA_BASE" = "$BANANA_STOP" ] && [ -n "$BANANA_BASE" ]; then
  probe_fail "stop:[\"banana\"] left the reply byte-identical to its own control — the knob never reached the engine"
else
  case "$BANANA_STOP" in
    *banana*) probe_fail "stop:[\"banana\"] kept the stop text in the reply: $(printf %.60s "$BANANA_STOP")" ;;
    *) probe_ok "stop:[\"banana\"] cut before the first occurrence (control had $(printf %.40s "$BANANA_BASE"))" ;;
  esac
fi
if [ -n "$BANANA_STOP_TOK" ] && [ -n "$BANANA_BASE_TOK" ] && [ "$BANANA_STOP_TOK" -ge "$BANANA_BASE_TOK" ]; then
  probe_fail "stop:[\"banana\"] did not shorten generation ($BANANA_STOP_TOK vs control $BANANA_BASE_TOK)"
fi

# A stop that never occurs must cut nothing.
ask ',"stop":["ZZZZ"]' "$BANANA_PROMPT" 40
if [ "$ANSWER" = "$BANANA_BASE" ]; then
  probe_ok "a stop sequence that never occurs cuts nothing (control agrees byte-for-byte)"
else
  probe_fail "stop:[\"ZZZZ\"] changed the reply: $(printf %.60s "$ANSWER") vs control $(printf %.60s "$BANANA_BASE")"
fi

# Streaming must agree with non-streaming about where the reply ends.
SSE_TEXT=""
stream_ask() {
  local body session extra="$1" prompt="$2" mt="$3" line
  session="$(fresh_session)"
  body='{"model":"'"$PROBE_MODEL"'","session_id":"'"$session"'","temperature":0,"max_tokens":'"$mt"',"stream":true,"messages":[{"role":"user","content":"'"$prompt"'"}]'"$extra"'}'
  probe_chat "$session" "$body" || true
  SSE_TEXT="$(PROBE_BODY="$PROBE_BODY" python3 - <<'PY'
import json, os
out = []
for line in os.environ["PROBE_BODY"].split("\n"):
    if not line.startswith("data:") or "[DONE]" in line:
        continue
    try:
        j = json.loads(line[5:].strip())
    except Exception:
        continue
    for ch in j.get("choices") or []:
        out.append(((ch.get("delta") or {}).get("content")) or "")
print("".join(out))
PY
)"
}
stream_ask ',"stop":["2"]' "$COUNT_PROMPT" 64
if [ "$SSE_TEXT" = "$STOP2" ]; then
  probe_ok "streaming agrees with non-streaming on the cut: $(printf %.20s "$SSE_TEXT")"
else
  probe_fail "streaming did not honour the stop like the non-streaming path: [$SSE_TEXT] vs [$STOP2]"
fi

# ── 2. seed reproducibility ────────────────────────────────────────────────────
probe_section "2 — the same seed at temperature 1.0 must give the same text"

seeded() {
  local body seed="$1" session
  session="$(fresh_session)"
  body='{"model":"'"$PROBE_MODEL"'","session_id":"'"$session"'","temperature":1.0,"max_tokens":24,"seed":'"$seed"',"messages":[{"role":"user","content":"Name five things found in a kitchen, one word each."}]}'
  probe_chat "$session" "$body" || true
  probe_json "$PROBE_BODY" 'choices.0.message.content'
}
S1="$(seeded 12345)"
S2="$(seeded 12345)"
if [ -z "$S1" ] || [ -z "$S2" ]; then
  probe_fail "seeded turns returned empty (either the seed broke the turn or the model is not answering)"
elif [ "$S1" = "$S2" ]; then
  probe_ok "seed=12345 twice at temperature 1.0 -> byte-identical generation"
else
  probe_fail "seed=12345 twice gave different text: [$S1] vs [$S2] — the seed is not honoured"
fi
probe_note "seed=9876 for contrast: $(printf %.80s "$(seeded 9876)")"

# ── 3. max_tokens honored ─────────────────────────────────────────────────────
probe_section "3 — usage.completion_tokens must respect max_tokens"

ask '' "$COUNT_PROMPT" 8
DONE_TOKENS="$ANSWER_TOKENS"
if [ -z "$DONE_TOKENS" ]; then
  probe_note "usage.completion_tokens absent from the response (not reported, not violated)"
elif [ "$DONE_TOKENS" -le 8 ]; then
  probe_ok "max_tokens=8 -> completion_tokens=$DONE_TOKENS (within the cap)"
else
  probe_fail "max_tokens=8 but completion_tokens=$DONE_TOKENS — the cap is not enforced"
fi

# ── 4. penalties: measured, and reported honestly ─────────────────────────────
probe_section "4 — penalties: measured effect on this prompt (recorded, not asserted)"

overlaps() { # overlaps LABEL EXTRA — print how far the answer moved from the baseline
  local label="$1" extra="$2"
  ask "$extra" "$REPEAT_PROMPT" 48
  if [ "$ANSWER_STATUS" != "200" ]; then
    probe_fail "$label -> HTTP $ANSWER_STATUS (a legal knob must be accepted): $(printf %.160s "$PROBE_BODY")"
    return
  fi
  if [ -z "$ANSWER" ]; then
    probe_fail "$label returned no content — nothing to measure"
    return
  fi
  local ov
  ov="$(python3 - "$REPEAT_ANSWER" "$ANSWER" <<'PY'
import sys
base, pen = sys.argv[1].split(), sys.argv[2].split()
print("n/a" if not pen else "%.2f" % (sum(1 for w in pen if w in set(base)) / len(pen)))
PY
)"
  if [ "$ANSWER" = "$REPEAT_ANSWER" ]; then
    probe_note "$label byte-identical to baseline on this prompt — a uniform penalty preserves the relative order of the tokens in the context window, so this alone is not proof of an inert knob"
  else
    probe_note "$label moved the output (word overlap with baseline: $ov)"
  fi
}
ask '' "$REPEAT_PROMPT" 48
REPEAT_ANSWER="$ANSWER"
if [ "$ANSWER_STATUS" != "200" ] || [ -z "$REPEAT_ANSWER" ]; then
  probe_fail "penalty baseline turn failed (status $ANSWER_STATUS)"
else
  probe_ok "penalty baseline turn answered 200"
fi
overlaps "presence_penalty=+2.0" ',"presence_penalty":2.0'
overlaps "presence_penalty=-2.0" ',"presence_penalty":-2.0'
overlaps "frequency_penalty=+2.0" ',"frequency_penalty":2.0'
overlaps "frequency_penalty=-2.0" ',"frequency_penalty":-2.0'
probe_note "sign correctness lives in PenaltySignDeliveryTests (mapping + upstream context-size premise); this section records what a real model did with the values"

probe_summary "$PROBE_NAME"
