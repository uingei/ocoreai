#!/usr/bin/env bash
# 20-download-path-traversal.sh — does a model id get to choose where the cache lives?
#
# ### Why (AGENTS.md invariant 1; the "no wire value may own the process" family)
# Two inputs were joined straight onto the cache root in Models/ModelScopeDownloader.swift:
#
#   cacheRoot.appendingPathComponent(id)          ← the wire's `model`
#   cacheDir.appendingPathComponent(filePath)    ← the hub's own manifest `Path` (a WRITE)
#   removeItem(cacheDir.appendingPathComponent(path)) × 2   ← and two DELETES
#
# `URL.appendingPathComponent` percent-encodes; it does **not** contain. So `..` walked out of
# `~/.ocoreai/models`, and on the delete lines the same string was an arbitrary-file-delete
# primitive. The manifest input is the one that decides the threat model: those bytes come from
# whatever answered the hub API, and `MODELSCOPE_ENDPOINT` makes "whatever answered" an operator
# choice (mirror / proxy). Grounding: ollama `types/model/name.go:262 IsValid()` rejects these
# shapes by enumerating hazards per component; codex #55384 refuses to follow a *replaceable
# symlink* out of a sandboxed exec lookup — hence the symlink leg below, where the lexical join
# is inside the root and only the resolved one is not.
#
# ### What this probe locks down
#   1. REFUSED BEFORE THE STREAM — a traversing `model`/`revision` answers 400 with
#      `error.param` naming the field and the value echoed, and the Content-Type is JSON, **not**
#      `text/event-stream`. A 200-SSE-followed-by-an-error-event is the worse contract: the
#      client's SDK has already committed to a download by then.
#   2. NOTHING LANDED — the cache root is pinned at a known depth, the path the id *would* have
#      reached is computed, and asserted absent.
#   3. LEGIT IDS STILL STREAM — a legal `org/name` is not refused: shape is refused, existence
#      is not. (A nonexistent-but-legal repo still opens SSE and reports its own hub error,
#      which is exactly the discriminator.)
#   4. SURVIVAL — `/health` still answers afterwards.
#
# No Metal turn is needed: every leg here is refused or accepted before generation.
#
# Run: bash scripts/probes/20-download-path-traversal.sh
PROBE_NAME="20-download-path-traversal"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ── cache root at a known depth, so "where it would have landed" is computable ──
TAG="p20-$$-${RANDOM}"
PARENT="/tmp/ocoreai-${TAG}"
export OCOREAI_MODELS_DIR="$PARENT/home/models"
mkdir -p "$OCOREAI_MODELS_DIR"
probe_atexit "rm -rf '$PARENT'"

# From $PARENT/home/models, `../../..` is /tmp — so this id names a directory beside the run.
ESCAPE_TARGET="/tmp/ocoreai-${TAG}-escaped"
TRAVERSING_ID='../../../ocoreai-'"$TAG"'-escaped'

probe_boot

# ── helpers ────────────────────────────────────────────────────────────────────

DL_STATUS=""
DL_BODY=""
DL_CTYPE=""

# Same shape as probe_api, but headers are captured: "refused before the stream" is a claim
# about Content-Type, not about the status line alone.
dl_call() {
  local body="$1" hdr raw
  hdr="$(mktemp)"
  if ! raw="$(curl -sS -m "${OCOREAI_PROBE_CURL_TIMEOUT:-60}" -X POST -D "$hdr" \
    -H 'Content-Type: application/json' --data "$body" -w $'\n%{http_code}' \
    "$PROBE_BASE/v1/models/download" 2>&1)"; then
    DL_STATUS="000"; DL_BODY="$raw"; DL_CTYPE=""; rm -f "$hdr"; return 1
  fi
  DL_STATUS="${raw##*$'\n'}"
  DL_BODY="${raw%$'\n'*}"
  DL_CTYPE="$(tr -d '\r' < "$hdr" | awk -F': ' 'tolower($1)=="content-type"{print $2}')"
  rm -f "$hdr"
  return 0
}

# One traversing request: 400 + JSON + param naming the field + the value echoed.
#   $1 label   $2 field   $3 body   $4 expected reason substring
refusal_leg() {
  local label="$1" field="$2" body="$3" reason="$4"
  dl_call "$body"
  local param msg has_value
  param="$(probe_json "$DL_BODY" "error.param")"
  msg="$(probe_json "$DL_BODY" "error.message")"
  has_value="$(probe_json "$DL_BODY" "error.value")"
  if [ "$DL_STATUS" != "400" ]; then
    probe_fail "$label -> $DL_STATUS, expected 400 (body: $(printf '%.160s' "$DL_BODY"))"
    return
  fi
  case "$DL_CTYPE" in
    *text/event-stream*)
      probe_fail "$label answered 400 but as text/event-stream — the stream opened anyway"
      return ;;
  esac
  if [ "$param" != "$field" ]; then
    probe_fail "$label: error.param=\"$param\", expected \"$field\" (body: $(printf '%.160s' "$DL_BODY"))"
    return
  fi
  if [ -z "$has_value" ]; then
    probe_fail "$label: the refusal does not echo the offending value (error.value empty)"
    return
  fi
  if [ -n "$reason" ] && [ "$(printf '%s' "$msg" | grep -c "$reason")" = "0" ]; then
    probe_fail "$label: message does not name the hazard \"$reason\": $msg"
    return
  fi
  probe_ok "$label -> 400 param=$field reason~$reason value echoed, Content-Type: $DL_CTYPE"
}

