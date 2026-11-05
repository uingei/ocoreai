# Who stood alone, who copied whom — the field's innovations, counted by diffusion

Long form beside `comparator-consensus.md` (**does the field agree on Y**) and `comparator-evolution.md`
(**where is its effort going now**). This file answers the fourth of them — **innovation** — and neither of
those two can: **what does a tree do that nobody else does, and did it spread.** Agreement and effort both count
trees; an innovation is a mechanism that starts in one tree and either dies there or becomes the consensus
row. A field-wide table cannot see that shape at all, which is why it needs its own instrument and its own
denominators.

> **Re-derive:** `bash scripts/comparator-consensus.sh` prints the two blocks this file reads — **DIFFUSION**
> (every axis classified by its share of its own segment, singleton → consensus, plus the `ours-alone` and
> `segment-majority-we-score-zero-on` lines) and **SEGMENT-AUDIT** (serving trees on disk the declared
> `serve` segment omits). Arrival dates come from the one-liner in § How an arrival is datable. Premise,
> because it decides every number: **this box's mirrors at their 11-04 HEADs**. No runner has
> `~/references`, so none of this is a gate; a cross-tree count is a direction input and a printed count
> carries no verdict (§ *Working here*).

## How an arrival is datable here, and how it is not

The honest limit first, because the seductive error in a file about innovations is claiming primacy from a
corpus of 29 mirrors.

- **A mirror cannot establish that a tree was first.** It can establish two weaker, useful things: that a
  mechanism is **solitary right now** (the DIFFUSION block: exactly one in-segment tree scores), and that a
  tree **had a given file by a given date**. Solitariness is not leadership and not error — nothing in this
  corpus has been exposed to the mechanism, which is a fact about the field, not a verdict about us.
- **The arrival probe is one file per call:**
  `git -C ~/references/$T log --diff-filter=A --format=%cs -- $F | tail -1`.
  Two forms of the same command print **nothing** for files whose dates the form above returns — I measured
  both today: adding `--full-history`, and passing more than one pathspec with `--diff-filter=A` (6 paths →
  empty output, exit 0, while 2 paths printed a date). An empty date is exactly the kind of nothing that
  reads as absence, so the working form is pinned here rather than re-typed from habit.
- **Where a tree dates its own decisions, the date is theirs.** `deepseek-harness` keeps
  `.agents/notes/archived/feature/2026-06-14-acp-agent-client-protocol.i18n.yaml` — a dated, *bilingual*
  feature note per mechanism, archived rather than deleted. That is a third date source, better than ours
  where it exists, and it is itself a signature mechanism (§ The table).
- Nothing in this file says "first in the industry". Where two trees hold a mechanism, the pair of arrival
  dates is the whole claim; where one holds it, the claim is "one of 29 mirrors".

## The diffusion ladder — what the block printed today

Share of each axis's own declared segment, ascending; the class is the block's, not prose.

| Class | Axes (n/segment) | Read |
|---|---|---|
| RARE | generates docs from source 2/24 · store route 2/24 | one-off machinery; nobody has died without it |
| MINORITY | committed HTTP contract 2/12 · published client package 2/12 · OS confinement of the child 6/14 · **the host's own devices behind a route 3/12** | a bet, per tree, with named reasons |
| MAJORITY | **speaks ACP 8/14** · typed install command 16/24 · artefact route 17/24 · notices 17/24 · SKILL.md 11/14 · digest provenance 19/24 · evals tree 19/24 | spreading, and this is where a gap starts to cost |
| NEAR-CONSENSUS | deferred/filtered tools 12/14 · screen capture 12/14 · any install route 21/24 · auto-update 21/24 · empty-suite refusal 21/24 · cancellation 22/24 · **wires a harness to itself 11/12** · live probes 23/24 | table stakes |
| CONSENSUS (11 axes) | MCP 14/14 · reads a rules file 14/14 · names `AGENTS.md` 14/14 · KV/prefix reuse 12/12 · `reasoning_effort` 12/12 · download verification 12/12 · rewind/fork/compaction 14/14 · spec decode/MTP 12/12 · turn/stall bound 14/14 · subagents 14/14 · tool/hook events 14/14 | spending here buys a claim, not a user |

Three lines of that output are the calibration, and one of them is about us in the least comfortable way:

