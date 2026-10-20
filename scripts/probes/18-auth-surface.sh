#!/usr/bin/env bash
# 18-auth-surface.sh — the `auth` column is not decoration: enforce it on the wire.
#
# Why (AGENTS.md § Endpoint Promises + invariant 2): `/v1/capabilities` publishes an
# `auth` column per endpoint, derived from `AuthRoutePolicy.publicPaths` — the same set
# `AuthMiddleware` consults. `V1EndpointCatalogTests` pins that derivation statically, so
# it proves the column is *derived*, never that the middleware enforces it. And on 10-20
# this repo had four separate statements of which routes are public, one of them (the
# router's own header comment) wrong about two of the seven: so "documented as public" and
# "reachable without a key" had never been measured as the same fact.
#
# This probe turns the column into a wire measurement, with auth switched ON:
#   • auth must be ON, or the middleware short-circuits (`config.enabled == false`) and
#     every route answers — the refusals below would pass vacuously at 200. The probe
#     therefore sets a key itself and floors its own premise on it.
#   • every endpoint the index labels `public` answers WITHOUT a key (anything but
#     401/403 — a 400/404 still means the door is open);
#   • every endpoint labelled `key` or `admin` answers 401 WITHOUT a key;
#   • `/v1/perception` is checked by name: the router docstring called it "public" while
#     it has never been in publicPaths, so this is the line that would catch someone
#     "fixing" the docstring the other way round and quietly widening auth;
#   • PATCH/DELETE with a *user* key answers 403 (`adminKeyRequired`), never silently 2xx;
#   • the public set measured here equals the count and the members documented in
#     README.md — the wire, the index and the human-facing list must be one fact.
#
# Run: OCOREAI_BIN=... bash scripts/probes/18-auth-surface.sh
PROBE_NAME="18-auth-surface"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# Auth ON. If the caller already configured keys, use theirs; otherwise invent one.
export OCOREAI_API_KEYS="${OCOREAI_API_KEYS:-probe-surface-key-1}"
USER_KEY="${OCOREAI_API_KEYS%%,*}"

probe_boot

RAW_STATUS=""
RAW_BODY=""
# Same shape as probe_api, but the key is an argument: this probe's whole subject is
# the difference between arriving with one and arriving without.
raw_call() {
  local method="$1" path="$2" key="${3:-}" body="${4:-}"
  local -a args=(-sS -m "${OCOREAI_PROBE_CURL_TIMEOUT:-30}" -X "$method" -w $'\n%{http_code}')
  if [ -n "$key" ]; then args+=(-H "Authorization: Bearer $key"); fi
  if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data "$body"); fi
  local raw
  if ! raw="$(curl "${args[@]}" "$PROBE_BASE$path" 2>&1)"; then
    RAW_STATUS="000"; RAW_BODY="$raw"; return 1
  fi
  RAW_STATUS="${raw##*$'\n'}"
  RAW_BODY="${raw%$'\n'*}"
  return 0
}

probe_section "premise: auth is actually on"
raw_call GET /health ""
if [ "$RAW_STATUS" = "200" ]; then
  probe_ok "GET /health 200 without a key (public path, as documented)"
else
  probe_fail "GET /health -> $RAW_STATUS without a key; /health is in publicPaths, so the"
  probe_fail "  public surface itself is not answering — nothing below means anything"
  probe_summary "$PROBE_NAME"
fi
# The negative control: if a keyed route also answers without a key, auth is off and
# every refusal this probe reports would be fiction.
raw_call POST /v1/count-tokens "" '{}'
if [ "$RAW_STATUS" = "401" ]; then
  probe_ok "POST /v1/count-tokens without a key -> 401 (auth is enforced, not configured)"
else
  probe_fail "auth appears DISABLED: POST /v1/count-tokens without a key -> $RAW_STATUS, expected 401"
  probe_fail "  OCOREAI_API_KEYS did not reach the server; refusals below cannot be trusted"
  probe_summary "$PROBE_NAME"
fi

probe_section "index published by the running server"
raw_call GET /v1/capabilities ""
if [ "$RAW_STATUS" != "200" ]; then
  probe_fail "GET /v1/capabilities -> $RAW_STATUS (it is public — it must answer keyless)"
  probe_summary "$PROBE_NAME"
fi