probe_section "refusal: ids that walk out of the cache root"
refusal_leg "model=\"$TRAVERSING_ID\"" "model" \
  '{"model":"'"$TRAVERSING_ID"'","provider":"mscope"}' "dotComponent"
refusal_leg 'model=".."' "model" '{"model":"..","provider":"hf"}' "dotComponent"
refusal_leg 'model="/etc/passwd"' "model" '{"model":"/etc/passwd","provider":"hf"}' "absolutePath"
refusal_leg 'model="a/../../b"' "model" '{"model":"a/../../b","provider":"mscope"}' "dotComponent"
refusal_leg 'model="~/ssh"' "model" '{"model":"~/id_rsa","provider":"hf"}' "tildeHome"
refusal_leg 'revision="../evil"' "revision" \
  '{"model":"mlx-community/gemma-4-e2b-it-4bit","provider":"hf","revision":"../evil"}' \
  "dotComponent"

probe_section "premise: the refusal happened before anything was written"
if [ -e "$ESCAPE_TARGET" ]; then
  probe_fail "$ESCAPE_TARGET exists — the traversing id reached the filesystem anyway"
else
  probe_ok "nothing landed at $ESCAPE_TARGET (the path the id would have joined)"
fi
# And the cache root itself stayed a directory with nothing unexpected in it.
if [ -d "$OCOREAI_MODELS_DIR" ]; then
  probe_ok "cache root intact at $OCOREAI_MODELS_DIR"
else
  probe_fail "cache root vanished: $OCOREAI_MODELS_DIR is not a directory"
fi

probe_section "positive control: legal ids are still accepted"
LEGIT_ID='mlx-community/definitely-not-a-real-repo-'"$TAG"
dl_call '{"model":"'"$LEGIT_ID"'","provider":"mscope"}'
case "$DL_CTYPE" in
  *text/event-stream*)
    probe_ok "legal org/name is not refused by shape — SSE opened (status $DL_STATUS)"
    ;;
  *)
    probe_fail "legal id $LEGIT_ID did not open SSE (status $DL_STATUS, Content-Type: $DL_CTYPE)"
    ;;
esac
case "$DL_BODY" in
  *"data:"*) probe_ok "the stream speaks DownloadSSEEvent (first bytes: $(printf '%.90s' "$DL_BODY"))" ;;
  *) probe_fail "SSE opened but emitted no data: line — the stream is silent" ;;
esac

# The two refusals that predate this fix must keep their own wording — a validator rewrite that
# turns "must not be empty" into a path verdict is a regression too.
probe_section "pre-existing validation is untouched"
# Both legs assert WHY the 400 happened. On the run that surfaced the `useLatest` defect, these
# two legs passed while the whole endpoint was broken — every request 400'd, just not for the
# reason being tested. A refusal leg that does not name its own field is not evidence.
# (Case-insensitive: these two refusals are prose — "Model identifier must not be empty" — and
# the second run proved the harness, not the server, was wrong here.)
dl_call '{"model":"","provider":"hf"}'
if [ "$DL_STATUS" = "400" ] && [ "$(printf '%s' "$DL_BODY" | grep -ci "model")" -gt 0 ]; then
  probe_ok "empty model still 400 naming model (body: $(printf '%.90s' "$DL_BODY"))"
else
  probe_fail "empty-model leg did not produce a 400 naming model: $DL_STATUS $DL_BODY"
fi
dl_call '{"model":"mlx-community/tiny","provider":"modelscope"}'
if [ "$DL_STATUS" = "400" ] && [ "$(printf '%s' "$DL_BODY" | grep -ci "provider")" -gt 0 ]; then
  probe_ok "provider outside {hf,mscope} still 400 naming provider: $(printf '%.90s' "$DL_BODY")"
else
  probe_fail "provider leg did not produce a 400 naming provider: $DL_STATUS $DL_BODY"
fi

probe_section "survival"
probe_api GET /health
if [ "$PROBE_STATUS" = "200" ]; then
  probe_ok "server still answers /health after six refusals"
else
  probe_fail "/health -> $PROBE_STATUS after the refusal legs; the box did not survive its own validator"
fi

probe_summary "$PROBE_NAME"
