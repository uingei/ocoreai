#!/usr/bin/env bash
# 33-mcp-required-byte-determinism.sh — does a tool whose server declares no `required` reach the
# prompt with the same bytes every boot?
#
# ### Why this door and not the caller's `tools[]`
# Probe 32 proved prompt bytes are request-determined for caller-declared tools. It left one
# synthesis path untouched, because a caller-declared schema never routes through it: when *nobody*
# declares `required`, the registry writes "every declared parameter is required" from
# `Array(schema.parameters.keys)` — the iteration order of a Swift `Dictionary`, which Swift picks
# from a **per-process hash seed**. Two cold boots, two orders, two prompt hashes: the 10-23(8)
# skill-block class arriving through MCP. The two live exits are `ToolRegistry.swift:820` and
# `ToolEntry.swift:237` (the third translation, `MCPTools`, was reached by nobody and is deleted —
# the outbound face publishes from the same home as everything else). All 8 built-ins declare
# `required` themselves, so an MCP server that omits it (`inputSchema.required` absent is
# MCP-legal — `MCPBridge.swift:782` reads it with `as? [String]`, so it lands as nil) is the only
# door left on this host.
#
# ### What is asserted, in order
#   1. REACHABILITY — the tool must be *local* (the engine logs
#      `whitelist route (1 local + 0 caller-only of 1)`), otherwise nothing of its schema enters
#      the prompt and every byte claim below would be vacuous.
#   2. THE DECLARATION ARRIVES — the dumped prompt contains a `<|tool>declaration:mcp_noreq`
#      block with a `required:` list of all four parameters.
#   3. BYTES ACROSS BOOTS — one `promptHash` for this shape across boots, and the extracted
#      `required:` sequence byte-identical between boots.
#   4. ORDER — that sequence is name-sorted, i.e. it came from the canonicalizer and not from
#      whoever happened to build the dictionary.
#   5. Premises floored — boots >= 2, hashes >= boots, four names extracted per boot.
#
# `required` is a set, so sorting changes no meaning; it only stops the process seed from
# authoring prompt bytes. A caller-declared subset keeps its own order (asserted in
# `ToolRequiredOrderDeterminismTests`), because that order came from the request.
source "$(dirname "$0")/_lib.sh"

PROBE_NAME="33-mcp-required-byte-determinism"
BOOTS="${BOOTS:-2}"
DUMP="${OCOREAI_MARGIN_DUMP:-${TMPDIR:-/tmp}/ocoreai-mcp-req-$$}"
KEEP_DUMP="${OCOREAI_MARGIN_DUMP:-}"

STUB="$(mktemp -t oc_mcp_req_stub_XXXXXX).py"
cleanup() { rm -f "$STUB"; [ -z "$KEEP_DUMP" ] && rm -rf "$DUMP" "$DUMP.all"; return 0; }
trap cleanup EXIT

cat > "$STUB" <<'PYEOF'
import sys, json

def out(obj):
    print(json.dumps(obj))
    sys.stdout.flush()

# Insertion order is deliberately NOT alphabetical: if a raw `.keys` reaches the prompt, the
# rendered order will differ from `alpha,bravo,charlie,delta` in most processes.
TOOLS = [
    {"name": "mcp_noreq",
     "description": "Reports rows; declares no required list.",
     "inputSchema": {"type": "object",
                     "properties": {"delta": {"type": "string"},
                                   "charlie": {"type": "string"},
                                   "alpha": {"type": "string"},
                                   "bravo": {"type": "string"}}}},
]

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method = msg.get("method", "")
    if method == "initialize":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "ocoreai-required-stub", "version": "0.1"}}})
    elif method.startswith("notifications/"):
        pass
    elif method == "tools/list":
        out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": TOOLS}})
    elif method == "tools/call":
        out({"jsonrpc": "2.0", "id": msg.get("id"),
             "result": {"content": [{"type": "text", "text": "ok"}]}})
    else:
        out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
PYEOF

