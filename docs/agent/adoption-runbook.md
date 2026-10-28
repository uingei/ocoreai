# Adoption runbook — what the leaders run, with the cite that proves it

> Long form behind § *Adoption* in `AGENTS.md` and the rungs of `docs/agent/long-horizon-goal.md`.
> The ladder owns *order and falsifiability*; this file owns *mechanics* — what each mechanism is, which
> tree ships it, and `file:line` in a local clone. Every number is a dated snapshot with the command that
> re-measures it; a stale cell is yours to notice.
> Cites are written `../references/<tree>/<path>:<line>` because that is the form `make anchor-check`
> resolves and verifies, and because a bare `README.md:20` would silently resolve against our own README.

## The leaderboard (stars are the only ranking GitHub publishes for a repo)

`curl -sL api.github.com/repos/<owner>/<repo>` — api.github.com is authoritative for HEAD (§ Upstream), a
mirror proves content, never HEAD.

Age and rate are columns now, because 10-28's re-measure turned up a tree created eleven weeks ago that
outran every premise written here. Re-measure: `curl -sL api.github.com/repos/<owner>/<repo>`, then
`stars ÷ (today − created_at)`; the shape, not the number, is what the ladder reads.

| repo | stars | age d | **stars/day** | forks | open iss+PR | what the number is made of |
|---|---|---|---|---|---|---|
| openclaw/openclaw | 393 221 | 338 | **1 163** | 82 663 | 7 694 | local-first assistant; 6 native apps + 20+ chat channels |
| deepseek-ai/deepseek-harness | 263 687 | 76 | **3 469** | 31 890 | issues off | agent harness, everything-a-plugin; issue tracker disabled, Discussions on |
| NousResearch/hermes-agent | 257 756 | 463 | 556 | 56 519 | 51 492 | agent harness + skills/plugin catalog |
| anomalyco/opencode | 222 385 | 546 | 407 | 29 767 | 3 865 | terminal coding agent; 22 README locales |
| ollama/ollama | 185 027 | 1 220 | 151 | 18 659 | 4 468 | local server, two engine families behind one API |
| openai/codex | 131 273 | 563 | 233 | 20 739 | 25 124 | terminal agent + IDE + cloud surfaces |
| earendil-works/pi | 118 294 | 445 | 265 | 15 153 | 380 | minimal coding agent; extensions over core |
| vllm-project/vllm | 95 715 | 1 357 | 70 | 24 070 | 9 616 | serving (not an agent) |
| OpenHands/OpenHands | 92 031 | 959 | 95 | 12 227 | 1 138 | agent platform |
| Niko1221/Strata | 34 577 | 34 | **1 016** | 3 708 | 955 | local-AI product: desktop app + agent terminal + multi-backend engine |
| aaif-goose/goose | 55 836 | 796 | 70 | 6 480 | 530 | agent platform + ACP |
| sgl-project/sglang | 38 288 | 1 024 | 37 | 9 937 | 6 210 | serving (not an agent) |
| jundot/omlx | 23 108 | 257 | 89 | 2 071 | 573 | MLX server + native menubar app (closest published distribution analogue) |
| apple/coreai-models | 2 225 | 142 | 15 | 242 | 48 | our pin 2 |
| ddalcu/mlx-serve | 2 114 | 253 | 8.4 | 227 | 84 | MLX serving; 55 area guides |
| ashhart/TensorFold | 1 505 | 131 | 11 | 310 | 143 | Zig Metal engine + packaging |
| ml-explore/mlx-swift-lm | 848 | 391 | 2.2 | 445 | 127 | our pin 1 |
| **uingei/ocoreai** | **1** | 136 | **0.007** | **0** | **0** | this repo |

