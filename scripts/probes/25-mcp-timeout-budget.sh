#!/usr/bin/env bash
# 25-mcp-timeout-budget.sh — is an external MCP server's response budget the number this
# server publishes, and does a bad number come back as an answer instead of a hang?
#
# ### What was measured on 10-21 (before the fix, this host)
# `MCPBridgeConfig` carried a documented "external server response timeout" knob (default 10)
# with **zero consumers**: `git grep serverTimeoutSeconds -- Sources` returned the declaration,
# its `self.x = x`, and nothing else. The number actually in force was the literal `15`,
# written twice in `MCPStdioClient` — an outer `withTimeout(seconds: 15)` plus a second
# absolute deadline inside the very wait it wrapped. So the config described a 10 s budget, the
# code enforced 15 s in two places, `MCPEndpointTests` asserted the knob's storage round-tripped
# (`== 10`, `== 5`), and no gate could go red: the suite read the storage, not the behaviour.
#
# ### What the fix made decidable
# One home (`MCPTimeouts`): startup (`initialize` + first `tools/list`) 30 s, tool call
# (`tools/call`) 300 s, domain 1…600 s — the split and the numbers from codex
# `codex-mcp/src/rmcp_client.rs:110-111`, carried per-server like codex
# `config/src/mcp_types.rs:272/276`. Per-endpoint override > bridge config > default. An
# out-of-domain value is refused by name (JSON-RPC -32602 with field + range + the value sent),
# never clamped, and it must not leave a half-built endpoint behind.
#
# ### What this probe locks down over HTTP (the unit suite cannot see this layer)
#   1. THE BUDGETS ARE PUBLISHED — `$bridge/status` states the two numbers in force, so a
#      client does not have to guess a constant that may not exist (invariant 2: a value the
#      surface does not state is a value the surface does not promise).
#   2. A BAD NUMBER IS AN ANSWER — `tool_timeout_sec:-5` returns -32602 naming
#      field + range + value, inside a second, with the box still serving.
#   3. AN OVERRIDE REACHES THE ENGINE AND THE LEDGER — connect a real stdio child with
#      `startup_timeout_sec:12` and `$bridge/endpoint/list` must publish 12 (override) next to
#      300 (untouched default). A knob that only changes a struct would show the default here.
#   4. SURVIVAL — after connect/disconnect/refusal traffic, `/health` answers and a normal chat
#      turn still returns its code word.
#
# ### What stays in Tests/ (and is NOT claimed here)
# The measured cut — a 1 s budget ending a 3 s `tools/call` and naming "1s" in the error — is
# gated in `MCPTimeoutDeliveryTests` against a live child. Over HTTP the same call would first
# meet the MCP approval gate (`routeToolCall` → securityGate), which denies without a broker, so
# this probe says that instead of pretending it measured the cut through the router.
#
# Run: bash scripts/probes/run.sh 25
PROBE_NAME="25-mcp-timeout-budget"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CODE_WORD="BASTION"
STUB="$(mktemp -t oc_mcp_stub_XXXXXX).py"
cleanup() { rm -f "$STUB"; }
trap cleanup EXIT

cat > "$STUB" <<'PYEOF'
import sys, json

def out(obj):
    print(json.dumps(obj))
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method = msg.get("method", "")
    if method == "initialize":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "ocoreai-budget-stub", "version": "0.1"}}})
    elif method.startswith("notifications/"):
        pass
    elif method == "tools/list":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"tools": [{"name": "budget_tool",
                                   "description": "answers immediately",
                                   "inputSchema": {"type": "object", "properties": {}}}]}})
    elif method == "tools/call":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"content": [{"type": "text", "text": "arrived"}]}})
    else:
        out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
PYEOF

