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
#   6. A broken script fails loudly: the cause reaches the client (5xx off, diagnostic on), never a
#      quiet empty turn that looks finished.
#   7. Static floor: the scoreboard still refuses a scripted backend.
#   8. The tool count AGENTS.md quotes is this server's: the injected file says how many tools the wire
#      advertises, so a tool added or left unregistered must move the sentence, not age inside it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="scripted-engine-wire"

SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
probe_atexit "rm -f '$SCRIPT_FILE'"
EXPECTED_TEXT='Sure — two deltas, in order.'

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

# 4 — the SSE stream, frame by frame.
STREAM="$(curl -sN -X POST "$PROBE_BASE/v1/chat/completions" -H 'Content-Type: application/json' \
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

# 6 — same path, broken content: the cause must reach the client.
printf '{"segments":["x"],"finishReason":"bogus"}\n' > "$SCRIPT_FILE"
probe_chat "" "$BODY"
if [ "${PROBE_STATUS:-0}" -ge 500 ] && printf '%s' "$PROBE_BODY" | grep -q 'bogus'; then
  probe_ok "broken script -> HTTP $PROBE_STATUS naming the offending finishReason (not an empty turn)"
else
  probe_fail "broken script -> HTTP ${PROBE_STATUS:-0}: $(printf '%s' "$PROBE_BODY" | head -c 200)" \
    "— an unusable script must name its cause, never answer 200 with nothing in it"
fi

# 7 — the scoreboard's refusal, so this tier can never be read as a score.
if grep -q 'engineBackend' "$HERE/../eval/run.sh" && grep -qi 'scripted' "$HERE/../eval/run.sh"; then
  probe_ok "scripts/eval/run.sh still checks engineBackend and refuses a scripted run"
else
  probe_fail "scripts/eval/run.sh no longer refuses a scripted backend — a replayed run could be" \
    "published as a task-success score, which is the one thing this tier must never allow"
fi

# 8 — the injected context quotes one number about the tool surface; this is the seat that can check it,
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

probe_summary "$PROBE_NAME"
