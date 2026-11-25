#!/usr/bin/env bash
# 62-acp-stdio.sh. Does `ocoreai acp` actually speak ACP to a client over stdio?
#
# ### Why
# The ACP face is how an editor drives this agent, and every claim about it is a property of the
# running process, not of a unit test: stdout must carry protocol messages ONLY (one stray log byte
# kills the client's parser), the turn must stream as `session/update` notifications and answer
# exactly once, and the HTTP bridge must stay down. The pure codec half is
# Tests/ocoreaiTests/ACPFramingTests.swift; this is the live half (AGENTS.md: prefer a live drive
# over an inference about behaviour).
#
# ### What makes it a proof rather than a demo
# Weight-free: the scripted engine lane answers every turn from a script this file owns, so the
# compared values are literals here, not model output. A real Python driver holds the subprocess
# open across the whole session (line-buffered, one thread per pipe) because a shell pipeline
# cannot read a live pipe line-by-line — the exact defect this probe now gates. Every stdout line
# is re-parsed, and the listening-socket check runs while the process is still alive.
#
# ### Premises (each a red with a remedy, never a skip)
# The resolved binary and python3. A missing subject is red naming the remedy, so a tree cannot
# pass by having no driver.
#
# Fails when: stdout carries a non-JSON line, initialize/session new/prompt lose exact values or
# stopReason, a foreign protocolVersion is refused instead of answered with ours, a client that
# stays after a declined negotiation gets a session, tool_call's rawInput is not the parsed
# object, an unknown method is not refused with -32601 quoting the method, a refused session/new
# shape is accepted, the bridge opens a listening socket anyway, EOF does not exit 0,
# `acp --help`/a bad token stops refusing cleanly, an answered turn is absent from
# session/list, session/load answers before its replay finished or replays a different order,
# or a loaded session cannot continue. The permission handshake is gated in ACPFramingTests,
# not here: the scripted lane surfaces tool calls without dispatching them, so no weight-free
# drive parks an approval — the same boundary this probe's completion claim stops at.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="acp-stdio"

BIN="$(probe_resolve_binary)" || probe_fail "no ocoreai binary" " set OCOREAI_BIN"
command -v python3 >/dev/null 2>&1 \
  || probe_fail "no python3 to drive the stdio session" \
    " the driver is the subject's only client; a skip here would let a tree pass with no witness"

EXPECTED_TEXT='Sure — two deltas, in order.'
EXPECTED_TOOL='read_file'
EXPECTED_ARGS='{"path":"README.md"}'

# ── §0 refusal before boot: no arguments are honoured, usage answers ───────────────────────────
probe_section "§0 'acp --help' exits 0; an unknown token exits 64 naming itself"
HELP_OUT="$("$BIN" acp --help 2>&1)"; HELP_RC=$?
if [ "$HELP_RC" -eq 0 ] && printf '%s' "$HELP_OUT" | grep -q 'session/prompt' \
   && printf '%s' "$HELP_OUT" | grep -q 'Registry'; then
  probe_ok "usage answers exit 0 and names the methods spoken and the registry limit"
else
  probe_fail "acp --help exited $HELP_RC without the promised text" " see ACPMode.usageText()"
fi
REFUSE_ERR="$("$BIN" acp --port 9090 2>&1 >/dev/null)"; REFUSE_RC=$?
if [ "$REFUSE_RC" -eq 64 ] && printf '%s' "$REFUSE_ERR" | grep -q -- '--port'; then
  probe_ok "an unrecognized token is refused exit 64 and quoted, before anything boots"
else
  probe_fail "acp --port 9090 exited $REFUSE_RC; refusal must be 64 and name the token" \
    " a silently-ignored flag would serve a config nobody asked for"
fi

