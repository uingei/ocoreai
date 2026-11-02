#!/usr/bin/env bash
# 49-decisions-contract-refusal.sh — does `/v1/decisions` ever answer with a number it did not measure?
#
# The axis exists to hand a caller a probability it will *act on* (pick a route, grade a ticket), so
# this route has exactly one unforgivable answer: a number that was never read. This build cannot read
# one — an answer is the probability of each offered label at the answer position, and only the CoreAI
# route publishes logits (`Engine/EngineLogprobs.swift:22`), which is why `POST /v1/completions` with
# `logprobs` answers 501 on the same box (`Handlers/CompletionsHandler.swift:102`). So the pair this
# probe pins is the pair the route is allowed to give: **400 naming every reason a body is wrong, or
# 501 naming the read that is missing — and no probability, `prompt_token_ids` or `confidence` field on
# either path.**
#
# Measured 11-02 on one live `serve` driving the scripted engine (no weights, so this is a wire-tier
# verdict and claims nothing about a checkpoint) — 25 passed, 0 failed: the five valid shapes (26
# options, 10 levels, all three question types, every accepted key, an unserved model name) all reached
# the scoring seat and answered 501 `unsupported` naming the logits read and both exits; the eight
# malformed bodies answered 400 `invalid_request_error` each naming its own fault, and one body with
# four faults was told all four at once. §4's first run reported every 501 as a leak and was wrong: it
# substring-matched the body, and the refusal's own sentence contains the words "no probability". The
# scan now walks parsed keys, was sampled against a planted nested `probabilities`/`confidence` pair,
# and reads clean on the prose — which is the distinction the leg is for.
#
# Legs:
#   1) discovery + control — the route is in the index a stranger reads (`/v1/capabilities` →
#      `endpoints[]`), and a well-formed body reaches the seat that decides scoring. Without this a
#      later 404 would look like a refusal and a later 501 would look like a broken route.
#   2) contract — each malformed body is refused by name (400), and a body with four faults is told
#      all four at once, the way the reference's detail list does
#      (`sglang …/http_server.py:636-660`; rules cited per-field in `Wire/DecisionsWire.swift`).
#   3) the other direction — the shapes the contract *accepts* (26 options, 10 levels, all three
#      question types, every accepted key at once, an unserved model name) must NOT be refused. Only
#      this leg can see a bound that got tightened by mistake.
#   4) no invented numbers — nothing on either path carries a probability-shaped key,
#      `return_prompt_token_ids` buys no token ids that were never produced, and the 501 names the
#      missing read, one exit, and its own refusal to guess.
#   5) floor — both directions count their own subjects: a server that 400s everything cannot pass §3,
#      and one that 501s everything cannot pass §2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="decisions-contract-refusal"

SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
BODY_DIR="$(mktemp -d)"
probe_atexit 'rm -f "$SCRIPT_FILE"; rm -rf "$BODY_DIR"'

# The decisions route never reaches the engine — it refuses before scoring — so the scripted engine is
# here to boot a server cheaply, not to stand in for an answer.
printf '%s\n' '{"segments": ["refused"], "finishReason": "eos", "promptTokens": 4, "generatedTokens": 1}' \
  > "$SCRIPT_FILE"
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"

python3 - "$BODY_DIR" <<'PY'
import json, os, sys
out = sys.argv[1]

def choice(n, id="q1"):
    return {"id": id, "type": "choice", "question": "which one?",
            "options": [{"name": "opt%d" % i} for i in range(n)]}

def score(n, id="q1"):
    return {"id": id, "type": "score", "question": "how good?",
            "levels": ["level%d" % i for i in range(n)]}

