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
#   5. The ungently shape: an OPEN-ENDED prompt, temp 0, max_tokens 512, k=6 — does the
#      constrained document actually close? §1–§4 name their own keys in a 96-token budget,
#      which is the easiest form a grammar ever sees. coreai-models shipped a mask-level whitespace
#      cap for ITS version of this face (Gemma 4 E2B/E4B, runs to 99 chars), enforced on the mask
#      because compiling it expands a nested schema from 0.3 MiB to 1.2 GiB; our bridge leaves that
#      knob unset (Sources/lib/CXGrammar/xgrammar_c_bridge.cpp:138, max_whitespace_cnt = nullopt).
#      Measured 10-30 in §5b: the whitespace axis is CLOSED on this lane (max run 11 against Apple's
#      32, because the guided loop applies upstream's WhitespaceTokenBias at -200), and what still
#      fails is a 126-character repeat run. Document closure is therefore recorded as XFAIL while
#      open, XPASS (red) once it closes so a fix cannot pass silently, and §5b reddens if
#      whitespace ever does run past 32 here — that is the day #368 becomes ours to port.
#   6. The shape a client really sends: `response_format` + `tools[]` in ONE turn, k=3, against the
#      control of the same request with `tools` removed. This USED to deliver 0/3 on both shapes —
#      every turn ending `finish=tool_calls`, one of them a schema-valid but semantically absurd
#      `edit_file{oldString:"read_file",newString:"counts.txt"}` — because `buildGrammarSchema` let
#      the tool envelope win whenever tools were declared, so the caller's JSON was ungeneratable.
#      Precedence now follows the request (JSON unless tool_choice demands a call, mirroring sglang
#      serving_chat.py:1488-1501), measured 3/3 with tools on both shapes; the branch is probe_fail,
#      so a recurrence goes red rather than back to XFAIL.
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

# ── 5. open-ended turns: does the constrained document actually CLOSE? ────────
# Decidable, k=6, and reported honestly: an unparseable answer is a surface that said "JSON"
# and delivered bytes. finish_reason=length is spec-correct, so it is printed — but it is not
# a structured answer, and nothing else in this suite would notice.
probe_section "5 — open-ended json_object · temp 0 · max_tokens 512 · k=6 — the document must close"
OPEN_TOTAL=0
OPEN_BAD=0
OPEN_MAX_WS=0
OPEN_MAX_REP=0
OPEN_NOTES=""
for ask in "Tell me about the city you would most like to visit." \
           "Explain how a phone camera works and what makes a photo good."; do
  for round in 1 2 3; do
    s="$(fresh_session)"
    b="$(OPEN_MODEL="$PROBE_MODEL" OPEN_SESSION="$s" OPEN_PROMPT="$ask" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "model": os.environ["OPEN_MODEL"],
    "session_id": os.environ["OPEN_SESSION"],
    "temperature": 0,
    "max_tokens": 512,
    "response_format": {"type": "json_object"},
    "messages": [{"role": "user", "content": os.environ["OPEN_PROMPT"]}],
}))')"
    probe_chat "$s" "$b" || true
    verdict="$(OPEN_BODY="$PROBE_BODY" python3 -c '
import json, os, re, sys
d = json.loads(os.environ["OPEN_BODY"])
ch = (d.get("choices") or [{}])[0]
c = (ch.get("message") or {}).get("content") or ""
if isinstance(c, list):
    c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
fr = ch.get("finish_reason")
tok = (d.get("usage") or {}).get("completion_tokens")
ws = max([len(m) for m in re.findall(r"[ \t\n]+", c)] or [0])
rep = max([len(m.group(0)) for m in re.finditer(r"([^\s])\1{2,}", c)] or [0])
try:
    ok = isinstance(json.loads(c), dict)
except Exception:
    ok = False
sys.stdout.write("%s finish=%s completion=%s maxWSrun=%d maxRepeatRun=%d tail=%r"
                 % ("closed" if ok else "INVALID", fr, tok, ws, rep, c[-22:].replace("\n", "\\n")))
