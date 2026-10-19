#!/usr/bin/env bash
# 14-parallel-and-terminal-word.sh — the three promises a tool-call turn makes about itself.
#
# ### Why (AGENTS.md invariant 2, and the family "a knob the wire accepts must reach the
# engine — behaviour ends, and the word is right")
# An agent loop lives on three facts the server states about every tool turn: how many calls
# it may run at once, whether the turn finished or the budget cut it, and which chunk is the
# last. All three were being asserted on the wire without being delivered by the engine, and
# 2688 tests stayed green because every one of them spoke about another request. Measured
# 10-19 on this host (`mlx-community/gemma-4-e2b-it-4bit`, temp 0):
#
#   parallel_tool_calls:false  -> 2 tool_calls (Paris + London)      both faces, decoded, unread
#   max_tokens:18             -> completion_tokens:18, finish "tool_calls"  (a cut, called clean)
#   SSE                       -> the tool_calls delta said finish_reason:"tool_calls",
#                               then the terminal chunk said "stop" — so the streaming face
#                               denied the calls the JSON face admitted, and a client that
#                               stops reading at the first non-null finish_reason never sees
#                               the answer that follows the call.
#   tool_choice (OpenAI shape {"type":"function","function":{"name":…}})
#                            -> 400 {"error":{"message":"Coding key `name` not found."}}
#                               while this server's invented flat alias worked, and "banana"
#                               answered 200.
#
# vllm keeps all of it in one module (`maybe_filter_parallel_tool_calls` +
# `resolve_finish_reason`, vllm/entrypoints/serve/utils/tool_calls_utils.py:24-65); sglang
# upgrades the word only "if we had tool calls **and stopped naturally**"
# (serving_chat.py:2149-2152). The home here is Sources/ocoreai/Models/ToolCallWire.swift;
# the unit gate is Tests/ocoreaiTests/ToolCallWireContractTests.swift.
#
# ### What is measured
#   1. `parallel_tool_calls:false` delivers at most one call, and the first one is the
#      model's own first — with the unrestricted turn as the differential control.
#   2. The same promise on `/v1/messages`, spelled `tool_choice.disable_parallel_tool_use`.
#   3. A turn the budget cut says `length`, even when it delivered a call; a turn that
#      completed and called says `tool_calls`; the no-tools truncation control says `length`.
#   4. SSE: exactly one chunk carries a non-null finish_reason, it is the terminal one, the
#      tool_calls delta carries null, and `[DONE]` closes the stream.
#   5. Anthropic's stop_reason tracks what was delivered (`tool_use` iff a block arrived).
#   6. `tool_choice`: OpenAI's nested named-tool shape works (no leaked `Coding key`), the
#      flat alias still works, an unknown word and a choice with no `tools[]` come back 400
#      naming `tool_choice` with `type:"invalid_request_error"`.
#   7. A turn obeys its OWN `max_tokens` even when the turn before it on the same session
#      was grammar- or tool-constrained (measured 10-19 as asked-8-spent-64; see §7).
#
# Bodies are single-quoted JSON with "$VAR" splices (macOS bash 3.2 mis-parses nested
# quoted command substitution — see probe 09), and every compared turn gets its own session
# so a growing history cannot change the outcome on its own. §7 is the deliberate exception:
# its whole subject is what one turn leaves behind for the next turn on the same session.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 14`).
#
# Run: bash scripts/probes/14-parallel-and-terminal-word.sh
PROBE_NAME="14-parallel-and-terminal-word"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

WEATHER_TOOLS=',"tools":[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}}]'
# The Anthropic face spells the declaration `input_schema`, and both fragments carry their
# own leading comma — every body below splices one of them straight after `]`.
ANTH_TOOLS=',"tools":[{"name":"get_weather","description":"Get the current weather for a city","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]'
ASK_TWO="Call the get_weather tool twice: once for Paris and once for London. Do not answer, only call the tool."
ASK_ONE="Use the get_weather tool to check the weather in Paris."
LONG_ANSWER="Explain in detail how a gas turbine engine works, in five long paragraphs."