# ── §1 the live session: scripted lane, one subprocess, whole protocol ─────────────────────────
probe_section "§1 initialize → session/new → session/prompt over a live pipe"
SCRIPT_FILE="$(mktemp -t ocoreai-acp-script-XXXXXX).json"
DRIVER="$(mktemp -t ocoreai-acp-driver-XXXXXX).py"
probe_atexit "rm -f '$SCRIPT_FILE' '$DRIVER'"
cat > "$SCRIPT_FILE" <<'JSON'
{
  "reasoning": ["planning the answer"],
  "segments": ["Sure", " — two deltas, in order."],
  "toolCalls": [{"id": "call_1", "name": "read_file", "arguments": "{\"path\":\"README.md\"}"}],
  "finishReason": "eos",
  "promptTokens": 7,
  "generatedTokens": 12
}
JSON
cat > "$DRIVER" <<'PY'
"""Drives one `ocoreai acp` subprocess end to end; prints TAG\tvalue lines for the bash side.
Never a repo artefact beyond this probe: the session is the subject."""
import json, os, subprocess, sys, tempfile, threading, time

BIN, SCRIPT = sys.argv[1], sys.argv[2]
# OCOREAI_DATA_DIR is the store's lease: HOME alone does not move it (NSHomeDirectory
# ignores $HOME), and without the lease these probe rows would land on the operator's
# real session page.
env = dict(os.environ,
           HOME=tempfile.mkdtemp(prefix="ocoreai-acp-home-"),
           OCOREAI_DATA_DIR=tempfile.mkdtemp(prefix="ocoreai-acp-data-"),
           OCOREAI_SCRIPTED_ENGINE=SCRIPT,
           OCOREAI_DEFAULT_MODEL="scripted-model",
           OCOREAI_ALLOW_MULTI_INSTANCE="1")
proc = subprocess.Popen([BIN, "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
out, err = [], []

def pump(pipe, sink):
    for line in pipe:
        sink.append(line.rstrip("\n"))

threading.Thread(target=pump, args=(proc.stdout, out), daemon=True).start()
threading.Thread(target=pump, args=(proc.stderr, err), daemon=True).start()

def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()

def wait_for(needle, budget=180.0):
    deadline = time.time() + budget
    while time.time() < deadline:
        for line in out:
            if needle(line):
                return line
        if proc.poll() is not None:
            return None
        time.sleep(0.25)
    return None

def tag(name, value):
    print(f"{name}\t{value}")

def reply(rid):
    def matches(l):
        try:
            return json.loads(l).get("id") == rid
        except Exception:
            return False
    return wait_for(matches)

# v1 initialization is a negotiation: a version we do not speak is ANSWERED with ours (the
# client closes the connection itself), and sessions stay closed until an accepted handshake.
send({"jsonrpc": "2.0", "id": 6, "method": "initialize",
      "params": {"protocolVersion": 2}})
neg = reply(6)
negj = json.loads(neg) if neg else {}
tag("neg-error", "error" if "error" in negj else "none")
tag("neg-version", (negj.get("result") or {}).get("protocolVersion"))
send({"jsonrpc": "2.0", "id": 7, "method": "session/new",
      "params": {"cwd": os.getcwd(), "mcpServers": []}})
sn = reply(7)
tag("neg-session", "error" if sn and '"error"' in sn else "none")

send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
      "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": True}}}})
init = reply(0)
if init is None:
    tag("init-missing", "stderr: " + " | ".join(err[-6:]))
    sys.exit(0)
init = json.loads(init)
caps = init.get("result", {}).get("agentCapabilities", {})
pc = caps.get("promptCapabilities", {})
tag("init-version", init.get("result", {}).get("protocolVersion"))
tag("init-load-session", caps.get("loadSession"))
tag("init-image", pc.get("image"))
tag("init-audio", pc.get("audio"))
tag("init-embedded", pc.get("embeddedContext"))
tag("init-auth-methods", json.dumps(init.get("result", {}).get("authMethods")))
tag("agent-version", init.get("result", {}).get("agentInfo", {}).get("version"))

send({"jsonrpc": "2.0", "id": 1, "method": "session/new",
      "params": {"cwd": os.getcwd(), "mcpServers": []}})
new = reply(1)
tag("session-ok", "1" if new and "sessionId" in new else "0")
sid = json.loads(new)["result"]["sessionId"] if new and "result" in new else "none"

