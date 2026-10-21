#!/usr/bin/env bash
# 26-mcp-stderr-diagnosis.sh — when an external MCP server fails, does this server say WHY?
#
# ### What was measured on 10-21 (before the fix, this host)
# `MCPStdioClient.launchProcess` set `proc.standardError = nil`, so Foundation pointed the
# child's stderr at /dev/null. A server that dies on startup was therefore reported as
# "Connect failed: MCP server process exited with status 1" and one that never answered as
# "did not answer within 15s"/"30s". Both sentences are true, neither is a diagnosis: the
# `ModuleNotFoundError`, the `MODULE_NOT_FOUND`, the `address already in use` — the only lines
# that say what to fix — were destroyed on arrival, and no test could have caught it because
# nothing was expected to arrive (AGENTS.md invariant 1).
#
# ### What the fix made decidable
# stderr is collected into a bounded tail (`MCP/MCPStderrTail.swift`: last 12 lines × 400
# chars, suppression counted) and folded into every diagnosis the client emits
# (`MCPClientError.withStderr`, appended after the existing wording — never invented when the
# child said nothing). Shape borrowed from codex, which treats stderr as diagnostics, not
# protocol: `rmcp-client/src/executor_process_transport.rs:52-53` (1 MiB stderr line vs 8 MiB
# stdout) and `:480 flush_stderr()`.
#
# ### What this probe locks down over HTTP (the unit suite cannot see this layer)
#   1. THE CAUSE REACHES THE REFUSAL — a stub that writes a traceback and exits 3 must produce
#      a -32603 naming BOTH the exit status and `ModuleNotFoundError`, with exactly one
#      `stderr:` clause (the client wraps the error twice; a doubled clause is a bug).
#   2. THE TWO FAILURE MODES STAY DISTINGUISHABLE — a server that complains then hangs says
#      "did not answer within 2s" *and* carries its complaint; a dead one says "exited with
#      status 3". Collapsing these two is how a diagnosis becomes a shrug.
#   3. THE LEDGER REMEMBERS — `$bridge/endpoint/list` publishes the same evidence in
#      `lastError`, the row the GUI reads after the response has scrolled past.
#   4. THE HAPPY PATH IS UNTOUCHED — a working server still connects and the box still
#      answers a chat turn after three failed MCP connections. Capturing stderr must cost
#      nothing to a server that behaves.
#
# Run: bash scripts/probes/run.sh 26
PROBE_NAME="26-mcp-stderr-diagnosis"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CODE_WORD="LANTERN"
DIE_STUB="$(mktemp -t oc_mcp_die_XXXXXX).py"
HANG_STUB="$(mktemp -t oc_mcp_hang_XXXXXX).py"
WORK_STUB="$(mktemp -t oc_mcp_work_XXXXXX).py"
cleanup() { rm -f "$DIE_STUB" "$HANG_STUB" "$WORK_STUB"; }
trap cleanup EXIT

cat > "$DIE_STUB" <<'PYEOF'
import sys
print("Traceback (most recent call last):", file=sys.stderr, flush=True)
print("ModuleNotFoundError: No module named 'ocoreai_probe_dep'", file=sys.stderr, flush=True)
sys.exit(3)
PYEOF

cat > "$HANG_STUB" <<'PYEOF'
import sys, time
print("FATAL: cannot bind 127.0.0.1:8777, address already in use", file=sys.stderr, flush=True)
time.sleep(120)
PYEOF

cat > "$WORK_STUB" <<'PYEOF'
import sys, json

print("INFO: ocoreai-probe-stub ready", file=sys.stderr, flush=True)

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
                        "serverInfo": {"name": "ocoreai-diag-stub", "version": "0.1"}}})
    elif method.startswith("notifications/"):
        pass
    elif method == "tools/list":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"tools": [{"name": "diag_tool",
                                   "description": "answers immediately",
                                   "inputSchema": {"type": "object", "properties": {}}}]}})
    elif method == "tools/call":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"content": [{"type": "text", "text": "arrived"}]}})
    else:
        out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
PYEOF