Two numbers decide how the ladder reads. Effort, one 14-day window (`git log --since='14 days ago'
--oneline | wc -l`; tags from `git tag | wc -l`; author emails from `--format='%ae' | sort -u`):
openclaw 11 359 commits / 543 tags / 320 emails, hermes-agent 5 714 / 234, TensorFold 2 724 / 50,
Strata 2 381 / 67, deepseek-harness 1 570 / 33, opencode 1 126 / 1 156, codex 587 / 1 501, ollama 62 / 719 —
**ours 1 453 commits, 4 authors, 0 tags.** Rate is the finding that had to
delete a sentence: this file claimed the field's best sustained rate is ~150/day and openclaw's total is
"~7 years of growth". Measured 10-28 the category's own record is **263 687 stars in 76 days**
(deepseek-harness, 3 469/day), with openclaw at 1 163/day and Strata — created 2026-09-24, the closest
product shape to ours — at 1 016/day on 3 708 forks. So #1 is not bounded by arithmetic, elapsed time, or
engineering throughput; it is bounded by whether something outside the repo defaults to it. Two of the
three fast movers are institution-shipped (DeepSeek AI ships `dsh` under its own homepage; openclaw is the
501(c)(3) that employs its team and signs its releases), the mechanism a 1-star repo does
not have — and the honest response is the wedge rank in `docs/agent/long-horizon-goal.md` § Rung zero:
be *consumed* (rungs 1 and 6) rather than be admired. A star count stays a pruned estimate: the morning pass
found opencode 419 stars *below* its own two-day-old snapshot, and today every tree read higher than that
pass, which does not undo the pruning — it proves one delta cannot show it. No rung targets a day-delta; the
column ranks machines, not resolutions.

## The install machine (every tree in this set has all four parts)

- **An installer that provisions its own runtime**, so the reader's machine is not a premise:
  `../references/openclaw/README.md:30`, `../references/pi/README.md:28`, `../references/codex/README.md:19`,
  `../references/opencode/README.md:50`. Ours: `swift build -c release`, or a DMG behind a tag that does not
  exist, plus the Gatekeeper right-click that `README.md` documents.
- **A package manager, ideally self-serve:** `../references/codex/README.md:47` (brew cask), and
  `../references/omlx/README.md:58` — `brew tap jundot/omlx <repo-url>`, whose formula lives in the repo
  (`Formula/omlx.rb`), so publishing a release needs no third-party merge. A cask/tap is the difference
  between "readme archaeology" and one line.
- **Update inside the app,** so the second install costs nothing: `../references/omlx/README.md:53`
  (auto-update plus a `~/.omlx/bin/omlx` shim so terminal commands *and Apple Shortcuts* drive the
  app-managed server), and openclaw ships `appcast.xml` + `appcast-arm64.xml` + `appcast-x86_64.xml`
  (Sparkle). Ours: `Sources/ocoreai/Core/UpdateCheck.swift` parses the latest release and hands back a
  *release-page URL* for the Settings screen — a notification, not an update.
- **Degraded install, not failed install:** `../references/omlx/README.md` ships the native kernels behind
  an optional flag (`--with-custom-kernel`, needs full Xcode) so a machine without Xcode still installs.
  That is invariant 2 applied to packaging: install what your machine measured, and say which half you left.
- **Channels and release shape:** canary vs stable (`hermes-agent` `canary-release.yml`,
  `stable-release-publication.yml`), a rehearsed release (`opencode` `release-dry-run.yml`,
  `nightly-beta.yml`), and goose's version-bump-PR → release-branch → close-on-tag trilogy
  (`create-version-bump-pr.yaml`, `close-release-pr-on-tag.yaml`). Ours is two files now: the DMG's build
  half rehearses on `main` under `contents: read` (`package.yml`); only publish is tag-gated and unrun.

## The intake machine (what 320 author emails in 14 days costs)

- **vllm** `../references/vllm/AGENTS.md` — the policy an AI-assisted contribution must satisfy: `:8`
  duplicate-work checks as runnable `gh` commands, `:21` no low-value busywork PRs (a lone typo is not a
  contribution), `:27` no pure code-agent PR — a human must defend it, `:35` a user-visible change updates
  the rendered docs *in the same PR*, `:39` fail-closed: if it is duplicate or busywork, do not proceed,
  return the reason. Our analogue of `:8` is "grep for the mechanism that already exists", applied to
  symbols; nobody has written it for issues and PRs yet.
