#!/usr/bin/env bash
# 39-skill-contract-exec.sh — does the published skill survive being executed?
#
# ### Why
# `skills/ocoreai/SKILL.md` is the artefact another harness reads to drive `/v1`. Prose that describes a
# wire rots the first time the wire moves, and a rotting skill is worse than none: another agent's session
# acts on it. So the skill carries its own executor — every claim it makes about the surface is written as
# a machine-readable marker in the paragraph it belongs to, and this probe boots a server and runs them.
# That is this repo's own rule ("anything that proves behaviour against a live server ships as a script in
# scripts/probes/") aimed at the adoption surface: a doc that cannot be executed is a claim.
#
# ### Marker syntax (in the skill, one per line, an HTML comment so it does not render)
#   <!-- exec: METHOD PATH STATUS [| {json-body}] [| substring]... -->        contract tier, no weights
#   <!-- exec-model: METHOD PATH STATUS [| {json-body with @model}] [...] --> needs a ready checkpoint
# `@model` is replaced by the first `state:"ready"` id from `/v1/models`.
#
# ### Tiers, because only one of them can run anywhere
#   §0 clone     — no server: every path the skill cites is tracked by git, and nothing under skills/ is
#                  ignored. This is how §0 caught an unanchored `references/` rule shipping a skill whose three
#                  reference files only existed on the author's disk.
#   §1 contract  — scripted lane (nothing resident, no Metal): executes every `exec:` marker, and FLOORS
#                  its own hit count: a renamed skill or a rotted pattern must fail loudly, not pass by
#                  finding nothing (invariant 1 — the failure this probe exists to prevent is its own).
#   §1b auth     — a second boot with OCOREAI_API_KEYS: a generating route without a key is 401 naming the
#                  remedy, with a key it completes, and `/health` stays public. The public set is
#                  AuthRoutePolicy.publicPaths; the skill tells clients to read the `auth` column instead of
#                  hard-coding it, so the boundary itself has to be proven, not asserted in prose.
#   §2 checkpoint — real engine + a ready model. The tier's premise is established before any assertion
#                  (a minimal turn must complete); if the engine cannot generate on this host the tier
#                  prints WHY with the observed status, and never reports a pass it did not measure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="skill-contract-exec"

SKILL_DIR="$PROBE_REPO_ROOT/skills/ocoreai"
SKILL="$SKILL_DIR/SKILL.md"
if [ ! -f "$SKILL" ]; then
  probe_fail "skills/ocoreai/SKILL.md is absent — the published skill vanished, so there is nothing here" \
    " to execute and every sentence a harness read from it is now unverifiable"
  probe_summary "$PROBE_NAME"
fi

SCRIPT_FILE="$(mktemp -t ocoreai-skill-XXXXXX).json"
T1="$(mktemp -t ocoreai-markers-XXXXXX).tsv"
T2="$(mktemp -t ocoreai-markers-XXXXXX).tsv"
probe_atexit "rm -f '$SCRIPT_FILE' '$T1' '$T2'"
cat > "$SCRIPT_FILE" <<'JSON'
{
  "segments": ["contract lane answer."],
  "finishReason": "eos",
  "promptTokens": 6,
  "generatedTokens": 3
}
JSON
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"

python3 - "$SKILL_DIR" "$T1" "$T2" <<'PY'
import glob, os, re, sys
root, t1, t2 = sys.argv[1:4]
# Canonical marker:  METHOD PATH [JSON-BODY] STATUS [| substring]...
# The body is scanned by brace balance rather than by regex, because a request body carries nested
# objects and a non-greedy regex stops at the inner `}` — which silently drops the marker, the exact
# vacuous-pass failure this probe exists to police. A marker that cannot be parsed is a loud exit, not
# a skipped line.
HEAD = re.compile(r"<!--\s*exec(-model)?:\s*(.*?)-->\s*$")


def take_object(text):
    depth = 0
    for i, ch in enumerate(text):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[: i + 1], text[i + 1 :].strip()
    raise ValueError("unbalanced JSON body in marker")


def parse(content):
    m = re.match(r"([A-Z]+)\s+(\S+)\s*(.*)$", content, re.S)
    if not m:
        raise ValueError("no METHOD PATH")
    method, route, rest = m.group(1), m.group(2), m.group(3).strip()
    body = "-"
    if rest.startswith("{"):
        body, rest = take_object(rest)
    m2 = re.match(r"(\d{3})\s*(.*)$", rest, re.S)
    if not m2:
        raise ValueError("no 3-digit status after the path/body: %r" % rest[:60])
    status, tail = m2.group(1), m2.group(2).strip()
    if tail.startswith("{"):                      # body written after the status is also fine
        body, tail = take_object(tail)
    subs = [x.strip() for x in tail.split("|") if x.strip()]
    return method, route, status, body, subs