OK = {
    "valid_min": {"input": "the ticket says ship Friday",
                  "questions": [{"id": "q", "type": "yes_no", "question": "safe to ship?"}]},
    # Boundaries at the upper end of both families: options are labelled A–Z, levels 0–9.
    "valid_choice_max": {"input": "x", "questions": [choice(26)]},
    "valid_score_max": {"input": "x", "questions": [score(10)]},
    "valid_three_types": {"input": "x", "questions": [
        {"id": "a", "type": "yes_no", "question": "safe?"},
        score(3, id="b"), choice(2, id="c")]},
    # Every key the contract accepts, in one body. `return_prompt_token_ids` is accepted and means
    # nothing until something scores; §4 pins that it buys nothing back.
    "valid_all_keys": {
        "input": "x", "questions": [choice(2)], "model": "scripted-model", "temperature": 0.3,
        "chat_template_kwargs": {"enable_thinking": False}, "prompt_format_version": 1,
        "return_prompt_token_ids": True, "images": []},
    # A model name that is not served. The refusal is about this BUILD, not about the checkpoint, so
    # the answer must be the same 501 for the same reason rather than a 404 implying the box could
    # score one if asked nicely.
    "valid_unknown_model": {"input": "x", "model": "no-such-model-xyz",
                            "questions": [{"id": "q", "type": "yes_no", "question": "ok?"}]},
}
# label → (body, the substring a correct 400 must contain). The expectation travels beside the body it
# belongs to: a second table of these strings below would be a second home that can drift.
BAD = {
    "unknown_top": ({"input": "x", "questions": [choice(2)], "temprature": 0.2},
                    "unknown field 'temprature'"),
    "unknown_in_question": ({"input": "x", "questions": [
        {"id": "q", "type": "yes_no", "question": "ok?", "yes_label": "yep"}]},
        "unknown field 'yes_label'"),
    "blank_input": ({"input": "   ", "questions": [{"id": "q", "type": "yes_no", "question": "ok?"}]},
                    "'input' must not be blank"),
    "one_option": ({"input": "x", "questions": [choice(1)]}, "2 to 26"),
    "eleven_levels": ({"input": "x", "questions": [score(11)]}, "2 to 10"),
    "misspelled_type": ({"input": "x", "questions": [
        {"id": "q", "type": "yesno", "question": "ok?"}]},
        "'type' must be choice, score or yes_no"),
    "duplicate_ids": ({"input": "x", "questions": [
        {"id": "same", "type": "yes_no", "question": "first?"},
        {"id": "same", "type": "yes_no", "question": "second?"}]},
        "repeats another question"),
    "zero_temperature": ({"input": "x", "questions": [choice(2)], "temperature": 0},
                         "'temperature' must be greater than 0"),
}
MULTI = {"input": "", "questions": [], "temprature": 1, "model": 7}
MULTI_REASONS = ["unknown field 'temprature'", "'input' must not be blank",
                 "'questions' must be an array of at least 1 question",
                 "'model' must be a string"]

for name, body in list(OK.items()) + [(k, v[0]) for k, v in BAD.items()] + [("four_faults", MULTI)]:
    with open(os.path.join(out, name + ".json"), "w") as fh:
        json.dump(body, fh)
for name, (_, expected) in BAD.items():
    with open(os.path.join(out, name + ".expected"), "w") as fh:
        fh.write(expected)
with open(os.path.join(out, "four_faults.expected"), "w") as fh:
    fh.write("\n".join(MULTI_REASONS))
# Not JSON at all: a schema failure is a 400 here, never a 500.
with open(os.path.join(out, "not_json.json"), "w") as fh:
    fh.write("{not json")
print("bodies=%d" % len([f for f in os.listdir(out) if f.endswith(".json")]), file=sys.stderr)
PY

probe_boot

post_body() { probe_api POST /v1/decisions "$(cat "$BODY_DIR/$1.json")"; }
expected_of() { cat "$BODY_DIR/$1.expected"; }

probe_section "1) discovery + control — a stranger can find the route and reach the scoring seat"
probe_api GET /v1/capabilities
LISTED="$(PROBE_ENDPOINTS="$PROBE_BODY" python3 -c '
import json, os, sys
try:
    rows = json.loads(os.environ["PROBE_ENDPOINTS"])["endpoints"]
except Exception:
    print(0); sys.exit(0)
print(sum(1 for r in rows if r.get("method") == "POST" and r.get("path") == "/v1/decisions"))')"
if [ "${LISTED:-0}" -ge 1 ]; then
  probe_ok "POST /v1/decisions is in /v1/capabilities endpoints[] — the index a client enumerates" \
    " before calling, so the published row and the live route are one fact"
else
  probe_fail "POST /v1/decisions is absent from endpoints[] ($(printf '%s' "$PROBE_BODY" | head -c 120))" \
    " — a route a client cannot discover is a route it will not use"
fi
post_body valid_min
case "$PROBE_STATUS" in
  200|501)
    probe_ok "a well-formed body reached the seat that decides scoring (HTTP $PROBE_STATUS) — every" \
      " verdict below is about an answer, not about a route that stopped answering" ;;
  *)
    probe_fail "well-formed body got HTTP $PROBE_STATUS ($(printf '%s' "$PROBE_BODY" | head -c 160))," \
      " expected 200 (scored) or 501 (no logits read) — nothing below reads as a contract verdict" ;;
esac

