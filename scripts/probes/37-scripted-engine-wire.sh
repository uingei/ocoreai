#!/usr/bin/env bash
# 37-scripted-engine-wire.sh — can the wire's contract be decided with NO model resident?
#
# ### Why
# Every live probe here used to need Metal and a checkpoint, so a contract verdict (does SSE frame
# a tool call correctly, does `usage` carry the counts it claims) cost minutes and could not run in
# the sandbox tier at all. `ScriptedInference` replays a script through the real handlers, parsers,
# SSE writer and dispatch path, so this probe is the tier that decides those claims at k=1.
# It is a wire-contract fixture, not a capability: `/v1/capabilities` says `engineBackend:
# "scripted"`, `scripts/eval/run.sh` refuses to score it, and nothing here may be read as a model
# having done anything (AGENTS.md invariant 2).
#
# ### What is asserted
#   1. Honesty field: `/v1/capabilities` answers `engineBackend: scripted` while a script drives.
#   2. Nothing resident: `/health` reports zero loaded models — the verdict above cost no weights.
#   3. Resolvable is not offered: the fixture id answers turns and is absent from `/v1/models`.
#   4. Streaming shape: reasoning delta, then tool call, then text, then a terminal frame, then
#      `[DONE]`, with the segments concatenated byte-for-byte.
#   5. Non-streaming shape: `finish_reason`, the assembled `tool_calls`, and `usage` equal to the
#      declared counts — and no `prompt_tokens_details`, because a replay reuses no prefix.
#   6. The completions lane keeps the thought channel out of `choices[].text`, and both of its
#      lanes release the same bytes — this endpoint has no field for thinking, so it must not
#      publish one by concatenating two channels into the answer.
#   7. A broken script fails loudly: the cause reaches the client (5xx off, diagnostic on), never a
#      quiet empty turn that looks finished.
#   8. Static floor: the scoreboard still refuses a scripted backend.
#   9. The tool count AGENTS.md quotes is this server's: the injected file says how many tools the wire
#      advertises, so a tool added or left unregistered must move the sentence, not age inside it.
#  10. `/v1/stats` accounting: one turn moves the request counter once and the declared token counts
#      once; a streaming turn enters the TTFB histogram exactly once and a non-streaming one not at
#      all. Those counters are advertised on `/v1/capabilities`, and nothing had read them while a
#      turn ran until 11-05, which is how a histogram with two producers stayed green.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="scripted-engine-wire"

SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
probe_atexit "rm -f '$SCRIPT_FILE'"
EXPECTED_TEXT='Sure — two deltas, in order.'
## The same script's thinking channel, spelled out because the assertion below is about a leak:
## matching on prose that the script owns keeps the verdict about the wire, not about this file.
EXPECTED_REASONING='planning the read'

cat > "$SCRIPT_FILE" <<JSON
{
  "reasoning": ["planning the read"],
  "segments": ["Sure", " — two deltas, in order."],
  "toolCalls": [{"id": "call_1", "name": "read_file", "arguments": "{\\"path\\":\\"README.md\\"}"}],
  "finishReason": "eos",
  "promptTokens": 7,
  "generatedTokens": 12
}
JSON

export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"
probe_note "script $SCRIPT_FILE — 2 segments, 1 tool call, declared counts 7/12"

BODY='{"model":"scripted-model","messages":[{"role":"user","content":"hi"}]}'

# 1 + 2 — the honesty field, and the fact that it cost no model.
probe_boot
probe_api GET /v1/capabilities
BACKEND="$(probe_json "$PROBE_BODY" 'engineBackend')"
if [ "$BACKEND" = "scripted" ]; then
  probe_ok "/v1/capabilities engineBackend=scripted — a replayed turn labels itself as one"
else
  probe_fail "/v1/capabilities engineBackend='${BACKEND:-<absent>}' with a script loaded — a replayed" \
    "turn would be published as a capability (body: $(printf '%s' "$PROBE_BODY" | head -c 200))"
fi
probe_api GET /health
RESIDENT="$(probe_json "$PROBE_BODY" 'engineSummary.loadedModels')"
probe_require_int "engineSummary.loadedModels" "${RESIDENT:-}"
if [ "${RESIDENT:-x}" = "0" ]; then
  probe_ok "0 models resident while the wire answers — this tier decides contract claims without" \
    "Metal, a checkpoint or a download"
