#!/usr/bin/env bash
# 36-download-plan-dry-run.sh — can a client size a download before it commits to one?
#
# ### Why (AGENTS.md invariant 2; the mechanism is Strata's, docs/TERMINAL_LAUNCH.md:110)
# `POST /v1/models/download` used to have exactly one mode: start fetching. A client that
# wanted to know the size of the hole first had to open the stream and watch progress events,
# which is the same thing as committing — and the guard that refuses a 40 GB ask fired
# only after the client had already dialed. Strata answers that question before touching the
# disk: `launch --plan` lists the model, the context and "what would download (0 when everything
# is here)", then exits untouched.
#
# The numbers already existed in this repo: DiskSpaceGuard.measuredRemoteBytes + cachedBytes +
# decision are the same three the guard blocks on (Models/DiskSpaceGuard.swift). What was
# missing was a way to *read* them without the block, and a verdict shape that could say
# "unknown" — DiskSpaceGuard.verdict exists for exactly that, because a guard must not
# block on silence and a published answer must not claim on silence either.
#
# ### What is asserted
#   1. Premise: the stub hub recorded the metadata request — the plan asked, it did not guess.
#   2. Measured numbers are exact: remote total, cache credit and the remaining bytes all match
#      the sizes the stub declared (1000000 + 100 + 50).
#   3. Nothing was fetched: no directory, no file, not one byte under the cache root for the id.
#   4. Unknown stays unknown: a repo the hub 404s answers with NO requiredBytes and NO
#      wouldFit — silence is neither a size nor a fit.
#   5. "0 when everything is here": the same id, seeded with the three required files, plans
#      requiredBytes 0 and says so from the local predicate rather than the hub.
#   6. An unsafe id is refused before the hub is asked, so dry-run is not a bypass of probe 20.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="36-download-plan-dry-run"

REPO="ocoreai-probe/plan-dryrun-$$"
MISSING="ocoreai-probe/plan-missing-$$"
REMOTE_TOTAL=1000150

STUB_PORT="$(probe_free_port)"
STUB_LOG="$(mktemp -t ocoreai-planstub-XXXXXX).log"

python3 - "$STUB_PORT" "$REPO" "$MISSING" "$STUB_LOG" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, repo, missing, logpath = (int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4])
SIZES = [("model.safetensors", 1000000), ("config.json", 100), ("chat_template.jinja", 50)]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with open(logpath, "a") as handle:
            handle.write(self.path + "\n")
        # The SDK appends its query params, so the path alone is what identifies the repo.
        route = self.path.split("?", 1)[0].rstrip("/")
        if route == "/api/models/" + repo:
            payload = {"_id": repo, "id": repo, "revision": "main",
                      "siblings": [{"rfilename": n, "size": s} for n, s in SIZES]}
            self._send(200, json.dumps(payload).encode())
            return
        self._send(404, b'{"error": "no such repo on this hub"}')

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
STUB_PID=$!
probe_atexit 'kill "$STUB_PID" 2>/dev/null || true'

stub_ready=0
for _ in $(seq 1 40); do
  code="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${STUB_PORT}/api/models/${REPO}" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    stub_ready=1
    break
  fi
  sleep 0.25
done
if [ "$stub_ready" != "1" ]; then
  probe_fail "the stub hub never answered on ${STUB_PORT} (last code ${code}) — no sizes to plan against"
  probe_summary "$PROBE_NAME"
fi

# Read once by HFMirrorPolicy at startup, so it must be exported before probe_boot.
export HF_ENDPOINT="http://127.0.0.1:${STUB_PORT}"
probe_boot

MODELS_ROOT="${HOME}/.ocoreai/models"
REPO_DIR="${MODELS_ROOT}/${REPO}"
SEED_DIR=""
probe_atexit '[ -n "$SEED_DIR" ] && rm -rf "$SEED_DIR" || true'
rm -rf "$REPO_DIR" 2>/dev/null || true

plan_body() { printf '{"model":"%s","dryRun":true}' "$1"; }

# The route answers SSE; probe_json wants the payload object, not the `data: ` frame.
sse_json() { printf '%s' "$1" | sed -n 's/^data:[[:space:]]*//p' | head -1; }

probe_section "1) premise — the plan asked the hub, it did not invent a number"
: > "$STUB_LOG"
OCOREAI_PROBE_CURL_TIMEOUT=60 probe_api POST /v1/models/download "$(plan_body "$REPO")" || true
PLAN_BODY="$PROBE_BODY"
asked="$(grep -c "^/api/models/${REPO}" "$STUB_LOG" 2>/dev/null)"
if [ "${asked:-0}" -ge 1 ]; then
  probe_ok "stub recorded ${asked} metadata request(s) for $REPO — the bytes below are measured"
else
  probe_fail "no metadata request reached the stub (log: $(tr '\n' ' ' < "$STUB_LOG" | head -c 160))"
  probe_summary "$PROBE_NAME"
fi

probe_section "2) the plan states the sizes it was told"
case "$PLAN_BODY" in
  *"data:"*) : ;;
  *) probe_fail "dry-run opened no SSE frame: ${PLAN_BODY:0:160}"; ;;
esac
case "$PLAN_BODY" in
  *"eventType\":\"plan\""*) probe_ok "eventType plan" ;;
  *) probe_fail "dry-run did not answer a plan event: ${PLAN_BODY:0:200}" ;;
esac
PLAN_JSON="$(sse_json "$PLAN_BODY")"
[ -n "$PLAN_JSON" ] \
  && probe_ok "the frame carries a JSON payload" \
  || probe_fail "no JSON payload inside the SSE frame: ${PLAN_BODY:0:160}"

