#!/usr/bin/env bash
# 45-cli-argument-honesty.sh — an informational CLI call must never boot, and a flag nobody
# reads must be refused before the bind rather than ignored after it.
#
# Measured 10-31 on this host: `ocoreai serve --help` started the production server — crash
# handlers, SQLite against the caller's own data directory, the single-instance lock — and printed
# no usage at all. `serve --port 9090` did the same on the *default* port, because the flag was
# "documented but not yet consumed". Both are the defect `CLIMode`'s header already records for
# `--version` (live-tested 10-11), one token later: the first token after argv[0] was the only one
# ever inspected, so anything after `serve` was accepted and dropped.
#
# The observable is the exit code plus an empty port: 0 for usage, 64 (EX_USAGE) for a refusal,
# and nothing listening afterwards. Bare `serve` booting is not re-probed here — that is the CI
# headless smoke step's sentence, and this probe costs no model and no boot.
#
# Every leg exports OCOREAI_DATA_DIR into a temp dir first: if a regression does boot, it boots
# into a scratch store rather than the operator's, which is the difference between a red probe
# and a wrecked session.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source _lib.sh

BIN="$(probe_resolve_binary)" || exit 1
PORT="$(probe_free_port)"
# Registered, never `trap`: a bare trap inside a probe silently replaces `_lib.sh`'s
# `probes_cleanup`, which is how 10-17 leaked a server and left three later probes burning their
# ready-timeout on the single-instance lock while blaming Metal.
STORE="$(mktemp -d -t ocoreai-cli-XXXXXX)"
OUT="$(mktemp)"
ERRF="$(mktemp)"
probe_atexit 'rm -rf "$STORE" "$OUT" "$ERRF"'

# Bounded run: if the invocation boots, it never exits, so "still alive" IS the failure. Ten
# seconds is generous against a measured ~3 s boot on this host.
# The return is read through `$?`, never through `if` — a conditional resets it to 0.
run_bounded() {
  : > "$OUT"; : > "$ERRF"
  OCOREAI_ENABLE_HTTP=1 OCOREAI_HOST=127.0.0.1 OCOREAI_PORT="$PORT" \
    OCOREAI_DATA_DIR="$STORE" OCOREAI_APPROVAL_POLICY=auto \
    "$@" < /dev/null > "$OUT" 2> "$ERRF" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
    if [ "$waited" -ge 10 ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 99
    fi
  done
  wait "$pid"
}

probe_section "1) serve --help answers usage and binds nothing"
run_bounded "$BIN" serve --help
RC=$?
if [ "$RC" = "0" ]; then
  if grep -q "USAGE:" "$OUT" && grep -q "OCOREAI_PORT" "$OUT"; then
    probe_ok "serve --help printed usage carrying the real configuration channel"
  else
    probe_fail "exit 0 without usage on stdout: $(head -c 160 "$OUT")"
  fi
elif [ "$RC" = "99" ]; then
  probe_fail "serve --help booted instead of answering — an informational call owns the process"
else
  probe_fail "serve --help exited $RC — expected 0 with usage"
fi

probe_section "2) serve --port 9090 is refused, naming the token it cannot honour"
run_bounded "$BIN" serve --port 9090
RC2=$?
if [ "$RC2" = "64" ]; then
  if grep -q -- "--port" "$ERRF" && grep -q "takes no arguments" "$ERRF"; then
    probe_ok "refused with the token quoted and the env remedy: $(head -c 160 "$ERRF")"
  else
    probe_fail "exit 64 that does not name what it refused: $(head -c 160 "$ERRF")"
  fi
elif [ "$RC2" = "99" ]; then
  probe_fail "serve --port 9090 booted on the default port — a flag nobody reads steered nothing"
else
  probe_fail "serve --port 9090 exited $RC2 — expected 64 (EX_USAGE)"
fi

probe_section "3) -h after serve, and the port stayed shut"
run_bounded "$BIN" serve -h
RC3=$?
if [ "$RC3" = "0" ] && grep -q "USAGE:" "$OUT"; then
  probe_ok "serve -h answered usage in $BIN"
else
  probe_fail "serve -h exited $RC3 with $(wc -c < "$OUT") stdout bytes"
fi
if curl -s -m 2 -o /dev/null "http://127.0.0.1:${PORT}/health"; then
  probe_fail "something is listening on $PORT after three refusals — a refusal booted"
else
  probe_ok "nothing bound on $PORT — every refusal stayed a refusal"
fi