n1 = n2 = 0
f1 = open(t1, "w", encoding="utf-8")
f2 = open(t2, "w", encoding="utf-8")
files = [os.path.join(root, "SKILL.md")] + sorted(glob.glob(os.path.join(root, "references", "*.md")))
for path in files:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = HEAD.search(line)
            if not m:
                continue
            tier = m.group(1)
            try:
                method, route, status, body, subs = parse(m.group(2))
            except ValueError as exc:
                print("unparseable marker in %s: %s (%s)" % (path, line.strip(), exc), file=sys.stderr)
                sys.exit(2)
            if "\t" in body or any("\t" in s for s in subs):
                print("TAB in marker (would break the TSV): %s" % line.strip(), file=sys.stderr)
                sys.exit(2)
            out = f2 if tier else f1
            out.write("\t".join([method, route, status, body, "\x1f".join(subs)]) + "\n")
            if tier:
                n2 += 1
            else:
                n1 += 1
f1.close(); f2.close()
print("extracted contract=%d checkpoint=%d over %d file(s)" % (n1, n2, len(files)), file=sys.stderr)
PY

N1=$(wc -l < "$T1" | tr -d ' ')
N2=$(wc -l < "$T2" | tr -d ' ')
probe_require_int "contract marker count" "$N1"
probe_require_int "checkpoint marker count" "$N2"
if [ "${N1:-0}" -lt 12 ]; then
  probe_fail "only $N1 contract marker(s) in the skill (floor 12) — the scan is the premise, and a skill" \
    " whose markers were deleted or re-formatted proves nothing by executing nothing"
else
  probe_ok "skill carries $N1 contract marker(s) (floor 12) — the scan still matches its own content"
fi
if [ "${N2:-0}" -lt 4 ]; then
  probe_fail "only $N2 checkpoint marker(s) (floor 4) — the measured lane would be silently empty, which" \
    " is how a contract tier comes to look like a capability claim"
else
  probe_ok "skill carries $N2 checkpoint marker(s) (floor 4) for the measured lane"
fi

# ── §0 the clone a stranger actually gets ─────────────────────────────────────────────────────
probe_section "§0 every file the skill cites is in git, not merely on this disk"
# Why this clause exists: `.gitignore` carried an unanchored `references/` rule (for a mirrored tree
# that is not even in this repo any more), and it silently swallowed `skills/ocoreai/references/` —
# three files SKILL.md points a harness at, present on the author's disk, absent from every clone.
# Every on-disk doc check passed, because on disk the pointer resolves; only git knows the file was
# never shipped. So this clause asks git, and floors its own hit count for the same reason §1 does.
if ! command -v git >/dev/null 2>&1; then
  probe_note "§0 skipped — no git binary, so trackedness cannot be measured here"
else
  SWALLOWED="$(git -C "$PROBE_REPO_ROOT" ls-files --others --ignored --exclude-standard -- skills \
    | LC_ALL=C sort)"
  CITED=0
  UNTRACKED=""
  while IFS= read -r cited; do
    [ -n "$cited" ] || continue
    # Cites arrive repo-relative (`skills/ocoreai/references/wire.md`) or skill-relative
    # (`references/wire.md`); resolve both, then ask git whether the path it names is shipped.
    for candidate in "$cited" "$SKILL_DIR/$cited"; do
      [ -f "$candidate" ] || continue
      rel="${candidate#"$PROBE_REPO_ROOT"/}"
      CITED=$((CITED + 1))
      if ! git -C "$PROBE_REPO_ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        UNTRACKED="$UNTRACKED        cited but untracked: $rel\n"
      fi
      break
    done
  done < <(grep -ohE '`(skills|docs|scripts|Sources|Tests)/[A-Za-z0-9._/-]+`|`references/[A-Za-z0-9._-]+\.md`' \
      "$SKILL" "$PROBE_REPO_ROOT/skills/README.md" 2>/dev/null | tr -d '`' | LC_ALL=C sort -u)

  if [ "$CITED" -lt 3 ]; then
    probe_fail "only $CITED cite(s) scanned in the skill (floor 3) — the scan lost its own premise, so" \
      " a passing trackedness check below would be a pass over an empty set"
  elif [ -n "$SWALLOWED" ]; then
    probe_fail "git ignores file(s) inside the published skill: $(echo "$SWALLOWED" | tr '\n' ' ')" \
      " — a .gitignore pattern is swallowing part of the artefact another harness clones"
  elif [ -n "$UNTRACKED" ]; then
    printf "%b" "$UNTRACKED"
    probe_fail "the skill cites file(s) that exist here but are not tracked by git" \
      " — a fresh clone ships a skill with dangling pointers; `git add` the path or drop the cite"
  else
    probe_ok "$CITED cited file(s) all tracked by git, and nothing under skills/ is ignored" \
      " — the skill a stranger clones is the skill on this disk"
  fi
