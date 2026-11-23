#!/usr/bin/env bash
# 57-tool-result-token-accounting.sh. Does a tool result reach the prompt at all?
#
# ### Why (invariant 2 at its deepest: the model must see the work it asked for)
# A coding agent's tool loop lives or dies on one fact: the result the client posts
# back must occupy the next prompt. On the checkpoint the product ships as default
# (`gemma-4-e2b-it-4bit`) it does not. Measured live twice, once per side of this
# row's life:
#   11-09  a ~1 550-token tool result moved prompt_tokens 690 → 693 (both faces).
#   11-12  weights ARE on this host (`~/.ocoreai/models/mlx-community/gemma-4-e2b-it-4bit`,
#          3.3 GB, complete. The earlier "absent here" claim was stale) and the number
#          stands: baseline 872 → 877 with a ~2 490-token result. delta = 5.
# The control arm proves the pipeline is not broken generally: the SAME text block
# posted as user-role content bills +2 283 to +2 488 tokens. Only the tool role
# reads as noise. The name-threading that landed 11-12 (`toolResultNamesByID`,
# `MTPMessagePair`) labels the metadata correctly and moves none of this. The loss
# is content, and it is template-side.
#
# ### Where it is lost (read at the checkpoint's own chat_template.jinja, 11-12)
# The gemma4 template's main loop SKIPS `role:"tool"` messages (`:217`). They render
# only through the forward-scan that an assistant message carrying `tool_calls` runs
# over its following tool messages (`:271`-`:315`, calling `format_tool_response_block`
# per result). A delta of 5 therefore says the assistant message reached the template
# WITHOUT its `tool_calls`, or the scan found none. Convicted 11-16 by discriminator:
# the same payload WITH `tools[]` declared billed the full block (the ChatSession lane
# renders intact), while an assistant carrying `tool_calls` on the no-tools route
# billed ZERO. The std-reasoning lane snapshots `(role, content)` pairs and rebuilds
# `Chat.Message(role:content:)`, erasing `tool_calls` and the result pairing before the
# template ever sees them.
#
# ### What is measured (six arms)
#   1. CONTROL: a ~2 500-token block as user-role content must bill >= 400 extra
#      prompt tokens. This guards the instrument itself; if it reddens, nothing
#      downstream means anything.
#   2-4. The same block as a tool result (OpenAI face, ladder-resolved name; OpenAI
#      face, caller-supplied name; Anthropic face, `tool_result` block): billed delta
#      >= 400. These ran XFAIL until the 11-16 fix (the std-reasoning lane's
#      `(role, content)` snapshot dropped `tool_calls`; the gate now refuses that lane
#      for tool-metadata history) and are promoted to real checks here.
#   5. Cross-conversation KV: after a tool turn returns its ChatSession to the pool, a
#      DIFFERENT conversation sharing the leading user message (the `anon:` key) must
#      not inherit that session's KV. Upstream ChatSession appends rather than
#      reconciles, so an unprovable turn must not be pooled at all. Measured 11-16: the
#      forked resend billed 3 092 tokens (the previous conversation's result block plus
#      its own 736) before the release-site rule landed.
#   6. Malformed tool history is refused with a named 400, and legal shapes stay 200.
#      Measured 11-16 before the boundary refusal: an orphan result answered 200/686
#      (its content silently gone) and a mismatched id answered 200/1033 (labelled
#      `unknown`). The three refusals and the two legal shapes follow sglang's shipped
#      walker (`serving_chat.py:300-330`). Including its leniency that a run left
#      open at the END is what the completion is asked to answer.
#
# Needs a real Metal device AND the default checkpoint's weights (this host holds
# them at ~/.ocoreai/models; a runner without them takes the SKIP branch below).
# Run: bash scripts/probes/run.sh 57

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"

# ── boot ───────────────────────────────────────────────────────────────────────
probe_boot

MODEL="$(curl -sf --max-time 10 "$PROBE_BASE/v1/models" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "")')"
if [ -z "$MODEL" ]; then
  probe_note "SKIP — no checkpoint loadable on this runner (no weights); tool-token accounting is unmeasurable here"
  exit 0
fi

# ── payloads ───────────────────────────────────────────────────────────────────
export RESULT_BLOCK="$(python3 -c 'print("\n".join(f"row {i}: sector {i} checksum {(i*2654435761)%4294967296:08x}" for i in range(1,121)))')"
export PREAMBLE="You are a coding agent. Answer briefly with the facts found. You are a coding agent. Answer briefly with the facts found. You are a coding agent. Answer briefly with the facts found."
export MODEL

prompt_tokens() {  # $1 = path, $2 = json body file — one POST, either usage schema
  curl -sf --max-time 300 -X POST "$PROBE_BASE$1" -H 'Content-Type: application/json' \
    --data @"$2" | python3 -c 'import json,sys; u=json.load(sys.stdin)["usage"]; print(u.get("prompt_tokens", u.get("input_tokens")))'
}

