# Auto-A/B proposals

One `.patch` per proposal, plus an optional `.md` of the same stem saying the claim in one
sentence (what behaviour moves, and why). `bash scripts/eval/autoab.sh` takes them in filename
order: gate → apply → build → frozen set k=6 → exact McNemar → keep or revert → ledger row in
`../autoloop.tsv`. A proposal never commits; the owner reviews the tree and the ledger.

Write proposals against `Sources/` only. Anything that moves the frozen task set, a verifier, a
floor, or the doc ratchet is refused before it is applied — that refusal is the point of
`../autoloop-protected.txt`, and `../_autoab_selftest.py` is the gate that says the refusal still
works. `../fixtures/` holds the patches the self-test and the end-to-end probes use — a comment-only touch,
a goal-post move, a stale-context patch and one that does not compile — exercised by
`../_autoab_selftest.py`; they are not proposals and the loop ignores them.