')"
    OPEN_TOTAL=$(( OPEN_TOTAL + 1 ))
    printf '  · ask=%.28s… %s\n' "$ask" "$verdict"
    ws="$(printf '%s' "$verdict" | sed -n 's/.*maxWSrun=\([0-9]*\).*/\1/p')"
    rep="$(printf '%s' "$verdict" | sed -n 's/.*maxRepeatRun=\([0-9]*\).*/\1/p')"
    if [ -n "$ws" ] && [ "$ws" -gt "$OPEN_MAX_WS" ]; then OPEN_MAX_WS="$ws"; fi
    if [ -n "$rep" ] && [ "$rep" -gt "$OPEN_MAX_REP" ]; then OPEN_MAX_REP="$rep"; fi
    case "$verdict" in
      INVALID*) OPEN_BAD=$(( OPEN_BAD + 1 )); OPEN_NOTES="$OPEN_NOTES; $verdict" ;;
    esac
  done
done
if [ "$OPEN_BAD" -gt 0 ]; then
  probe_xfail open "open-ended json_object: $OPEN_BAD/$OPEN_TOTAL turn(s) never closed the document — the face answers 200 with bytes no client can parse and the only tell is finish_reason (measured$OPEN_NOTES)"
else
  probe_xfail fixed "open-ended json_object closed $OPEN_TOTAL/$OPEN_TOTAL — promote §5 to probe_ok and delete this xfail"
fi

# §5b — the whitespace axis, measured instead of imported. coreai-models #368 caps whitespace
# between JSON tokens at 32 (ConstrainedGenerationSession.defaultMaxWhitespaceCount) because ITS
# Gemma 4 runs reached 99. This lane applies upstream's WhitespaceTokenBias (-200 on
# whitespace-only tokens, Engine/EngineInference.swift:2090), so the honest question is whether
# #368's cap would bind anything here. While this holds it binds nothing — and if a bridge bump or
# a new checkpoint lets a run pass 32, this is the red that re-opens the port with a number on it.
if [ "$OPEN_TOTAL" -lt 6 ]; then
  probe_fail "§5b ran $OPEN_TOTAL/6 open-ended turns — the premise is gone, so a whitespace verdict here would be vacuous"
elif [ "$OPEN_MAX_WS" -le 32 ]; then
  probe_ok "whitespace stays inside Apple's 32 on OUR lane (max run $OPEN_MAX_WS over $OPEN_TOTAL open-ended turns) — #368's mask cap would bind nothing here"
else
  probe_fail "whitespace ran to $OPEN_MAX_WS > 32 — coreai-models #368 applies to this lane now, port WhitespaceGuard (docs/agent/coreai-fork-adjudication.md)"
fi
probe_note "what §5 leaves open is repetition, not whitespace: maxRepeatRun=$OPEN_MAX_REP inside a 512-token budget"