# fresh_session — a session id unique per CALL.
#
# `SESSION_SEQ=$(( SESSION_SEQ + 1 ))` inside this function does not survive the call site
# `s="$(fresh_session)"`: the increment happens in the command-substitution subshell and the
# parent never sees it, so every "fresh" session in the run was ONE session. §1's control,
# §3's cut and the no-tools control shared a transcript, and the numbers compared were not
# comparable — that is what made §3 read as "max_tokens ignored" (max=25 → 28 tokens,
# max=20 → 220 tokens) on 10-19 while a unique-session replay of the same bodies honoured
# every budget (25/length, 20/length). The counter therefore lives in a file, and §7 keeps
# the one leak the shared session did expose in plain sight.
SESSION_SEQ_FILE="$(mktemp -t ocoreai-probe14-seq-XXXXXX)"
probe_atexit "rm -f '$SESSION_SEQ_FILE'"
fresh_session() {
  local n
  n=$(( $(cat "$SESSION_SEQ_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$SESSION_SEQ_FILE"
  printf 'probe14-%s-%s' "$$" "$n"
}

STATUS=""
BODY=""
FINISH=""
COMPLETION=""
N_CALLS=""
CITIES=""

# count_calls — number of tool_calls in the last chat body, or NOJSON.
count_calls() {
  printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.stdout.write("NOJSON"); raise SystemExit(0)
calls = (d.get("choices") or [{}])[0].get("message", {}).get("tool_calls") or []
sys.stdout.write(str(len(calls)))'
}

# cities_in_calls — the arguments delivered, so "the FIRST call" is an observation.
cities_in_calls() {
  printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.stdout.write("?"); raise SystemExit(0)
calls = (d.get("choices") or [{}])[0].get("message", {}).get("tool_calls") or []
out = []
for c in calls:
    fn = c.get("function", {})
    try:
        arg = json.loads(fn.get("arguments") or "{}")
    except Exception:
        arg = {}
    out.append("%s:%s" % (fn.get("name", "?"), arg.get("city", "?")))
sys.stdout.write(",".join(out) if out else "-")'
}

# budget_class MAX COMPLETION -> over | at | under | unknown.
# The terminal word must follow the *measured* relation between what the client asked for
# and what came back, so no checkpoint's token counts get baked into an assertion.
# `over` is never a wording question: completion_tokens > max_tokens means the budget
# never reached generation, so no terminal word for that turn can be trusted.
budget_class() {
  printf '%s %s' "$1" "$2" | python3 -c '
import sys
raw = sys.stdin.read().split()
if len(raw) != 2:
    print("unknown"); raise SystemExit(0)
try:
    mx, done = int(raw[0]), int(raw[1])
except ValueError:
    print("unknown"); raise SystemExit(0)
print("over" if done > mx else ("at" if done == mx else "under"))'
}

# ask_chat_in SESSION EXTRA_JSON MAX_TOKENS PROMPT — one non-streaming turn on a session the
# caller keeps, so a probe can hold one conversation open across turns.
ask_chat_in() {
  local s="$1" b
  b='{"model":"'"$PROBE_MODEL"'","session_id":"'"$s"'","temperature":0,"max_tokens":'"$3"',"messages":[{"role":"user","content":"'"$4"'"}]'"$2"'}'
  probe_chat "$s" "$b" || true
  STATUS="$PROBE_STATUS"
  BODY="$PROBE_BODY"
  FINISH="$(probe_json "$BODY" 'choices.0.finish_reason')"
  COMPLETION="$(probe_json "$BODY" 'usage.completion_tokens')"
  N_CALLS="$(count_calls)"
  CITIES="$(cities_in_calls)"
}

# ask_chat EXTRA_JSON MAX_TOKENS PROMPT — the same turn, on its own fresh session.
ask_chat() {
  ask_chat_in "$(fresh_session)" "$1" "$2" "$3"
}

# ask_anthropic EXTRA_JSON MAX_TOKENS PROMPT — one /v1/messages turn.
N_BLOCKS=""
STOP=""
ANTH_OUT=""
ask_anthropic() {
  local s b
  s="$(fresh_session)"
  b='{"model":"'"$PROBE_MODEL"'","max_tokens":'"$2"',"temperature":0,"messages":[{"role":"user","content":"'"$3"'"}]'"$1"'}'
  probe_api POST /v1/messages "$b" || true
  STATUS="$PROBE_STATUS"
  BODY="$PROBE_BODY"
  STOP="$(probe_json "$BODY" 'stop_reason')"
  ANTH_OUT="$(probe_json "$BODY" 'usage.output_tokens')"
  N_BLOCKS="$(printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.stdout.write("NOJSON"); raise SystemExit(0)
sys.stdout.write(str(len([b for b in d.get("content", []) if b.get("type") == "tool_use"])))')"
}

probe_boot
probe_require_ready_model

# ── 1. parallel_tool_calls:false must mean one call ─────────────────────────
probe_section "1 — parallel_tool_calls:false delivers one call, not the model's whole list"
ask_chat "$WEATHER_TOOLS" 220 "$ASK_TWO"
if [ "$STATUS" != "200" ]; then
  probe_fail "unrestricted control turn answered $STATUS — $(printf %.200s "$BODY")"
  probe_note "sections 1 and 2 cannot judge parallelism without a control turn that calls"
else
  DEFAULT_CALLS="$N_CALLS"
  DEFAULT_CITIES="$CITIES"
  probe_note "unrestricted turn: finish=$FINISH calls=$DEFAULT_CALLS $DEFAULT_CITIES"
  if [ "$DEFAULT_CALLS" = "0" ]; then
    probe_fail "the checkpoint delivered no tool call at all on the unrestricted turn — this probe cannot judge parallelism here (the same prompt+tools must call; cf. probe 11 §2)"
  else
    ask_chat "$WEATHER_TOOLS,\"parallel_tool_calls\":false" 220 "$ASK_TWO"
    probe_note "parallel_tool_calls:false: finish=$FINISH calls=$N_CALLS $CITIES"
    if [ "$N_CALLS" -gt 1 ]; then
      probe_fail "parallel_tool_calls:false delivered $N_CALLS calls ($CITIES) — the client forbade parallel calls and the flag was ignored"
    elif [ "$DEFAULT_CALLS" -ge 2 ] && [ "$N_CALLS" != "1" ]; then
      probe_fail "the checkpoint offered $DEFAULT_CALLS calls unrestricted but $N_CALLS under parallel_tool_calls:false — expected exactly the first"
    else
      probe_ok "parallel_tool_calls:false delivered $N_CALLS call(s) ($CITIES)"
      if [ "$DEFAULT_CALLS" = "1" ]; then
        probe_note "unrestricted turn emitted a single call, so the filter had nothing to cut here; the cut itself is pinned by ToolCallWireContractTests (limitKeepsFirstCall)"
      fi
    fi
  fi
fi

# ── 2. the same promise on the Anthropic face ────────────────────────────────
probe_section "2 — tool_choice.disable_parallel_tool_use:true delivers one tool_use block"
ask_anthropic "$ANTH_TOOLS,\"tool_choice\":{\"type\":\"auto\"}" 220 "$ASK_TWO"
ANTH_DEFAULT_BLOCKS="$N_BLOCKS"
probe_note "Anthropic tool_choice:auto: stop_reason=$STOP blocks=$ANTH_DEFAULT_BLOCKS"
if [ "$STATUS" != "200" ]; then
  probe_fail "Anthropic control turn answered $STATUS — $(printf %.200s "$BODY")"
else
  ask_anthropic "$ANTH_TOOLS,\"tool_choice\":{\"type\":\"auto\",\"disable_parallel_tool_use\":true}" 220 "$ASK_TWO"
  probe_note "Anthropic disable_parallel_tool_use:true: stop_reason=$STOP blocks=$N_BLOCKS"
  if [ "$STATUS" != "200" ]; then
    probe_fail "Anthropic restricted turn answered $STATUS — $(printf %.200s "$BODY")"
  elif [ "$N_BLOCKS" -gt 1 ]; then
    probe_fail "disable_parallel_tool_use:true delivered $N_BLOCKS tool_use blocks — Anthropic's flag never reached the engine path"
  elif [ "$ANTH_DEFAULT_BLOCKS" -ge 2 ] && [ "$N_BLOCKS" != "1" ]; then
    probe_fail "$ANTH_DEFAULT_BLOCKS blocks unrestricted but $N_BLOCKS with the flag set — expected exactly one"
  else
    probe_ok "disable_parallel_tool_use:true delivered $N_BLOCKS tool_use block(s)"
  fi
fi

# ── 3. the terminal word must not lie about a cut ─────────────────────────────
# A cut is defined by the measurement, not by a remembered token count: `at` the budget
# means the turn was chopped (the word must be length), `under` means it completed (the
# word must not be length), and `over` means max_tokens never reached generation.
# 25 is where the cut lands on this checkpoint — the two-call answer measures 28 tokens
# (measured 10-19), so one complete call survives mid-list: the exact situation where the
# old word (`tool_calls`) told a client the call list was whole.
probe_section "3 — finish_reason: a budget cut stays visible (length), a clean call says tool_calls"
CUTS_OBSERVED=0

# check_turn LABEL MAX — judges the last turn's terminal word against its measured budget.
check_turn() {
  local label="$1" max="$2" cls
  if [ "$STATUS" != "200" ]; then
    probe_fail "$label answered $STATUS — $(printf %.200s "$BODY")"
    return
  fi
  cls="$(budget_class "$max" "$COMPLETION")"
  case "$cls" in
    over)
      probe_fail "$label: completion_tokens=$COMPLETION exceeds max_tokens=$max — the budget never reached generation, so no terminal word for this turn can be trusted"
      ;;
    at)
      CUTS_OBSERVED=$(( CUTS_OBSERVED + 1 ))
      if [ "$FINISH" != "length" ]; then
        probe_fail "$label: completion_tokens=$COMPLETION == max_tokens=$max but finish_reason=$FINISH — a turn the budget chopped must say length, or a client executes a call list it cannot know was cut"
      else
        probe_ok "$label: a budget-cut turn says finish_reason=length (calls delivered: $N_CALLS)"
      fi
      ;;
    under)
      if [ "$FINISH" = "length" ]; then
        probe_fail "$label: finish_reason=length but completion_tokens=$COMPLETION < max_tokens=$max — the turn stopped early and blamed the budget"
      else
        probe_ok "$label: completed under budget ($COMPLETION/$max) says $FINISH"
      fi
      ;;
    *)
      probe_fail "$label: no numeric usage.completion_tokens in the response (got '$COMPLETION') — cannot judge the terminal word without it"
      ;;
  esac
}

