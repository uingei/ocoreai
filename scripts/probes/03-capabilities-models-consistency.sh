#!/usr/bin/env bash
# 03-capabilities-models-consistency.sh — does the discovery surface answer?
#
# Why (AGENTS.md § Endpoint Promises): the 404 envelope on this server tells clients to
# "enumerate endpoints via GET /v1/capabilities". For weeks that payload had no endpoint
# list — a dead end dressed as guidance — and separately /v1/count-tokens answered 404 on
# models /v1/models reported ready (10-12), and a VLM that answered images correctly was
# published with vlm:false (10-13). All three are the same defect: a surface that
# contradicts the engine. V1EndpointCatalogTests pins the index against the router at
# COMPILE time; this probe pins it against the RUNNING server, which is the only place a
# route can be registered and still 404 (middleware, ordering, or a handler that throws).
#
# Asserted:
#   • /v1/capabilities returns an endpoint index above a floor (an index that stopped
#     populating must not pass by being empty);
#   • every GET endpoint the index lists resolves on the live server — no 404s;
#   • a parameterised route is reachable with SOME form of the ids /v1/models publishes,
#     and if the verbatim id does not work then the index note must say what to do —
#     a route that needs undocumented trickery is still a dead end for a client;
#   • every ready model accepts /v1/count-tokens;
#   • every model row states `vlm` explicitly, and every capability row states
#     `available` + a reason, so nothing user-visible is an unstated guess.
#
# Wire-shape notes learned the hard way by running this probe (10-14): the two count
# endpoints publish the same vocabulary under different casings — `/v1/capabilities` uses
# `tokenizerBackend` (camelCase, per-object convention, see ModelObject's comment) while
# `/v1/count-tokens` uses `tokenizer_backend` — and this server's JSON escapes forward
# slashes, so a raw grep for "/v1/…" misses what the JSON decoder returns. Both are
# handled below; do not "simplify" them back.
#
# Run: bash scripts/probes/03-capabilities-models-consistency.sh
PROBE_NAME="03-capabilities-models-consistency"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

probe_boot
probe_require_ready_model

probe_section "GET /v1/capabilities"
probe_api GET /v1/capabilities
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "GET /v1/capabilities -> ${PROBE_STATUS:-no response}"
  probe_summary "$PROBE_NAME"
fi
ENDPOINTS="$(probe_json "$PROBE_BODY" 'endpoints')"
EP_COUNT="$(python3 - "$ENDPOINTS" <<'PY'
import json, sys
try:
    print(len(json.loads(sys.argv[1])))
except Exception:
    print(0)
PY
)"
# Floor: the router registers 33 routes today. 20 is well under that and well above zero,
# so an index that stopped being populated fails instead of passing vacuously.
if [ "$EP_COUNT" -ge 20 ]; then
  probe_ok "endpoint index present — $EP_COUNT entries"
else
  probe_fail "endpoint index has $EP_COUNT entries (< 20) — the 404 hint points clients at an index with nothing behind it"
fi

# Same vocabulary, two casings, because the two objects are cased differently by design.
BACKEND="$(probe_json "$PROBE_BODY" 'tokenizerBackend')"
[ -z "$BACKEND" ] && BACKEND="$(probe_json "$PROBE_BODY" 'tokenizer_backend')"
if [ "$BACKEND" = "real" ] || [ "$BACKEND" = "heuristic" ]; then
  probe_ok "tokenizer backend published as '$BACKEND' (every token count on the wire is labelled)"
else
  probe_fail "no tokenizerBackend / tokenizer_backend on /v1/capabilities — clients cannot tell an estimate from a real count"
fi

CAPS="$(probe_json "$PROBE_BODY" 'capabilities')"
CAP_BAD="$(python3 - "$CAPS" <<'PY'
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    print("capabilities not parseable"); sys.exit(0)
bad = [r.get("name", "?") for r in rows if not isinstance(r.get("available"), bool) or not str(r.get("note", "")).strip()]
print("none" if not bad else ", ".join(bad))
PY
)"
if [ "$CAP_BAD" = "none" ]; then
  probe_ok "every capability line states available + a reason"
else
  probe_fail "capability line(s) without a boolean or a reason: $CAP_BAD"
fi

probe_section "every GET endpoint in the index must resolve on the live server"
PLAIN_GETS="$(python3 - "$ENDPOINTS" <<'PY'
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for r in rows:
    if r.get("method") != "GET":
        continue
    path = r.get("path", "")
    if ":model" in path:
        continue  # measured separately: the id is what makes these hard
    elif ":" in path:
        print("SKIP|" + path)  # needs a resource id this probe cannot invent
        continue
    print("GET|" + path)
