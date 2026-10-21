#!/usr/bin/env bash
# 22-session-memory-identity.sh — does one `session_id` become one session, does a message
# row hold its own tokens, and does a re-sent history get written twice?
#
# Why: both used to be no, measured on this host on 10-21 in the same hop
# (`ChatHandler.persistConversation`):
#   • three turns with the same `session_id` created THREE `sessions` rows, because a row was
#     reused only when the key parsed as `Int64` — and nothing on the HTTP surface ever hands a
#     client an integer (`/sessions` is read-only), so memory, FTS and the GUI session list saw
#     one snapshot per request instead of one conversation;
#   • a 34-character user message was stored with `token_count: 705` — that turn's whole
#     rendered prompt, divided over the user rows — while the session total that
#     `SessionCompressor` compares against `tokenThreshold` (128k) to prune charged the same
#     history once per turn.
# Fixed the same day: `SessionCompressor.resolveSession` maps the client's key to the one row
# it owns (keyed with the model id, as `SessionPool.poolKey` is), `SessionTranscript` writes
# only the messages the turn adds, and rows carry their own content tokens through
# `EnginePool.countContentTokens` (byte heuristic when the model has no tokenizer, which
# `tokenizerBackend` on `/v1/capabilities` already discloses).
#
# These are hard gates now, not xfail: a conversation splitting into a second row, a row
# costing anything like the turn's whole prompt, a re-sent history written a second time, or
# the Anthropic face (`/v1/messages`, keyed by `metadata.session_id`) keeping no conversation
# at all fails the run.
#
# Run: bash scripts/probes/22-session-memory-identity.sh
PROBE_NAME="22-session-memory-identity"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

KEY="MEMPROBE-$$"
MAX_TOKENS="${OCOREAI_PROBE_MAX_TOKENS:-8}"

probe_boot
probe_require_ready_model

probe_section "three turns on ONE session_id ($KEY)"
probe_api GET "/sessions?limit=500"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "GET /sessions -> ${PROBE_STATUS:-no response}: the surface this probe reads is not answering"
  probe_summary "$PROBE_NAME"
fi
IDS_BEFORE="$PROBE_BODY"

TURN_WORDS="ALPHA BETA GAMMA"
OK_TURNS=0
LAST_PROMPT=""
# What the conversation actually looked like on the wire, so the last turn can re-send a real
# history (with the assistant replies this server produced) instead of a hand-written one.
HISTORY="/tmp/ocoreai-probe22-history-$$.json"
printf '[]' > "$HISTORY"
for word in $TURN_WORDS; do
  body="$(python3 - "$PROBE_MODEL" "$KEY" "$MAX_TOKENS" "$word" <<'PY'
import json, sys
model, key, max_tokens, word = sys.argv[1:5]
print(json.dumps({
    "model": model,
    "session_id": key,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "messages": [{"role": "user", "content": "Reply with exactly the word %s." % word}],
}))
PY
)"
  probe_chat "$KEY" "$body"
  if [ "${PROBE_STATUS:-}" = "200" ]; then
    OK_TURNS=$(( OK_TURNS + 1 ))
    LAST_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
    probe_note "turn $word 200 — prompt_tokens=${LAST_PROMPT:-?}"
    python3 - "$HISTORY" "Reply with exactly the word $word." \
      "$(probe_json "$PROBE_BODY" 'choices.0.message.content')" <<'PY'
import json, sys
path, user_text, reply = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    history = json.load(fh)
history.append({"role": "user", "content": user_text})
if reply.strip():
    history.append({"role": "assistant", "content": reply})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(history, fh, ensure_ascii=False)
PY
  else
    probe_fail "turn $word -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  fi
done
if [ "$OK_TURNS" -eq 3 ]; then
  probe_ok "all 3 turns landed on one conversation key — the premise for what memory must have made of them"
else
  probe_fail "only $OK_TURNS/3 turns succeeded — identity could not be judged, this run proves nothing"
fi

# Persistence is fire-and-forget off the response path; give the last turn's rows a moment to
# land before reading them back, so a slow embedder is not reported as lost memory.
sleep 1

probe_api GET "/sessions?limit=500"
python3 - "$PROBE_BODY" "$IDS_BEFORE" "$KEY" "$LAST_PROMPT" > "/tmp/ocoreai-probe22-$$.txt" <<'PY'
import json, sys
after_raw, before_raw, key, prompt = sys.argv[1:5]
try:
    after = json.loads(after_raw)
    before = json.loads(before_raw)
except Exception as e:
    print("ERR could not parse /sessions: %s" % e)
    sys.exit()
