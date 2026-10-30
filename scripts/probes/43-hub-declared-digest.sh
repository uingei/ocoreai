#!/usr/bin/env bash
# 43-hub-declared-digest.sh — does a hub that lies about the bytes get refused?
#
# ### Why (AGENTS.md invariant 2; the shape ollama already refuses)
# The post-download integrity check used to compare **sizes** (`Local file size does not match
# remote manifest`). A size compare cannot see right-size wrong bytes, and which server answers
# is an operator choice: `MODELSCOPE_ENDPOINT` is the documented mirror/proxy lever, the same
# reachability that makes probe 20 treat the manifest as untrusted input. The hub already
# publishes the answer — `Data.Files[].Sha256`, 64-hex per blob, LFS shards included — so the
# fix reads it and re-hashes what arrived (ollama `server/images.go:1870 verifyBlob`, reported
# as `want %s, got %s`).
#
# Two facts are at stake and they need different instruments:
#   • that the real hub actually sends the field — a unit test cannot say so, and if it stops
#     sending it the digest path becomes decoration again;
#   • that our client *acts* on it — which a stub can say exactly, at the byte level.
# So §1 asks the real hub once, and §§2-4 run the client against a stub that answers in
# ModelScope's own shape.
#
# ### What this probe locks down
#   1. PREMISE (live hub) — a real public repo's file list carries a lowercase 64-hex `Sha256`
#      for every blob, the multi-GB LFS shards included. No digests ⇒ nothing downstream is
#      measured; and since the compare is exact (ollama's), the regex demands lowercase instead
#      of trusting it — a hub that flipped case would otherwise false-refuse honest bytes.
#   2. HONEST HUB — the turn completes and the bytes on disk hash to what the hub declared.
#   3. LYING HUB — the declared digest does not match the bytes served: the SSE stream reports an
#      error naming SHA-256 with both digests, the corrupt file is gone, and the honest repo's
#      file is **still there** (a refusal removes the file it proved bad, never the cache).
#   4. SURVIVAL — /health still answers afterwards.
#
# No Metal turn is needed: every leg is settled before generation. Green 10-30: 13 passed /
# 0 failed / 7 measured; short-circuit the digest branch and 4 go red, the lying hub completing
# with its file left where the next load would read it.
#
# Run: bash scripts/probes/43-hub-declared-digest.sh
PROBE_NAME="43-hub-declared-digest"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"

TAG="p43-$$-${RANDOM}"
PARENT="/tmp/ocoreai-${TAG}"
export OCOREAI_MODELS_DIR="$PARENT/home/models"
mkdir -p "$OCOREAI_MODELS_DIR"
probe_atexit "rm -rf '$PARENT'"

HONEST="ocoreai-probe/digest-honest-${TAG}"
LIAR="ocoreai-probe/digest-liar-${TAG}"
GOOD='{"hub":"honest"}'
BAD='{"hub":"lies-lies-"}'
GOOD_SHA="$(printf '%s' "$GOOD" | shasum -a 256 | cut -d' ' -f1)"
BAD_SHA="$(printf '%s' "$BAD" | shasum -a 256 | cut -d' ' -f1)"
probe_note "declared digest ${GOOD_SHA:0:16}…; lying hub's bytes hash to ${BAD_SHA:0:16}…"

# ── §1 premise: the real hub publishes a digest per blob ─────────────────────────
probe_section "1) premise — a real hub declares a digest for the bytes it serves"
# A premise sample, not the model a turn runs on (rule 5 is about that one).
REAL_REPO="Qwen/Qwen2.5-7B-Instruct"
REAL_JSON="$(curl -sS -m 30 \
  "https://www.modelscope.cn/api/v1/models/${REAL_REPO}/repo/files?Recursive=true" 2>&1)"
COUNTS="$(printf '%s' "$REAL_JSON" | python3 -c '
import json, re, sys
try:
    files = (json.load(sys.stdin).get("Data") or {}).get("Files") or []