else
  probe_fail "/health reports ${RESIDENT} resident model(s) under the scripted backend — prewarm is" \
    "loading weights anyway, so this tier no longer proves the thing it exists to prove"
fi

# 3 — a fixture id answers turns but is not offered as a model.
probe_api GET /v1/models
if printf '%s' "$PROBE_BODY" | grep -q 'scripted-model'; then
  probe_fail "/v1/models advertises scripted-model — a client would route to a model that cannot load"
else
  probe_ok "scripted-model absent from /v1/models — resolvable while a script is loaded, never offered"
fi

# 4 — the SSE stream, frame by frame. -m is not decoration: this is the one request here that does
# not go through probe_api, so a stream the server never closes has no other bound. Measured 10-28:
# a stalled stream parked the arm64 authority leg until the 60-min job timeout on six consecutive
# pushes, so each of those runs reported `cancelled` instead of a verdict.
STREAM="$(curl -sSN -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -X POST "$PROBE_BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"scripted-model","stream":true,"messages":[{"role":"user","content":"hi"}]}')"
FRAMES="$(printf '%s' "$STREAM" | grep -c '^data: ')"
probe_require_int "SSE frame count" "$FRAMES"
JOINED="$(printf '%s' "$STREAM" | python3 -c '
import json, sys
text = ""
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data:"):
        continue
    payload = line[5:].strip()
    if payload == "[DONE]":
        break
    try:
        delta = (json.loads(payload).get("choices") or [{}])[0].get("delta") or {}
    except Exception:
        continue
    text += delta.get("content") or ""
print(text)')"
if [ "$JOINED" = "$EXPECTED_TEXT" ]; then
  probe_ok "streamed text equals the script byte-for-byte (\"$JOINED\" in $FRAMES frames)"
else
  probe_fail "streamed text is \"$JOINED\", expected \"$EXPECTED_TEXT\" — the segments did not reach the" \
    "wire in order (first frames: $(printf '%s' "$STREAM" | head -4 | tr '\n' '|'))"
fi
for want in 'reasoning_content' '"tool_calls"' '"finish_reason"' '\[DONE\]'; do
  if printf '%s' "$STREAM" | grep -q -- "$want"; then
    probe_ok "stream carries $want"
  else
    probe_fail "stream carries no $want — the frame set this tier exists to pin is incomplete"
  fi
done

# 5 — the aggregated turn, with exact numbers.
probe_chat "" "$BODY"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "non-streaming turn -> ${PROBE_STATUS:-no response}: $(printf '%s' "$PROBE_BODY" | head -c 200)"
  probe_summary "$PROBE_NAME"
fi
probe_note "turn round-trip ${PROBE_ELAPSED_MS}ms with 0 models resident"
for pair in 'choices.0.finish_reason=tool_calls' \
            'choices.0.message.tool_calls.0.function.name=read_file' \
            'choices.0.message.tool_calls.0.id=call_1' \
            'usage.prompt_tokens=7' 'usage.completion_tokens=12' 'usage.total_tokens=19'; do
  key="${pair%%=*}" want="${pair#*=}"
  got="$(probe_json "$PROBE_BODY" "$key")"
  if [ "$got" = "$want" ]; then
    probe_ok "$key=$want"
  else
    probe_fail "$key='${got:-<absent>}' expected \"$want\" — the wire publishes a different turn than the" \
      "script declares (body: $(printf '%s' "$PROBE_BODY" | head -c 200))"
  fi
done
if printf '%s' "$PROBE_BODY" | grep -q 'prompt_tokens_details'; then
  probe_fail "usage carries prompt_tokens_details on a replayed turn — a script reuses no prefix, so a" \
    "cached count here is a claim the engine did not deliver"
else
  probe_ok "no prompt_tokens_details — no cache-reuse claim on a replayed turn"
fi