- **`ours-alone … — none; every practice we hold is held by others —`.** On all 32 measured axes there is no
  mechanism that we hold and the segment lacks. Whatever makes ocoreai different is a *combination* (two
  engines on one Apple-silicon box, vision+voice+code in one binary, an honesty gate on each claim), and no
  axis in this corpus measures a combination. Consequence: the differentiator has to be legible on a surface
  a stranger or a harness reads — which is § Adoption's problem restated by an instrument rather than by me.
  **One axis qualifies the line without breaking it:** the 32nd, added today, scores 3/12 and only one of its three
  holders owns a live input device — § The wire that points the box at the world.
- **The zeros at MAJORITY-and-above: typed install 16/24, ACP 8/14, harness-wiring 11/12.** Two of those three
  were already direction items; the third is new to this corpus today and is § The protocol that spread.
- **Confinement was the only MINORITY mechanism with a user-safety payload; the device route is the second** (6/14
  for confinement, and per § *Where the field confines a child* it tracks whose code the child runs; 3/12 for a route
  that points the host's screen or camera at a caller, 1/12 for a live input, § The wire that points the box at the
  world — and that 1/12 is **ours**, which makes the payload ours too). Everything else at MINORITY is a business bet.

**The denominator this cut had been getting wrong.** `serve` was hand-typed at 7 members while five serving
trees sat unlisted on the same disk (`Rapid-MLX` `rapid_mlx/routes/chat.py:2` "Chat completion endpoints —
/v1/chat/completions."; `MTPLX` `mtplx/server/openai.py:37679` `@app.post("/v1/chat/completions")`; `Strata`
`serve/server.py:6`, which names the Anthropic route in the same sentence; `openclaw`, where the endpoint is
a knob defaulting off — `src/config/schema.help.runtime.ts:287`; `TensorFold` `../references/TensorFold/README.md:3` "TensorFold
serves language models from a Zig binary"). So `wires a harness to itself` had been printing **6/7** when the
disk said **11/12 — we are the twelfth**, and `committed HTTP contract` had been 2/7 where it is 2/12. The
SEGMENT-AUDIT block now prints loose candidates; after the widening it prints two, both adjudicated
non-members on a read: `coreai-models` (`../references/coreai-models/swift/Sources/Tools/llm-server/ChatHandler.swift:45`
`router.post("/v1/chat/completions")` — a *pin*, and a finding about the vendor's own reference tree rather
than a comparator) and `hermes-agent` (its 23 registration-shaped lines are an eval probe:
`evals/api_delegation_http_probe.py:53` — a server it starts to test a client against). `vllm-metal` stays
out because its one /v1 line is a client POST (`args.endpoint + "/v1/chat/completions"`): a backend riding
vllm's server is not a server.

## The protocol that spread — ACP, with dates

Eight of the fourteen agent trees speak the Agent Client Protocol and all eight are editing that code now
(heat block: `present 8/14 · edited now 8/8`). The arrivals, each a file-add date from the probe above:

| Tree | The file that is the surface | Arrived | Which side |
|---|---|---|---|
| `hermes-agent` | `acp_adapter/__init__.py` | 2026-03-14 | agent-side server (+ `acp_adapter/edit_approval.py`) |
| `goose` | `crates/goose/src/acp/server.rs` | 2026-04-21 | agent-side server; deps pinned `agent-client-protocol = 2.2.0`, `-schema = 1.9.1` (`Cargo.toml:22-23`) |
| `cline` | `apps/cli/src/acp/acpAgent.ts` | 2026-06-03 | agent-side server |
| `openclaw` | `extensions/acpx/doctor-contract-api.ts` | 2026-06-06 | client-side: it drives another agent (`test/fixtures/codex-app-server.mjs`) |
| `qwen-code` | `packages/acp-bridge/src/bridge.ts` | 2026-06-12 | bridge; also ships `packages/zed-extension`, `vscode-ide-companion` |
| `deepseek-harness` | `.agents/notes/archived/feature/2026-06-14-acp-agent-client-protocol.i18n.yaml` | 2026-06-14 (their date) | agent-side, with an escalation e2e test |
| `opencode` | `packages/cli/src/acp/connection.ts` | 2026-09-17 | an ACP connection module in its CLI (`RequestPermissionRequest`/`Response` at `:9-10`) |
| `TensorFold` | `app/electron/agent/acp-server.ts` | 2026-10-13 | agent-side server, built on the official SDK |

Two readings that survive the limit in § How an arrival is datable: the practice reached this corpus's agent
segment in **March** and was still arriving in **October**, so the diffusion is open, not finished; and the
trees arriving latest are the ones you would not predict from the leaderboard (`TensorFold`, 943 tracked
receipt files and 5 556 commits in its last 30 days — see § The table).

**The primitive that made it worth adopting is the one we already own.** The protocol's approval call is
`session/request_permission`, and four trees route *tool approval* through it:
`TensorFold app/electron/agent/acp-server.test.ts:124` "a tool-approval request routes through
session/request_permission"; `qwen-code integration-tests/cli/acp-agent-loop-parity.test.ts:53` "Answers
each `session/request_permission`; allows once by default"; `goose crates/goose-cli/src/commands/roam_client.rs:42`
responding to `RequestPermissionRequest`; and `hermes-agent acp_adapter/edit_approval.py:201`, which builds
the `ToolCallUpdate` payload for an **edit** approval — the same problem as our `edit_file` mismatch offer,
solved at the protocol layer. That file's header is also the scope-discipline shape § *Working here* asks
for, stated at the declaration: *"Intentionally isolated from the generic tool registry: ACP binds an edit
approval requester in a ContextVar for the duration of one ACP agent run; CLI, gateway, and other sessions
leave it unset and therefore bypass this guard."* A transport-scoped approval guard that says so is a
defensible alternative to ours, not a bug in theirs.

**Who the clients are — borrowed, labelled.** `goose`'s own docs say ACP is Zed Industries' protocol and
name the client and agent sets (`documentation/blog/2025-10-24-intro-to-agent-client-protocol-acp/index.md:50`
"editors that support ACP include Zed, Neovim, and Marimo. Supported agents include Claude Code, Codex CLI,
Gemini, StackPack, and of course, goose"; `documentation/blog/2026-02-06-…:140` "goose is … also an ACP …
server … connect it to any editor that supports ACP"), and `../references/hermes-agent/skills/autonomous-ai-agents/hermes-agent/SKILL.md:24`
says its agent core drives "an ACP server for IDEs (VS Code / Zed / JetBrains)". **Those are comparator
claims, not measurements** — this box ran no editor against any of them, so for us the existence of an
editor-side demand is inference (§ *Upstream* 5). What *is* measured: 8/14 present, 8/8 editing, and zero
`acp` occurrences in `Sources/`, `docs/` or `skills/` here (grep, 11-04).

**Why this is not a task, and what it is.** A new inbound wire is rung 6 of the footprint ladder, so it is an
owner call — the registry already ruled that way when `goose`'s ACP surface was first registered (its row in
§ The table), and nothing here overrides it. What the round adds is the price: it is no longer "an
alternative some agents use", it is a MAJORITY axis whose approval primitive is a re-exposure of the single
destructive truth we already keep (`ToolEntry.isDestructive` → `securityPrecheck`), i.e. an adapter would be
a *second consumer of one home*, not a second home. The consumer-with-a-name test the ladder demands still
hasn't been met on this box.

## The wire that points the box at the world — a new axis, one false negative, and one device class nobody else has

Thirty-two axes measure MCP-to-screen-capture and until today none asked the question root's own identity sentence
answers —
*"sees, hears, speaks and codes, in one binary"*. An axis nobody patterns is indistinguishable from an axis nobody
works on, which is this file's own failure mode (§ What this costs), so the question got two decidable forms.

**Q1 — does the served wire carry media at all? Table stakes, and we are in it.** A media route registered by the
server itself (not called by its UI) scores in **8 of the 12 serve trees**: `vllm`
(`vllm/entrypoints/speech_to_text/transcription/api_router.py:31-32`, `@router.post(` over
`"/v1/audio/transcriptions"`),
`sglang` (`python/sglang/srt/entrypoints/http_server.py:1940`), `ollama` (`server/routes.go:2444-2446`, transcriptions
+ translations + speech), `omlx` (`omlx/api/audio_routes.py:512,1528`), `mlx-serve`
(`src/host/http/router.zig:110-113`, whose table at `:119-120,166` also carries `/v1/images/…`, `/v1/video/` and
`/v1/3d/`), `Rapid-MLX` (`rapid_mlx/routes/audio.py:2641,3512`), `TensorFold`
(`zig/src/server/routes.zig:115` dispatches `/v1/audio/speech`; its own ledger records it at `## 1.1.0`) and us
(`/v1/audio/transcriptions`). `openclaw` offers the same paths through its router extension
(`extensions/clawrouter/capability-offers.ts:34-35`) — a proxy row, not a model it runs. `splash` and `MTPLX` carry
none; `Strata`'s `serve/images.py` was not read far enough to call. Consequence: no spending is owed here, and
`mlx-serve` serving `/v1/video/` is the comparator our own video row should be read against.

**Q2 — does the wire carry the host's own devices? Three of twelve; the live ones are one.** New axis
`captures the host's own devices behind a route`, serve segment, `OC_EVIDENCE=1` prints all three hits, each a
different device class:

- **`Rapid-MLX`** — `@router.post("/observations")` mounted at `/v1/cua` (`rapid_mlx/routes/cua.py:62,913`) returns a
  PNG of a window **on the machine running the server**, taken through CoreGraphics
  (`rapid_mlx/computer_use/ax_driver.py:388-389` `CGWindowListCopyWindowInfo`). It is also the disciplined one: a
  requested app identity that disagrees with the target process is `app_mismatch` → 409, a stale window is
  `window_stale`, a missing frame is `screenshot_failed`, a 4 MiB frame is `screenshot_too_large` → 413
  (`routes/cua.py:426,474,480,969,983,988`), and permission state sits *on* the surface
  (`GET /v1/cua/permissions`, `POST /v1/cua/permissions/request` at `:559,574`).
- **us** — `routes.post("/v1/multimodal/capture")` (`Sources/ocoreai/Router/ChatCompletionsRouter.swift:895`), whose
  request type is `enum CaptureType { case camera, microphone, screen }`
  (`Sources/ocoreai/Handlers/MultimodalHandler.swift:24-28`): an HTTP caller points *this machine's* camera, mic or
  screen. `/v1/multimodal/speak` drives this machine's output. It is not in `AuthRoutePolicy.publicPaths`
  (`Sources/ocoreai/Middleware/AuthMiddleware.swift:146-154`), so it is keyed wherever auth is on.
- **`openclaw`** — `app.post("/screenshot")` (`extensions/browser/src/browser/routes/agent.snapshot.ts:236`) and
  `/screencast` (`routes/index.ts:45`), served by the browser extension's own local server: a **tab**, captured
  through the browser, not the OS camera or microphone. Same shape, different ownership.

**Heat puts it in the class this corpus calls a direction:** `present 3/12 · edited now 3/3` — a minority that every
holder is working on right now, which is the same test that made confinement a direction (§ The field's own trend in
`comparator-consensus.md`).

**Split by device class, because the count alone hides the finding.** A host **screen or window** behind a route is
held by three trees; a live **camera or microphone** behind a route by **one**, and it is ours — `Rapid-MLX` takes a
window, `openclaw` takes a tab, and both are screen-class. The trees that come nearest to live audio all put that
sensor on the caller: `pi` registers `web.get("/listen", listen)` and decodes samples **pushed up the websocket**
(`apps/p2/voice-server/server.py:355-357,368`), then answers `/speak` with a WAV **body** rather than a room
(`:188-195`), and `hermes-agent` registers `/api/audio/voice-live/session`, which opens a **WebRTC** session
(`hermes_cli/web_routers/audio.py:190-198`) while its desktop app records the mic in the **renderer** —
`navigator.mediaDevices.getUserMedia` inside a React hook (`apps/desktop/src/app/chat/composer/hooks/use-mic-recorder.ts:290,310`).
So the field's convention is **client-owned
sensors** — bytes up, or a session the client's browser holds — and the inverted wire is the singular thing here.

**The instrument was wrong once before it was right, and the fix is in the noun list.** The axis first required the
bound path to say `capture|screenshot|camera|microphone` and printed **2/12**, missing `Rapid-MLX` outright: its route
is `/observations`, and it surfaced only because the Q1 media enumeration walked the same directory and found a PNG
being assembled there (`rapid_mlx/routes/cua.py:978`). Adding `observation|cua|/screen` turned a false 2 into a true
3. What was tried and deliberately left out is `voice|listen|speak|talk` — binding those *is* the client-owned
convention, and scoring it here would count the convention as its own exception. The binding is doing all the work
either way: a bare `capture|screenshot|camera|microphone` word probe hits 27 of 29 trees, almost all of it capturing
stdout, closures and config keys (`config.get("camera_layout")`, mlx-serve's diffusion-sampler `noise_camera`
tensors), and requiring an HTTP-verb call whose first argument is a `/`-led path literal is what turns 27 into 3 —
the same correction the ACP row below records: in this corpus a word is not a mechanism, a binding is.

**What that means for `ours-alone: none`.** The DIFFUSION block still prints it, correctly — three in-segment trees
score the axis. What survives is narrower than a singleton and still stronger than the old line: **the screen-class
route is 3 of 12, the live-input one is 1 of 12**, and both halves are disclosed on every agent-readable surface we
have — `GET /v1/capabilities` (`V1EndpointCatalog.swift:155-165`, whose note states the two-phase mic),
`GET /openapi.json` (4 media paths of 34) and the README's endpoint table (`README.md:121, 126-127`) — so this is the
one differentiator a stranger's client can observe today without reading our source.

**The two trees that hold the mechanism converged on the same posture, and the comparator is the stricter on three
counts.** Both are **off until someone says otherwise** and both refuse by name rather than returning an empty
success: ours is a user-facing toggle that starts `false` (`UI/Models/MultimodalState.swift:42,51`) and a capture leg
that answers from the *measured* permission instead of opening a modal nobody on a headless box can click
(`Sources/ocoreai/Handlers/MultimodalHandler.swift:275-295`), with `success` derived from bytes actually coming back
(`:8-13`); `Rapid-MLX`'s is a server-side env opt-in — *"Screenshots are sensitive and require an explicit server
opt-in"*
over `env_truthy("RAPID_MLX_CUA_EXPOSE_SCREENSHOTS")` (`rapid_mlx/routes/cua.py:429-431`) — answering
`screenshot_disabled` 403 with a `recovery` array when it is off (`:925-936`), and a named `permission_denied` before
a frame is ever attempted (`:938-948`). Then it does three things we do not: **caps** one frame at 4 MiB and answers
413 (`:426,988`), stamps the response `Cache-Control: no-store` + `Pragma: no-cache` (`:918-919`, and our capture path
sets no cache header anywhere), and its `POST /v1/cua/permissions/request` **refuses a non-loopback client** —
`local_request_required`, 403, behind a config flag that must be on first (`:574-600`). Our own answer to that last
danger sits one rung earlier: `ServerAuthGate` refuses a keyless server any non-loopback **bind**
(`Sources/ocoreai/Middleware/ServerAuthGate.swift:9-35`) — stronger for the server, weaker for this route, because
once a key exists a caller on the LAN and a harness on this box are the same caller to us. And one rung *below* it:
`captureGate` consults the measured OS permission and nothing else (`MultimodalHandler.swift:160-176,275-295`), so the
user's own off-toggle is not on the wire path — the finding and its cost are filed in `open-items.md`, not fixed here.

**The limit, before anyone celebrates.** No caller has ever invoked it: the consumer-with-a-name test (§ *Working
here*, and item 3 above) is unmet on this box exactly as it is for ACP, and an un-copied mechanism is a posture until
a consumer exists. The action this axis points at is therefore not more multimodal machinery — it is the § Direction
item 3 harness work, since a harness that writes our base URL into its config is also the thing that would learn the
capture route exists.

## The table — the mechanism this corpus has no second instance of

One row per mirror. Verified today by opening the cited line (`show HEAD:<file> | sed -n <N>p`), the layer
that catches a drifted cite; where a number moved since the last read it is stated as measured today.

| Tree | The signature | Evidence read today | State |
|---|---|---|---|
| `vllm` | Keeps the Python engine, rewrites the northbound wire in Rust | `../references/vllm/rust/README.md:3` "rebuild the northbound serving layer in Rust while still talking to the core Python vLLM engine process(es) via ZMQ" | copied (see § Diffusion observed) |
| `sglang` | Generates its HTTP contract as Rust crates *and* ships the server crate | `rust/sglang-server/Cargo.toml:3` `description = "Sglang server in rust"`, beside `rust/sglang-api-codegen` | copied + one-up |
| `ollama` | A published logits lane: `POST /v1/systemone` | `api/client.go:449` `c.do(ctx, http.MethodPost, "/v1/systemone", req, &resp)` | singleton (the AR axis is homed in `systemone-decisions.md`) |
| `omlx` | KV's cold tier lives on disk | `../references/omlx/README.md:410` "PagedSSDCacheManager (SSD cold tier, safetensors format)" — **line moved from 402 since the last read** | singleton on disk-cold; § the divergence in `comparator-consensus.md` <!-- anchor:omlx README.md:410 PagedSSDCacheManager -->
| `mlx-serve` | A shipping ANE decode lane | `docs/reference.md:441` serves a dense pack "entirely on the Neu…", and `docs/reference.md:454` refuses grammars/forced tool calls by name | singleton |
| `splash` | Asserts the usage identity a client sums | `dev/tests/server/test_anthropic_contract.py:889` `count, usage["input_tokens"] + usage["cache_read_input_tokens"]` | singleton (ours is the second consumer, gated) |
| `Rapid-MLX` | Spec decode as *registry data*, naming a competitor's technique as a backend | `rapid_mlx/spec_decode/config.py:212-215` `named_backends = ("native", "tensorfold")`; `capability.py:4` "Registry flags are recommendation evidence… runtime preflight owns compatibility" | singleton |
| `MTPLX` | Prices a family's prefill from measurement, narrows before refusing | commit `ee9cca4f` (2026-10-03, in-mirror) | singleton; quiet for a month (0 commits in the last 30 d) |
| `TensorFold` | **A published evidence corpus as a product surface** — `docs/receipts/` holds 16 bundles and **943 tracked files**, 10 of them carrying a `SHA256SUMS`, and the model table cites a receipt per claim | `../references/TensorFold/README.md:182` links a "contributed receipt… on #1050's head, **not rerun on main**" | singleton by an order of magnitude (nothing else here publishes evidence per product claim) |
| `Strata` | Prices every harness it launches, in the user's own text | `strata_cli/launch/harness.py:165` "The setup needs limit.input (strata connect sets it to %d); without it OpenCode never compacts its conversation." | singleton |
| `vllm-metal` | Named the decision-probability axis in a doc before anyone shipped it | `docs/structured_decisions.md:3` "Jev-like System 1 decisions return yes/no probabilities, choices, and scores." | singleton (the axis, not the route) |
| `openclaw` | Shrink-only ratchets on *code* properties — and it has two | `config/assertion-safety-baseline.txt` "Ratchet: counts may only shrink"; `config/test-mock-exports-baseline.txt` "New factories require importOriginal/vi.importActual pass-through" | converged with us (§ Diffusion observed 4) |
| `hermes-agent` | Renders what a stock install actually sends, and fails on a stale snapshot | workflow `prompt-surface-diff.yml` present; skills tier counted 44 under `skills/`, 142 under `optional-skills/` | singleton |
| `codex` | Fail-closed context assembly for the reviewer that guards the shell | `codex-rs/guardian-context/src/lib.rs:5` "Contributor failures abort collection without returning partial context." | singleton |
| `claude-code` | The only sequence-bearing document in this corpus | 436 versions / 8 668 bullets, ledger block 11-04 (its tree is 1 348 `.ts` under `mods/`, so its churn is the plugin API, not the engine) | singleton |
| `qwen-code` | A vendored runtime with its divergences written down as a patch ledger | `packages/cua-driver/.vendored-from` + `.vendored-patches.md` both tracked; dated bilingual design docs land same-day (`docs/design/2026-11-03-project-execution-trust.md` + `.zh-CN`) | converged with us (different home: header-per-file + `make drift`) |
| `opencode` | Contract-first wire, then eats its own dogfood | `packages/cli/src/commands/handlers/api.ts:72` `fetch(new URL("/openapi.json", endpoint.url)…)` | singleton among agent trees |
| `goose` | Memory truth owned by the backend that owns the allocator | `crates/goose-local-inference/src/backend.rs:49` `fn available_memory_bytes(&self) -> u64;`; `tool_parsing.rs:4` `compact_tools_json` | singleton (no `BackendProtocol` here by decision) |
| `pi` | Deferred tools ranked by BM25 into the conversation's tool list | `packages/durable/src/tool-search/tool-search.ts`; `packages/evals` prices docs-lift per case | singleton; we score the axis on 2 noise hits (§ ledger) |
| `cline` | Publishes the agent *as an SDK*, and says so on its own board | `sdk/packages/*` with its own publish leg; `../references/cline/evals/README.md:5` "Smoke tests (Layer 2) are partially disabled while the eval framework is repointed at the new SDK CLI." | singleton (also: the only intake workflows that strip AI badges — `.github/workflows/repo-strip-agent-badges.yml`) |
| `deepseek-harness` | Dated, bilingual decision notes + a tested injected corpus + oversize refused not truncated | `.agents/notes/archived/feature/2026-06-14-…`; `snapshots/session/*`; `docs/config-catalog.md:378` "larger files are refused, never truncated"; 4 `packages/sandbox/*` packages, 95 tracked files today (was 92) | singleton ×3 |
| `OpenHands` | The locale table generates the declaration, then a checker proves coverage | `../references/OpenHands/AGENTS.md:8` "After editing `src/i18n/translation.json`, run `npm run make-i18n`" | converged with us (we gate harder) |
| `harness2` | Every redistributed byte pinned in a committed map with a checker | `dependencies/PINNED.md`, `scripts/check_provenance.py` | consumed already (manifest schema 2) |
| `mlx-swift-lm` | Ships the skill that teaches an outside agent its own API | `../references/mlx-swift-lm/skills/README.md:1` "# MLX Swift LM skill" | converged with `coreai-models` |
| `coreai-models` | Same, plus a local OpenAI-compatible server of its own | 3 `skills/**/SKILL.md`; `../references/coreai-models/swift/Sources/Tools/llm-server/ChatHandler.swift:45` | singleton among the pins |
| `SWE-bench` | A vacuity floor argued in prose and enforced by a regex | `swebench/harness/grading.py:31` `SUITE_RAN = re.compile(` | confirmation, not an axis |
| `Qwen3.8` | The trainer's own wire words | `../references/Qwen3.8/README.md:25` "Reasoning depth can be tuned with `reasoning_effort`, and reasoning context from historical messa…" | the vendor's, not ours |
| `Qwen3.8-Flash-Next` | A native MTP module + N-gram embedding tables in the checkpoint | README serve line now reads `--context-length 262144 --reasoning-…` (the row's other numbers are in `comparator-repos.md`) | the model, not the harness |
| **ocoreai** | The one wire in the corpus whose capture happens on the box behind the address, not in the caller | `Sources/ocoreai/Router/ChatCompletionsRouter.swift:895` + `Handlers/MultimodalHandler.swift:24-28`; `ours-alone: none` still prints (3/12) | live input behind a route: 1 of 12; a combination otherwise |

## Diffusion observed — four cases where I could see the mechanism move

1. **ACP**, 1 → 8 in the agent segment between 03-14 and 10-13 (§ The protocol that spread). The mechanism
   that made it worth copying is not the transport, it is that approval is *in* the protocol, so an agent
   gets a UI for its gate for free.
2. **Rust northbound, Python engine.** `vllm rust/README.md:3` and `../references/sglang/rust/sglang-server/Cargo.toml:3`
   within one quarter, with sglang adding a *generated* API crate. Two independent trees decided the same
   thing about the same layer; the read is "the wire is a compiled-language problem, the engine is not".
3. **A comparator consumed by a comparator.** `Rapid-MLX` lists `tensorfold` as a named spec-decode backend
   (`rapid_mlx/spec_decode/config.py:212-215`) and refuses to let the registry be a permission check
   (`capability.py:4`). Our own closest comparator is thus *shipping* a different comparator's technique as a
   data row — which is the strongest available evidence that an idea has spread: it stopped being code and
   became a row someone configures.
5. **Refusal-shaped device exposure, twice, independently.** The two trees that put the host behind a wire route
   both answered the same way without consulting each other: name every refusal, never return an empty success, and
   publish the permission state beside the capability (`Rapid-MLX` `rapid_mlx/routes/cua.py:474-480,559-574` against
   our `MultimodalHandler.swift:275-295` and the `success`-from-bytes rule at `:8-13`). The delta runs one way and is
   worth acquiring: it caps what a capture may cost (4 MiB → 413, `:426,988`) and refuses to let a **non-loopback**
   client trigger a permission prompt (`:574-600`), where our rule is about the bind, not the caller
   (`ServerAuthGate.swift:9-35`). Filed against the existing authority owner call, not opened as a task.
6. **The shrink-only ratchet, twice, independently.** `openclaw` runs it over production type assertions
   (`config/assertion-safety-baseline.txt`, 1 619 touches in 60 d) and over mock factories; we run it over
   the injected-byte budget (`scripts/agents-md-contract.sh:76` — `make docs-budget` "lower[s] the pinned
   root cap … (refuses to raise it)"). Same shape, different property, and the shape came from the same
   place in the end (harness2's digest map taught the manifest, the manifest taught the ratchet). A
   convergent invention is the one class of innovation claim this corpus can actually support.

## What this costs — three numbers in our own docs that were wrong while I read them

Reported here rather than in `comparator-consensus.md` § The ledger because they are this file's findings and
the ledger is that file's home; all three are the same bug: **a count that was not re-grepped before it was
quoted.**

- `wires a third-party coding agent to itself` printed **6/7**; the correct statement off the same patterns
  with an honest serve segment is **11/12** and we are the twelfth. Every sentence built on "five of seven"
  understated the debt.
- **One unit error, mine, caught before it shipped.** I read `git ls-files docs/receipts/ | wc -l` = 943, took
  it against the registry's "16", and wrote that the row was 60× stale. `16` is **bundles**, and the tree
  still has 16; 943 is files inside them. The registry was right and I was wrong, and the error had the
  corpus's exact shape — a count divided by the wrong denominator, this time a count compared against the
  wrong unit. `git ls-files docs/receipts/*/README.md | wc -l` is the line that says what the registry's
  number measures.
- The DIFFUSION block inherits every false positive § *The ledger* already documents, so its `ours: yes`
  cells are candidates, not verdicts — `deferred / filtered tool surface 12/14 ours:yes` is scored on
  `Tests/ocoreaiTests/CheckToolsTests.swift:44` (`func toolFilterExact()`) and a comment *about codex* at
  `scripts/eval/_eval.py:214`; re-checked today, those are still our only two hits. `OC_EVIDENCE=1` exists for
  exactly this, and "ours-alone: none" is the one line of the block that stays true under such a correction.
- `omlx`'s SSD-tier cite moved from `../references/omlx/README.md:402` to `:410` between rounds (the anchor checker passes a
  moved-but-resolving line, and the memory note about comparator cites being content-unverified is exactly
  for this).

## Where this leaves the direction

`comparator-consensus.md` § Direction is the home of the ranked list; only the deltas go here, each with the
number that moved:

1. **Harness-wiring is now measured at 11/12, not 6/7** (§ What this costs) — direction item 3 goes from
   "five of seven nearest trees do it" to "every serving tree in the corpus does it except us". Same
   cheapest slice, more urgency, no new mechanism.
2. **ACP becomes a measured MAJORITY axis (8/14, 8/8 editing) rather than a named pattern.** Still rung 6,
   still an owner call, and the consumer-with-a-name test is *not* met here (no editor ran us). What changed
   is the price of the call: on the other side of the decision is a protocol whose approval primitive
   consumes our existing single destructive home instead of adding a second one.
3. **Do not chase the singleton column.** Of the ~20 signature mechanisms in § The table, the ones that were
   copied (Rust northbound, the shrink-only ratchet, the vendored patch ledger, generated contracts) all got
   copied *because they were cheap to adopt, not because they were clever*. The signatures nobody copied —
   `hermes-agent`'s prompt-surface diff, `codex`'s fail-closed context, `TensorFold`'s receipts, `Strata`'s
   per-harness token pricing, `openclaw`'s LLM-refreshed locale catalogs — are each a standing cost with no
   observed imitator. Reading that honestly: an un-copied mechanism is a *posture* until a consumer exists,
   which is exactly the test our own footprint ladder already applies (§ *Working here*).
4. **`ours-alone: none` has its first qualified answer, and it changes no spend.** The device route (§ The wire that
   points the box at the world) is 3/12 by pattern and 1 of 12 on the live-input class, and it is already disclosed on
   `/v1/capabilities`, `openapi.json` and the README — so the disclosure half of the old claim is done for this
   mechanism and the *consumer* half is not. It reads as one more reason behind direction item 3, not as an item: a
   harness wired to us is the only thing that would make the route more than a posture here.
5. **The device split cuts against the intuition, so name it plainly.** Every near-miss in this corpus puts the mic
   and camera on the caller (uploaded bytes, a websocket the client feeds, a WebRTC session the browser holds) and
   returns media as a response body. Ours is the inverted wire. That is a bet with two tails: a harness that wants
   audio *bytes* back has no route to ask for them (we speak through the host), and a caller that would use our
   camera has to trust an authenticated route onto someone's hardware, which is the same owner's question the
   unconfined child process is (§ *Where the field confines a child*) and is not answered by anything in this corpus.
   Both tails are owner calls, not tasks; what was missing was the measurement, and now it exists.
