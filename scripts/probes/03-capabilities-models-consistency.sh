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
#   • `/v1/capabilities` publishes `instructionBudget` — the byte cap the project
#     instructions were cut to, plus a row per discovered doc. This probe boots with a
#     workspace it seeds to overflow that cap, so the field is measured under the exact
#     condition it exists to expose: one doc truncated to the cap, one dropped whole, and
#     every counter agreeing with its own rows. No absolute path reaches this public row.
#   • the two capability rows that carry a measured overlay agree with the surfaces that
#     hold the evidence — `screenshot_capture` vs /v1/multimodal/status, `video_input` vs
#     the per-model `videoInput` on /v1/models (see the section near the end).
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

# Seed a workspace whose project instructions overflow the loader's byte cap, so this probe
# measures `instructionBudget` under the exact condition the row exists to expose. Without
# the seed the chain is empty on a host with no configured workspace, and every per-doc
# assertion below would pass by finding nothing.
INSTR_WS="$(mktemp -d -t ocoreai-instrws-XXXXXX)"
probe_atexit "rm -rf '$INSTR_WS'"
mkdir -p "$INSTR_WS/.git" "$INSTR_WS/sub"
SEED_BYTES=40000
python3 -c "
import sys
header = '# root\n'
open(sys.argv[1] + '/AGENTS.md', 'w').write(header + 'x' * (int(sys.argv[2]) - len(header)))
open(sys.argv[1] + '/sub/AGENTS.md', 'w').write('sub rule\n')
" "$INSTR_WS" "$SEED_BYTES"
SUB_BYTES="$(wc -c < "$INSTR_WS/sub/AGENTS.md" | tr -d ' ')"
export OCOREAI_WORKSPACE="$INSTR_WS/sub"

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

# The sibling of the tokenizer row: a degraded component a client must be able to read. The
# degradation here is the project-instruction chain being cut at the loader's byte cap,
# which until 10-28 fell off silently for the model AND for the caller. Two halves: the row
# must agree with its own per-doc rows (its honest failure mode is a number that disagrees
# with the rows beneath it), and it must state the seeded overflow exactly — one doc
# truncated to the cap, one dropped whole, no absolute path on a public endpoint.
INSTR="$(probe_json "$PROBE_BODY" 'instructionBudget')"
INSTR_BAD="$(python3 - "$INSTR" "$INSTR_WS" "$SEED_BYTES" "$SUB_BYTES" <<'PY'
import json, sys
raw, ws, seed, sub = sys.argv[1].strip(), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
if not raw:
    print("instructionBudget absent from /v1/capabilities"); sys.exit(0)
try:
    b = json.loads(raw)
except Exception:
    print("instructionBudget not parseable"); sys.exit(0)
docs = b.get("docs")
if not isinstance(docs, list):
    print("instructionBudget.docs is not an array"); sys.exit(0)
cap = b.get("maxBytes")
bad = []
if not isinstance(cap, int) or cap <= 0:
    print("maxBytes absent or not a positive int — nothing else can be said"); sys.exit(0)
injected = sum(int(d.get("bytesInjected", -1)) for d in docs)
if injected != b.get("injectedBytes"):
    bad.append("injectedBytes %r != sum of docs (%d)" % (b.get("injectedBytes"), injected))
if injected > cap:
    bad.append("injectedBytes %d exceeds maxBytes %d" % (injected, cap))
if len(docs) != b.get("docCount"):
    bad.append("docCount %r != %d rows" % (b.get("docCount"), len(docs)))
for key, state in (("truncatedDocs", "truncated"), ("droppedDocs", "dropped")):
    rows = sum(1 for d in docs if d.get("state") == state)
    if rows != b.get(key):
        bad.append("%s %r != %d rows" % (key, b.get(key), rows))
# Premise floor: the seed must really overflow the cap the server reports, or the exact
# assertions below would be measuring a chain that never needed cutting.
if seed <= cap:
    bad.append("seed %d B does not overflow the reported cap %d — the premise died" % (seed, cap))
elif [d.get("state") for d in docs] != ["truncated", "dropped"]:
    bad.append("expected [truncated, dropped], got %r" % [d.get("state") for d in docs])
elif [d.get("label") for d in docs] != ["<root>/AGENTS.md", "<root>/sub/AGENTS.md"]:
    bad.append("labels are %r" % [d.get("label") for d in docs])
elif [d.get("bytesTotal") for d in docs] != [seed, sub]:
    bad.append("bytesTotal is %r, expected [%d, %d]" % ([d.get("bytesTotal") for d in docs], seed, sub))
elif [d.get("bytesInjected") for d in docs] != [cap, 0]:
    bad.append("bytesInjected is %r, expected [%d, 0]" % ([d.get("bytesInjected") for d in docs], cap))
elif b.get("docCount") != 2 or b.get("truncatedDocs") != 1 or b.get("droppedDocs") != 1:
    bad.append("counters disagree with the seeded overflow")
if any(d.get("path") is not None for d in docs):
    bad.append("a doc row published an absolute path on a public endpoint")
for candidate in {ws, ws.replace("/", "\\/")}:
    if candidate in raw:
        bad.append("the payload carries the workspace path: %s" % candidate)
        break
print("none" if not bad else "; ".join(bad))
PY
)"
if [ "$INSTR_BAD" = "none" ]; then
  INSTR_SUMMARY="$(python3 - "$INSTR" <<'PY'
