#!/usr/bin/env bash
# _lib.sh — shared harness for the live HTTP probes in scripts/probes/.
#
# Why this directory exists (AGENTS.md § Open, 10-14): the live conclusions this
# repo publishes were produced by ad-hoc scripts that lived in a temp dir
# (`live24.py` on port 8124, the count-tokens triple on port 8157). Neither is in
# git, so no measurement in CHANGELOG/AGENTS.md could be re-run by anyone else, and
# the evidence left with the temp dir. mlx-swift-lm pins its probes as
# `tests/test_*.sh`; this directory does the same for ocoreai's HTTP surface, so a
# conclusion points at a script name instead of at a story.
#
# Contract every probe here keeps:
#   • It boots its OWN server on a free port, so runs are repeatable and never ride
#     on a GUI instance someone else left open.
#   • A server that never became ready is a FAILURE with the remedy, never a silent
#     skip — a check that passes vacuously is worse than no check (invariant 1).
#   • It floors its own premises: an assertion block that produced no verdict fails.
#   • It prints the raw measured numbers, not only a verdict, so a doc claim can be
#     re-checked against a run instead of re-argued.
#   • No model id is hardcoded: it reads GET /v1/models and uses a ready model.
#
# Environment knobs:
#   OCOREAI_BIN            binary to probe (default: newest of .build-clt/debug and
#                          .build/debug; a release binary works too)
#   OCOREAI_PROBE_PORT     port to bind (default: OS-assigned free port)
#   OCOREAI_READY_TIMEOUT  seconds to wait for /health (default 240: a cold model
#                          load here is ~8-15 s, a first Metal shader compile is more)
#   OCOREAI_API_KEYS       passed through to the server; when set, probes send
#                          `Authorization: Bearer <first key>` like a real client
#   OCOREAI_PROBE_KEEP_LOGS=1  keep the server log and print its path

# Deliberately NOT `-e`: probes count failures and report them all in one run.
set -uo pipefail

PROBE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_REPO_ROOT="$(cd "$PROBE_LIB_DIR/../.." && pwd)"

PROBE_PASS=0
PROBE_FAIL=0
PROBE_INFO=0

PROBE_OS="$(uname -s)-$(uname -r) $(uname -m)"

probe_section() {
  printf '\n── %s\n' "$*"
}

probe_ok() {
  PROBE_PASS=$(( PROBE_PASS + 1 ))
  printf '  PASS  %s\n' "$*"
}

probe_fail() {
  PROBE_FAIL=$(( PROBE_FAIL + 1 ))
  printf '  FAIL  %s\n' "$*"
}

# A measured fact that is not itself a pass/fail — printed so the number outlives
# the session, which is the whole point of keeping probes in git.
probe_note() {
  PROBE_INFO=$(( PROBE_INFO + 1 ))
  printf '  NOTE  %s\n' "$*"
}

# Verdict. Fails when nothing was asserted: a probe whose checks never ran must not
# report success (the vacuous-pass family).
probe_summary() {
  local name="$1"
  printf '\n%s: %d passed, %d failed, %d measured\n' "$name" "$PROBE_PASS" "$PROBE_FAIL" "$PROBE_INFO"
  if [ "$PROBE_FAIL" -gt 0 ]; then
    exit 1
  fi
  if [ "$PROBE_PASS" -eq 0 ]; then
    echo "FAIL  no assertion executed — this run proves nothing"
    exit 1
  fi
  exit 0
}

# ── cleanup ────────────────────────────────────────────────────────────────────
PROBE_PID=""
PROBE_LOG=""
PROBE_EXIT_HOOKS=""

# Register a cleanup action *without* replacing the trap.
#
# Bash keeps one handler per signal, so a probe that writes its own `trap '…' EXIT`
# silently replaces probes_cleanup. That is exactly how 10-17 lost three probes:
# 05-hearing.sh installed `trap 'rm -f "$AIFF"' EXIT INT TERM`, its server never got
# TERM'd, the flock in Core/SingleInstanceLock.swift stayed held, and 06/07/08 each
# burned the full 240 s ready-timeout on "Another ocoreai instance is already running" —
# a leak reported three times as "Metal unavailable or model load stuck", which is the
# wrong diagnosis, at 12 minutes a run.
probe_atexit() {
  if [ -n "$PROBE_EXIT_HOOKS" ]; then
    PROBE_EXIT_HOOKS="$PROBE_EXIT_HOOKS
$1"
  else
    PROBE_EXIT_HOOKS="$1"
  fi
}

