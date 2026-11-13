#!/usr/bin/env bash
# 35-kv-cache-residency.sh — does the KV byte figure the surfaces publish ever become real?
#
# ### Why (AGENTS.md invariant 2: the surface never claims more than the engine delivered)
# `/metrics` publishes `ocoreai_kv_cache_gpu_bytes` and `ocoreai_gpu_memory_gb`, both HELP
# lines naming KV cache, and the dashboard shows the same figure as a GPU tile. All three were
# fed by `EnginePool.engineSummary()`, whose `gpuCacheGB` was the literal `0.0` — so every
# deployment ever run certified a zero-byte KV cache while holding hundreds of megabytes of it
# (measured: model ready, both series 0, and no test in Tests/ named any of the three series).
#
# The quantity is measurable and upstream owns the arithmetic: `ChatSession.cacheStatus()`
# returns `.realized` per-layer `memoryBytes`, computed by mlx-swift-lm from the cache arrays'
# own `nbytes` (KVCacheRuntime.swift:210). That prices sliding-window layers, KV sharing and
# the `.turboQuant`/`.affine` strategies by the code that implements them, which is why this
# probe reads the number out instead of checking it against a formula written here.
#
# ### What is asserted
#   1. Honest zero, before anything exists to measure: the gauge reads 0, and the endpoint
#      either 404s naming the model (listed but not resident) or answers `not_observed`. A 200
#      that states a residency nobody measured is the failure this file was written for.
#   2. The no-tools turn — which routes through the std-reasoning lane, which bypasses the
#      pooled ChatSession and frees its cache at turn end — prices its own traffic: the release
#      log names bytes it allocated and tokens it wrote, and `/kv-cache` still refuses to call
#      anything resident. A price (a property of the weights) is claimable; residency for bytes
#      that no longer exist is not.
#   3. The admission gate adopts THAT lane price with no pooled turn ever having happened:
#      turn 1 can only reserve at the fallback, turn 2 must reserve at the measured lane price.
#   4. A tools-bearing turn (the ChatSession lane, whose cache stays resident in the pool)
#      makes the endpoint say `measured`, with `bytesPerToken` in a band no KV cache can escape
#      (>= 256 B/token and < 1 MiB/token), so a stale or unit-confused number is caught.
#   5. Causation and arithmetic: the process-wide gauge leaves zero after that pooled turn, is
#      at least the model's resident bytes, and `residentBytes >= bytesPerToken * processedTokens`.
#   6. Every dispatched turn reserved and named its basis — the gate is on the live path.
#   8. `rewindReserve` reaches the live wire stating exactly the plan this server's own
#      environment resolved to (unset/positive/zero/negative/garbage mirrored from $env).
#
# ### Why §4-5 ride a tools-bearing turn
# The reasoning lane legitimately holds nothing between turns (its shipped design, open-items),
# so residency is asserted on the lane that really realizes a cache, and lane-only traffic is
# judged in §2-3 — a permanent red that states nothing true is not a gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="kv-cache-residency"

probe_boot
probe_require_ready_model

model_encoded="$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" \
  "$PROBE_MODEL")"
auth_args=()
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi

kv_cache() {  # kv_cache -> JSON body
  curl -sS -m 20 "${auth_args[@]+"${auth_args[@]}"}" \
    "$PROBE_BASE/v1/models/${model_encoded}/kv-cache"
}
gauge_bytes() {  # gauge_bytes -> int (empty on scrape failure)
  curl -sS -m 10 "$PROBE_BASE/metrics" 2>/dev/null \
    | awk '/^ocoreai_kv_cache_gpu_bytes /{print $2; exit}'
}

probe_section "1. honest zero before any cache exists"
# Before the first turn the model may not even be resident, and a 404 naming it is the honest
# answer. What is NOT allowed is a 200 that states a residency the engine has not measured.
gauge_before="$(gauge_bytes)"
if [ "${gauge_before:-}" = "0" ] || [ "${gauge_before:-}" = "0.0" ] || [ -z "$gauge_before" ]; then
  if [ -z "$gauge_before" ]; then
    probe_fail "/metrics does not expose ocoreai_kv_cache_gpu_bytes at all"
  else
    probe_ok "before any turn: ocoreai_kv_cache_gpu_bytes = $gauge_before"
  fi
else
  probe_fail "before any turn the gauge already read $gauge_before — a number nobody measured"
fi
before_json="$(kv_cache)"
before_code="$(curl -sS -m 20 "${auth_args[@]+"${auth_args[@]}"}" -o /dev/null -w '%{http_code}' \
  "$PROBE_BASE/v1/models/${model_encoded}/kv-cache")"
