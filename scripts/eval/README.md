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

## Status — and what it is not

This is a **scoreboard, not yet a CI gate**. A 4-bit local checkpoint has a hard ceiling
here, and wiring an unknown number into CI turns a ceiling into a fake regression. It goes
into `make test-ci` only once its number is measured, stable across runs, and recorded in
`CHANGELOG.md` with the run that produced it.

Task set: 9 tasks (`tasks.json`) covering write / scoped edit / diagnose-and-repair /
run-a-test-until-green / read-and-report / execute-and-report / multi-step / honest refusal.
Add a task by adding one object to `tasks.json`; `verify` runs in the workspace with
`$OCOREAI_EVAL_ANSWER` (the final assistant text) and `$OCOREAI_EVAL_EXPECT` available.
