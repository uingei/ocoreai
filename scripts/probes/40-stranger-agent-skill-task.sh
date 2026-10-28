#!/usr/bin/env bash
# 40-stranger-agent-skill-task.sh — can a fresh agent finish a real task from only the skill?
#
# ### Why
# `skills/ocoreai/` is the artefact another harness reads to drive `/v1`, and probe 39 proves every
# documented call in it answers. That is not the rung's claim. The claim is that an agent whose *only*
# knowledge of this server is the published artefact completes a real job. A skill can be perfectly
# accurate and still undiscoverable, badly ordered, or too long for the model that has to act on it —
# probe 39 cannot see any of that, because it executes the artefact instead of being read by it. This
# is the instrument `docs/agent/long-horizon-goal.md` § Rung zero names for the wedge, and the only one
# here that measures the artefact the way a stranger's harness will.
#
# ### What makes it a proof rather than a demo
# The server is seeded with a note: a searchable KEY plus a VALUE generated per run. The task names the
# KEY and never the VALUE, so the only route to the answer is a live call chain — discover the search
# surface in the artefact, query it, read the snippet, write the file. `audit` enforces that structure
# (a task text that leaks the VALUE, a route, a method+path pair or a query parameter fails the run),
# and §1 carries a negative control: a WRONG deliverable must be rejected, because a lenient verifier
# would turn every §2 green into a measurement of the checker.
#
# ### Tiers
#   §1 (any host, no weights, no server) — the two parts that decide the verdict are pure functions of
#      files, so they are testable everywhere: the injection (artefact verbatim, over a byte floor) and
#      the verifier. The live tier runs the same code, so instrument and measurement cannot drift.
#   §2 (needs a ready checkpoint) — premise first: the note must be storable and retrievable by the
#      server's own search before any claim about an agent finding it. Then one agent turn: system =
#      the artefact, user = the task, tools = the server's own `exec_command` declaration fetched from
#      `GET /v1/tools` (never a local copy of a schema).
#
# ### Honesty
# Prints the injected byte count, the checkpoint judged, and the loop's finish reason — a task-success
# figure without those three is not reproducible. Where a premise cannot be established (no Metal, no
# ready checkpoint, storage that did not keep the note) the tier says WHY and reports known-open; it
# never reports a pass it did not measure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="stranger-agent-skill-task"

SKILL_DIR="$PROBE_REPO_ROOT/skills/ocoreai"
HARNESS="$HERE/_skill_task_harness.py"
# A declaration, not a mute button: flip to 1 only when a measured run shows the capability is
# genuinely absent, so the probe reports it as known-open instead of as a claim going red.
KNOWN_OPEN="${OCOREAI_PROBE40_KNOWN_OPEN:-0}"

SCRATCH="$(mktemp -d -t ocoreai-skilltask-XXXXXX)"
probe_atexit "rm -rf '$SCRATCH'"
KEY="skillnote$(openssl rand -hex 3 2>/dev/null || date +%s)"
VALUE="sksecret$(openssl rand -hex 5 2>/dev/null || date +%N)"

# ── §1 does the instrument bite? ────────────────────────────────────────────────────────────────
probe_section "§1 the instrument (no weights, no server)"
for f in "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/wire.md" "$HARNESS"; do
  if [ ! -f "$f" ]; then
    probe_fail "$f is absent" " the artefact or its harness vanished, so nothing downstream can be" \
      " measured — build the tree and re-run rather than trusting the rest of this output"
    probe_summary "$PROBE_NAME"
  fi
done

TASK_TMPL="$SCRATCH/task.template"
cat > "$TASK_TMPL" <<'EOF'
A local HTTP server is running on this machine at __BASE_URL__ . You have documentation for it above,
and nothing else.

That server keeps a note. Its text begins with the token __KEY__ .