before_status="$(probe_json "$before_json" "residency.status")"
if [ "$before_code" = "404" ]; then
  probe_note "kv-cache 404 before the first turn: $PROBE_MODEL is listed but not resident yet"
elif [ "$before_status" = "not_observed" ]; then
  probe_ok "resident but nothing measured: residency = not_observed / 0 bytes"
else
  probe_fail "kv-cache answered HTTP $before_code with residency.status=${before_status:-missing}"
fi

probe_section "2. the bypassing lane prices its own turn and claims no residency"
# The no-tools turn rides the reasoning lane, which frees its cache at turn end. What it owes:
# a measured price for the traffic it really ran, and no residency claim for freed bytes.
long_prompt="$(probe_pad_text 60)"
body="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'session_id': 'KV-1',
    'max_tokens': 8,
    'temperature': 0.0,
    'messages': [{'role': 'user', 'content': sys.argv[2] + ' Reply with the single word OK.'}],
}))" "$PROBE_MODEL" "$long_prompt")"
probe_chat "KV-1" "$body"
if [ $? -ne 0 ]; then
  probe_fail "the long turn did not complete — residency cannot be judged (turns: 0)"
  probe_summary "$PROBE_NAME"
fi
prompt_tokens="$(probe_json "$PROBE_BODY" "usage.prompt_tokens")"
if ! [[ "${prompt_tokens:-}" =~ ^[0-9]+$ ]] || [ "$prompt_tokens" -lt 500 ]; then
  probe_fail "premise too small to price a cache: prompt_tokens=${prompt_tokens:-none} (floor 500)"
else
  probe_ok "turn prefilled prompt_tokens=$prompt_tokens in ${PROBE_ELAPSED_MS}ms"
fi
lane_line="$(grep -o "priced from the bypassing lane's own cache: [0-9]* bytes / [0-9]* tokens" \
  "$PROBE_LOG" 2>/dev/null | tail -1)"
lane_bytes="$(printf '%s' "$lane_line" | sed -n 's/.*cache: \([0-9]*\) bytes.*/\1/p')"
lane_tokens="$(printf '%s' "$lane_line" | sed -n 's/.*bytes \/ \([0-9]*\) tokens.*/\1/p')"
if [ -n "$lane_bytes" ] && [ -n "$lane_tokens" ] && [ "$lane_bytes" -gt 0 ] \
  && [ "$lane_tokens" -gt 0 ]; then
  lane_bpt=$(( lane_bytes / lane_tokens ))
  probe_ok "the lane priced its own turn: $lane_bytes bytes / $lane_tokens tokens"
  if [ "$lane_bpt" -ge 256 ] && [ "$lane_bpt" -lt 1048576 ]; then
    probe_ok "lane bytesPerToken=$lane_bpt sits in the plausible KV band (256 .. 1048575)"
  else
    probe_fail "lane bytesPerToken=$lane_bpt is outside any KV band — wrong quantity or unit"
  fi
else
  lane_bpt=""
  probe_fail "the bypassing lane left no price in the log — its traffic stays unaccounted"
  probe_fail "  (this is the open-items reasoning-lane row still being true)"
fi
lane_json="$(kv_cache)"
lane_status="$(probe_json "$lane_json" "residency.status")"
lane_code="$(curl -sS -m 20 "${auth_args[@]+"${auth_args[@]}"}" -o /dev/null -w '%{http_code}' \
  "$PROBE_BASE/v1/models/${model_encoded}/kv-cache")"
if [ "$lane_code" = "404" ] || [ "$lane_status" = "not_observed" ]; then
  probe_ok "after the lane turn the endpoint still claims no residency (HTTP $lane_code, ${lane_status:-404})"
else
  probe_fail "residency.status=$lane_status after a turn whose cache was freed — the surface"
  probe_fail "  calls bytes that no longer exist resident"
fi

probe_section "3. the reservation basis moves on the lane's own price alone"
# The price exists only after a cache has been read (lane or session -> KVCachePriceLedger),
# and so far NO pooled turn has run on this server: any `@ measured` reservation can only have
# come from the lane's own number. A log with no `Admitted` line is not "not applicable" — it
# means the gate is off the live path.
body2="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'session_id': 'KV-2',
    'max_tokens': 8,
    'temperature': 0.0,
    'messages': [{'role': 'user', 'content': sys.argv[2] + ' Reply with the single word OK.'}],
}))" "$PROBE_MODEL" "$long_prompt")"
probe_chat "KV-2" "$body2"

admitted_all="$(grep -o "Admitted [^ ]*: [0-9]*MB reserved @ [a-z]* [0-9]* B/token" \
  "$PROBE_LOG" 2>/dev/null || true)"