# ── 6. response_format + tools[] in ONE turn — the shape a client actually sends ──
# §1–§5 pass without tools. The task scoreboard sends `tools` on EVERY turn
# (scripts/eval/_eval.py:173), and its three structured tasks measure 0/6 at k=6 — raw evidence
# from a retained run root, three different turns:
#   json-object-closes        finish=stop       completion_tokens=1    content=""            (1 token!)
#   json-schema-report        finish=tool_calls completion_tokens=107  content="" + tool_call
#   json-two-integers-closes  finish=tool_calls completion_tokens=89   content="" + tool_call
# …and the tool call it emitted for "read counts.txt" was `edit_file{oldString:"read_file",
# newString:"counts.txt", path:<the workspace dir>}` — schema-valid, semantically nonsense. So the
# question this section owns, decidable at the cheapest prompt that needs no workspace and no tool:
# can the answer channel and the tool channel both be satisfied in one turn? The control is the
# SAME request with `tools` removed, which makes tools the only variable.
probe_section "6 — response_format + tools[] · temp 0 · k=3 — the answer channel must survive the tool channel"
probe_api GET /v1/tools || true
WANTED="${OCOREAI_EVAL_TOOLS:-read_file write_file edit_file edit_lines search_files exec_command}"
TOOL_SPECS="$(PROBE_BODY="$PROBE_BODY" TOOL_WANTED="$WANTED" python3 -c '
import json, os, sys
d = json.loads(os.environ["PROBE_BODY"])
specs = d.get("data") or d.get("tools") or []
want = os.environ["TOOL_WANTED"].split()
keep = [s for s in specs if ((s.get("function") or {}).get("name") or s.get("name")) in want]
sys.stdout.write(json.dumps(keep or specs))
')"
TOOL_N="$(TOOL_SPECS="$TOOL_SPECS" python3 -c '
import json, os, sys
sys.stdout.write(str(len(json.loads(os.environ["TOOL_SPECS"]))))
')"
TOOL_N_ALL="$(PROBE_BODY="$PROBE_BODY" python3 -c '
import json, os, sys
d = json.loads(os.environ["PROBE_BODY"])
sys.stdout.write(str(len(d.get("data") or d.get("tools") or [])))
')"
probe_require_int "tool specs kept from GET /v1/tools" "$TOOL_N"
probe_require_int "tool specs declared by the server" "$TOOL_N_ALL"
if [ -z "$TOOL_SPECS" ] || [ "$TOOL_N" -lt 1 ]; then
  probe_fail "§6 could not read a tool spec from /v1/tools — the section's own premise is missing, so it cannot isolate the tool channel"
else
  probe_note "§6 sends $TOOL_N tool spec(s) read from GET /v1/tools, the way scripts/eval/_eval.py does"
  SIX_ASK='Reply as JSON with exactly two keys: n, the integer 2 + 3, and w, the word ok. No tool is needed.'
  # Which half is at fault? The same ask with tools declared and NO response_format: if the answer
  # still arrives, tools alone do not silence the model — the pinned grammar plus tools does.
  PLAIN_OK=0
  PLAIN_NOTES=""
  for round in 1 2 3; do
    s="$(fresh_session)"
    b="$(OPEN_MODEL="$PROBE_MODEL" OPEN_SESSION="$s" OPEN_ASK="$SIX_ASK" OPEN_TOOLS="$TOOL_SPECS" python3 -c '
import json, os, sys
body = {
    "model": os.environ["OPEN_MODEL"],
    "session_id": os.environ["OPEN_SESSION"],
    "temperature": 0,
    "max_tokens": 64,
    "messages": [{"role": "user", "content": os.environ["OPEN_ASK"]}],
    "tools": json.loads(os.environ["OPEN_TOOLS"]),
}
sys.stdout.write(json.dumps(body))
')"
    probe_chat "$s" "$b" || true
    v="$(OPEN_BODY="$PROBE_BODY" python3 -c '
import json, os, sys
d = json.loads(os.environ["OPEN_BODY"])
ch = (d.get("choices") or [{}])[0]
msg = ch.get("message") or {}
c = msg.get("content")
c = "" if c is None else (" ".join(b.get("text", "") for b in c if isinstance(b, dict)) if isinstance(c, list) else c)
tc = msg.get("tool_calls") or []
ok = ("5" in c) and ("ok" in c.lower())
sys.stdout.write("%s finish=%s completion=%s tool_calls=%d tail=%r"
                 % ("answered" if ok else "NO_ANSWER", ch.get("finish_reason"),
                    (d.get("usage") or {}).get("completion_tokens"), len(tc), c[-18:].replace("\n", "\\n")))
