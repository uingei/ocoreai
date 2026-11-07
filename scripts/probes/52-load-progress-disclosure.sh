#!/usr/bin/env bash
# 52-load-progress-disclosure.sh — during a load a stranger is actually waiting through, does
# `/v1/models` say what the loader read, or only what it did not do?
#
# Why this probe exists. `/v1/models` has published `loadProgress` since 11-01 on the strength of a
# measured wait — the shipping default checkpoint is 3 550 670 554 B and fetched in 794 s at 4.5 MB/s
# while a waiter was released at the 120 s window with nothing but "still loading" (CHANGELOG
# 11-01(101)) — and not one probe had ever watched a real load produce those numbers. The phase that
# needed the proof is the one the shape could only describe by negation: once the bytes are on disk
# the row said `downloading:false` and nothing else, while the loader was still mapping gigabytes.
#
# Measured 11-07, one live `serve`, `mlx-community/gemma-4-e2b-it-4bit` on disk and not resident:
# the ready-directory route (the one every warm start takes — `MLXBridge.swift`, "Loading ready
# model …") read the weights in **6 808 ms**, and 30 polls of `/v1/models` during it returned
# `{"downloading":false,"elapsedSeconds":N}` and nothing else — an honest sentence about a phase
# nobody measured. mlx-swift-lm #551 measures that phase in bytes, with the denominator read off the
# checkpoint's own `*.safetensors`; once the loader installs the handler (and it must be installed
# by the route that has the id, because upstream creates no reporter when the handler is nil), the
# same load published 2 043 453 000 → 3 548 197 834 → 3 550 670 554 of 3 550 670 554 B, and that
# total is byte-for-byte the size of `model.safetensors` on disk (§3).
#
# Legs:
#   1) watch + floor — from the moment `/health` answers, poll until the boot's own prewarm load is
#      seen in `state:"loading"`; a run that saw nothing has no subject, fails loudly, and names
#      the knob to turn rather than passing quietly (§1);
#   2) the weights axis reached the wire at least once, and in every sample it came as a PAIR with
#      bytes ≤ denominator (upstream publishes a synthetic 1/1 when it never measured a total —
#      copying that would publish a byte count the loader never read);
#   3) the denominator is the checkpoint: `weightsBytesTotal` equals the summed bytes of the
#      `*.safetensors` files this load read, so the wire number is a file fact, not an estimate;
#   4) the row closes with the load — once the id is ready again, no `loadProgress` survives on it
#      (a stale row reads as a finished load still at 40 %).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="load-progress-disclosure"
SAMPLES="$(mktemp -t ocoreai-loadprogress-XXXXXX)"
probe_atexit 'rm -f "$SAMPLES"'

probe_boot
probe_require_ready_model

# ── 1) watch the boot's own load — premise and observation in one loop ───────────────────────
#
# Premise and observation live in the same loop on purpose. Splitting them (the first draft polled
# once a second for five seconds to "find" a load, then started watching) lost the load it had just
# found: the boot prewarm had finished in the gap, and the legs below were left with no subject. The
# load this probe watches is the one every first run does by itself — the prewarm — so the watch
# starts the moment `/health` answers, which is how the stranger's wait is actually ordered.
probe_section "1) watching the boot's own load from the moment /health answered"
SUBJECT=""
LOADING_SAMPLES=0
READY_SEEN=""
started="$(date +%s)"
budget="${OCOREAI_PROBE_LOAD_WAIT:-120}"
waited=0
while :; do
  waited=$(( $(date +%s) - started ))
  [ "$waited" -lt "$budget" ] || break
  probe_api GET /v1/models || true
  # Whichever row is loading is the subject (at boot that is the prewarm's own id, which need not be
  # the one `/v1/models` lists first); with nothing loading, follow PROBE_MODEL so the loop still
  # sees the transition instead of printing nothing.
  line="$(printf '%s' "${PROBE_BODY:-}" | python3 -I -c '
import json,sys
want = sys.argv[1]
try: rows = json.load(sys.stdin).get("data", [])
except Exception: rows = []
pick = next((m for m in rows if m.get("state") == "loading"), None)
if pick is None:
    pick = next((m for m in rows if m.get("id") == want), None)
if pick is None:
    sys.exit()
lp = pick.get("loadProgress") or {}
def g(k):
    # str() is load-bearing: `downloading` is a bool and the byte counts are ints, and a bare
    # join raised TypeError that the 2>/dev/null below hid as "no row" for the whole load.
    v = lp.get(k)
    return "" if v is None else str(v)
print("|".join([str(pick.get("id")), str(pick.get("state")), g("downloading"),
                g("bytesDownload"), g("weightsBytes"), g("weightsBytesTotal")]))
' "${PROBE_MODEL:-}" 2>/dev/null || true)"
  [ -n "$line" ] && printf '%s\n' "$line" >> "$SAMPLES"
  sid="${line%%|*}"
  rest="${line#*|}"
  state="${rest%%|*}"
  if [ "$state" = "loading" ]; then
    LOADING_SAMPLES=$(( LOADING_SAMPLES + 1 ))
    [ -n "$SUBJECT" ] || SUBJECT="$sid"
  elif [ -n "$SUBJECT" ] && [ "$state" = "ready" ]; then
    # Only break after the subject was seen loading — a ready sighting before that is the
    # prewarm not having started yet, not the load having ended.
    READY_SEEN=1
    break
  elif [ "$LOADING_SAMPLES" -eq 0 ] && [ "$state" = "ready" ] && [ "$waited" -ge 10 ]; then
    # The prewarm starts with the server; ten seconds of a ready row with nothing ever loading
    # means this boot has no load to watch (a resident model) — stop before the whole budget.
    break
  fi
  # One poll interval per sleep, never the deadline (§ Code Conventions).
  sleep 0.1
