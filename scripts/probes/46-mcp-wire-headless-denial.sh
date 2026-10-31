#!/usr/bin/env bash
# 46-mcp-wire-headless-denial.sh — a channel that cannot answer an approval must be refused,
# not left waiting for a GUI that is not on its channel.
#
# Measured 10-31 on this host against a live `serve` with the shipped default policy
# (`interactive`), booting no model:
#   initialize                 → answered
#   tools/call write_file      → nothing for 12 s (`curl -m 12` → status 000), and the file was
#                                not written either.
# The call had parked on `ApprovalBroker`, waiting for the in-app GUI's approval card — a surface
# that does not exist on the wire. Three of the four tool-bearing lanes (`chat/completions`,
# `completions`, `anthropic/messages`) declare `headless: true` and are refused at the gate
# (codex `codex-rs/exec/src/lib.rs:566`); `/mcp` never declared its channel, so it was the one
# lane where an agent harness could hang forever with no error, no timeout and no way out.
#
# Why the legs are these three:
#   1) a handshake that answers is the positive control — a surface that answered nothing would
#      otherwise look like a fixed hang when it was only a dead server;
#   2) the destructive call must come back as an MCP error result that names the channel, inside a
#      bounded budget, and must not touch the file (the refusal must not be a lie either way);
#   3) a non-destructive tool on the SAME lane must still run — otherwise "refused" would only mean
#      the surface was switched off, which is a different bug.
# The broker holding no orphan row is asserted in MCPServerHeadlessGateTests: no wire surface
# publishes pending approvals, so it cannot be measured from here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="mcp-wire-headless-denial"

# The pin in `_lib.sh` is `auto`, which never asks and would make this probe vacuous: the defect
# only exists where the policy asks. Set before `probe_boot`, which inherits an outer value.
export OCOREAI_APPROVAL_POLICY=interactive

probe_boot

auth_args=()
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi

OUT="$(mktemp)"
# Short on purpose. `ApprovalBroker` fail-closes any `.ask` whose arguments exceed the 80-grapheme
# review surface (codex #41159), and a `mktemp -d` path blows that budget: measured here, the call
# then gets refused for being unreviewable and never reaches the channel branch this probe is about.
TARGET="/tmp/oc46-parked.txt"
probe_atexit 'rm -f "$OUT" "$TARGET"'

# One POST, bounded. The answer is the whole verdict, so the deadline is the instrument: a parked
# handler returns 000 and that IS the defect (`curl` exit ≠ 0 with no body).
post() {  # post <deadline-s> <json>
  local code
  : > "$OUT"   # a timed-out write leaves the previous leg's body behind, which then lies twice
  code="$(curl -sS -m "$1" -X POST "$PROBE_BASE/mcp" ${auth_args[@]+"${auth_args[@]}"} \
    -H 'Content-Type: application/json' --data "$2" -o "$OUT" -w '%{http_code}' 2>/dev/null)" \
    || code="000"
  printf '%s' "${code:-000}"
}
rpc() {  # rpc <id> <method> <params-json>
  printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}' "$1" "$2" "$3"
}

# Bodies are assembled in plain variables, never nested inside `$( … "$(…)" … )`: the stock macOS
# bash (3.2) splits an escaped-quote string there instead of quoting it, which sends a torn JSON
# body and gets a parse error back — the probe would then be measuring its own harness.

probe_section "1) positive control — the handshake answers, so a later silence means silence"
INIT_PARAMS='{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe46","version":"0"}}'
INIT_BODY="$(rpc 1 initialize "$INIT_PARAMS")"
code="$(post 15 "$INIT_BODY")"
if [ "$code" = "200" ] && grep -q '"serverInfo"' "$OUT"; then
  probe_ok "initialize answered on /mcp — the surface is live, so leg 2 measures a hang and" \
    " not a dead server"
else
  probe_fail "initialize returned HTTP $code with $(wc -c < "$OUT") bytes — the probe is blind" \
    " and cannot tell a refusal from a hang"
fi
curl -sS -m 5 -o /dev/null ${auth_args[@]+"${auth_args[@]}"} -X POST "$PROBE_BASE/mcp" \
  -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"notifications/initialized"}'

probe_section "2) a destructive call is refused on this channel, and nothing is written"
CALL_PARAMS="$(printf '{"name":"write_file","arguments":{"path":"%s","content":"parked"}}' "$TARGET")"
CALL_BODY="$(rpc 2 tools/call "$CALL_PARAMS")"
code="$(post 15 "$CALL_BODY")"
if [ "$code" = "000" ]; then
  probe_fail "write_file on /mcp still parks — 15 s and no answer, which is the defect: the" \
    " wire lane did not declare that nobody on it can adjudicate"
elif grep -q '"isError":true' "$OUT" && grep -qi 'headless' "$OUT"; then
  probe_ok "refused inside the budget, naming the channel: $(head -c 200 "$OUT")"
else
  probe_fail "HTTP $code without a channel-naming refusal: $(head -c 200 "$OUT")"
fi
if [ -e "$TARGET" ]; then
  probe_fail "the destructive tool WROTE $TARGET — a refusal that executed the call is worse than" \
    " a hang, because the caller cannot tell them apart"
else
  probe_ok "the target file was not created — the refusal is honest either way"
fi

probe_section "3) a non-destructive tool on the same lane still runs"
ECHO_PARAMS='{"name":"echo","arguments":{"message":"wire-still-works"}}'
ECHO_BODY="$(rpc 3 tools/call "$ECHO_PARAMS")"
code="$(post 15 "$ECHO_BODY")"
if [ "$code" = "200" ] && grep -q '"isError":false' "$OUT" && grep -q 'wire-still-works' "$OUT"; then
  probe_ok "echo ran on the same lane — the refusal is scoped to what needs an adjudicator," \
    " not a switched-off surface"
else
  probe_fail "echo did not run on /mcp (HTTP $code): $(head -c 200 "$OUT") — the lane was" \
    " disabled instead of the prompt being refused"
fi

probe_summary "$PROBE_NAME"
