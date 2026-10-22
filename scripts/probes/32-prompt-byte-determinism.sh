#!/usr/bin/env bash
# 32-prompt-byte-determinism.sh — does the same request compile to the same prompt bytes?
#
# ### Why (P0: a task must not fail by coin flip)
# Every discriminant arm written before 10-23 claimed "identical prompt bytes" and none of them
# checked bytes — probe fidelity compared a token COUNT. When `promptHash` (FNV-1a over the
# tokens actually fed) was added, the premise died immediately: eight cold boots of one request
# produced four byte-variants of the same 713-token prompt, because the skill blocks were written
# into the system prompt in Swift's per-process dictionary order (SkillRegistry.resolveOrder).
# Two of the four variants answered EOS after one token. Prompt bytes must be a function of the
# request, not of the process's hash seed — same class, same severity, anywhere bytes are built
# from a Dictionary/Set or serialized without sorted keys.
#
# ### What is asserted
#   1. Stability ACROSS boots: for each request shape, every boot must produce ONE promptHash.
#      More than one is a P0 regression, and it is the class of bug no unit test can see,
#      because Swift fixes the hash seed for the lifetime of a process.
#   2. Sensitivity WITHIN a boot: the shapes must hash DIFFERENTLY. A run where every shape
#      collides proves the request is not reaching the prompt at all, and such a run would pass
#      leg 1 vacuously — so the instrument checks that it can tell things apart before it
#      claims they are stable.
#   3. Premises floored: at least two boots, and at least one hash per shape per boot.
#
# Shapes, named by what each one varies: `bare` (no tools) / `required` (a tool whose JSON schema
# declares `required`) / `unrequired` (the same kind of tool with `required` omitted) / `history`
# (two prior turns, no tools).
#
# ### Mechanism, read off the dumped bytes (10-23, gemma-4-e2b-it-4bit)
# Declaring one tool changed the delivered prompt by **+595 bytes / +131 tokens** and in two places
# at once: the identity paragraph flips its posture wholesale ("This conversation gives you no
# tools: answer directly…" → "Assume the user wants code changes or tool actions…"), and the
# checkpoint's own template emits the declaration — `<|tool>declaration:lookup_order{…}<tool|>`.
# That template **sorts the property names** (requested `order_id, status, limit`; rendered
# `limit, order_id, status`) and **drops `required` when the caller omits it**, so on this
# checkpoint property order cannot leak a hash seed, and an unrequired schema tells the model that
# nothing is mandatory. Both are the checkpoint's behaviour, not ours: a checkpoint whose
# `toolCallFormat` is plain JSON serializes the dictionary instead, and that path stays unmeasured
# here. The three `Array(schema.parameters.keys)` exits (`ToolRegistry.swift:817`,
# `ToolEntry.swift:235`, `MCP/MCPTools.swift:46`) are registry-side and unreachable from a
# caller-declared schema; all 8 built-ins declare `required` themselves, so nothing on this host
# reaches them — closing that gap needs an MCP tool whose `inputSchema` omits `required`.
#
# ### What `promptHash` could not see when this probe was written, and what it can see now
# The hash comes from `DegenerateMarginProbe`, which re-prepares the prompt instead of riding the
# live turn. At the time this probe was committed it built `UserInput` with **no `tools:`**, so on
# the two tool shapes the schema never entered the reconstruction: `promptHash` covered instructions
# and message text only, and a run could report "stable bytes" while every schema byte sat outside
# the measurement. Its NOTE explained a tool-shape collision by pointing at the tool surface — a
# mechanism the instrument had no way to observe. Retracted here. The probe now carries the turn's
# resolved `[ToolSpec]` and prints `toolsCarried=N`, and leg 4 below fails when a shape that
# declares a tool reports `toolsCarried=0`: a declaration that cannot reach the hash makes every
# other assertion in this file vacuous, so the instrument checks that it can see schemas before it
# says anything about their stability.
#
# Fails when: any shape yields more than one promptHash across boots, or shapes collide within a
# boot, or a shape's toolsCarried disagrees with what it declares, or too few boots/turns
# completed to say anything.
source "$(dirname "$0")/_lib.sh"

