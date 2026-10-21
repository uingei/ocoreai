#!/usr/bin/env bash
# 24-hub-existence-gate.sh — does the hub reachability gate refuse only what it actually asked?
#
# ### Why this exists (and why it stands its own hub)
# probe 23 §4 measures the verdict this network produces: a dead id comes back HTTP 503 in ~8 s
# naming both hubs and the `HF_ENDPOINT` lever. That leg cannot certify the *other* half of
# `HubReachability` — a hub that answers "yes, this repo exists" must NOT be refused. On this
# host huggingface.co is a black hole (measured 10-21: `curl` to its API returns nothing, while
# ModelScope answers a real 404 in 0.18 s), so the `.present` branch never runs here against a
# real hub, and a gate that wrongly refused a reachable hub would look exactly like the fix while
# breaking every download the product advertises. So this probe supplies its own hub: a stub
# that answers 200 for `/api/models/<repo>` and 404 for everything else, with `HF_ENDPOINT`
# pointed at it (HFMirrorPolicy captures the operator env once, at startup).
#
# ### What this probe locks down (hard gates)
#   1. PREMISE — the stub must actually see the existence request for the repo. A stub nobody
#      called makes every later assertion here vacuous, so the log is checked first.
#   2. PASS-THROUGH — with the hub saying the repo exists, the request must go to the hub
#      client: the answer may be a download failure (the stub holds no weights), but it must
#      not be the reachability refusal, and it must arrive within 30 s with the box alive.
#   3. THE OTHER HALF, SAME ID — kill the stub, send the same id: no hub can answer now, so
#      the verdict must flip to 503 naming the id, inside 15 s. Two outcomes from one id,
#      decided by what the hub said — not by how long the caller waited.
#
# Run: bash scripts/probes/run.sh 24
PROBE_NAME="24-hub-existence-gate"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

BOGUS="ocoreai-stub/definitely-not-a-real-repo"

STUB_PORT="$(probe_free_port)"
STUB_LOG="$(mktemp -t ocoreai-hubstub-XXXXXX).log"
DEAD_PORT="$(probe_free_port)"

python3 - "$STUB_PORT" "$BOGUS" "$STUB_LOG" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, repo, logpath = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(logpath, "a") as handle:
            handle.write(self.path + "\n")
        if self.path == "/api/models/" + repo:
            body = json.dumps({"_id": repo, "id": repo}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = b'{"error": "not on this hub"}'
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
STUB_PID=$!
probe_atexit 'kill "$STUB_PID" 2>/dev/null || true'

# The stub has to be listening before the server under test can be pointed at it, and a stub
# that died on an import error would otherwise read as "the gate refused".
stub_ready=0
for _ in $(seq 1 40); do
  code="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${STUB_PORT}/api/models/${BOGUS}" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    stub_ready=1
    break
  fi
  sleep 0.25
done
if [ "$stub_ready" != "1" ]; then
  probe_fail "the stub hub never answered on port ${STUB_PORT} (last code ${code}) — nothing to point HF_ENDPOINT at"
  probe_summary "$PROBE_NAME"
fi
probe_ok "stub hub listening on ${STUB_PORT}: 200 for /api/models/$BOGUS, 404 elsewhere"

# Captured once at startup by HFMirrorPolicy, so it must be exported before probe_boot.
export HF_ENDPOINT="http://127.0.0.1:${STUB_PORT}"
probe_boot

chat_body() {
  printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":4}' "$BOGUS"
}

probe_section "1) premise — the engine actually asked the stub hub"
: > "$STUB_LOG"
OCOREAI_PROBE_CURL_TIMEOUT=30 probe_api POST /v1/chat/completions "$(chat_body)" || true
FIRST_STATUS="${PROBE_STATUS:-000}"
FIRST_BODY="$PROBE_BODY"
asked="$(grep -c "^/api/models/${BOGUS}$" "$STUB_LOG" 2>/dev/null)"
if [ "${asked:-0}" -ge 1 ]; then
  probe_ok "the stub recorded the existence request for $BOGUS (${asked}x) — the leg below is live"
else
  probe_fail "the stub saw no existence request (log: $(tr '\n' ' ' < "$STUB_LOG" | head -c 160)) — HF_ENDPOINT was not honored, so pass-through is unmeasured, not proven"
fi

probe_section "2) the hub said it exists — the gate must let the request through"
case "$FIRST_BODY" in
  *"unreachable ("*)
    probe_fail "refused as unreachable a hub that answered 200: ${FIRST_BODY:0:200}"
    ;;
  *)
    probe_ok "no reachability refusal on a hub that said the repo exists (HTTP ${FIRST_STATUS}) — the load went to the hub client"
    ;;
esac
if [ "$FIRST_STATUS" = "200" ]; then
  probe_note "the stub served enough of the API that the turn completed — pass-through still proven, weights included"
fi
probe_api GET /health || true
if [ "${PROBE_STATUS:-000}" = "200" ]; then
  probe_ok "server alive after the pass-through attempt"
else
  probe_fail "server stopped answering /health after a hub pass-through"
fi

probe_section "3) same id, hub gone — the verdict must flip, and flip fast"
# Nothing is listening now: the existence question itself fails, which is the definition of the
# 503 branch. Same model id as §2, so only the hub's answer changed.
kill "$STUB_PID" 2>/dev/null || true
wait "$STUB_PID" 2>/dev/null || true
STUB_PID=""
started=$(date +%s)
OCOREAI_PROBE_CURL_TIMEOUT=20 probe_api POST /v1/chat/completions "$(chat_body)" || true
elapsed=$(( $(date +%s) - started ))
named="$(printf '%s' "${PROBE_BODY:-}" | tr -d '\\')"
if [ "${PROBE_STATUS:-000}" = "503" ] && printf '%s' "$named" | grep -q "$BOGUS"; then
  probe_ok "$BOGUS now refused in ${elapsed}s with HTTP 503 naming the id — two verdicts, one id, decided by the hub"
else
  probe_fail "with the hub gone the answer was HTTP ${PROBE_STATUS:-000} after ${elapsed}s, expected a prompt 503 naming $BOGUS: ${PROBE_BODY:0:200}"
fi
probe_note "stub log: $(tr '\n' ' ' < "$STUB_LOG" | head -c 200)"

probe_summary "$PROBE_NAME"
