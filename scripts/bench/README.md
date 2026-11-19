# Benchmark artifacts

`make bench` regenerates `scripts/bench/results/scripted.json` — host, toolchain, commit,
conditions and four metrics, each the median of repeats. Third parties judge ocoreai by
what they can re-measure on their own machine, so the artifact ships with the tree and one
command rebuilds it.

```bash
make bench    # zero weights, no Metal device, no model download; runs on any host that builds the binary
```

## The two boards and the artifact — three instruments, three questions

- `scripts/probes/` — does the wire tell the truth (numbered probes up to 57, booted live).
- `scripts/eval/` — does the agent finish real jobs (task-success board, `README.md` there).
- `scripts/bench/` — how fast and at what token cost, as a machine-readable artifact a
  third party regenerates and diffs.

## The lane, and its honest limit

The scripted lane boots the real `serve` route with `OCOREAI_SCRIPTED_ENGINE` set to a
generated fixture (a script path replacing the model, never the wire). It measures the
agent system's own overhead — HTTP/SSE plumbing, token accounting, turn latency — with
zero weights, so anyone can regenerate it, and cross-build diffs are meaningful.
Because tokens are pre-declared, `tok_s` here is **plumbing overhead, not model
throughput**; it must never be quoted next to a checkpoint tok/s number. The live-weight
tok/s lane is planned and absent from the artifact — no number is claimed for it.

## Metrics

- `tok_s` — streamed tokens per wall-second the client waits (median of repeats)
- `ttft_ms` — request sent to first streamed frame (median of repeats)
- `req_latency_ms` — whole non-stream round trip (median of repeats)
- `prompt_tokens_server` — the server's own `usage.prompt_tokens` for the fixed prompt

## Regeneration contract

The artifact self-describes what varies across machines: commit and dirty-path count,
chip/arch/macOS, toolchain path, binary path and size, repeat count, fixture token
declarations, prompt hash and byte count, and the request parameters left at their server
defaults. A regeneration will move `tok_s`/`ttft_ms` — across hosts with the hardware, and
on one host run to run (a ~6% band was measured across back-to-back runs on the same
machine), which is why each metric ships median and samples. `prompt_tokens_server` and the
correctness flags (`stream_bytes_match`, `usage_equals_declared`) must not move at all —
they are correctness reads, and `run.sh`
fails the run rather than printing numbers when they break. The usage-vs-declared assertion
is the bench proving its own timed region measured the right work; the wire contract
itself keeps its seat in the probe fleet.

## Publishing gate

These numbers are internal preparation. Publishing them outside the repository — release
notes, README, anything a user reads — is a release act and needs the owner's
authorization. Regeneration and verification are open to anyone.