ask_chat "$WEATHER_TOOLS" 25 "$ASK_TWO"
probe_note "cut turn (max_tokens=25): finish=$FINISH completion=$COMPLETION calls=$N_CALLS $CITIES"
check_turn "cut turn (max=25)" 25

# Control: the same request with room to finish must say tool_calls.
ask_chat "$WEATHER_TOOLS" 220 "$ASK_ONE"
probe_note "complete call turn (max_tokens=220): finish=$FINISH completion=$COMPLETION calls=$N_CALLS $CITIES"
if [ "$STATUS" != "200" ]; then
  probe_fail "the complete-call turn answered $STATUS — $(printf %.200s "$BODY")"
elif [ "$N_CALLS" = "0" ]; then
  probe_fail "no call delivered on the complete-call turn — the finish-word assertion below would pass vacuously"
elif [ "$COMPLETION" = "220" ]; then
  probe_note "the complete call also filled its budget (completion=$COMPLETION) — length is the honest word here, recorded not overridden"
elif [ "$FINISH" != "tool_calls" ]; then
  probe_fail "a delivered call must end with finish_reason=tool_calls, got $FINISH"
else
  probe_ok "a call that completed says finish_reason=tool_calls"
fi

# Control: truncation without any tools must say length (proves the mapping, not the tools).
ask_chat "" 20 "$LONG_ANSWER"
probe_note "no-tools truncation (max_tokens=20): finish=$FINISH completion=$COMPLETION"
check_turn "no-tools truncation (max=20)" 20

