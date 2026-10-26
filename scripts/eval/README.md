# Task-success scoreboard

`scripts/probes/` answers *is the wire telling the truth*. This directory answers the
mission's own question: **did the agent finish a real coding job on this machine?**

## The rule that makes it a measurement

Each task mutates a throwaway workspace and the verifier inspects **the workspace**, never
the model's description of its own work:

- `fix-syntax-error` passes when `python3 -m py_compile calc.py` succeeds, not when the
  answer says "fixed".
- `change-config-value` passes only when the port changed **and** its neighbours survived.
- `read-and-report` puts the token in a file and not in the prompt, so a correct answer can
  only have come from `read_file`.
- `no-fabrication-missing-file` fails if the answer quotes the token of a file that does not
  exist (AGENTS.md invariant 2: refuse honestly, never invent).

An answer that claims success while the file is unchanged scores FAIL. That gap — generated
content versus reliable action — is what this scoreboard exists to keep visible.

## Running

```bash
swift build --scratch-path .build-clt            # or the CLT route in the Makefile
bash scripts/eval/run.sh                          # boots its own serve, runs every task
```

Needs a real Metal device (same requirement as the probes) and runs unsandboxed: the tasks
require the agent to execute its own tools, so `OCOREAI_APPROVAL_POLICY` defaults to `auto`
here. Traces (prompt/response, answer, verify output, workspace path, usage per task) are
printed as a directory at the start of the run — read the failures, not only the score.

## What is floored, so a quiet pass is impossible

- the server must have a ready model (`probe_require_ready_model`) — never a silent skip;
- the pinned dependency checkout must be clean (inherited from `scripts/probes/_lib.sh`);
- ≥ `OCOREAI_EVAL_FLOOR_TASKS` (18) tasks loaded and ≥ `OCOREAI_EVAL_FLOOR_SPECS` (4) of the
  needed tools declared by `GET /v1/tools` — otherwise every task would fail for the wrong
  reason, which is a harness bug, not a model result;
- every count read back from `_eval.py` is proven to be an integer (`probe_require_int`, in
  `scripts/probes/_lib.sh`): `[ "" -lt N ]` is a bash *error*, not a comparison, so a task set
  the loader could not parse once printed "2 passed, 0 failed" and exited 0. The guard runs before
  the boot and self-tests on an empty value, because a floor on a non-number is no floor;
- tool schemas come from `/v1/tools`, so this directory holds no copy to drift.

## Every task leaves its artefacts on disk

`verify_rc 1` says the workspace is wrong, never what the produced file *said*, and the next task
wipes the directory. So each task writes `artifacts-$id.txt` into its trace dir (≤2 KiB per file,
≤64 KiB per task, byte counts and truncation marked), passes included — "it passed" is only
evidence once the shape is on disk. The writer is self-tested alongside the verifiers
(`snapshot_selftest` in `_verifier_selftest.py`): sabotage it and the run reports six defects and
exits 1, because a snapshot that silently came out empty would restore the exact hole it closes.

## The number it carries: a noise floor, not a score

Three identical runs on this host (10-22, `gemma-4-e2b-it-4bit`) scored **16 / 19 / 20**: mean 18.33/24 (76.4%),
SD 2.08, so a *single* run has a 95% CI half-width of **±4.1 tasks (±17 pp)** and an unpaired A/B needs **≥6
tasks moved** to say anything (paired McNemar, 8 discordant task-pairs this round, lands on the same 6). Four
tasks flip between identical runs — `fix-off-by-one`, `fix-syntax-error`, `make-failing-test-pass`,
`move-into-subdir` — while write/read/exec/honesty never flip: the loss is in multi-step repair, not in the tool
plumbing. Reproduce with `bash scripts/eval/repeat.sh` (writes `results.tsv` per run and `noise.json` for the
aggregate). **A difference below that threshold is not an improvement and does not go in `CHANGELOG.md`.**

## A run that never reached the engine is not a score

Measured 10-22: one run of `repeat.sh` lost **13 consecutive tasks in 4 seconds** to
`{"error":{"message":"Generation failed: Engine busy","code":500}}` — `finish=None`, ~68 ms each, usage empty —
because an abandoned request kept the inference lock for ~160 s. That run scored 7/23, the aggregator averaged it
in, and McNemar reported a **p=0.0032 "significant regression"** that was an outage, not a model.

The rule now enforced in code: a row whose usage carries `finish=None`, or whose response contains `Engine busy` /
`app_error`, is a **fault**, not a failure. `run.sh` counts faults into `faults.txt`, writes
`# invalid faults=N/<run>` into `results.tsv`, and exits 1 with `TASK SUCCESS NOT MEASURED`.
`_repeat_stats.py` refuses to average an invalid run (retroactively, via `finish=None`, for data written before
the marker existed) and prints the exclusion to stderr — quote it together with the number it changes.

A transport timeout is the same class, measured 10-23: in run 3 of the 30-task k=6 window
`make-two-tests-pass` died at `curl: (28) Operation timed out after 180010 milliseconds with 0 bytes received`,
and no row was written for it at all. That run's own line reads `TASK SUCCESS 23/29 (of 30 loaded; a refusal to
run is not a pass)` — it drops the task from its denominator — while `_repeat_stats.py` books a missing task as a
fail over the union of tasks, because a slot that silently disappears would slide the other runs out of the 1:1
alignment the paired test depends on. Two denominators, one rule: the run is not credited, the task is not excused.

Updated verdict after `replace_all` landed (see `CHANGELOG.md` 10-22(5)): over `k=3` valid runs
`edit-replace-all` went **0/3 → 3/3** — every attempt succeeded where none had, judged by the workspace — while
the aggregate stayed inside noise (A=`16/19/20` → B=`17/19/18`, mean −0.33, McNemar p=0.749). Both statements
are true and they are different statements: the scoreboard resolves a failure mode disappearing, not one task
being fixed. What was measured before that, kept for the record: the honest reading of the `edit_file` remedy A/B is: A=`16/19/20` → B=`20/20` after excluding one invalid run,
mean **18.33 → 20.00 (+1.67)**, nominal McNemar b=4 c=14 p=0.031 — from 2 valid B runs, with |A|×|B| run pairs
that are strongly correlated, and a single-run CI of ±3.6. That is **below the ≥6-task bar above**, so it is
recorded as promising, not as an improvement. The task the change was written for did not move:
`edit-replace-all 0/3 → 0/2`, with the model answering the *user* instead of retrying.

## What produced the number: the `# conditions` line

`# score 30/36  model X` is the line quoted into `CHANGELOG.md` and averaged by `_repeat_stats.py`,
and until now it carried no conditions. The denominator comes from a task file that gets edited, and
the tool set comes from `GET /v1/tools` on a server that gets rebuilt, so two runs printing the same
score may have been played under different rules — and `repeat.sh` averages whatever it finds.

So `run.sh` writes one line above the score:

    # conditions model=mlx-community/gemma-4-e2b-it-4bit tasks=tasks.json+3f2a… tools=6+9c11… \
      temperature=0.0 approval=auto concurrency=1 host=Darwin 25.4.0 arm64

