# System 1 / Jev decisions — what the axis is, and what it would cost here

> Status: **Shape B's contract landed; scoring is still refused.** `POST /v1/decisions` is registered,
> validates a body against sglang's rules in one home (`Wire/DecisionsWire.swift`), and refuses every
> request that passed — a 501 naming the read that is missing (`Handlers/DecisionsHandler.swift`). Gates:
> `DecisionsContractTests` for the contract, probe 49 for the live pair of answers. Nothing scores yet: an
> answer is a label probability read at the answer position and only the CoreAI route publishes logits
> (§ What this repo already has), so the slice that could ship honestly was the contract plus the refusal,
> which is what shipped. Shape A (`POST /v1/systemone`) stays unregistered: a route row is a promise, since
> it renders onto `/v1/capabilities` and `/openapi.json`.
>
> The research below stands as written before any of that existed. Everything marked *read* came from a
> file in a local clone at the cited path:line; none of it was executed then, and the parts about our own
> tree that are still true are re-grepped by the markers here rather than re-asserted in prose. "Jev
> Compatibility" in the mission line had no definition anywhere in this repo until this file supplied one;
> the word now appears in `Sources/` only as this route's name for itself.
>
> <!-- claim:decisions_route_registered>=1 :: git grep -lE 'routes\.post\("/v1/decisions"\)' -- Sources | wc -l -->
> <!-- claim:systemone_route_registered<=0 :: git grep -lE 'routes\.(post|get)\("/v1/systemone"\)' -- Sources | wc -l -->
> <!-- claim:logprob_surface_files>=2 :: git grep -l "includeLogits" -- Sources | wc -l -->

## Shape A — vllm: `POST /v1/systemone`, diffusion-native

*read* `~/references/vllm-metal/docs/structured_decisions.md:3` — "Jev-like System 1 decisions
return yes/no probabilities, choices, and scores" — which points at upstream vllm
`examples/features/structured_diffusion/` (present in our vllm clone at HEAD `5285b9b864`:
`README.md` + `structured_server.py`). The API's own name for itself, *read* at
`examples/features/structured_diffusion/README.md:47`: "POST /v1/systemone implements the Jev
decision API."

- **Body** (`README.md:47-50`): `model`, `state` (the thing judged) and `questions` = a **map** of
  id → `{type, instructions, criteria}`; schema options ride in the same body.
- **Question types** (`README.md:43`): `noul` (yes/no), `choice` + `options`, `score` + ordered
  `levels`. Every label must be **a single token in the answer template**, which the server
  checks against the tokenizer when a request uses the schema.
- **Answers** (`README.md:48-50`): a `noul` probability; a `choice` with `probabilities` and
  `confidence`; a `score` with a 0-indexed `legend`.
- **Diffusion controls** (`README.md:10-13`): `diffusion_seed_canvas` (exactly `canvas_length`
  ids), `diffusion_pinned` (positions held at their seed value every denoise step, so a read past
  one step keeps its template), `diffusion_max_steps`, `diffusion_read_only` (emit the argmax
  canvas at the cap, end the request there, return temperature-1 logprobs at every position).
- **Staging between questions** (`README.md:52-54`): `depends_on` (later stage, those answers in
  the prompt), `ask_if` (asked only when a named question's answer is among listed ones, else
  null), `alone` (a read of its own).
- **Images** (`README.md:56-57`): `multipart/form-data` with the JSON in a part named `request`
  plus one file part per image, or an `images` array of data URLs.
- **`"think": N`** (`README.md:68-75`): up to N tokens in the model's thought channel before the
  read, with the chat template's thinking marker on, so the answer slots condition on it; all
  noise draws of one decision share the thought. `diagnostics.thought` returns the text, its
  token length, whether the model closed the channel itself, and generation time.
- **Server prerequisites**: `--diffusion-config '{"canvas_length": N}'` + `--max-logprobs 32`
  (+ `--enable-prefix-caching` in the example). vllm-metal's own note (`docs/structured_decisions.md:31-36`):
  per-request canvases narrower than the served canvas are unsupported on Metal with vLLM 0.31.0,
  and DiffusionGemma takes text input only.

## Shape B — sglang: `POST /v1/decisions`, autoregressive, no special checkpoint