# §3's premise is that a cut actually happened somewhere above; without it the length
# mapping was never exercised and the section asserted nothing (AGENTS.md: a scan must
# floor its own premises).
if [ "$CUTS_OBSERVED" = "0" ]; then
  probe_fail "§3 saw no turn land on its budget (no completion_tokens == max_tokens) — the length mapping was never exercised here, so §3 judged nothing about cuts"
fi

# ── 4. SSE: only the terminal chunk carries the word ──────────────────────────
probe_section "4 — SSE: null on deltas, one terminal word, [DONE] last"
SSE_SESSION="$(fresh_session)"
SSE_BODY='{"model":"'"$PROBE_MODEL"'","session_id":"'"$SSE_SESSION"'","temperature":0,"max_tokens":220,"stream":true,"messages":[{"role":"user","content":"'"$ASK_ONE"'"}]'"$WEATHER_TOOLS"'}'
probe_chat "$SSE_SESSION" "$SSE_BODY" || true
SSE="$PROBE_BODY"
SSE_STATS="$(printf '%s' "$SSE" | python3 -c '
import json, sys
lines = [l[6:] for l in sys.stdin.read().splitlines() if l.startswith("data: ")]
done = bool(lines) and lines[-1] == "[DONE]"
chunks = []
for l in lines:
    if l == "[DONE]":
        continue
    try:
        chunks.append(json.loads(l))
    except Exception:
        pass
