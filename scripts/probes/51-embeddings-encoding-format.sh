#!/usr/bin/env bash
# 51-embeddings-encoding-format.sh — does /v1/embeddings answer the fields it accepts?
#
# Why this file exists: measured 11-05 against the cached canonical embedder on a live server,
# the route parsed only `model`, `input` and `user`. A caller that asked `"encoding_format":
# "base64"` was answered with float arrays, and one that asked `"dimensions": 256` was answered
# with the full 1024-dim vector — two declared words the wire accepted and silently
# reinterpreted (AGENTS.md invariant 2: the surface never claims more than the engine delivered).
# Both faces are refused by name or honored now (`embeddingsWireEncoding`,
# `Router/ChatCompletionsRouter.swift`); this file is the live half of that claim, because the
# unit gate cannot see the envelope the caller actually reads.
#
# Which field carries the base64 string was decided from the spec, not from taste: OpenAI's
# `Embedding.embedding` is `anyOf: [array<float>, string(base64)]` — "as a base64-encoded string
# when `encoding_format` is `base64`" (`openai/openai-openapi openapi.yaml` ~:51627, fetched
# through api.github.com 11-06; `b64_json` appears in that file only on images). Every comparator
# in the mirrors that implements the parameter puts the string under `embedding`: ollama
# `openai/openai.go:533-549` (LE pack, `floatsToBase64`), vllm `pooling/embed/protocol.py:206-209`
# with its own example decoding `data["embedding"]` (`embedding_requests_base64_online.py:56`),
# sglang `EmbeddingObject` + `serving_embedding.py:270-279`, Rapid-MLX `routes/embeddings.py:323-336`.
# The two that refuse an unknown format do it by naming the value (ollama
# `middleware/openai.go:409-410`, sglang `serving_embedding.py:46-49`) — which is the shape here.
#
# Legs:
#   1) control — a token-id `input` is refused 400 (one of the three refusal faces measured
#      11-05), so every 400 below is about its own field and not about a route that never
#      worked. Weight-free.
#   2) the refusal faces: an unknown `encoding_format` names itself, the bad value and both
#      accepted words; a `dimensions` this embedder cannot answer names the value, the native
#      width and the way out. Both are decided before the embedder is touched, so they judge
#      on a runner with no weights and no Metal.
#   3) the shape pair — ONLY when the embedder's weights are cached, and it says so when they
#      are not (the checkpoint tier has no CI seat; `docs/agent/open-items.md`): the same two
#      texts through `float` and through `base64` must decode to the SAME little-endian float32
#      bytes, 1024 per vector (`usage` agreeing too). This is where §2's promise about 1024 is
#      measured rather than asserted.
#   4) floor — each leg counts its own subjects; a leg that produced no verdict is a failure,
#      never a smaller pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="embeddings-encoding-format"

# The scripted engine boots a server with no weights, no Metal and no download; the embedder is
# never reached, because every arm in §1-§2 is answered at the request boundary.
SCRIPT_FILE="$(mktemp -t ocoreai-embeddings-script-XXXXXX).json"
probe_atexit 'rm -f "$SCRIPT_FILE"'
printf '%s\n' '{"segments": ["not reached"], "finishReason": "eos", "promptTokens": 3, "generatedTokens": 1}' \
  > "$SCRIPT_FILE"
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"

# Where §3's python verdict travels (see §3's note on why it is a file and not a substitution).
VERDICT_FILE="$(mktemp -t ocoreai-embeddings-verdict-XXXXXX)"
probe_atexit 'rm -f "$VERDICT_FILE"'

# The canonical embedder's hub cache — the same path `EmbeddingService.hubRepoDir` resolves
# (MLXBridge.swift), so this probe and the service agree about what "cached" means.
EMBED_CACHE="$HOME/.cache/huggingface/hub/models--mlx-community--LFM2.5-Embedding-350M-4bit"

probe_boot

CTRL_PASSED=0
REFUSALS_PASSED=0
SHAPES_PASSED=0
SHAPES_RAN=0

# ── 1) control ─────────────────────────────────────────────────────────────────────────
probe_section "1) control — the route refuses a wrong-typed input, so §2's 400s mean their own field"
probe_api POST /v1/embeddings '{"model":"x","input":[1,2,3]}'
if [ "$PROBE_STATUS" = "400" ]; then
  case "$PROBE_BODY" in
    *input*)
      probe_ok "token-id input → 400 naming 'input' ($(printf '%.90s' "$PROBE_BODY")…)"
      CTRL_PASSED=$(( CTRL_PASSED + 1 ))
      ;;
    *) probe_fail "token-id input → 400 but the body names nothing: $PROBE_BODY" ;;
  esac