- **mlx-swift-lm** `../references/mlx-swift-lm/AGENTS.md` — `:5` AI-generated code is allowed, code you
  cannot explain is not, and AI-drafted prose is allowed only if the human read every word; `:24` the agent
  may draft a PR description and **may not open the PR, issue, or reply on the author's behalf**, with the
  refusals scripted verbatim so the boundary is not improvised per session.
- **pi** — `.github/APPROVED_CONTRIBUTORS` (411 lines) as merge policy in data, and `README.md:40`
  `npm install -g --ignore-scripts` as an explicit supply-chain contract (a normal install runs no
  lifecycle scripts).
sglang- **opencode** — intake closed by bots (`triage-close-issues.yml`, `triage-close-prs.yml`,
  `triage-pr-standards.yml`, `triage-contributor.yml`), and 22 README locales kept fresh by
  `bot-docs-locale.yml`. Latency is the product: 3 865 open issues at 222 k stars.
hermes- **deepseek-harness** — intake and review as *code with its own tests*: `.github/issue-management/`
  (`policy.mjs`, `rules.mjs`, `lifecycle.mjs`, beside `policy.test.mjs`) and `.github/review-ownership/`
  (`approval-policy.json`, `author-weight.mjs`, `check-approval.test.mjs`) publish an approval **weight** per
  reviewer derived from blame ownership, delegable in points, surfaced as a check by
  `.github/workflows/weighted-approval.yml`. That is one step past sglang's permissions-as-data: who may
  approve is itself data, unit-tested. It runs at 263 k stars with `has_issues: false` — the tracker is off,
  the policy is the queue.

- **openclaw** — governance in the README: a 501(c)(3) that employs the core team and signs releases, with
  donors listed and expressly *not* owners ("OpenAI is a donor, not an owner"), plus `VISION.md` and a
  docs site. Institution, not vibes, is what a stranger delegates to.

## Agents as clients — the rung the audit says to take first

The leader does not compete with a local engine, it **consumes** one: "Models and agent harnesses (Claude,
Codex, local models) are plugins you can swap" (`../references/openclaw/README.md:20`). Every harness tree
here needs a model behind it; ocoreai is the only tree that is model *and* harness on one die, offline, with
no key. So the wedge is not to out-loop codex — it is to be the local-model plugin those loops install.

What that costs, and what landed 10-28 (the audit's own first pass over-claimed the gap: it had not read
`GET /v1/capabilities`, invariant 2 cuts both ways):

halfcontractskill- **The instrument runs the artefact**: `scripts/probes/39-skill-contract-exec.sh` boots its own server and
  executes every marker — 14 `exec:` on the scripted lane (nothing resident) and 5 `exec-model:` against a
  ready checkpoint — flooring its own marker counts at 12/4 so a scan that stops matching is red, not
  vacuously green. CI runs it as its own step since 10-29 (7 s on the runner).
notproven## The first screen — twenty lines decide

- **Badge the artefact, not the language**: opencode `README.md:12-14` (Discord members, npm version,
  release-workflow status), omlx `README.md:12-14` (license, Python range, **platform: Apple Silicon** — the
  reader self-selects), hermes-agent `README.md:10-16` (docs site, Built-by-Nous, three locale badges).
  `README.md:5-8` here badges Swift, platform, license and CI: the language, not the thing to install. A
  version badge is unreachable until a tag exists — rung 1's second cost.
- **Route, do not describe**: codex `README.md:6-8` sends the IDE / desktop / cloud reader elsewhere before
  line 10, then installs in one line at `:19` (`brew install --cask codex` at `:47`); pi `README.md:21` lists
  interactive / print-JSON / RPC / SDK; omlx `README.md:23-28` anchors Install · Quickstart · Features ·
  Models · Benchmarks. Ours has no anchor nav and no install one-liner.
- **The policy line is a feature**: pi `README.md:11` says new-contributor issues and PRs are auto-closed and
  maintainers review them daily, and `:19` that Pi "skips features like sub-agents and plan mode. Ask Pi to
  build what you want". A promise about answering, and a named non-scope, both read as finished.