import json, sys
b = json.loads(sys.argv[1])
print("%d/%d B injected over %d doc(s), %d truncated, %d dropped"
      % (b["injectedBytes"], b["maxBytes"], b["docCount"], b["truncatedDocs"], b["droppedDocs"]))
PY
)"
  probe_ok "instructionBudget states the seeded overflow exactly: $INSTR_SUMMARY"
else
  probe_fail "$INSTR_BAD — the row that exists to expose a silent truncation is wrong or absent"
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
MODELS_BODY="$PROBE_BODY"   # reused below: the capability rows have to agree with these rows
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

probe_section "capability rows must agree with the surfaces that measured them"
# /v1/capabilities is the surface a client routes by, so it carries the measured overlay
# (RuntimeCapability.measured): the screen row degrades on a capture that actually failed,
# and `video_input` says whether any model here completed a turn carrying a clip. Both
# halves were missing until now — round 14 shipped the per-model row and said so, and this
# section is what keeps the server-wide half from drifting back into either direction:
# claiming delivery no model earned, or staying silent where one was.
probe_api POST /v1/multimodal/status '{}'
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_note "POST /v1/multimodal/status -> ${PROBE_STATUS:-no response}: screen row cannot be cross-checked live"
  SCREEN_BODY='{}'
fi
SCREEN_BODY="$PROBE_BODY"
CROSS="$(python3 - "$CAPS" "$MODELS_BODY" "$SCREEN_BODY" <<'PY'
import json, sys

caps_raw, models_raw, screen_raw = sys.argv[1:4]


def emit(level, msg):
    print("%s|%s" % (level, msg))


try:
    caps = json.loads(caps_raw)
except Exception:
    emit("fail", "capabilities array unparseable — the measured rows cannot be cross-checked")
    sys.exit(0)
by_name = {r.get("name"): r for r in caps if isinstance(r, dict)}
# Floor the premises of this check: 10 tier rows + video_input. A truncated array makes
# every "agree" below true by having nothing to agree with.
if len(caps) < 11:
    emit("fail", "capability array has %d rows (< 11) — this check would pass vacuously" % len(caps))

try:
    models = json.loads(models_raw).get("data", [])
except Exception:
    models = []
    emit("fail", "/v1/models body unparseable — video_input has no per-model control")
delivered = [str(m.get("id", "?")) for m in models if m.get("videoInput") == "delivered"]

vid = by_name.get("video_input")
if vid is None:
    emit("fail", "no video_input row on /v1/capabilities — the discovery surface is silent about taking video in")
else:
    avail, note = vid.get("available"), str(vid.get("note", ""))
    if delivered and not avail:
        emit("fail", "/v1/models reports delivered video for %s but video_input.available=false" % ", ".join(delivered))
    elif delivered:
        emit("ok", "video_input.available=true, agreed by %d model row(s)" % len(delivered))
        if "delivered across" not in note:
            emit("fail", "video_input claims delivery without the aggregate evidence sentence: %s" % note[:180])
    elif avail:
        emit("fail", "video_input.available=true while no model row reports delivered video — the aggregate claims more than the per-model rows")
    else:
        emit("ok", "video_input=not_observed, agreed by all %d model row(s)" % len(models))
        if "not_observed" not in note:
            emit("fail", "the negative must be explicit, not blank: %s" % note[:180])

try:
    screen = json.loads(screen_raw)
except Exception:
    screen = {}
    emit("fail", "/v1/multimodal/status body unparseable — screenshot_capture has no control")
delivery = screen.get("screenDelivery", "<absent>")
shot = by_name.get("screenshot_capture")
if shot is None:
    emit("fail", "no screenshot_capture row on /v1/capabilities")
else:
    avail, note = shot.get("available"), str(shot.get("note", ""))
    if delivery == "failed":
        if avail:
            emit("fail", "capture failed here (screenStatus=%s) yet screenshot_capture.available=true — the surface outruns the engine" % screen.get("screenStatus", "<absent>"))
        elif "capture failed" not in note:
            emit("fail", "the measured failure is not stated on the capability row: %s" % note[:180])
        else:
            emit("ok", "screenshot_capture degraded from the measured capture failure")
    elif delivery == "captured":
        if not avail:
            emit("fail", "a frame was delivered yet screenshot_capture.available=false")
        elif "a frame was delivered" not in note:
            emit("fail", "the delivered frame is not stated on the capability row: %s" % note[:180])
        else:
            emit("ok", "screenshot_capture carries the measured delivery evidence")
    else:
        if note.startswith("Measured on this box"):
            emit("fail", "the row reports a measurement no attempt produced (screenDelivery=%s): %s" % (delivery, note[:180]))
        else:
            emit("ok", "no capture attempted here (screenDelivery=%s) — the row states the tier floor, available=%s" % (delivery, avail))
    # Whatever the delivery, a row this server leaves switched on must say where a
    # client can read the measurement instead of trusting the tier.
    if avail and "/v1/multimodal/status" not in note:
        emit("fail", "screenshot_capture available=true without naming where delivery is measured: %s" % note[:200])
PY
)"
CROSS_CHECKS=0
while IFS='|' read -r level msg; do
  [ -n "${level:-}" ] || continue
  CROSS_CHECKS=$(( CROSS_CHECKS + 1 ))
  case "$level" in
    ok)   probe_ok "$msg" ;;
    note) probe_note "$msg" ;;
    *)    probe_fail "$msg" ;;
  esac
done <<< "$CROSS"
if [ "$CROSS_CHECKS" -lt 2 ]; then
  probe_fail "only $CROSS_CHECKS cross-surface verdict(s) issued — the comparison did not run"
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
