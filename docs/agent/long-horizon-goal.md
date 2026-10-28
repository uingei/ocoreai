# Long-horizon goal — the four numbers, the ladder, and what would kill it

> Long form behind the active goal's first rung. The objective is not a feature list: it is **the cost of
> turning a change into a fact**. Everything here is re-computable with the commands quoted next to each
> number; a number that cannot be re-run is not a target, it is a slogan.

## The proposition the product is judged on

The instrument below keeps claims true; it is not the product. The falsifiable question: **on Apple devices,
can ocoreai finish real software-engineering tasks at acceptable cost, and on failure explain, recover and
verify?** Four axes, scored by the fixed task set (`scripts/eval/`) and its verifiers, never by the model's
self-report: **correctness** (the task's verifier, not the answer's prose) · **reliability** (the same task at
k repeats; recovery from a tool error, a stall, a model swap) · **efficiency** (wall-clock and tokens per
*verified* success) · **safety** (a side effect only inside the approval boundary, one auditable record each).
Acceptance = task success, outcome correctness, execution reliability, cost per successful task. Explicitly
not acceptance: lines of code, commit count, supported model count, architectural complexity.

## The objective (the instrument)

Make ocoreai a machine that converts *change* → *fact* cheaply and cannot move its own goal posts:

**B** provable-improvement bandwidth ↓ · **C** verdict cost ↓ · **G** goal-post write surface = 0 · **S**
claim coverage → 1.0. The product surface grows only where a gate already measures it (§ *Two invariants*).

## Today's baseline (re-measure with the command on the right)

| # | quantity | value | how to re-measure |
|---|---|---|---|
| B | smallest provable improvement | **6 discordant cells** | `mcnemar_exact(b,0) < 0.05` first holds at b=6 (b=5 → 0.0625) — `scripts/eval/_repeat_stats.py` |
| B′ | tasks that can produce a cell | set size, pass/fail split, noise band: `scripts/eval/README.md` (not restated here — a figure in two homes drifts) | `_repeat_stats.py` on the base root |
| C | cost of one verdict | minutes; the floor is inference throughput, so ≤3 min/proposal is throughput-bound, not orchestration | `stat -f %m` on the run dirs → deltas |
| G | goal-post write surface | **0** (allow = 1 prefix, protected = 15 judgement paths) | `scripts/eval/autoloop-allow.txt` / `autoloop-protected.txt`, gated by `scripts/eval/_autoab_selftest.py` + `_autoab_mutate.py` |
| S | claim coverage | incomplete: doc claims reproduce, 41 live probes; gap = MTP acceptance (0 sites); truncation disclosed, ungated | `make docs-check` + rung 3 |


**Why B is the constraint**: stable-pass tasks give *no* upward evidence yet *can* trip the regression veto,
so the shape is asymmetric on purpose — a sub-point effect is not measurable at any α, and that effort is not
conservative, it is invisible.

## The ladder

1. **Resolution first** — critical-task share ≥12: **met** (the share and its floors live in
   `scripts/eval/README.md`). Structured output is on the board and probe 12 still fails open-ended; §7
   keeps the grounded half open — a read-turn cannot emit the call its JSON integers come from. Screening
   criteria were tried against the mid-band tasks and **none moved B′ past window noise** (per-round
   windows: CHANGELOG).
2. **Beat** — C 12 min → ≤3 min: engine stays warm across proposals, contract-class changes judge at
   k=1 by byte-exact gates (they are decidable, so they must not spend statistical budget). *Failure
   signal*: the floor is inference throughput, not orchestration. Measured answer first — every agent
   tree here judges its loop against a fake or mock provider, so the floor moves by taking the model out
   of contract claims before it moves by making inference faster (`docs/agent/open-items.md`).
   **Landed 10-27(20):** `Engine/ScriptedInference.swift` + probe 37 decide that class at k=1 in ~4 s with
   nothing resident (`engineBackend: scripted`; the scoreboard refuses a replayed run), and CI runs it as a
   step of its own: green on the runner since 10-29 (4 s there, 2 s here), so the class is decided off-box at k=1.