except Exception:
    print(0, 0, 0); raise SystemExit
blobs = [f for f in files if f.get("Type") == "blob"]
hexes = [f for f in blobs if re.fullmatch(r"[0-9a-f]{64}", str(f.get("Sha256") or ""))]
big = [f for f in blobs if (f.get("Size") or 0) > 1_000_000_000 and str(f.get("Sha256") or "")[:1]]
print(len(blobs), len(hexes), len(big))
')
"
read -r blobs digests big_shards <<< "$COUNTS"
probe_note "$REAL_REPO: $blobs blobs, $digests with a digest, $big_shards over 1 GB"
probe_require_int "blob count from $REAL_REPO" "${blobs:-}"
if [ "${blobs:-0}" -lt 1 ]; then
  probe_fail "the hub answered no blobs for $REAL_REPO — premise unavailable. This leg asks one real hub question: run it with network, the same route \`make probes\` takes."
elif [ "$blobs" != "$digests" ]; then
  probe_fail "only $digests/$blobs blobs carry a lowercase 64-hex Sha256 — decoration for the rest, or about to false-refuse"
else
  probe_ok "all $blobs blobs of $REAL_REPO carry a lowercase 64-hex Sha256 (of which $big_shards exceed 1 GB)"
  if [ "${big_shards:-0}" -lt 1 ]; then
    probe_fail "no multi-GB shard in the listing — the claim that weights, not just configs, are digestable is unproven"
  else
    probe_ok "$big_shards multi-GB shard(s) carry a digest — the bytes that matter are covered"
  fi
fi

# ── the stub hub, in ModelScope's own shapes ─────────────────────────────────────
STUB_PORT="$(probe_free_port)"
STUB_LOG="$(mktemp -t ocoreai-digeststub-XXXXXX).log"

python3 - "$STUB_PORT" "$HONEST" "$LIAR" "$GOOD" "$BAD" "$GOOD_SHA" "$STUB_LOG" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, honest, liar, good, bad, good_sha, logpath = (
    int(sys.argv[1]), sys.argv[2], sys.argv[3],
    sys.argv[4].encode(), sys.argv[5].encode(), sys.argv[6], sys.argv[7])

# repo → (bytes served, digest declared). The liar declares the size it really serves and the honest
# repo's digest: the size compare is satisfied for both, so only the digest can tell them apart.
REPOS = {honest: (good, good_sha), liar: (bad, good_sha)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with open(logpath, "a") as handle:
            handle.write(self.path + "\n")
        route = self.path.split("?", 1)[0]
        for repo, (payload, sha) in REPOS.items():
            if route == "/api/v1/models/" + repo:
                return self._send(200, json.dumps({"Revision": "master", "Id": repo}).encode())
            if route == "/api/v1/models/%s/repo/files" % repo:
                manifest = {"Data": {"Files": [{
                    "Path": "config.json", "Size": len(payload), "Type": "blob", "Sha256": sha}]}}
                return self._send(200, json.dumps(manifest).encode())
            if route.startswith("/api/v1/models/%s/resolve/" % repo):
                return self._send(200, payload, "application/octet-stream")
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
    "http://127.0.0.1:${STUB_PORT}/api/v1/models/${HONEST}" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && { stub_ready=1; break; }
  sleep 0.25
done
if [ "$stub_ready" != "1" ]; then
  probe_fail "the stub hub never answered on ${STUB_PORT} (last code ${code}) — no manifest to download against"
  probe_summary "$PROBE_NAME"
fi

# Read per downloader construction, so it must be exported before probe_boot.
export MODELSCOPE_ENDPOINT="http://127.0.0.1:${STUB_PORT}"
probe_boot

download_body() { printf '{"model":"%s","provider":"mscope"}' "$1"; }
repo_dir() { printf '%s/%s' "$OCOREAI_MODELS_DIR" "$1"; }

# ── §2 the honest hub completes ─────────────────────────────────────────────────
probe_section "2) honest hub — the declared digest and the bytes agree"
: > "$STUB_LOG"
OCOREAI_PROBE_CURL_TIMEOUT=120 probe_api POST /v1/models/download "$(download_body "$HONEST")" || true
HONEST_BODY="$PROBE_BODY"
asked_files="$(grep -c "/api/v1/models/${HONEST}/repo/files" "$STUB_LOG" 2>/dev/null)"
probe_require_int "manifest requests for $HONEST" "${asked_files:-}"
if [ "${asked_files:-0}" -ge 1 ]; then
  probe_ok "stub recorded ${asked_files} manifest request(s) — the digest below came from the hub, not from us"
else
  probe_fail "the client never asked the stub for a manifest (log: $(tr '\n' ' ' < "$STUB_LOG" | head -c 160))"
  probe_summary "$PROBE_NAME"
fi
case "$HONEST_BODY" in
  *'"eventType":"completed"'*) probe_ok "completed event" ;;
  *) probe_fail "no completed event from an honest hub: ${HONEST_BODY:0:220}" ;;