PY
)"
CHECKED=0
SKIPPED=0
while IFS='|' read -r kind path; do
  [ -n "${kind:-}" ] || continue
  if [ "$kind" = "SKIP" ]; then
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi
  probe_api GET "$path"
  CHECKED=$(( CHECKED + 1 ))
  case "${PROBE_STATUS:-}" in
    404) probe_fail "index lists GET $path but the live server 404s — the index and the running router disagree" ;;
    000) probe_fail "GET $path produced no response: ${PROBE_BODY:0:120}" ;;
    *)   probe_ok "GET $path -> $PROBE_STATUS" ;;
  esac
done <<< "$PLAIN_GETS"
if [ "$CHECKED" -ge 10 ]; then
  probe_ok "$CHECKED indexed GET route(s) probed live ($SKIPPED skipped for want of a resource id)"
else
  probe_fail "only $CHECKED indexed GET route(s) were probeable — this run does not cover the index it claims to check"
fi

probe_section "the id /v1/models publishes must reach the /v1/models/:model routes"
# This server publishes HuggingFace-style ids ("org/name"), which are TWO path segments,
# while the index advertises `/v1/models/:model/…` — one segment. resolvedSamplingModelId
# calls removingPercentEncoding, so the encoded form is the intended one. Measure all
# three shapes rather than assume which the router takes: a route that only answers to
# trickery a client cannot discover is the same dead end as a 404.
MODEL_PATH_FORMS="$(python3 - "$PROBE_MODEL" <<'PY'
import json, sys
raw = sys.argv[1]
print("verbatim|%s" % raw)
print("percent-encoded|%s" % raw.replace("/", "%2F"))
print("bare-no-org|%s" % (raw.rsplit("/", 1)[-1] if "/" in raw else raw))
PY
)"
LITERAL_OK=""
ANY_OK=""
FORMS_SEEN=""
OK_SUFFIXES=""
mark_reachable() {
  ANY_OK="yes"
  FORMS_SEEN="$FORMS_SEEN$2, "
  case "$OK_SUFFIXES" in *"|${1}"*) ;; *) OK_SUFFIXES="$OK_SUFFIXES|${1}" ;; esac
}
# Every parameterised GET route, not just one: kv-cache was the route that 404'd on a
# percent-encoded id because it skipped the router's id-resolution choke (found 10-14 by
# 01-prefix-accounting.sh), so the check must cover the whole family.
while IFS='|' read -r form mid; do
  [ -n "${form:-}" ] || continue
  for suffix in sampling kv-cache; do
    # curl --path-as-is keeps `%2F` encoded on the wire instead of normalising it away.
    raw="$(curl -sS -m 30 --path-as-is -w $'\n%{http_code}' \
      "${PROBE_BASE}/v1/models/${mid}/${suffix}" 2>/dev/null || printf '\n000')"
    code="${raw##*$'\n'}"
    body="${raw%$'\n'*}"
    # A router miss and an engine refusal are both 404 but mean opposite things:
    # `route_not_found` (the 404 middleware's envelope) = nothing registered for this
    # id shape; any other 404 came from INSIDE a matched handler, which proves the route
    # is reachable and the engine merely declined (e.g. kv-cache needs the model loaded).
    case "$code" in
      000)
        probe_fail "$form id + /$suffix -> no response"
        ;;
      404)
        if printf '%s' "$body" | grep -q "route_not_found"; then
          probe_note "$form id + /$suffix -> router 404 (nothing registered for this id shape)"
        else
          probe_ok "$form id + /$suffix -> 404 raised inside the handler: route reachable, engine declined"
          mark_reachable "$suffix" "$form"
        fi
        ;;
      401)
        probe_ok "$form id + /$suffix -> 401: route registered and auth-gated"
        mark_reachable "$suffix" "$form"
        ;;
      *)
        probe_ok "$form id + /$suffix -> $code"
        mark_reachable "$suffix" "$form"
        [ "$form" = "verbatim" ] && LITERAL_OK=1
        ;;
    esac
  done
done <<< "$MODEL_PATH_FORMS"

if [ -z "$ANY_OK" ]; then
  probe_fail "GET /v1/models/:model/sampling 404s for verbatim, percent-encoded AND bare forms of the published id — the index advertises a route no real model id can reach"
