#!/usr/bin/env bash
# Reproducible benchmark artifact — scripted lane.
#
# One command (`make bench`) regenerates scripts/bench/results/scripted.json: host,
# toolchain, commit, conditions and four metrics, each the median of repeats. The lane
# boots the real `serve` route with OCOREAI_SCRIPTED_ENGINE (a script path replacing the
# model, never the wire), so it costs no weights, no Metal device and no model download —
# any machine that builds the binary can regenerate and diff the artifact.
#
# Lane honesty: the scripted engine emits pre-declared tokens, so tok_s here measures
# HTTP/SSE plumbing overhead, NOT model throughput; only cross-build comparison is
# legitimate. The live-weight tok/s lane is a planned second mode and is absent from this
# artifact (no number claimed — invariant 2). Each run also asserts its own work happened:
# streamed segments byte-match the script and usage equals the declared counts (a bench
# whose work may not have run is not an instrument). Publishing these numbers externally
# is a release act needing owner authorization; regeneration is open.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../probes/_lib.sh
source "$HERE/../probes/_lib.sh"   # boot, binary resolution, stale reaping — one home
PROBE_NAME="bench-scripted"

OUT="${OCOREAI_BENCH_OUT:-$PROBE_REPO_ROOT/scripts/bench/results/scripted.json}"
REPEATS="${OCOREAI_BENCH_REPEATS:-3}"

# The fixture: 200 segments x 8 tokens + 64 thinking tokens = 1664 generated,
# prompt 512 — counts declared by the script itself, asserted equal to usage below.
SCRIPT_FILE="$(mktemp -t ocoreai-bench-script-XXXXXX).json"
probe_atexit "rm -f '$SCRIPT_FILE'"
python3 - "$SCRIPT_FILE" <<'PY'
import json, sys
# Space trails each segment: the scripted lane trims the assembled content channel's
# outer whitespace, so a leading-space fixture would assert a contract the lane does
# not offer (the probe fleet misses the trim — no probe's first segment is prefixed).
seg = "alpha bravo charlie delta echo foxtrot golf hotel "   # 8 nominal tokens
with open(sys.argv[1], "w") as f:
    json.dump({
    "reasoning": ["thinking " * 16],                          # 64 nominal tokens
    "segments": [seg] * 200,
    "finishReason": "eos",
        "promptTokens": 512,
        "generatedTokens": 1664,
    }, f)
PY
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"
probe_note "fixture $SCRIPT_FILE — 200 segments x 8 tok + 64 thinking, declared 512/1664"

# Release build, pinned: a Debug binary would measure Debug (benchmark checklist: every
# side runs the way production runs it), and an unpinned boot picks the newest binary
# in either build dir, which is not necessarily ours.
BENCH_BIN="$(swift build -c release --show-bin-path)/ocoreai"
swift build -c release >/dev/null
export OCOREAI_BIN="$BENCH_BIN"
probe_boot
mkdir -p "$(dirname "$OUT")"
python3 "$HERE/_bench.py" --port "$PROBE_PORT" --repeats "$REPEATS" --out "$OUT" \
  --repo-root "$PROBE_REPO_ROOT" --expect-script "$SCRIPT_FILE" --bin "$BENCH_BIN"
probe_note "artifact $OUT — regenerate with: make bench"
