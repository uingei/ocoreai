# Long-horizon goal — the four numbers, the ladder, and what would kill it

> Long form behind the active goal's first rung. The objective is not a feature list: it is **the cost of
> turning a change into a fact**. Everything here is re-computable with the commands quoted next to each
> number; a number that cannot be re-run is not a target, it is a slogan.

## The objective

Make ocoreai a machine that converts *change* → *fact* cheaply and cannot move its own goal posts:

**B** provable-improvement bandwidth ↓ · **C** verdict cost ↓ · **G** goal-post write surface = 0 · **S**
claim coverage → 1.0. The product surface grows only where a gate already measures it (§ *Two invariants*).

## Today's baseline (re-measure with the command on the right)

| # | quantity | value | how to re-measure |
|---|---|---|---|
| B | smallest provable improvement | **6 discordant cells** | exact sign test at the shipped α: `mcnemar_exact(b,0) < 0.05` first holds at b=6 (b=5 → 0.0625) — `scripts/eval/_repeat_stats.py` |
| B′ | tasks that can produce a cell | **14 of 52** (21 pass, 17 fail); adjacent k=6 windows moved 7/48 bands, so ±4 is noise | `_repeat_stats.py` on the base root; ledger in `scripts/eval/README.md` |
| C | cost of one verdict | **≈28.7 min** at 52 tasks (4.79 min/run × k=6, base reused) — one run costs 4.8 min, so a ≤3 min/proposal target is throughput-bound, not orchestration | `stat -f %m /tmp/oc-k6-f52/run-*` → deltas |
| G | goal-post write surface | **0** (allow = 1 prefix, protected = 15 judgement paths) | `scripts/eval/autoloop-allow.txt` / `autoloop-protected.txt`, gated by `scripts/eval/_autoab_selftest.py` + `_autoab_mutate.py` |
| S | claim coverage | incomplete: doc claims reproduce, 36 live probes; gaps = MTP acceptance rate (0 sites) | `make docs-check` + the gap list below |

**Why B is the constraint**: stable-pass tasks give *no* upward evidence yet *can* trip the regression veto, so
the shape is asymmetric on purpose, and **≈0.5 tasks is not measurable at any α** — that effort is not
conservative, it is invisible. Per-window numbers: `scripts/eval/README.md`.

## The ladder

1. **Resolution first** — critical-task share 6 → ≥12: **met, 14 of 52** (k=6, 29-31, SD 0.89). Structured
   output is on the board; probe 12 fails open-ended (3/6 never close), while §6 (grammar + tools in one turn)
   now delivers 3/3 with tools on both shapes, pinned fail-first; §7 keeps the grounded half open — a
   read-turn cannot emit the call its JSON integers come from. Guessing p from last window's rates added nothing (8 instances: three at
   6/6, five at 0/6); screening at k=3 and freezing only the mid-band ones took B′ 9 → 10 → 14 while 7/48
   bands moved on their own — **a window statistic, not a set property; no criterion moved.**
2. **Beat** — C 12 min → ≤3 min: engine stays warm across proposals, contract-class changes judge at
   k=1 by byte-exact gates (they are decidable, so they must not spend statistical budget). *Failure
   signal*: the floor is inference throughput, not orchestration — that is a quantization/kernel job, not
   a harness job.
3. **Coverage** — S gaps 3 → 0: publish MTP acceptance where MTP runs (or keep MTP off the capability
   face, which is honest today), disclose truncated structured output rather than 200 + invalid JSON, and
   the UI's focus/number rules are pinned (`UIFocusDisciplineTests`). *Failure signal*: a capability row that
   cannot name its measurement site survives a review cycle → the review, not the code, is broken.
4. **Anti-self-deception** — the mutation set only grows; each cycle re-proves the judges catch a real
   defect, not just a fabricated board. *Failure signal*: a mutation escapes.

## Rung zero — adoption (the third kill criterion has fired)

"S = 1.0 with no adoption" is measured, not felt (2026-10-26, `api.github.com` — HEAD's only authority;
a mirror proves content, never HEAD): `openclaw` 393 101 stars / 82 643 forks, `opencode` 222 704 / 29 649
(**408 stars/day** over 544 d), `claude-code` 153 415, `codex` 130 965 (233/day), `cline` 70 860, `goose`
55 732, `aider` 49 756 — and **ocoreai 1 star / 0 forks / 0 open issues / 7 DMG downloads across 3
releases**. The shape is the finding, not the gap: the field's best *sustained* growth is ~408/day, the
leader is at ~393k, so no honest engineering schedule reaches #1. #1 is a distribution event — bundled,
defaulted, or virally demoed — and the top four each sit on a machine that manufactures those (two model
vendors, one large ecosystem, one phenomenon with institutional amplification). Distribution therefore comes
first, and every rung below is falsifiable:

0. **Ship.** `make push-ready` said it in the project's own words: "8 commit(s) ahead of origin/main — **CI
   has not seen them, so they are unverified**." Pushed; the gate now reads "nothing unpushed".
1. **One release per tag.** `v0.1.14` exists on this host while the newest published release is `v0.1.13`,
   so the README's double-click path serves a build 15 days behind `main`. Gate to write: published
   release tag == `git describe --tags` at HEAD (`scripts/verify-installed-release.sh` is the harness);
   needs the owner's credentials — `gh` is not installed here, so this rung is the owner's, not ours.
2. **Sixty seconds to first token.** Honest today: `swift build -c release` (minutes) or an ad-hoc-signed
   DMG plus the Gatekeeper right-click. Rung = notarised artefact + Homebrew cask; the metric to floor is
   *clean machine → first completion*, one command, timed.
3. **Something to look at.** `grep -c '!\[' README.md` yields only the four badges: no recording, where
   every top-five coding agent leads with one. Capture machinery already exists (`GUI_REQUIRE_PIXELS`,
   `scripts/e2e-gui-app.sh`), so a real demo needs no fakery.
4. **A wedge the leaders structurally cannot copy**: offline on Apple silicon, one binary, no API key,
   native screen/camera/speech, MTP lane plus ANE constrained decoding — no comparator tree among 20
   combines them. Ceiling stated honestly: it is a *niche* wedge, and the leaders are cloud-led, which is
   both why they do not copy it and why it caps this ceiling. "Auditable, airgapped coding agent" is the
   framing with the larger audience.
5. **Amplification, then retention.** 82 643 forks against our 0 is not a code gap; it is a community
   machine, and it is fed by issue latency, not by gates.

What this does **not** mean: retire B/C/G/S. They keep claims true once attention exists; what changed is
the order of spending, because the objective's noun is the product, not the instrument.

## Kill criteria (checked, not felt)

- Two consecutive quarters with B and C unmoved → the bottleneck is model capability, not instrumentation:
  stop building gauges, spend on data/checkpoint instead.
- Any change the loop kept and a human reviewer then rejected → the criteria have decoupled from truth:
  revert to manual k judgement; while the instrument is untrusted, automation is a liability.
- S = 1.0 with no adoption → honest instrumentation has become a shelter, and the objective's object was
  the wrong noun.

## Not on this ladder

Weight-level self-improvement: interface kept, never claimed (no training pipeline here, and a 4-bit
checkpoint cannot be quietly upgraded into a claim). Multi-machine/MoE staging: outside the hardware
envelope this product ships in. Putting MTP on the capability face before an acceptance rate exists.

*Discordant cell* = one (task, matched run) pair where the two configurations disagree; pairing is
matched 1:1, never the A×B product (`scripts/eval/README.md`, where the numbers live).