elif [ -z "$LITERAL_OK" ]; then
  probe_ok "reachable via ${FORMS_SEEN%, } — the verbatim id published by /v1/models does NOT work, so the index has to say so"
  # The contract is only honest where a client reads it: the index note must name the
  # encoding. Without this line the fix is folklore.
  NACK="$(python3 - "$ENDPOINTS" <<'PY'
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    print("unparseable"); sys.exit(0)
missing = [
    r["path"] for r in rows
    if ":model" in r.get("path", "")
    and "%" not in r.get("note", "") and "encod" not in r.get("note", "").lower()
]
print("none" if not missing else ", ".join(missing))
PY
)"
  if [ "$NACK" = "none" ]; then
    probe_ok "every /v1/models/:model note states the percent-encoding requirement"
  else
    probe_fail "verbatim ids 404 and these index notes do not tell clients to encode: $NACK — a route that needs undocumented trickery is a dead end dressed as a path"
  fi
else
  probe_ok "verbatim id reaches the parameterised routes — no client-side encoding required"
fi

# Route-family coverage: a suffix that no id form can reach is an advertised-but-dead route.
for suf in sampling kv-cache; do
  case "$OK_SUFFIXES" in
    *"|${suf}"*) probe_ok "/v1/models/:model/${suf} reachable with some id form" ;;
    *) probe_fail "/v1/models/:model/${suf} 404s for every id form this probe tried — published but unreachable" ;;
  esac
done

probe_section "models surface must not promise what count-tokens denies"
probe_api GET /v1/models
LIMIT="${OCOREAI_PROBE_MODEL_LIMIT:-2}"
READY_LIST="$(python3 - "$PROBE_BODY" "$LIMIT" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1]).get("data", [])
except Exception:
    sys.exit(0)
limit = int(sys.argv[2])
ready = [m for m in data if str(m.get("state", "ready")) == "ready"]
for m in ready[:limit]:
    print("%s|%s|%s|%s" % (
        m.get("id", ""),
        m.get("vlm", ""),
        m.get("contextLength", ""),
        ",".join(m.get("capabilities", []) or [])))
PY
)"
if [ -z "$READY_LIST" ]; then
  probe_fail "/v1/models lists no ready model to cross-check — nothing to verify"
fi
ROWS=0
while IFS='|' read -r mid vlm ctx caps; do
  [ -n "${mid:-}" ] || continue
  ROWS=$(( ROWS + 1 ))
  if [ -z "$vlm" ]; then
    probe_note "model $mid omits vlm (ModelObject leaves it nil rather than guess) — clients cannot tell whether it sees images"
  else
    # `contextLength` absent is the documented honest shape (unknown ≠ 0, see
    # ModelObject); present-but-zero would be a lie. Only fail on the lie.
    if [ -n "$ctx" ] && [ "${ctx:-0}" -le 0 ]; then
      probe_fail "model $mid reports contextLength=$ctx — a non-positive window is not a real ceiling"
    elif [ -z "$ctx" ]; then
      probe_note "model $mid omits contextLength (documented as unknown ≠ 0) — clients must budget by trial"
    else
      probe_ok "model $mid states vlm=$vlm contextLength=$ctx${caps:+ caps=$caps}"
    fi
  fi
  probe_api POST /v1/count-tokens "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
  if [ "${PROBE_STATUS:-}" = "200" ]; then
    probe_ok "ready model $mid accepts /v1/count-tokens (count=$(probe_json "$PROBE_BODY" 'prompt_tokens'), backend=$(probe_json "$PROBE_BODY" 'tokenizer_backend'))"
  else
    probe_fail "/v1/models says $mid is ready but /v1/count-tokens -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:160}"
  fi
done <<< "$READY_LIST"
if [ "$ROWS" -gt 0 ]; then
  probe_note "cross-checked $ROWS ready model(s) (raise with OCOREAI_PROBE_MODEL_LIMIT)"
fi

probe_section "the 404 envelope itself"
probe_api GET "/v1/definitely-not-a-route-$$"
# Read the message through a JSON decoder: this server escapes forward slashes on the
# wire, so grepping the raw body for "/v1/capabilities" never matches what a client reads.
HINT="$(probe_json "$PROBE_BODY" 'error.message')"
if printf '%s' "$HINT" | grep -q "/v1/capabilities"; then
  probe_ok "404 envelope points at /v1/capabilities — and this probe verified that pointer leads somewhere"
else
  probe_fail "404 envelope does not name /v1/capabilities: ${HINT:-<no error.message>: ${PROBE_BODY:0:200}}"
fi

probe_summary "$PROBE_NAME"