fi

# ── §1 contract lane ──────────────────────────────────────────────────────────────────────────
probe_section "§1 every exec: marker, against a scripted server (nothing resident)"
probe_boot
RUN1=0
while IFS=$'\t' read -r M P S B SUBS; do
  [ -n "${M:-}" ] || continue
  RUN1=$(( RUN1 + 1 ))
  if [ "$B" = "-" ]; then probe_api "$M" "$P" || true; else probe_api "$M" "$P" "$B" || true; fi
  bad=""
  if [ "${PROBE_STATUS:-000}" != "$S" ]; then bad="status ${PROBE_STATUS:-000}, expected $S"; fi
  if [ -n "${SUBS:-}" ]; then
    IFS=$'\x1f' read -r -a NEEDS <<< "$SUBS"
    for need in "${NEEDS[@]}"; do
      case "$PROBE_BODY" in
        *"$need"*) ;;
        *) bad="${bad:+$bad; }missing \"$need\"" ;;
      esac
    done
  fi
  if [ -z "$bad" ]; then
    probe_ok "$M $P → $S with every documented field present"
  else
    probe_fail "$M $P broke the skill: $bad" \
      " — the skill states it; either the wire moved (fix the code) or the sentence did (fix the marker in the same commit)"
  fi
done < "$T1"
if [ "$RUN1" -ne "$N1" ]; then
  probe_fail "executed $RUN1 of $N1 contract markers — the loop lost one, so the count above proves nothing"
fi

# ── §1b auth boundary ─────────────────────────────────────────────────────────────────────────
probe_section "§1b the key boundary the skill tells clients to expect"
kill -TERM "${PROBE_PID:-}" 2>/dev/null || true
for _ in $(seq 1 40); do kill -0 "${PROBE_PID:-}" 2>/dev/null || break; sleep 0.25; done
export OCOREAI_API_KEYS="sk-probe-39-local"
probe_boot
UNKEYED="$(curl -sS -m 30 -o /tmp/ocoreai-39-a.json -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  --data '{"model":"scripted-model","messages":[{"role":"user","content":"hi"}]}' \
  "$PROBE_BASE/v1/chat/completions" 2>/dev/null || echo 000)"
if [ "$UNKEYED" = "401" ] && grep -q 'API key required' /tmp/ocoreai-39-a.json 2>/dev/null; then
  probe_ok "generating route without a key → 401 naming the fix, not a silent 200"
else
  probe_fail "generating route without a key → $UNKEYED: $(head -c 160 /tmp/ocoreai-39-a.json 2>/dev/null)" \
    " — the skill promises 401 with the remedy; a caller is being told something else"
fi
KEYED="$(curl -sS -m 30 -o /tmp/ocoreai-39-b.json -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $OCOREAI_API_KEYS" -H 'Content-Type: application/json' \
  --data '{"model":"scripted-model","messages":[{"role":"user","content":"hi"}]}' \
  "$PROBE_BASE/v1/chat/completions" 2>/dev/null || echo 000)"
if [ "$KEYED" = "200" ] && grep -q 'chat.completion' /tmp/ocoreai-39-b.json 2>/dev/null; then
  probe_ok "the same route with the bearer key → 200 chat.completion"
else
  probe_fail "keyed request → $KEYED: $(head -c 160 /tmp/ocoreai-39-b.json 2>/dev/null)" \
    " — the skill tells callers a bearer value from OCOREAI_API_KEYS is accepted"
fi
PUB="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$PROBE_BASE/health" 2>/dev/null || echo 000)"
if [ "$PUB" = "200" ]; then
  probe_ok "/health stays public with keys set (the auth column a client must read, not guess)"
else
  probe_fail "/health with keys set → $PUB — AuthRoutePolicy.publicPaths says this one stays public"
fi
rm -f /tmp/ocoreai-39-a.json /tmp/ocoreai-39-b.json
unset OCOREAI_API_KEYS

# ── §2 checkpoint lane ────────────────────────────────────────────────────────────────────────
probe_section "§2 the exec-model: markers, against a real checkpoint"
kill -TERM "${PROBE_PID:-}" 2>/dev/null || true
for _ in $(seq 1 40); do kill -0 "${PROBE_PID:-}" 2>/dev/null || break; sleep 0.25; done
unset OCOREAI_SCRIPTED_ENGINE

