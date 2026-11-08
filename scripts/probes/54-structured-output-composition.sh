#!/usr/bin/env bash
# 54-structured-output-composition.sh — the disclosed composition limit, proved live.
#
# ### Why (AGENTS.md invariant 2: the surface never claims more than the engine delivered)
# A request carrying BOTH `tools[]` and `response_format` is answered as a single-pass
# constrained turn: the answer grammar wins (OpenAIModels.swift, "the JSON wins") and the turn
# cannot emit a tool call first, so a task that must read a file before answering can only
# fabricate. This measured pair — the board's structured tasks fabricated plausible JSON on
# both arms 11-08 (`OLTREZvTTx`/`B3mcwWEGT8`, 3 tasks, temp 0, deterministic) — was invisible
# to the caller: a 200, valid schema, invented values. The row now lives in the tier matrix
# (`RuntimeCapability`, "structured_output"); this probe pins that (a) a client reads the
# limit BEFORE its first request and (b) the live turn matches the disclosure: schema-valid
# JSON, no tool-calls channel, and the file's real value absent from the answer.
#
# sglang treats the pair the same way (python/sglang/srt/entrypoints/openai/serving_chat.py:
# 1130 — the tool-call parser is switched off for a JSON response_format), so the limit is
# stated, not hidden: field-compatible behaviour, honestly disclosed.
#
# ### What is asserted
#   1. /v1/capabilities carries the `structured_output` row, available, with the exact
#      limit markers in its note ("single-pass", "cannot run first").
#   2. Live combination: file + tools + json_schema → 200 whose message is schema-valid JSON
#      with NO tool_calls, and whose integers do not match the file it never read (the
#      fabrication the disclosure now warns about; the values may coincide only if the model
#      guessed, and both distinctive numbers hitting by luck is treated as a finding, not a flake).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="structured-output-composition"

probe_boot
probe_require_ready_model

auth_args=()
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi

probe_section "1. the limit is readable before the first request"
caps="$(curl -sS -m 20 "${auth_args[@]+"${auth_args[@]}"}" "$PROBE_BASE/v1/capabilities")"
row="$(printf %s "$caps" | python3 -I -c '
import json,sys
rows = json.load(sys.stdin).get("capabilities") or []
hit = [r for r in rows if r.get("name") == "structured_output"]
if not hit:
    print("absent"); raise SystemExit
r = hit[0]
note = r.get("note", "")
ok = r.get("available") is True and "single-pass" in note and "cannot run first" in note
print("disclosed" if ok else "row-present-but-silent:" + note)
')"
if [ "$row" = "disclosed" ]; then
  probe_ok "structured_output row is available and names its composition limit"
else
  probe_fail "/v1/capabilities does not disclose the limit: $row"
fi

probe_section "2. the live turn matches the disclosure"
ws="$(mktemp -d -t ocoreai-probe54-XXXXXX)"
# `probe_atexit`, not a raw `trap … EXIT`: bash keeps one handler per signal and a raw trap here
# would silently replace `probes_cleanup`, leaving the probe's own serve on the instance lock —
# the class ProbeHarnessHygieneTests exists to catch, and caught this file for, 11-08.
probe_atexit 'rm -rf "$ws"'
# Distinctive values: a model that never reads grid.txt has no route to 4477/9013.
printf 'shape 4477 by 9013\n' > "$ws/grid.txt"
body="$(python3 -I -c '
import json, sys
schema = {"type": "object", "properties": {"rows": {"type": "integer"}, "cols": {"type": "integer"}},
          "required": ["rows", "cols"], "additionalProperties": False}
body = {
    "model": sys.argv[2],
    "session_id": "probe54-combination",
    "messages": [{"role": "user", "content":
        "Read grid.txt in the workspace (absolute path: " + sys.argv[1] + "). "
        "Answer as JSON with the two integers it states: rows and cols. "
        "Use the tools to read the file, then reply with only the JSON object."}],
    "max_tokens": 160,
    "temperature": 0,
    "tools": [{"type": "function", "function": {
        "name": "read_file",
        "description": "Read a text file from the workspace.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}},
                       "required": ["path"]}}}],
    "response_format": {"type": "json_schema", "json_schema": {"name": "grid", "schema": schema}},
}
print(json.dumps(body))
' "$ws" "$PROBE_MODEL")"
resp="$(curl -sS -m 240 "${auth_args[@]+"${auth_args[@]}"}" -H 'Content-Type: application/json' \
  -d "$body" "$PROBE_BASE/v1/chat/completions")"
verdict="$(printf %s "$resp" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
choice = (d.get("choices") or [{}])[0]
msg = choice.get("message") or {}
calls = msg.get("tool_calls") or []
content = msg.get("content") or ""
try:
    obj = json.loads(content)
except Exception:
    print("not-schema-json:" + content[:80]); raise SystemExit
ok_shape = (not calls) and isinstance(obj, dict) and set(obj) >= {"rows", "cols"} \
    and isinstance(obj["rows"], int) and isinstance(obj["cols"], int)
if not ok_shape:
    print("shape:" + content[:80] + " calls=" + str(len(calls))); raise SystemExit
grounded = obj["rows"] == 4477 and obj["cols"] == 9013
print("single-pass-fabricated" if not grounded else "grounded-despite-disclosure")
')"
if [ "$verdict" = "single-pass-fabricated" ]; then
  probe_ok "combination turn: schema-valid, no tool_calls, file's values absent — matches the disclosure"
elif [ "$verdict" = "grounded-despite-disclosure" ]; then
  probe_fail "the turn read the file after all — the disclosed limit is now WRONG (engine changed? " \
             "re-read OpenAIModels buildGrammarSchema and restate the row's note)"
else
  probe_fail "combination turn did not behave as disclosed: $verdict"
fi

probe_summary "$PROBE_NAME"