probes_cleanup() {
  local hooks="$PROBE_EXIT_HOOKS"
  PROBE_EXIT_HOOKS=""
  if [ -n "$hooks" ]; then
    eval "$hooks" || true
  fi
  [ -n "$PROBE_PID" ] || return 0
  kill -TERM "$PROBE_PID" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$PROBE_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill -KILL "$PROBE_PID" 2>/dev/null || true
  PROBE_PID=""
  if [ -n "$PROBE_LOG" ] && [ "${OCOREAI_PROBE_KEEP_LOGS:-}" != "1" ]; then
    rm -f "$PROBE_LOG"
  fi
}
trap probes_cleanup EXIT INT TERM

# Reap a stale engine before booting ours.
#
# Scope is deliberately narrow: only an `ocoreai` whose executable lives under this repo's
# build dirs can be ours to clean up. Anything else (the GUI app, a server started by hand)
# is reported with its pid and the remedy, never killed.
probe_reap_stale_instances() {
  local pid exe foreign
  foreign=""
  for pid in $(pgrep -x ocoreai 2>/dev/null || true); do
    [ "$pid" = "$PROBE_PID" ] && continue
    exe="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/[[:space:]]*$//')"
    case "$exe" in
      "$PROBE_REPO_ROOT/.build-clt/"* | "$PROBE_REPO_ROOT/.build/"*)
        probe_note "reaping stale probe-built ocoreai pid $pid — it holds the single-instance lock and would kill this server at boot"
        kill -TERM "$pid" 2>/dev/null || true
        ;;
      *)
        foreign="$foreign $pid($exe)"
        ;;
    esac
  done
  for _ in $(seq 1 40); do
    pgrep -x ocoreai >/dev/null 2>&1 || break
    sleep 0.5
  done
  for pid in $(pgrep -x ocoreai 2>/dev/null || true); do
    [ "$pid" = "$PROBE_PID" ] && continue
    exe="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/[[:space:]]*$//')"
    case "$exe" in
      "$PROBE_REPO_ROOT/.build-clt/"* | "$PROBE_REPO_ROOT/.build/"*)
        kill -KILL "$pid" 2>/dev/null || true
        ;;
    esac
  done
  if [ -n "$foreign" ]; then
    probe_note "instance(s) outside this repo hold the single-instance lock:$foreign — not touched; kill them or set OCOREAI_ALLOW_MULTI_INSTANCE=1"
  fi
}

# ── helpers ────────────────────────────────────────────────────────────────────
probe_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Which binary to probe: the one built from the pinned, clean dependency tree; the newest
# when nothing distinguishes them.
#
# What this replaces promised "newest" in a comment and delivered "first existing".
# SwiftPM 6.4 emits products at <scratch>/out/Products/<config>/ocoreai, so
# `.build-clt/debug/ocoreai` has not existed on this host since the toolchain moved, and
# the loop fell through to `.build/debug/ocoreai` — measured 10-17: five days stale and
# built from mlx-swift-lm 7eb77efa while the pin says 6e338e5df. Every number such a run
# reports describes code this repo does not ship. The pin guard further down does catch
# it, but only because it derives the scratch path *from the chosen binary*; resolution
# itself was the defect, and it picked wrong by default.
#
# Score, highest wins: 2 = built from a dependency checkout that is clean and at the pin,
# 1 = not verifiable (no checkout / no .git), 0 = dirty or off-pin. Ties break on
# mtime, so a verifiable tree beats an unverifiable one, and among verifiable trees the
# freshest build wins.
probe_scratch_for_binary() {
  # Walk up from the binary until the SwiftPM scratch dir itself, because the product
  # depth is a toolchain property: SwiftPM 6.1 put it at <scratch>/<config>/ocoreai, 6.4
  # at <scratch>/out/Products/<config>/ocoreai. Deriving it by a fixed number of hops
  # (the old `dirname/../`) silently pointed at `.build-clt/out/Products`, so the pin and
  # cleanliness premise of every measurement printed "not verifiable" instead of holding.
  local p
  p="$(cd "$(dirname "$1")" && pwd)" || return 1
  while [ "$p" != "/" ]; do
    case "${p##*/}" in
      .build|.build-*) printf '%s\n' "$p"; return 0 ;;
    esac
    p="${p%/*}"
  done
  printf '\n'
}