`tasks` digests the file the tasks were loaded from (ids + prompts + verifiers); `tools` digests the
declaration set the model was actually handed — names, descriptions *and* schemas, order-insensitive,
plus the count — because that set is the instrument, and a reworded description is a different
instrument. The comparators that got this right record the same thing: ollama writes `corpus_sha256`,
`concurrency`, `epoch` and `cached_input_tokens` into every bench row
(`~/references/ollama/cmd/bench/decision.go:98`) and refuses warmup or concurrency for a case that
claims cache reuse (`:69`); Strata documents how a number is produced before it quotes one
(`~/references/Strata/docs/BENCHMARK_PROTOCOL.md`).

Recording is half of it, so `_repeat_stats.py` refuses:

- **inside one root** — a run whose fingerprint differs from the majority of its root is excluded,
  naming the field (`run-04: tasks tasks.json+a… → tasks.json+b…`);
- **across two roots** — a base/variant pairing whose *invariant* fields differ (task file, model,
  temperature, approval policy, concurrency, host) is reported with no p at all.

`tools` is deliberately not an invariant across roots: a proposal may edit precisely the tool
descriptions and schemas it is being judged on (AGENTS.md treats them as function-calling contracts),
so refusing there would stop the loop deciding the experiments it exists to decide. Movement there is
printed under the p and recorded as `declarations_moved` in `_autoab_gate.py`'s JSON, so a `keep`
never reads as if only the engine moved.

Measured over fabricated scoreboards (no GPU; `_conditions_selftest.py` = 25 checks, and these are the
same fixtures by hand):

| fixture | with the conditions line | with the line deleted (red sample) |
|---|---|---|
| 3 runs @ tasks-a + 1 @ widened tasks | `repeats 3 · mean 3.33/5`, run-04 excluded | `repeats 4 · mean 3.75/5` — +0.42 tasks bought by another task file |
| base @ tools v1 vs variant @ reworded tools | judged: p=0.0625, verdict carries `declarations_moved` | judged: the p says nothing about which contract moved |
| base @ model `mlx/probe` vs variant @ `mlx/other` | `no p reported — conditions differ on model` | judged as if another model were a code change |
| runs stating nothing | kept, and says `conditions none stated … not attributable` | identical |

A run that states nothing is kept, because an unknown is not proof of a difference — but it is counted
out loud, so a number averaged with pre-conditions runs carries that caveat instead of pretending the
comparison is clean.

What that buys on real runs: three live runs of the default set in one root (the first written before
the separator fix, so its `tools` digest covers zero declarations) come back as

    ⚠️  1 run(s) … EXCLUDED — conditions differ … run-01: tools 6+0ad61eed0ea0 → 0+e3b0c44298fc
    repeats 2 · tasks 36 · scores 23/24
    mean 23.50/36 (65.3%) · SD across runs 0.71
    single-run 95% CI half-width ±5.6 tasks (15.6 pp) — a smaller difference is noise
    stable-pass 23 · stable-fail 12 · FLAKY 1 (fix-boundary-comparison)
    detection: an unpaired A/B must move >= 8 tasks to clear 95% on one run each

i.e. the default set resolves **8 tasks**, not 1, per single-run A/B — every `±1 task` claim this
directory ever made was inside the noise it could not see.

## Status — and what it is not

This is a **scoreboard, not yet a CI gate**. A 4-bit local checkpoint has a hard ceiling
here, and wiring an unknown number into CI turns a ceiling into a fake regression. It goes
into `make test-ci` only once its number is measured, stable across runs, and recorded in
`CHANGELOG.md` with the run that produced it.

Task set: **24 tasks** (`tasks.json`), eight families — write / edit / code-fix / code-fix-with-tests /
read / exec / multi-step / honesty — each family floored (`_eval.py families`) so a family vanishing from the
set is a harness failure, not a smaller score. Add a task by adding one object to `tasks.json`; `verify` runs in
the workspace with `$OCOREAI_EVAL_ANSWER` (the final assistant text) and, where the expectation belongs to the
machine rather than the prose, `$OCOREAI_EVAL_EXPECT` computed from the task's own `expect_cmd`.

## The verifiers audit themselves first



`_verifier_selftest.py` runs before the server even boots: every task's `verify` must pass against a workspace
brought to the solved state by an independent reference solution, fail against the untouched one, and fail against
a fabricated answer. It earns its place — the first run found three verifiers of the form
`case "$ANSWER" in *"$EXPECT"*)` which, when `EXPECT` is empty, is `*""*` and matches any answer whatsoever.
A verifier that cannot fail is not a scoreboard entry; the empty-expectation guard is now part of those tasks.

A fourth scenario closes the distance between "cannot fail" and "cannot notice": every task whose solved state
mutates the disk must also name a **near miss** — right path, wrong bytes; right bytes, wrong path; one bound
shifted; the neighbouring setting collateral-damaged; the test assertion edited to bless the bug — and `verify`
must reject it. Coverage is asserted rather than trusted: a disk-mutating task with no near-miss entry is itself
a defect, so the rule cannot rot into an empty dict. Measured: `near-miss coverage 19/19 disk-mutating task(s)`
on the frozen set, `16/16` on `tasks.json`, 0 defects on both.

## The frozen edit-repair set (`tasks-edit-repair.json`)

`tasks.json` is the scoreboard; this file is the instrument for one defect class — multi-step
*repair* — so that a change to the edit contract can be judged against a quiet baseline instead of
against noise. It keeps the tasks that passed every run plus the ones that did not, and drops the
tasks whose verdict flipped between identical runs:

- 30 tasks with the default floors satisfied (`count 30 ≥ 24`, every family ≥ 2) — a drop-in for
  `tasks.json`, not a special case wired into the harness. Nine were added on 10-23 to widen the band a
  single A/B verdict draws on: seven new near-line instances of the families that were already flaky
  (`copy-with-prefix`, `transform-uppercase-copy`, `edit-delete-first-line`, `exec-count-words`,
  `fix-off-by-two`, `fix-wrong-index-key`, `make-second-test-pass`) plus the two `structured` tasks, copied
  byte-for-byte out of `tasks.json` so both sets judge the same `response_format` promise;
- baseline k=3 on `gemma-4-e2b-it-4bit`: **16/17/16, mean 16.33/21 (77.8%), SD 0.58**, single-run
  CI ±3.7 tasks (±17.8 pp); detection needs ≥6 tasks unpaired, or 6/6 discordant paired;
- `OCOREAI_EVAL_TASKS=scripts/eval/tasks-edit-repair.json bash scripts/eval/repeat.sh`.

Stability is a property of an *n*, not of a task set: the first window (k=3 over all 24) called six
tasks deterministic failures, and the window right after it called three of those six flaky. Either
quote the n with the word "stable" or drop the word.

### k=6 over 30 tasks: what the widening bought, and what it did not