remote="$(probe_json "$PLAN_JSON" "plan.remoteTotalBytes")"
cached="$(probe_json "$PLAN_JSON" "plan.cachedBytes")"
required="$(probe_json "$PLAN_JSON" "plan.requiredBytes")"
basis="$(probe_json "$PLAN_JSON" "plan.basis")"
fit="$(probe_json "$PLAN_JSON" "plan.wouldFit")"
[ "$remote" = "$REMOTE_TOTAL" ] \
  && probe_ok "remoteTotalBytes == ${REMOTE_TOTAL} (the stub's own three sizes)" \
  || probe_fail "remoteTotalBytes is '${remote:-absent}', expected ${REMOTE_TOTAL}"
[ "$cached" = "0" ] \
  && probe_ok "cachedBytes == 0 on a cache that holds nothing of this repo" \
  || probe_fail "cachedBytes is ${cached:-absent}, expected 0"
[ "$required" = "$REMOTE_TOTAL" ] \
  && probe_ok "requiredBytes == ${REMOTE_TOTAL} — the whole repo is still to fetch" \
  || probe_fail "requiredBytes is ${required:-absent}, expected ${REMOTE_TOTAL}"
[ "$basis" = "measured" ] \
  && probe_ok "basis measured" \
  || probe_fail "basis is ${basis:-absent}, expected measured"
case "$fit" in
  true) probe_ok "wouldFit true with both sides measured" ;;
  *) probe_fail "wouldFit is ${fit:-absent} although free space and size are both known" ;;
esac

probe_section "3) nothing was fetched"
if [ -e "$REPO_DIR" ]; then
  stray="$(find "$REPO_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  probe_fail "dry-run created ${REPO_DIR} (${stray} file(s)) — it was asked to plan, not download"
else
  probe_ok "no directory for $REPO under ${MODELS_ROOT} — zero bytes written"
fi

probe_section "4) unknown stays unknown — a hub that says nothing is not a size"
OCOREAI_PROBE_CURL_TIMEOUT=60 probe_api POST /v1/models/download "$(plan_body "$MISSING")" \
  || true
MISS_JSON="$(sse_json "$PROBE_BODY")"
miss_remote="$(probe_json "$MISS_JSON" "plan.remoteTotalBytes")"
miss_required="$(probe_json "$MISS_JSON" "plan.requiredBytes")"
miss_fit="$(probe_json "$MISS_JSON" "plan.wouldFit")"
if [ -z "$miss_required" ] && [ -z "$miss_fit" ]; then
  probe_ok "a repo the hub 404s publishes no requiredBytes and no wouldFit (no fabricated fit)"
else
  probe_fail "unknown repo published requiredBytes=${miss_required:-absent} wouldFit=${miss_fit:-absent}"
fi
[ -z "$miss_remote" ] \
  && probe_ok "remoteTotalBytes absent for the unknown repo" \
  || probe_fail "remoteTotalBytes leaked ${miss_remote} for a repo the hub does not have"

probe_section "5) everything already here — the plan says zero"
SEED_DIR="$REPO_DIR"
mkdir -p "$REPO_DIR" || probe_fail "could not seed ${REPO_DIR}"
python3 - "$REPO_DIR" <<'PY'
import os
sys_path, sizes = __import__("sys").argv[1], [("model.safetensors", 1000000),
                                               ("config.json", 100), ("chat_template.jinja", 50)]
for name, size in sizes:
    with open(os.path.join(sys_path, name), "wb") as handle:
        handle.write(b"\0" * size)
PY
OCOREAI_PROBE_CURL_TIMEOUT=60 probe_api POST /v1/models/download "$(plan_body "$REPO")" || true
SEED_JSON="$(sse_json "$PROBE_BODY")"
seed_required="$(probe_json "$SEED_JSON" "plan.requiredBytes")"
seed_basis="$(probe_json "$SEED_JSON" "plan.basis")"
seed_cached="$(probe_json "$SEED_JSON" "plan.cachedBytes")"
[ "$seed_required" = "0" ] \
  && probe_ok "requiredBytes == 0 when every required file is already local" \
  || probe_fail "requiredBytes is ${seed_required:-absent} for a complete local model, expected 0"
[ "$seed_basis" = "locallySatisfied" ] \
  && probe_ok "basis locallySatisfied — the verdict came from the cache, not the hub" \
  || probe_fail "basis is ${seed_basis:-absent}, expected locallySatisfied"
[ "$seed_cached" = "$REMOTE_TOTAL" ] \
  && probe_ok "cachedBytes == ${REMOTE_TOTAL} quoted off the disk" \
  || probe_fail "cachedBytes is ${seed_cached:-absent}, expected ${REMOTE_TOTAL}"

probe_section "6) dry-run is not a bypass of the path-traversal rule"
OCOREAI_PROBE_CURL_TIMEOUT=30 probe_api POST /v1/models/download \
  '{"model":"../../etc/passwd","dryRun":true}' || true
case "$PROBE_BODY" in
  *"eventType\":\"plan\""*,"*cacheDir"*"root"*)
    probe_fail "an escaping id was planned anyway: ${PROBE_BODY:0:200}"
    ;;
  *"error"* | *"outside"*)
    probe_ok "escaping id refused before any hub question (first bytes: ${PROBE_BODY:0:120})"
    ;;
  *)
    probe_fail "expected a refusal for an escaping id, got: ${PROBE_BODY:0:200}"
    ;;
esac

probe_summary "$PROBE_NAME"

