# The references corpus, read by problem. Does each problem exist here?

> Owner directive 11-20: deep-research `~/references` for the **problem each tree exists to solve**, not
> their architectures, and check whether that problem exists in ocoreai. This is the problem-first view;
> the per-tree content axis stays in `comparator-repos.md` (one home each: that file answers "what does
> tree X hold", § Field-solved here answers "does the problem exist here", `comparator-consensus.md`
> answers "does the field do Y").
> Label discipline (root § Working here): **measured** = read or run this session at the disk HEAD;
> **registry (dated)** = the problem statement carried by that tree's row, its own dated snapshot;
> **inferred** = judgment, labelled. A new row's cites are read 11-20 unless marked otherwise.

## Corpus at HEAD (measured 11-20)

The registry header's own instrument, `for r in $(ls "$HOME/references"); do … CHANGELOG count … done`,
had not been run since 10-28. Run today: **56 trees on disk; 7 had no registry row**
(`foundation-models-utilities`, `gemini-cli`, `mlx-lm`, `mlx-swift`, `oh-my-pi`, `evals`,
`cursor-plugins`. Zero registry rows; the `evals`/`mlx-swift` doc hits are other trees' packages and the
pin-1 label, not rows). `MTPLX`'s row was stale in kind, not just date (its fresh row names the defect).
Rows added, so the registry again answers for every clone on disk.

**Re-measured 11-25, and the claim went false exactly as this section's law predicts.** Disk is 58 clones;
one carried no row (`mlx`, Apple's C++/Metal core, clone born 11-23, HEAD `5598dfa0a` 11-24), so a tree
arrived and went unread for two days because nothing diffed disk against registry. The diff is now the
script `scripts/audit-registry-coverage.sh` (in `make audit`), and its first run named both faults of the
hand-written sweep in one pass: it missed `mlx` and reported `coreai-models` as a hole, because that tree's
row shares a bullet with `mlx-swift-lm` (`comparator-repos.md`) and the naive regex reads one name per
bullet. Row added; the script runs green.

## Field-solved here (open. The five findings that change something; the fifth is an absence)

1. **`foundation-models-utilities` is a consumer channel we already satisfy and never advertise.**
   Measured: Apple's package drives Apple's `LanguageModelSession` against *any* OpenAI-compatible
   `/chat/completions` (`ChatCompletionsLanguageModel.swift:23`, endpoint selection `:632`), streaming
   with `stream_options: {include_usage: true}` (`:731`), `response_format`, `tool_choice`; its test
   suite is an SSE-edge-case/tool-calling/usage/error checklist
   (`Tests/FoundationModelsUtilitiesTests/LanguageModelsTests` family, read by filename). Our side was
   measured this session: `streamOptions.includeUsage` exists and the final-SSE-chunk usage emission is
   wired (`Handlers/ChatHandler.swift:2023-2024`), `response_format` parses (`Models/OpenAIModels.swift`
   `responseFormat` coding keys), delivery gated by probes 12/54. **Not** measured: a live round-trip of
   Apple's own client against our server. Never run, so it is an axis with a candidate probe, owned by
   root § Adoption ("agents are a channel they cannot find") and § Upstream's "judge OpenAI/Anthropic
   compatibility as vllm and sglang judge it: the spec, their implementation, real requests". Apple's
   client is now the third implementation in that judgment, and an iOS app built on the FM framework is
   the exact stranger in `long-horizon-goal.md`. The package also teaches foreign hosts through
   `skills/`. The shipped-skill pattern now has three pin-adjacent trees (mlx-swift-lm, coreai-models,
   this), which raises the field count behind runbook § rung-6 without changing its owner-call status.
   Premise check the same day, which half-killed the candidate: the round-trip cannot run on this host
   for a reason that is not ours. The package's manifest requires `.macOS("27.0")` (`Package.swift:19`,
   measured) against this host's 26.6.2 (measured `sw_vers`), the same premise as the CoreAI/macOS-27
   row, and building an external tree's code needs the owner's explicit word (the harness refused the
   compile-attempt for a read-only comparator, correctly). The client's source carries zero
   `@available(macOS 27` gates (measured). The block is the manifest and the framework, not their file.
   The curl-level half of the contract is already gated (probes 12/54/22/56); the client-parser half
   waits on a 27 host, not on a decision.