ids_before = {r.get("id") for r in before if isinstance(r, dict)}
by_id = {r["id"]: r for r in after if isinstance(r, dict) and "id" in r}
new = [by_id[i] for i in sorted(set(by_id) - ids_before)]
if not new:
    print("ERR no new session row after 3 accepted turns — session memory is not writing at all")
    sys.exit()
if len(new) != 1:
    print("COUNTFAIL %d" % len(new))
    for s in new:
        print("      id=%s message_count=%s token_count=%s" % (
            s.get("id"), s.get("message_count"), s.get("token_count")))
    sys.exit()
s = new[0]
print("COUNT OK one session row id=%s holding message_count=%s token_count=%s" % (
    s.get("id"), s.get("message_count"), s.get("token_count")))
print("SESSIONID %s" % s.get("id"))
total, p = s.get("token_count"), (int(prompt) if str(prompt).isdigit() else None)
if isinstance(total, int) and p:
    # Three turns of whole-prompt charging would be ~3x the prompt; content-only rows are a
    # fraction of one prompt. Anything past 1.5x means history is being charged again per turn.
    if total <= int(p * 1.5):
        print("TOTAL OK session token_count=%s for prompt_tokens=%s — history is not re-charged per turn" % (total, p))
    else:
        print("TOTALFAIL session token_count=%s across 3 turns of prompt_tokens=%s — the whole prompt is being added again every turn" % (total, p))
PY
VERDICTS="/tmp/ocoreai-probe22-$$.txt"

while IFS= read -r line; do
  case "$line" in
    COUNT\ OK\ *) probe_ok "one conversation key makes exactly one session row — ${line#COUNT OK }" ;;
    COUNTFAIL\ *) probe_fail "${line#COUNTFAIL } sessions for one session_id ($KEY) across 3 turns — a conversation must own one row to grow into" ;;
    TOTAL\ *)     probe_ok "session accounting is per message — ${line#TOTAL }" ;;
    TOTALFAIL\ *) probe_fail "${line#TOTALFAIL }" ;;
    ERR\ *)       probe_fail "$line" ;;
  esac
done < "$VERDICTS"
printf '%s\n' "$(grep '^      ' "$VERDICTS")" | grep . | sed 's/^/      /' || true

probe_section "does a message row hold its own tokens?"
SID="$(awk '/^SESSIONID /{print $2}' "$VERDICTS")"
rm -f "$VERDICTS"
if [ -z "$SID" ]; then
  probe_fail "no session id to read back — the token-size question was never asked"
else
  probe_api GET "/sessions/$SID/memory"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "GET /sessions/$SID/memory -> ${PROBE_STATUS:-no response}"
  else
    # The script arrives on stdin (heredoc), so the payload cannot also ride stdin — it goes
    # through a file. (`python3 -` consumes stdin for the script; a pipe on top of the
    # heredoc is silently the loser, which reads as "the endpoint returned junk".)
    MEM_JSON="/tmp/ocoreai-probe22-memjson-$$.json"
    printf '%s' "$PROBE_BODY" > "$MEM_JSON"
    python3 - "$MEM_JSON" > /tmp/ocoreai-probe22-mem-$$.txt <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
try:
    msgs = json.loads(raw).get("messages", [])
except Exception as e:
    print("ERR could not parse the memory window: %s" % e)
    sys.exit()
users = [m for m in msgs if m.get("role") == "user"]
if len(users) < 3:
    print("HOLDFAIL only %d user row(s) in the one session (expected the 3 turns to accumulate): %s" % (
        len(users), [m.get("content", "")[:24] for m in msgs]))
    sys.exit()
print("HOLD OK all %d turns accumulated in one session: %s" % (
    len(users), [m.get("content", "")[:30] for m in users]))
worst = None
for m in users:
    text, tokens = m.get("content") or "", m.get("token_count")
    if not isinstance(tokens, int):
        print("ERR a user row carries no token_count")
        sys.exit()
    ceiling = len(text) // 2 + 8
    if worst is None or tokens - ceiling > worst[0] - worst[1]:
        worst = (tokens, ceiling, text)
if worst[0] <= worst[1]:
    print("SIZE OK the largest user row costs token_count=%s for a %d-character message — its own size, not the turn's prompt" % (worst[0], len(worst[2])))
else:
    print("SIZEFAIL a %d-character user message is stored with token_count=%s — a row cannot cost more than its own content (~%d by the bytes heuristic)" % (len(worst[2]), worst[0], worst[1]))
PY
    while IFS= read -r line; do
      case "$line" in
        HOLD\ OK\ *) probe_ok "the conversation accumulates in that row — ${line#HOLD OK }" ;;
        HOLDFAIL\ *) probe_fail "${line#HOLDFAIL }" ;;
        SIZE\ *)     probe_ok "rows carry their own size — ${line#SIZE }" ;;
        SIZEFAIL\ *) probe_fail "${line#SIZEFAIL }" ;;
        ERR\ *)      probe_fail "$line" ;;
      esac
    done < /tmp/ocoreai-probe22-mem-$$.txt
    rm -f /tmp/ocoreai-probe22-mem-$$.txt /tmp/ocoreai-probe22-memjson-$$.json
  fi
