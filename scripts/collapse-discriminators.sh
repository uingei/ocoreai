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
#   E margin×outcome : 12 boots in `OCOREAI_MARGIN_PROBE=all`. Identical bytes landed in FOUR
#                  discrete step-1 logprob regimes and the outcome tracked the regime with zero
#                  overlap: collapsed lp −0.0111/−0.0094 (margin 5.5677/5.8204, n=3) vs healthy
#                  lp −0.0278/−0.0222 (margin 4.4361/4.6290, n=9). So certainty, not a near-tie,
#                  precedes the collapse; a margin width cannot be the mechanism (the collapsed
#                  margins are the wider ones); and a collapsed turn records no step 2 at all.
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
# The arms below judge themselves on the probe's log lines, and nothing else in this repo sets the
# switch: an operator who forgets it gets zero probe lines, which arm D used to count as collapsed
# replays and print as a verdict. Arm it here (one home); arm E widens it to every turn.
export OCOREAI_MARGIN_PROBE="${OCOREAI_MARGIN_PROBE:-1}"

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

case "$ARMS" in
  *D*)
    # Arm D — the carrier. Measured on this host: on a process whose real turn collapsed, the
    # probe re-runs the SAME prompt bytes (fidelity=match against the turn's own promptTokens)
    # and reports how many tokens it got before the model answered EOS.
    #   parity (engine's GenerateParameters, kvCache included) -> reconstruction stops at step1,
    #     the same one-token shape as the real collapse;
    #   OCOREAI_MARGIN_NO_KV=1 (kvCache dropped, everything else identical) -> the reconstruction
    #     reaches step2 and beyond.
    # One field, two outcomes, same process, same bytes: the KV-cache configuration is what
    # carries the collapse. Both legs must actually see a collapse, or the run is INCONCLUSIVE —
    # a leg that never fired proves nothing, and the rate on this host swings across boots.
    echo "arm D — which configuration carries the collapse? ($BOOTS boots per leg)"
    PARITY_HITS=0
    PARITY_COLLAPSED_REPLAY=0
    NOKV_HITS=0
    NOKV_SURVIVED_REPLAY=0
    for LEG in parity nokv; do
      if [ "$LEG" = nokv ]; then export OCOREAI_MARGIN_NO_KV=1; else unset OCOREAI_MARGIN_NO_KV; fi
      for b in $(seq 1 "$BOOTS"); do
        new_boot
        for t in 1 2 3; do
          answer=$(ask "d${LEG}${b}${t}" "$TARGET")
          case "$answer" in C) ;; *) continue ;; esac
          LINE=$(grep "Degenerate margin probe" "$PROBE_LOG" | tail -1)
          STEPS=$(printf '%s' "$LINE" | grep -c "step[0-9]* chose")
          FID=$(printf '%s' "$LINE" | grep -o "fidelity=[a-zA-Z]*" | head -1)
          # Vacuity guard: a leg may only count a replay whose reconstruction was verified. An
          # absent line or fidelity=UNVERIFIED carries no number, and counting it would let a
          # scan that stopped matching decide the verdict.
          if [ -z "$LINE" ] || [ "$FID" != "fidelity=match" ]; then
            echo "  D $LEG boot=$b turn=$t NO VERIFIED PROBE (${FID:-no probe line}) — not counted"
            continue
          fi
          if [ "$LEG" = parity ]; then
            PARITY_HITS=$((PARITY_HITS + 1))
            [ "$STEPS" -le 1 ] && PARITY_COLLAPSED_REPLAY=$((PARITY_COLLAPSED_REPLAY + 1))
          else
            NOKV_HITS=$((NOKV_HITS + 1))
            [ "$STEPS" -ge 2 ] && NOKV_SURVIVED_REPLAY=$((NOKV_SURVIVED_REPLAY + 1))
          fi
          echo "  D $LEG boot=$b turn=$t $FID replay_steps=$STEPS"
        done
        probes_cleanup >/dev/null 2>&1
        sleep 2
      done
    done
    echo "  D summary: parity replays collapsed $PARITY_COLLAPSED_REPLAY/$PARITY_HITS; no-kv replays survived $NOKV_SURVIVED_REPLAY/$NOKV_HITS"
    if [ "$PARITY_HITS" -eq 0 ] || [ "$NOKV_HITS" -eq 0 ]; then
      echo "  D VERDICT: INCONCLUSIVE — one leg never saw a collapse, so nothing was separated"
    elif [ "$PARITY_COLLAPSED_REPLAY" -eq "$PARITY_HITS" ] && [ "$NOKV_SURVIVED_REPLAY" -eq "$NOKV_HITS" ]; then
      echo "  D VERDICT: kvCache configuration carries the collapse (every parity replay collapsed, every no-kv replay continued)"
    else
      echo "  D VERDICT: SEPARATION BROKEN — replay shape no longer tracks kvCache; the carrier changed, re-open the hunt"
    fi
    ;;
esac