*read* `~/references/sglang/docs/docs/supported-models/decision_models.mdx:3,5` — typed choice,
score and yes/no questions with "a probability for every option from a chat model, without
generating text", needing "no special checkpoint: any generation model served with a Jinja chat
template can answer, as long as the checks below pass for it".

- The probabilities are read from **next-token scores at the answer position**: no text generated,
  no output parsing (`:3`).
- Per-request validation (`:20`): answer labels must be single tokens at the answer position, and
  the answer must not start inside a reasoning block; a failure is a **400 naming the reason**.
  The server explicitly does *not* verify how the chat template renders the question or where the
  template would put an answer — callers are told to inspect `prompt_token_ids` (via
  `return_prompt_token_ids`) before trusting a new model.
- Positioning (`:7`): an SGLang extension under `/v1`, like `/v1/score` and `/v1/rerank` — not
  part of the OpenAI API, so it is called over HTTP, not through an OpenAI SDK method.
- Honesty shape worth copying: the "any chat model" claim sits above a **validated-on-two-models**
  table. Design capability and validated capability are two columns, exactly the tier split this
  repo publishes for vision/screen/video (AGENTS.md invariant 2).

## Shape C — ollama: `/v1/systemone` on an autoregressive local server (read 11-02, mirror `74686a75`)

The name of Shape A's route, shipped by the local server the category's users actually hit
(185 660 stars, api.github.com 11-02) — and it is **not** diffusion: it is Shape B's read on a
lane of its own. *read* (never run):

- **Registered**: `server/routes.go:2431` — `POST /v1/systemone`, behind the same cloud-passthrough
  middleware as the chat routes; `/v1/messages` at `:2449` and `/v1/responses` at `:2441` sit in the
  same block, so their compat trio and our compat trio now cover the same routes on a third stack.
- **Wire = Shape A's body, Shape B's read.** `api/types.go:604-622`: `model`, `state` (raw JSON),
  `questions` = **ordered** map id → `{type: noul|choice|score, instructions, criteria}`, `images`,
  `videos`, `keep_alive`. Answers (`:628-638`): ordered map id → raw JSON whose `type` field names
  its own fields — fixture `{"type":"noul","noul":0.9}` (`server/systemone_test.go:47`) — plus
  `usage{input_tokens,output_tokens}`; **no probabilities are published on the wire**.
- **The lane answers § *The cheapest honest slice* part 1's question.** Their scoring is an engine-internal
  request shape — `llm.ScoreRequest{Rows[{Question,Options}]}` in, `llm.ScoreResponse{Logits
  [][]float32}` out (`decision/pplx.go:22-30`) — consumed in the decision layer, **never surfaced
  on a chat route**. Position order is load-bearing: "the publisher's readout assigns answer codes
  by position, so sorting choices changes scores" (`pplx.go:16-17`). Malformed lane results (row
  count ≠ questions, NaN logits) are refused, not answered (`decision/systemone_test.go:162-164`).
- **400s on capability, not silence**: unknown runner → 400 (`server/systemone_test.go:256`); a
  video for a candidate model that cannot take one → 400 (`:260-261`).
- **What it proves and what it does not**: a local AR server can answer typed decisions with no
  diffusion checkpoint (their decision adapters live in `decision/` — `kev.go`, `pplx.go`,
  `clef_test.go`); it does **not** lift our owner call — our MLX route still publishes no logits,
  and this file's 501 stands until that seam exists. Borrowable verdicts, if the owner takes the
  lane: one scoring request shape per engine lane (not a chat-route bolt-on), ordered questions with
  the order asserted, and refusal-on-malformed-logits as the floor under every number.

## What this repo already has — read from our own tree *today*, not run

- **Logprobs exist, on one route only.** `Engine/EngineLogprobs.swift:60 collectLogits` and
  `Engine/LogProbabilities.swift` (ported copy-first from coreai-models; that file's header states
  it is CoreAI-gated because `LogitsScalarType` exists only in the CoreAI engine tree). On the
  macOS 26 delivery platform `POST /v1/completions` with `logprobs` therefore accepts the field
  for parity and answers **501 `AppError.logitsUnsupported`** (`Handlers/CompletionsHandler.swift:102-107`)
  — honest degradation already in place, and that missing primitive is precisely what Shape B
  reads.
