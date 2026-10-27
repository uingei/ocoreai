# Open — measured, unresolved

The long form of § Open in `AGENTS.md`, which owes only the address. Nothing here is a capability claim:
where a number is unmeasured it says so, and where a fix is blocked by the host or by upstream it names
which. A resolution goes to `docs/agent/closed-items-log.md`; a decision becomes a rule in `AGENTS.md` or
the area guide, with its gate. Per-item evidence is in `CHANGELOG.md` (grep the symbol).

- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — accepting a slash costs a second routing truth, so the
  wire shape stays pinned in `Handlers/AGENTS.md` § Endpoint Promises and the owner call stays open here.
- **A stall stops MTP hard, the std lane only by consent** (Tools/, Engine/) — the ladder and
  `LoopStallTerminationTests`(6) landed; upstream's `restart:` loop (ChatSession.swift:1154) still has no
  cap, and a std-lane hard stop throws out of `toolDispatch` (:1632) reaching the wire as an error, not a
  finished turn — the terminal word for four faces is the owner call.
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/) — three `@available(macOS 27.0, *)` or
  SDK-gated sites (detail: `docs/agent/build-gate-reality.md`) ⇒ no blind fix and no claim of one; their
  suites now skip on this OS through `PlatformPremise.hasMacOS27` instead of reporting a red.
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). The injection seam landed
  upstream at pin `991266ad3` (`observe(to:using:)` + `GenerationTransformer`), so what is left is
  owning what upstream's `ChatSession` loop owns. Owner call.
- **Rewind is landed; the reserve is a guessed constant** (Engine/) — 1024 rows measured on one checkpoint,
  not tuned to model or memory pressure, so an edit further back than the reserve still pays its full prefix.
  `SessionRewindOnDivergenceTests`(7) + probe 27 hold the wiring and the number.
- **Video publishing is per-checkpoint** (Multimodal/) — one processor reads `input.videos`, the other does
  not, so it is never inferred from architecture; a turn that received frames but never answered is not
  counted, and relaxing that is untested (`VideoDeliveryLedger`).
- **Screen capture cannot start a stream headlessly** (Multimodal/) — authorized, display attached, still
  "cannot start stream", while the camera on the same box delivers: an SCStream-in-no-GUI-session limit,
  not TCC. `screenStatus` is `ready` only after a delivered frame.
- **`tools[]` enforcement has gaps** — scope and open halves: `Sources/ocoreai/UI/AGENTS.md`; the
  `required`-strength bound sits in `Handlers/AGENTS.md` § Endpoint Promises.
- **Two owner questions have data now and no answer** — refresh-vs-refuse when instructions change, and
  cross-conversation prefix sharing. `ReuseRefusalLedger` publishes both; the ledger is opportunity, not a
  capability claim.

- **The board measures 6 of the 43 registered tools.** `scripts/eval/run.sh` pins `OCOREAI_EVAL_TOOLS` to
  read_file / write_file / edit_file / edit_lines / search_files / exec_command and prints that count in
  its premise line, so every figure the board has printed is about a 6-tool slice, not the surface a user
  gets. The registered surface is 43 typed declarations (`core_tools`, now counted without comments — 2 of
  the 45 it cited were prose). Comparators measured in their own trees: codex 13 tool specs
  (`codex-rs/core/src/tools/handlers/*_spec.rs`), opencode 16 (`packages/core/src/tool/plugin/`);
  hermes-agent states the rule — "the core is a narrow waist", "every model tool is sent on every API
  call, so the bar for a new *core* tool is high". Settled by: the same 39 tasks and verifiers over the
  full declared surface, reported beside the 6-tool slice. Whether 43 is right for a small local model is
  then an owner call with two boards to read; nothing here claims 43 is wrong, only that this board
  cannot answer it.