3. **Coverage** — S gaps 3 → 0 (a fourth, silent instruction truncation, is disclosed since 10-29 and still ungated — rung 5's *Budget* half): publish MTP acceptance where MTP runs (or keep MTP off the capability face, which is honest today), disclose truncated structured output rather than 200 + invalid JSON, and the UI's focus/number rules are pinned (`UIFocusDisciplineTests`). *Failure signal*: a capability row that
   cannot name its measurement site survives a review cycle → the review, not the code, is broken.
4. **Anti-self-deception** — the mutation set only grows; each cycle re-proves the judges catch a real
   defect, not just a fabricated board. *Failure signal*: a mutation escapes. Measured floor for the board this
   rung judges by (10-27(22), k=3 over 39 tasks): one run is **±6 tasks (15.5 pp)**, so an unpaired Δ under
   9 tasks and a paired one under 6 clean flips are not evidence — which retroactively disqualifies several
   earlier rounds whose single-run deltas were read as improvement. It shows up across sessions too — the
   `docs=none` arm read 22.67 / 24.67 / 25.00 on 10-27 under byte-identical `tasks=`/`tools=` digests — so
   re-running one arm is not re-deriving one number, which is why `binary=` is a conditions field.
5. **What a turn is handed** — all three halves of the turn are priced, and the third is new. *Tools*
   (10-27(22)): handing the turn 40 tools instead of 6 cost **−18.8 pp** on the same 39 tasks (k=3, paired,
   McNemar exact p < 0.0001). *Text* (10-27(24), replicated twice): injecting this repo's ~21.5 KB
   `AGENTS.md` cost **25.00 → 16.33/39** (−22.2 pp, p < 0.0001; replicate −19.7 pp), the premise floor having
   proved the doc reached all 39 turns — per-turn instructions cost a small checkpoint roughly what handing it
   every tool costs, and the traces say why: the doc gets *edited* as if it were the task's file, and the tool
   call arrives as narration. The next slice is
   *selection* on both axes, not *registration* (curve, replicates, distillate: `docs/agent/open-items.md`). *Budget* (10-28, paid 10-29): the cap was hidden — the deepest chain sits at **98 % of the loader's
   32 768 B** (`make docs-check` prints `deepest-chain=`) and the injector cut the tail without a word; the cut
   is now named to the model and served on `/v1/capabilities` as `instructionBudget` (probe 03 judges it). *Failure signal*: a capability row that cannot name its measurement site
   survives a review cycle.

## Rung zero — adoption (the third kill criterion has fired)

"S = 1.0 with no adoption" is measured, not felt: 20 trees with stars, forks, age and stars/day in
`docs/agent/adoption-runbook.md` § The leaderboard (`api.github.com` — HEAD's only authority; a mirror proves
content, never HEAD), and **ocoreai 1 star / 0 forks / 0 open issues / 0 tags / 0 releases (10-29;
withdrawn assets left with them)**, 137 days old. The gap is not the finding, the *shape* is — and the arithmetic that used to
justify this section is **deleted, not softened (10-28(6))**: it read "the field's best sustained growth is
~408/day, so no honest engineering schedule reaches #1", yet `deepseek-ai/deepseek-harness` reached 263 687
stars 76 days after creation, and `Niko1221/Strata` 34 577 in 34 days (rates per tree: the leaderboard).
Neither elapsed time, star arithmetic nor throughput bounds #1 — the record is an eleven-week
distribution event — and what does is whether something outside this repo defaults to it: each of the top
four sits on a machine that manufactures one (two model vendors, one ecosystem, one institution-amplified
phenomenon), and two of the three fastest movers are institution-shipped. So distribution comes first, the
objective stays the wedge rank not the headline, the rungs that move a stranger's install decision this
quarter are 1 (a tag per merge) and 6 (be consumed), and the cheapest parts are still unpaid — Discussions
off, no homepage, `VISION.md` absent, 1 watcher. Every rung below is falsifiable:

0. **Ship.** Done, and askable: `scripts/ci-status.sh` never calls a question it could not ask green.
1. **Cadence, not one tag.** The eight installable trees publish 34 → 1 254 releases each, newest ≤8 d old
   (`bash scripts/audit-facts.sh` re-measures); this repo has **0 tags and 0 listed releases**
   (`git ls-remote --tags origin` empty, `/tags` and `/releases` both `[]`). The publisher needs no owner
   credential (the `release` job uses the runner's own `${{ github.token }}`), and the tag *is* the version
   (`scripts/version.sh`): the withdrawn line reached 0.1.13, so the number to type is **`v0.1.14`**,
   prepared on this host and never pushed. Two things ride on it: the trust signals a first
   screen can show are outputs of cadence (§ The first screen), and before self-serve publishing, build and
   publish must split — ours runs repository code inside the job holding `contents: write`
   (`competitor-iteration-paths.md` § The release cadence rule) — paid 10-29: `package.yml` builds the DMG
   and probe 41 judges it under `permissions: contents: read`, so a rehearsal cannot publish. What the
   runner proved: the delivery shape, a DMG that finishes a real turn from a fresh directory, and — first green
   main run, 10-29 — every leg, the three scripted steps at 4/3/7 s (a runner holds no weights,
   so no checkpoint tier ran there). Nothing in code separates HEAD from a release: `release` is tag-gated, and
   a tag is a hand, not a task.
2. **Sixty seconds to first token.** Honest today: `swift build -c release` (minutes) or an ad-hoc-signed
   DMG plus the Gatekeeper right-click. Rung = notarised artefact + Homebrew cask; the metric to floor is
   *clean machine → first completion*, one command, timed. First measured point: 22.1 s from a built DMG to
   one real completion with weights already cached (`scripts/e2e-gui-app.sh`, exit 0; run detail is the
   diary's). Not the rung yet: a clean machine also pays the first-run model download, and nothing here is
   notarised.
   The leader machine is four parts, each cited in `adoption-runbook.md`: a runtime-provisioning installer
   script, a self-serve tap/cask, **update inside the app** (ours only *notifies* — `Core/UpdateCheck.swift`
   returns a release-page URL to Settings; openclaw's mechanism is named in its own root —
   `appcast.xml`, `appcast-arm64.xml`, `appcast-x86_64.xml`, a per-arch feed the app polls), and a
   degraded-not-failed install.
3. **Intake, then a demo.** The premise here was wrong once already (`grep -c '!\['` counts Markdown image
   syntax the CLI trees do not use; re-measured as `<img>` plus media refs a recording is a product-tree
   habit, and capture machinery exists — `GUI_REQUIRE_PIXELS`, `scripts/e2e-gui-app.sh`). Corrected 10-28: 4
   `.github/ISSUE_TEMPLATE` forms and 4 `README.md` media refs now exist, so intake's first commit landed and
   the demo has not. Past templates the leaders run bots that close stale intake, keep locales fresh, and
   apply an **intake policy to AI-authored contributions** (duplicate-work check, no busywork, fail-closed, a
   human who defends it; `adoption-runbook.md` § The intake machine) — that is what 320 author emails in one
   14-day window costs. Our home for that policy is `CONTRIBUTING.md`, written when outside intake exists to
   apply it to.
4. **A wedge the leaders structurally cannot copy**: offline on Apple silicon, one binary, no API key,
   native screen/camera/speech, MTP lane plus ANE constrained decoding — no comparator tree here combines
   them. Ceiling stated honestly: it is a *niche* wedge, and the leaders are cloud-led, which is
   both why they do not copy it and why it caps this ceiling. "Auditable, airgapped coding agent" is the
   framing with the larger audience.
5. **Amplification, then retention.** 82 660 forks measured 10-28 against our 0 is not a code gap; it is a
   community machine, fed by issue latency and by the automation that keeps a large intake cheap
   (`adoption-runbook.md` § The intake machine) — none of it a gate on our own prose.
6. **Agents as clients — take this before any of the others.** The leader does not compete with a local
   engine, it *consumes* one: "Models and agent harnesses (Claude, Codex, local models) are plugins you can
   swap" (`../references/openclaw/README.md:20`), and ocoreai is the only tree here that is model *and*
   harness on one die, offline, no key. Half landed 10-28: `/v1/capabilities` serves `endpoints[]` (34 rows,
   `V1EndpointCatalogTests`) and `skills/ocoreai/` is published, probe 39 executing every marker against a live
   `serve` and a real checkpoint, so the claim carries its gate.
   Missing: a standard-format spec (OpenAPI) plus a generated client — an owner call, because a public
   contract is a promise about future releases — and the harder proof that a stranger's agent, handed only the
   skill, finds it and finishes a task. `scripts/probes/40-stranger-agent-skill-task.sh` is that instrument — a seeded note whose
   VALUE is reachable only by a live call chain, plus a negative control that must reject a wrong deliverable.
   Probe 39 executes the artefact; probe 40 is read by it.
7. **Editors as clients (ACP)** — the rung `docs/agent/open-items.md` already cites: goose ships
   `agent-client-protocol` 2.2.0 and hermes-agent an `acp_adapter`; a third surface is a new core
   surface, so it waits on the owner.

What this does **not** mean: retire B/C/G/S — they keep claims true once attention exists. What changed is the
order of spending, because the objective's noun is the product, not the instrument.

**The gate layer is frozen (10-28).** Measured, then cut (counts: CHANGELOG `gate-deletion-10-28`): one gate
commit per three product commits while `git tag` stayed empty. A new check names the red it was sampled
against and the reader whose action it changes, or nobody writes it. Freed attention has three addresses —
rung 1 (a tag-per-merge policy), rung 2's open half (whether 43 declarations suit a 4-bit checkpoint, priced
at −18.8 pp, owner call), and the measured gallery a first screen needs (§ The first screen).

## Kill criteria (checked, not felt)

- Two consecutive quarters with B and C unmoved → the bottleneck is model capability, not instrumentation:
  stop building gauges, spend on data/checkpoint.
- A change the loop kept that a human reviewer then rejected → the criteria decoupled from truth: revert to
  manual k judgement.
- S = 1.0 with no adoption → honest instrumentation became a shelter, and the objective's object was the
  wrong noun.

## Not on this ladder

Weight-level self-improvement: interface kept, never claimed (no training pipeline here, and a 4-bit
checkpoint cannot be quietly upgraded into a claim). Multi-machine/MoE staging: outside the hardware envelope
this product ships in. MTP on the capability face before an acceptance rate exists. And checks on the tidiness
of our own prose: that family went 10-28, and a check with no quoted failure and no named reader who acts on
its red does not get written again.


*Discordant cell* = one (task, matched run) pair where the two configurations disagree; pairing is
matched 1:1, never the A×B product (`scripts/eval/README.md`, where the numbers live).