mcp_call() {  # mcp_call <method> <json-params> → sets PROBE_STATUS / PROBE_BODY
  probe_api POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

probe_boot
probe_require_ready_model
MODEL="$PROBE_MODEL"

probe_section "1) a server that dies on startup names its own cause in the refusal"
mcp_call '$bridge/endpoint/connect' \
  "{\"name\":\"probe-dies\",\"command\":\"python3\",\"args\":[\"$DIE_STUB\"],\"capabilities\":[\"tools\"]}"
BODY="${PROBE_BODY:-}"
if printf '%s' "$BODY" | grep -q -- '-32603' \
  && printf '%s' "$BODY" | grep -q 'exited with status 3' \
  && printf '%s' "$BODY" | grep -q 'ModuleNotFoundError'; then
  probe_ok "refusal carries symptom AND cause: ${BODY:0:190}"
else
  probe_fail "refusal names only the symptom, cause still discarded: ${BODY:0:240}"
fi
if printf '%s' "$BODY" | grep -q 'Traceback (most recent call last)'; then
  probe_ok "the older traceback frames survive too (a ring keeps the context, not just the tail)"
else
  probe_fail "only the last line was kept, context lost: ${BODY:0:240}"
fi
STDERR_CLAUSES=$(printf '%s' "$BODY" | grep -o 'stderr:' | wc -l | tr -d ' ')
if [ "$STDERR_CLAUSES" = "1" ]; then
  probe_ok "exactly one stderr clause — the two wrap layers did not say it twice"
else
  probe_fail "the diagnosis repeats itself ($STDERR_CLAUSES clauses): ${BODY:0:240}"
fi

probe_section "2) dead and hung stay distinguishable, and the budget still rules"
START_TS=$(date +%s)
mcp_call '$bridge/endpoint/connect' \
  "{\"name\":\"probe-hangs\",\"command\":\"python3\",\"args\":[\"$HANG_STUB\"],\"capabilities\":[\"tools\"],\"startup_timeout_sec\":2}"
ELAPSED=$(( $(date +%s) - START_TS ))
BODY="${PROBE_BODY:-}"
if printf '%s' "$BODY" | grep -q 'did not answer within 2s'; then
  probe_ok "hung server is reported as a timeout at the override (2s), not as a crash"
else
  probe_fail "hung server not reported as a 2s timeout: ${BODY:0:240}"
fi
if printf '%s' "$BODY" | grep -q 'address already in use'; then
  probe_ok "and it still carries what the server complained about before going quiet"
else
  probe_fail "timeout refusal lost the server's own complaint: ${BODY:0:240}"
fi
if [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 6 ]; then
  probe_ok "cut at the budget, measured ${ELAPSED}s"
else
  probe_fail "elapsed ${ELAPSED}s is not the 2s budget that was set"
fi

probe_section "3) the ledger remembers the cause after the response scrolled past"
mcp_call '$bridge/endpoint/list' '{}'
BODY="${PROBE_BODY:-}"
if printf '%s' "$BODY" | grep -q '"probe-dies"' \
  && printf '%s' "$BODY" | grep -q 'errored' \
  && printf '%s' "$BODY" | grep -q 'ModuleNotFoundError'; then
  probe_ok "endpoint/list keeps the errored row with its evidence — the GUI reads this row"
else
  probe_fail "endpoint/list lost the diagnosis or the row: ${BODY:0:260}"
fi

probe_section "4) a healthy server is unaffected, and three failed MCP connections own nothing"
mcp_call '$bridge/endpoint/connect' \
  "{\"name\":\"probe-works\",\"command\":\"python3\",\"args\":[\"$WORK_STUB\"],\"capabilities\":[\"tools\"]}"
if printf '%s' "${PROBE_BODY:-}" | grep -q '"status":"connected"'; then
  probe_ok "working server still connects — collecting stderr did not disturb the protocol"
else
  probe_fail "working server failed to connect: HTTP ${PROBE_STATUS:-000} ${PROBE_BODY:-}"
fi
mcp_call '$bridge/endpoint/disconnect' '{"name":"probe-works"}'
mcp_call '$bridge/endpoint/disconnect' '{"name":"probe-dies"}'
mcp_call '$bridge/endpoint/disconnect' '{"name":"probe-hangs"}'
probe_api GET /health
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "/health 200 after two failed and one healthy MCP connection"
else
  probe_fail "/health ${PROBE_STATUS:-000} — a failing MCP server took the box down"
fi
probe_chat "probe-mcp-diagnosis" \
  "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the word $CODE_WORD and nothing else.\"}],\"max_tokens\":8}" || true
if printf '%s' "${PROBE_BODY:-}" | grep -q "$CODE_WORD"; then
  probe_ok "a normal chat turn still answers after the MCP failures (model: $MODEL)"
else
  probe_fail "chat turn did not return the code word: ${PROBE_BODY:-}"
fi

probe_note "the bounded tail itself (5000 lines → last 12 + a suppressed count, 400-char line cap, chunk-boundary and multibyte assembly, no clause when the child said nothing) is gated in MCPStderrDiagnosisTests: over HTTP only one window of a misbehaving server is reachable, and the buffer must be pinned where every line can be controlled"

probe_summary "$PROBE_NAME"
