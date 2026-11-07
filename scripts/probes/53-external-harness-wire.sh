#!/usr/bin/env bash
# 53-external-harness-wire.sh — can a real coding harness run its own loop on our wire alone?
#
# ### Why
# `docs/agent/comparator-consensus.md` measures 11 of the 12 serving trees wiring at least one external
# agent harness to their own endpoint (ollama `cmd/launch/claude.go:15`, mlx-serve `CLILauncher.swift:4`);
# we were the twelfth — and probe 40, our own harness-consumer proof, drives the loop *ourselves* over
# `/v1/chat/completions`. Nothing here proved the other direction: that a third-party harness, with its
# own agent loop, its own tool implementations and its own ~18 KB system prompt, can point at this server
# and finish a real multi-turn job. That is the claim the rung makes, and it is only true if a harness
# that owes us nothing runs green.
#
# ### What makes it a proof rather than a demo
# The cloud is severed before the harness starts: every credential variable the CLI could use for a
# fallback is unset, and the only base URL it gets is ours, with a fake key — so the only way the run
# can succeed is through `/v1/messages`. The deliverable is an exact value planted on disk and never
# named in the task text, judged by a verifier whose negative control (§1) must reject a wrong answer
# first. Wire truth is asserted from the server's own log, not inferred from the exit code: at least two
# `Assembled prompt` lines means the harness really ran a multi-turn loop through the engine.
#
# ### Premises (each a red with a remedy, never a skip)
# A `claude` CLI on PATH (or `$OCOREAI_PROBE53_BIN`), and a booted server with a ready chat checkpoint.
# An absent harness is a missing subject, which the house treats like probe 41's absent DMG: a green
# that never had one proves nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="external-harness-wire"

HARNESS="${OCOREAI_PROBE53_BIN:-$(command -v claude || true)}"

SCRATCH="$(mktemp -d -t ocoreai-harnesswire-XXXXXX)"
probe_atexit "rm -rf '$SCRATCH'"
# One VALUE per run so two runs of one tree cannot share an answer file; the task names the file,
# never the token, so the only route to it is the harness actually reading the seed off disk.
VALUE="$(openssl rand -hex 8 2>/dev/null || date +%N)$(openssl rand -hex 8 2>/dev/null || date +%N)"

verify_answer() {  # $1 = file expected to hold exactly the token
  [ -f "$1" ] || return 1
  [ "$(tr -d '[:space:]' < "$1")" = "$VALUE" ]
}

# ── §1 the instrument (no weights, no server, no harness) ──────────────────────────────────────
probe_section "§1 the verifier bites (no server)"
printf '%s\n' "deadbeefdeadbeef" > "$SCRATCH/wrong.txt"
if verify_answer "$SCRATCH/wrong.txt"; then
  probe_fail "the verifier ACCEPTED a wrong token" \
    " then every §2 pass would be measuring the checker, not the harness"
else
  probe_ok "verifier rejects a wrong deliverable (negative control bites)"
fi
printf '  %s \n' "$VALUE" > "$SCRATCH/right.txt"
if verify_answer "$SCRATCH/right.txt"; then
  probe_ok "verifier accepts the right token despite stray whitespace (no false red)"
else
  probe_fail "verifier rejected a CORRECT deliverable" \
    " the instrument is broken, so §2 could only ever report failure"
fi

# ── §2 the harness, on our wire only ───────────────────────────────────────────────────────────
probe_section "§2 a real harness running its own loop through /v1/messages"
if [ -z "$HARNESS" ]; then
  probe_fail "no claude CLI on PATH (nor \$OCOREAI_PROBE53_BIN)" \
    " the subject of the claim is absent, so nothing was measured — install the harness or name its" \
    " binary; a skip here would let a tree pass by having no consumer"
fi
probe_ok "harness: $HARNESS ($("$HARNESS" --version 2>/dev/null | head -1))"