Same host, same model (`gemma-4-e2b-it-4bit`), k=6: **24/22/23/22/21/22, mean 22.33/30 (74.4%), SD 1.03**,
single-run CI ±4.7 tasks (±15.6 pp). The mean fell against the 21-task window (84.9%) and the CI widened,
both for the same reason: the additions sit further from a ceiling than the set they joined.

| band | n | ids (\* = added this round) |
|---|---|---|
| stable-pass | 19 | the write/edit/read/exec/honesty staples, plus `edit-delete-first-line`\*, `exec-count-words`\*, `fix-wrong-index-key`\*, `transform-uppercase-copy`\* |
| near-line | 6 | `copy-with-suffix` 2/6, `exec-count-lines` 5/6, `fix-off-by-two`\* 4/6, `fix-wrong-key` 3/6, `make-failing-test-pass` 5/6, `make-two-tests-pass` 1/6 |
| stable-fail | 5 | `change-config-value`, `copy-with-prefix`\*, `json-object-closes`\*, `json-schema-report`\*, `make-second-test-pass`\* |

**The headline is a miss, stated as one: the near-line band went 6 → 6, not 6 → ≥12.** Four of the nine
additions landed at 6/6 and four at 0/6 — too easy or too hard, not near the line — while three old near-line
tasks (`edit-remove-line`, `fix-off-by-one`, both now 6/6) left the band as one entered it. The judgement
criteria were not moved to make the target look met; the target was aimed at, and missed by measurement.

What the widening does buy is direction with a named mechanism, which is the resource a paired test actually
consumes. All three `structured` tasks are 0, and probe 12 §5 says how the shape dies: 3 of 6 open-ended `json_object`
turns at temp 0 end `finish=length` with an unterminated document (`maxWSrun=11`, `maxRepeatRun=126`). An earlier
round of this file blamed Apple's whitespace ceiling for that class and pointed the next reader at
`maxWhitespaceCount` (this repo passes `std::nullopt` at `Sources/lib/CXGrammar/xgrammar_c_bridge.cpp:138`).
**That inference is retracted, not deferred**: Apple's 32 is
`coreai-models swift/Sources/CoreAILanguageModels/GuidedGeneration/ConstrainedGenerationSession.swift:27`, and the
lines above it say the session enforces it on the next-token mask "so it does not enlarge the compiled grammar" —
so a bound that bites at 32 whitespace characters cannot touch a run measured at `maxWSrun=11` whose repeated
bytes are digits inside a string value. The tasks' actual blocker is grounding, measured where the whitespace story
was: with `response_format` and `tools[]` on one turn the turn cannot emit the read, so §7 of probe 12 answers
200 with schema-valid integers the file never stated (fixture `shape 47 by 13`; answers `rows":10,"cols":10`).
That is a loop property — the grammar would have to change between iterations — not a mask, and not more tasks.

Measured again in the round that fixed §6 (`bash scripts/eval/run.sh`, 36 tasks, k=1): **22/35**, and all three
`structured` rows still verify-fail with their bytes retained — `json-object-closes` `{"word":"note.txt","chars":8}`,
`json-two-integers-closes` `{"cols":5,"rows":10}` against a file reading `shape 3 by 5`
(`finish=stop prompt=986 completion=16 echoed_tool_calls=0`), `json-schema-report` likewise. The grammar is no longer
the part that fails; the part that fails is that nothing read the file.

`make-second-test-pass` is 0/6 for a reason worth naming rather than burying: the turn ends "The execution
failed because the `python` command was not found. I will try using `python3` instead." and no repair lands after
it. That is Execute → Verify → Recover failing at Recover against a self-explanatory one-line environment error,
so the verdict is honest — but it is measuring recovery, not file editing, and should be read that way.

### k=6 over 37 tasks: the band went 6 → 10, and a leak's worth of cells got priced

Anchoring on measured rates instead of intuition moved the number: same host, same model, k=6 over the
37-task set — **25/23/22/22/23/23, mean 23.00/37 (62.2%), SD 1.10**, single-run CI ±5.8 tasks (±15.6 pp).

| band | n | ids |
|---|---|---|
| stable-pass | 17 | the write/read/honesty staples plus `edit-replace-all`, `exec-count-words`, `fix-off-by-one`, `fix-typo-variable`, `transform-uppercase-copy`, … |
| near-line | **10** | `copy-with-suffix` 2/6, `edit-delete-first-line` 5/6, `edit-remove-line` 4/6, `exec-count-lines` 5/6, `fix-boundary-comparison`\* 5/6, `fix-off-by-two` 4/6, `fix-wrong-index-key` 5/6, `fix-wrong-key` 3/6, `fix-wrong-key-decoy`\* 2/6, `make-two-tests-pass` 1/6 |
| stable-fail | 10 | `change-config-value`, `copy-with-prefix`, `copy-with-suffix-token2`\*, `exec-sum-column`\*, `json-object-closes`, `json-schema-report`, `json-two-integers-closes`\*, `make-second-test-pass`, `make-third-test-pass`\*, `multi-step-two-derived-writes`\* |

**Target ≥12, measured 10.** Two widenings in a row missed it, and the reason is visible in the rows:
five of the seven new tasks landed at 0/6 — inheritance from a marginal family is not a guarantee, because
the marginal family's rate belongs to a *specific* mechanism, and several new instances asked for one more
step than the task they were modelled on. Two of the ten near-line tasks are also new arrivals that were
stable-pass in the previous window (`edit-delete-first-line` 6/6 → 5/6, `fix-wrong-index-key` 6/6 → 5/6),
so band membership is a property of the window as well as of the task: never quote the word "stable"
without its n.

What the same window paid for unintentionally is worth more than the count. `copy-with-suffix` carries its
answer in the prompt and scores 2/6; its clean twin `copy-with-suffix-token2` (same mechanism, token only
on disk) scores **0/6**. That prices the leak at two cells on this checkpoint, and it says the honest thing
about the old number: the 2/6 was partly a dictate-and-write rate. Fixing the leak should therefore be
expected to *lower* the scoreboard, which is a good reason to do it and a bad reason to leave it.

The structured family also narrowed its own diagnosis, and the cheapest measurement it asked for is now
shipped: probe 12 §7 sends exactly this shape (json_schema `rows`/`cols` + the six eval tool specs + a file whose
numbers appear nowhere in the prompt) and it is 0/3, `finish=stop`, schema-valid, integers fabricated. So the defect
is not "long documents run away" and not the whitespace mask either: **a turn that must call a tool and then close a
grammar is where it breaks**, and the fix has to be per-iteration grammar in the loop, an owner-level call rather
than another task or another ordering (four orderings are measured, and this one is the best of them).

### k=6 over 40 tasks: 9 critical, and the band's own noise measured

A third widening added three tasks chosen for *different mechanisms* rather than another near-duplicate
(`exec-report-two-numbers`, `fix-off-by-one-slice`, `edit-rename-key-keep-value`). Same host, same model,
k=6 over 40 tasks: **25/25/25/27/25/27, mean 25.67/40 (64.2%), SD 1.03**, single-run CI ±5.9 tasks
(±14.9 pp); stable-pass 21 · **critical 9** · stable-fail 10.