probe_dependency_score() {
  local bin="$1" scratch c pin head dirty
  scratch="$(probe_scratch_for_binary "$bin")"
  if [ -z "$scratch" ]; then
    printf '1\n'
    return 0
  fi
  c="$scratch/checkouts/mlx-swift-lm"
  if [ ! -d "$c/.git" ]; then
    printf '1\n'
    return 0
  fi
  dirty="$(git -C "$c" status --porcelain 2>/dev/null | grep -c . || true)"
  if [ "${dirty:-0}" -gt 0 ]; then
    printf '0\n'
    return 0
  fi
  pin="$(sed -nE 's/.*mlx-swift-lm\.git", *revision: "([0-9a-f]+)".*/\1/p' \
    "$PROBE_REPO_ROOT/Package.swift" | head -1)"
  head="$(git -C "$c" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$pin" ] && [ "${head#"$pin"}" = "$head" ]; then
    printf '0\n'
    return 0
  fi
  printf '2\n'
}

probe_resolve_binary() {
  if [ -n "${OCOREAI_BIN:-}" ]; then
    if [ ! -x "${OCOREAI_BIN}" ]; then
      printf 'OCOREAI_BIN=%s is not an executable file\n' "$OCOREAI_BIN" >&2
      return 1
    fi
    printf '%s\n' "$OCOREAI_BIN"
    return 0
  fi
  local candidate mtime score
  local best="" best_score=-1 best_mtime=-1
  for candidate in \
    "$PROBE_REPO_ROOT/.build-clt/out/Products/Debug/ocoreai" \
    "$PROBE_REPO_ROOT/.build-clt/out/Products/Release/ocoreai" \
    "$PROBE_REPO_ROOT/.build-clt/debug/ocoreai" \
    "$PROBE_REPO_ROOT/.build-clt/release/ocoreai" \
    "$PROBE_REPO_ROOT/.build/out/Products/Debug/ocoreai" \
    "$PROBE_REPO_ROOT/.build/out/Products/Release/ocoreai" \
    "$PROBE_REPO_ROOT/.build/debug/ocoreai" \
    "$PROBE_REPO_ROOT/.build/release/ocoreai"
  do
    [ -x "$candidate" ] || continue
    mtime="$(stat -f %m "$candidate" 2>/dev/null || echo 0)"
    score="$(probe_dependency_score "$candidate")"
    if [ "$score" -gt "$best_score" ] \
      || { [ "$score" -eq "$best_score" ] && [ "$mtime" -gt "$best_mtime" ]; }; then
      best="$candidate"
      best_score="$score"
      best_mtime="$mtime"
    fi
  done
  [ -n "$best" ] || return 1
  # stderr, because the path is the function's stdout contract and a caller captures it.
  printf 'resolved %s (dependency score %s)\n' "$best" "$best_score" >&2
  printf '%s\n' "$best"
  return 0
}

# Extract one value from a JSON document by dotted path (list indices as digits).
# Prints empty string and returns 0 when the path is absent, so callers can test for
# a missing field without juggling python tracebacks.
probe_json() {
  PROBE_JSON_INPUT="$1" PROBE_JSON_PATH="$2" python3 - <<'PY'
import json, os, sys
node = None
try:
    node = json.loads(os.environ["PROBE_JSON_INPUT"])
except Exception:
    print("")
    sys.exit(0)
for part in os.environ["PROBE_JSON_PATH"].split("."):
    if isinstance(node, list):
        try:
            node = node[int(part)]
        except Exception:
            print("")
            sys.exit(0)
    elif isinstance(node, dict):
        if part not in node:
            print("")
            sys.exit(0)
        node = node[part]
    else:
        print("")
        sys.exit(0)
if node is None:
    print("")
elif isinstance(node, bool):
    print("true" if node else "false")
elif isinstance(node, (list, dict)):
    print(json.dumps(node, separators=(",", ":")))
else:
    print(node)
PY
}