# Model id is not needed (auth runs before any handler), but a plausible segment keeps
# the router happy: `:model` matches exactly one path segment.
TABLE="$(python3 - "$RAW_BODY" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
eps = d.get("endpoints") or []
rows = []
for e in eps:
    path = str(e.get("path", "")).replace(":model", "probe%2Fmodel")
    rows.append("%s\t%s\t%s" % (e.get("method", ""), path, e.get("auth", "")))
sys.stdout.write("\n".join(rows))
PY
)"
EP_TOTAL="$(printf '%s\n' "$TABLE" | grep -c '[^[:space:]]' || true)"
if [ "${EP_TOTAL:-0}" -ge 30 ]; then
  probe_ok "endpoint index carries $EP_TOTAL rows with an auth column"
else
  probe_fail "endpoint index only $EP_TOTAL rows (< 30) — the probe would certify an empty surface"
  probe_summary "$PROBE_NAME"
fi

probe_section "auth column == enforced behaviour, route by route"
PUBLIC_TOTAL=0; PUBLIC_OPEN=0; KEYED_TOTAL=0; KEYED_401=0; BAD=""; BAD_COUNT=0
PUBLIC_PATHS=""
# NOTE the loop variable is EP_PATH, never PATH: a first draft named it PATH, which
# overwrote the shell's search path mid-run, so every later curl was "not found" and the
# refusals all read 000 — while `000` also slipped through the "not 401/403" test and
# certified the public surface as open. A route that never answered is not a door.
while IFS=$'\t' read -r METHOD EP_PATH AUTH; do
  [ -n "$METHOD" ] || continue
  raw_call "$METHOD" "$EP_PATH" "" '{}'
  ST="$RAW_STATUS"
  if [ "$ST" = "000" ]; then
    BAD="${BAD}${METHOD} ${EP_PATH} did not answer at all (transport failure) — uncountable"$'\n'
    BAD_COUNT=$((BAD_COUNT + 1))
    continue
  fi
  if [ "$AUTH" = "public" ]; then
    PUBLIC_TOTAL=$((PUBLIC_TOTAL + 1))
    PUBLIC_PATHS="${PUBLIC_PATHS}${EP_PATH}"$'\n'
    if [ "$ST" = "401" ] || [ "$ST" = "403" ]; then
      BAD="${BAD}${METHOD} ${EP_PATH} labelled public but got ${ST}"$'\n'
      BAD_COUNT=$((BAD_COUNT + 1))
    else
      PUBLIC_OPEN=$((PUBLIC_OPEN + 1))
    fi
  else
    KEYED_TOTAL=$((KEYED_TOTAL + 1))
    if [ "$ST" = "401" ]; then
      KEYED_401=$((KEYED_401 + 1))
    else
      BAD="${BAD}${METHOD} ${EP_PATH} labelled ${AUTH:-?} but got ${ST}, expected 401"$'\n'
      BAD_COUNT=$((BAD_COUNT + 1))
    fi
  fi
done <<EOF
$TABLE
EOF

if [ "$PUBLIC_TOTAL" -lt 5 ]; then
  probe_fail "only $PUBLIC_TOTAL routes reported as public (< 5) — the index or the scan rotted"
elif [ "$PUBLIC_OPEN" -eq "$PUBLIC_TOTAL" ]; then
  probe_ok "all $PUBLIC_TOTAL index-labelled public endpoints answered keyless ($PUBLIC_OPEN/$PUBLIC_TOTAL)"
else
  probe_fail "public surface incomplete: $PUBLIC_OPEN/$PUBLIC_TOTAL open keyless"
fi
# An empty contradiction list is only meaningful if the two branches actually ran.
if [ "$((PUBLIC_TOTAL + KEYED_TOTAL))" -lt "$EP_TOTAL" ]; then
  probe_fail "only $((PUBLIC_TOTAL + KEYED_TOTAL)) of $EP_TOTAL indexed rows reached a verdict"
fi
if [ "$KEYED_TOTAL" -ge 20 ] && [ "$KEYED_401" -eq "$KEYED_TOTAL" ]; then
  probe_ok "all $KEYED_TOTAL key/admin endpoints refused keyless with 401 ($KEYED_401/$KEYED_TOTAL)"
else
  probe_fail "keyed surface leaked: $KEYED_401/$KEYED_TOTAL refused with 401"
