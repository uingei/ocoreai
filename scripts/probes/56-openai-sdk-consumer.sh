#!/usr/bin/env bash
# 56-openai-sdk-consumer.sh — does the canonical OpenAI Python SDK consume our wire unmodified?
#
# ### Why
# Root § Adoption left "a generated client" as the missing artifact of a public contract. The field's
# shipped shape answers that differently: `vllm` ships no client — it pins `openai >= 2.25.0` as a
# test dependency (requirements/common.txt:21) and its entrypoint tests import `from openai import
# OpenAI` as the consumer (tests/entrypoints/**). The promise is not an artifact we maintain but a
# claim we prove: a canonical client, written against the spec and owing us nothing, round-trips
# `/v1/chat/completions`. This probe makes that claim gateable on both turn faces.
#
# ### What makes it a proof rather than a demo
# The SDK is used the way its docs use it (typed create(), streamed iteration, `.tool_calls` access),
# and every compared value is a literal owned by this file through the scripted engine (no weights).
# §1 the tool-turn face asserts what this server DOCUMENTS rather than what a happy-path test would
# wish: on a turn carrying tool calls, `message.content` is "" by `contentWireFallback`'s rule (the
# corrective-echo incident — narration must not become the answer), the calls and usage carry exact
# values, and `finish_reason` is `tool_calls`; the streamed face still shows the narration deltas —
# that asymmetry is shipped intent, recorded here so a reader learns it from a green, not an incident.
# §2 the answer-turn face asserts the text itself byte-exact, non-stream and streamed.
#
# ### Premises (each a red with a remedy, never a skip)
# The resolved binary, a scripted boot, and `openai` importable — system Python first, else a
# throwaway venv (`pip install 'openai>=2.25.0,<3'`). Both failing is a missing subject: red naming
# the remedy, not a skip, so a tree cannot pass by having no consumer.
#
# Fails when: the SDK rejects our response shape, calls/usage/content lose exact values in the round
# trip, the tool-turn blank-face stops being blank, or a streamed answer does not reassemble in order.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="openai-sdk-consumer"

BIN="$(probe_resolve_binary)" || probe_fail "no ocoreai binary" " set OCOREAI_BIN"

EXPECTED_TEXT='Sure — two deltas, in order.'
EXPECTED_TOOL='read_file'
EXPECTED_ARGS='{"path":"README.md"}'
EXPECTED_PROMPT_TOKENS=7
EXPECTED_GEN_TOKENS=12

# ── §0 the subject: the canonical SDK itself ───────────────────────────────────────────────────
probe_section "§0 openai-python is importable (system first, throwaway venv else)"
PY=""
if python3 -c "import openai" >/dev/null 2>&1; then
  PY="python3"
  probe_ok "system python carries openai $(python3 -c 'import openai;print(openai.__version__)')"
else
  VENV="${OCOREAI_PROBE56_VENV:-$(mktemp -d -t ocoreai-sdk-venv-XXXXXX)}"
  probe_atexit "[ \"\${OCOREAI_PROBE56_KEEP_VENV:-}\" = 1 ] || rm -rf '$VENV'"
  if python3 -m venv "$VENV" >/dev/null 2>&1 \
     && "$VENV/bin/pip" install --quiet --timeout 20 --retries 2 'openai>=2.25.0,<3' >/dev/null 2>&1 \
     && "$VENV/bin/python" -c "import openai" >/dev/null 2>&1; then
    PY="$VENV/bin/python"
    probe_ok "venv carries openai $("$VENV/bin/python" -c 'import openai;print(openai.__version__)')"
  else
    probe_fail "no openai-python: not on the host, and venv+pip could not provision it" \
      " pypi may be unreachable or python3 lacks venv — pre-provision a venv and export" \
      " OCOREAI_PROBE56_VENV; a skip here would let a tree pass by having no consumer"
  fi
fi

SCRIPT_FILE="$(mktemp -t ocoreai-sdk-script-XXXXXX).json"
probe_atexit "rm -f '$SCRIPT_FILE'"
write_tool_script() {
  cat > "$SCRIPT_FILE" <<JSON
{
  "reasoning": ["planning the answer"],
  "segments": ["Sure", " — two deltas, in order."],
  "toolCalls": [{"id": "call_1", "name": "read_file", "arguments": "{\\"path\\":\\"README.md\\"}"}],
  "finishReason": "eos",
  "promptTokens": $EXPECTED_PROMPT_TOKENS,
  "generatedTokens": $EXPECTED_GEN_TOKENS
}
JSON
}
write_answer_script() {
  cat > "$SCRIPT_FILE" <<JSON
{
  "segments": ["Sure", " — two deltas, in order."],
  "finishReason": "eos",
  "promptTokens": $EXPECTED_PROMPT_TOKENS,
  "generatedTokens": $EXPECTED_GEN_TOKENS
}
JSON
}