# 6 — the completions lane, which has no second channel to put thinking in.
#     Measured 10-31 against this very script: `stream:false` published
#     "planning the read Sure — two deltas, in order." as `choices[0].text` while `stream:true`
#     published "Sure — two deltas, in order.", and the chat sibling of the same turn split them
#     into `content` and `reasoning_content`. `text` is what a client prints and what a harness
#     scores, so on a thinking model this route handed the thought back as the answer. The decision
#     already has a home with the other two consumers of the event (ChatHandler.swift:1072-1075 —
#     "leaked the full thought block into the non-streaming `content` field" — and
#     AnthropicMessagesHandler.swift:1031, which gives it a `thinking` block): reasoning is its own
#     channel, and a wire with no field for it does not publish one by concatenating.
COMPLETIONS_BODY='{"model":"scripted-model","prompt":"write a line","max_tokens":8}'
LANES=0
probe_api POST /v1/completions "$COMPLETIONS_BODY"
PLAIN_TEXT=""
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "non-streaming /v1/completions -> ${PROBE_STATUS:-no response}:" \
    "$(printf '%s' "$PROBE_BODY" | head -c 200)" \
    " — neither lane below can be read as a verdict while the route does not answer"
else
  PLAIN_TEXT="$(probe_json "$PROBE_BODY" 'choices.0.text')"
  LANES=$(( LANES + 1 ))
  if [ "$PLAIN_TEXT" = "$EXPECTED_TEXT" ]; then
    probe_ok "completions choices[0].text is the answer alone (\"$PLAIN_TEXT\") — the thought channel" \
      "stayed off the field a client prints"
  elif printf '%s' "$PLAIN_TEXT" | grep -qF "$EXPECTED_REASONING"; then
    probe_fail "completions choices[0].text carries the thought: \"$PLAIN_TEXT\" — the reasoning channel" \
      "was concatenated into the answer, so every score read off this field reads the wrong bytes"
  else
    probe_fail "completions choices[0].text is \"$PLAIN_TEXT\", expected \"$EXPECTED_TEXT\" — neither the" \
      "answer nor a known leak: the segments stopped reaching this wire"
  fi
fi

CSTREAM="$(curl -sSN -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -X POST "$PROBE_BASE/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"scripted-model\",\"prompt\":\"write a line\",\"max_tokens\":8,\"stream\":true}")"
CFRAMES="$(printf '%s' "$CSTREAM" | grep -c '^data: ')"
probe_require_int "completions SSE frame count" "$CFRAMES"
CJOINED="$(printf '%s' "$CSTREAM" | python3 -c '
import json, sys
text = ""
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data:"):
        continue
    payload = line[5:].strip()
    if payload == "[DONE]":
        break
    try:
        choice = (json.loads(payload).get("choices") or [{}])[0]
    except Exception:
        continue
    text += choice.get("text") or ""
print(text)')"
if [ "${CFRAMES:-0}" -ge 1 ]; then
  LANES=$(( LANES + 1 ))
fi
if [ "$CJOINED" = "$EXPECTED_TEXT" ]; then
  probe_ok "completions stream released \"$CJOINED\" in $CFRAMES frame(s) — the same bytes, no thought"
elif printf '%s' "$CJOINED" | grep -qF "$EXPECTED_REASONING"; then
  probe_fail "completions stream released the thought too: \"$CJOINED\" — the two lanes now disagree with" \
    "each other and with the sanitizer, which is the drift this file's invariant forbids"
else
  probe_fail "completions stream released \"$CJOINED\", expected \"$EXPECTED_TEXT\" (frames:" \
    "$(printf '%s' "$CSTREAM" | head -3 | tr '\n' '|'))"
fi
if [ -n "$PLAIN_TEXT" ] && [ "$PLAIN_TEXT" = "$CJOINED" ]; then
  probe_ok "both lanes of /v1/completions released byte-identical text — the streaming wire did not" \
    "drift from the non-streaming one"
else
  probe_fail "/v1/completions lanes disagree: non-stream \"$PLAIN_TEXT\" vs stream \"$CJOINED\" — one" \
    "endpoint cannot publish two different turns for one request"
fi
if [ "$LANES" -ge 2 ]; then
  probe_ok "$LANES/2 completions lanes measured — §6's green is a verdict about both, not a scan that" \
    "answered nothing"
else
  probe_fail "only $LANES/2 completions lanes were measured — §6 has no subjects, so its verdict means" \
    "nothing (probe rule: floor your own premises)"