n_admitted="$(printf '%s' "$admitted_all" | grep -c Admitted || true)"
n_fallback="$(printf '%s' "$admitted_all" | grep -c "@ fallback " || true)"
if [ "${n_admitted:-0}" -lt 2 ]; then
  probe_fail "the gate logged ${n_admitted:-0} reservations across 2 dispatched turns — it is not"
  probe_fail "  on the live path, so no pricing claim about it can be true"
else
  probe_ok "the gate reserved on both turns, at default log level, with its basis"
fi
if [ "${n_fallback:-0}" -ge 1 ]; then
  probe_ok "a turn before any cache was priced reserved @ fallback 1024 B/token"
else
  probe_fail "no reservation named the fallback basis — the price arrived from nowhere, or the"
  probe_fail "  basis is not logged at all: $(printf '%s' "$admitted_all" | head -1)"
fi
if [ -n "$lane_bpt" ]; then
  n_lane_price="$(printf '%s' "$admitted_all" | grep -c "@ measured ${lane_bpt} B/token" || true)"
  if [ "${n_lane_price:-0}" -ge 1 ]; then
    probe_ok "the next turn reserved @ measured ${lane_bpt} B/token — the lane's own number, no pooled turn needed"
  else
    probe_fail "no reservation used the lane price ${lane_bpt} read this section: $(printf '%s' "$admitted_all" | tail -1)"
  fi
else
  probe_note "lane price absent (§2) — cannot judge the reservation's source price"
fi

probe_section "4. a tools-bearing turn realizes a resident cache the endpoint measures"
# The tools turn rides the pooled ChatSession, whose cache STAYS resident in the pool — that is
# the lane the gauge and `measured` residency are about.
body3="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'session_id': 'KV-3',
    'max_tokens': 8,
    'temperature': 0.0,
    'messages': [{'role': 'user', 'content': sys.argv[2] + ' Reply with the single word OK.'}],
    'tools': [{'type': 'function', 'function': {
        'name': 'get_weather',
        'description': 'Get the weather for a city.',
        'parameters': {'type': 'object', 'properties': {
            'city': {'type': 'string'}}, 'required': ['city']}}}],
}))" "$PROBE_MODEL" "$long_prompt")"
probe_chat "KV-3" "$body3"

probe_section "5. that pooled turn makes the gauge leave zero, and the endpoint measure it"
gauge=""
waited=0
while [ "$waited" -lt 30 ]; do
  gauge="$(gauge_bytes)"
  if [ -n "$gauge" ] && [ "$(python3 -c "print(1 if float('$gauge')>0 else 0)")" = "1" ]; then
    break
  fi
  sleep 2
  waited=$(( waited + 2 ))
done
if [ -n "$gauge" ] && [ "$(python3 -c "print(1 if float('$gauge')>0 else 0)")" = "1" ]; then
  probe_ok "ocoreai_kv_cache_gpu_bytes = $gauge after ${waited}s (was 0 by construction before)"
else
  probe_fail "ocoreai_kv_cache_gpu_bytes = ${gauge:-missing} after ${waited}s — a resident cache was"
  probe_fail "  allocated by the pooled turn and the surface still says nothing"
fi
after_json="$(kv_cache)"
a_status="$(probe_json "$after_json" "residency.status")"
a_bytes="$(probe_json "$after_json" "residency.residentBytes")"
a_sessions="$(probe_json "$after_json" "residency.residentSessions")"
a_tokens="$(probe_json "$after_json" "residency.processedTokens")"
a_bpt="$(probe_json "$after_json" "residency.bytesPerToken")"
probe_note "residency: status=$a_status bytes=$a_bytes sessions=$a_sessions tokens=$a_tokens bpt=$a_bpt"
if [ "$a_status" = "measured" ] && [[ "$a_bytes" =~ ^[0-9]+$ ]] && [ "$a_bytes" -gt 0 ]; then
  probe_ok "residency.status=measured with residentBytes=$a_bytes"
else
  probe_fail "residency after the pooled turn: status=$a_status bytes=$a_bytes (expected measured / > 0)"
fi
if [[ "$a_bpt" =~ ^[0-9]+$ ]] && [ "$a_bpt" -ge 256 ] && [ "$a_bpt" -lt 1048576 ]; then
  probe_ok "bytesPerToken=$a_bpt sits in the plausible KV band (256 .. 1048575)"
  probe_note "what the floor would have reserved for this cache: $a_bpt vs 1024 B/token"
else
  probe_fail "bytesPerToken=${a_bpt:-none} is outside any KV band — wrong quantity or stale number"
fi

