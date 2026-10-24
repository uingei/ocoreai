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
#   3. Causation: one ~3K-token turn makes the process-wide gauge leave zero within 30 s.
#   4. The endpoint says `measured`, and its `bytesPerToken` lands in a band no KV cache can
#      escape (>= 256 B/token and < 1 MiB/token), so a stale or unit-confused number is caught.
#   5. Internal arithmetic: `residentBytes >= bytesPerToken * processedTokens` (integer floor),
#      and the process-wide gauge is at least this model's resident bytes.
#   6. The per-token price is quoted, because that is the number the admission gate reserves at
#      (Scheduler/KVCacheBudget.swift prices an unpriced model at 1024 B/token; section 7 checks
#      that the gate found out what this checkpoint actually costs).
#   7. The reservation itself moves to that price: the first turn can only reserve at the
#      fallback, the turn after it must reserve at the measured price and name the basis.
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

probe_section "2. cause a real cache: one long prompt, few output tokens"
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

probe_section "3. the /metrics gauge must leave zero"
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
  probe_fail "ocoreai_kv_cache_gpu_bytes = ${gauge:-missing} after ${waited}s — a KV cache was"
  probe_fail "  allocated by this turn and the surface still says nothing (prompt_tokens=$prompt_tokens)"
fi

probe_section "4. the endpoint measures the same cache"
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
  probe_fail "residency after the turn: status=$a_status bytes=$a_bytes (expected measured / > 0)"
fi
if [[ "$a_bpt" =~ ^[0-9]+$ ]] && [ "$a_bpt" -ge 256 ] && [ "$a_bpt" -lt 1048576 ]; then
  probe_ok "bytesPerToken=$a_bpt sits in the plausible KV band (256 .. 1048575)"
  probe_note "what the floor would have reserved for this cache: $a_bpt vs 1024 B/token"
else
  probe_fail "bytesPerToken=${a_bpt:-none} is outside any KV band — wrong quantity or stale number"
fi

probe_section "5. arithmetic: a breakdown cannot exceed its whole"
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

probe_section "6. admission must reserve at the model's price, and name the basis"
# The price exists only after a cache has been read (SessionPool.release -> KVCachePriceLedger),
# so the honest ordering is testable on one server: turn 1 reserves at the fallback because
# nothing had been measured, turn 2 reserves at the price turn 1 produced. A log with no
# `Admitted` line is not "not applicable" — it means the gate is off the live path.
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
measured_price="${a_bpt:-none}"
n_measured="$(printf '%s' "$admitted_all" | grep -c "@ measured ${measured_price} B/token" || true)"
probe_note "reservations logged: ${n_admitted} (${n_fallback} fallback, ${n_measured} measured@${measured_price})"
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
if [ "${n_measured:-0}" -ge 1 ]; then
  probe_ok "the next turn reserved @ measured ${measured_price} B/token — this probe's own number"
else
  probe_fail "no reservation used the measured price ${measured_price} read off the same model's"
  probe_fail "  caches: $(printf '%s' "$admitted_all" | tail -1)"
fi
if [[ "$measured_price" =~ ^[0-9]+$ ]] && [ "$measured_price" -gt 1024 ]; then
  probe_note "the bet avoided: the floor reserves $(( measured_price / 1024 ))x less than the cache holds"
fi

probe_summary "$PROBE_NAME"
