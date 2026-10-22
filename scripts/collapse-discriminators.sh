#!/usr/bin/env bash
# collapse-discriminators.sh — separate "per-process numerics" from "per-content state" for the
# degenerate-turn collapse. Probe 30 owns the failure shape and its rate; this script answers a
# different question, because every mechanism story told so far died on a missing control.
#
# ### What each arm discriminates (all numbers below are from one host, one model, greedy,
# ### `max_tokens=200`, fresh `session_id` per turn — re-run before quoting any of them)
#   A interleave : TARGET collapses 3/3 inside ONE process while two other prompts deliver
#                  200 and 173 tokens ⇒ the collapse is NOT a process-global bind. It also
#                  exposes the blind spot in "15 boots / 84 turns were unanimous": every boot
#                  repeated a single content, so unanimity was guaranteed by the content and
#                  could not distinguish the two hypotheses.
#   B nonce      : never-before-sent byte variants of the same task deliver 8/8 while TARGET
#                  collapses 3/4 ⇒ it is keyed to the exact prompt bytes, not the task.
#   C empty cache: TARGET still collapses with zero snapshots on disk ⇒ restoring a disk KV
#                  snapshot is not the mechanism.
#
# What survives: a content-specific decision that stays fixed inside a process and flips between
# processes. The next instrument is the logprob margin between EOS and the next candidate at
# slot 2 — and it cannot ride the chat face: `ChatSession.swift` contains zero references to
# `logProbabilities`/`LogProbabilityTokenLoopHandler`, and `.probability` events exist only at
# `LogProbabilityTokenLoopHandler.swift:9`, so assigning `chatSession.generateParameters
# .logProbabilities` would be a silent no-op (AGENTS.md: a knob the wire accepts must reach the
# engine; a stub substitution must be detectable at runtime).
#
### Hygiene — read before editing
# The cache move is registered with `probe_atexit` AFTER sourcing `_lib.sh`, and the restore is
# verified before exit. Writing `trap '…' EXIT` before the source silently replaces
# `probes_cleanup` (`_lib.sh:158`) — that is how a 695 MB cache move lost its restore and left
# the engine's prompt cache empty.
set -uo pipefail
source "$(dirname "$0")/probes/_lib.sh"
export OCOREAI_PROBE_KEEP_LOGS=1

CACHE="$HOME/Library/Application Support/ocoreai/cache/kvcache"
ORIG="$(mktemp -d -t ocoreai-kvbak-XXXXXX)"
CACHE_BACKUP_COUNT=0

# Idempotent, and verified unconditionally once arm C has run. Two failure modes this shape
# closes, both hit on the first run of this file:
#   • counting the backup dir *after* moving it back compares 44 against 0 and reports failure
#     on a good restore;
#   • `probes_cleanup`, which every arm calls between boots, drains PROBE_EXIT_HOOKS — so an
#     atexit restore runs mid-run and the end-of-run report never prints at all. A safety net
#     that only reports when it happens to be the last handler left is not a safety net.
restore_cache() {
  mv -f "$ORIG"/*.safetensors "$ORIG"/*.manifest.json "$CACHE"/ 2>/dev/null || true
  [ "$CACHE_BACKUP_COUNT" -gt 0 ] || return 0
  local n
  n=$(ls "$CACHE"/*.safetensors 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -ge "$CACHE_BACKUP_COUNT" ]; then
    echo "cache verified: $n snapshots at $CACHE (backed up $CACHE_BACKUP_COUNT)"
  else
    echo "CACHE NOT FULLY RESTORED: $n snapshots, expected >= $CACHE_BACKUP_COUNT — recover from $ORIG" >&2
    return 1
  fi
}
probe_atexit restore_cache

# Run one arm at a time while chasing: each arm boots its own engines, and a full pass is
# 3 x BOOTS boots. ARMS=A / ARMS=B / ARMS=C (default: all three).
ARMS="${ARMS:-ABC}"

TARGET='Count from 1 to 200, one number per line.'
D1='List every planet of the solar system, one per line, each with a short factual note.'
D2='Write ten short rhyming couplets about the sea, one couplet per line.'
BOOTS="${BOOTS:-3}"

tok() {
  python3 -c '
import json,sys
try: print(json.load(open(sys.argv[1])).get("usage",{}).get("completion_tokens","-"))
except Exception: print("-")' "$1"
}
ask() { # $1=session suffix  $2=prompt  -> "C" | "ok(N)"
  local body out t
  body=$(printf '{"model":"%s","max_tokens":200,"temperature":0.0,"stream":false,"session_id":"cd-%s","messages":[{"role":"user","content":"%s"}]}' \
    "$PROBE_MODEL" "$1" "$2")
  out=$(mktemp -t cd.XXXXXX)
  curl -sS -m 180 -X POST "$PROBE_BASE/v1/chat/completions" -H 'Content-Type: application/json' \
    --data "$body" -o "$out"
  t=$(tok "$out")
  rm -f "$out"
  if [ "${t:-0}" -le 1 ] 2>/dev/null; then printf 'C'; else printf 'ok(%s)' "$t"; fi
}
new_boot() {
  probe_boot >/dev/null 2>&1
  probe_require_ready_model >/dev/null 2>&1
}

case "$ARMS" in
  *A*)
    echo "arm A — content-specific or process-global? ($BOOTS boots, interleaved)"
    for b in $(seq 1 "$BOOTS"); do
      new_boot
      echo "  A boot=$b  T=$(ask "a${b}t1" "$TARGET")  D1=$(ask "a${b}d1" "$D1")  T=$(ask "a${b}t2" "$TARGET")  D2=$(ask "a${b}d2" "$D2")"
      probes_cleanup >/dev/null 2>&1
      sleep 2
    done
    ;;
esac

case "$ARMS" in
  *B*)
    echo "arm B — prompt bytes or task meaning? ($BOOTS boots, nonce variants never sent before)"
    for b in $(seq 1 "$BOOTS"); do
      new_boot
      echo "  B boot=$b  T=$(ask "b${b}t1" "$TARGET")  U1=$(ask "b${b}u1" "Count upward from 1 to 200, one integer per line. nonce-${b}a")  T=$(ask "b${b}t2" "$TARGET")  U2=$(ask "b${b}u2" "Count upward from 1 to 200, one integer per line. nonce-${b}b")"
      probes_cleanup >/dev/null 2>&1
      sleep 2
    done
    ;;
esac

case "$ARMS" in
  *C*)
    echo "arm C — disk KV snapshot or not? ($BOOTS boots, cache dir emptied before every boot)"
    mv -f "$CACHE"/* "$ORIG"/ 2>/dev/null || true
    CACHE_BACKUP_COUNT=$(ls "$ORIG"/*.safetensors 2>/dev/null | wc -l | tr -d ' ')
    echo "  backed up $CACHE_BACKUP_COUNT snapshots to $ORIG"
    for b in $(seq 1 "$BOOTS"); do
      rm -f "$CACHE"/*.safetensors "$CACHE"/*.manifest.json 2>/dev/null
      new_boot
      echo "  C boot=$b (cache empty)  T=$(ask "c${b}t1" "$TARGET")  U=$(ask "c${b}u" "Count upward from 1 to 200, one integer per line. ncn-${b}")  T=$(ask "c${b}t2" "$TARGET")"
      probes_cleanup >/dev/null 2>&1
      sleep 2
    done
    restore_cache
    rmdir "$ORIG" 2>/dev/null || true
    ;;
esac