2. **`oh-my-pi` names a problem we have and do not solve: IDE-grade feedback inside the loop.**
   Measured both sides. There: LSP as a multiplexed daemon module. One language-server process per
   identity and instance, per-session request-id remap, cached `initialize`, replayed diagnostics,
   watched-file forwarding (`packages/coding-agent/src/daemon/modules/lsp.ts` header comment, read 11-20
   at `63bfb67d16`); agent-visible ops `diagnostics`/`hover`/`definition`/`references`/`rename`/
   `symbols`, plus a debug-adapter lane (`evaluate`). The README's 31 tools / 14 LSP ops / 28 DAP ops is
   its first screen's claim. Here: zero `lsp`/`dap`/`sourcekit` in `Sources/ocoreai/Tools/` (measured
   grep); our coding loop's feedback after an edit is a full build plus the edit-repair round trip
   (`EditMismatchRecoveryTests`). The problem exists here, unsolved, and the remedy is a new agent-facing
   tool surface, so it was an owner call; **ruled 11-25, ruling text at § What this map changes**. Footprint
   ladder note: sourcekit-lsp already exists as the mechanism to consume, and the host carries it
   (`xcrun --find sourcekit-lsp` → the Xcode toolchain's binary, measured 11-25). Adjacent axes on the same
   shelf, one line each: `mnemopi` (a local SQLite memory engine for its agents), `snapcompact`
   (bitmap-frame vision compaction), `metaharness` (benchmark runner + run storage + live dashboard,
   the board display our `scripts/eval` has no analogue of). All inferred-not-priced for us.
3. **`gemini-cli` states our § Open tool-surface premise in Google's own product copy.** Its README's
   first screen is now a warning: not tuned for Gemini 4+, and "**Don't use Gemini CLI to benchmark
   Gemini models**. Its harness isn't tuned … and produces unrepresentative scores" (read 11-20 at
   `d4cb1713f`; free tier moved to Antigravity CLI 06-18, enterprise Code Assist only). That is exactly
   the premise of § Open's "the tool surface is ungated against the loaded model" (row confirmed at
   `open-items.md:262`): a harness drifted from its model produces confidently wrong numbers. Field
   backing for the owner call; the tree itself is not a benchmark instrument here (measured: its README
   says so), and the registry row keeps it as that verdict's home.
4. **`MTPLX` now ships the flagship our pin cannot load.** Measured at `eb580fce`: first screen "The
   fastest way to run Qwen 3.8 on a Mac" (`README.md:5`), running Qwen 3.8 Flash Next on native MTP with
   a public per-number receipts board (version, machine, date; `README.md:19`), and an honesty line at
   its own version boundary. The image path uses the compiled verifier but "that sampled comparison has
   not yet been repeated for images" (`README.md:34`). Our pin's inability re-measured today: `qsa` and
   `ngram` are zero times in the built checkout's sources (grep, exit 1). No new consequence. The
   owner's download-plus-upstream-port decision already lives in the `Qwen3.8-Flash-Next` row, but the
   pressure is now "a small tree ships it", which is the same class as the ladder's field-ceiling
   pattern.
5. **`mlx` is not where the flagship loads: an absence, measured.** At `5598dfa0a` (11-24) the words `qsa`,
   `ngram`, `MTP` and `speculative` appear **zero times in the whole clone** (grep, 0 files each), and the
   pin-1 window is unchanged at **+9** (`api.github.com` compare `bf5a5d438...main` re-read 11-25; upstream
   `main` has not moved since `6759555f2` 11-20). So finding 4's gap closes only through Swift-side model
   code we author or through upstream `mlx-swift-lm`: pulling the C++ core forward buys nothing here. Same
   tree, second datum: its Metal and common backends read exactly one runtime env var
   (`MLX_METAL_GPU_ARCH`, a `getenv` sweep), so our memory-pressure route (`MemoryTracker`, `OOMGuard`) has
   no upstream env rung to ride either. Consequence: a kernel-class ceiling is ours to decide, and this row
   is read before any custom-kernel spend, not after.