')"
    printf '  · plain (no response_format) + tools round %s: %s\n' "$round" "$v"
    case "$v" in
      answered*) PLAIN_OK=$((PLAIN_OK + 1)) ;;
      *) PLAIN_NOTES="$PLAIN_NOTES; $v" ;;
    esac
  done
  probe_note "control — same ask, tools declared, response_format ABSENT: answered $PLAIN_OK/3, so tools alone $([ "$PLAIN_OK" -eq 3 ] && printf 'do not silence the answer — the grammar is what breaks when tools are present' || printf 'already cost the answer without any grammar, so the checkpoint is tool-happy first')$PLAIN_NOTES"
  for shape in json_object json_schema; do
    case "$shape" in
      json_object) RF='"response_format":{"type":"json_object"}' ;;
      json_schema) RF='"response_format":{"type":"json_schema","json_schema":{"name":"twokeys","schema":{"type":"object","properties":{"n":{"type":"integer"},"w":{"type":"string"}},"required":["n","w"],"additionalProperties":false}}}' ;;
    esac
    CTRL_OK=0; TOOLS_OK=0; CTRL_NOTES=""; TOOLS_NOTES=""
    for mode in notools tools; do
      for round in 1 2 3; do
        s="$(fresh_session)"
        b="$(OPEN_MODEL="$PROBE_MODEL" OPEN_SESSION="$s" OPEN_ASK="$SIX_ASK" OPEN_RF="$RF" OPEN_MODE="$mode" OPEN_TOOLS="$TOOL_SPECS" python3 -c '
import json, os, sys
body = {
    "model": os.environ["OPEN_MODEL"],
    "session_id": os.environ["OPEN_SESSION"],
    "temperature": 0,
    "max_tokens": 128,
    "messages": [{"role": "user", "content": os.environ["OPEN_ASK"]}],
}
if os.environ["OPEN_RF"] == "json_object":
    body["response_format"] = {"type": "json_object"}
else:
    body["response_format"] = {"type": "json_schema", "json_schema": {"name": "twokeys",
        "schema": {"type": "object", "properties": {"n": {"type": "integer"}, "w": {"type": "string"}},
                  "required": ["n", "w"], "additionalProperties": False}}}
if os.environ["OPEN_MODE"] == "tools":
    body["tools"] = json.loads(os.environ["OPEN_TOOLS"])
sys.stdout.write(json.dumps(body))
')"
        probe_chat "$s" "$b" || true
        v="$(OPEN_BODY="$PROBE_BODY" python3 -c '
import json, os, sys
d = json.loads(os.environ["OPEN_BODY"])
ch = (d.get("choices") or [{}])[0]
msg = ch.get("message") or {}
c = msg.get("content")
c = "" if c is None else (" ".join(b.get("text", "") for b in c if isinstance(b, dict)) if isinstance(c, list) else c)
tc = msg.get("tool_calls") or []
fr = ch.get("finish_reason")
tok = (d.get("usage") or {}).get("completion_tokens")
ok = False
try:
    p = json.loads(c)
    ok = isinstance(p, dict) and "n" in p and "w" in p
except Exception:
    ok = False
sys.stdout.write("%s finish=%s completion=%s tool_calls=%d tail=%r"
                 % ("answered" if ok else "NO_JSON", fr, tok, len(tc), c[-18:].replace("\n", "\\n")))