PROBE_NAME="32-prompt-byte-determinism"
BOOTS="${BOOTS:-3}"
# Honor an externally supplied dump dir: a hash says *that* boots differ, only the bytes say
# *where*, and this script used to delete its own dump unconditionally — so the one artefact that
# could name the varying lines was thrown away by design. Kept when the caller asks for a path.
DUMP="${OCOREAI_MARGIN_DUMP:-${TMPDIR:-/tmp}/ocoreai-bytes-$$}"
KEEP_DUMP="${OCOREAI_MARGIN_DUMP:-}"

shape_body() {
  local shape="$1"
  python3 - "$PROBE_MODEL" "$shape" <<'PY'
import json, sys
model, shape = sys.argv[1], sys.argv[2]
msgs = [{"role": "system", "content": "You are a terse assistant. Answer exactly as asked."}]
if shape == "history":
    msgs += [
        {"role": "user", "content": "Remember the token BLUE."},
        {"role": "assistant", "content": "BLUE"},
    ]
# Shapes carry distinct tool names and descriptions, so a reconstruction that actually receives the
# schemas cannot collide them by accident of length — see the header.
msgs.append({"role": "user", "content": "Reply with the single word READY."})
body = {
    "model": model,
    "session_id": "bytes-%s" % shape,
    "max_tokens": 8,
    "temperature": 0.0,
    "stream": False,
    "messages": msgs,
}
if shape == "unrequired":
    # `required` is NOT declared. Measured 10-23 on gemma-4-e2b: this checkpoint's template
    # renders the declaration itself and omits the `required:` key entirely, so the model reads
    # every argument as optional. This shape does NOT reach `Array(schema.parameters.keys)`
    # (ToolRegistry.swift:817, ToolEntry.swift:235, MCP/MCPTools.swift:46) — those sit on the
    # registry side, a caller-declared schema never routes through them, and all 8 built-ins
    # declare `required` themselves. Kept because "caller omits required" is a wire-legal shape
    # a real client sends; the claim it tests is delivery, not the dictionary exit.
    body["tools"] = [{
        "type": "function",
        "function": {
            "name": "fetch_rows",
            "description": "Fetch rows from a table with filters.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table to read"},
                    "where_clause": {"type": "string", "description": "SQL filter"},
                    "row_limit": {"type": "integer", "description": "Max rows returned"},
                    "include_meta": {"type": "boolean", "description": "Include column metadata"},
                },
            },
        },
    }]
elif shape == "required":
    body["tools"] = [{
        "type": "function",
        "function": {
            "name": "lookup_order",
            "description": "Look an order up by id and status.",
            "parameters": {
                "type": "object",
                "properties": {
                    "order_id": {"type": "string", "description": "Order identifier"},
                    "status": {"type": "string", "description": "Status filter"},
                    "limit": {"type": "integer", "description": "Max rows"},
                },
                "required": ["order_id"],
            },
        },
    }]
print(json.dumps(body))
PY
}

SHAPES="bare required unrequired history"

export OCOREAI_MARGIN_PROBE=all
export OCOREAI_MARGIN_DUMP="$DUMP"

for b in $(seq 1 "$BOOTS"); do
  probe_boot
  probe_require_ready_model
  for shape in $SHAPES; do
    probe_chat "bytes-$shape" "$(shape_body "$shape")"
    if [ "${PROBE_STATUS:-}" != "200" ]; then
      probe_fail "boot $b shape $shape -> HTTP ${PROBE_STATUS:-none} (nothing was measured)"
    fi
  done
  grep -oE "promptHash=[0-9a-f]+ toolsCarried=[0-9]+" "$PROBE_LOG" 2>/dev/null \
    | sed -E "s/promptHash=([0-9a-f]+) toolsCarried=([0-9]+)/$b\t\1\t\2/" >> "$DUMP.all" || true
  probes_cleanup >/dev/null 2>&1
  sleep 2
done
unset OCOREAI_MARGIN_PROBE OCOREAI_MARGIN_DUMP

