#!/usr/bin/env bash
# 15-system-instruction-delivery.sh — do the caller's instructions reach the model, on both faces?
#
# ### Why (AGENTS.md invariant 2 + "a per-turn knob must reach the engine")
# `messages[role=system]` is the most-used instruction field on the OpenAI wire. Measured 10-20
# on this host (`mlx-community/gemma-4-e2b-it-4bit`, temp 0) before the fix: a request whose
# `messages[0]` was a ~1000-character system message delivered the *same* `usage.prompt_tokens`
# (705) as the identical request with no system message — differential **0** — while this
# server's own disclosure line claimed it counted them (`promptTokens=838` against 712). The
# Anthropic face, whose spec carries `system` as a top-level field, delivered the same text
# (+182 `input_tokens`). One face honoured the field, the other silently dropped it, and the
# estimate said the client had paid for text the model never saw.
#
# The drop was structural, not a parsing miss: the engine takes instructions from the *first*
# system message it finds (`EngineInference.swift:1791`) and filters every `system` role out of
# the feed it renders — mlx-swift-lm's `Chat.Message.Role` has no `developer` case either
# (`Chat.swift:120-124`) — while `buildMessages` inserted this server's own prompt at index 0
# and left the client's message at index 1. Counted, never delivered; and `developer` fell
# through the engine's role switch, arriving as something the *user* said.
#
# ### Upstream
# vllm routes both roles to the developer channel (`entrypoints/openai/responses/harmony.py:128`,
# `entrypoints/openai/parser/harmony_utils.py:436`); sglang admits both as generic message roles
# (`srt/entrypoints/openai/protocol.py:727-729`). Neither strips instructions from the render,
# and neither counts them without sending them.
#
# ### What is measured
#   1. Delivery — adding ~1k chars of client instructions must raise the *delivered*
#      `usage.prompt_tokens` by a wide margin (>=40), on `/v1/chat/completions`.
#   2. `developer` lands in the same channel as `system` (same differential, not a user turn).
#   3. The two faces agree — OpenAI `prompt_tokens` and Anthropic `input_tokens` for the same
#      content within 8 tokens, with-system and without-system.
#   4. No phantom turn — the disclosure line must show exactly one system message
#      (`[system,…]`, never `[system,system,…]`) and its `systemChars=` must grow by at least
#      60% of the client text it now carries.
#   5. Instruction identity gates cache reuse — replaying the same conversation with the same
#      instructions must reuse the prefix (`cached_tokens>0`); changing the system text must
#      refuse the pooled session (`cached_tokens==0`), because that cache was rendered under an
#      instruction list this turn never sent. §5 fails as vacuous if the first pattern shows no
#      reuse, so the second half can never pass on a dead premise.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 15`).
#
# Run: bash scripts/probes/15-system-instruction-delivery.sh
PROBE_NAME="15-system-instruction-delivery"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
probe_boot
probe_require_ready_model
PROBE_TMP="$(mktemp -d -t ocoreai-probe15-XXXXXX)"
probe_atexit "rm -rf \"$PROBE_TMP\""