mcp_call() {
  probe_api POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

shape_body() {
  python3 - "$PROBE_MODEL" <<'PY'
import json, sys
body = {
    "model": sys.argv[1],
    "session_id": "bytes-mcp-noreq",
    "max_tokens": 8,
    "temperature": 0.0,
    "stream": False,
    "messages": [
        {"role": "system", "content": "You are a terse assistant. Answer exactly as asked."},
        {"role": "user", "content": "Reply with the single word READY."},
    ],
    # A client declaring the server's tool by name: the registry is local, so resolveToolSurface
    # hands the *registry* spec upstream — the one whose `required` we synthesize.
    "tools": [{
        "type": "function",
        "function": {
            "name": "mcp_noreq",
            "description": "Reports rows; declares no required list.",
            "parameters": {
                "type": "object",
                "properties": {
                    "delta": {"type": "string", "description": "d"},
                    "charlie": {"type": "string", "description": "c"},
                    "alpha": {"type": "string", "description": "a"},
                    "bravo": {"type": "string", "description": "b"},
                },
            },
        },
    }],
}
print(json.dumps(body))
PY
}

export OCOREAI_MARGIN_PROBE=all
export OCOREAI_MARGIN_DUMP="$DUMP"

for b in $(seq 1 "$BOOTS"); do
  probe_boot
  probe_require_ready_model

  probe_section "boot $b: connect the server that declares no required"
  mcp_call '$bridge/endpoint/connect' \
    "{\"name\":\"reqorder-$b\",\"command\":\"python3\",\"args\":[\"$STUB\"]}"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "endpoint/connect -> HTTP ${PROBE_STATUS:-none}: ${PROBE_BODY:0:200}"
  fi

  probe_chat "bytes-mcp-noreq" "$(shape_body)"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "boot $b chat -> HTTP ${PROBE_STATUS:-none} (nothing was measured)"
  fi

  # 1) REACHABILITY: local, not caller-only. Without this the schema never enters the prompt.
  if grep -q "Tool surface \[whitelist route (1 local + 0 caller-only of 1)\]" "$PROBE_LOG"; then
    probe_ok "boot $b: mcp_noreq resolved as a local tool (its spec reaches the prompt)"
  else
    probe_fail "boot $b: mcp_noreq was not local — $(grep -o 'Tool surface \[[^]]*\]: [0-9]*/[0-9]* injected' "$PROBE_LOG" | head -1) — no schema bytes entered the prompt, so bytes below would be vacuous"
  fi

  grep -oE "promptHash=[0-9a-f]+ toolsCarried=[0-9]+" "$PROBE_LOG" 2>/dev/null \
    | sed -E "s/promptHash=([0-9a-f]+) toolsCarried=([0-9]+)/$b\t\1\t\2/" >> "$DUMP.all" || true
  probes_cleanup >/dev/null 2>&1
  sleep 2
done
unset OCOREAI_MARGIN_PROBE OCOREAI_MARGIN_DUMP

python3 - "$DUMP" "$DUMP.all" "$BOOTS" <<'PY'
import collections, os, re, sys

dump, all_path, boots = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = [l.rstrip("\n").split("\t") for l in open(all_path) if l.strip()] if os.path.exists(all_path) else []
seq = collections.defaultdict(list)
for row in rows:
    if len(row) >= 3:
        seq[row[0]].append((row[1], int(row[2])))

names = ["alpha", "bravo", "charlie", "delta"]
per_boot_decl = {}
for boot, entries in sorted(seq.items()):
    if not entries:
        continue
    h = entries[-1][0]
    path = os.path.join(dump, "prompt-%s.txt" % h)
    if not os.path.exists(path):
        print("  FAIL  boot %s: no dumped prompt for %s — nothing to read the declaration from" % (boot, h))
        continue
    text = open(path, encoding="utf-8", errors="replace").read()
    block = re.search(r"<\|tool>declaration:mcp_noreq.*?<tool\|>", text, re.S)
    if not block:
        print("  FAIL  boot %s: no <|tool>declaration:mcp_noreq block in the delivered prompt" % boot)
        continue
    req = re.search(r"required:\[([^\]]*)\]", block.group(0))
    # The template wraps every string member in its own quote token `<|"|>` (so a schema cannot
    # forge a boundary), and the token appears on BOTH sides of the name. Strip the token rather
    # than matching `<|"` … `"|>`, which straddles two members and yields `|>alpha<|`.
    quote = '<|"|>'
    items = []
    if req:
        items = [t.replace(quote, "").strip() for t in req.group(1).split(",")]
        items = [t for t in items if t]
    per_boot_decl[boot] = (h, items, block.group(0))
    print("  boot %-3s promptHash=%s required=%s" % (boot, h, items))

bad = 0
if len(per_boot_decl) < boots:
    print("  FAIL  only %d/%d boots produced a readable declaration" % (len(per_boot_decl), boots))
    bad += 1
hashes = {h for h, _, _ in per_boot_decl.values()}
if len(per_boot_decl) >= 2 and len(hashes) != 1:
    print("  FAIL  P0 REGRESSION: the same MCP request hashed %s across boots — a Dictionary order "
          "is authoring prompt bytes" % sorted(hashes))
    bad += 1
if len(per_boot_decl) >= 2:
    decls = {d for _, _, d in per_boot_decl.values()}
    if len(decls) != 1:
        print("  FAIL  the rendered tool declaration differs across boots (%d variants)" % len(decls))
        bad += 1
for boot, (_, items, _) in sorted(per_boot_decl.items()):
    if sorted(items) != names:
        print("  FAIL  boot %s: required=%s is not the four parameters — the synthesized list is wrong"
              % (boot, items))
        bad += 1
    elif items != names:
        print("  FAIL  boot %s: required=%s is not name-sorted — the canonicalizer was bypassed"
              % (boot, items))
        bad += 1
print("  verdict: %s" % ("MCP-synthesized required list reaches the prompt sorted and boot-stable"
                         if bad == 0 else "%d determinism defect(s)" % bad))
sys.exit(1 if bad else 0)
PY
PY_RC=$?
if [ "$PY_RC" -eq 0 ]; then
  probe_ok "no-declared-required tool reaches the prompt with identical bytes and a name-sorted required list"
else
  probe_fail "MCP required-list determinism broken (see per-boot lines above)"
fi
probe_summary "$PROBE_NAME"
