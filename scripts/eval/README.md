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