## Tree → problem → exists here?

Per-tree content verdicts are the registry's (that table's *source* column names the row holding the
detail; "registry (dated)" there means the problem statement is that row's, not re-read today).

| Tree | The problem it exists to solve | Exists here? | Source / home |
|---|---|---|---|
| vllm | compatible serving + intake policy at scale | yes, consumed | registry (dated); `CONTRIBUTING.md` |
| sglang | same compat axis + permissions as data | yes, consumed | registry (dated); adoption-runbook |
| splash | usage identity a client can sum | yes, consumed | `AnthropicCacheUsageTests` + probe 22 |
| harmony | the response-format role vocabulary | yes, cited | registry (dated), primary cite |
| ollama | two engine families behind one local API | yes (our dual lane) | registry (dated) |
| llama.cpp | engine depth on one bet: grammar, MTP, Peg tools | axes, no consumption | registry (dated) |
| mlx-swift-lm | LLM/VLM layer on MLX (pin 1) | consumed (pin) | § Upstream 1 |
| mlx-swift | the Swift array framework itself | consumed transitively | new row, measured 11-20 |
| mlx | the kernel/allocator substrate every MLX binding shares | yes, transitively; read for the first time 11-25 | new row + this §5, measured 11-25 |
| mlx-lm | Python reference for MLX models + finetune | no; out of stack | new row, measured 11-20 |
| mlx-serve | same product sentence, foreign engine | the wedge is what it lacks | registry (dated); goal § Rung zero 4 |
| Rapid-MLX | our sentence shipped, app+server, agents wired | four axes, no home yet | registry (dated) |
| omlx | distribution: DMG, auto-update, shim, tap | rung 2 consumed | registry (dated); runbook |
| MTPLX | MTP decoding as its own product | yes (our MTP lane) | registry + dated note, measured 11-20 |
| TensorFold | a measurement travels as a portable receipt | pattern, no consumer | registry (dated) |
| Strata | local product growth + honest dry-run | dry-run consumed | registry (dated); probe 36 |
| vllm-metal | vllm backend on Metal | no; out of stack | registry (dated) |
| openclaw | #1 distribution machine | no; the wedge it declares | registry (dated); runbook |
| unsloth | train+run at cadence (AGPL boundary) | axis only | registry (dated) |
| coreai-models | Apple reference graph (pin 2) | consumed (pin) | § Upstream 2 |
| foundation-models-utilities | FM framework needs a backend; teach foreign hosts | **yes; wire already fits; channel unadvertised** | new row + this §1, measured 11-20 |
| hermes-agent | loop shape + ops + skills tier | yes, consumed | registry (dated) |
| codex | first-party self-documentation; guardian context | on-demand file:line（drift 轴位 11-22 撤销） | registry (dated), owner ruled comparator |
| claude-code | product-behaviour diary of a peer | tracking axis | registry (dated); CHANGELOG 11-02(112) |
| qwen-code | workspace trust + vendored CUA + self-mod gate | axis, measured absence | registry (dated) |
| cline | publish legs + SDK embedding | axis, no home today | registry (dated) |
| opencode | contract-first wire + cassette replay | replay axis | registry (dated) |
| goose | dual-engine pool + compaction crate | axes, not debt | registry (dated) |
| pi | deferred tools, code mode, docs-lift | § Open items | registry (dated) |
| deepseek-harness | tested injected surface; oversize refused | consumed to open-items | registry (dated) |
| harness2 | unforgeable grades + asset provenance | consumed (schema 2); env-scrub gap | registry (dated); open-items |
| SWE-bench | a score that cannot lie (vacuity floor) | confirmed, nothing taken | registry (dated) |
| terminal-bench | continuous benchmark hygiene | confirmation | registry (dated) |
| harbor | external task supply for a board | not live | registry (dated) |
| SWE-agent | agent–computer interface as config | axis only | registry (dated, stale clone) |
| mini-swe-agent | the price ceiling of harness simplicity | foil axis | registry (dated) |
| aider | failed-edit round trip as prompt contract | consumed | registry (dated); edit-repair row |
| evals | a shared registry for eval corpora | no; board scores its own workspace | new row, measured 11-20 |
| SWE-ReX | remote sandboxed shell runtime | dormant | registry (dated) |
| autoresearch | keep-or-discard without floors | pattern only | registry (dated) |
| OSWorld | per-task honesty in a CU corpus | confirmation | registry (dated) |
| BrowserGym | silently-skipped ≠ passed | one home (SWE-bench row) | registry (dated) |
| Hybrid-Computer-Use | refuse actions planned on stale state | § Open multimodal | registry (dated) |
| HyperAgents | none; placeholder | none | registry (dated), removal candidate |
| oh-my-pi | IDE-grade feedback (LSP+DAP) in the loop | **yes; unsolved, ruled 11-25: diagnostics slice, flagged** | new row + this §2 + § What this map changes |
| gemini-cli | enterprise CLI honesty incl. its own staleness | premise feeds § Open tool-surface | new row + this §3, measured 11-20 |
| OpenHands | UI state + locale completeness | gates exist, harder | registry (dated) |
| modelcontextprotocol | dated wire substrate for tools | consumed as spec | registry (dated) |
| agent-client-protocol | editors as harness consumers | **yes; face shipped 11-24** (long-horizon rung 7; owed witness: a real editor driving a turn) | `Sources/ocoreai/ACP/`; registry row now stale in kind, not date |
| claude-skills-official | how a skill routes | consumed 11-09 | registry (dated); probe 39 |
| claude-plugins-official | the plugin channel + validator | consumed 11-09 | registry (dated) |
| nanoGPT | a dated reference's death by pointer | pattern axis | registry (dated) |
| nanochat | one-knob training reference | no; out of stack | registry (dated) |
| llm.c | pretraining reference (dormant) | no; out of stack | registry (dated) |
| Qwen3.8 | what the family promises (wire words) | feeds § Open thinking row | registry (dated) |
| Qwen3.8-Flash-Next | what the next year runs on | **yes; pin cannot load it** | registry (dated); QSA re-measured 11-20 |
| nginx | what a forwarded header canonically means | consumed as authority | registry (dated) |
| cursor-plugins | none; the owner's own tooling repo | n/a | new row, measured 11-20 |