fi

# 7 — same path, broken content: the cause must reach the client.
printf '{"segments":["x"],"finishReason":"bogus"}\n' > "$SCRIPT_FILE"
probe_chat "" "$BODY"
if [ "${PROBE_STATUS:-0}" -ge 500 ] && printf '%s' "$PROBE_BODY" | grep -q 'bogus'; then
  probe_ok "broken script -> HTTP $PROBE_STATUS naming the offending finishReason (not an empty turn)"
else
  probe_fail "broken script -> HTTP ${PROBE_STATUS:-0}: $(printf '%s' "$PROBE_BODY" | head -c 200)" \
    "— an unusable script must name its cause, never answer 200 with nothing in it"
fi

# 8 — the scoreboard's refusal, so this tier can never be read as a score.
if grep -q 'engineBackend' "$HERE/../eval/run.sh" && grep -qi 'scripted' "$HERE/../eval/run.sh"; then
  probe_ok "scripts/eval/run.sh still checks engineBackend and refuses a scripted run"
else
  probe_fail "scripts/eval/run.sh no longer refuses a scripted backend — a replayed run could be" \
    "published as a task-success score, which is the one thing this tier must never allow"
fi

# 9 — the injected context quotes one number about the tool surface; this is the seat that can check it,
# because the count is a property of a running server and `make docs-check` runs without one.
# The phrasing around the number is prose and gets rewritten (it drifted from "measures 6 of the 43
# tools" to "scores 6 of the 40 advertised tools" and this scan silently found nothing), so match on
# the shape that carries the fact — "6 of [the] N [advertised|registered] tools" — not on one wording.
DOC_TOOLS="$(sed -nE 's/.*6 of (the )?([0-9]+)( (advertised|registered))? tools.*/\2/p' \
  "$PROBE_REPO_ROOT/AGENTS.md" | head -1)"
probe_require_int "the tool count AGENTS.md quotes" "${DOC_TOOLS:-}"
probe_api GET /v1/tools
ADVERTISED="$(printf '%s' "$PROBE_BODY" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data", [])))')"
probe_require_int "GET /v1/tools entries" "$ADVERTISED"
if [ "${DOC_TOOLS:-x}" = "${ADVERTISED:-y}" ]; then
  probe_ok "AGENTS.md quotes $DOC_TOOLS advertised tools — the injected number is this server's"
else
  probe_fail "AGENTS.md quotes ${DOC_TOOLS:-?} advertised tools, /v1/tools answers ${ADVERTISED:-?} — a" \
    "tool landed or stopped registering and the injected context still describes the old surface; fix" \
    "the sentence in AGENTS.md or the registration, whichever is wrong"
fi

# 10 — the counters `/v1/capabilities` advertises ("Structured inference counters and gauges") must
# move exactly once per turn. `/v1/stats` was a published promise no probe had read while a turn ran
# until 11-05: the TTFB histogram had two producers — the streaming lane called `observeTTFB` and
# handed the same value to `observeInferenceDuration`, which counts it too — so every streamed turn
# entered `ocoreai_ttfb_seconds` twice while `totalRequests` moved by one. The average hid it (both
# sides of the quotient doubled); only the counts lied, and nothing read the counts. This is the seat
# that reads them, weight-free: a replayed turn drives the same handlers, so it produces the same
# accounting a checkpoint would, at no Metal cost.
# Tool-free on purpose: a tool call would add a second generation round, and every assertion below
# is one turn = the script's declared counts, exactly once.
cat > "$SCRIPT_FILE" <<JSON
{
  "reasoning": ["planning the read"],
  "segments": ["counting the deltas, once each"],
  "finishReason": "eos",
  "promptTokens": 7,
  "generatedTokens": 12
}
JSON

