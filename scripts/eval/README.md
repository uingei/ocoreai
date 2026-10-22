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

An answer that claims success while the file is unchanged scores FAIL. That gap — 生成内容
vs 可靠行动 — is what this scoreboard exists to keep visible.

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
- ≥ `OCOREAI_EVAL_FLOOR_TASKS` (6) tasks loaded and ≥ `OCOREAI_EVAL_FLOOR_SPECS` (4) of the
  needed tools declared by `GET /v1/tools` — otherwise every task would fail for the wrong
  reason, which is a harness bug, not a model result;
- tool schemas come from `/v1/tools`, so this directory holds no copy to drift.

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

Updated verdict after `replace_all` landed (see `CHANGELOG.md` 10-22(5)): over `k=3` valid runs
`edit-replace-all` went **0/3 → 3/3** — every attempt succeeded where none had, judged by the workspace — while
the aggregate stayed inside noise (A=`16/19/20` → B=`17/19/18`, mean −0.33, McNemar p=0.749). Both statements
are true and they are different statements: the scoreboard resolves a failure mode disappearing, not one task
being fixed. What was measured before that, kept for the record: the honest reading of the `edit_file` remedy A/B is: A=`16/19/20` → B=`20/20` after excluding one invalid run,
mean **18.33 → 20.00 (+1.67)**, nominal McNemar b=4 c=14 p=0.031 — from 2 valid B runs, with |A|×|B| run pairs
that are strongly correlated, and a single-run CI of ±3.6. That is **below the ≥6-task bar above**, so it is
recorded as promising, not as an improvement. The task the change was written for did not move:
`edit-replace-all 0/3 → 0/2`, with the model answering the *user* instead of retrying.

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
