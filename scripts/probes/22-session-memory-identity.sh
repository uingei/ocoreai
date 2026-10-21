#!/usr/bin/env bash
# 22-session-memory-identity.sh — does one `session_id` become one session, and does a
# message row hold its own tokens?
#
# Why (P1 执行链/状态, measured 10-21 on this host): three `/v1/chat/completions` turns sent
# with the same `session_id` ("MEMPROBE-…") created **three** SQLite sessions, because
# `ChatHandler.persistConversation` resolves the row as `Int64(sessionID)` and creates a new
# session whenever the key is not an integer — which is every key a real client sends
# (UUIDs, `PROBE-…`), and nothing on the HTTP surface ever hands a client an integer to
# reuse. The conversation the engine keeps in its session pool therefore has no counterpart
# in session memory: `/sessions`, `/sessions/:id/memory`, `/sessions/search` and the GUI's
# session list see one snapshot per request instead of one conversation.
#
# Second measured fact, same hop: `persistConversation` apportions the turn's prompt over the
# user rows (`tokensPerMsg = promptTokens / userMsgCount`), so a 34-character user message
# was stored with `token_count: 705` — the whole rendered prompt of that turn, including the
# engine's own system prompt and template. The running total of those rows is what
# `SessionCompressor` compares against `tokenThreshold` (128k default) to decide when to
# prune, and `SessionView` shows it as a session's size, so history is charged repeatedly for
# tokens it was charged for already.
#
# Both are `probe_xfail open`: reproduced here, recorded in AGENTS.md § Open, and the line
# turns into XPASS (a failure) the day either is fixed — delete the xfail then. The assertions
# that make this run mean something (the turns landed, the rows appeared, the memory route
# answered) are hard gates.
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
for word in $TURN_WORDS; do
  body="$(python3 - "$PROBE_MODEL" "$KEY" "$MAX_TOKENS" "$word" <<'PY'
import json, sys
model, key, max_tokens, word = sys.argv[1:5]
print(json.dumps({
    "model": model, "session_id": key, "max_tokens": int(max_tokens), "temperature": 0.0,
    "messages": [{"role": "user", "content": "Reply with exactly the word %s." % word}],
}))
PY
)"
  probe_chat "$KEY" "$body"
  if [ "${PROBE_STATUS:-}" = "200" ]; then
    OK_TURNS=$(( OK_TURNS + 1 ))
    probe_note "turn $word 200 — prompt_tokens=$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  else
    probe_fail "turn $word -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  fi
done
if [ "$OK_TURNS" -eq 3 ]; then
  probe_ok "all 3 turns landed on one conversation key — the premise for counting what memory made of them"
else
  probe_fail "only $OK_TURNS/3 turns succeeded — identity could not be judged, this run proves nothing"
fi

# One verdict per line; the loop runs in this shell (a here-string, not a pipe) so every
# verdict it counts survives to the summary.
VERDICTS="$(python3 - "$IDS_BEFORE" "$PROBE_BODY" <<'PY'
import json, sys
before_raw, last_body = sys.argv[1], sys.argv[2]
try:
    before = json.loads(before_raw)
except Exception as e:
    print("ERR could not parse the /sessions snapshot before the turns: %s" % e)
    sys.exit()
ids_before = {r.get("id") for r in before if isinstance(r, dict)}
prompt = None
try:
    prompt = (json.loads(last_body).get("usage") or {}).get("prompt_tokens")
except Exception:
    pass
print("PRE %d sessions visible before, ids %s..%s, turn prompt_tokens=%s" % (
    len(ids_before), min(ids_before, default="-"), max(ids_before, default="-"), prompt))
PY
)"
printf '%s\n' "$VERDICTS" | grep '^PRE ' | sed 's/^PRE /  NOTE  /'

probe_api GET "/sessions?limit=500"
python3 - "$PROBE_BODY" "$IDS_BEFORE" "$KEY" > /tmp/ocoreai-probe22-$$.txt <<'PY'
import json, sys
after_raw, before_raw, key = sys.argv[1:4]
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
    print("ERR no new session row appeared after 3 accepted turns — session memory is not writing, so neither question below was answered")
    sys.exit()