else
  probe_fail "token-id input → HTTP $PROBE_STATUS, expected 400 (route or gate is wrong, so §2 proves nothing)"
fi

# ── 2) refusal faces (weight-free: decided before the embedder is touched) ─────────────
probe_section "2) a declared field the embedder cannot honor is refused by name, not reinterpreted"

# One arm: expect 400 and every listed substring present in the refusal body.
refusal() {
  local label="$1" body="$2"; shift 2
  probe_api POST /v1/embeddings "$body"
  if [ "$PROBE_STATUS" != "400" ]; then
    probe_fail "$label → HTTP $PROBE_STATUS, expected 400 — body: $(printf '%.140s' "$PROBE_BODY")"
    return
  fi
  local missing=""
  for want in "$@"; do
    case "$PROBE_BODY" in
      *"$want"*) ;;
      *) missing="$missing '$want'" ;;
    esac
  done
  if [ -n "$missing" ]; then
    probe_fail "$label → 400 but the refusal omits:$missing — body: $(printf '%.200s' "$PROBE_BODY")"
    return
  fi
  probe_ok "$label → 400 naming the field, the value, and the way out"
  REFUSALS_PASSED=$(( REFUSALS_PASSED + 1 ))
}

# `dimensions` is refused because the embedder cannot truncate: the spec supports the field only
# "on text-embedding-3 and later models", and nothing measured here says this embedder's cosine
# survives cutting the post-layer-norm vector (its norm 1.000183 was measured whole, 11-05).
refusal "unknown encoding_format 'msgpack'" \
  '{"model":"x","input":"hi","encoding_format":"msgpack"}' \
  "encoding_format" "msgpack" "'float'" "'base64'"
refusal "dimensions=256" \
  '{"model":"x","input":"hi","dimensions":256}' \
  "dimensions=256" "1024" "Omit 'dimensions'"
refusal "dimensions=0 (spec minimum: 1)" \
  '{"model":"x","input":"hi","dimensions":0}' \
  "dimensions" ">= 1"

# ── 3) the shape pair, with weights ────────────────────────────────────────────────────
probe_section "3) float and base64 are the same vectors (needs the embedder's cached weights)"
if [ ! -d "$EMBED_CACHE/snapshots" ]; then
  probe_note "§3 skipped — no cached embedder at $EMBED_CACHE (the checkpoint tier has no CI seat;" \
    " §1-§2 are the runner's verdicts, §3 runs wherever the weights live)"
else
  SHAPES_RAN=1
  TEXTS='["hello world","a second text about vectors"]'
  probe_api POST /v1/embeddings "{\"model\":\"x\",\"input\":$TEXTS}"
  FLOAT_STATUS="$PROBE_STATUS"; FLOAT_BODY="$PROBE_BODY"
  probe_api POST /v1/embeddings "{\"model\":\"x\",\"input\":$TEXTS,\"encoding_format\":\"base64\"}"
  B64_STATUS="$PROBE_STATUS"; B64_BODY="$PROBE_BODY"
  probe_api POST /v1/embeddings "{\"model\":\"x\",\"input\":$TEXTS,\"dimensions\":1024}"
  DIM_STATUS="$PROBE_STATUS"; DIM_BODY="$PROBE_BODY"

  # One python verdict over the three bodies: the same float32 values in two encodings is the
  # contract, and the width it pins is the 1024 §2 refuses against. The heredoc feeds python
  # directly and the verdict travels through a file — a `<<PY` nested inside `"$( )"` gets
  # re-lexed against the outer quotes, where one apostrophe in a comment breaks the whole file.
  FLOAT_STATUS="$FLOAT_STATUS" FLOAT_BODY="$FLOAT_BODY" \
    B64_STATUS="$B64_STATUS" B64_BODY="$B64_BODY" DIM_STATUS="$DIM_STATUS" DIM_BODY="$DIM_BODY" \
    python3 - > "$VERDICT_FILE" <<'PY'
import base64, json, os, struct


def parse(raw):
    try:
        return json.loads(raw)
    except Exception:
        return None