- **Locales are a channel**: opencode ships 22 README locales (`README.md:17-32`), hermes-agent 3
  badge-linked. Our P18 rule (English by default, exactly one Chinese file) is the owner's decision and it
  caps this channel — recorded as a priced cost of a rule, not a licence to break it quietly.
  deepseek-harness keeps exactly one English and one Chinese file too, and pairs them per heading by
  hash (`README.i18n.yaml`, re-recorded by one command), so a mirror that drifts is machine-visible: a second
  language without a bot.

- **Name the preview and the danger on the first screen** — deepseek-harness puts `SAFETY.md`, `BENCHMARK.md`
  and `BRAND_GUIDELINES.md` at the root and states "THERE WILL BE COMPATIBILITY-BREAKING CHANGES" above the
  run command; openclaw puts its privacy contract in README ¶2 with the telemetry doc named in the same
  sentence and one flag to silence it, plus `VISION.md` at the root. Ours carries a "Measured vs declared"
  block (the right instinct) and **zero** privacy or telemetry sentences in `README.md` — the cheapest line a
  local-first product can own, and the one a stranger checks before typing a model's worth of secrets.

## The proof surface — a gallery we own but do not publish

- pi publishes a **model catalog from CI** (`../references/pi/.github/workflows/publish-model-catalog.yml:1-14`),
  gated by a compatibility check and a minimum-version protocol (`scripts/check-model-catalog-compat.mjs`,
  `scripts/model-catalog-minimum-version.mjs`). vllm gives each feature its own page and documents how to
  extend it (`../references/vllm/docs/features/reasoning_outputs.md:441`).
- Our equivalent needs no new machinery and is invariant-2 native: `/v1/models` already publishes
  per-checkpoint *measured* verdicts (`vlm`, `contextLength`, `toolCallDelivery`, `reasoningEffort`,
  `videoInput`) and `scripts/eval/` holds a 39-task scoreboard. A generated README table plus `models.json` (absent),
  refreshed by a probe with its command beside it, puts a measured gallery where strangers look — the
  leaders' galleries are adjectives, so here honesty is also the louder surface.

## Corrections and new baselines (10-28)

- **Bind a comparator to its `origin`, never to a well-known org** (twice in one pass):
  `../references/pi` is `earendil-works/pi` (**118 294 stars**) while `badlogic/pi` measures **102**; `coreai-models` is `apple/coreai-models`, and `ml-explore/coreai-models` is a
  404. A mechanism claim bound to the wrong org is worthless even when every line in it is true.
- **Intent and load**, unmeasured here before — watchers: openclaw 1 696, hermes-agent 984, opencode 859,
  codex 666, vllm 607, **ocoreai 0**. Open issues+PRs (the API counts both together): hermes-agent 51 482,
  codex 25 097, vllm 9 609, opencode 3 853, **us 0** — and opencode answers its 3 853 with **five** triage
  workflows (`.github/workflows/triage-*.yml`). That is what the load costs; the load is not optional if the
  stars are wanted. Two settings cost nothing and 6+ trees already have them: Discussions is on for pi, codex,
  omlx, vllm, sglang and mlx-swift-lm and off here, and a homepage is set for 6 of the nine others.
- **The 20th tree, and what a tracker costs** (`deepseek-ai/deepseek-harness`, same day): 263 687 stars,
  1 115 watchers, Discussions on, homepage set — and `has_issues: false`. It carries 263 k stars with the
  issue tracker **switched off**, intake handled by policy code in `.github/issue-management/` instead of a
  queue. Our row is the cheapest delta on this page and is still unpaid: watchers **1**, Discussions **off**,
  no homepage, root `VISION.md` absent (openclaw ships one; a stranger reads it to judge direction).

## Not in this runbook

Star-buying, follow-trading, launch-week theatre, and any figure that has no command next to it. Adoption
machines are borrowed; the claims a stranger acts on stay gated by § *Two invariants* in `AGENTS.md`.