mcp_call() {  # mcp_call <json-params-object> → sets PROBE_STATUS / PROBE_BODY
  probe_api POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

probe_boot
probe_require_ready_model
MODEL="$PROBE_MODEL"

probe_section "1) \$bridge/status publishes the two budgets in force"
mcp_call '$bridge/status' '{}'
if [ "${PROBE_STATUS:-}" = "200" ]; then
  if printf '%s' "$PROBE_BODY" | grep -qE '"startupTimeoutSeconds":30(\.0)?'; then
    probe_ok "status publishes startup budget 30s"
  else
    probe_fail "status does not publish the startup budget: ${PROBE_BODY:0:220}"
  fi
  if printf '%s' "$PROBE_BODY" | grep -qE '"toolTimeoutSeconds":300(\.0)?'; then
    probe_ok "status publishes tool budget 300s (was a hardcoded 15 nobody could move)"
  else
    probe_fail "status does not publish the tool budget: ${PROBE_BODY:0:220}"
  fi
else
  probe_fail "\$bridge/status HTTP ${PROBE_STATUS:-000}: ${PROBE_BODY:0:200}"
fi

probe_section "2) an out-of-domain budget is refused by name, not clamped, not hung"
START_TS=$(date +%s)
mcp_call '$bridge/endpoint/connect' '{"name":"probe-bad","command":"python3","args":[],"tool_timeout_sec":-5}'
ELAPSED=$(( $(date +%s) - START_TS ))
BODY="${PROBE_BODY:-}"
if [ "${PROBE_STATUS:-}" = "200" ] \
  && printf '%s' "$BODY" | grep -q -- '-32602' \
  && printf '%s' "$BODY" | grep -q 'tool_timeout_sec' \
  && printf '%s' "$BODY" | grep -q '1s and 600s' \
  && printf '%s' "$BODY" | grep -q -- '-5'; then
  probe_ok "tool_timeout_sec:-5 → -32602 naming field + range + value, in ${ELAPSED}s"
else
  probe_fail "bad budget not refused by name (HTTP ${PROBE_STATUS:-000}, ${ELAPSED}s): ${BODY:0:240}"
fi
if [ "$ELAPSED" -le 5 ]; then
  probe_ok "refusal is immediate (${ELAPSED}s) — a domain error must not cost a wait window"
else
  probe_fail "refusal took ${ELAPSED}s — a rejected value must not buy a timeout"
fi

probe_section "3) a legal override reaches the engine and shows up in the ledger"
mcp_call '$bridge/endpoint/connect' \
  "{\"name\":\"probe-budgeted\",\"command\":\"python3\",\"args\":[\"$STUB\"],\"capabilities\":[\"tools\"],\"startup_timeout_sec\":12}"
if printf '%s' "${PROBE_BODY:-}" | grep -q '"status":"connected"'; then
  probe_ok "stub connected with startup_timeout_sec:12"
else
  probe_fail "stub did not connect: HTTP ${PROBE_STATUS:-000} ${PROBE_BODY:0:240}"
fi
mcp_call '$bridge/endpoint/list' '{}'
BODY="${PROBE_BODY:-}"
if printf '%s' "$BODY" | grep -qE '"startupTimeoutSeconds":12(\.0)?'; then
  probe_ok "endpoint/list publishes the override (12) — the number moved the engine"
else
  probe_fail "override not published: ${BODY:0:280}"
fi
if printf '%s' "$BODY" | grep -qE '"toolTimeoutSeconds":300(\.0)?'; then
  probe_ok "untouched knob stays at the published default (300)"
else
  probe_fail "default tool budget not published beside the override: ${BODY:0:280}"
fi

probe_section "4) cleanup + survival — MCP traffic must not cost the box anything"
mcp_call '$bridge/endpoint/disconnect' '{"name":"probe-budgeted"}'
probe_api GET /health || true
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "/health answers after connect + refuse + disconnect"
else
  probe_fail "/health unreachable after MCP traffic (HTTP ${PROBE_STATUS:-000})"
fi
probe_chat "probe-mcp-survival" "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the word $CODE_WORD and nothing else.\"}],\"max_tokens\":8}" || true
if printf '%s' "${PROBE_BODY:-}" | grep -q "$CODE_WORD"; then
  probe_ok "a normal chat turn still works after the MCP budget traffic"
else
  probe_fail "chat turn lost its code word after MCP traffic (HTTP ${PROBE_STATUS:-000}): ${PROBE_BODY:0:160}"
fi

probe_note "the measured cut (1s budget ending a 3s tools/call, error naming \"1s\") lives in MCPTimeoutDeliveryTests against a live child: over HTTP the same call first meets the MCP approval gate, which denies without a broker"

probe_summary "$PROBE_NAME"