f_stat, b_stat, d_stat = (os.environ[k] for k in ("FLOAT_STATUS", "B64_STATUS", "DIM_STATUS"))
f_body, b_body, d_body = (parse(os.environ[k + "_BODY"]) for k in ("FLOAT", "B64", "DIM"))
if not (f_stat == b_stat == d_stat == "200"):
    print(f"statuses are {f_stat}/{b_stat}/{d_stat}, expected 200/200/200 — the embedder did not answer")
    raise SystemExit
for name, body in (("float", f_body), ("base64", b_body), ("dimensions", d_body)):
    if not body or not body.get("data"):
        print(f"{name} body carries no data[]: {str(body)[:120]}")
        raise SystemExit
floats_arm = [d["embedding"] for d in f_body["data"]]
if not all(isinstance(v, list) for v in floats_arm):
    print(f"float arm is not arrays: {str(floats_arm[0])[:80]}")
    raise SystemExit
strings_arm = [d["embedding"] for d in b_body["data"]]
if not all(isinstance(v, str) for v in strings_arm):
    print(f"base64 arm is not strings: {str(strings_arm[0])[:80]}")
    raise SystemExit
packed = [base64.b64decode(v) for v in strings_arm]
if any(len(p) % 4 for p in packed):
    print(f"base64 payload is not a whole number of float32: {[len(p) for p in packed]}")
    raise SystemExit
widths = {len(f) for f in floats_arm} | {len(p) // 4 for p in packed}
if widths != {1024}:
    print(f"vector widths are {widths}, expected exactly {1024}")
    raise SystemExit
# The comparison requantizes the float arm to float32 first: a JSON decimal only has to
# round-trip to the same float32 (Swift prints the shortest such decimal), so comparing it
# in float64 against the exact float32 bits of the base64 arm differs by ~half an ULP per
# value —
# measured 2.5e-9 on the first run, which is ULP-sized, not a defect. Same float32 bits is
# the contract: two encodings, one vector.
worst = 0.0
worst_at = None
for row, (f, p) in enumerate(zip(floats_arm, packed)):
    decoded = struct.unpack(f"<{len(p) // 4}f", p)
    requantized = struct.unpack(f"<{len(f)}f", struct.pack(f"<{len(f)}f", *f))
    for k, (a, b) in enumerate(zip(requantized, decoded)):
        if a != b:
            worst = max(worst, abs(a - b))
            worst_at = f"row {row} component {k}: {a!r} vs {b!r}"
if worst_at is not None:
    print(f"the two encodings carry different float32 values: {worst_at} (max diff {worst})")
    raise SystemExit
u_f, u_b, u_d = (b["usage"] for b in (f_body, b_body, d_body))
if not (u_f == u_b == u_d) or u_f["prompt_tokens"] != u_f["total_tokens"]:
    print(f"usage disagrees across the arms or within one: {u_f} {u_b} {u_d}")
    raise SystemExit
if {d["index"] for d in b_body["data"]} != set(range(len(packed))):
    print(f"base64 arm indexes are wrong: {[d['index'] for d in b_body['data']]}")
    raise SystemExit
tokens = u_f["prompt_tokens"]
print(f"OK {len(packed)} vectors x 1024 dim; both encodings carry the same float32 bits; usage {tokens} tokens; dimensions=1024 accepted")
PY
  verdict="$(cat "$VERDICT_FILE")"
  case "$verdict" in
    OK\ *)
      probe_ok "$verdict"
      SHAPES_PASSED=3
      ;;
    *) probe_fail "$verdict" ;;
  esac
fi

# ── 4) floor ───────────────────────────────────────────────────────────────────────────
probe_section "4) floor — every leg counted its own subjects"
for row in "control:1:$CTRL_PASSED" "refusals:3:$REFUSALS_PASSED" "$([ "$SHAPES_RAN" = 1 ] && printf 'shapes:3:%s' "$SHAPES_PASSED" || printf 'shapes:skipped')"; do
  name="${row%%:*}"; rest="${row#*:}"
  if [ "$rest" = "skipped" ]; then
    probe_note "$name leg skipped with its reason printed above (§3) — not counted, not passed"
    continue
  fi
  want="${rest%%:*}"; got="${rest##*:}"
  if [ "${got:-0}" -eq "$want" ]; then
    probe_ok "$name leg ran all $want of its subjects"
  else
    probe_fail "$name leg judged $got of $want subjects — the rest produced no verdict, which is a" \
      " vacuous pass, not a smaller one"
  fi
done

probe_summary "$PROBE_NAME"