done
# The legs below (checkpoint stat, row-closure) judge the row that actually loaded.
TARGET="${SUBJECT:-${PROBE_MODEL:-}}"

if [ "$LOADING_SAMPLES" -ge 1 ]; then
  probe_ok "$LOADING_SAMPLES loading samples observed for $TARGET over ${waited}s$([ -n "$READY_SEEN" ] && printf ' (watched it reach ready)')"
else
  probe_fail "no row was ever seen in state:\"loading\" (watched ${waited}s, $(wc -l < "$SAMPLES" | tr -d ' ')" \
    " rows) — so the legs below have no subject and nothing here is proven. Remedy: this probe needs a" \
    " server whose model is not yet resident at /health time (a fresh OCOREAI_DATA_DIR, or a checkpoint" \
    " big enough to still be loading then). Do not read this as a smaller pass."
  probe_summary "$PROBE_NAME"
fi

# ── 2) the weights axis reached the wire, as a pair, under its own denominator ────────────────
probe_section "2) the weights axis reached the wire, and never over its denominator"
stats="$(python3 -I - "$SAMPLES" <<'PY3'
import sys
seen = pairs = over = 0
mx = 0
for raw in open(sys.argv[1]):
    parts = raw.strip().split("|")
    if len(parts) != 6 or parts[1] != "loading":
        continue
    _, _, _, _, b, t = parts
    if not b or not t:
        continue
    b, t = int(b), int(t)
    seen += 1
    pairs += 1
    if b > t:
        over += 1
    mx = max(mx, b)
print(seen, pairs, over, mx)
PY3
)"
read -r W_SEEN W_PAIRS W_OVER W_MAX <<< "$stats"
if [ "$W_SEEN" -ge 1 ]; then
  probe_ok "weights reached /v1/models in $W_SEEN of $LOADING_SAMPLES samples (max $W_MAX B)"
else
  probe_fail "no sample carried weightsBytes during a $LOADING_SAMPLES-sample load — the loader stopped" \
    " installing the handler (#551's reporter exists only when a handler is non-nil, so the route" \
    " that has the id must install it); the wait would be back to describing its second half by negation"
fi
if [ "$W_PAIRS" -eq "$W_SEEN" ] && [ "$W_OVER" -eq 0 ]; then
  probe_ok "every weights sample came as a pair with bytes ≤ denominator (no synthetic 1/1 shipped)"
else
  probe_fail "$W_OVER sample(s) over the denominator and $(( W_SEEN - W_PAIRS )) unpaired — a byte count" \
    " without a measured total is a number the loader did not read"
fi

# ── 3) the denominator is the checkpoint on disk, not an estimate ─────────────────────────────
probe_section "3) weightsBytesTotal is the size of the files this load read"
MODELS_DIR="${OCOREAI_MODELS_DIR:-$HOME/.ocoreai/models}"
CKPT="$MODELS_DIR/$TARGET"
if [ -d "$CKPT" ]; then
  ON_DISK="$(python3 -I -c '
import glob, os, sys
print(sum(os.path.getsize(p) for p in glob.glob(os.path.join(sys.argv[1], "*.safetensors"))))' "$CKPT")"
  TOTAL_OBSERVED="$(python3 -I - "$SAMPLES" <<'PY3'
import sys
vals = set()
for raw in open(sys.argv[1]):
    parts = raw.strip().split("|")
    if len(parts) == 6 and parts[5]:
        vals.add(parts[5])
print(sorted(vals, key=int)[-1] if vals else "")
PY3
)"
  if [ -n "${TOTAL_OBSERVED:-}" ] && [ "$TOTAL_OBSERVED" = "$ON_DISK" ]; then
    probe_ok "denominator $TOTAL_OBSERVED B == the summed *.safetensors of $CKPT (a file fact)"
  else
    probe_fail "wire said weightsBytesTotal=${TOTAL_OBSERVED:-<none>}, the directory holds $ON_DISK B" \
      " — the denominator is no longer the checkpoint, it is a number someone carried in"
  fi
else
  probe_note "no checkpoint directory at $CKPT (a hub cache layout or a scripted arm) — §3 has no" \
    " file to compare against; §2 still binds, and the denominator claim stays unproven here"
fi

# ── 4) the row closes with the load ──────────────────────────────────────────────────────────
probe_section "4) the row closes with the load (no stale progress on a ready id)"
probe_api GET /v1/models || true
STALE="$(printf '%s' "${PROBE_BODY:-}" | python3 -I -c '
import json,sys
target=sys.argv[1]
try: rows=json.load(sys.stdin).get("data",[])
except Exception: rows=[]
for m in rows:
    if m.get("id")==target:
        print(str(m.get("state"))+"|"+("present" if "loadProgress" in m else "absent"))
        break
' "$TARGET" 2>/dev/null || true)"
case "$STALE" in
  ready\|absent)
    probe_ok "ready with no loadProgress — nothing publishes bytes for a load that ended"
    ;;
  ready\|present)
    probe_fail "the row is ready and still carries loadProgress — a finished load keeps publishing" \
      " a percentage, which is the stale-clock defect this type was written against"
    ;;
  "")
    probe_fail "$TARGET left /v1/models entirely after loading — a client that was polling for the" \
      " wait cannot see the arrival"
    ;;
  *)
    probe_note "still $STALE after ${waited}s — §4 judged on what arrived; the wait bound is" \
      " OCOREAI_PROBE_LOAD_WAIT"
    ;;
esac

probe_summary "$PROBE_NAME"