Find that note using the server itself, and write the secret token contained in it to __OUT__ . Use
your shell tool to do the work — do not guess, and do not stop at describing what you would do.
EOF
# §1 audits the shape with a stand-in URL: the live tier renders the port it actually got, so a
# hard-coded base here would point the agent at a server that does not exist and blame the agent.
sed -e "s|__BASE_URL__|http://127.0.0.1:8080|g" -e "s|__KEY__|$KEY|g" \
    -e "s|__OUT__|$SCRATCH/note.txt|g" "$TASK_TMPL" > "$SCRATCH/task.audit"

if ! python3 "$HARNESS" audit --skill-dir "$SKILL_DIR" --task-file "$SCRATCH/task.audit" \
    --min-artefact-bytes 12000 --nonce "$VALUE" > "$SCRATCH/audit.txt" 2>&1; then
  probe_fail "the injection audit refuses to pass: $(cat "$SCRATCH/audit.txt")" \
    " either the artefact shrank below the size the claim is about, or the task text now hands the" \
    " agent what it is supposed to discover"
else
  probe_ok "$(cat "$SCRATCH/audit.txt") — artefact whole, task names no route and no answer"
fi

printf '%s\n' "sksecret-notthe-realvalue" > "$SCRATCH/wrong.txt"
if python3 "$HARNESS" verify --expect "$VALUE" --file "$SCRATCH/wrong.txt" \
    > "$SCRATCH/v1.txt" 2>&1; then
  probe_fail "the verifier ACCEPTED a wrong deliverable: $(cat "$SCRATCH/v1.txt")" \
    " so every §2 pass from here on would be measuring the checker, not the agent"
else
  probe_ok "verifier rejects a wrong token (negative control bites)"
fi
printf '%s\n' "the note says $VALUE" > "$SCRATCH/right.txt"
if python3 "$HARNESS" verify --expect "$VALUE" --file "$SCRATCH/right.txt" \
    > "$SCRATCH/v2.txt" 2>&1; then
  probe_ok "verifier accepts a deliverable that carries the token (no false red)"
else
  probe_fail "verifier rejected a CORRECT deliverable: $(cat "$SCRATCH/v2.txt")" \
    " the instrument is broken, so §2 could only ever report failure"
fi

# ── §2 the real agent ───────────────────────────────────────────────────────────────────────────
probe_section "§2 a fresh agent, given only the artefact, against a live server"
PORT="$(probe_free_port)"
BASE="http://127.0.0.1:${PORT}"
LOG="$(mktemp -t ocoreai-stranger-XXXXXX).log"
WS="$SCRATCH/ws"
mkdir -p "$WS"
OCOREAI_ENABLE_HTTP=1 OCOREAI_HOST=127.0.0.1 OCOREAI_PORT="$PORT" OCOREAI_APPROVAL_POLICY=auto \
  OCOREAI_WORKSPACE="$WS" "$(probe_resolve_binary)" serve < /dev/null > "$LOG" 2>&1 &
SPID=$!
probe_atexit "kill -TERM $SPID 2>/dev/null || true"

READY=1
waited=0
code=000
while [ "$waited" -lt "${OCOREAI_READY_TIMEOUT:-240}" ]; do
  kill -0 "$SPID" 2>/dev/null || break
  code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && break
  sleep 1; waited=$(( waited + 1 ))
done
if ! kill -0 "$SPID" 2>/dev/null || [ "$code" != "200" ]; then
  READY=0
  probe_note "§2 skipped — the real engine never became ready within ${waited}s:"
  tail -3 "$LOG" | sed 's/^/        /'
  probe_xfail open "§2 unmeasured on this host: no live engine, so the artefact was never read by" \
    " a model (run outside the agent sandbox to judge it)"
else
  probe_ok "/health 200 after ${waited}s (real engine, nothing scripted, nothing replayed)"
fi

MODEL=""
if [ "$READY" = "1" ]; then
  MODEL="$(curl -sS -m 20 "$BASE/v1/models" 2>/dev/null | python3 -c '
import json,sys
try: data = json.load(sys.stdin).get("data", [])
except Exception: data = []
for m in data:
    if str(m.get("state","ready")) == "ready":
        print(m.get("id","")); break