probe_section "2) contract — a malformed body is refused by name, every reason at once"
REFUSED_BY_NAME=0
for label in unknown_top unknown_in_question blank_input one_option eleven_levels \
             misspelled_type duplicate_ids zero_temperature; do
  expected="$(expected_of "$label")"
  post_body "$label"
  TYPE="$(probe_json "$PROBE_BODY" 'error.type')"
  MESSAGE="$(probe_json "$PROBE_BODY" 'error.message')"
  if [ "$PROBE_STATUS" != "400" ]; then
    probe_fail "$label → HTTP $PROBE_STATUS, expected 400 — the body was accepted, so whatever answer" \
      " follows scores a question the caller did not write"
    continue
  fi
  if [ "$TYPE" != "invalid_request_error" ]; then
    probe_fail "$label → 400 but type='${TYPE:-<absent>}' — both specs name invalid_request_error for" \
      " a 400 and an SDK branches on it, not on the message"
    continue
  fi
  case "$MESSAGE" in
    *"$expected"*) ;;
    *) probe_fail "$label → 400 that does not name the fault (looked for \"$expected\" in:" \
      " ${MESSAGE:0:140}) — a refusal without the field is not actionable"; continue ;;
  esac
  REFUSED_BY_NAME=$(( REFUSED_BY_NAME + 1 ))
  probe_ok "$label → 400 invalid_request_error naming \"$expected\""
done

post_body not_json
TYPE="$(probe_json "$PROBE_BODY" 'error.type')"
if [ "$PROBE_STATUS" = "400" ] && [ "$TYPE" = "invalid_request_error" ]; then
  probe_ok "a body that is not JSON → 400 invalid_request_error, not a 500 — the reference overrides" \
    " FastAPI's default to 400 on this route, and a crash would be a different bug"
else
  probe_fail "non-JSON body → HTTP $PROBE_STATUS type='${TYPE:-<absent>}' — a schema failure must" \
    " never surface as a server fault"
fi

post_body four_faults
MESSAGE="$(probe_json "$PROBE_BODY" 'error.message')"
ALL_AT_ONCE=0
while IFS= read -r reason; do
  [ -z "$reason" ] && continue
  case "$MESSAGE" in *"$reason"*) ALL_AT_ONCE=$(( ALL_AT_ONCE + 1 )) ;; esac
done < <(expected_of four_faults; printf '\n')
if [ "$PROBE_STATUS" = "400" ] && [ "$ALL_AT_ONCE" -eq 4 ]; then
  probe_ok "one request, four faults, four reasons in one message — the body is fixed in one round" \
    " trip instead of four"
else
  probe_fail "four-fault body → HTTP $PROBE_STATUS carrying $ALL_AT_ONCE/4 reasons (${MESSAGE:0:160})" \
    " — one-complaint-per-round-trip validation is how an integrator loses a day"
fi

probe_section "3) the other direction — a body the contract accepts must not be refused"
REACHED_SEAT=0
for label in valid_choice_max valid_score_max valid_three_types valid_all_keys; do
  post_body "$label"
  if [ "$PROBE_STATUS" = "400" ]; then
    probe_fail "$label → 400 ($(printf '%s' "$PROBE_BODY" | head -c 140)) — this shape is legal by the" \
      " cited bounds, so refusing it costs a client an integration that is allowed to work"
  elif [ "$PROBE_STATUS" = "200" ] || [ "$PROBE_STATUS" = "501" ]; then
    REACHED_SEAT=$(( REACHED_SEAT + 1 ))
    probe_ok "$label → HTTP $PROBE_STATUS — accepted by the contract, passed to the scoring seat"
  else
    probe_fail "$label → HTTP $PROBE_STATUS ($(printf '%s' "$PROBE_BODY" | head -c 140))," \
      " expected 200 or 501"
  fi
done
post_body valid_unknown_model
CODE="$(probe_json "$PROBE_BODY" 'error.error_code')"
CODE_NUM="$(probe_json "$PROBE_BODY" 'error.code')"
if [ "$PROBE_STATUS" = "501" ] && [ "$CODE" = "unsupported" ]; then
  REACHED_SEAT=$(( REACHED_SEAT + 1 ))
  probe_ok "an unserved model name gets the same 501 \`unsupported\` (code=$CODE_NUM) as a served one" \
    " — the refusal is about this build's logits; a 404 would imply the box could score one"
else
  probe_fail "unserved model → HTTP $PROBE_STATUS error_code='${CODE:-<absent>}' — the refusal must" \
    " stay the build-wide one it actually is"
fi