export TMPD="$(mktemp -d)"
probe_atexit "rm -rf '$TMPD'"

# Body builders: one per (face, mode). `base` = same preamble, no tool exchange.
oa_body() {  # $1 = outfile, $2 = base|ladder|named
  python3 - "$1" "$2" <<'PY'
import json, os, sys
out, mode = sys.argv[1], sys.argv[2]
res = os.environ["RESULT_BLOCK"]; pre = os.environ["PREAMBLE"]; model = os.environ["MODEL"]
if mode == "base":
    msgs = [{"role": "user", "content": pre}]
else:
    call = {"id": "c1", "type": "function",
            "function": {"name": "read_file", "arguments": "{\"path\":\"a.txt\"}"}}
    tool = {"role": "tool", "content": res, "tool_call_id": "c1"}
    if mode == "named":
        tool["name"] = "read_file"
    msgs = [{"role": "user", "content": pre},
            {"role": "assistant", "content": "", "tool_calls": [call]}, tool]
json.dump({"model": model, "messages": msgs, "max_tokens": 1, "temperature": 0}, open(out, "w"))
PY
}
anth_body() {  # $1 = outfile, $2 = base|tool
  python3 - "$1" "$2" <<'PY'
import json, os, sys
out, mode = sys.argv[1], sys.argv[2]
res = os.environ["RESULT_BLOCK"]; pre = os.environ["PREAMBLE"]; model = os.environ["MODEL"]
if mode == "base":
    msgs = [{"role": "user", "content": pre}]
else:
    msgs = [{"role": "user", "content": pre},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "c1", "name": "read_file", "input": {"path": "a.txt"}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "c1", "content": res}]}]
json.dump({"model": model, "messages": msgs, "max_tokens": 1}, open(out, "w"))
PY
}

probe_section "the tool-result token delta on the shipped default checkpoint ($MODEL)"

# Arm 1. Control: the same text as user content must bill (instrument sanity).
python3 - <<'PY'
import json, os
json.dump({"model": os.environ["MODEL"],
           "messages": [{"role": "user", "content": "hi"}],
           "max_tokens": 1, "temperature": 0}, open(os.environ["TMPD"] + "/ctrl_hi.json", "w"))
json.dump({"model": os.environ["MODEL"],
           "messages": [{"role": "user", "content": os.environ["RESULT_BLOCK"]}],
           "max_tokens": 1, "temperature": 0}, open(os.environ["TMPD"] + "/ctrl_res.json", "w"))
PY
base_u=$(prompt_tokens /v1/chat/completions "$TMPD/ctrl_hi.json")
with_u=$(prompt_tokens /v1/chat/completions "$TMPD/ctrl_res.json")
ctrl_delta=$(( with_u - base_u ))
if [ "$ctrl_delta" -ge 400 ]; then
  probe_ok "control: user-role content bills its length (delta $ctrl_delta) — the counter works"
else
  probe_fail "control: user-role content billed only $ctrl_delta — the instrument itself is blind, the tool arms prove nothing"
fi

# Arms 2-4. Tool-role content on each face: counted known-open while the loss stands.
oa_body "$TMPD/base_oai.json" base
anth_body "$TMPD/base_anth.json" base

check_tool_arm() {  # $1 = label, $2 = face path, $3 = body, $4 = base body
  local w b delta
  b=$(prompt_tokens "$2" "$4")
  w=$(prompt_tokens "$2" "$3")
  delta=$(( w - b ))
  if [ "$delta" -ge 400 ]; then
    probe_ok "$1: ~2 500-token tool result billed $delta tokens — the prompt carries what the model asked for"
  else
    probe_fail "$1: ~2 500-token tool result billed only $delta tokens — REGRESSION: the tool exchange never reaches the prompt (check the reasoning-lane gate for tool-metadata history)"
  fi
}

oa_body "$TMPD/ladder.json" ladder
oa_body "$TMPD/named.json" named
anth_body "$TMPD/tool.json" tool
check_tool_arm "openai-face-ladder-name" /v1/chat/completions "$TMPD/ladder.json" "$TMPD/base_oai.json"
check_tool_arm "openai-face-caller-name" /v1/chat/completions "$TMPD/named.json" "$TMPD/base_oai.json"
check_tool_arm "anthropic-face-tool-result" /v1/messages "$TMPD/tool.json" "$TMPD/base_anth.json"

# Arm 5. Cross-conversation KV. Every arm above shares the same leading user message,
# so they share the pool's `anon:` key. A tool turn must NOT leave its filled ChatSession
# in the pool behind an empty ledger: the next conversation on that key would vacuously
# "hit" it, and upstream ChatSession APPENDS the new transcript after the old
# conversation. The fork below would bill the previous arm's result block. A forked
# resend therefore has to bill about its own length (< 200 over base), never thousands.
python3 - <<'PY'
import json, os
pre = os.environ["PREAMBLE"]; model = os.environ["MODEL"]
msgs = [{"role": "user", "content": pre},
        {"role": "assistant", "content": "A different conversation entirely, with nothing to add."}]
