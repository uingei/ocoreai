#!/usr/bin/env bash
# 55-connect-harness-launch.sh — does `ocoreai connect` detect, trust only what it probes, and
# hand the measured env contract to the child exactly?
#
# ### Why
# `docs/agent/comparator-consensus.md` § The harness side counts nine of twelve serving trees
# shipping harness-launch product code; probe 53 proved the WIRE route with a real claude loop,
# but nothing pinned our own CLI face: does detection report the binary the user's PATH actually
# resolves, does the server count as ours only after `/v1/models` answers, are the env values
# byte-exact, and is the child's exit code forwarded unchanged? Those are the four claims
# `connect` prints, and each gets an exact-value assertion here.
#
# ### What makes it a proof rather than a demo
# The subject is a stand-in, and the probe says so: §3 execs a fake `claude` that records its
# environment and exit 3s. That is deliberate — the claim under test is the mechanism (detect,
# probe, exact env, exit forwarding), while the claim "a harness ran real turns on us" belongs
# to probe 53, which needs weights and a real CLI. A stand-in that verifies bytes prices the
# mechanism at k=1 and stays in the sandbox tier.
#
# ### Premises (each a red with a remedy, never a skip)
# The resolved `ocoreai` binary (OCOREAI_BIN or the newest build) and a scripted-engine boot —
# no checkpoint, no Metal for §1–§3.
#
# Fails when: a classifier token stops being refused with 64, detection reports a path its own
# PATH fixture did not provide, a launch proceeds while the server line says it must not, the
# env the child sees differs byte-for-byte, or a child exit code is swallowed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="connect-harness-launch"

BIN="$(probe_resolve_binary)" || probe_fail "no ocoreai binary to drive connect" " set OCOREAI_BIN"

SCRATCH="$(mktemp -d -t ocoreai-connect-XXXXXX)"
probe_atexit "rm -rf '$SCRATCH'"
mkdir -p "$SCRATCH/bin" "$SCRATCH/emptybin"
cat > "$SCRATCH/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$ANTHROPIC_BASE_URL|$ANTHROPIC_API_KEY|$*" > "$OCOREAI_CONNECT_RECORD"
exit 3
SH
chmod +x "$SCRATCH/bin/claude"

# ── §1 the classifier answers before anything runs ─────────────────────────────────────────────
probe_section "§1 argv refusals exit 64 and name the token (no server, no child)"
out="$("$BIN" connect bogus 2>&1)"; rc=$?
if [ "$rc" -eq 64 ] && printf '%s' "$out" | grep -q '"bogus"' \
   && printf '%s' "$out" | grep -q 'claude-code'; then
  probe_ok "unknown harness refused 64, naming the token and the supported set"
else
  probe_fail "unknown harness got rc=$rc: $out" " a caller typo must not fall through to the GUI branch"
fi
out="$("$BIN" connect claude-code --bogus-flag 2>&1)"; rc=$?
if [ "$rc" -eq 64 ] && printf '%s' "$out" | grep -q -- '--bogus-flag'; then
  probe_ok "an unknown flag is refused named, like serve refuses its arguments"
else
  probe_fail "unknown flag got rc=$rc: $out" " silently ignored flags are the failure serve already refuses"
fi
"$BIN" connect --help >/dev/null 2>&1 && probe_ok "connect --help exits 0" \
  || probe_fail "connect --help did not exit 0" " usage is the promise channel; it must answer"

# ── §2 detection reports its own fixture, or says absent ──────────────────────────────────────
probe_section "§2 detection finds exactly what PATH fixture provides (dead server port)"
record="$SCRATCH/record.txt"
out="$(OCOREAI_CONNECT_RECORD="$record" OCOREAI_PORT=1 PATH="$SCRATCH/bin" \
  "$BIN" connect claude-code --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "harness: found $SCRATCH/bin/claude"; then
  probe_ok "dry-run names the fixture binary by exact absolute path, exit 0"
else
  probe_fail "dry-run with PATH fixture got rc=$rc: $out" " detection must report the same binary the shell would exec"
fi
printf '%s' "$out" | grep -q 'start it with `ocoreai serve`' \
  && probe_ok "the plan's server line carries the remedy for a dead listener" \
  || probe_fail "dry-run omitted the serve remedy: $out" " a plan without its remedy is a promise, not a plan"
[ ! -f "$record" ] && probe_ok "dry-run exec'd nothing (the fixture left no record)" \
  || probe_fail "dry-run exec'd the harness — the record file exists" " --dry-run must not touch anything, that is its only job"
out="$(OCOREAI_PORT=1 PATH="$SCRATCH/emptybin" "$BIN" connect claude-code --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'no claude on PATH'; then
  probe_ok "an absent harness is reported as absent, still exit 0 for the plan"
else
  probe_fail "absent-harness dry-run got rc=$rc: $out" " honesty about a missing subject is the claim, not an error path"
fi

# ── §3 the live bridge: trusted only after /v1/models answered; env and exit are exact ─────────
probe_section "§3 launch hands the exact contract and forwards the child's exit code"
SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
cat > "$SCRIPT_FILE" <<'JSON'
{"segments": ["ok"], "finishReason": "eos", "promptTokens": 1, "generatedTokens": 1}
JSON
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"
probe_boot
probe_atexit "unset OCOREAI_SCRIPTED_ENGINE; rm -f '$SCRIPT_FILE'"

rm -f "$record"
out="$(OCOREAI_CONNECT_RECORD="$record" OCOREAI_HOST=127.0.0.1 OCOREAI_PORT="$PROBE_PORT" \
  PATH="$SCRATCH/bin:/usr/bin:/bin" env -u ANTHROPIC_API_KEY "$BIN" connect claude-code -- --version 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then
  probe_ok "the child's exit 3 is forwarded unchanged (neither swallowed nor reinterpreted)"
else
  probe_fail "launch got rc=$rc: $out" " the harness's own verdict must reach the caller verbatim"
fi
if [ -f "$record" ] && [ "$(cat "$record")" = "$PROBE_BASE|ocoreai-local|--version" ]; then
  probe_ok "env contract exact: ANTHROPIC_BASE_URL=\$PROBE_BASE, synthesized key, args verbatim"
else
  probe_fail "child recorded '$(cat "$record" 2>/dev/null || echo NOTHING)'" \
    " expected exactly '$PROBE_BASE|ocoreai-local|--version' — probe 53's whole route rides these bytes"
fi
printf '%s' "$out" | grep -qF "server:  ours at $PROBE_BASE (/v1/models answered)" \
  && probe_ok "the server is declared ours only because /v1/models answered that shape" \
  || probe_fail "live dry-run face missing the ours-line: $out" " trust after probe, never by port number"

# A caller-supplied key is kept, not overwritten: severing it is probe 53's burden of proof, not
# the user-invoked route's.
rm -f "$record"
out="$(OCOREAI_CONNECT_RECORD="$record" OCOREAI_HOST=127.0.0.1 OCOREAI_PORT="$PROBE_PORT" \
  PATH="$SCRATCH/bin:/usr/bin:/bin" ANTHROPIC_API_KEY='user-key' "$BIN" connect claude-code 2>&1)"
if [ -f "$record" ] && [ "$(cat "$record")" = "$PROBE_BASE|user-key|" ]; then
  probe_ok "a caller-supplied API key reaches the child unchanged (nothing of the user's is overwritten)"
else
  probe_fail "key passthrough recorded '$(cat "$record" 2>/dev/null || echo NOTHING)'" \
    " connect may add to the caller's environment, never replace it"
fi

probe_summary "$PROBE_NAME"