non_null = []
terminals = 0
tool_delta_has_word = False
for c in chunks:
    for ch in c.get("choices", []):
        fr = ch.get("finish_reason")
        if fr is not None:
            non_null.append(fr)
            terminals += 1
        if ch.get("delta", {}).get("tool_calls") and fr is not None:
            tool_delta_has_word = True
last = non_null[-1] if non_null else None
sys.stdout.write("chunks=%d nonnull=%d words=%s last=%s tooldelta_word=%s done=%s" % (
    len(chunks), terminals, ",".join(non_null) or "-", last or "-",
    tool_delta_has_word, done))')"
probe_note "SSE $SSE_STATS"
case "$SSE_STATS" in
  *"nonnull=1 "*) probe_ok "exactly one chunk carries a non-null finish_reason" ;;
  *"nonnull=0 "*) probe_fail "SSE carried no finish_reason at all — the turn has no terminal word" ;;
  *) probe_fail "SSE carried $(printf '%s' "$SSE_STATS" | sed -n 's/.*nonnull=\([0-9]*\).*/\1/p') non-null finish_reasons — only the terminal chunk may carry one (OpenAI sends null on content/tool_calls deltas)" ;;
esac
case "$SSE_STATS" in
  *"tooldelta_word=False"*) probe_ok "the tool_calls delta carried finish_reason:null" ;;
  *"tooldelta_word=True"*) probe_fail "a mid-stream tool_calls delta carried a non-null finish_reason — a client that stops at the first one never sees the answer" ;;
  *) probe_fail "no tool_calls delta in the stream — §4 judged nothing: $SSE_STATS" ;;
esac
case "$SSE_STATS" in
  *"words=tool_calls"*) probe_ok "the terminal word is tool_calls for a turn that called" ;;
  *) probe_fail "the terminal word was not tool_calls on a calling turn: $SSE_STATS" ;;