RUNNER="$(mktemp -t ocoreai-sdk-run-XXXXXX).py"
probe_atexit "rm -f '$RUNNER'"
cat > "$RUNNER" <<'PY'
import os, sys
from openai import OpenAI

client = OpenAI(base_url=os.environ["SDK_BASE"] + "/v1", api_key="probe-local", timeout=30.0)
text = os.environ["EXPECTED_TEXT"]
mode = os.environ["SDK_MODE"]
wants = set()
if mode == "tool":
    wants = {"tool-name", "tool-args", "content-blank", "finish-tool-calls",
             "prompt-tokens", "gen-tokens", "stream-tool-name"}
else:
    wants = {"answer-content", "prompt-tokens", "gen-tokens", "stream-rejoin"}

def ok(what, value):
    print(f"OK\t{what}\t{value}")
    wants.discard(what)

body = [{"role": "user", "content": "hi"}]
r = client.chat.completions.create(model="scripted-model", messages=body)
msg = r.choices[0].message
if r.usage.prompt_tokens == int(os.environ["EXPECTED_PROMPT_TOKENS"]):
    ok("prompt-tokens", r.usage.prompt_tokens)
if r.usage.completion_tokens == int(os.environ["EXPECTED_GEN_TOKENS"]):
    ok("gen-tokens", r.usage.completion_tokens)

if mode == "tool":
    calls = msg.tool_calls
    if calls and calls[0].function.name == os.environ["EXPECTED_TOOL"]:
        ok("tool-name", calls[0].function.name)
    if calls and calls[0].function.arguments == os.environ["EXPECTED_ARGS"]:
        ok("tool-args", calls[0].function.arguments)
    if (msg.content or "") == "":
        ok("content-blank", repr(msg.content))
    if r.choices[0].finish_reason == "tool_calls":
        ok("finish-tool-calls", r.choices[0].finish_reason)
    acc_name = ""
    for chunk in client.chat.completions.create(model="scripted-model", messages=body, stream=True):
        ch = chunk.choices[0] if chunk.choices else None
        for tc in (ch.delta.tool_calls or []) if ch else []:
            if tc.function and tc.function.name:
                acc_name += tc.function.name
    if acc_name == os.environ["EXPECTED_TOOL"]:
        ok("stream-tool-name", acc_name)
else:
    if msg.content == text:
        ok("answer-content", msg.content)
    acc = ""
    for chunk in client.chat.completions.create(model="scripted-model", messages=body, stream=True):
        if chunk.choices and chunk.choices[0].delta.content:
            acc += chunk.choices[0].delta.content
    if acc == text:
        ok("stream-rejoin", acc)

for missing in sorted(wants):
    print(f"MISSING\t{missing}")
sys.exit(1 if wants else 0)
PY

run_sdk() {  # $1 = mode; fills SDK_OUT / SDK_RC
  SDK_OUT="$(SDK_MODE="$1" SDK_BASE="$PROBE_BASE" EXPECTED_TEXT="$EXPECTED_TEXT" \
    EXPECTED_TOOL="$EXPECTED_TOOL" EXPECTED_ARGS="$EXPECTED_ARGS" \
    EXPECTED_PROMPT_TOKENS="$EXPECTED_PROMPT_TOKENS" EXPECTED_GEN_TOKENS="$EXPECTED_GEN_TOKENS" \
    "$PY" "$RUNNER" 2>&1)"; SDK_RC=$?
}
assert_sdk() {  # $1 = check key
  if printf '%s\n' "$SDK_OUT" | grep -qF "OK	$1"; then
    probe_ok "openai-python round-trips $1 with the byte-exact value"
  else
    probe_fail "the SDK did not carry $1 — python said: $(printf '%s' "$SDK_OUT" | tr '\n' ' ' | head -c 220)" \
      " the compat promise breaks exactly here; compare against the script's literals in this file"
  fi
}

# ── boot 1: the tool-turn face ─────────────────────────────────────────────────────────────────
write_tool_script
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"
probe_boot

probe_section "§1 the tool-turn face, exactly as documented"
run_sdk tool
for want in tool-name tool-args content-blank finish-tool-calls prompt-tokens gen-tokens; do
  assert_sdk "$want"
done
assert_sdk stream-tool-name

# ── boot 2: the answer-turn face (same lane, script without calls) ────────────────────────────
kill -TERM "$PROBE_PID" 2>/dev/null || true
for _ in $(seq 1 40); do kill -0 "$PROBE_PID" 2>/dev/null || break; sleep 0.5; done
write_answer_script
probe_boot

probe_section "§2 the answer-turn face carries the text itself, non-stream and streamed"
run_sdk answer
assert_sdk answer-content
assert_sdk stream-rejoin
assert_sdk prompt-tokens

probe_summary "$PROBE_NAME"