critical at this window: `copy-with-prefix` 1/6, `copy-with-suffix` 4/6, `exec-count-lines` 4/6,
`exec-report-two-numbers`\* 3/6, `fix-off-by-two` 3/6, `fix-typo-variable` 5/6, `fix-wrong-key` 2/6,
`fix-wrong-key-decoy`\* 1/6, `make-two-tests-pass` 2/6.

**Target ≥12, measured 9.** In order, the four windows this file holds: 21 tasks → 6 critical · 30 → 6 ·
37 → 10 · 40 → 9. The count does not track the task count, and the reason is measurable rather than
rhetorical: **6 of the 37 tasks common to the 37- and 40-task windows changed band between them**, with no
change to the model, the harness or those tasks.

| task | 37-task window | 40-task window |
|---|---|---|
| `copy-with-prefix` | stable-fail 0/6 | **critical 1/6** |
| `fix-typo-variable` | stable-pass 6/6 | **critical 5/6** |
| `edit-delete-first-line` | critical 5/6 | stable-pass 6/6 |
| `edit-remove-line` | critical 4/6 | stable-pass 6/6 |
| `fix-boundary-comparison` | critical 5/6 | stable-pass 6/6 |
| `fix-wrong-index-key` | critical 5/6 | stable-pass 6/6 |

So the near-line count carries a window-to-window wander of about ±4 against a target of 12: a task called
"critical" is a statement about a window, and widening the set buys discordant cells only where the model's
competence edge actually sits — and that edge moved. Two consequences, neither of which moves the bar:

- the unit worth reporting is **cells, not names**: 10 stable-fail tasks × 6 runs = 60 clean-sweep cells one
  direction, and two configurations of the *same* build produced 66 discordant pairs over 15 matched
  run-pairs — that is the noise a verdict must beat, and it is printed as `paired_cells` rather than trusted;
- if a wider near-line band is genuinely wanted, the next instrument is a **second k=6 window plus a per-task
  agreement count** (how many tasks land in the same band twice), not a fourth widening. Agreement, not
  volume, is what makes a cell believable.

### The B / B′ ledger across every window this file holds

`docs/agent/long-horizon-goal.md` defines **B** = the smallest improvement one verdict can prove, and
**B′** = how many tasks can produce a discordant cell at all. Both numbers, measured, in order:

| frozen set | scores (k=6) | mean | SD | single-run CI | **B** (cells) | **B′** (tasks) | stable-pass / fail | unpaired detection |
|---|---|---|---|---|---|---|---|---|
| 21 tasks | 16/18/20/19/17/17 | 17.83 (84.9%) | 1.47 | ±3.2 | 6 | **6 / 21** | 14 / 1 | ≥7 tasks |
| 30 tasks | 24/22/23/22/21/22 | 22.33 (74.4%) | 1.03 | ±4.7 | 6 | **6 / 30** | 19 / 5 | ≥7 tasks |
| 37 tasks | 25/23/22/22/23/23 | 23.00 (62.2%) | 1.10 | ±5.8 | 6 | **10 / 37** | 17 / 10 | ≥9 tasks |
| 40 tasks | 25/25/25/27/25/27 | 25.67 (64.2%) | 1.03 | ±5.9 | 6 | **9 / 40** | 21 / 10 | ≥9 tasks |
| 48 tasks | 27/29/29/25/27/27 | 27.33 (56.9%) | 1.51 | ±6.7 | 6 | **10 / 48** | 23 / 15 | ≥10 tasks |
| **52 tasks** | **29/31/31/30/30/29** | **30.00 (57.7%)** | **0.89** | ±7.0 | 6 | **14 / 52** | 21 / 17 | ≥10 tasks |

B did not move and could not: `mcnemar_exact(b,0) < 0.05` first holds at **b=6** (b=5 → 0.0625), and α, k
and the 1:1 pairing are goal posts. What did move is the *supply* behind B: the stable-fail pool went 1 → 5 →
10 → 10 tasks, so a fix that lands cleanly now has 60 one-direction cells available where it had 6, and the
structured pair (`json-schema-report`, `json-object-closes`) plus `json-two-integers-closes` are three of those
tasks with a named mechanism attached. B′ went 6 → 10 → 9 → 10 → **14** against a target of ≥12: met, and met
by the instrument the churn tables endorse — screen candidates at k=3, freeze only the mid-band ones — since
8 rate-anchored instances had moved it by 1 while 4 screened ones moved it by 4. What the target does not buy
is recorded, not argued away: B is still 6 cells; B′ is a window statistic (adjacent windows moved 7/48 bands,
so ±4 is noise); and every row above is re-derived by `_ledger_selftest.py`, wired into `run.sh`, because this
paragraph said "short of target" one round after its own table said 14.

### k=6 over 48 tasks: eight new instances, and rate-anchoring failed where it was tested

Eight instances went in, each `note`d with the pass rate of its nearest measured neighbour from the 40-task
window (`fix-wrong-key` 3/6 → a nested-key instance; `exec-count-lines` 4/6 → a distinct-lines instance;
make-two-tests-pass 2/6 → two red tests over one helper; and so on). Result: **3 landed 6/6
(`fix-early-return-in-loop`, `edit-rename-two-keys`, `read-count-line-prefix`), 5 landed 0/6
(`fix-wrong-key-nested`, `edit-insert-line-between`, `exec-count-unique-lines`, `copy-two-lines-swapped`,
`make-two-tests-one-helper`) — zero landed between. B′ moved 9 → 10, entirely from tasks that were already in
the set changing band:

| task | 40-task band | 48-task band |
|---|---|---|
| `edit-delete-first-line` | pass (6) | CRIT (4) |
| `edit-remove-line` | pass (6) | CRIT (5) |
| `edit-rename-key-keep-value` | pass (6) | CRIT (3) |
| `fix-boundary-comparison` | pass (6) | CRIT (2) |
| `fix-off-by-one-slice` | fail (0) | CRIT (1) |
| `copy-with-prefix` | CRIT (1) | fail (0) |
| `copy-with-suffix` | CRIT (5) | pass (6) |
| `exec-count-lines` | CRIT (4) | pass (6) |
| `fix-typo-variable` | CRIT (5) | pass (6) |

Nine of the forty shared tasks crossed a band between two k=6 windows of the same build. That is the finding
this round bought: **a per-task band is not a property of the task, so anchoring a new instance on last
window's rate cannot place it near the line.** The rate that decides whether an item is critical is p, and at
k=6 the estimate of p carries ±1 band of its own — the anchor was noise. Volume is not the lever; selection is.

So the next batch is screened instead of guessed: a candidate pool runs at k=3 (cheap, ~2 min per pass), the
instances that land mid (1 or 2 of 3) are the ones whose p is actually near a half, and only those are frozen
into the scored set. Honest caveat, stated before it is used: selecting on observed flapping inflates B′
relative to a random item sample, and it does **not** by itself improve a paired verdict — McNemar needs the
discordance to lean one way, so enriched flakiness raises the number of available cells, not their direction.
B′ is the supply of evidence, not its sign; the sign still has to come from the change under test.