' 2>/dev/null || true)"
  if [ -z "$MODEL" ]; then
    READY=0
    probe_note "§2 skipped — /v1/models reports no ready checkpoint; task success is a claim about a" \
      " model, and with none resident there is nothing to judge"
    probe_xfail open "§2 unmeasured: no resident checkpoint"
  fi
fi

if [ "$READY" = "1" ]; then
  BACKEND="$(curl -sS -m 20 "$BASE/v1/capabilities" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("engineBackend",""))' 2>/dev/null || true)"
  probe_note "§2 backend=$BACKEND model=$MODEL"
  SEED_CODE="$(curl -sS -m 180 -o "$SCRATCH/seed.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"model\":\"$MODEL\",\"session_id\":\"skillprobe-seed-$KEY\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Remember this note verbatim and reply OK: $KEY $VALUE\"}]}" \
    "$BASE/v1/chat/completions" 2>/dev/null || echo 000)"
  SEARCH="$(curl -sS -m 30 "$BASE/sessions/search?q=$KEY&limit=5" 2>/dev/null || true)"
  case "$SEARCH" in
    *"$VALUE"*)
      probe_ok "premise: the note is stored and the server's own search returns the secret token"
      ;;
    *)
      READY=0
      probe_note "premise FAILED — seed HTTP $SEED_CODE, search answered: ${SEARCH:0:220}"
      probe_xfail open "§2 cannot run: the stored note is not retrievable, so asking an agent to find" \
        " it measures the build's storage, not the artefact"
      ;;
  esac
fi

if [ "$READY" = "1" ]; then
  sed -e "s|__BASE_URL__|$BASE|g" -e "s|__KEY__|$KEY|g" -e "s|__OUT__|$SCRATCH/note.txt|g" \
    "$TASK_TMPL" > "$SCRATCH/task.live"
  curl -sS -m 30 "$BASE/v1/tools" -o "$SCRATCH/tools.json" 2>/dev/null || true
  if ! python3 "$HARNESS" prompt \
      --skill-dir "$SKILL_DIR" --task-file "$SCRATCH/task.live" --out "$SCRATCH/body.json" \
      --model "$MODEL" --session "skillprobe-agent-$KEY" \
      --tools-file "$SCRATCH/tools.json" --only-tools exec_command --max-tokens 900 \
      > "$SCRATCH/prompt.txt" 2>&1; then
    probe_fail "could not assemble the agent request: $(cat "$SCRATCH/prompt.txt")" \
      " the server's own tool list did not yield the declaration the task depends on"
  else
    probe_note "§2 injection: $(cat "$SCRATCH/prompt.txt")"
    AGENT_CODE="$(curl -sS -m 420 -o "$SCRATCH/agent.json" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' --data @"$SCRATCH/body.json" \
      "$BASE/v1/chat/completions" 2>/dev/null || echo 000)"
    DIAG="$(python3 - "$SCRATCH/agent.json" <<'PY' 2>/dev/null || echo "answer=unparseable"
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("answer=unparseable"); raise SystemExit
c = (d.get("choices") or [{}])[0]
msg = c.get("message") or {}
content = msg.get("content")
if isinstance(content, list):
    content = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
print("finish=%s tool_calls_echoed=%d answer=%r" % (
    c.get("finish_reason"), len(msg.get("tool_calls") or []), (content or "")[:160].replace("\n", " ")))
PY
)"
    probe_note "§2 agent turn: HTTP $AGENT_CODE $DIAG"
    if python3 "$HARNESS" verify --expect "$VALUE" --file "$SCRATCH/note.txt" \
        > "$SCRATCH/verdict.txt" 2>&1; then
      probe_ok "a fresh agent holding only skills/ocoreai/ retrieved the secret token on $MODEL"
    elif [ "$KNOWN_OPEN" = "1" ]; then
      probe_xfail open "$(cat "$SCRATCH/verdict.txt") — $DIAG"
    else
      probe_fail "$(cat "$SCRATCH/verdict.txt")" \
        " the artefact did not carry a real agent to the answer on $MODEL ($DIAG): either the skill" \
        " does not make the search surface findable, or the loop does not act on it"
    fi
  fi
fi

probe_summary "$PROBE_NAME"