# ── server lifecycle ───────────────────────────────────────────────────────────
PROBE_BASE=""

## Premise: the dependency tree we just probed is the tree that ships.
#
# A local patch left in a SwiftPM checkout is invisible to `git status` in this repo,
# invisible to CI (which resolves the pin from GitHub), and silently changes what every
# measurement here describes. Found the hard way on 10-14: 21 uncommitted debug lines sat
# in `.build-clt/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/ChatSession.swift` — the
# exact file the open prefix-cache conclusions are about — while AGENTS.md asserted the
# clone, the pin and the checkout were byte-identical. All three were different.
probe_require_clean_dependency_checkout() {
  local scratch="$1" pin c other head dirty
  pin="$(sed -nE 's/.*mlx-swift-lm\.git", *revision: "([0-9a-f]+)".*/\1/p' \
    "$PROBE_REPO_ROOT/Package.swift" | head -1)"

  # The scratch path that produced the binary under test — this is the tree the
  # measurement describes, so dirt or a pin mismatch here invalidates the run.
  c="$scratch/checkouts/mlx-swift-lm"
  if [ ! -d "$c" ]; then
    probe_note "no mlx-swift-lm checkout under $scratch — pin not verifiable for this binary"
  elif [ ! -d "$c/.git" ]; then
    probe_note "$c has no .git — pin not verifiable for this binary"
  else
    dirty="$(git -C "$c" status --porcelain 2>/dev/null | grep -c . || true)"
    head="$(git -C "$c" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "${dirty:-0}" -gt 0 ]; then
      probe_fail "the checkout this binary was built from is DIRTY ($dirty file(s)) — it contains code CI will never compile:"
      git -C "$c" status --porcelain | sed 's/^/        /'
    elif [ -n "$pin" ] && [ "${head#"$pin"}" = "$head" ]; then
      probe_fail "$c is at ${head:0:9} but Package.swift pins $pin — the binary under test is not the pinned upstream"
    else
      probe_ok "built-from checkout clean at the pin (${head:0:9})"
    fi
  fi

  # Other scratch dirs on this host: not this measurement's premise, but a stale one is
  # a live trap for the next plain `swift build` (no --scratch-path) or an Xcode build.
  for other in "$PROBE_REPO_ROOT/.build" "$PROBE_REPO_ROOT/.build-clt"; do
    [ "$other" = "$scratch" ] && continue
    [ -d "$other/checkouts/mlx-swift-lm/.git" ] || continue
    head="$(git -C "$other/checkouts/mlx-swift-lm" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ -n "$pin" ] && [ "${head#"$pin"}" = "$head" ]; then
      probe_note "STALE scratch $other holds mlx-swift-lm ${head:0:9}, not the pinned $pin — a build that resolves from there gets different code (self-heals on the next swift build against it)"
    fi
  done
}

# Boot `ocoreai serve` and block until /health answers. Fails the run — loudly,
# with the remedy — when the engine cannot come up.
probe_boot() {
  local bin
  if ! bin="$(probe_resolve_binary)"; then
    probe_fail "no ocoreai binary found — build first (swift build, or the CLT route in Makefile)"
    probe_summary "${PROBE_NAME:-probe}"
  fi
  probe_require_clean_dependency_checkout "$(probe_scratch_for_binary "$bin")"
  probe_reap_stale_instances
  PROBE_PORT="${OCOREAI_PROBE_PORT:-$(probe_free_port)}"
  PROBE_BASE="http://127.0.0.1:${PROBE_PORT}"
  PROBE_LOG="$(mktemp -t ocoreai-probe-XXXXXX).log"
  probe_note "binary $bin"
  probe_note "bridge $PROBE_BASE · log ${PROBE_LOG}"

  # stdin must be /dev/null: HeadlessServer installs a stdin-EOF shutdown watcher for
  # pipes and TTYs (agent-harness semantics). A background probe launched from a
  # script would otherwise be killed by its own closed pipe at t=0.
  OCOREAI_ENABLE_HTTP=1 \
  OCOREAI_HOST=127.0.0.1 \
  OCOREAI_PORT="$PROBE_PORT" \
    "$bin" serve < /dev/null > "$PROBE_LOG" 2>&1 &
  PROBE_PID=$!

  local waited=0 timeout="${OCOREAI_READY_TIMEOUT:-240}"
  while [ "$waited" -lt "$timeout" ]; do
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      probe_fail "server exited during boot (waited ${waited}s) — last lines:"
      tail -20 "$PROBE_LOG" | sed 's/^/        /'
      probe_summary "${PROBE_NAME:-probe}"
    fi
    local code
    code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$PROBE_BASE/health" 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then
      probe_ok "/health 200 after ${waited}s"
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  probe_fail "/health never answered 200 within ${timeout}s — Metal unavailable or model load stuck. Last lines:"
  tail -20 "$PROBE_LOG" | sed 's/^/        /'
  echo "        If this host reports \"No Metal device available\", run this probe outside the agent sandbox"
  echo "        (make test-clt is the same route) — inside it MLX cannot load a device."
  probe_summary "${PROBE_NAME:-probe}"
}

# First model GET /v1/models reports as ready. Sets PROBE_MODEL.
PROBE_MODEL=""
probe_require_ready_model() {
  probe_api GET /v1/models || true
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "GET /v1/models -> ${PROBE_STATUS:-no response}"
    probe_summary "${PROBE_NAME:-probe}"
  fi
  PROBE_MODEL="$(probe_json "$PROBE_BODY" 'data.0.id')"
  if [ -z "$PROBE_MODEL" ]; then
    # Prefer an explicitly ready entry; `state` is how this server says "loadable".
    PROBE_MODEL="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1]).get("data", [])
except Exception:
    sys.exit(0)
for m in data:
    if str(m.get("state", "ready")) == "ready":
        print(m.get("id", ""))
        break
PY
)"
  fi
  if [ -z "$PROBE_MODEL" ]; then
    probe_fail "no ready model reported by /v1/models — nothing to run against. Put a model in ~/.ocoreai/models or POST /v1/models/download first."
    probe_summary "${PROBE_NAME:-probe}"
  fi
  probe_note "model $PROBE_MODEL"
}