probe_boot

# Which checkpoint answers is a condition of the verdict (same rule as probe 40): pin with
# OCOREAI_PROBE_MODEL or take the first ready CHAT model — embeddings are skipped because the
# list order would otherwise hand this claim to a model that cannot answer at all.
PIN="${OCOREAI_PROBE_MODEL:-}"
MODEL="$(curl -sS -m 20 "$PROBE_BASE/v1/models" 2>/dev/null | python3 -c '
import json, sys
pin = sys.argv[1]
try:
    data = json.load(sys.stdin).get("data", [])
except Exception:
    data = []
ready = [m.get("id", "") for m in data
         if str(m.get("state", "ready")) == "ready" and "embedding" not in m.get("id", "").lower()]
print((pin if pin in ready else "") if pin else (ready[0] if ready else ""))
' "$PIN" 2>/dev/null || true)"
if [ -n "$PIN" ] && [ "$MODEL" != "$PIN" ]; then
  probe_fail "OCOREAI_PROBE_MODEL=$PIN is not a ready chat checkpoint on this server" \
    " the subject was named and is absent — this probe does not fall back, the verdict is about" \
    " the checkpoint it names"
fi
[ -n "$MODEL" ] || probe_fail "no ready chat checkpoint on $PROBE_BASE" \
  " a task-success claim is a claim about a model; with none resident nothing was measured"

printf '%s\n' "$VALUE" > "$SCRATCH/note.txt"
rm -f "$SCRATCH/answer.txt"

# Cloud severance, then the one base URL: unset every credential the CLI could spend on a provider
# fallback (env -u also defeats a shell-exported one), so success has exactly one possible source.
OUT="$(cd "$SCRATCH" && env \
  -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BEARER_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
  ANTHROPIC_BASE_URL="$PROBE_BASE" \
  ANTHROPIC_API_KEY="probe-local-key" \
  ANTHROPIC_MODEL="$MODEL" \
  ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
  "$HARNESS" -p "Read the file note.txt in the current directory. Write ONLY the hex value it contains (nothing else) to answer.txt in the same directory." \
    --output-format json --dangerously-skip-permissions --no-session-persistence \
  < /dev/null 2>"$SCRATCH/harness.err")"
RC=$?
TURNS="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("num_turns","?"))' 2>/dev/null || echo "?")"
probe_note "§2 harness: exit $RC on $MODEL, num_turns=$TURNS, stderr $(wc -c < "$SCRATCH/harness.err" | tr -d ' ') bytes"

# Wire truth from the engine's own words — the exit code proves the harness is happy, only the
# server log proves who served it. One line would be a single request; a loop is two or more.
SERVED="$(grep -c "Assembled prompt" "$PROBE_LOG" 2>/dev/null || echo 0)"
probe_note "§2 wire truth: $SERVED 'Assembled prompt' line(s) in the server log:"
grep "Assembled prompt" "$PROBE_LOG" 2>/dev/null | tail -2 | sed 's/^/        /'

if [ "$SERVED" -lt 2 ]; then
  probe_fail "the harness finished (exit $RC) but the engine assembled a prompt $SERVED time(s)" \
    " a multi-turn job through our wire cannot fit in fewer — the harness answered some other way," \
    " which is exactly the drift this probe exists to catch"
elif verify_answer "$SCRATCH/answer.txt"; then
  probe_ok "a third-party harness, cloud-severed, completed the job on our wire alone: answer.txt" \
    " holds the exact token ($SERVED engine-served turns, checkpoint $MODEL)"
else
  probe_fail "answer.txt is wrong or absent (want=$VALUE got=$(cat "$SCRATCH/answer.txt" 2>/dev/null || echo none))" \
    " the harness ran $SERVED turn(s) through the engine but did not deliver the seeded value —" \
    " read the harness stderr and the log lines above before blaming the model"
fi

probe_summary "$PROBE_NAME"