esac
HONEST_FILE="$(repo_dir "$HONEST")/config.json"
if [ -f "$HONEST_FILE" ]; then
  landed="$(shasum -a 256 "$HONEST_FILE" | cut -d' ' -f1)"
  probe_note "on disk: $(wc -c < "$HONEST_FILE" | tr -d ' ') bytes, sha256 ${landed:0:16}…"
  [ "$landed" = "$GOOD_SHA" ] \
    && probe_ok "the bytes on disk hash to the declared digest" \
    || probe_fail "accepted bytes that hash to ${landed}, not the declared ${GOOD_SHA}"
else
  probe_fail "the completed turn left no file at $HONEST_FILE"
fi

# ── §3 the lying hub is refused ─────────────────────────────────────────────────
probe_section "3) lying hub — right size, wrong bytes: refused, and the file does not stay"
OCOREAI_PROBE_CURL_TIMEOUT=120 probe_api POST /v1/models/download "$(download_body "$LIAR")" || true
LIAR_BODY="$PROBE_BODY"
LIAR_FILE="$(repo_dir "$LIAR")/config.json"
case "$LIAR_BODY" in
  *'"eventType":"error"'*) probe_ok "error event from the lying hub" ;;
  *) probe_fail "a lying hub produced no error event: ${LIAR_BODY:0:220}" ;;
esac
case "$LIAR_BODY" in
  *"SHA-256 mismatch"*) probe_ok "the refusal names SHA-256, not a size" ;;
  *) probe_fail "the refusal does not name SHA-256 — a size message would mean the digest was never consulted: ${LIAR_BODY:0:220}" ;;
esac
case "$LIAR_BODY" in
  *"$GOOD_SHA"*"$BAD_SHA"*) probe_ok "both digests travel to the client: declared, then observed" ;;
  *) probe_fail "the refusal omits the declared or observed digest: ${LIAR_BODY:0:220}" ;;
esac
if [ -e "$LIAR_FILE" ]; then
  probe_fail "the refused file is still on disk at $LIAR_FILE — the next load would read bytes we just proved bad"
else
  probe_ok "the corrupt file was removed"
fi
if [ -f "$HONEST_FILE" ]; then
  probe_ok "the honest repo's file survived the refusal — only the proven-bad byte was deleted"
else
  probe_fail "the refusal swept the cache: $HONEST_FILE is gone"
fi

# ── §4 survival ─────────────────────────────────────────────────────────────────
probe_section "4) survival"
probe_api GET /health || true
case "$PROBE_BODY" in
  *"status"*|*"ok"*) probe_ok "/health still answers after a refused download" ;;
  *) probe_fail "/health did not answer after the refusal: ${PROBE_BODY:0:160}" ;;
esac

probe_summary "$PROBE_NAME"
