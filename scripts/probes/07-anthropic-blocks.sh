#!/usr/bin/env bash
# 07-anthropic-blocks.sh — does /v1/messages honour, or blank, the blocks a real SDK sends?
#
# Why (AGENTS.md invariant 2 + § Wire DTOs: "a field the spec calls polymorphic must decode
# every shape the spec names"): `/v1/messages` decodes a message's content as
# `AnthropicContent`, whose array branch decodes `[AnthropicContentBlock]`, whose `type` is a
# closed enum of `text | tool_use`. Array decoding is all-or-nothing, so ONE spec-legal block
# of any other type — `image`, `document`, or `tool_result` (the shape Anthropic's own SDK
# requires for returning tool results in a multi-turn agent loop) — makes the whole array fail,
# and `AnthropicContent`'s non-throwing fallback turns the message into `.text("")`. The turn
# that reaches the model is then empty, and the route can answer 200. A client cannot tell that
# from a model that simply had nothing to say.
#
# The invariant this probe holds the route to, for every block shape it sends:
#
#   1. HONOURED  — 200, and the text sitting next to the exotic block demonstrably reached
#                  the model: a deterministic code-word instruction at temperature 0, plus a
#                  prompt-token floor. The floor is two-tier because the engine's own
#                  accounting is: text-bearing blocks must ADD tokens (their words went in),
#                  while a media block may leave the count unchanged — measured 10-16, this
#                  route reports the same 22 input_tokens with and without an 8x8 PNG, so it
#                  counts the text axis only. For media the floor is therefore "never smaller
#                  than baseline" (pre-fix blanking measured 10 against 22) and the proof of
#                  delivery is the code word plus the cross-route vision check below; or
#   2. REFUSED   — a non-2xx whose message NAMES the block type it cannot honour.
#
# A 200 that answers around an empty turn is a FAIL, and a refusal that does not name the
# block is a FAIL. Both are the same defect wearing different clothes.
#
# Vision on a `vlm: true` model additionally reports (never gates) whether the picture's
# colour came back, so `/v1/messages` and `/v1/chat/completions` — which probe 04 shows
# delivering an inline PNG — can be compared rather than assumed equal.
#
# Run: bash scripts/probes/07-anthropic-blocks.sh
PROBE_NAME="07-anthropic-blocks"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CHECKS=0
ok()  { CHECKS=$(( CHECKS + 1 )); probe_ok "$*"; }
bad() { CHECKS=$(( CHECKS + 1 )); probe_fail "$*"; }

# Deterministic instruction: if the sibling text survived decoding, this word comes back.
WORD="KESTREL"
INSTRUCTION="Reply with the single word $WORD and nothing else."

anthropic_text() {
  python3 - "$1" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
content = doc.get("content")
if isinstance(content, list):
    print(" ".join(str(b.get("text", "")) for b in content).strip())
elif isinstance(content, str):
    print(content.strip())
PY
}

# 8x8 solid-red PNG, built inline so the run needs no external asset (same as probe 04).
red_png() {
  python3 - <<'PY'
import base64, struct, zlib
w = h = 8
raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
def chunk(tag, payload):
    return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
print(base64.b64encode(png).decode())
PY
}

probe_boot
probe_require_ready_model

# ── 1. baseline: plain-string content, the shape that has always worked ──────
probe_section "baseline — content as a plain string, so the code-word method is calibrated"
BASELINE_OK=0
BASE_INPUT_TOKENS=""
BODY="$(python3 - "$PROBE_MODEL" "$INSTRUCTION" <<'PY'
import json, sys
model, instruction = sys.argv[1:3]
print(json.dumps({
    "model": model, "max_tokens": 16, "temperature": 0.0,
    "messages": [{"role": "user", "content": instruction}],
}))
PY
)"
probe_api POST /v1/messages "$BODY"
BASE_TEXT_OUT="$(anthropic_text "$PROBE_BODY")"
BASE_INPUT_TOKENS="$(probe_json "$PROBE_BODY" 'usage.input_tokens')"
probe_note "baseline -> HTTP ${PROBE_STATUS:-none} | input_tokens=${BASE_INPUT_TOKENS:-none} | text='${BASE_TEXT_OUT:0:80}'"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  ok "text-only /v1/messages 200"
else
  bad "text-only /v1/messages -> ${PROBE_STATUS:-no response}: $(printf '%.200s' "$PROBE_BODY")"
fi
if printf '%s' "$BASE_TEXT_OUT" | grep -qi "$WORD"; then
  BASELINE_OK=1
  ok "the code-word method works on this model (answer contains $WORD at temperature 0)"
else
  probe_note "this model does not obey the code-word instruction even on a clean text turn"
  probe_note "⇒ delivery is measured by the input-token floor alone (still a hard check)"
fi