probe_section "6. arithmetic: a breakdown cannot exceed its whole"
if [[ "$a_bytes" =~ ^[0-9]+$ ]] && [[ "$a_bpt" =~ ^[0-9]+$ ]] && [[ "$a_tokens" =~ ^[0-9]+$ ]] \
  && [ "$a_tokens" -gt 0 ]; then
  floor_total=$(( a_bpt * a_tokens ))
  if [ "$a_bytes" -ge "$floor_total" ]; then
    probe_ok "residentBytes=$a_bytes >= bytesPerToken*processedTokens=$floor_total"
  else
    probe_fail "residentBytes=$a_bytes < bytesPerToken*processedTokens=$floor_total"
  fi
else
  probe_fail "arithmetic leg had no numbers: bytes=$a_bytes bpt=$a_bpt tokens=$a_tokens"
fi
if [ -n "$gauge" ]; then
  cmp="$(python3 -c "
import sys
print(1 if float(sys.argv[1]) >= float(sys.argv[2]) else 0)" "$gauge" "${a_bytes:-0}")"
  if [ "$cmp" = "1" ]; then
    probe_ok "process gauge $gauge >= this model's residentBytes $a_bytes"
  else
    probe_fail "process gauge $gauge < this model's residentBytes $a_bytes — the two surfaces disagree"
  fi
else
  probe_fail "no process gauge to compare against residentBytes=$a_bytes"
fi

probe_section "7. every dispatched turn reserved, and a measured basis appears"
# Both price sources exist by now, so only the cheap invariants are judged here: every turn
# reserved, at least one reservation used a measured (not fallback) basis, and the fallback
# appeared first. The exact per-source prices are asserted where their source is unambiguous (§3).
admitted_all="$(grep -o "Admitted [^ ]*: [0-9]*MB reserved @ [a-z]* [0-9]* B/token" \
  "$PROBE_LOG" 2>/dev/null || true)"
n_admitted="$(printf '%s' "$admitted_all" | grep -c Admitted || true)"
n_measured_any="$(printf '%s' "$admitted_all" | grep -c "@ measured " || true)"
if [ "${n_admitted:-0}" -ge 3 ]; then
  probe_ok "all 3 dispatched turns reserved and named their basis"
else
  probe_fail "only ${n_admitted:-0} reservations across 3 dispatched turns — the gate skipped one"
fi
if [ "${n_measured_any:-0}" -ge 1 ]; then
  probe_ok "at least one reservation reserved @ measured — the gate learned a real price"
else
  probe_fail "every reservation used the fallback basis — the measured price never reached the gate"
fi
if [[ "${a_bpt:-}" =~ ^[0-9]+$ ]] && [ "$a_bpt" -gt 1024 ]; then
  probe_note "the bet avoided: the floor reserves $(( a_bpt / 1024 ))x less than the cache holds"
fi

probe_section "8. the wire states the rewind-reserve plan this server booted under"
# `KVCacheRewindReserveTests` proves the resolver and the encoder agree in-process; only a live
# server proves the field reaches the wire at all (invariant 2: what a stranger reads must be
# what was delivered). The expectation mirrors the same decision table from THIS probe's
# environment — the server was booted from it — so an operator running the suite with the knob
# set asserts the override reached the wire instead of watching it silently evaporate.
python3 - "$after_json" "${OCOREAI_KV_REWIND_RESERVE_TOKENS-__unset__}" <<'PY'
import json, sys
body, raw = sys.argv[1], sys.argv[2]
try:
    published = json.loads(body).get("rewindReserve")
except Exception:
    print("FAIL rewindReserve: response body did not parse"); sys.exit(1)
if published is None:
    print("FAIL rewindReserve: field absent — the plan is not on the wire"); sys.exit(1)
if raw == "__unset__":
    want = {"requested": True, "tokens": 1024, "basis": "default", "rawEnvironment": None}
elif __import__("re").fullmatch(r"[+-]?[0-9]+", raw):
    v = int(raw)
    if v == 0:
        want = {"requested": False, "tokens": 0, "basis": "off", "rawEnvironment": raw}
    elif v > 0:
        want = {"requested": True, "tokens": v, "basis": "environment", "rawEnvironment": raw}
    else:
        want = {"requested": True, "tokens": 1024, "basis": "invalid_environment", "rawEnvironment": raw}
else:
    want = {"requested": True, "tokens": 1024, "basis": "invalid_environment", "rawEnvironment": raw}
got = {k: published.get(k) for k in want}
if got != want:
    print(f"FAIL rewindReserve: wire {got} != booted plan {want}"); sys.exit(1)
print(f"OK rewindReserve on the live wire states the booted plan: {got}")
PY
if [ $? -ne 0 ]; then
  probe_fail "rewindReserve on the wire does not state the plan this server booted under"
fi

probe_summary "$PROBE_NAME"