fi
if [ -n "$BAD" ]; then
  printf '%s' "$BAD" | sed '/^$/d' | sed 's/^/        /'
  probe_fail "$BAD_COUNT endpoint(s) contradict their published auth column"
fi

probe_section "the perception gauge, by name"
raw_call GET /v1/perception ""
if [ "$RAW_STATUS" = "401" ]; then
  probe_ok "GET /v1/perception keyless -> 401 (keyed, exactly as README.md now states)"
else
  probe_fail "GET /v1/perception keyless -> $RAW_STATUS, expected 401: either publicPaths grew"
  probe_fail "  without a doc/CHANGELOG change, or the gauge's auth changed shape"
fi
raw_call GET /v1/perception "$USER_KEY"
if [ "$RAW_STATUS" = "200" ]; then
  probe_ok "GET /v1/perception with a key -> 200 (the door works for authorised clients)"
else
  probe_fail "GET /v1/perception with the configured key -> $RAW_STATUS, expected 200"
fi

probe_section "admin methods need an admin key"
if [ -n "${OCOREAI_ADMIN_KEYS:-}" ]; then
  probe_note "OCOREAI_ADMIN_KEYS is set by the caller — skipping the 403 expectation"
else
  raw_call DELETE /sessions/probe-nonexistent-session "$USER_KEY"
  if [ "$RAW_STATUS" = "403" ]; then
    probe_ok "DELETE /sessions/:id with a USER key -> 403 (adminKeyRequired, not silently served)"
  else
    probe_fail "DELETE /sessions/:id with a user key -> $RAW_STATUS, expected 403 adminKeyRequired"
  fi
fi
raw_call DELETE /sessions/probe-nonexistent-session ""
if [ "$RAW_STATUS" = "401" ]; then
  probe_ok "DELETE /sessions/:id keyless -> 401 (key check precedes the admin check)"
else
  probe_fail "DELETE /sessions/:id keyless -> $RAW_STATUS, expected 401 before any admin check"
fi

probe_section "wire == index == README"
WIRE_PUBLIC="$(printf '%s' "$PUBLIC_PATHS" | sed '/^$/d' | sort | tr '\n' ' ')"
probe_note "measured public paths ($PUBLIC_TOTAL): $WIRE_PUBLIC"
# Walk up to the repo root by a marker unique to it. A first draft stopped at the first
# README.md it found — which is scripts/probes/README.md, a different document that says
# nothing about public routes, and the cross-check then reported "no target" from the wrong
# file. Package.swift exists only at the root.
README_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$README_ROOT" != "/" ] && [ ! -f "$README_ROOT/Package.swift" ]; do
  README_ROOT="$(dirname "$README_ROOT")"
done
if [ ! -f "$README_ROOT/README.md" ] || [ ! -f "$README_ROOT/Package.swift" ]; then
  probe_fail "cannot locate repo root from ${BASH_SOURCE[0]} — the README cross-check is skipped, not passed"
else
  # Backticks inside $( ) + a heredoc are a bash 3.2 parsing trap, so the Python output
  # goes to a file and the file is read back, instead of nesting the two.
  DOC_TMP="$(mktemp -t ocoreai-docpublic-XXXXXX)"
  python3 - "$README_ROOT/README.md" > "$DOC_TMP" <<'PY'
import io, re, sys
BACKTICK = chr(96)
PATTERN = BACKTICK + "(/[^" + BACKTICK + "]+)" + BACKTICK
for ln in io.open(sys.argv[1], encoding="utf-8"):
    if "/health" in ln and "/metrics" in ln:
        print(" ".join(sorted(re.findall(PATTERN, ln))))
        break
PY
  DOC_PUBLIC="$(cat "$DOC_TMP")"
  rm -f "$DOC_TMP"
  INDEX_PUBLIC="$(printf '%s' "$WIRE_PUBLIC" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ -z "$DOC_PUBLIC" ]; then
    probe_fail "README.md no longer states which routes are public — the cross-check has no target"
  elif [ "$(printf '%s' "$DOC_PUBLIC" | tr -s ' ' | sed 's/^ //; s/ $//')" = "$INDEX_PUBLIC" ]; then
    probe_ok "README's documented public list == the surface measured keyless ($PUBLIC_TOTAL paths)"
  else
    probe_fail "README documents [$DOC_PUBLIC] but the wire served [$INDEX_PUBLIC]"
  fi
fi

probe_summary "$PROBE_NAME"