# Premises gate. Every block verdict below compares against this baseline; a run whose
# baseline is unusable must say so and stop, not hand out PASSes built on thin air
# (AGENTS.md invariant 1 — the same reasoning as the scan floors).
if [ "${PROBE_STATUS:-}" != "200" ] || [ -z "$BASE_TEXT_OUT" ] || [ -z "$BASE_INPUT_TOKENS" ]; then
  bad "baseline is unusable (HTTP ${PROBE_STATUS:-none}, text='${BASE_TEXT_OUT:0:40}', input_tokens=${BASE_INPUT_TOKENS:-none}) — no block verdict would mean anything, aborting"
  probe_summary "$PROBE_NAME"
fi
ok "baseline premises hold: 200, non-empty answer, input_tokens=$BASE_INPUT_TOKENS"

# ── 2. the boundary: a content ARRAY holding only a text block ───────────────
probe_section "text-block array — where does the array branch itself start to fail?"
TBODY="$(python3 - "$PROBE_MODEL" "$INSTRUCTION" <<'PY'
import json, sys
model, instruction = sys.argv[1:3]
print(json.dumps({
    "model": model, "max_tokens": 16, "temperature": 0.0,
    "messages": [{"role": "user", "content": [{"type": "text", "text": instruction}]}],
}))
PY
)"
probe_api POST /v1/messages "$TBODY"
TTEXT="$(anthropic_text "$PROBE_BODY")"
TTOKENS="$(probe_json "$PROBE_BODY" 'usage.input_tokens')"
probe_note "text-block array -> HTTP ${PROBE_STATUS:-none} | input_tokens=${TTOKENS:-none} (baseline $BASE_INPUT_TOKENS) | text='${TTEXT:0:60}'"
# The array wrapper costs no tokens (same text inside), so this case is judged on the
# answer, with the token floor as the fallback when the model ignores the code word.
TOK_OK=0
if [ -n "$TTOKENS" ] && [ "$TTOKENS" -ge "$BASE_INPUT_TOKENS" ]; then TOK_OK=1; fi
if [ "${PROBE_STATUS:-}" = "200" ] && [ "$TOK_OK" = "1" ] \
   && { [ "$BASELINE_OK" != "1" ] || printf '%s' "$TTEXT" | grep -qi "$WORD"; }; then
  ok "[{type:text,…}] alone is honoured (input_tokens $TTOKENS vs baseline $BASE_INPUT_TOKENS) — the break is specific to unrecognised block types"
else
  bad "even [{type:text,…}] blanks the turn (HTTP ${PROBE_STATUS:-none}, input_tokens=${TTOKENS:-none} vs baseline $BASE_INPUT_TOKENS) — the array branch is broken for every shape"
fi

# ── 2. each spec-legal block type next to the same instruction ───────────────
PNG_B64="$(red_png)"

check_block() {
  local label="$1" block_json="$2" block_name="$3" kind="${4:-text}"
  local body text tokens errtype errmessage
  # The block arrives as JSON text so this function can take any shape, known or not.
  body="$(python3 - "$PROBE_MODEL" "$block_json" "$INSTRUCTION" <<'PY'
import json, sys
model, block_json, instruction = sys.argv[1:4]
print(json.dumps({
    "model": model,
    "max_tokens": 16,
    "temperature": 0.0,
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": instruction}, json.loads(block_json)]}],
}))
PY
)"
  probe_api POST /v1/messages "$body"
  text="$(anthropic_text "$PROBE_BODY")"
  tokens="$(probe_json "$PROBE_BODY" 'usage.input_tokens')"
  errtype="$(probe_json "$PROBE_BODY" 'error.type')"
  errmessage="$(probe_json "$PROBE_BODY" 'error.message')"
  probe_note "$label -> HTTP ${PROBE_STATUS:-none} | input_tokens=${tokens:-none} (baseline ${BASE_INPUT_TOKENS:-none}) | text='${text:0:70}' | error.type=${errtype:-none}"

  case "${PROBE_STATUS:-}" in
    200)
      # HONOURED: the sibling text must demonstrably still be in the turn.
      if [ -z "$text" ]; then
        bad "$label: 200 with empty content — the turn was accepted and nothing was answered"
        return
      fi
      if [ "$BASELINE_OK" = "1" ] && ! printf '%s' "$text" | grep -qi "$WORD"; then
        bad "$label: 200 but the sibling text did not reach the model (no $WORD in the answer) — the block blanked the message"
        return
      fi
      # The sibling instruction is in EVERY request sent here, so a prompt that comes back
      # SMALLER than the plain-string baseline lost it — the blanking this probe exists to
      # catch (measured pre-fix: 10 tokens against a 22-token baseline).
      if [ -z "$tokens" ]; then
        bad "$label: 200 with no usage.input_tokens — delivery cannot be claimed or refuted"
        return
      fi
      if [ "$tokens" -lt "$BASE_INPUT_TOKENS" ]; then
        bad "$label: 200 with input_tokens $tokens vs baseline $BASE_INPUT_TOKENS — the instruction never entered the prompt, so this turn was answered blind"
        return
      fi
      if [ "$kind" = "text" ]; then
        # A text-bearing block adds words to the prompt, so its absence in the count means
        # the words were not added.
        if [ "$tokens" -le "$(( BASE_INPUT_TOKENS + 4 ))" ]; then
          bad "$label: 200 with input_tokens $tokens vs baseline $BASE_INPUT_TOKENS — the block's text never entered the prompt"
          return
        fi
        ok "$label: 200 with input_tokens $tokens vs baseline $BASE_INPUT_TOKENS — the block's text reached the model"
      else
        # Media: this route's `usage.input_tokens` counts the text axis only (measured 10-16:
        # the same 22 with and without an 8x8 PNG), so the floor is "not smaller", and the
        # proof of delivery is the code word plus the cross-route vision check below.
        probe_note "$label: input_tokens $tokens == baseline $BASE_INPUT_TOKENS — this route counts no vision tokens, so the floor here is 'not smaller', and delivery rests on the code word"
        ok "$label: 200, prompt not smaller than baseline ($tokens vs $BASE_INPUT_TOKENS), and the instruction survived"
      fi
      ;;
    4??|5??)
      if printf '%s' "$errmessage" | grep -qi "$block_name"; then
        ok "$label: refused by name at ${PROBE_STATUS} ('$block_name' named in the message)"
      else
        bad "$label: refused at ${PROBE_STATUS} without naming the block — client cannot tell which shape to drop: ${errmessage:0:140}"
      fi
      ;;
    *)
      bad "$label: unexpected HTTP ${PROBE_STATUS:-none}: $(printf '%.200s' "$PROBE_BODY")"
      ;;
  esac
}

