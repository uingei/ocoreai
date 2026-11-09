# Auto-A/B proposals

One `.patch` per proposal, plus an optional `.md` of the same stem saying the claim in one
sentence (what behaviour moves, and why). `bash scripts/eval/autoab.sh` takes them in filename
order: gate → apply → build → frozen set k=6 → exact McNemar → keep or revert → ledger row in
`../autoloop.tsv`. A proposal never commits; the owner reviews the tree and the ledger.

A measured verdict consumes its proposal: on `keep`/`revert` the loop moves the patch (and its `.md`)
to `adjudicated/`, so the next bare run buys no verdict twice — the ledger row is the record. The move
skips anything outside this directory (the fixtures below stay put under an explicit re-run) and skips
a name collision rather than clobber archaeology. `refused`/`not-measured` rows consume nothing; the
patch stays and the round is retryable. The stem is the ledger's proposal key: a revised payload gets
a new stem (`…-v2.patch` is that rule working), and an explicit-path re-run of a held verdict stays
possible: `bash autoab.sh proposals/adjudicated/<name>.patch`.

Write proposals against `Sources/` only. Anything that moves the frozen task set, a verifier, a
floor, or the doc ratchet is refused before it is applied — that refusal is the point of
`../autoloop-protected.txt`, and `../_autoab_selftest.py` is the gate that says the refusal still
works. `../fixtures/` holds the four demo patches: the comment-only touch and the goal-post move are
exercised offline by `../_autoab_selftest.py` (gate verdicts only); the stale-context patch and the one
that does not compile only move through the full loop (apply → build → measure), so they ran manually
once on 10-23 and live as `autoloop.tsv` rows 4–6 — re-run: `bash autoab.sh ../fixtures/<name>.patch`,
which needs a build and a checkpoint. None is a proposal, and the loop's glob (`proposals/*.patch`)
ignores all four.
