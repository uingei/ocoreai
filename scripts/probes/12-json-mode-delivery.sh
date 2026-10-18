#!/usr/bin/env bash
# 12-json-mode-delivery.sh — does response_format deliver JSON with something inside it?
#
# ### Why (invariant 2: the surface may not claim more than the engine delivered)
# `response_format:{"type":"json_object"}` is how an OpenAI client says "answer in JSON".
# It carries no schema — the spec says so — so whatever this server constrains with comes
# from OUR fallback, and ours was `{"type":"object","properties":{}}`. Naming zero
# properties tells the grammar that no key is legal, so the only thing the model may emit
# is the empty object. Measured on this host, temperature 0, a prompt naming two keys:
#   json_object        -> content = '{}'                          completion_tokens = 2
#   json_schema {"type":"object"}                      -> content = '{"answer": 8, "unit": "planets"}'  = 20
#   json_schema {"type":"object","properties":{}}      -> content = '{}'                          = 2
# Valid JSON, no information, 200 OK, finish_reason "stop", and nothing said so. vllm and
# sglang both map this mode to `{"type":"object"}` (vllm/parser/abstract_parser.py:277,
# sglang/srt/entrypoints/openai/protocol.py:1191) — no properties key at all.
#
# ### What is measured
#   1. json_object must come back parseable as a JSON object (we said we constrained it).
#   2. json_object must AGREE with `json_schema{"type":"object"}` — that equivalence is
#      the whole upstream mapping, so it is the assertion this server owns. It is used
#      instead of "keys > 0" because the smallest legal open object IS `{}`: asserting a
#      checkpoint fills it would make this probe red for someone else's fact.
#   3. A real schema (required keys) must deliver those keys — the grammar still does its
#      actual job after §2 made the open case open.
#   4. Control, and the premise of the fix: a CALLER that pins zero properties must still
#      get `{}`. If this stops being true, the fix was achieved by weakening grammars
#      everywhere, and §2's pass would be worth nothing.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 12`).
# Run: bash scripts/probes/12-json-mode-delivery.sh
PROBE_NAME="12-json-mode-delivery"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SESSION_SEQ=0
fresh_session() {
  SESSION_SEQ=$(( SESSION_SEQ + 1 ))
  printf 'probe12-%s-%s' "$$" "$SESSION_SEQ"
}

ASK='Reply as JSON with two keys: answer, whose value is the number of planets in our solar system as an integer, and unit, whose value is the word planets.'

# ask_json <response_format fragment> <label> — sends one turn, sets JSON_KEYS/CONTENT/FINISH.
# JSON_KEYS is a key count, or PARSE_FAIL / NOT_OBJECT.
ask_json() {
  local rf="$1" lab="$2" s b
  s="$(fresh_session)"
  b='{"model":"'"$PROBE_MODEL"'","session_id":"'"$s"'","temperature":0,"max_tokens":96,"messages":[{"role":"user","content":"'"$ASK"'"}],'"$rf"'}'
  probe_chat "$s" "$b" || true
  printf -- '-- %s\n' "$lab"
  JSON_CONTENT="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  JSON_FINISH="$(probe_json "$PROBE_BODY" 'choices.0.finish_reason')"
  JSON_COMPLETION="$(probe_json "$PROBE_BODY" 'usage.completion_tokens')"
  JSON_KEYS="$(printf '%s' "$JSON_CONTENT" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write("PARSE_FAIL")
    raise SystemExit(0)
sys.stdout.write(str(len(d)) if isinstance(d, dict) else "NOT_OBJECT")')"
  printf '   finish=%s keys=%s completion=%s content=%s\n' \
    "$JSON_FINISH" "${JSON_KEYS:-?}" "${JSON_COMPLETION:-?}" "$(printf %.70s "$JSON_CONTENT")"
}

# The probe owns its server: without these two lines PROBE_MODEL is empty and every
# request fails against nothing, which would read as "the server answered prose".
probe_boot
probe_require_ready_model

