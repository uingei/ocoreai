# Codex runtime facts (host-local, not project evidence)

Long form moved out of `AGENTS.md` so the injected file stays rule-only. Nothing here binds a
verdict about the repo: engine truth is `git` + `swift build` + `make test-clt` + the probes, and
every repo-binding verdict lives in `CHANGELOG.md`.

## Who works here
- The coding agent is **Codex** (CLI + desktop app), driving this repo through `exec_command` /
  `apply_patch` plus the MCP tools the harness lists in the current session.
- It is **not** Hermes and it is **not** served by Ollama. The model id this file used to name
  (`qwen3.8:27b-mtp`) is `OCRE_SEARCH_MODEL` — ocoreai's opt-in web-search backend model
  (`Sources/ocoreai/Tools/WebSearchTool.swift:346`), reached only from
  `Sources/ocoreai/Tools/DirectWebSearch.swift:532`/`:540` when `OCRE_SEARCH_MODE=backend|auto`;
  the default `native` path (`:529`) needs no local server.

## Skills
- The authoritative skills list is the one the runtime injects into its own system prompt. The list
  on disk (`~/.codex/skills/.system`) drifts and is a convenience, not a contract.
- Names previously listed in `AGENTS.md` — `single-pass-orchestration`, `code-review-discipline`,
  `hermes-agent`, `ocreai-dev`, `engineering-grilling`, `code-audit-methodology` — were dead
  pointers: `find` over `~/.codex` and this repo returned 0 hits. Their substance is the root file
  (Build / Test / Lint + Working here), so nothing was lost by deleting them.

## Sub-agents
- Codex can fan out (`spawn_agent`, parallel tool calls). The default here stays one-pass:
  intent → plan → implement → review → verify → commit inside one thread, no sub-agent unless the
  owner asks. Two reasons survive the tooling change: the owner reviews every commit, so a
  fan-out nobody reads adds no assurance; and local verification is serialised regardless —
  `swift build` / `swift test` share one scratch path (`.build`, `.build-clt`), so parallel jobs
  contend a lock instead of saving time.

## Escalation / approval reality
- `approvals_reviewer = auto_review` on this host asked its configured provider
  (`~/.codex/config.toml` → `model_provider = omlx`) for a model `codex-auto-review` that server
  does not serve → `404 … Model 'codex-auto-review' not found`, so an escalated command never ran.
  That is a review-service failure, not a safety verdict, and it is host config outside this repo.
- As of the 10-18 round, `make test-clt` and the live probes escalate and run fine, so the
  Metal-heavy gates are available locally; CI macos-26 stays the authority.

## Host notes and scratch dirs are not evidence
- `~/wiki` (Obsidian vault) is absent here (`ls ~/wiki` → *No such file*): not in the repo, not on
  CI, therefore never project evidence. Cite `CHANGELOG.md` + the code instead. `make docs-check`
  reports `~`-rooted refs separately from failures (mechanical, not rhetorical). Time-aging applies
  to any such vault: a page saying "implemented" is not a commit — check
  `git merge-base --is-ancestor <wiki-head> <real-head>` plus symbol greps.
- `.hermes/` is gitignored and holds only an old roadmap; untracked scratch is not shareable
  evidence, and where it conflicts with `AGENTS.md`/`CHANGELOG.md` it is history, not truth.
