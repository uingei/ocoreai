# System 1 / Jev decisions — what the axis is, and what it would cost here

> Status: **research, nothing implemented, nothing run.** Written 10-20 because "Jev
> Compatibility" appears in the mission line and had **no definition anywhere in this repo**
> (`git grep -in jev -- Sources` = 0 hits, and no doc defined it either). The comparators do
> define it, in two shapes. Everything below marked *read* came from a file in a local clone at
> the cited path:line; nothing here was executed.
>
> <!-- claim:systemone_route_sites<=0 :: git grep -lE '/v1/(systemone|decisions)' -- Sources | wc -l -->
> <!-- claim:logprob_surface_files>=2 :: git grep -l "includeLogits" -- Sources | wc -l -->

## Shape A — vllm: `POST /v1/systemone`, diffusion-native

*read* `~/references/vllm-metal/docs/structured_decisions.md:3` — "Jev-like System 1 decisions
return yes/no probabilities, choices, and scores" — which points at upstream vllm
`examples/features/structured_diffusion/` (present in our vllm clone at HEAD `5285b9b864`:
`README.md` + `structured_server.py`). The API's own name for itself, *read* at
`examples/features/structured_diffusion/README.md:47`: "POST /v1/systemone implements the Jev
decision API."

- **Body** (`README.md:47-50`): `model`, `state` (the thing being judged, e.g. a ticket), and
  `questions` = a **map** of id → `{type, instructions, criteria}`. Schema options ride in the
  same body as extensions.
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

*read* `~/references/sglang/docs/docs/supported-models/decision_models.mdx:3,5`:

> "Answer typed choice, score, and yes or no questions with a probability for every option from a
> chat model, without generating text." … "It needs no special checkpoint: any generation model
> served with a Jinja chat template can answer, as long as the checks below pass for it."

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
  (`Libraries/MLXLLM/LLMModelFactory.swift:118-119`, shipped config `:527`, listed `:603`) whose
  header documents AR / block-diffusion / linear-self-speculation over one weight set
  (`Libraries/MLXLLM/Models/NemotronLabsDiffusion.swift:7-12`) — so Shape A has an upstream
  consumer path at mlx level, but no DiffusionGemma in mlx-swift-lm as of the pin.
- **Neither route exists here**: `/v1/systemone`, `/v1/decisions` = 0 sites in `Sources/` (claim
  marker above), and `make drift` reports all three HEAD axes at the baseline — so this is an
  **unclaimed axis**, not upstream drift we failed to follow.

## What the cheapest honest slice would need (owner decision — not started)

Shape B is cheaper than Shape A: no new checkpoint family, no canvas semantics, and it reuses the
logprob primitive we already ship honestly. Priced in five parts:

1. a published-logits seam on the MLX path — or ship B on the CoreAI route first and 501 with the
   remediation the completions face already uses;
2. questions-schema decode + **per-request single-token label validation** against our tokenizer
   (sglang's contract is the reference: refuse with 400 naming the reason, and expose
   `prompt_token_ids` so a caller can see where the answer position landed);
3. the answer-shape family (`noul` / `choice`+`confidence` / `score`+`legend`) in **one home**, the
   way `Models/ToolCallWire.swift` is the one home for what a tool turn asserts about itself;
4. disclosure: a per-model `decisions: ready|blocked|unsupported` + reason, measured, with the
   validated-list tier kept separate from the design claim (invariant 2 — the sglang page is the
   template for saying it honestly);
5. a probe for this surface (`run.sh` enumerates `scripts/probes/[0-9]*.sh`, so the next number self-registers) that either returns real probabilities for
   a ready model or refuses naming the missing prerequisite — **never a fabricated probability**. A
   decision API that returns made-up numbers is the worst failure mode this file can imagine: the
   whole point of the axis is a number a caller acts on.

## Not verified, stated rather than hidden

Nothing above was executed. Not read: sglang's full `/v1/decisions` request/response field list
beyond the intro and error rules, and vllm's `structured_server.py` internals (the example server
that adapts `/v1/completions` into `/v1/systemone` — worth reading before any implementation,
because it shows which parts of the contract live in the server vs the client). Not tested:
whether `nemotron_labs_diffusion` loads through our `MLXModelLoader` at all.