## What this map changes, and its gate

Problems 1 and 3 feed existing owner calls (Adoption's channel; § Open's tool-surface) rather than new work;
problem 4 moves no row. **Problem 2 is ruled (maintainer ruling 11-25, the day design authority moved into
this thread): adopted, first slice diagnostics only, behind an opt-in flag.** The consumer exists today (the
Execute → Verify loop pays a full `swift build` per edit), so `sourcekit-lsp` diagnostics after an edit is a
surface with a real reader; the DAP lane is refused for exactly that reason, nothing in the loop debugs. The
spend is not authorised until the board prices one arm of it, and `ToolSurfaceReachability`'s dark landing is
the precedent for "built, unflagged, one arm short".

One gate was added 11-25 against the freeze, and it pays the two debts § Working here demands. The red it was
sampled against: `mlx` on disk since 11-23 carrying no row, found only because a round hand-diffed the disk.
The reader whose action changes: the round re-deriving the corpus, which until now had to guess whether
registry silence meant absence. Its floor is its own hit count (`row_names >= 50`, `covered >= 50`), so a scan
that stopped matching reddens as `INSTRUMENT BROKEN` rather than as coverage. This doc's other decay
instrument stays the registry header's diary loop, re-runnable from disk by construction, plus each new row's
`file:line` cites, read off HEAD today and re-anchorable by any future round.