# The real lane cannot use probe_boot: a host without a Metal device is a legitimate place to run this
# script (that is the sandbox tier), and a boot that never becomes ready there must print its reason
# instead of reporting a regression. Establish the premise, then assert — never the other way round.
S2_PORT="$(probe_free_port)"
S2_BASE="http://127.0.0.1:${S2_PORT}"
S2_LOG="$(mktemp -t ocoreai-skill-real-XXXXXX).log"
OCOREAI_ENABLE_HTTP=1 OCOREAI_HOST=127.0.0.1 OCOREAI_PORT="$S2_PORT" OCOREAI_APPROVAL_POLICY=auto \
  "$(probe_resolve_binary)" serve < /dev/null > "$S2_LOG" 2>&1 &
S2_PID=$!
probe_atexit "kill -TERM $S2_PID 2>/dev/null || true"
waited=0
while [ "$waited" -lt "${OCOREAI_READY_TIMEOUT:-180}" ]; do
  if ! kill -0 "$S2_PID" 2>/dev/null; then break; fi
  code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$S2_BASE/health" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && break
  sleep 1; waited=$(( waited + 1 ))
done
REAL_READY=1
if ! kill -0 "$S2_PID" 2>/dev/null || [ "${code:-000}" != "200" ]; then
  REAL_READY=0
  probe_note "§2 skipped — the real engine never became ready within ${waited}s on this host:"
  tail -3 "$S2_LOG" | sed 's/^/        /'
  echo "        Run this probe outside the agent sandbox (the same route as make test-clt) to run §2."
fi
if [ "$REAL_READY" = "1" ]; then
  probe_ok "/health 200 on the real lane after ${waited}s (no scripted engine, nothing replayed)"
  MODEL_ID="$(curl -sS -m 20 "$S2_BASE/v1/models" 2>/dev/null | python3 -c '
import json,sys
try: data = json.load(sys.stdin).get("data", [])
except Exception: data = []
for m in data:
    if str(m.get("state","ready")) == "ready":
        print(m.get("id","")); break
' 2>/dev/null || true)"
  if [ -z "$MODEL_ID" ]; then
    REAL_READY=0
    probe_note "§2 skipped — /v1/models reports no ready checkpoint; put weights in ~/.ocoreai/models" \
      " or POST /v1/models/download first (the marker set is the point of this tier)"
  fi
fi
if [ "$REAL_READY" = "1" ]; then
  BACKEND="$(curl -sS -m 20 "$S2_BASE/v1/capabilities" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("engineBackend",""))' 2>/dev/null || true)"
  probe_note "§2 backend=$BACKEND model=$MODEL_ID"
  PREMISE="$(curl -sS -m 180 -o /tmp/ocoreai-39-pre.json -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}],\"max_tokens\":8}" \
    "$S2_BASE/v1/chat/completions" 2>/dev/null || echo 000)"
  if [ "$PREMISE" != "200" ]; then
    REAL_READY=0
    probe_note "§2 skipped — a real turn did not complete (HTTP $PREMISE):"
    head -c 200 /tmp/ocoreai-39-pre.json | sed 's/^/        /'; echo
    echo "        The tier asserts only against an engine that generated, so it declines to claim anything."
  fi
fi
if [ "$REAL_READY" = "1" ]; then
  probe_ok "premise: one real generation completed on $MODEL_ID — assertions below are measurements"
  RUN2=0
  while IFS=$'\t' read -r M P S B SUBS; do
    [ -n "${M:-}" ] || continue
    RUN2=$(( RUN2 + 1 ))
    BODY="${B//@model/$MODEL_ID}"
    [ "$BODY" = "-" ] && BODY=""
    PROBE_BASE="$S2_BASE" probe_api "$M" "$P" "$BODY" || true
    bad=""
    if [ "${PROBE_STATUS:-000}" != "$S" ]; then bad="status ${PROBE_STATUS:-000}, expected $S"; fi
    if [ -n "${SUBS:-}" ]; then
      IFS=$'\x1f' read -r -a NEEDS <<< "$SUBS"
      for need in "${NEEDS[@]}"; do
        case "$PROBE_BODY" in
          *"$need"*) ;;
          *) bad="${bad:+$bad; }missing \"$need\"" ;;
        esac
      done
    fi
    if [ -z "$bad" ]; then
      probe_ok "§2 $M $P → $S as documented, on a real checkpoint"
    else
      probe_fail "§2 $M $P broke the skill on $MODEL_ID: $bad" \
        " — this is the measured lane: the sentence in skills/ocoreai/SKILL.md is now false"
    fi
  done < "$T2"
  if [ "$RUN2" -ne "$N2" ]; then
    probe_fail "executed $RUN2 of $N2 checkpoint markers — the loop lost one, so §2 proves nothing"
  fi
fi
rm -f /tmp/ocoreai-39-pre.json
kill -TERM "$S2_PID" 2>/dev/null || true

probe_note "executed $N1 contract marker(s) + $N2 checkpoint marker(s) out of the skill's own text"
probe_summary "$PROBE_NAME"