')"
        printf '  · %s %s round %s: %s\n' "$shape" "$mode" "$round" "$v"
        case "$v" in
          answered*) if [ "$mode" = notools ]; then CTRL_OK=$((CTRL_OK+1)); else TOOLS_OK=$((TOOLS_OK+1)); fi ;;
          *) if [ "$mode" = notools ]; then CTRL_NOTES="$CTRL_NOTES; $v"; else TOOLS_NOTES="$TOOLS_NOTES; $v"; fi ;;
        esac
      done
    done
    if [ "$CTRL_OK" -ne 3 ]; then
      probe_fail "$shape without tools delivered $CTRL_OK/3 — §1's premise is gone, so §6 cannot blame the tool channel for anything ($CTRL_NOTES)"
    elif [ "$TOOLS_OK" -eq 3 ]; then
      probe_ok "$shape + tools: 3/3 closed with the declared keys — the answer channel survived the tool channel on this shape"
    else
      # The caller's JSON wins the turn when tools are declared but `tool_choice` does not
      # demand a call: `shouldConstrainOutput` (Models/OpenAIModels.swift:2273) returns true on
      # the JSON shape alone, and `buildGrammarSchema` then compiles the CALLER's schema, not the
      # tool envelope — so the answer arrives clean while the tool channel is ungeneratable for
      # that turn. Every grammar that picks a side loses the other channel; measured four ways
      # in CHANGELOG 10-24(1) and again in §7. A recurrence here means the keys stopped arriving
      # with the tools still declared.
      probe_fail "$shape + tools: only $TOOLS_OK/3 turns delivered the declared keys while the identical prompt WITHOUT tools delivered 3/3 — the answer channel lost to the tool channel again, and the wire reports 200 for it (measured$TOOLS_NOTES)"
    fi
  done
fi


# ── 7 — grounded JSON · temp 0 · k=3 — the shape must not arrive without the facts ────
# §6 proves the answer channel survives; it cannot prove the answer is TRUE. Measured 10-24:
# while the request's JSON outranked the tool envelope, `json-two-integers-closes` delivered
# {"cols":5,"rows":10} for a file reading "shape 3 by 5" — schema-valid JSON, finish=stop,
# HTTP 200, `prompt=986 completion=16 echoed_tool_calls=0`, i.e. `read_file` could not be
# emitted at all and the numbers were invented. A confident lie delivered as 200 is worse
# than a lost answer, so this section asks for both channels in one turn and judges the
# VALUES: the file's path is in the prompt, its numbers are not, so a correct answer is only
# reachable by reading.
probe_section "7 — json + tools on a turn that must read · temp 0 · k=3 — the keys must carry the file's numbers"
GROUND_DIR="$(mktemp -d -t oc-probe12-grounded-XXXXXX)"
printf 'shape 47 by 13\n' > "$GROUND_DIR/grid.txt"
SEVEN_OK=0
SEVEN_NOTES=""
for round in 1 2 3; do
  s="$(fresh_session)"
  b="$(OPEN_MODEL="$PROBE_MODEL" OPEN_SESSION="$s" OPEN_TOOLS="$TOOL_SPECS" OPEN_PATH="$GROUND_DIR/grid.txt" python3 -c '
import json, os, sys
body = {
    "model": os.environ["OPEN_MODEL"],
    "session_id": os.environ["OPEN_SESSION"],
    "temperature": 0,
    "max_tokens": 192,
    "messages": [{"role": "user", "content":
        "Read %s and reply as JSON with exactly two integer keys: rows and cols, "
        "the two numbers the file states after \"shape\"." % os.environ["OPEN_PATH"]}],
    "tools": json.loads(os.environ["OPEN_TOOLS"]),
    "response_format": {"type": "json_schema", "json_schema": {"name": "grid",
        "schema": {"type": "object",
                  "properties": {"rows": {"type": "integer"}, "cols": {"type": "integer"}},
                  "required": ["rows", "cols"], "additionalProperties": False}}},
}
sys.stdout.write(json.dumps(body))
')"
  probe_chat "$s" "$b" || true
  v="$(OPEN_BODY="$PROBE_BODY" python3 -c '
import json, os, sys
d = json.loads(os.environ["OPEN_BODY"])
ch = (d.get("choices") or [{}])[0]
msg = ch.get("message") or {}
c = msg.get("content")
c = "" if c is None else (" ".join(b.get("text", "") for b in c if isinstance(b, dict)) if isinstance(c, list) else c)
tc = msg.get("tool_calls") or []
u = d.get("usage") or {}
want = {"rows": 47, "cols": 13}
got = None
try:
    p = json.loads(c)
    if isinstance(p, dict):
        got = {k: p.get(k) for k in want}
except Exception:
    got = None