esac
case "$SSE_STATS" in
  *done=True) probe_ok "[DONE] closed the stream" ;;
  *) probe_fail "stream did not close with [DONE]: $SSE_STATS" ;;
esac

# ── 5. Anthropic stop_reason tracks what was delivered ────────────────────────
probe_section "5 — Anthropic stop_reason tracks delivery"
ask_anthropic "$ANTH_TOOLS" 220 "$ASK_ONE"
probe_note "Anthropic call turn: stop_reason=$STOP blocks=$N_BLOCKS output=$ANTH_OUT"
if [ "$STATUS" != "200" ]; then
  probe_fail "Anthropic call turn answered $STATUS — $(printf %.200s "$BODY")"
elif [ "$N_BLOCKS" -gt 0 ] && [ "$STOP" != "tool_use" ]; then
  probe_fail "a turn that delivered $N_BLOCKS tool_use block(s) said stop_reason=$STOP — a delivered call must be named"
elif [ "$N_BLOCKS" = "0" ] && [ "$STOP" = "tool_use" ]; then
  probe_fail "stop_reason=tool_use with no tool_use block delivered — the word claims a call the client never got"
else
  probe_ok "stop_reason=$STOP agrees with $N_BLOCKS delivered block(s)"
fi
ask_anthropic '' 20 "$LONG_ANSWER"
probe_note "Anthropic no-tools truncation: stop_reason=$STOP output=$ANTH_OUT"
if [ "$STOP" != "max_tokens" ]; then
  probe_fail "Anthropic no-tools truncation said stop_reason=$STOP, expected max_tokens — the mapping this face promises"
else
  probe_ok "Anthropic truncation control says max_tokens"
fi

# ── 6. tool_choice shapes ─────────────────────────────────────────────────────
probe_section "6 — tool_choice: OpenAI's shape decodes, unknown values are refused by name"

# Bodies are assembled, never hand-typed twice, and every fragment is a single-quoted
# literal with its own leading comma. Both comma bugs in this probe's first draft (a
# missing one before "tools", a doubled one before $WEATHER_TOOLS) and one quote bug
# produced "not valid JSON" answers that judged nothing — the exact nested-quoting trap
# probe 09 documents for macOS bash 3.2.
chat_body() {
  printf '{"model":"%s","session_id":"%s","temperature":0,"max_tokens":%s,"messages":[{"role":"user","content":"%s"}]%s%s}' \
    "$PROBE_MODEL" "$1" "$3" "$2" "$4" "$5"
}

PIN_NESTED=',"tool_choice":{"type":"function","function":{"name":"get_weather"}}'
PIN_FLAT=',"tool_choice":{"type":"function","name":"get_weather"}'
CHOICE_BANANA=',"tool_choice":"banana"'
CHOICE_ARRAY=',"tool_choice":["auto"]'

S="$(fresh_session)"
B="$(chat_body "$S" "What is the weather in Tokyo?" 150 "$WEATHER_TOOLS" "$PIN_NESTED")"
probe_chat "$S" "$B" || true
NESTED_CALLS="$(printf '%s' "$PROBE_BODY" | count_calls)"
probe_note "nested named-tool pin -> status=$PROBE_STATUS calls=$NESTED_CALLS finish=$(probe_json "$PROBE_BODY" 'choices.0.finish_reason')"
if [ "$PROBE_STATUS" = "400" ]; then
  probe_fail "OpenAI's canonical nested tool_choice was refused: $(printf %.200s "$PROBE_BODY")"
elif [ "$PROBE_STATUS" != "200" ]; then
  probe_fail "nested named-tool pin answered $PROBE_STATUS — $(printf %.200s "$PROBE_BODY")"
elif [ "$NESTED_CALLS" = "0" ]; then
  probe_note "the pin decoded (no 400) but this checkpoint produced no call — per-checkpoint refusal is probe 11 §3c's ledger, not this section's claim"
else
  probe_ok "tool_choice {\"type\":\"function\",\"function\":{\"name\":…}} decodes and delivers the pinned call"