fi

# A client sends the whole conversation on every request while `messages` rows are append-only.
# Turn 4 re-sends the three turns above with the real replies interleaved; if the persist hop
# inserts what is already written, this session grows by 8 rows instead of 2. Reading the row
# count after the turn is the only way to see it — the response itself says nothing about it.
probe_section "does a re-sent history get stored twice?"
if [ -z "${SID:-}" ]; then
  probe_fail "no session id to read back — the duplication question was never asked"
else
  BODY4="$(python3 - "$PROBE_MODEL" "$KEY" "$MAX_TOKENS" "$HISTORY" <<'PY'
import json, sys
model, key, max_tokens, hist_path = sys.argv[1:5]
with open(hist_path, encoding="utf-8") as fh:
    messages = json.load(fh)
messages.append({"role": "user", "content": "Reply with exactly the word DELTA."})
print(json.dumps({
    "model": model,
    "session_id": key,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "messages": messages,
}))
PY
)"
  probe_chat "$KEY" "$BODY4"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "the re-sent-history turn -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  else
    sleep 1
    probe_api GET "/sessions/$SID/memory"
    RES_JSON="/tmp/ocoreai-probe22-resend-$$.json"
    RES_VERDICT="/tmp/ocoreai-probe22-resend-verdict-$$.txt"
    printf '%s' "$PROBE_BODY" > "$RES_JSON"
    python3 - "$RES_JSON" "$HISTORY" > "$RES_VERDICT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    msgs = json.loads(fh.read()).get("messages", [])
with open(sys.argv[2], encoding="utf-8") as fh:
    prior_users = [m["content"] for m in json.load(fh) if m.get("role") == "user"]
users = [m.get("content") or "" for m in msgs if m.get("role") == "user"]
expected = len(prior_users) + 1
dupes = sorted({c for c in users if users.count(c) > 1})
if dupes:
    print("DUPFAIL the re-sent history was stored a second time: %s" % [d[:34] for d in dupes])
elif len(users) != expected:
    print("DUPFAIL %d user rows after %d accepted turns: %s" % (
        len(users), expected, [u[:34] for u in users]))
else:
    print("DUP OK %d turns on one key, %d user rows, nothing duplicated: %s" % (
        len(users), len(users), [u[:24] for u in users]))
PY
    while IFS= read -r line; do
      case "$line" in
        DUP\ OK\ *) probe_ok "a re-sent history lands once — ${line#DUP OK }" ;;
        DUPFAIL\ *) probe_fail "${line#DUPFAIL }" ;;
      esac
    done < "$RES_VERDICT"
    rm -f "$RES_JSON" "$RES_VERDICT"
  fi
fi
rm -f "$HISTORY"

# The Anthropic face is a second wire onto the same engine, and it carries its own conversation
# key (`metadata.session_id`, mapped by `toChatCompletionRequest`). Two turns on one key must
# land on ONE new session row that grew to hold both — before 10-21 this face wrote nothing at
# all, so an Anthropic-SDK conversation was invisible to `/sessions`, `/sessions/:id/memory`,
# `/sessions/search` and the GUI list while the OpenAI face above was remembered.
probe_section "does the Anthropic face keep one conversation too?"
MKEY="AMEMPROBE-$$"
probe_api GET "/sessions?limit=500"
IDS_BEFORE_M="$PROBE_BODY"

MTEXT1="Reply with exactly the word ZETA."
MTEXT2="Reply with exactly the word ETA."
MBODY1="$(python3 - "$PROBE_MODEL" "$MKEY" "$MAX_TOKENS" "$MTEXT1" <<'PY'
import json, sys
model, key, max_tokens, text = sys.argv[1:5]
print(json.dumps({
    "model": model,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "metadata": {"user_id": "probe-user", "session_id": key},
    "messages": [{"role": "user", "content": text}],
}))
PY
)"
probe_api POST /v1/messages "$MBODY1"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "POST /v1/messages (turn 1) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
else
  MREPLY1="$(probe_json "$PROBE_BODY" 'content.0.text')"
  MBODY2="$(python3 - "$PROBE_MODEL" "$MKEY" "$MAX_TOKENS" "$MTEXT1" "$MREPLY1" "$MTEXT2" <<'PY'
import json, sys
model, key, max_tokens, t1, r1, t2 = sys.argv[1:7]
messages = [{"role": "user", "content": t1}]
if r1.strip():
    messages.append({"role": "assistant", "content": r1})
