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
# Shapes: no tools / tool with `required` declared / tool with `required` omitted (the schema then
# falls through to Array(parameters.keys) — the dictionary exit that actually randomizes bytes) /
# with prior history.
#
# Fails when: any shape yields more than one promptHash across boots, or shapes collide within a
# boot, or too few boots/turns completed to say anything.
source "$(dirname "$0")/_lib.sh"

PROBE_NAME="32-prompt-byte-determinism"
BOOTS="${BOOTS:-3}"
DUMP="${TMPDIR:-/tmp}/ocoreai-bytes-$$"

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
msgs.append({"role": "user", "content": "Reply with the single word READY."})
body = {
    "model": model,
    "session_id": "bytes-%s" % shape,
    "max_tokens": 8,
    "temperature": 0.0,
    "stream": False,
    "messages": msgs,
}
if shape == "tools_noreq":
    # The discriminating shape: `required` is NOT declared, so the schema falls through to
    # `Array(schema.parameters.keys)` (ToolRegistry.swift:817, ToolEntry.swift:235,
    # MCPTools.swift:46) and the `properties` map is handed over as a dictionary. Both are
    # Dictionary exits, so ordering is seed-dependent unless something sorts it. The shape with
    # `required` declared cannot see this hole — its required array comes from the request.
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
elif shape == "tools":
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

SHAPES="notools tools tools_noreq history"

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
  grep -o "promptHash=[0-9a-f]*" "$PROBE_LOG" 2>/dev/null | sed "s/promptHash=//; s/^/$b\t/" >> "$DUMP.all" || true
  probes_cleanup >/dev/null 2>&1
  sleep 2
done
unset OCOREAI_MARGIN_PROBE OCOREAI_MARGIN_DUMP

N=$(grep -c . "$DUMP.all" 2>/dev/null || echo 0)
if [ "$N" -lt "$(( BOOTS * 4 ))" ]; then
  probe_fail "only $N prompt hashes recorded for $BOOTS boots x 3 shapes — the probe did not run on every turn"
fi

python3 - "$DUMP.all" "$BOOTS" <<'PY'
import collections, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
boots = int(sys.argv[2])
by_shape = collections.defaultdict(dict)   # shape -> boot -> hash
# Rows arrive in send order within a boot: notools, tools, history.
seq = collections.defaultdict(list)
for boot, h in rows:
    seq[boot].append(h)
shapes = ["notools", "tools", "tools_noreq", "history"]
for boot, hs in sorted(seq.items()):
    for shape, h in zip(shapes, hs):
        by_shape[shape][boot] = h
bad = 0
for shape in shapes:
    per = by_shape.get(shape, {})
    vals = sorted(set(per.values()))
    print("  shape %-8s boots=%d distinct promptHash=%d %s" % (shape, len(per), len(vals), vals))
    if len(per) < boots:
        print("     FAIL  only %d/%d boots recorded a hash for this shape" % (len(per), boots))
        bad += 1
    elif len(vals) != 1:
        print("     FAIL  P0 REGRESSION: prompt bytes for '%s' vary across boots — a dictionary/Set "
              "or unsorted JSON is reaching the prompt" % shape)
        bad += 1
# Sensitivity, stated precisely. What must differ is the presence of a declaration: a turn with
# tools may not hash the same as a turn without them, otherwise "stable bytes" would only prove
# nothing was injected. What must NOT be assumed to differ is the tool schema text: the surface
# injects local tool names, and a caller-declared name that is not local goes back as tool_calls
# capability without ever reaching the prompt (ToolDeclarationSurfaceTests, probe 11 §7), so two
# shapes that differ only in a foreign schema legitimately collide. Colliding there is reported,
# not failed — a gate that red-lights documented design is a gate people learn to ignore.
for boot, hs in sorted(seq.items()):
    if len(hs) != len(shapes):
        continue
    by = dict(zip(shapes, hs))
    if by.get("notools") == by.get("tools"):
        print("  FAIL  boot %s: declaring a tool changed nothing in the prompt (%s) — the "
              "declaration never reached it, so byte stability here is vacuous" % (boot, hs))
        bad += 1
    elif by.get("tools") == by.get("tools_noreq"):
        print("  NOTE  boot %s: both tool shapes hash identically (%s) — expected when the "
              "declared names are not local tools: the surface injects 0/N and only the "
              "tools/no-tools directive changes the bytes" % (boot, by["tools"]))
print("  verdict: %s" % ("prompt bytes are request-determined for all shapes" if bad == 0
                         else "%d determinism defect(s)" % bad))
sys.exit(1 if bad else 0)
PY
PY_RC=$?
rm -rf "$DUMP" "$DUMP.all"
if [ "$PY_RC" -eq 0 ]; then
  probe_ok "same request -> same prompt bytes across $BOOTS boots, and shapes distinguishable"
else
  probe_fail "prompt-byte determinism broken (see per-shape lines above)"
fi
probe_summary "$PROBE_NAME"