N=$(grep -c . "$DUMP.all" 2>/dev/null || echo 0)
if [ "$N" -lt "$(( BOOTS * 4 ))" ]; then
  probe_fail "only $N prompt hashes recorded for $BOOTS boots x 4 shapes — the probe did not run on every turn"
fi

python3 - "$DUMP.all" "$BOOTS" <<'PY'
import collections, sys

# Rows arrive in send order within a boot and carry what the probe actually fed: the hash over the
# tokens, plus how many ToolSpec dictionaries went into UserInput.tools.
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
boots = int(sys.argv[2])
shapes = ["bare", "required", "unrequired", "history"]
# What each shape declares, so `toolsCarried` is checked against a stated expectation instead of
# being printed and admired. A tool shape reporting 0 means the schema never reached the probe, and
# then byte-stability for that shape says nothing about schemas — the exact defect this file had.
declare = {"bare": 0, "required": 1, "unrequired": 1, "history": 0}
by_shape = collections.defaultdict(dict)   # shape -> boot -> (hash, carried)
seq = collections.defaultdict(list)
for row in rows:
    if len(row) < 3:
        continue
    seq[row[0]].append((row[1], int(row[2])))
for boot, entries in sorted(seq.items()):
    for shape, (h, carried) in zip(shapes, entries):
        by_shape[shape][boot] = (h, carried)
bad = 0
for shape in shapes:
    per = by_shape.get(shape, {})
    vals = sorted({h for h, _ in per.values()})
    carries = sorted({c for _, c in per.values()})
    print("  shape %-11s boots=%d distinct promptHash=%d %s toolsCarried=%s"
          % (shape, len(per), len(vals), vals, carries))
    if len(per) < boots:
        print("     FAIL  only %d/%d boots recorded a hash for this shape" % (len(per), boots))
        bad += 1
        continue
    if any(c != declare[shape] for c in carries):
        print("     FAIL  this shape declares %d tool(s) but the probe carried %s — the schema is "
              "outside promptHash, so 'stable bytes' below cannot be read as schema stability"
              % (declare[shape], carries))
        bad += 1
    if len(vals) != 1:
        print("     FAIL  P0 REGRESSION: prompt bytes for '%s' vary across boots — a dictionary/Set "
              "or unsorted JSON is reaching the prompt" % shape)
        bad += 1
# Sensitivity: a turn that declares a tool may not hash the same as one that does not, otherwise
# "stable bytes" would only prove nothing was injected at all. And now that schemas are inside the
# hash, `required` and `unrequired` must differ too — they carry different names, descriptions and
# property sets, so a collision there would mean the carried specs were dropped on the way to
# prepare(), which is the same instrument blindness as toolsCarried=0 wearing a different hat.
for boot, entries in sorted(seq.items()):
    if len(entries) != len(shapes):
        continue
    by = dict(zip(shapes, entries))
    if by["bare"][0] == by["required"][0]:
        print("  FAIL  boot %s: declaring a tool changed nothing in the prompt (%s) — the "
              "declaration never reached it, so byte stability here is vacuous"
              % (boot, [h for h, _ in entries]))
        bad += 1
    elif by["required"][0] == by["unrequired"][0]:
        print("  FAIL  boot %s: the two tool schemas hash identically (%s) though they differ in "
              "name, description and properties — the carried specs are not reaching the tokenizer"
              % (boot, by["required"][0]))
        bad += 1
print("  verdict: %s" % ("prompt bytes are request-determined for all shapes, schemas included"
                         if bad == 0 else "%d determinism defect(s)" % bad))
sys.exit(1 if bad else 0)
PY
PY_RC=$?
if [ -n "$KEEP_DUMP" ]; then
  printf '  NOTE  prompt bytes kept in %s (one file per distinct promptHash; diff names the varying lines)\n' "$DUMP"
else
  rm -rf "$DUMP" "$DUMP.all"
fi
if [ "$PY_RC" -eq 0 ]; then
  probe_ok "same request -> same prompt bytes across $BOOTS boots, and shapes distinguishable"
else
  probe_fail "prompt-byte determinism broken (see per-shape lines above)"
fi
probe_summary "$PROBE_NAME"
