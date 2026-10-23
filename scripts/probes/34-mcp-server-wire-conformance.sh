#!/usr/bin/env bash
# 34-mcp-server-wire-conformance.sh — does the advertised /mcp face answer the requests the
# specs it names actually allow?
#
# ### Measured on this host at HEAD, by booting `serve` and posting spec-legal JSON-RPC
#   1. `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` → `-32700 Parse error`.
#      `JsonRpcReq.id` was `String?`, so the synthesized Decodable *required* a string, while
#      JSON-RPC §4.1 allows String, Number or Null. The Python/TypeScript MCP SDKs and Claude
#      Desktop send integers: a standard client could not complete one handshake with a route the
#      endpoint catalog publishes (`V1EndpointCatalog.swift`: POST /mcp).
#   2. `params` was decoded into `paramsData`, a key that exists nowhere on the wire, so every
#      request arrived with params == nil. `tools/call` answered `{"result":{}}` — present, empty,
#      success-shaped. A caller cannot tell "the tool ran and returned nothing" from "we threw your
#      arguments away", which is the worst direction invariant 2 can point.
#   3. `tools/list` answered `{"inputSchema":{"properties":{},"type":"object"}}` for all 39
#      tools: every tool described as taking no arguments, with descriptions dropped. A client
#      that trusted the list generated argument-less calls; nothing could succeed.
#
# ### What is asserted (each leg was the failure above)
#   A. uninitialized says so — `tools/list` before `initialize` names the missing step instead of
#      returning an empty list that reads as "this server has no tools".
#   B. numeric id is accepted (no -32700) and echoed back as a NUMBER, since §4.1 requires the
#      responder to return the same identifier.
#   C. tools/list describes the tools — floor on the count, and at least one tool carrying real
#      `properties` and a `description`.
#   D. params decode — `tools/call` with a real name and real arguments returns content built from
#      those arguments, not `{}`.
#   E. a malformed call is refused by name (-32602 naming `name`), never answered empty.
#
# Run: bash scripts/probes/run.sh 34
source "$(dirname "$0")/_lib.sh"

PROBE_NAME="34-mcp-server-wire-conformance"

rpc() {  # raw JSON-RPC over the advertised route
  probe_api POST /mcp "$1"
}
body() { printf '%s' "${PROBE_BODY:-}"; }

probe_boot
probe_require_ready_model

probe_section "A) tools/list before initialize names the missing step (silent {} reads as 'no tools')"
rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
if body | grep -q '"error"'; then
  if body | grep -qi "initialize"; then
    probe_ok "uninitialized refusal states the step: $(body | head -c 120)"
  else
    probe_fail "error did not name the missing step: $(body | head -c 160)"
  fi
else
  probe_fail "pre-initialize tools/list was not refused by name: $(body | head -c 160)"
fi

probe_section "B) a spec-legal numeric id completes a handshake and echoes as a number"
rpc '{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
if body | grep -q '\-32700'; then
  probe_fail "numeric id rejected as Parse error — §4.1 allows Number ids; standard SDK clients send them"
elif [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "initialize HTTP ${PROBE_STATUS:-none}: $(body | head -c 160)"
else
  probe_ok "initialize accepted a numeric id (no -32700)"
  python3 - "$(body)" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
got = d.get("id")
if isinstance(got, str):
    print('  id echoed as the string "%s" — the same identifier must come back' % got)
    sys.exit(1)
if not isinstance(got, (int, float)):
    print("  id missing or wrong type: %r" % (got,))
    sys.exit(1)
if int(got) != 7:
    print("  id changed value on the way out: sent 7, got %r" % (got,))
    sys.exit(1)
print("  id echoed as %r (%s)" % (got, type(got).__name__))
PY
  if [ $? -eq 0 ]; then
    probe_ok "numeric id survives the round trip as a number"
  else
    probe_fail "id did not survive the round trip (JSON-RPC wants the same identifier back)"
  fi
fi
if body | grep -q '"protocolVersion"'; then
  probe_ok "handshake result carries protocolVersion"
else
  probe_fail "initialize returned no capabilities: $(body | head -c 160)"
fi

probe_section "C) tools/list describes the tools it exposes"
rpc '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}'
python3 - "$(body)" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
tools = d.get("result", {}).get("tools", [])
if len(tools) < 10:
    print("  tools/list published %d tools — too few to describe a registry" % len(tools))
    sys.exit(1)
rich = [t for t in tools
        if t.get("inputSchema", {}).get("properties") and t.get("description")]
if not rich:
    print("  %d tools published, none with properties+description — the surface describes "
          "nothing (HEAD shipped properties:{} for all of them)" % len(tools))
    sys.exit(1)
sample = rich[0]
print("  %d tools, %d with real schemas; e.g. %s props=%s"
      % (len(tools), len(rich), sample["name"],
         sorted(sample["inputSchema"]["properties"])))
PY
if [ $? -eq 0 ]; then
  probe_ok "tools/list publishes real parameter schemas"
else
  probe_fail "tools/list does not describe its tools — clients get properties:{} and must guess"
fi

probe_section "D) params reach the tool: a real tools/call returns its arguments, not {}"
rpc '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"Package.swift"}}}'
python3 - "$(body)" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if "error" in d:
    print("  tools/call refused: %s" % json.dumps(d["error"])[:200])
    sys.exit(1)
res = d.get("result", {})
if not res:
    print("  result is empty — params were dropped again (HEAD answered exactly {})")
    sys.exit(1)
text = "".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
if "swift-tools-version" not in text:
    print("  the arguments never reached the tool, got: %s" % text[:200])
    sys.exit(1)
print("  tools/call executed with arguments (%d chars back)" % len(text))
PY
if [ $? -eq 0 ]; then
  probe_ok "params reach the tool and its output comes back"
else
  probe_fail "tools/call did not deliver the call — a success-shaped empty result is not an answer"
fi

probe_section "E) a call without name is refused by name, not answered empty"
rpc '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"arguments":{}}}'
if body | grep -q '"error"'; then
  if body | grep -q '\-32602' && body | grep -q 'name'; then
    probe_ok "malformed tools/call refused with -32602 naming the field"
  else
    probe_fail "refusal did not name the field/code: $(body | head -c 160)"
  fi
else
  probe_fail "malformed tools/call looked like success: $(body | head -c 160)"
fi

probe_section "F) a normal chat turn still works after MCP traffic"
probe_chat "mcp-wire-survival" "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":16,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word SURVIVE.\"}]}"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "box still serving after MCP conformance traffic"
else
  probe_fail "server stopped answering after MCP traffic: HTTP ${PROBE_STATUS:-none}"
fi

probe_summary "$PROBE_NAME"