fi

S="$(fresh_session)"
B="$(chat_body "$S" "What is the weather in Tokyo?" 150 "$WEATHER_TOOLS" "$PIN_FLAT")"
probe_chat "$S" "$B" || true
if [ "$PROBE_STATUS" = "200" ]; then
  probe_ok "the flat alias still decodes (tolerated extension, pinned by ToolsWireDecodeTests)"
else
  probe_fail "the flat alias regressed: status=$PROBE_STATUS $(printf %.200s "$PROBE_BODY")"
fi

named_400() {
  local lab="$1" body="$2" want="$3" s
  s="$(fresh_session)"
  body="${body//SESSION_ID/$s}"
  probe_api POST /v1/chat/completions "$body" || true
  local msg param type
  msg="$(probe_json "$PROBE_BODY" 'error.message')"
  param="$(probe_json "$PROBE_BODY" 'error.param')"
  type="$(probe_json "$PROBE_BODY" 'error.type')"
  probe_note "$lab -> status=$PROBE_STATUS param=$param type=$type msg=$(printf %.120s "$msg")"
  if [ "$PROBE_STATUS" != "400" ]; then
    probe_fail "$lab answered $PROBE_STATUS, expected 400"
  elif [ "$param" != "tool_choice" ]; then
    probe_fail "$lab did not name tool_choice (param=$param)"
  elif [ "$type" != "invalid_request_error" ]; then
    probe_fail "$lab carried type=$type — a 400 speaks invalid_request_error"
  elif printf '%s' "$msg" | grep -q 'Coding key'; then
    probe_fail "$lab leaked Hummingbird's decoder wording: $msg"
  elif ! printf '%s' "$msg" | grep -q "$want"; then
    probe_fail "$lab did not echo the offending value ($want): $msg"
  else
    probe_ok "$lab refused by name (param=tool_choice, value echoed)"
  fi
}

named_400 "tool_choice banana" \
  "$(chat_body SESSION_ID "hi" 32 "$WEATHER_TOOLS" "$CHOICE_BANANA")" "banana"
named_400 "tool_choice with no tools[]" \
  "$(chat_body SESSION_ID "hi" 32 "" "$PIN_NESTED")" "get_weather"
named_400 "tool_choice as an array" \
  "$(chat_body SESSION_ID "hi" 32 "" "$CHOICE_ARRAY")" "tool_choice"

probe_api POST /v1/messages '{"model":"'"$PROBE_MODEL"'","max_tokens":32,"messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"any"}}' || true
probe_note "Anthropic tool_choice with no tools -> status=$PROBE_STATUS msg=$(printf %.160s "$PROBE_BODY")"
if [ "$PROBE_STATUS" != "400" ]; then
  probe_fail "Anthropic tool_choice without tools answered $PROBE_STATUS, expected 400"
elif printf '%s' "$PROBE_BODY" | grep -q '"param":"tool_choice"'; then
  probe_ok "Anthropic face refuses tool_choice-without-tools and names the field"
else
  probe_fail "Anthropic refusal did not name tool_choice: $(printf %.200s "$PROBE_BODY")"
fi

