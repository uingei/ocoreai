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
| B′ | tasks that can produce a cell | **6 of 21** (14 stable-pass, 1 stable-fail) | per-task passes across the k runs of the frozen baseline — `_repeat_stats.py` on the base root |
| C | cost of one verdict | **≈12 min** (build 11.7 s, rest is inference at k=6) | `OCOREAI_AUTOAB_BASE=<root> bash scripts/eval/autoab.sh <patch>` and time it |
| G | goal-post write surface | **0** (allow = 1 prefix, protected = 15 judgement paths) | `scripts/eval/autoloop-allow.txt` / `autoloop-protected.txt`, gated by `scripts/eval/_autoab_selftest.py` + `_autoab_mutate.py` |
| S | claim coverage | incomplete: doc claims reproduce, 34 live probes, the UI capability matrix reads `RuntimeCapability.lines`; gaps = MTP acceptance rate (0 sites), structured output has no eval task, UI focus discipline has no test | `make docs-check` + the gap list below |

**Why B is the constraint**: 14 stable-pass tasks contribute *no* upward evidence but *can* trip the
regression veto, so the structure is asymmetric on purpose — a change must move most of the flaky pool
cleanly to be provable. Consequence worth repeating: **an improvement of ≈0.5 tasks is not measurable here
at any α**, so effort spent on it is not conservative, it is invisible.

## The ladder

1. **Resolution first** — critical-task share 6 → ≥12: replace stable-pass tasks with near-line tasks
   (same count, same cost, double the cell sources), and put structured output on the board so the
   `response_format` face has a task and a probe that fails open-ended (`scripts/probes/12-json-mode-delivery.sh`
   currently asks a two-key prompt with a 96-token budget). *Failure signal*: after reshaping, the base run
   still shows ≤6 flaky tasks → our model of where the model fails is empty.
2. **Beat** — C 12 min → ≤3 min: engine stays warm across proposals, contract-class changes judge at
   k=1 by byte-exact gates (they are decidable, so they must not spend statistical budget). *Failure
   signal*: the floor is inference throughput, not orchestration — that is a quantization/kernel job, not
   a harness job.
3. **Coverage** — S gaps 3 → 0: publish MTP acceptance where MTP runs (or keep MTP off the capability
   face, which is honest today), disclose truncated structured output rather than 200 + invalid JSON, and
   pin the UI's focus/number rules with a test instead of prose. *Failure signal*: a capability row that
   cannot name its measurement site survives a review cycle → the review, not the code, is broken.
4. **Anti-self-deception** — the mutation set only grows; each cycle re-proves the judges catch a real
   defect, not just a fabricated board. *Failure signal*: a mutation escapes.

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

*Discordant cell* = one (task, matched run) pair where the two configurations disagree;
pairing is matched 1:1, never the A×B product (see § *Measured, not asserted* in
`scripts/eval/README.md`, where the numbers live).