probe_section "4) no invented numbers — nothing on either path may look like a measurement"
# The one failure this surface cannot afford: an answer-shaped field with no read behind it
# (`docs/agent/systemone-decisions.md` § the cheapest honest slice, item 5). Scanned across BOTH paths,
# since a leak on either is the same lie to a client.
#
# Keyed, not grepped: the first run of this probe substring-matched the raw body and reported every 501
# as a leak, because the refusal's own sentence says "returns no probability rather than an invented
# one". The claim is about FIELDS a client would read as an answer, so the scan walks the parsed tree's
# keys and says which one it found.
bad_answer_keys() {
  PROBE_JSON_INPUT="$1" python3 - <<'PY'
import json, os, re, sys
try:
    node = json.loads(os.environ["PROBE_JSON_INPUT"])
except Exception:
    # An unparsable body is judged by §2/§3, not here; say nothing rather than claim a clean scan.
    print("")
    sys.exit(0)
BAD = re.compile(r"(?i)probabilit|confidence|logprob|prompt_token_ids|^answers?$|^legend$|^labels?$")
found = []

def walk(node, path):
    if isinstance(node, dict):
        for key, value in node.items():
            if BAD.search(key):
                found.append(path + key)
            walk(value, path + key + ".")
    elif isinstance(node, list):
        for index, item in enumerate(node):
            walk(item, "%s[%d]." % (path.rstrip("."), index))

walk(node, "")
print(" ".join(found))
PY
}
LEAK=""
SCANNED=0
SCORED=0
for label in valid_min valid_choice_max valid_score_max valid_three_types valid_all_keys \
             valid_unknown_model unknown_top blank_input four_faults not_json; do
  post_body "$label"
  case "$PROBE_STATUS" in
    2*)
      # A 200 means this box scores for real, which makes the question "is the number right?" — a
      # different probe on a ready model, not this one. Counted and said, never silently skipped.
      SCORED=$(( SCORED + 1 ))
      continue ;;
  esac
  SCANNED=$(( SCANNED + 1 ))
  BADKEYS="$(bad_answer_keys "$PROBE_BODY")"
  [ -n "$BADKEYS" ] && LEAK="$LEAK $label[$BADKEYS]"
done
if [ -z "$LEAK" ]; then
  probe_ok "$SCANNED refusal responses scanned by key, none carrying a probability-, confidence-," \
    " logprob-, prompt_token_ids-, answer-, legend- or label-shaped field — including the body that" \
    " asked for prompt token ids, which is accepted and correctly answered with nothing"
else
  probe_fail "answer-shaped field in:$LEAK — this route must return no probability rather than an" \
    " invented one"
fi
if [ "$SCORED" -gt 0 ]; then
  probe_note "$SCORED/$(( SCANNED + SCORED )) bodies answered 200 — this build scores, so the answer" \
    " shape was NOT judged here; the numbers themselves still need a ready-model verdict"
fi
post_body valid_min
CODE="$(probe_json "$PROBE_BODY" 'error.error_code')"
REMEDY="$(probe_json "$PROBE_BODY" 'error.remediation')"
MESSAGE="$(probe_json "$PROBE_BODY" 'error.message')"
# `unsupported` is coreai-models' own word for a logprobs request on a logits-less engine
# (`swift/Sources/Tools/llm-server/CompletionHandler.swift`), so a client that already handles one of
# these handles both without a new branch.
if [ "$CODE" = "unsupported" ] && [ -n "$REMEDY" ]; then
  probe_ok "the 501 carries error_code=unsupported plus a remediation of" \
    "$(printf '%s' "$REMEDY" | wc -c | tr -d ' ') bytes"
else
  probe_fail "the 501 carries error_code='${CODE:-<absent>}' with a remediation of ${#REMEDY} bytes —" \
    " a 501 without the missing prerequisite and the way around it is a dead end"
fi
NAMED=0
case "$MESSAGE" in *logits*) NAMED=$(( NAMED + 1 )) ;; esac
case "$MESSAGE" in *invent*) NAMED=$(( NAMED + 1 )) ;; esac
if [ "$NAMED" -eq 2 ]; then
  probe_ok "the refusal names the read that is missing and states that it will not invent a number"
else
  probe_fail "the refusal does not both name the missing logits read and disclaim invention" \
    " (${MESSAGE:0:160}) — the caller cannot tell 'not yet' from 'not ever'"
fi

probe_section "5) floor — both directions count their own subjects"
if [ "$REFUSED_BY_NAME" -ge 8 ]; then
  probe_ok "$REFUSED_BY_NAME/8 malformed bodies refused by name, each with the reason the client can" \
    " act on — §2 has subjects"
else
  probe_fail "only $REFUSED_BY_NAME/8 malformed bodies refused by name — the leg that counts these is" \
    " not measuring what it claims"
fi
if [ "$REACHED_SEAT" -ge 5 ]; then
  probe_ok "$REACHED_SEAT/5 legal shapes reached the scoring seat — §3 exercised the direction a" \
    " mistyped bound would break"
else
  probe_fail "only $REACHED_SEAT/5 legal shapes reached the scoring seat — if every body were refused" \
    " §2 would still look green, which is the vacuous green this floor exists to catch"
fi
if [ "$SCANNED" -ge 8 ]; then
  probe_ok "$SCANNED bodies scanned for answer-shaped keys — §4's clean verdict has subjects, so it is" \
    " not a scan that matched nothing"
else
  probe_fail "§4 scanned only $SCANNED bodies — a leak check with nothing to read out is the exact" \
    " vacuous green this file's own rule names"
fi

probe_summary "$PROBE_NAME"