# ── 7. a turn obeys its own budget even after a guided turn on the same session ───
# Measured 10-19 on this host (`gemma-4-e2b-it-4bit`, temp 0), two turns on ONE session,
# before the fix:
#
#   grammar turn (`response_format: json_object`) max_tokens=64 -> completion=19, finish=stop
#   next turn, plain text                              max_tokens=8  -> completion=64, finish=length
#   tool turn (`tools[]`, calls returned)             max_tokens=64 -> completion=28, finish=tool_calls
#   next turn, plain text                              max_tokens=8  -> completion=64, finish=length
#   control, no guided turn first in the session:     max_tokens=60 -> 60, max_tokens=8 -> 8
#
# The client asked for 8, paid for 64, and the same response body contradicted itself
# (`usage.completion_tokens=64` against `max_tokens=8`) — invariant 2 and "a knob the wire
# accepts must reach the engine". The wire is not where it was lost (`max_tokens` is
# resolved per request at Handlers/ChatHandler.swift:582-583 and threaded into
# `GenerateParameters` at Engine/MLXBridge.swift:954), and the follow-up turn's own log said
# `wireMaxTokens=8` / `Generation budget: maxTokens=8`.
#
# Root cause, and why only the guided/tool session leaked: sampling lives on the
# `ChatSession`, not on the call — mlx-swift-lm declares `public var generateParameters`
# (ChatSession.swift:370) and `streamMap` captures that stored property when the stream
# starts (ChatSession.swift:981-987), so `streamDetails(to:)` carries no parameters at all. A pooled session
# reused on the next turn therefore generates under whatever budget it was created with.
# Plain turns mask this: they park a transcript in the pool, so their successor fails
# `MLXSessionPool.canReusePooledSession` and gets a clean session; a guided/MTP turn
# releases with `assistantMessage: nil`, which parks an *empty* transcript — and an empty
# transcript reuses against anything.
#
# Fix: `MLXSessionPool.acquire` refreshes the reused session's `generateParameters` from
# this turn's request before handing it back (cache-affecting fields stay upstream's job:
# ChatSession.swift:1052-1067 rebuilds from its retained transcript when the plan moves).
# Unit gate: Tests/ocoreaiTests/PooledParameterDriftTests.swift (field set + the site).
# This section is that gate's live half: delete the refresh and §7 goes red twice.
probe_section "7 — a turn obeys its own budget after a guided turn on the same session"
JSON_ONLY=',"response_format":{"type":"json_object"}'

# budget_after LABEL PRIOR_EXTRA PRIOR_MAX PRIOR_PROMPT — a guided turn, then a plain turn
# on the SAME session with a budget an eighth of the prior, so a leak is unmistakable.
budget_after() {
  local lab="$1" prior_extra="$2" prior_max="$3" prior_prompt="$4"
  local tight=$(( prior_max / 8 ))
  local leaky_session
  leaky_session="$(fresh_session)"
  ask_chat_in "$leaky_session" "$prior_extra" "$prior_max" "$prior_prompt"
  probe_note "$lab: guided turn max=$prior_max -> completion=$COMPLETION finish=$FINISH"
  ask_chat_in "$leaky_session" "" "$tight" "$LONG_ANSWER"
  probe_note "$lab: next turn, same session, max=$tight -> completion=$COMPLETION finish=$FINISH"
  if [ "$STATUS" != "200" ]; then
    probe_fail "$lab: the follow-up turn answered $STATUS — $(printf %.200s "$BODY")"
  elif [ "$(budget_class "$tight" "$COMPLETION")" = "over" ]; then
    probe_fail "$lab: max_tokens=$tight delivered completion_tokens=$COMPLETION (the guided turn before it asked for $prior_max) — a reused pooled session served this turn under the previous turn's budget"
  else
    probe_ok "$lab: max_tokens=$tight delivered $COMPLETION — the second turn on this session obeyed its own budget"
  fi
}

# Control first: without it §7 cannot tell a leak from a server that ignores budgets whole.
ask_chat "" 8 "$LONG_ANSWER"
probe_note "control (this session never saw a guided turn): max=8 -> completion=$COMPLETION finish=$FINISH"
if [ "$(budget_class 8 "$COMPLETION")" = "over" ]; then
  probe_fail "control turn exceeded max_tokens=8 (completion=$COMPLETION) — max_tokens is not reaching generation at all, so §7 cannot isolate a leak"
else
  probe_ok "tight budget honoured when no guided turn came first ($COMPLETION/8)"
fi

budget_after "grammar-first session" "$JSON_ONLY" 64 "Give me a person's name and age as JSON."
budget_after "tools-first session" "$WEATHER_TOOLS" 64 "$ASK_TWO"

probe_summary "$PROBE_NAME"
