# What the field agrees on — the consensus, counted

Long form behind § *Upstream Audit Dependencies* 5. `comparator-repos.md` answers **what does tree X hold**; this
file answers the other question — **does the field agree on Y** — and that question has a denominator, which is why
it needs its own instrument instead of twenty readings of twenty READMEs.

> **Re-derive:** `bash scripts/comparator-consensus.sh [parent-dir]` — 29 mirrors: the 28 in `~/references` plus
> us, scored by the same patterns. Premise, stated because it decides every number below: **this box's mirrors at
> their 11-04 HEADs**. A runner has no `~/references`, so none of this is a gate — a cross-tree count is a
> direction input, and a printed count carries no verdict (§ *Working here*). The script floors one thing about
> itself: an axis no tree matches prints `INSTRUMENT-DEAD`, because that has already happened here (§ The ledger),
> and `OC_EVIDENCE=1` prints one matched `file:line` per tree, because three counts here turned out to be counting
> the right word in the wrong role.

## What the corpus did not know about itself

Read for consensus, the corpus first failed to agree with its own inventory. Five findings, all invariant 1:

- **27 trees on disk, 26 rows in the registry.** `cline` (71 277 stars, 855 tags, four publish legs) had been
  cloned here since the corpus began and had no row; it has one now.
- **The sentence that claimed completeness named an instrument that cannot see the thing.** "26 on disk, 26 rows
  here, counted by the P1 scan" — P1 derives the tree set from *the registry's own bullets*
  (`scripts/agents-md-contract.sh:388-390`) against a floor of 16 and never reads `~/references`; a missing row is
  exactly what it cannot report. The clones it does glob are used to resolve cites, not to count trees.
- **The command written to catch a stale cell was the stalest thing in the file:** the diary one-liner hand-typed
  24 tree names while 27 sat in the directory. It derives from the disk now, so a tree that arrives without a row
  is visible on the next run.
- **The instrument caught the next tree the same day; the prose did not.** `Rapid-MLX` arrived at 12:26 and the
  sweep printed `mirrors: 29` while the registry still had 27 rows — nothing scans the disk for *rows*. The
  durable half: a count derived from the disk updates itself, prose does not, and a scan that reads its own
  declaration instead of the world agrees with itself forever (root's first invariant; the dated round is in the
  diary).