- **The MLX path computes logits but publishes none.** `Engine/EngineInference.swift:914` and
  `:997` call `generate(includeLogits: true)` in-tree for `ConstrainedDecodingStrategy`. So
  Shape B on MLX needs a *published-logits seam*, not a new algorithm.
- **No diffusion LM arch in our registry.** The only "Diffusion" under `Sources/` is
  `Video/CoreAIDiffusionModelFunction.swift` (video generation — unrelated axis). Upstream
  mlx-swift-lm at our pin registers `nemotron_labs_diffusion`
  (`Libraries/MLXLLM/LLMModelFactory.swift:119-119`, shipped config `:527`, listed `:603`) whose
  header documents AR / block-diffusion / linear-self-speculation over one weight set
  (`Libraries/MLXLLM/Models/NemotronLabsDiffusion.swift:7-12`) — so Shape A has an upstream
  consumer path at mlx level, but no DiffusionGemma in mlx-swift-lm as of the pin.
- **Shape A stays unregistered here; Shape B is registered and refuses.** `/v1/systemone` = 0
  registrations in `Sources/` (marker above). `/v1/decisions` is registered (marker above) but answers a
  501 on every body that validates, for the reason in the next-but-one bullet. `make drift` reports all
  three HEAD axes at the baseline, so the *capability* is still an **unclaimed axis**, not upstream drift
  we failed to follow — what landed is the contract, not the measurement.

## The cheapest honest slice, part by part — what landed and what is still owner-call

Shape B is cheaper than Shape A: no new checkpoint family, no canvas semantics, and it reuses the
logprob primitive we already ship honestly. Priced in five parts; each part now says which way it went:

1. **Landed as the 501 half, not the seam half.** No published-logits seam was invented for this; the
   route answers 501 naming the missing read, the way the `logprobs` face on
   `POST /v1/completions` already does. The seam (MLX publishes logits, or scoring runs on the CoreAI
   route first) is still the owner-call that gates every probability this API will ever return.
2. **Decode landed; the tokenizer check did not, deliberately.** The questions schema is validated in
   one home (`Wire/DecisionsWire.swift`, `DecisionsContractTests`). The *per-request single-token label
   validation* needs the served tokenizer at the answer position, so it cannot be measured before a
   checkpoint is loaded to score with — and while every validated request is refused, a multi-token
   label cannot answer anything. It lands with the seam, and it must not be skipped then: it is the
   check that stops a label scored as two tokens from being read as one. `return_prompt_token_ids` is
   accepted on the wire and means nothing yet, which the probe pins.
3. **Deliberately absent.** No answer-shape DTO was written: `noul` / `choice`+`confidence` /
   `score`+`legend` would be a type nothing in the tree can fill, and the empty version of it is how a
   probability gets invented. It goes in one home when there is a producer.
4. **Not landed.** A per-model `decisions: ready|blocked|unsupported` row is a measurement per
   checkpoint; with no scoring there is nothing to measure. Today the honest disclosure is the route
   note itself — it renders onto `/v1/capabilities` and `/openapi.json` saying this build answers 501.
5. **Landed as probe 49** (`scripts/probes/49-decisions-contract-refusal.sh`): a malformed body must
   400 with every reason at once, a valid body must 501 naming the prerequisite, and neither response
   may carry a probability. A decision API that returns made-up numbers is the worst failure mode this
   file can imagine: the whole point of the axis is a number a caller acts on.

## Not verified, stated rather than hidden

What is executed now is only our own side: the decoder's rules run in `DecisionsContractTests`, and the
live pair of answers runs in probe 49. What was never executed is the axis's *reference*: every sglang
rule the wire adopts was read in `protocol.py`/`http_server.py`, never sent to a running sglang, so a
field listed here as the reference's is a read until some request says otherwise. Still not read:
sglang's full response field list beyond the intro and error rules (read it before writing answer DTOs,
not after), and vllm's `structured_server.py` internals (the example server that adapts
`/v1/completions` into `/v1/systemone` — it shows which parts of the contract live in the server vs the
client). Not tested: whether `nemotron_labs_diffusion` loads through our `MLXModelLoader` at all.