probe_section "image block — the vision shape Anthropic SDKs emit"
check_block "image block" \
  "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"$PNG_B64\"}}" \
  "image" media

probe_section "tool_result block — the required shape for a tool loop's second turn"
check_block "tool_result block" \
  "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_probe_1\",\"content\":[{\"type\":\"text\",\"text\":\"The measured value is 42.\"}]}" \
  "tool_result"

probe_section "document block — spec-legal, and this engine has no document reader"
check_block "document block" \
  "{\"type\":\"document\",\"source\":{\"type\":\"text\",\"media_type\":\"text/plain\",\"data\":\"The capital of Peru is Lima.\"}}" \
  "document"

probe_section "unknown future block — one unrecognised type must not erase the text beside it"
check_block "unknown block" \
  "{\"type\":\"search_result\",\"content\":[{\"type\":\"text\",\"text\":\"irrelevant\"}]}" \
  "search_result"

# ── 3. vision cross-route comparison (reported, not gated) ───────────────────
probe_section "vision cross-route — does /v1/messages see what /v1/chat/completions sees?"
probe_api GET /v1/models
VLM="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1]).get("data", [])
except Exception:
    sys.exit(0)
for m in data:
    caps = m.get("capabilities") or {}
    if caps.get("vlm") or m.get("vlm"):
        print(m.get("id", ""))
        break
PY
)"
if [ -n "$VLM" ]; then
  VBODY="$(python3 - "$VLM" "$PNG_B64" <<'PY'
import json, sys
model, png = sys.argv[1:3]
print(json.dumps({
    "model": model,
    "max_tokens": 16,
    "temperature": 0.0,
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "What single colour fills this image? Answer with the colour name only."},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": png}},
    ]}],
}))
PY
)"
  probe_api POST /v1/messages "$VBODY"
  VTEXT="$(anthropic_text "$PROBE_BODY")"
  probe_note "$VLM via /v1/messages -> HTTP ${PROBE_STATUS:-none} | text='${VTEXT:0:100}'"
  if [ "${PROBE_STATUS:-}" = "200" ] && [ -n "$VTEXT" ]; then
    if printf '%s' "$VTEXT" | grep -qiE "red|红色"; then
      ok "/v1/messages answered the red PNG — vision delivered on this route too"
    else
      probe_note "it answered but did not name red; probe 04 keeps colour out of the gate (model fidelity on a ≤2B model)"
    fi
  elif [ "${PROBE_STATUS:-}" = "200" ]; then
    bad "$VLM via /v1/messages returned 200 with empty content next to an image — 能看 claimed, not delivered"
  else
    probe_note "/v1/messages did not accept the image (${PROBE_STATUS:-no response}) — see the image-block verdict above for whether it named the shape"
  fi
else
  probe_note "no vlm:true model published by /v1/models — cross-route vision not measurable this run"
fi

# ── verdict ───────────────────────────────────────────────────────────────────
# Baseline (2) + four block shapes (1 each) + the vision cross-check + this floor is ~8.
# 6 sits well under that and well above zero: a route that stopped answering, or a scan that
# stopped matching, fails instead of passing vacuously.
if [ "$CHECKS" -ge 7 ]; then
  ok "premise floor: $CHECKS verdicts issued by this run"
else
  probe_fail "only $CHECKS verdicts issued (< 6) — this probe silently stopped measuring"
fi
probe_summary "$PROBE_NAME"