# ── 1. json_object must be JSON, as the request promised ─────────────────────
probe_section "1 — json_object delivers a JSON object"
ask_json '"response_format":{"type":"json_object"}' "json_object, no schema (what an OpenAI client sends)"
if [ "$JSON_KEYS" = "PARSE_FAIL" ] || [ "$JSON_KEYS" = "NOT_OBJECT" ] || [ -z "$JSON_KEYS" ]; then
  probe_fail "response_format json_object answered with something that is not a JSON object (content='$(printf %.70s "$JSON_CONTENT")') — the client asked for JSON and got prose"
else
  probe_ok "json_object delivers a parseable JSON object ($JSON_KEYS key(s))"
fi

# ── 2. json_object must equal upstream's mapping, not a pinned empty object ──
probe_section "2 — json_object must behave as {\"type\":\"object\"}, which is what vllm/sglang map it to"
ask_json '"response_format":{"type":"json_schema","json_schema":{"name":"open","schema":{"type":"object"}}}' \
  "json_schema {\"type\":\"object\"} — the upstream mapping for json_object"
OPEN_KEYS="$JSON_KEYS"
OPEN_CONTENT="$JSON_CONTENT"
if [ "$OPEN_KEYS" = "PARSE_FAIL" ] || [ "$OPEN_KEYS" = "NOT_OBJECT" ] || [ -z "$OPEN_KEYS" ]; then
  probe_fail "the open-object control itself did not deliver JSON (keys=${OPEN_KEYS:-?}) — §2 cannot judge anything until the grammar path works"
elif [ "$JSON_KEYS" = "0" ] && [ "$OPEN_KEYS" != "0" ]; then
  probe_fail "json_object answered '{}' while the identical turn with {\"type\":\"object\"} answered '$(printf %.60s "$OPEN_CONTENT")' — json_object is being pinned to zero keys again, which is the defect this probe exists for"
else
  probe_ok "json_object and the open object agree (keys $JSON_KEYS vs $OPEN_KEYS)"
  if [ "$JSON_KEYS" = "0" ] && [ "$OPEN_KEYS" = "0" ]; then
    probe_note "both open shapes answered '{}' on this checkpoint — legal for an open grammar, so recorded rather than asserted; the zero-key collapse is caught by §4's control plus GrammarSchemaRegressionTests"
  fi
fi

# ── 3. a real schema still gets its keys ─────────────────────────────────────
probe_section "3 — a declared schema delivers its declared keys"
ask_json '"response_format":{"type":"json_schema","json_schema":{"name":"planets","strict":true,"schema":{"type":"object","properties":{"answer":{"type":"integer"},"unit":{"type":"string"}},"required":["answer","unit"]}}}' \
  'json_schema {answer:integer, unit:string}'
if [ "$JSON_KEYS" = "PARSE_FAIL" ] || [ "$JSON_KEYS" = "NOT_OBJECT" ]; then
  probe_fail "a required-key schema produced no parseable object (content='$(printf %.70s "$JSON_CONTENT")')"
else
  HAS_KEYS="$(printf '%s' "$JSON_CONTENT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.stdout.write("no"); raise SystemExit(0)
sys.stdout.write("yes" if isinstance(d, dict) and "answer" in d and "unit" in d else "no")')"
  if [ "$HAS_KEYS" = "yes" ]; then
    probe_ok "declared keys answer+unit both arrived — structured output is delivered, not just accepted"
  else
    probe_fail "declared keys answer+unit did not both arrive (keys=$JSON_KEYS content='$(printf %.70s "$JSON_CONTENT")') — the schema was accepted and then ignored"
  fi
fi

# ── 4. control: the caller's OWN zero-key pin must still mean zero keys ─────
probe_section "4 — control: a caller that pins zero properties still gets {} (the fix was not grammar-weakening)"
ask_json '"response_format":{"type":"json_schema","json_schema":{"name":"pinned","schema":{"type":"object","properties":{}}}}' \
  'json_schema {"type":"object","properties":{}} — caller-declared zero keys'
if [ "$JSON_KEYS" = "0" ]; then
  probe_ok "the grammar still distinguishes a caller-pinned empty object (keys=0 as the caller asked)"
else
  probe_fail "caller-pinned zero properties returned $JSON_KEYS key(s) — this server no longer honours what the caller declared, so §2's pass is not trustworthy"
fi

probe_summary "$PROBE_NAME"