PROBE_STATUS=""
PROBE_BODY=""

# probe_api METHOD PATH [JSON_BODY]  → PROBE_STATUS / PROBE_BODY
probe_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -X "$method" -w $'\n%{http_code}')
  if [ -n "${OCOREAI_API_KEYS:-}" ]; then
    args+=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
  fi
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  local raw
  if ! raw="$(curl "${args[@]}" "$PROBE_BASE${path}" 2>&1)"; then
    PROBE_STATUS="000"
    PROBE_BODY="$raw"
    return 1
  fi
  PROBE_STATUS="${raw##*$'\n'}"
  PROBE_BODY="${raw%$'\n'*}"
  return 0
}

# POST a non-streaming chat turn; echoes client-side elapsed ms in PROBE_ELAPSED_MS.
PROBE_ELAPSED_MS=0
probe_chat() {
  local session_id="$1" body="$2"
  local start end
  start="$(python3 -c 'import time;print(int(time.time()*1000))')"
  probe_api POST /v1/chat/completions "$body"
  local rc=$?
  end="$(python3 -c 'import time;print(int(time.time()*1000))')"
  PROBE_ELAPSED_MS=$(( end - start ))
  return $rc
}

# Build one chat turn body with a deliberately long system prompt, so prefill is
# large enough for prompt-time differences to be measurable rather than noise.
probe_chat_body() {
  local session_id="$1" messages_json="$2" max_tokens="${3:-8}"
  python3 - "$PROBE_MODEL" "$session_id" "$messages_json" "$max_tokens" "${PROBE_SYS_PAD:-}" <<'PY'
import json, sys
model, session_id, messages, max_tokens, pad = sys.argv[1:6]
body = {
    "model": model,
    "session_id": session_id,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "messages": json.loads(messages),
}
if pad:
    body["messages"] = [{"role": "system", "content": pad}] + body["messages"]
print(json.dumps(body))
PY
}

# Long, deterministic filler text (no randomness — runs must be comparable).
probe_pad_text() {
  python3 - "${1:-40}" <<'PY'
import sys
units = int(sys.argv[1])
sentence = ("The engineering rule for this system is that a promise on the wire must be "
            "backed by something the engine can actually deliver, and every claim needs a "
            "check that goes red when the claim stops being true. ")
print(" ".join([sentence] * units))
PY
}