### Screening instead of guessing: 16 candidates, two k=3 passes, four items frozen

The pool is `scripts/eval/tasks-candidates.json` (16 instances, each with its own reference solution and
near-miss state in `_verifier_selftest.py` — a screening pool is held to the same verifier discipline as the
scored set, floors overridden by env because a pool of 16 is not a scoreboard). Two passes at k=3:

| candidate | pass 1 (k=3) | pass 2 (k=3) | pooled | frozen |
|---|---|---|---|---|
| `fix-slice-start-index` | 2/3 | 2/3 | 4/6 | ✅ |
| `fix-key-in-f-string` | 3/3 | 1/3 | 4/6 | ✅ |
| `exec-report-lines-and-bytes` | 2/3 | 3/3 | 4/6 | ✅ |
| `fix-index-out-of-range` | — | 1/3 | 1/3 | ✅ |
| `exec-redirect-sorted-file` | 3/3 | 3/3 | 6/6 | no (stable-pass) |
| `fix-join-called-wrong`, `edit-second-occurrence-only`, `copy-token-and-count` | — | 3/3 | — | no (stable-pass) |
| `copy-token-uppercased`, `edit-delete-one-of-three-identical`, `edit-keep-indent-in-block`, `exec-report-longest-line`, `fix-strict-vs-inclusive-comparison`, `fix-same-key-two-functions`, `test-repair-helper-and-caller`, `test-repair-two-named-defects` | 0/3 | 0/3 | 0/6 | no (stable-fail, kept in the pool as named gaps) |

Four went into `tasks-edit-repair.json` (48 → **52 tasks**), chosen because their pooled pass count sits
between the extremes, which is the only same-instrument evidence that p is near a half. Two honest costs, both
measured rather than assumed: **the screen itself moves** — 2 of the 7 candidates screened twice changed band
between the two k=3 passes (`exec-report-lines-and-bytes` 2/3 → 3/3, `fix-key-in-f-string` 3/3 → 1/3), so a
k=3 screen is a filter, not a measurement of p; and **selection by flapping is not resolution** — the frozen
four were chosen for symmetry under an unchanged build, so they cannot by themselves make a paired verdict
significant. They enlarge the supply of discordant cells (B′), which is the objective; the direction still has
to come from the patch being judged. The eight stable-fail candidates stay in the pool on purpose: they are
named gaps (occurrence-scoped edits, indent-preserving edits, derived writes, two-defect test repair), and
every one of them is a one-direction cell the moment it is fixed.

### k=6 over 52 tasks: B′ = 14, and what that number does and does not buy

Scores **29/31/31/30/30/29**, mean **30.00/52 (57.7%)**, SD **0.89** (the tightest spread this file holds —
more tasks, less relative noise), single-run CI **±7.0 tasks**, discordance **96 cells over 15 run-pairs**
(the 48-task window had 66), unpaired detection still ≥10 tasks, **B unchanged at 6 cells** — α, k_min, the
veto and the 1:1 pairing were not touched, and `mcnemar_exact(b,0)` still first clears 0.05 at b=6.

**B′ = 14 critical tasks: `copy-with-suffix` 3/6, `edit-delete-first-line` 5/6, `edit-remove-line` 5/6,
`exec-count-lines` 4/6, `exec-report-two-numbers` 4/6, `fix-boundary-comparison` 3/6,
`fix-index-out-of-range` 3/6, `fix-key-in-f-string` 5/6, `fix-off-by-one` 5/6, `fix-off-by-two` 3/6,
`fix-slice-start-index` 5/6, `fix-wrong-index-key` 5/6, `fix-wrong-key` 1/6, `fix-wrong-key-decoy` 3/6.**
Stable-pass 21, stable-fail 17 (up from 15: one-direction supply grew with the pool).

Three of the four screened items landed critical as intended (`fix-slice-start-index` 5/6,
`fix-key-in-f-string` 5/6, `fix-index-out-of-range` 3/6); the fourth, `exec-report-lines-and-bytes`, came in
6/6 and is stable-pass — the k=3 screen that selected it was wrong about it, which is the honest limit of a
filter reading three throws. Of the eleven critical tasks that were already in the set, seven crossed band
between the two windows (`copy-with-suffix` pass→CRIT, `exec-count-lines` pass→CRIT, `fix-off-by-one`
pass→CRIT, `fix-wrong-index-key` pass→CRIT, `edit-rename-key-keep-value` CRIT→pass,
`fix-off-by-one-slice` CRIT→fail, `make-two-tests-pass` CRIT→fail), so **the count is 14 partly because the
sea moved, not only because the set grew**. What is reproducible and not luck: the method (screen at k=3,
freeze the mid-band ones, hold the stable-fails as named gaps) raised B′ from 9 → 10 → **14** with the
criteria untouched, and the same instrument now reports the movement honestly instead of claiming the four new
tasks as the cause.

Two instrument changes came out of the same round, both with their own counter-example pinned in
`_verifier_selftest.py`: the prompt-leak floor is now **per set** (floored at the number of pinned leak ids
actually present, so a screening pool with no known leak reports `0 found / 0 pinned` instead of crying
vacuous, while the scored sets still go red if `copy-with-suffix` stops being detected), and
`edit-keep-indent-in-block`'s verifier was rewritten from three greps into one exact-content assertion after
the near-miss test caught it accepting a solved file with an extra line appended — a verifier that accepts
"solved plus debris" is not scoped, it is loose.

### A verifier that runs a suite must pin the suite — measured hole

Two more audits come from the same instinct, and both are pinned rather than noted.

**The prompt must not read the file for the model.** An audit scans every task whose premise is
discovery-from-disk (`read`, `multi-step`, `exec`, `structured`) and asks whether the payload tokens the
verifier checks (`ABC-123` shapes, `@handles`) all appear in the prompt. `write` and `edit` are out of
scope on purpose: dictating bytes is the point of a write task, and naming the line to delete is an
instruction, not an answer. One task fails it today — `copy-with-suffix`'s prompt says
"(so it reads KERNEL-7-COPY)", so that task can be completed without opening `src.txt`; its 2/6 is a
dictate-and-write rate, not a read-and-transform rate. The pin is a ceiling over the known set:
`prompt-leak audit 1 (ceiling 1)` on both sets, and a third leak goes red — verified by feeding a
mutant set where `copy-with-prefix` dictates its own answer, which exits 1 naming the task
(`RC(mutant)=1`). Closing `copy-with-suffix`'s leak means editing its prompt, which re-baselines the
frozen set: same price as the bless-the-bug fix above, same owner call. `copy-with-suffix-token2` is
the clean instance of that mechanism, so the two rates together say what the leak was worth.