ASK="Name one large city in Europe."
Q1="Which is bigger, 3^4 or 4^3?"
Q2="And 2^10 vs 10^3?"
PAD="Report findings in a compact numbered list."
LONG="Client standing instruction:"
i=0
while [ "$i" -lt 22 ]; do LONG="$LONG $PAD"; i=$(( i + 1 )); done
LONG_CHARS=${#LONG}
SFX="$$"

is_int() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
abs_val() { local v="$1"; [ "$v" -lt 0 ] && v=$(( -v )); printf '%s' "$v"; }
prompt_tokens() { probe_json "$1" 'usage.prompt_tokens'; }
cached_tokens() { probe_json "$1" 'usage.prompt_tokens_details.cached_tokens'; }
input_tokens()  { probe_json "$1" 'usage.input_tokens'; }
content_of()    { probe_json "$1" 'choices.0.message.content'; }

# chat_body SESSION MAX MESSAGES_JSON — bodies are built by python from a JSON array passed
# through the environment, because assistant text replayed from a previous turn may contain
# quotes, and macOS bash 3.2 mis-parses nested quoted substitution (probe 09 documents it).
chat_body() {
  S="$1" MAX="$2" MSGS="$3" MODEL="$PROBE_MODEL" python3 -c '
import json, os
body = {"model": os.environ["MODEL"], "session_id": os.environ["S"], "temperature": 0,
        "max_tokens": int(os.environ["MAX"]), "messages": json.loads(os.environ["MSGS"])}
print(json.dumps(body))'
}
msg_array() { MSGS="$1" python3 -c 'import json,os; print(os.environ["MSGS"])'; }

# ── 1. client instructions must reach the prefill ─────────────────────────────
probe_section "1 — /v1/chat/completions delivers the caller's system message"
PLAIN="$(msg_array "[{\"role\":\"user\",\"content\":\"$ASK\"}]")"
WITH="$(msg_array "[{\"role\":\"system\",\"content\":\"$LONG\"},{\"role\":\"user\",\"content\":\"$ASK\"}]")"
probe_chat "p15-plain-$SFX" "$(chat_body "p15-plain-$SFX" 32 "$PLAIN")" || true
A="$(prompt_tokens "$PROBE_BODY")"
probe_chat "p15-sys-$SFX" "$(chat_body "p15-sys-$SFX" 32 "$WITH")" || true
B="$(prompt_tokens "$PROBE_BODY")"
if ! is_int "$A" || ! is_int "$B"; then
  probe_fail "§1 could not read prompt_tokens (plain=$A with=$B) — the differential was never measured"
else
  D=$(( B - A ))
  probe_note "delivered prompt_tokens: no instructions=$A, with ${LONG_CHARS}-char instructions=$B (differential=$D)"
  if [ "$PROBE_STATUS" != "200" ]; then
    probe_fail "§1 the instructions turn answered $PROBE_STATUS — $(printf %.200s "$PROBE_BODY")"
  elif [ "$D" -lt 40 ]; then
    probe_fail "adding $LONG_CHARS chars of client instructions changed delivered prompt_tokens by $D — the text never reached the prefill"
  else
    probe_ok "client instructions are delivered (+$D prompt_tokens for $LONG_CHARS chars)"
  fi
fi

# ── 2. developer is an instruction role, not a user turn ─────────────────────
probe_section "2 — role: developer lands in the instruction channel"
DEV="$(msg_array "[{\"role\":\"developer\",\"content\":\"$LONG\"},{\"role\":\"user\",\"content\":\"$ASK\"}]")"
probe_chat "p15-dev-$SFX" "$(chat_body "p15-dev-$SFX" 32 "$DEV")" || true
C="$(prompt_tokens "$PROBE_BODY")"
if ! is_int "$A" || ! is_int "$C"; then
  probe_fail "§2 could not read prompt_tokens (baseline=$A developer=$C)"
else
  DD=$(( C - A ))
  probe_note "developer-role differential=$DD (system-role differential was $D)"
  if [ "$DD" -lt 40 ]; then
    probe_fail "role:developer changed delivered prompt_tokens by $DD — it is not reaching the instruction channel"
  elif [ "$(abs_val "$(( DD - D ))")" -gt 8 ]; then
    probe_fail "developer and system delivered different amounts ($DD vs $D) — two channels where there should be one"
  else
    probe_ok "role:developer is delivered as instructions (+$DD, within 8 of the system-role path)"
  fi
fi

# ── 3. both faces agree ───────────────────────────────────────────────────────
probe_section "3 — Anthropic and OpenAI deliver the same instruction text"
anth_body() {
  SYS="$1" MODEL="$PROBE_MODEL" python3 -c '
import json, os
b = {"model": os.environ["MODEL"], "max_tokens": 32, "temperature": 0,
     "messages": [{"role": "user", "content": "Name one large city in Europe."}]}
if os.environ["SYS"]: b["system"] = os.environ["SYS"]
print(json.dumps(b))'
}
probe_api POST /v1/messages "$(anth_body "$LONG")" || true
E="$(input_tokens "$PROBE_BODY")"
probe_api POST /v1/messages "$(anth_body "")" || true
F="$(input_tokens "$PROBE_BODY")"
if ! is_int "$E" || ! is_int "$F" || ! is_int "$A" || ! is_int "$B"; then
  probe_fail "§3 could not read token counts (anthropic with=$E without=$F openai with=$B without=$A)"
else
  probe_note "with instructions: openai=$B anthropic=$E | without: openai=$A anthropic=$F"
  if [ "$(abs_val "$(( E - B ))")" -gt 8 ] || [ "$(abs_val "$(( F - A ))")" -gt 8 ]; then
    probe_fail "the faces disagree about the same content (with: $(abs_val "$(( E - B ))") apart, without: $(abs_val "$(( F - A ))") apart)"
  else
    probe_ok "both faces render the same instructions into the same number of tokens (within 8)"
  fi
fi

# ── 4. the disclosure must not claim a turn that was dropped ─────────────────
probe_section "4 — one instructions channel in the assembled prompt, counted once"
if grep -q '\[system,system' "$PROBE_LOG"; then
  probe_fail "the disclosure shows a duplicated system message ([system,system,…]) — the shape that let a client message be counted and then dropped"
else
  probe_ok "exactly one system message in every assembled prompt this run"
fi
CHARS_MAX="$(grep -o 'systemChars=[0-9]*' "$PROBE_LOG" | cut -d= -f2 | sort -n | tail -1)"
CHARS_MIN="$(grep -o 'systemChars=[0-9]*' "$PROBE_LOG" | cut -d= -f2 | sort -n | head -1)"
if ! is_int "$CHARS_MAX" || ! is_int "$CHARS_MIN"; then
  probe_fail "§4 could not read systemChars from $PROBE_LOG — the disclosure line is missing, so nothing was checked"
else
  GROW=$(( CHARS_MAX - CHARS_MIN ))
  NEED=$(( LONG_CHARS * 6 / 10 ))
  probe_note "systemChars span: $CHARS_MIN -> $CHARS_MAX (grew $GROW, client text was $LONG_CHARS)"
  if [ "$GROW" -lt "$NEED" ]; then
    probe_fail "the single instructions channel grew by only $GROW chars for $LONG_CHARS chars of client text — the client's instructions are not in the message that is delivered"
  else
    probe_ok "the client's text is inside the one instructions message that generation reads (+$GROW chars)"
  fi
fi

# ── 5. instruction identity gates prefix reuse ────────────────────────────────
probe_section "5 — changed instructions must not reuse the pooled session"
SAME="Keep answers to one line."
OTHER="Answer in French, keep it to one line."
# reuse_run SESSION SYS1 SYS2 — turn 1 under SYS1, then replay the whole conversation with
# SYS2 and a new question. Writes turn 2's cached_tokens to $PROBE_TMP/<sess>.cached and
# prints both turns' measured numbers directly (globals do not survive command substitution).
reuse_run() {
  local sess="$1" sys1="$2" sys2="$3"
  local m1 b1 reply m2 b2 p1 c1 p2 c2
  SYS="$sys1" Q="$Q1" python3 -c '
import json, os
print(json.dumps([{"role": "system", "content": os.environ["SYS"]},
                 {"role": "user", "content": os.environ["Q"]}]))' > "$PROBE_TMP/$sess.m1.json"
  m1="$(cat "$PROBE_TMP/$sess.m1.json")"
  b1="$(probe_chat_body "$sess" "$m1" 32)"
  probe_chat "$sess" "$b1" || true
  p1="$(prompt_tokens "$PROBE_BODY")"
  c1="$(cached_tokens "$PROBE_BODY")"
  reply="$(content_of "$PROBE_BODY")"
  SYS="$sys2" Q1="$Q1" A="$reply" Q2="$Q2" python3 -c '
import json, os
print(json.dumps([{"role": "system", "content": os.environ["SYS"]},
                 {"role": "user", "content": os.environ["Q1"]},
                 {"role": "assistant", "content": os.environ["A"]},
                 {"role": "user", "content": os.environ["Q2"]}]))' > "$PROBE_TMP/$sess.m2.json"
  m2="$(cat "$PROBE_TMP/$sess.m2.json")"
  b2="$(probe_chat_body "$sess" "$m2" 32)"
  probe_chat "$sess" "$b2" || true
  p2="$(prompt_tokens "$PROBE_BODY")"
  c2="$(cached_tokens "$PROBE_BODY")"
  printf '%s' "$c2" > "$PROBE_TMP/$sess.cached"
  printf '  NOTE  %s: turn1 prompt=%s cached=%s -> turn2 prompt=%s cached=%s (reply: %.24s)\n' \
    "$sess" "${p1:-?}" "${c1:-none}" "${p2:-?}" "${c2:-none}" "$reply"
}

SAME_SESS="p15-same-$SFX"
CHANGED_SESS="p15-changed-$SFX"
reuse_run "$SAME_SESS" "$SAME" "$SAME"
reuse_run "$CHANGED_SESS" "$SAME" "$OTHER"
REUSE_SAME="$(cat "$PROBE_TMP/$SAME_SESS.cached" 2>/dev/null || true)"
REUSE_CHANGED="$(cat "$PROBE_TMP/$CHANGED_SESS.cached" 2>/dev/null || true)"
probe_note "turn-2 cached_tokens: unchanged instructions=$REUSE_SAME, changed instructions=$REUSE_CHANGED"
if ! is_int "$REUSE_SAME" || ! is_int "$REUSE_CHANGED"; then
  probe_fail "§5 could not read cached_tokens (unchanged=$REUSE_SAME changed=$REUSE_CHANGED) — §5 judged nothing"
elif [ "$REUSE_SAME" -eq 0 ]; then
  probe_fail "unchanged instructions did not reuse the prefix (cached_tokens=0) — the reuse premise is dead, so the changed-instructions result would prove nothing"
elif [ "$REUSE_CHANGED" -ne 0 ]; then
  probe_fail "changing the system text still reused the pooled session (cached_tokens=$REUSE_CHANGED) — that cache was rendered under instructions this turn never sent"
else
  probe_ok "instruction identity gates reuse: $REUSE_SAME cached tokens kept when unchanged, 0 kept once the caller rewrote them"
fi

# The refusal must say why, out loud at the default log level: `cached_tokens==0` tells an
# operator that a turn was slow, only the reason line tells them the caller rewrote its
# instructions. Both directions are checked, and the count for the refused conversation is a
# premise floor — a grep that matched nothing would otherwise let a silent pool pass. The
# conversation id sits in the pool key, which precedes the reason, so the patterns read in
# that order.
REFUSED_CHANGED="$(grep -c "$CHANGED_SESS.*not reusable.*instructions changed" "$PROBE_LOG" 2>/dev/null || true)"
REFUSED_CHANGED="${REFUSED_CHANGED:-0}"
REFUSED_SAME="$(grep -c "$SAME_SESS.*not reusable" "$PROBE_LOG" 2>/dev/null || true)"
REFUSED_SAME="${REFUSED_SAME:-0}"
probe_note "refusal lines logged — changed-instructions conversation: $REFUSED_CHANGED, unchanged: $REFUSED_SAME"
if [ "$REFUSED_CHANGED" -lt 1 ]; then
  probe_fail "the changed-instructions refusal was not logged with a reason for $CHANGED_SESS — a cache dropped silently is indistinguishable from one that was never there"
elif [ "$REFUSED_SAME" -ne 0 ]; then
  probe_fail "the unchanged-instructions conversation was refused $REFUSED_SAME time(s) despite sending the same instructions — the identity check does not compare what it claims"
else
  probe_ok "the refusal names its cause ($REFUSED_CHANGED line, 'instructions changed'), and the identical-instructions conversation was never refused"
fi

probe_summary "$PROBE_NAME"