verdict = "GROUNDED" if got == want else ("WRONG_VALUES" if got else "NO_JSON")
sys.stdout.write("%s finish=%s completion=%s prompt=%s tool_calls=%d keys=%r content=%r"
                 % (verdict, ch.get("finish_reason"), u.get("completion_tokens"),
                    u.get("prompt_tokens"), len(tc), got, c[:60].replace(chr(10), "\\n")))
for call in tc:
    fn = (call.get("function") or {}).get("name")
    sys.stdout.write(" call=%s" % fn)
')"
  printf '  · round %s: %s\n' "$round" "$v"
  case "$v" in
    GROUNDED*) SEVEN_OK=$((SEVEN_OK+1)) ;;
    *) SEVEN_NOTES="$SEVEN_NOTES; $v" ;;
  esac
done
  # Which channel does what, measured on the same prompt: envelope-only shows whether the
  # model would have read the file at all; json-only shows the 10-24 defect (shape without
  # facts). Both are notes, not gates — §7's gate is the union, because that is the only
  # shape the caller asked for.
  for ctrl in envelope_only json_only; do
    cv=""
    for round in 1 2 3; do
      s="$(fresh_session)"
      cb="$(OPEN_MODEL="$PROBE_MODEL" OPEN_SESSION="$s" OPEN_TOOLS="$TOOL_SPECS" OPEN_PATH="$GROUND_DIR/grid.txt" OPEN_CTRL="$ctrl" python3 -c '
import json, os, sys
ask = ("Read %s and reply as JSON with exactly two integer keys: rows and cols, "
       "the two numbers the file states after \"shape\"." % os.environ["OPEN_PATH"])
body = {"model": os.environ["OPEN_MODEL"], "session_id": os.environ["OPEN_SESSION"],
        "temperature": 0, "max_tokens": 192,
        "messages": [{"role": "user", "content": ask}]}
ctrl = os.environ["OPEN_CTRL"]
if ctrl == "envelope_only":
    body["tools"] = json.loads(os.environ["OPEN_TOOLS"])
    body["tool_choice"] = "required"
else:
    body["response_format"] = {"type": "json_schema", "json_schema": {"name": "grid",
        "schema": {"type": "object",
                  "properties": {"rows": {"type": "integer"}, "cols": {"type": "integer"}},
                  "required": ["rows", "cols"], "additionalProperties": False}}}
sys.stdout.write(json.dumps(body))
')"
      probe_chat "$s" "$cb" || true
      one="$(OPEN_BODY="$PROBE_BODY" python3 -c '
import json, os, sys
d = json.loads(os.environ["OPEN_BODY"])
ch = (d.get("choices") or [{}])[0]
msg = ch.get("message") or {}
c = msg.get("content")
c = "" if c is None else (" ".join(b.get("text", "") for b in c if isinstance(b, dict)) if isinstance(c, list) else c)
tc = msg.get("tool_calls") or []
names = ",".join(((t.get("function") or {}).get("name") or "?") for t in tc)
truth = all(x in c for x in ("3", "5"))
sys.stdout.write("finish=%s completion=%s tool_calls=%d carried_the_numbers=%s names=%s content=%r"
                 % (ch.get("finish_reason"), (d.get("usage") or {}).get("completion_tokens"),
                    len(tc), truth, names or "-", c[:48].replace(chr(10), "\\n")))
')"
      cv="$cv; $one"
    done
    probe_note "§7 control $ctrl (3 rounds):$cv"
  done

if [ "$SEVEN_OK" -eq 3 ]; then
  probe_xfail fixed "json + tools on a read-turn grounded 3/3 (rows=47, cols=13) — promote §7 to probe_ok: the loop can now answer a JSON shape it had to work for"
else
  probe_xfail open "json + tools on a read-turn: $SEVEN_OK/3 carried the file's numbers — a response_format grammar forbids the call the integers come from, so the face returns 200 with schema-valid JSON that was never grounded ($SEVEN_NOTES)"
fi

probe_summary "$PROBE_NAME"