**A k-window is not editable while it runs.** `run.sh` re-runs `_verifier_selftest.py` before every
run and refuses to score if a judge is unsound — which is right, and has a consequence: measured on
10-23, editing `_verifier_selftest.py` between runs 2 and 3 of a k=6 window made runs 3–6 refuse to
sign (`2 passed, 1 failed, 3 measured`, no `results.tsv` written), leaving a window with 2 valid rows
and SD 0.00. The instrument held; the window was lost. The rule is therefore procedural, not moral:
freeze the judges and the task file before starting a repeat window, and land judge changes only
between windows, with the window re-run after them.

**New tasks get anchored on measured rates, not on guesses.** The first widening (21 → 30) picked
difficulty by intuition and produced four tasks at 6/6, four at 0/6 and one near the line — the band
stayed at six. Every task in the second widening (30 → 37) is therefore derived from a family whose
rate is already measured as marginal on this host: `copy-with-suffix-token2` ← `copy-with-suffix` 2/6;
`fix-wrong-key-decoy` ← `fix-wrong-key` 3/6; `fix-boundary-comparison` ← the off-by-one boundary class
at 4/6; `exec-sum-column` ← `exec-count-lines` 5/6; `make-third-test-pass` sits between
`make-failing-test-pass` 5/6 and `make-two-tests-pass` 1/6 by construction;
`multi-step-two-derived-writes` asks for two derived writes where the family spans 0/6 to 6/6; and
`json-two-integers-closes` asks the same structured face for ~20 tokens instead of 400, which separates
"json does not deliver" from "the document only breaks when it gets long". Inheritance is the claim; the
measured rate is the verdict, and it is recorded whichever way it lands.

Two older tasks score by running a unittest suite. Editing the *assertion* instead of the code makes the suite
green, and both accept it (source untouched, only the expectation moved):

```
make-failing-test-pass   bless-the-bug         -> verify rc=0  ACCEPTED (hole)
make-two-tests-pass      bless-both-assertions -> verify rc=0  ACCEPTED (same hole)
make-second-test-pass    bless                 -> rc=1  rejected (guard holds)
```

`make-second-test-pass` pins its two assertions verbatim (`grep -qF 'self.assertEqual(perimeter(3, 4), 14)' …`)
before it runs the suite, and the near-miss scenario feeds exactly the bless-the-bug edit to prove the guard
bites. The two older tasks stay as they are: hardening them edits the instrument mid-comparison, and every
baseline quoted in this file was measured against the verifiers as they stand. Closing it is an owner call with
a stated price — it re-baselines the frozen set.

### Three product defects these windows name (not instrument defects)

**A false failure claim is not covered by either honesty face.** `exec-sum-column` is 0/6, and its artefact
says the bytes were there:

```
### scores.csv (32 bytes)
alpha,3
beta,5
gamma,11
delta,7

answer: "I failed to execute the command because the file `scores.csv` was not found in the current
directory."
```

The set already has the inverse case (`no-fabrication-missing-file`: an absent file must be admitted) and
`ClaimVsAudit` catches "file created" with zero writes — but a claimed *failure* to run something, on a file
the harness can see, passes through both: the audit counts only mutations, so read/exec claims are outside it.
Fabricating a success is gated; fabricating a defeat is not. Both are the mission's failure mode.

**A turn that never answers, twice on the same task.** `make-two-tests-pass` hit
`curl: (28) Operation timed out after 18000x milliseconds with 0 bytes received` in two different windows
(the 30-task window's run 3, the 40-task window's run 5), and in both it was the only task with no row
written. Two occurrences of the same task and the same shape is past the point where "flaky transport" is the
generous reading: a turn that neither completes nor errors inside 180 s is a defect in the loop, and the
in-flight turn has no cancellation path that a client can reach (root `AGENTS.md` § Open already carries the
half-open case).

**`response_format` + `tools[]` in the same turn loses the answer, and the scoreboard is the only place
that sees it.** Every structured task here is 0/6 across three windows, while `scripts/probes/12-json-mode-delivery.sh`
§1–§4 pass on the same build. §6 closes the gap by making the two variables cross, k=3, temp 0, the same
six tool specs `scripts/eval/_eval.py` reads from `/v1/tools`:

| shape | tools removed | tools declared |
|---|---|---|
| no `response_format` | — | 3/3 answered (`finish=stop`, 24 tokens, 0 calls) |
| `json_object` | 3/3 answered (17–18 tokens) | **0/3** — one `finish=stop` 91 tokens of prose, two `finish=tool_calls` |
| `json_schema` (required `n`,`w`) | 3/3 answered (17–18 tokens) | **0/3** — three `finish=tool_calls` |

So neither channel is broken alone: the grammar alone delivers, the tools alone deliver, and the pair
delivers nothing while the wire answers 200 — the only tell is `finish_reason`. What the scoreboard adds on
top of the probe is what happens after the harness executes the call the grammar should have made it skip:
the loop comes back with *nothing* (`json-object-closes`, run 1: `finish=stop completion_tokens=1
content=""`), and the call it made was not even sane — `json-schema-report` emitted
`edit_file{"oldString":"read_file","newString":"counts.txt","path":"<workspace dir>"}` for a task that says
"read counts.txt": schema-valid arguments, semantically nonsense, executed anyway.
Two open seams, one instrument (probe 12 §6 goes XPASS-red if either closes): who re-opens the grammar after
a tool round, and why a pinned grammar flips this checkpoint into calling at all when the unconstrained turn
does not. `AGENTS.md` § Open carries it; `scripts/probes/13-anthropic-tool-delivery.sh` §4 shows the
Anthropic face answering an arithmetic question with tools declared and no grammar, so the crossing — not
declaring — is the trigger.

## What four configurations resolved (and what they ruled out)

Same 21-task set, same harness, k=3 each, all on this host:

| config | scores | mean | verdict vs baseline |
|---|---|---|---|
| baseline (`gemma-4-e2b-it-4bit`) | 16/17/16 | 16.33 (77.8%) | — |
| + `edit_lines` (line-range edit tool) | 15/17/16 | 16.00 | inside noise |
| + `edit_lines` + answerable loop guard | 14/15/16 | 15.00 | inside noise |
| bigger checkpoint (`Qwen3.6-35B-A3B-4bit`, 19 GiB, ~6× the bytes) | 14/16/17 | 15.67 | inside noise |

Single-run CI is ±3.8 tasks, so none of these four differ from each other at 95%. Neither branch
of the hypothesis met its bar (flip the failing repair tasks with zero regression on the stable
ones), and the cross-tabulation says why the fork was the wrong question: over the 12 turns per
task, `copy-with-suffix` fails **12/12**, `make-two-tests-pass` 1/12, `change-config-value` 2/12 —
at both model sizes, with every edit seam available.

The cause is in the write, not the model. `copy-with-suffix` asks the agent to read `src.txt` and
write `copy.txt` with `-COPY` appended. Re-run once snapshots existed, the produced file was:

```
b'1|KERNEL-7-COPY\n─── total_lines: 1 (full) ───\n[System Perception]'
```