json.dump({"model": model, "messages": msgs, "max_tokens": 1, "temperature": 0},
          open(os.environ["TMPD"] + "/forked.json", "w"))
PY
w=$(prompt_tokens /v1/chat/completions "$TMPD/forked.json")
b=$(prompt_tokens /v1/chat/completions "$TMPD/base_oai.json")
delta=$(( w - b ))
if [ "$delta" -lt 200 ]; then
  probe_ok "cross-conversation KV: forked resend billed $delta over base — no foreign tool context inherited"
else
  probe_fail "cross-conversation KV: forked resend billed $delta over base — it inherited a previous conversation's cached KV (an unprovable turn was pooled with an empty ledger)"
fi

# Arm 6. Malformed tool history refused by name, legal shapes kept. Before the
# boundary refusal this was a 200 over a silently dropped or `unknown`-labelled result
# (measured 11-16: orphan 200/686, mismatch 200/1033). The refused/legal split is
# sglang's walker's own shape, checked on both faces.
python3 - <<'PY'
import json, os
res = os.environ["RESULT_BLOCK"]; pre = os.environ["PREAMBLE"]; model = os.environ["MODEL"]
call = {"id": "c1", "type": "function",
        "function": {"name": "read_file", "arguments": "{\"path\":\"a.txt\"}"}}
def w(name, msgs):
    json.dump({"model": model, "messages": msgs, "max_tokens": 1, "temperature": 0},
              open(os.environ["TMPD"] + "/" + name, "w"))
def anth(name, msgs):
    json.dump({"model": model, "messages": msgs, "max_tokens": 1},
              open(os.environ["TMPD"] + "/" + name, "w"))
w("bad_orphan.json", [{"role": "user", "content": pre},
                      {"role": "tool", "content": res, "tool_call_id": "c1"}])
w("bad_mismatch.json", [{"role": "user", "content": pre},
                        {"role": "assistant", "content": "", "tool_calls": [call]},
                        {"role": "tool", "content": res, "tool_call_id": "ghost"}])
w("bad_unanswered.json", [{"role": "user", "content": pre},
                          {"role": "assistant", "content": "", "tool_calls": [call]},
                          {"role": "user", "content": "and now?"}])
w("ok_trailing.json", [{"role": "user", "content": pre},
                       {"role": "assistant", "content": "", "tool_calls": [call]}])
anth("bad_anth_orphan.json",
     [{"role": "user", "content": pre},
      {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "ghost",
                                    "content": res}]}])
anth("ok_anth_trailing.json",
     [{"role": "user", "content": pre},
      {"role": "assistant", "content": [{"type": "tool_use", "id": "c1", "name": "read_file",
                                         "input": {"path": "a.txt"}}]}])
PY

post_code() {  # $1 path, $2 body → HTTP status; body left in $TMPD/resp.json
  curl -s --max-time 300 -o "$TMPD/resp.json" -w '%{http_code}' -X POST "$PROBE_BASE$1" \
    -H 'Content-Type: application/json' --data @"$2"
}
check_refused() {  # $1 label, $2 path, $3 body
  local code; code=$(post_code "$2" "$3")
  if [ "$code" = "400" ] && grep -qiE 'tool_call_id|tool_result|tool_use' "$TMPD/resp.json"; then
    probe_ok "$1: malformed tool history refused with a named 400"
  else
    probe_fail "$1: got HTTP $(head -c 160 "$TMPD/resp.json") — malformed tool history must be a named 400, not a 200 over content the prompt dropped"
  fi
}
check_accepted() {  # $1 label, $2 path, $3 body — sglang-legal shapes stay legal
  local code; code=$(post_code "$2" "$3")
  if [ "$code" = "200" ]; then
    probe_ok "$1: sglang-legal shape accepted at 200"
  else
    probe_fail "$1: got HTTP $(head -c 160 "$TMPD/resp.json") — a legal history was refused"
  fi
}
check_refused "openai-orphan" /v1/chat/completions "$TMPD/bad_orphan.json"
check_refused "openai-mismatch" /v1/chat/completions "$TMPD/bad_mismatch.json"
check_refused "openai-mid-unanswered" /v1/chat/completions "$TMPD/bad_unanswered.json"
check_refused "anthropic-orphan" /v1/messages "$TMPD/bad_anth_orphan.json"
check_accepted "openai-trailing-call" /v1/chat/completions "$TMPD/ok_trailing.json"
check_accepted "anthropic-trailing-use" /v1/messages "$TMPD/ok_anth_trailing.json"

probe_summary "57-tool-result-token-accounting"