messages.append({"role": "user", "content": t2})
print(json.dumps({
    "model": model,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "metadata": {"user_id": "probe-user", "session_id": key},
    "messages": messages,
}))
PY
)"
  probe_api POST /v1/messages "$MBODY2"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "POST /v1/messages (turn 2) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  else
    sleep 1
    MREPLY2="$(probe_json "$PROBE_BODY" 'content.0.text')"
    # Turn 3 goes out streaming with the whole history again: streaming has its own persist
    # call on this face, so it needs its own wire — the static gate can see the call exists,
    # only this can see the row grow.
    MBODY3="$(python3 - "$PROBE_MODEL" "$MKEY" "$MAX_TOKENS" "$MTEXT1" "$MREPLY1" "$MTEXT2" "$MREPLY2" <<'PY'
import json, sys
model, key, max_tokens, t1, r1, t2, r2 = sys.argv[1:8]
messages = [{"role": "user", "content": t1}]
if r1.strip():
    messages.append({"role": "assistant", "content": r1})
messages.append({"role": "user", "content": t2})
if r2.strip():
    messages.append({"role": "assistant", "content": r2})
messages.append({"role": "user", "content": "Reply with exactly the word THETA."})
print(json.dumps({
    "model": model,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "stream": True,
    "metadata": {"user_id": "probe-user", "session_id": key},
    "messages": messages,
}))
PY
)"
    probe_api POST /v1/messages "$MBODY3"
    if [ "${PROBE_STATUS:-}" != "200" ]; then
      probe_fail "POST /v1/messages (stream turn) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
    elif ! printf '%s' "$PROBE_BODY" | grep -q message_stop; then
      probe_fail "the stream turn never reached message_stop — nothing was there to persist: ${PROBE_BODY:0:200}"
    else
      probe_ok "the streaming Anthropic turn delivered message_stop"
      sleep 1
    fi
    probe_api GET "/sessions?limit=500"
    MJSON="/tmp/ocoreai-probe22-anth-$$.json"
    MVERDICT="/tmp/ocoreai-probe22-anth-verdict-$$.txt"
    printf '%s' "{\"after\": $PROBE_BODY, \"before\": $IDS_BEFORE_M}" > "$MJSON"
    python3 - "$MJSON" > "$MVERDICT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    doc = json.load(fh)
after, before = doc["after"], doc["before"]
ids_before = {r.get("id") for r in before if isinstance(r, dict)}
by_id = {r["id"]: r for r in after if isinstance(r, dict) and "id" in r}
new = [by_id[i] for i in sorted(set(by_id) - ids_before)]
if not new:
    print("ANTHFAIL two accepted /v1/messages turns wrote no session row — this face has no memory")
elif len(new) > 1:
    print("ANTHFAIL %d session rows for one metadata.session_id: %s" % (
        len(new), [(s.get("id"), s.get("message_count")) for s in new]))
else:
    s = new[0]
    print("ANTHROW %s" % s.get("id"))
    # Three turns (two non-stream, one streaming), the 2nd and 3rd re-sending history:
    # 3 user + 3 assistant rows on one row, nothing duplicated.
    if s.get("message_count") == 6:
        print("ANTH OK one row id=%s holds message_count=%s (3 user + 3 assistant, both response modes) token_count=%s" % (
            s.get("id"), s.get("message_count"), s.get("token_count")))
    else:
        print("ANTHFAIL one row id=%s holds message_count=%s, expected 6 (three turns, two re-sent, stored once)" % (
            s.get("id"), s.get("message_count")))
PY
    while IFS= read -r line; do
      case "$line" in
        ANTH\ OK\ *) probe_ok "one metadata.session_id makes one session row on the Anthropic face — ${line#ANTH OK }" ;;
        ANTHFAIL\ *) probe_fail "${line#ANTHFAIL }" ;;
      esac
    done < "$MVERDICT"
    MSID="$(awk '/^ANTHROW /{print $2}' "$MVERDICT")"
    if [ -n "${MSID:-}" ]; then
      probe_atexit "curl -s -m 5 -X DELETE \"$PROBE_BASE/sessions/$MSID\" > /dev/null 2>&1"
    fi
    rm -f "$MJSON" "$MVERDICT"
  fi
fi

# Leave the dev database as found: the rows this run made are evidence, not cruft. The id list
# is flattened at registration time — `probe_atexit` stores a string it later evals, so a
# multi-line command (or one with non-id digits glued on) dies with a syntax error at exit.
if [ -n "${SID:-}" ]; then
  probe_atexit "curl -s -m 5 -X DELETE \"$PROBE_BASE/sessions/$SID\" > /dev/null 2>&1"
fi

probe_summary "$PROBE_NAME"