# Snapshot into globals, never through `$( )`: a verdict raised inside a command substitution runs
# in a subshell, so its `probe_fail` would print and vanish while `probe_summary` still counted the
# section green. Only the pure parsers get to live in a subshell.
stats_snap() {
  probe_api GET /v1/stats
  [ "${PROBE_STATUS:-0}" = "200" ] || probe_fail "GET /v1/stats -> ${PROBE_STATUS:-0} — the counters" \
    "this section judges are unreadable, which is a harness fault and never a zero"
  STATS_R="$(probe_json "$PROBE_BODY" totalRequests)"
  STATS_T="$(probe_json "$PROBE_BODY" ttfbSampleCount)"
  STATS_P="$(probe_json "$PROBE_BODY" totalPromptTokens)"
  STATS_G="$(probe_json "$PROBE_BODY" totalGeneratedTokens)"
  local pair
  for pair in "totalRequests=$STATS_R" "ttfbSampleCount=$STATS_T" "totalPromptTokens=$STATS_P" \
    "totalGeneratedTokens=$STATS_G"; do
    probe_require_int "GET /v1/stats ${pair%%=*}" "${pair#*=}"
  done
}

stats_snap; R0="$STATS_R"; T0="$STATS_T"; P0="$STATS_P"; G0="$STATS_G"

# 10a — a non-streaming turn has no first byte, so it moves the request and token counters and
# leaves the latency curve untouched.
probe_chat "" "$BODY"
[ "${PROBE_STATUS:-0}" = "200" ] || probe_fail "§10a's turn answered ${PROBE_STATUS:-0}, so the" \
  "deltas below have no subject — a counter verdict about a turn that never ran is a vacuous pass"
stats_snap; R1="$STATS_R"; T1="$STATS_T"; P1="$STATS_P"; G1="$STATS_G"
if [ $(( R1 - R0 )) -eq 1 ] && [ $(( T1 - T0 )) -eq 0 ]; then
  probe_ok "non-streaming turn: requests +1, TTFB samples +0 — a turn that streamed nothing" \
    "entered no first-byte curve"
else
  probe_fail "non-streaming turn moved requests by $(( R1 - R0 )) and TTFB samples by" \
    "$(( T1 - T0 )) — expected +1/+0; a silent turn entering the latency curve counts a byte" \
    "nobody sent"
fi
if [ $(( P1 - P0 )) -eq 7 ] && [ $(( G1 - G0 )) -eq 12 ]; then
  probe_ok "the same turn moved the counters by the script's declared 7/12 — the advertised" \
    "counters and the turn's own usage field agree"
else
  probe_fail "the counters moved by $(( P1 - P0 ))/$(( G1 - G0 )), the script declared 7/12 — the" \
    "advertised counters and the wire's usage field now describe different turns"
fi

# 10b — a streaming turn has exactly one first byte, so exactly one sample enters. The doubled
# producer measured 2 here on 11-05.
STREAM_BODY="$(printf '%s' "$BODY" \
  | python3 -c 'import json,sys; b=json.load(sys.stdin); b["stream"]=True; print(json.dumps(b))')"
# An array, not an inline `${KEYS:+-H "Authorization: …"}`: inside an unquoted word the quotes in the
# alternate value are literal bytes, so a keyed run would send `-H "Authorization:` and split the rest.
stream_args=(-sS -X POST)
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  stream_args+=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi
stream_args+=(-H 'Content-Type: application/json' --data "$STREAM_BODY"
  "$PROBE_BASE/v1/chat/completions")
# The deadline sits on the call line, not inside the array: Class-L reads the site, and a site whose
# bound lives twelve lines away is indistinguishable from one that has none.
stream_status="$(curl -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" "${stream_args[@]}" \
  -o /dev/null -w '%{http_code}' 2>/dev/null)"
if [ "$stream_status" = "200" ]; then
  stats_snap; R2="$STATS_R"; T2="$STATS_T"
  if [ $(( R2 - R1 )) -eq 1 ] && [ $(( T2 - T1 )) -eq 1 ]; then
    probe_ok "streaming turn: requests +1, TTFB samples +1 — one first byte is one sample"
  else
    probe_fail "streaming turn moved requests by $(( R2 - R1 )) and TTFB samples by" \
      "$(( T2 - T1 )) — expected +1/+1; $(( T2 - T1 )) samples for one streamed turn means the" \
      "histogram has two producers again, which doubles every rate a dashboard computes from it"
  fi
else
  probe_fail "the streaming turn answered ${stream_status:-nothing} — §10b has no subject, so its" \
    "counter verdict would be a vacuous pass (probe rule: floor your own premises)"
fi

probe_summary "$PROBE_NAME"