print("SESS %d" % len(new))
for s in new:
    print("ROW id=%s message_count=%s token_count=%s" % (
        s.get("id"), s.get("message_count"), s.get("token_count")))
PY
NEW_COUNT="$(grep '^SESS ' "/tmp/ocoreai-probe22-$$.txt" | awk '{print $2}')"
ROWS_TXT="$(grep '^ROW ' "/tmp/ocoreai-probe22-$$.txt" | sed 's/^ROW /      /')"
rm -f "/tmp/ocoreai-probe22-$$.txt"

if [ -z "$NEW_COUNT" ]; then
  probe_fail "identity check produced no verdict (empty output) — a check that stays silent is not a check"
else
  printf '%s\n' "$ROWS_TXT" | grep . || true
  # One conversation key, three accepted turns => the honest answer is one session row.
  if [ "$NEW_COUNT" -eq 1 ]; then
    probe_xfail fixed "one conversation key now makes exactly one session row — §Open's identity item is closed: delete this xfail and the §Open entry"
  else
    probe_xfail open "$NEW_COUNT SQLite sessions for one session_id ($KEY) across 3 turns — a conversation has no session to grow into, so memory, FTS and the GUI session list see one snapshot per request"
  fi
fi

probe_section "does a message row hold its own tokens?"
FIRST_NEW="$(printf '%s\n' "$ROWS_TXT" | awk 'NR==1{gsub(/[^0-9]/,"",$1); print $1}')"
if [ -z "$FIRST_NEW" ]; then
  probe_fail "no session id to read memory from — the token-size question was never asked"
else
  probe_api GET "/sessions/$FIRST_NEW/memory"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "GET /sessions/$FIRST_NEW/memory -> ${PROBE_STATUS:-no response}"
  else
    MEM_VERDICT="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    msgs = json.loads(sys.argv[1]).get("messages", [])
except Exception as e:
    print("ERR could not parse the memory response: %s" % e)
    sys.exit()
users = [m for m in msgs if m.get("role") == "user"]
if not users:
    print("ERR the session's memory window holds no user message — nothing was measured")
    sys.exit()
m = users[0]
text, tokens = m.get("content") or "", m.get("token_count")
print("MEM %s %s" % (tokens, len(text)))
PY
)"
    case "$MEM_VERDICT" in
      ERR\ *) probe_fail "$MEM_VERDICT" ;;
      MEM\ *)
        set -- ${MEM_VERDICT#MEM }
        MEM_TOKENS="$1"; MEM_CHARS="$2"
        # A row for a message of N characters cannot cost the whole turn's prompt: that
        # number includes the engine's own system prompt and chat template, and charging it
        # per message re-bills history every turn (which is what feeds the 128k prune rule).
        if [ "${MEM_TOKENS:-0}" -gt $(( MEM_CHARS / 2 + 8 )) ]; then
          probe_xfail open "a $MEM_CHARS-character user message is stored with token_count=$MEM_TOKENS — the row carries the turn's whole prompt, not its own size (apportioned by persistConversation), so session totals and the prune threshold are charged for history repeatedly"
        else
          probe_xfail fixed "the user row now costs $MEM_TOKENS for $MEM_CHARS characters — per-message accounting landed: delete this xfail and the §Open entry"
        fi
        ;;
      *) probe_fail "token-size check produced no verdict (empty output)" ;;
    esac
  fi
fi

# Leave the dev database as found: the snapshots this run made are evidence, not cruft.
# The id list is flattened to one line at registration time — `probe_atexit` stores a string
# it later evals, and a multi-line command there dies with "syntax error near unexpected
# token" (measured: `tr -cd '0-9\n'` over the row dump left the digits of
# `message_count`/`token_count` glued to the id, producing 19372707 as a "session id").
CLEAN_IDS="$(printf '%s\n' "$ROWS_TXT" | sed -nE 's/.*id=([0-9]+).*/\1/p' | tr '\n' ' ')"
if [ -n "${CLEAN_IDS// /}" ]; then
  probe_atexit "for sid in $CLEAN_IDS; do curl -s -m 5 -X DELETE \"$PROBE_BASE/sessions/\$sid\" > /dev/null 2>&1; done"
fi

probe_summary "$PROBE_NAME"