- **The registry's own coupling counts were off, in both directions.** Re-derived 11-04 over 28 trees with `git
  grep -l -w`: **twelve** carry zero *name* coupling (MTPLX, OpenHands, Qwen3.8-Flash-Next, Rapid-MLX, SWE-bench,
  Strata, TensorFold, claude-code, cline, harness2, opencode, qwen-code — four of which say so themselves: "no
  home here today", "axis only, no new gate", "Named pattern only"), and **21 of 28** carry zero *cite* coupling,
  leaving `vllm`, `sglang`, `omlx`, `deepseek-harness`, `codex` and the two pins. `mlx-serve` sits in the zero-cite
  set while carrying the wedge of `long-horizon-goal.md` § Rung zero 4, which is why the two measures print
  separately: a row can be load-bearing in `docs/` and unmentioned in `Sources/`. Without `-w` the same command
  scores `cline` at 7 (from "decline") and `pi` at 458 (`Float.pi`), which is how the registry's sentence read
  *seven*, then *ten of the 24*, while the disk said otherwise each time.

## The consensus, ranked by how unanimous

Counts are in-segment (`serve` = **12** trees that answer a chat-completion POST themselves; `agent` = 14
harnesses a person drives; `shippable` = 24 trees that ship something a stranger installs — everything but the
two model READMEs, the two pins and the SWE-bench harness, plus us). Segments are declared in the script as
data, so a denominator can be argued with — and one of them *has* to be: `serve` had been hand-typed at 7
while five serving trees sat unlisted, so every serve row below was a field divided by a subset of itself
(the five, each with its route line, and the two adjudicated non-members: `comparator-innovation.md` § What
this costs). Re-measured 11-04 against 29 mirrors.

| Practice | Segment | Trees | Ours |
|---|---|---|---|
| Advertises an install route a stranger can reach | shippable | 21/24 | yes — a DMG, once (`README.md:23`) |
| …of which: a command a stranger can *type* | shippable | **16/24** | **no** (§ Direction, item 2) |
| …of which: a store shelf | shippable | 2/24 (`cline`, `mlx-serve`) | no — and neither does the field |
| Reads a project rules file in its own code | agent | 14/14 | yes (`WorkspaceContext.swift:34`) |
| Cancellation path in code | shippable | 22/24 | yes (35 files) |
| Auto-update path in code | shippable | 21/24 | half — notifies only (`Core/UpdateCheck.swift`) |
| Refuses an empty suite as evidence | shippable | 21/24 | yes (49 source files) |
| Live probe / smoke scripts committed | shippable | 23/24 | yes (58) |
| Session rewind / fork / compaction | agent | 14/14 | yes (`Reasoning/ConversationCompaction.swift`) |
| Turn/stall bound in code | agent | 14/14 | yes (`LoopStallTerminationTests`) |
| Verifies bytes in a download module | serve | 12/12 | yes on the route we fetch (`ModelScopeDownloader.swift:1136-1144`) |
| `reasoning_effort`-class knob | serve | 12/12 | yes, and gated (probe 38) |
| Evals or benchmark tree | shippable | 19/24 | yes (26) |
| Third-party notice manifest | shippable | 17/24 | yes (43) |
| Screen capture / computer use in code | agent | 12/14 | yes (17) |
| Deferred / filtered tool surface | agent | 12/14 | **no** (§ The ledger: our 2 hits are noise) |
| `SKILL.md` files published | agent | 11/14, median **14** | **1** (`skills/ocoreai/`) |
| Release tags | shippable | 23/24, median **245** | **1** (v0.1.14) |
| **Wires a third-party coding agent to itself** | serve | **11/12** | **no — we are the twelfth** (§ The harness side) |
| **Speaks ACP (the editor↔agent protocol)** | agent | **8/14, and 8/8 editing now** | **no** (§ Direction 8) |
| **OS confinement profile for the child process** | agent | 6/14, honest read 5 | **no** (§ Where the field confines) |
| Committed machine-readable HTTP contract | serve | **2/12** | yes (`openapi.json`, generated) |
| Published client *package* | serve | **2/12** (`openclaw`, `sglang`) | no |

Three numbers are the whole calibration, so read them twice. **Median tags 245, ours 1.** Of the 23 installable
comparators, **21 minted at least one tag in the last 30 days**; we minted one in the last 120 (§ The field's own
trend). And the practice we are behind on that the field holds near-unanimously (auto-update 21/24, an install
route 21/24) is the one root already calls the open item — now measured instead of asserted.

## Where the field disagrees

Agreement is the headline; the useful signal often sits where the trees split. Eight divergences worth a
direction, each with its own evidence (the rest are pointers to sections that already hold them, because a
second home for a decision is the thing this corpus keeps catching):

- **How long a warm prefix is allowed to live** — the axis is 12/12 present and 12/12 being edited, so
  everyone agrees on reuse and disagrees on its lifetime. `omlx` runs a cold tier on disk
  (`PagedSSDCacheManager`, `../references/omlx/README.md:410`, safetensors); `Rapid-MLX` writes its radix cache on shutdown and re-imports
  it at startup, guarding the swap so a torn snapshot cannot replace an importable one
  (`../references/Rapid-MLX/rapid_mlx/routes/cache.py:583-592`, its own claim at `README.md:78`); `mlx-serve`
  names a process-lifetime prefix cache and caps it on RAM-tight Macs
  (`../references/mlx-serve/docs/performance.md:65`); we persist per
  *session* — written on eviction, re-read on a cold pool miss (`Engine/SessionPool.swift:1179`, `:1253`, the
  rule stated at `:20`) — so a session that was never evicted has no snapshot and its warm prefix dies with the
  process, and no reuse crosses a session or a model. Nobody here is measured to be right;
  the divergence is the honest state of the art, and our choice is the one that matches a per-session product.
- **Whether the ruleset is a chain or an org chart** — § The injected ruleset: four trees load a ruleset bigger
  than their own loader's cap, and `Rapid-MLX` sidesteps the ladder entirely with one 19 438 B role roster.
- **Whether a served contract is a feature** — § Where we are ahead: vLLM builds its app with
  `openapi_url=None`, sglang keeps an env switch, we generate and commit the file. The split decides whether a
  generated client is a bet or a catch-up.
- **Whether the child gets confined** — § Where the field confines a child: it tracks whose code the child runs,
  not how careful the authors are. And the split is finer than that section knew when it was written: the trees that
  spend on this divide between **OS confinement** (TensorFold's profile, `deepseek-harness`'s four
  `packages/sandbox/*`) and **review/approval machinery** (`codex`'s `guardian/`) — `comparator-evolution.md` now
  measures them as two axes, because one bucket covering both said the wrong thing about both.
- **Whether language is a product surface or an afterthought** — `hermes-agent` carries nine locales
  (`ar de en es fr ja ru zh zh-hant`) behind `catalog-completeness.test.ts` and an `overlay-gaps.json` that names
  what is *not* translated, and locale tables are among the hottest files in `opencode`, `qwen-code` and
  `OpenHands`; `claude-code` records locale **twice in 436 releases, first at #429**. Both ship to large
  installs, so this is a real disagreement about whether the user's language is part of the product. We sit on the first half (two complete 463-key
  tables, `availableLocales` restricted to exactly those) — § Direction item 7.
- **Whether measurement is a product or a private harness** — `harness2` is benchmarks and nothing else (its churn
  is 27 % measurement, its hottest files are `benchmarks/jobbench.py` and `core/proposer.py`); `Strata` prices every
  harness it runs in tokens; `openclaw`'s single most-edited file is a **shrink-only debt ratchet** whose header
  reads "Ratchet: counts may only shrink", owned by `check-assertion-safety-ratchet.test.ts`. Against that, the most
  installed agent in the corpus records tests/evals in **29 of 436 releases, first at #118** — its ledger is almost
  silent about its own harness, which is expected of a user-facing changelog and is exactly why a ledger cannot be
  read as an effort report. Our half: 26 eval files, a scoreboard that verifies the workspace, and the standing
  disclosure that the board scores 6 of the 40 advertised tools.
- **Who owns the sensor the model sees through** — the field's convention is client-owned (bytes up; a websocket the
  client feeds); ours inverts it — a route points *this box's* camera, mic or screen at the caller. 3 of 12 bind
  such a route, 1 of 12 a live-input one, plain media is 8 of 12: the modality is table stakes, the ownership is
  the split (§ The wire that points the box at the world in `comparator-innovation.md`).
- **Whether you owe a stranger a ledger** — 14 of 29 trees track no changelog anywhere; 3 use a verb a machine can
  count; and among those 3 the fix:add ratio tracks the tree's *age* (0.4 : 1 at 16 versions, 2.7 : 1 at 85, 5.7 : 1
  at 436), not its diligence. So the disagreement is over whether release prose is for users at all — and our
  `CHANGELOG.md`, the most-edited file in this repo, answers "it is for the next engineer here", pointing a person
  deciding what to install at the release note instead (`CHANGELOG.md` header). That is a defensible position and it
  is also the position of 14 other trees, so it is not the field's default.

## The harness side is already built, on their side

Re-derive: the axis `wires a third-party coding agent to itself (code)`, serve segment (its in-segment list is
the twelve; the loop names the eight whose hits this section reads; `OC_AXES="wires a third-party"` re-runs it
alone).

```
for t in vllm sglang ollama omlx mlx-serve splash Rapid-MLX; do git -C ~/references/$t grep -l -I -i -E \
  -e 'ANTHROPIC_BASE_URL|OPENAI_BASE_URL|OPENAI_API_BASE|CLAUDE_CODE_|claude[-_]code|codex[-_](config|app[-_]server)' -- '*.py' '*.ts' '*.go' '*.rs' '*.swift'; done
```

**Eleven of the twelve serving trees score — we are the twelfth** (the axis printed 6/7 until the segment was
corrected today; § What this costs in `comparator-innovation.md` for the five trees that had been unlisted).
**Five of them were traced to product code this round** (the rest score on the pattern, and `OC_EVIDENCE=1`
prints one matched line per tree so any of them can be traced in one re-run) — `ollama` has a `Runner` per
(`cmd/launch/claude.go:15` "Claude implements Runner for Claude Code integration"); `mlx-serve` detects installed
agents on `PATH` through a *login* zsh so nvm/asdf/pyenv resolve the way the user's terminal sees them
(`app/Sources/MLXServe/Services/CLILauncher.swift:4-10`); `omlx` ships an `IntegrationsScreen`
(`apps/omlx-mac/Sources/AppView/Screens/IntegrationsScreen.swift:224`); `splash` writes client configs from its
installer (`install/clients.py`); `Rapid-MLX` renders its Launch page off a decoded registry whose kinds are
`config_writer` and `adapter_profile` (`apps/rapid-mac/Sources/Rapid/Server/IntegrationCatalog.swift:3-12`).
Two of the eleven score only on non-product code — vllm's hit is an example webserver script, sglang's a unit
test. The remaining four (`MTPLX`, `Strata`, `TensorFold`, `openclaw`) joined the segment today and have not
been read line by line. **We score nothing**: `/v1/capabilities` and `openapi.json` describe us to a client
that has to configure itself.

Why this is the round's real finding: root § Adoption says to spend on "a harness consuming us", and this says the
harness side is not an open research question in this field — it is a config file plus a detection routine that
five of our seven nearest trees already ship. `Rapid-MLX` goes one rung further and owns the risk that comes with
it: 17 harness configs, a reversible private profile (`isolated.py:23`, `--remove`), and `config_merge.py:1-15`
documenting the two ways a naive merge deletes the *user's* own entries (pi's id-keyed `models` list, dsh's
`cordis.patch.yml` layers). That docstring is the shape our § *Working here* "respect the person" rule wants: the
failure named before the code, in three lines.

## Where the field confines a child

Re-derive: axis `OS confinement profile for the child (code)` with `OC_EVIDENCE=1`.

The honest count is **five of the 14 agent trees**, not the 8/14 this instrument first printed — see § The ledger.
And the read is more useful than the count: **confinement shows up wherever a tree runs code it did not write.**
`codex` confines the model's shell (its exec processor carries the landlock feature flag,
`codex-rs/app-server/src/request_processors/command_exec_processor.rs:310`); `qwen-code` builds a landlock relay
(`esbuild.config.js:304` → `packages/core/src/sandbox/landlock-relay.ts`); `openclaw` resolves `sandbox-exec` in
its macOS app (`apps/macos/Sources/OpenClaw/ExecCommandResolution.swift:443`); `deepseek-harness` states the rule
in a test name — "bwrap on Linux, Seatbelt's `sandbox-exec` on macOS. Without one the strict …"
(`apps/cli/tests/profiles/acp/tests/escalation.e2e.ts:44`); `Strata` isolates generated Python with bubblewrap in
its grader and names the escape hatch and its condition in the same breath
(`strata_cli/launch/harness.py:174`).

Two of those are the pattern for **our** open child-process item, and both are about *other people's* processes:

- `TensorFold` spawns an MCP child under `/usr/bin/sandbox-exec -p <profile>` with per-config read roots, and when
  no profile can be built it **refuses** — `No supported MCP process sandbox is available on this platform. Use
  Docker Gateway or set …=1 only for deliberate unsandboxed local development` — while the spawn spec carries
  `sandboxed: true|false` so the state travels with the result
  (`app/electron/agent/mcp-process.ts:173-186`). Refusal with a named way out, plus the flag in the wire shape:
  invariants 1 and 2 in one function.
- `Rapid-MLX` will not *score* what it cannot confine: no `sandbox-exec`, no grade
  (`scripts/benchmark_glm53_real_tasks.py:226-228`).

Our position on that axis is nothing — no `seatbelt`/`sandbox-exec`/`landlock` symbol in `Sources/**` — and the
11-04(4) round already proved the premise that makes it matter here: a child we spawn inherits this server's whole
environment, keys included (`open-items.md` § A child process inherits the server's whole environment). Nothing
here writes a guard; that item is an owner call and now carries two shipped precedents with cites.

## The field's own trend

Re-derive: the TREND block the script prints after the axes (cadence in four 30-day windows, tags *minted* per
window, and concept heat over `OC_TREND_DAYS=60`).

- **Cadence is not our gap; release cadence is.** Field mean over the last 60 d is 4 058 commits/tree, ours 764 —
  but the distribution is a long tail with `openclaw` (19 835 in 30 d) and `hermes-agent` (12 256) at the front.
  Against the tree that ships our own sentence, `Rapid-MLX`: **771·535 commits** to our **523·241**, and
  **29·22 tags minted** to our **1·0**. Same order of work, two orders of magnitude apart on the thing a stranger
  can install. That kills the "we are too busy building" reading of § Adoption's cadence row: publishing is not
  capacity, it is a decision per merge.
- **21 of the 23 installable comparators minted a tag in the last 30 days.** The two that did not: `MTPLX` (which
  went from 827 commits/30 d to **0** — the MTP-for-MLX comparator has been quiet for a month, so our MTP lane now
  has no active sibling to read) and `harness2` (a 21-commit research drop).
- **Concept heat says nothing in this corpus is dormant, so heat ranks nothing.** Every axis printed
  present = edited-now (14/14 rules readers, 12/12 serving trees on KV, 12/12 deferred-tool trees, **8/8 ACP
  speakers**). The useful reading is therefore the *minority* axes: the ones where few trees hold the mechanism and
  all of them are editing it — confinement (6/14 scored, honest read 5, 5/5 editing) and, as of today, the
  host-device route (3/12, 3/3 editing, § Where the field disagrees). **The harness-wiring seam left
  this class when the segment was corrected**: it is 11/12, so it is not a minority practice we are early on,
  it is a near-consensus practice we alone skip (§ Direction 3). A practice that is both minority and
  unanimous-actively-worked is a direction; a practice at 14/14 is table stakes and further spending there
  buys a claim, not a user.
  **Corrected twice within a day — full account in `comparator-evolution.md`:** this reading is presence-weighted
  (a file touched once and one touched 200× both count 1), and that part holds — heat cannot rank a saturated axis.
  The surviving statement is narrow and both instruments are demoted on the authority axis: **confinement** really is
  quiet (shipped by a few, edited by none), and **approval** is invisible to any path pattern (0/13 by churn, ~15 %
  of every bullet the deepest ledger has carried), which is a fact about the instruments, not about the field.

## What the field is evolving into, and what its ledgers say

Both cuts moved out to `comparator-evolution.md` — churn by concept (touch-weighted, 13 agent trees) and the
release-ledger ladder — because putting them here put this file 5 278 B past its per-file cap; the
alternative was deleting evidence to fit a number no loader charges. The headline numbers, so a reader
can decide whether to open it: in the agent segment **surface is >= 10 % of own churn in 11 of 13 trees, measurement
in 9, the agent loop in 3**, and the serve segment **inverts** it — `engine` in 10 of 11, surface in 7, ours clearing
that floor at 17 % while its 10 % `deps` share (one file: the diary) is the segment's only one. Authority is invisible
to churn in *both* segments, so nothing about it may be concluded from churn; and **14 of 29 trees publish no
changelog at all**, while the deepest one — 436 versions, 8 668 bullets — runs 5.7 : 1 fix-to-add, is 66 % Fixed, and
recorded approval as its second-ever entry and language at #429.

## The injected ruleset

Re-derive: `for t in ~/references/*; do git -C "$t" grep -l -I -E -e 'AGENTS\.md' | grep -cE
'\.(py|ts|go|rs|swift)$'; done` — **21 of 28 trees' source mentions `AGENTS.md`, and all 14 agent-segment trees
do**, so our loader's two candidates in order — `AGENTS.override` then `AGENTS.md`
(`WorkspaceContext.swift:34` carries the literals) — are standard-aligned, not a local habit. 12 of the 28 also name `CLAUDE.md` in code, and `hermes-agent` turns that into
ordered precedence — `_CONTEXT_FILES = ("AGENTS.md", "CLAUDE.md", ".cursorrules")`
(`references/hermes-agent/agent/coding_context.py:38`) — then tells the model that what is already in context wins
over its defaults (`:104`). `goose` does what we do, one name (`crates/goose/src/hints/load_hints.rs:11`).

Context economy, ours 10-29 / field 10-28 plus 11-04, over each tree's own `AGENTS.md` set — **root bytes / corpus
bytes / deepest root→cwd chain against the 32 768 B our loader injects at**: mlx-serve 26 486 / 269 381 / **69 273
(211 %)**, deepseek-harness 19 113 / 96 369 / 55 362 (169 %), opencode 15 102 / 86 866 / 37 627 (115 %), openclaw
19 374 / 113 906 / 34 186 (104 %), **ocoreai 21 443 / 47 474 / 32 743 (100 %, 25 B of headroom)**, vllm 6 358 /
48 844 / 31 675, hermes-agent 11 952 / 159 599 / 30 192, Rapid-MLX 19 438 / 19 438 / 19 438 (59 %), pi 8 845,
codex 0 / 3 441, ollama 358. Re-measure: walk the tree for `AGENTS.md`, sum each file's ancestors up to the root,
divide by 32 768 — the semantics our loader implements (`Sources/ocoreai/WorkspaceContext.swift:224-233`). Four
trees read a ruleset their own loader truncates and three never say so; ours is 25 B from that line and names what
it drops.

Two shapes, not one: everyone else chains per-directory guides, and `Rapid-MLX` puts **an org chart** in a single
root file — six persistent roles (`AGENTS.md:3`, the table at `:11`), each with a default host, a worktree prefix,
an escalation target and its own *definition of done* (`:55`), 19 438 B, 59 % of our cap, with no per-directory
guides anywhere in its 4 232 tracked files. It buys role ownership instead of area locality, and it never has to re-measure a chain. Worth
knowing the option exists before assuming the chain is the only shape.

Consequence, named not taken: honouring an arriving stranger's existing `CLAUDE.md`/`.cursorrules` is rung 2 of the
footprint ladder — an entry appended to a list that already *is* the precedence seam, with AGENTS.md still first.
It changes injected context, so it is priced by the board, and the gate pattern already exists (`reasoning_effort`'s
honesty gate). **Owner call; nothing here changed model behaviour.**

## Where we are ahead, so further spending is mispriced

- **Publishing the contract is not the consensus — vLLM turns it off.** Three serving sites build
  `FastAPI(openapi_url=None, docs_url=None, redoc_url=None)`
  (`references/vllm/vllm/entrypoints/launchers/app.py:36`, `references/vllm/vllm/entrypoints/cli/preload.py:74`,
  `references/vllm/vllm/entrypoints/launchers/dp_supervisor.py:220` — the middle one was written here without its
  `vllm/entrypoints/` prefix, which resolves to nothing; re-pinned 11-04); sglang reserves a switch
  (`references/sglang/python/sglang/srt/entrypoints/http_server.py:501` — `/openapi.json` unless
  `DISABLE_OPENAPI_DOC`); only ollama commits a spec file besides us (2/12), and a published client package is
  2/12 (`sglang`, and `openclaw`, which joined the segment today). So a
  **generated client is our bet, not a field expectation** — the evidence behind the owner's standing caution that
  "a public contract is a promise" (root § Adoption).
- **Depth we already exceed:** notices (43 files vs 17/24 having any manifest), probes (58 of the 23/24 that ship
  any), evals, and a rules budget the field does not keep at all — four trees load a ruleset bigger than their own
  loader's cap and three never say so (§ The injected ruleset). Adding a fifth verification discipline buys a
  claim, not a user.
- **A store shelf is not the field's habit either** (2/24), so the `appStore` build trait is not a catch-up item
  pretending to be one.
- **Digest verification exists where we own the bytes**, gated by `DownloadIntegrityTests`(10) + probe 43; the open
  half is upstream's (`HubClient` carries an ETag, not a weight digest) — see the corrected Strata row.

## One more thing the field measures that we do not

`Strata` prices **each harness it launches**, in the text it shows the user: opencode's "system prompt and tools
take about 7.4K tokens of the window", codex's "about 8.6K", plus the premise its own limit depends on ("`strata
connect` sets `limit.input`; without it OpenCode never compacts its conversation")
(`strata_cli/launch/harness.py:165-176`). `mlx-serve` carries an `AgentBudget` module
(`app/Sources/MLXServe/Services/AgentBudget.swift`). That is our § Open injection row — "injected bytes cost a
2B checkpoint double-digit pp" — measured from the *other* side: the cost of a caller's own prompt+tools, per
caller, published. The third instance prices it *per tool*: `Rapid-MLX` gives every registered tool a risk class
and debits the context budget only for the non-read classes (`bounded_result(…, debit_context=spec.risk not in
{"read_only","read"})`, `rapid_mlx/chat_runtime/tools/__init__.py:70-81,318-331`), so the cost of handing the turn
a capability is charged where the capability is declared rather than measured afterwards in aggregate. We advertise
40 tools, score 6 on the board, and price bytes per row — never per risk, never per caller. That is an axis, not
yet a task.

## Direction — ranked by what the consensus actually says

1. **Cadence, not depth, is the measured gap, and it is a decision not a capacity limit.** 21/23 installable
   comparators ship monthly; against the tree building our own sentence we match on commits and lose 29·22 to 1·0
   on tags. Rung zero already says this; `scripts/audit-facts.sh` prints the field's release counts and
   `comparator-consensus.sh` now prints tags next to commits so the pair is visible at once.
2. **A typed install route is the field's majority (16/24) and we have none** — no brew formula, no `curl | sh`,
   no npm. omlx's quartet (DMG, auto-update, `~/.omlx/bin` shim, self-serve tap whose optional-kernel flag
   *degrades instead of failing*) remains the concrete shape; it is one `Formula/` file plus a publish leg CI
   already rehearses.
3. **Ship the harness side** (§ The harness side): **11 of 12 serving trees do it and we are the twelfth**; one owns the merge-safety
   problem in writing, and it is the rung root § Adoption says to spend on. Cheapest honest slice: the
   `launch <agent>`-equivalent for one harness, reversible, with the non-destructive-merge rule copied from the
   docstring above.
4. **Skills and deferred tool loading are the same economy** (median 14 SKILL.md against our 1; 12/14 agent trees
   defer or filter the tool surface) and we hold the problem — 40 advertised, 6 scored — without the mechanism.
5. **Put the child boundary on the owner's table with its precedents** (§ Where the field confines): TensorFold's
   refuse-and-name-the-exit with the flag in the result, Rapid-MLX's no-grade-without-confinement, and
   deepseek-harness's three-mode file-effect policy. Present it as **acquiring a shipped property, not out-building a
   frontier** — confinement churn is ~0 in every tree including the one that ships four packages of it — but pair
   that with the ledger's other half, or the framing misleads: whatever boundary we ship, the *approval* surface
   around it is a permanent ~15 % of the work, not a thing that lands once — 196 of 436 releases, recorded in
   `comparator-evolution.md`. It stays an owner call, not a task.
6. **Do not chase the contract-client pairing as "standard practice"** (contract 2/12, client package 2/12), and do
   not chase depth: § Where we are ahead. One honest carve-out: a contract can be load-bearing *internally* without
   ever shipping as a package — `opencode`'s own CLI fetches `/openapi.json`
   (`../references/opencode/packages/cli/src/commands/handlers/api.ts:72`) and its smoke test asserts the unauthenticated
   route refuses (`../references/opencode/packages/cli/script/service-smoke.ts:53,67`). "No published client" does not
   mean "nobody consumes the spec"; ours is rendered and unconsumed, which is the half worth noting.
7. **Language coverage is a split in the field, not a direction — so it is priced and not scheduled.** The
   localizing half (`hermes-agent`: nine locales behind a completeness gate; `opencode`, `qwen-code`, `OpenHands`,
   whose locale tables rank among their hottest files) and the not-bothering half — the deepest ledger in this corpus
   records locale **twice in 436 releases, first at #429**, next-to-last in its entire history. We ship two complete
   tables and advertise exactly those two, which sits us in the first half without pretending to nine. Filling
   `ja/ko/fr/es` is enumerable work with no observed request from anyone who asked, so: recorded as a gap, **not**
   scheduled, and `availableLocales` stays restricted to what has a table, which is what keeps it a gap and not a lie.
8. **ACP is a measured majority we sit outside** — 8/14 agent trees speak it, 8/8 of those are editing it, and its
   arrivals here are dated 03-14 → 10-13, so the spread is open (§ The protocol that spread in
   `comparator-innovation.md`). It stays an owner call: an inbound wire is ladder rung 6, and the
   consumer-with-a-name test is **not** met on this box — no editor ran us, and the client lists are comparator
   claims (§ Upstream 5). What the round changes is the shape of the ask: ACP's `session/request_permission`
   primitive is an *external consumer of the destructive truth we already keep in one home*
   (`ToolEntry.isDestructive` → `securityPrecheck`), so the cheapest honest slice is an adapter over that gate,
   never a second approval mechanism.

## The ledger: false positives that would have become claims

Every one of these was read before it was written down, and each is a count that was wrong until someone opened
the file — the reason the row-by-row cites above are the artefact and the counts are the summary. `OC_EVIDENCE=1`
now prints one matched line per tree so the next one is caught by a reader, not by a round.

- **`job.?object` read as "this harness sandboxes its shell."** The confinement axis first printed 8/14 and the
  evidence flag showed goose's match to be `CreateJobObjectW` + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` — killing a
  process tree on close, not a sandbox (`crates/goose/src/agents/platform_extensions/developer/shell_process.rs:100`)
  — pi's a comment about EACCES under someone else's seccomp policy (`packages/tui/src/terminal.ts:51`), vllm's and
  sglang's container-environment notes, hermes-agent's a docstring mentioning firejail inside an update-lock
  message (`hermes_cli/update_lock.py:483`). The escape was dropped from the axis; the count became 6/14 and the
  honest read 5. A pattern that matches a real word in the wrong role is worse than one that matches nothing,
  because it prints a confident number.
- **Bare-name coupling is substring-naive in both directions.** `cline` scored 7 hits in `Sources/`/`Tests` from
  words like "decline", so the registry's "eleven of 27 carry zero name coupling" was right about cline only by
  accident; with `-w` the number is **twelve of 28**. The measure is pinned to `-w` in the registry now.
- **Our own `Client/` directory is not a published SDK.** "codegen or published client" once scored us on
  `Sources/ocoreai/Client/DirectInferenceClient.swift`, an in-process lane. The axis now requires a *package*, and
  the honest count is 2/12.
- **We have no deferred-tool mechanism.** Our 2 hits are a static allowlist test name
  (`Tests/ocoreaiTests/CheckToolsTests.swift:44`) and a comment *describing codex* (`scripts/eval/_eval.py:214`).
- **"Installs in one command" was once matched by the word `.dmg` anywhere in a README**, which scored our
  conditional double-click path as a package-manager route. The axis is split in three now (typed command / store
  / artefact); the narrower half is where we sit at zero.
- **A "tightened" pattern using `\b` matched nothing at all** — POSIX ERE leaves it undefined — so `rewind`
  reported 0/28 including the trees that ship rewind. It would have read as "the field does not do session
  recovery". The un-anchored form says 26/29.
- **A *significance* floor used as a *liveness* floor printed a dead axis that was alive.** The churn block first
  demanded ≥ 10 % of a tree's own churn before a bucket counted, and `authority` scored **0 of 13** — reported
  internally as `INSTRUMENT-DEAD`, and one sentence from becoming "the field does not work on governance". The
  evidence flag showed the bucket had been matching the whole time: 33 distinct paths under
  `codex-rs/core/src/guardian/` were edited in the same window (against 27 files there on disk now), and
  deepseek-harness's four `packages/sandbox/*`. Shares were being squashed by denominators of 100 k–490 k touches, which is a statement
  about effort, not about existence. The floor now splits in two: the tally may use a share, the vacuity check uses a
  **file count of zero**. Two questions, two numbers — a threshold on magnitude can never certify presence.
- **Two axes were missing because nobody thought to pattern them, and the residual column is what caught it.** The
  first cut had no bucket for localization or for lockfile/release churn, and `unmatched` came back at 12–59 % per
  tree. Reading the actual hottest files then showed locale tables as the single most-edited file in four trees. An
  axis nobody writes a pattern for is indistinguishable from an axis nobody works on — so `unmatched` is now printed
  per tree rather than absorbed into the totals, and it is the number to watch before believing any share.
- **The worst error in this round was a cite I invented, and the only reason it died is that I went to look.** I
  wrote "`openclaw` ships seven `packages/sandbox/*`" — wrong tree (it is `deepseek-harness`) and wrong count (four
  packages, 92 tracked files). Neither number was obtainable from what I had: the evidence dump aggregates paths
  across trees without labelling the owner, so the count was a guess dressed as a measurement, and no gate in this
  repo could have caught it — `upstream-cite-check.sh` proves a cited line exists, not that it belongs to the tree I
  named. `git ls-files | grep -c` in the named tree is 200 ms and settled it. Comparator cites are
  content-unverified-by-construction; this is the second time that distinction has saved a false claim here.

- **Three porting bugs in the ledger block, each of which printed a confident wrong number.** (i) A changelog is
  written **newest-first**; the port forgot to reverse the release list, so "first release to record each axis"
  reported the *newest* release as #1 and made fifteen axes look like they shipped on day one — the throwaway script
  had the reverse, and re-typing the logic dropped it. (ii) The largest-ledger loop leaked its `body` variable into
  the ladder block, so the sequence printed under `claude-code`'s name was parsed from whatever file the loop touched
  last: 2 releases where 436 exist. It was visible only because the heading and the data disagreed. (iii) A `guard`
  token in the confinement pattern matched `codex`'s `guardian/`, which is its **approval** subsystem
  (`approval_request.rs`, `permissions.rs`, `score_authorization.rs`), moving 7 % of that tree's churn onto the
  opposite mechanism from the one the prose then claimed. All three die the same way: carry label and data in one
  tuple, print the premise beside the number, and open one file before quoting a bucket. None of the three would have
  been caught by a green run — every one of them exited 0.
- **The instrument's *denominators* were the likeliest lies in this file** — bullet 5 above, once for the measure
  and once for the counts.
- **The likeliest lie was a denominator that was also a hand-typed list.** `serve` declared 7 members while five
  serving trees sat on the disk, so 6/7 meant 11/12 and a § Direction item was under-priced for the life of this
  file; the account (five trees, five route lines, two adjudicated non-members) is `comparator-innovation.md`
  § What this costs, and `SEGMENT-AUDIT` now prints the candidates so the next clone cannot be missed the same way.
- **`sqrt_acp` — three ACP patterns, three wrong answers.** `[^a-z0-9]` treated `_` as a non-word character
  and scored `Rapid-MLX` off a diffusion sampler's `sqrt_acp`; treating `_` as identifier material fixed that
  and dropped OpenHands' real `acp_server: "claude-code"`; widening to `acp.`/`RequestPermission` then scored
  `codex`, `Strata` and `mlx-serve` on their *own* permission code, which is not the protocol. A three-letter
  token in a polyglot corpus has no decidable boundary, so the axis now asks the question a reader can check:
  does the tree name the protocol or import its package. Every broken version printed the same 8/14 —
  `OC_EVIDENCE=1` is the only thing on this box that could see the difference.

## Pointers

- Per-tree axes and what to borrow: `comparator-repos.md` (28 rows, one per tree on this box).
- Who holds a mechanism alone, and did it spread: `docs/agent/comparator-innovation.md` (the DIFFUSION cut,
  the dated arrivals, the per-tree signature table, the serve-segment account).
- The time axis, with the three instruments that disagree: `docs/agent/comparator-evolution.md` — churn by concept
  and the release-ledger ladder, plus the two claims this file had to take back.
- The ladder these numbers feed: `long-horizon-goal.md` § Rung zero; the install machine's four parts:
  `adoption-runbook.md`; the harness-consumer rung: root § Adoption.
- Why a mirror cite is content-unverified even when the anchor resolves: `competitor-iteration-paths.md` § What
  that gate does not see.