# Two refusals invariant 2 demands: a cwd we cannot honour, and directories we were not given.
send({"jsonrpc": "2.0", "id": 4, "method": "session/new", "params": {"cwd": "", "mcpServers": []}})
tag("cwd-refused", "1" if reply(4) and '"error"' in reply(4) else "0")
send({"jsonrpc": "2.0", "id": 5, "method": "session/new",
      "params": {"cwd": os.getcwd(), "mcpServers": [], "additionalDirectories": ["/tmp"]}})
tag("dirs-refused", "1" if reply(5) and '"error"' in reply(5) else "0")

send({"jsonrpc": "2.0", "id": 2, "method": "session/prompt",
      "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}]}})
prompt = reply(2)
updates = []
for line in out:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get("method") == "session/update":
        updates.append(msg.get("params", {}).get("update", {}).get("sessionUpdate"))
tag("stop-reason", (json.loads(prompt).get("result") or {}).get("stopReason")
    if prompt and "result" in prompt else "no-reply")
tag("thought-chunks", updates.count("agent_thought_chunk"))
tag("message-chunks", updates.count("agent_message_chunk"))
tag("tool-calls", updates.count("tool_call"))
texts = []
for line in out:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    upd = (msg.get("params") or {}).get("update") or {}
    if upd.get("sessionUpdate") == "agent_message_chunk":
        texts.append(((upd.get("content") or {}).get("text")) or "")
tag("msg-joined", "".join(texts))
tool_title = ""
tool_raw = ""
for line in out:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    upd = (msg.get("params") or {}).get("update") or {}
    if upd.get("sessionUpdate") == "tool_call":
        tool_title = f"{upd.get('title')}|{upd.get('status')}"
        tool_raw = json.dumps(upd.get("rawInput"), sort_keys=True)
tag("tool-call", tool_title)
tag("tool-raw", tool_raw)

# Durability, listable, loadable: the turn just answered must now BE the store's row,
# session/list must report exactly it, and session/load must replay it before answering.
send({"jsonrpc": "2.0", "id": 8, "method": "session/list", "params": {}})
listing = reply(8)
entries = ((json.loads(listing).get("result") or {}).get("sessions") or []) if listing else []
one = len(entries) == 1 and entries[0].get("sessionId") == sid \
    and entries[0].get("cwd") == os.getcwd() and "T" in str(entries[0].get("updatedAt"))
tag("list-matches", "1" if one else "0 " + json.dumps(entries)[:120])

boundary = len(out)
send({"jsonrpc": "2.0", "id": 10, "method": "session/load",
      "params": {"sessionId": sid, "cwd": os.getcwd(), "mcpServers": []}})
loaded = reply(10)
seq, response_at = [], None
tail = out[boundary:]
for i, line in enumerate(tail):
    try:
        msg = json.loads(line)
    except Exception:
        continue
    upd = (msg.get("params") or {}).get("update") or {}
    if upd.get("sessionUpdate"):
        seq.append(upd["sessionUpdate"])
    if msg.get("id") == 10:
        response_at = i
tag("replay-seq", " ".join(seq))
tag("replay-last", "1" if response_at == len(tail) - 1 else "0")
lr = json.loads(loaded) if loaded else {}
tag("replay-result", "empty" if lr.get("result") == {} else json.dumps(lr.get("result"))[:60])

send({"jsonrpc": "2.0", "id": 11, "method": "session/prompt",
      "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "and again"}]}})
again = reply(11)
tag("reload-stop", (json.loads(again).get("result") or {}).get("stopReason")
    if again and "result" in again else "no-reply")

send({"jsonrpc": "2.0", "id": 3, "method": "session/bogus", "params": {}})
bogus = reply(3)
if bogus:
    body = json.loads(bogus).get("error") or {}
    tag("bogus-code", body.get("code"))
    tag("bogus-message", body.get("message"))
else:
    tag("bogus-code", "no-reply")

# stdout purity and bridge-off, both sampled while the process is still alive.
bad = 0
for line in out:
    try:
        json.loads(line)
    except Exception:
        bad += 1
tag("purity-bad", bad)
lsof = subprocess.run(["lsof", "-a", "-p", str(proc.pid), "-iTCP", "-sTCP:LISTEN", "-n", "-P"],
                      capture_output=True, text=True)
tag("listen-count", max(0, len(lsof.stdout.strip().splitlines()) - 1))

proc.stdin.close()
try:
    rc = proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    rc = "timeout"
tag("exit-code", rc)
tag("line-count", len(out))
PY

DRIVER_OUT="$(python3 -I "$DRIVER" "$BIN" "$SCRIPT_FILE" 2>/dev/null)"
if [ -z "$DRIVER_OUT" ]; then
  probe_fail "the driver produced no assertions" \
    " run 'python3 -I' on the driver by hand; a silent driver is a green with no subject"
fi

driv() { printf '%s\n' "$DRIVER_OUT" | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }
want() { # want <tag> <expected> <claim>
  local got; got="$(driv "$1")"
  if [ "$got" = "$2" ]; then probe_ok "$3 ($1=$got)"; else
    probe_fail "$3 — got '$got', wanted '$2'" " the driver prints every tag it sampled; compare with ACPAgent.swift"
  fi
}

want init-version 1 "initialize answers the one protocol version we speak"
want init-load-session True "loadSession is promised because the transcript is stored and replayed"
want init-image False "image blocks are refused at capability level"
want init-audio False "audio blocks are refused at capability level"
want init-embedded True "embedded context is the one prompt capability kept"
want init-auth-methods '[]' "no auth methods: this product has no account and no key"
# `--version` prints "ocoreai <shortVersion>"; the wire carries only the version half.
VERSION_WANTED="$("$BIN" --version | awk '{print $NF}')"
want agent-version "$VERSION_WANTED" "agentInfo.version is AppInfo.shortVersion, the same truth --version prints"
want session-ok 1 "session/new hands back a sessionId"
want cwd-refused 1 "an empty cwd is refused, not defaulted to somewhere the client never chose"
want dirs-refused 1 "additionalDirectories we cannot honour are refused, not silently dropped"
want stop-reason end_turn "the scripted turn answers exactly once with end_turn"
want message-chunks 2 "the turn streams its message as chunks"
want msg-joined "$EXPECTED_TEXT" "the chunks rejoin byte-exact to the scripted text"
want tool-calls 1 "the tool call surfaces as a tool_call update"
want tool-call "$EXPECTED_TOOL|in_progress" "tool_call carries the call's own name and in_progress"
want tool-raw '{"path": "README.md"}' "rawInput is the parsed object an editor can render, not its escaped string"
want neg-error none "a foreign protocolVersion is negotiated, not refused (v1 initialization)"
want neg-version 1 "the declined client is answered with the latest version we speak"
want neg-session error "a client that stayed after the declined negotiation gets no session"
want bogus-code -32601 "an unknown method is refused with method-not-found"
want list-matches 1 "the answered turn is the store's row: session/list reports exactly it, cwd and stamp included"
want replay-seq "user_message_chunk agent_thought_chunk agent_message_chunk tool_call" \
  "session/load replays the stored turn in conversation order, the scripted tool call without a result never closes"
want replay-last 1 "the load response arrives only after every entry has been streamed (v1 MUST)"
want replay-result empty "session/load answers the empty result the v1 schema spells"
want reload-stop end_turn "a loaded session continues: the next prompt answers end_turn on the re-fed history"
BOGUS_MSG="$(driv bogus-message)"; case "$BOGUS_MSG" in *session/bogus*) probe_ok "the refusal quotes the method the client sent";; *) probe_fail "the refusal does not quote the method (said: '$BOGUS_MSG')" " a client cannot fix a bare code";; esac
want purity-bad 0 "every stdout line is JSON — stdout carries protocol messages only"
want listen-count 0 "the HTTP bridge stays down: no listening socket for the whole session"
want exit-code 0 "EOF on stdin exits 0"

probe_summary "$PROBE_NAME"