case "$ARMS" in
  *E*)
    # Arm E — does the margin actually predict the outcome? Arms A–D measure a margin only where a
    # turn ALREADY collapsed, so "small margin ⇒ collapse" never had a healthy comparison in the
    # same build. `OCOREAI_MARGIN_PROBE=all` runs the reconstruction after every turn on the
    # standard path, pairing each outcome with the margin of its own prompt bytes.
    #   groups separate (healthy margins wider than every collapsed one) -> the near-tie is the
    #     decision point, and the carrier is whatever moves it between processes;
    #   margins stable across boots while the outcome flips -> slot ordering is NOT what flips,
    #     and the terminator sits downstream of the logits (mask / grammar / eos handling).
    echo "arm E — margin paired with outcome ($BOOTS boots, probe on every turn)"
    ROWS=$(mktemp -t armE.XXXXXX)
    for b in $(seq 1 "$BOOTS"); do
      export OCOREAI_MARGIN_PROBE=all
      new_boot
      answer=$(ask "e${b}t" "$TARGET")
      LINE=$(grep "Degenerate margin probe" "$PROBE_LOG" | tail -1)
      printf '%s\t%s\t%s\n' "$b" "$answer" "$LINE" >> "$ROWS"
      echo "  E boot=$b outcome=$answer :: $(printf '%s' "${LINE#*:: }" | cut -c1-150)"
      probes_cleanup >/dev/null 2>&1
      sleep 2
    done
    unset OCOREAI_MARGIN_PROBE
    ROWS="$ROWS" python3 - <<'PY'
import os
import re

STEP = re.compile(
    r"step(\d+) chose '(.*?)' id=(-?\d+) lp=(-?[\d.]+) rival='(.*?)' id=(-?\d+) "
    r"margin=(-?[\d.]+|[-])"
)
rows = [l.rstrip("\n").split("\t") for l in open(os.environ["ROWS"]) if l.strip()]
healthy, collapsed, noprobe = [], [], 0
for boot, outcome, line in rows:
    steps = {int(m.group(1)): m for m in STEP.finditer(line)}
    if not steps:
        noprobe += 1
        continue
    m1 = steps.get(1)
    m2 = steps.get(2)
    rec = (
        float(m1.group(7)) if m1 and m1.group(7) != "-" else None,
        float(m2.group(7)) if m2 and m2.group(7) != "-" else None,
        float(m1.group(4)) if m1 else None,
    )
    (collapsed if outcome == "C" else healthy).append(rec)


# The outcome is already decided by the first sampled token, so the discriminator to test is
# step1's chosen logprob: does this process land in one discrete logits regime or another?
def fmt(group, idx):
    vals = [g[idx] for g in group if g[idx] is not None]
    if not vals:
        return "n/a"
    return "min=%.4f max=%.4f n=%d" % (min(vals), max(vals), len(vals))


print(
    "  E rows=%d (collapsed=%d healthy=%d no-probe=%d)"
    % (len(rows), len(collapsed), len(healthy), noprobe)
)
print("  E step1 margin — collapsed: %s | healthy: %s" % (fmt(collapsed, 0), fmt(healthy, 0)))
print("  E step2 margin — collapsed: %s | healthy: %s" % (fmt(collapsed, 1), fmt(healthy, 1)))
c0 = [g[2] for g in collapsed if g[2] is not None]
h0 = [g[2] for g in healthy if g[2] is not None]
print("  E step1 chosen lp — collapsed: %s | healthy: %s" % (fmt(collapsed, 2), fmt(healthy, 2)))
print("  E distinct step1 lp values: %s" % sorted({round(v, 4) for v in c0 + h0}))
c1 = [g[0] for g in collapsed if g[0] is not None]
h1 = [g[0] for g in healthy if g[0] is not None]
if not c1 or not h1:
    print("  E VERDICT: INCONCLUSIVE — need both a collapsed and a healthy turn in this run")
elif min(h1) > max(c1):
    print(
        "  E VERDICT: MARGIN SEPARATES — every healthy turn cleared every collapsed turn"
        " (gap %.4f nats at step1): the near-tie is the decision point" % (min(h1) - max(c1))
    )
elif max(c1) - min(c1) < 1e-3 and max(h1) - min(h1) < 1e-3:
    print(
        "  E VERDICT: MARGIN IS STABLE WHILE OUTCOME FLIPS — slot ordering is not what"
        " flips; look downstream of the logits (mask / grammar / eos handling)"
    )
else:
    print(
        "  E VERDICT: OVERLAP — collapsed %.4f..%.4f vs healthy %.4f..%.4f at step1 margin;"
        " width does not decide (see the step1 lp split below)"
        % (min(c1), max(c1), min(h1), max(h1))
    )
if c0 and h0:
    if min(h0) > max(c0):
        print(
            "  E VERDICT(2): STEP1 LP SEPARATES — every collapsed turn sits closer to 0 than every"
            " healthy one (gap %.4f nats): the process-level logits regime is the precursor"
            % (min(h0) - max(c0))
        )
    elif min(c0) > max(h0):
        print(
            "  E VERDICT(2): STEP1 LP SEPARATES INVERTED — collapsed turns are the MORE certain"
            " ones (gap %.4f nats): certainty, not a near-tie, precedes the collapse"
            % (min(c0) - max(h0))
        )
    else:
        print(
            "  E VERDICT(2): STEP1 LP OVERLAPS — collapsed %.4f..%.4f vs healthy %.4f..%.4f;"
            " no per-process regime found at step1" % (min(c0), max(c0), min(h0), max(h0))
        )
PY
    rm -f "$ROWS"
    ;;
esac