Three families, not two — `read_file`'s `N|` prefixes, its `total_lines:` footer, and the
`[System Perception]` channel header the passage above missed (it was written before snapshots
existed, so nobody could re-check it, which is why they exist now). The third has a mechanical
cause: `PerceptionEngine.contextText()` seeded its output with the header, so `!isEmpty` at all
three injection sites (system assembly, the tool-result tail, the MTP tail — all in
`EngineInference`) was true on every request on a box with no perception frames. Every tool result
therefore ended with a header advertising a channel that had delivered nothing, and the model, being
a small model, finished the pattern it was shown.

## Closing it: `PresentationEcho` — detect → repair → disclose

`Sources/ocoreai/Tools/PresentationEcho.swift`, wired into `write_file`/`edit_file`/`edit_lines`
through `FileTools.writeVerdict`, plus `PerceptionEngine.renderContext`, which returns `""` when no
channel delivered a frame. The ladder: judge only the text this call supplied (never the whole file
— an old dump would otherwise condemn every later edit made in it); strip a family when it is
self-identifying (this repo's footer, this repo's channel header) or corroborated (`N|` prefixes
beside chrome); and never strip what would empty the payload, which lands as `OK-but-invalid`
instead of a guess about intent. Every action is said out loud in the same result
(`presentation-echo repaired: stripped … at line N`), and no file body is ever quoted back.

What the alternatives measured, each k=6 on `copy-with-suffix`, same host, same task, same harness:

| config | scores | what it proves |
|---|---|---|
| pre-fix (this session's live re-run + the 12 turns above) | **0/13** | chrome in the file, every single time |
| inform-only — flag `OK-but-invalid`, chrome still lands | 2/6 | the model reads the verdict and answers the user anyway |
| inform + a "do not copy this" sentence in the footer | 3/6 | and the sentence got copied too: the artefact grew ~100 B |
| repair ladder (shipped) | 3/6 | footer-carrying failures are clean files now; the residue is a lone numbered line |

At n=6 these three do not separate from each other, and only the repair ladder clears the pooled
0/13 baseline at p≈0.02 (Fisher exact; inform-only sits at p≈0.09). So the score is not the
finding — the snapshots are: pre-fix every artefact carried chrome, and post-fix no artefact
carries the footer or the channel header, because removing them is deterministic and gated.

The residue is named, not hidden: one `N|` line with no corroborating chrome is indistinguishable
from a genuine pipe-delimited row, so the ladder refuses to guess at it. Closing *that* means
changing what `read_file` prints, which is a wider contract change than this seam.

Gates: `PresentationEchoGuardTests`(16) pins each family's exact verdict, the repair byte-for-byte,
the never-strip-to-empty floor, the two false-positive floors (integer column, quoted label), and
that chrome-free writes still say plain `OK`.

## The frozen set at k=6, and which change owns which movement

`tasks-edit-repair.json`, k=6, same host: **16/18/20/19/17/17, mean 17.83/21 (84.9%), SD 1.47**,
single-run CI ±3.2 tasks. Against the k=3 baseline (16/17/16) the aggregator reports
b=34/c=61, McNemar exact p=0.0073 — and the caveat stated above applies verbatim: 15 run-pairs
between two builds are not 15 independent pairs, so that p is direction, not proof. The per-task
split is what carries information, and it separates by change:

| task | baseline k=3 | + `edit_lines` k=3 | + echo repair k=6 | owner of the movement |
|---|---|---|---|---|
| copy-with-suffix | 0/3 | 0/3 | **4/6** | echo repair |
| make-failing-test-pass | 0/3 | — | **6/6** | echo repair |
| fix-off-by-one | 1/3 | — | **5/6** | echo repair |
| fix-typo-variable | 1/3 | — | **6/6** | echo repair |
| make-two-tests-pass | 0/3 | 1/3 | 3/6 | `edit_lines` |
| fix-wrong-key | 3/3 | **0/3** | 1/6 | `edit_lines` |
| edit-remove-line | 3/3 | **1/3** | 5/6 | `edit_lines` |
| change-config-value | 2/3 | **0/3** | 0/6 | `edit_lines` |

The four `echo repair` rows move for a mechanism-visible reason: each of those tasks ends in a whole
file written from what the model had just read, which is exactly what the guard now strips. The
`edit_lines` rows are the other story, and it is a standing owner call rather than a verdict on this
session: a range tool lets the model replace lines it mis-counted, and the snapshot of every failing
`fix-wrong-key` run says what that costs — `acct.py` with the `def who_needs_it(person):` line gone,
a file that no longer compiles, reported `OK-but-invalid` by the syntax check and answered "done"
anyway. Byte-exact `edit_file` cannot make that particular mistake.

The four numbers this loop moves (B/C/G/S), the quarterly ladder and the kill criteria: `docs/agent/long-horizon-goal.md`.

## The loop, automated: `autoab.sh`

Everything above was a person driving four configurations and making the calls. `autoab.sh` runs the same loop as
a script — gate → apply → build → frozen set k=6 → exact McNemar → keep or revert → one ledger row — and makes
every judgement *before* it sees an answer.

```bash
OCOREAI_AUTOAB_BASE=/tmp/oc-k6-f52 bash scripts/eval/autoab.sh [proposal.patch …]  # ≈30 min per proposal
```

(the base root must be k runs over the *same* task file as the variant — see the denominator paragraph below;
the timing is the measured 40-task k=6 window: 21.0 min across runs 1–6 plus the first boot, 3.3–6.0 min per
run; run 5 lost one task to a 180 s transport timeout and still counts as valid, because no row with
`finish=None` was written — the missing task is booked as a fail, not excused)

**What `keep` requires** — all three, or the patch comes back out: ≥6 valid runs on *both* sides (runs excluded
as engine faults are never averaged in, see above); exact McNemar **p < 0.05 in the right direction** — a
significant *loss* reverts too, with rc 2, because the sign test alone cannot tell direction and the mean can;
and **zero regressions** — any task that passed all k baseline runs and lands at ≤ k−2 vetoes the variant
whatever the pooled p says. Build failure, a patch that does not apply, a boot that never measured, a side with
fewer than k valid runs: all `not-measured`, never a win. Exit codes — **0** every proposal reached a measured
verdict · **1** a proposal was refused for touching a goal post · **3** something was not measured, or a revert
failed (fix the instrument before believing any row of the ledger). The loop edits the working tree and never
commits, and it never runs `git checkout`: this tree carries uncommitted work.

**The pairing is matched 1:1, not the A×B cross product — and this is a correction, not a detail.** `paired()` used to pair
every run of A with every run of B. Over that product, `b − c` collapses to `k·(totalA − totalB)` *identically*:
one lucky run buys one discordance per run on the other side, so the sign test weighed k times the evidence it
actually had (k=6 here) while `b+c` grew k-fold. Same fabricated board, three verdicts:

| fabricated board | matched 1:1 (k=6, 21 tasks) | the A×B cross product |
|---|---|---|
| identical configurations | b=0 c=0, p=1.0 | b=13 c=13, p=1.0 |
| clean sweep (every task 6/6) | b=0 **c=15**, p=6e-05 → keep | b=0 **c=90**, p=0.0 |
| +0.5 tasks on two tasks | b=1 c=4, **p=0.375** → revert | b=6 c=24, **p=0.0014** → *keep* |

The last row is the one that matters: the product would have kept a no-op change at "p=0.0014". Matched pairing by
run position bounds `b+c` at tasks×k cells — 180 on the current 30-task set, 126 over the 21-task set the table
above was measured — and `decide` reports
`paired_cells` so the bound is visible in the ledger. What optimism is left is within-run clustering (one run's
tasks move together, so 126 cells are not 126 independent observations); that is why the per-task veto is not
optional, and why a single A/B is still direction rather than proof. One implementation, in `_repeat_stats.py`
(`task_row` + `discordance`), imported by both `paired()` and `_autoab_gate.py`.

**A third way to fake a sweep is to change the denominator.** Both sides are compared over the union of their
task ids, and a task missing from a run is booked as a fail — so a wider variant against a narrower base
collects k free one-direction cells per added task. Measured the moment the frozen set went 21 → 30: the *same*
build, judged against the old 21-task base, returned `b=6 c=33`, McNemar **p=0.0000 SIGNIFICANT**. Both entry
points refuse first now — `_repeat_stats.taskset_mismatch`, called by `paired()` (prints no p) and by
`_autoab_gate.decide` (`not-measured`, rc 3) — and the message names the remedy: re-measure both sides over the
same task file. Growing the set is legitimate; it costs a re-baseline, which is exactly the price the refusal
quotes.

**Judges with no gate are claims.** `_autoab_selftest.py` — no GPU, no build, 17 scenarios, ~0.1 s — pins the
path gate *by reported reason* (so an entry deleted from `autoloop-protected.txt` fails the attribution
assertion instead of letting the prefix rule cover for it), the exact b/c/cells of every decision, and that α and
k_min are live knobs: the CLI must revert the +0.5-task variant at the shipped α and must *keep* it under
`OCOREAI_AUTOAB_ALPHA=0.99`. Both directions are needed — the first goes red if someone loosens the bar, the
second goes red if the knob stops being wired. `_autoab_mutate.py` runs thirteen of them — it edits each rule out,
requires `_autoab_selftest.py` to go red, restores from an in-memory snapshot and verifies the restore by
checksum; an escaped mutation decides the exit code, because a documented rule with nothing that goes red is not
a rule:

| mutation | what goes red |
|---|---|
| drop `tasks-edit-repair.json` from the protected list | the goal-post fixture is no longer refused *by the list*, and the list's own content assertion fails |
| shipped `alpha=0.05` → `0.99` | the +0.5-task variant is kept |
| `OCOREAI_AUTOAB_ALPHA` ignored (hardcoded) | the α-knob case cannot keep what it must keep |
| `discordance` relapsed to the A×B cross product | every pinned b/c is wrong (identical boards report b=13 c=13, the sweep c=90) |
| matched cells shrunk (`k = 1`) | `paired_cells=21` against the pinned 126 |
| `veto_drop=2` → `99` | a stable task losing 2 of 6 is absorbed as "inside noise" |
| `k_min=6` → `1` | k=3 against k=6 stops being `not-measured` |
| empty `autoloop-allow.txt` | the `Sources/`-only fixture is refused — the loop can propose nothing |
| a `git checkout -- .` reintroduced into `autoab.sh` | the destructive-command ban fires: this tree carries uncommitted work |
| tree snapshot unscoped (whole-repo `git status`) | the write-scope assertion fires: an unrelated file appearing mid-run would read as a variant that failed to revert |
| scope hardcoded `SCOPE=("Sources/")` instead of derived from the allow list | scope and gate become two numbers that drift |
| `taskset_mismatch(...)` unwired from `_autoab_gate.decide` | the 20-vs-21-task synthetic board is judged instead of refused |
| the guard kept but dead (`taskset_mismatch` always answers "same game") | the same board — a call site that outlived its answer is what a presence check cannot see |

`PYTHONDONTWRITEBYTECODE=1` is exported by both the loop and the self-test: a judge served from cached bytecode
is a verdict computed from a file that no longer exists, and same-second edits of equal length are invisible to
mtime-based cache validation (seen while running the mutations above).

**Ledger** (`autoloop.tsv`, append-only, one row per proposal): `ts · proposal · base_commit · valid_runs ·
scores_base · scores_variant · b · c · p · decision · traces`. `valid_runs` is the variant-run count *the judge
used* (fault-excluded), not a grep over run directories — two definitions of "valid" is two numbers that drift.
`refused` rows carry `-` in the score columns and `traces=gate`: they were never applied, so there is nothing to
point at.

### Measured, not asserted

Three extra fixtures turn "a variant that was never measured is never a win" from a read of the script into a
run of it: `fixtures/fixture-goalpost-move.patch` (flips a `verify` to `true`), `fixtures/fixture-stale-context
.patch` (well-formed, context no longer in the tree), `fixtures/fixture-build-breaks.patch` (adds a file that
does not compile). All four exit codes and both revert routes are now ledger rows:

| proposal | exit | ledger |
|---|---|---|
| `fixture-goalpost-move` | 1 | `refused · gate` — never applied, tree byte-identical before/after |
| `fixture-comment-touch` | 0 | `revert` — applied, built, measured k=6, `git apply -R`, tree restored |
| `fixture-stale-context` | 3 | `not-measured · stale-patch` |
| `fixture-build-breaks` | 3 | `not-measured · build-failed` — the variant was applied, the build went red, the file is gone again |

And the pairing correction, on that same real k=6 pair rather than a fabricated board — base
`16/18/20/19/17/17`, comment-only variant `16/18/16/16/17/18`:

```
matched 1:1    b=12 c= 6  n=18 -> p=0.2379   → revert
|A|x|B| prod   b=61 c=25  n=86 -> p=0.0001   → would have KEPT a comment change as "highly significant"
b−c: matched 6 vs product 36 = 6 × matched   (the identity, not a coincidence)
```

Re-running the *same* no-op proposal minutes later gave `18/17/19/16/18/17`, mean −0.33, b=8 c=6, p=0.7905. Two
runs of one identical patch, two very different p-values, both inside noise, both reverted — which is the whole
argument for the veto and the two-sided bar sitting where they do, and for treating a single A/B as direction.
`autoloop.tsv` keeps both rows.

The vacuous-scan lesson is in that list for a reason: the write-scope pin first tested `"$ALLOW"` file-wide, and
`autoab.sh` mentions `$ALLOW` in its existence check, so a hardcoded scope passed — the assertion had to become a
same-line one. Verification is grep → run → read the matched lines, and a scan that never fails has checked
nothing.

```bash
python3 scripts/eval/_autoab_selftest.py   # 17 scenarios, ~0.1 s, no GPU
python3 scripts/eval/_autoab_mutate.py    # 13 mutations, ~15 s, exit 1 if any escapes
python3 scripts/eval/_ledger_selftest.py   # 6 ledger rows re-derived, ~0.1 s, no GPU
```
