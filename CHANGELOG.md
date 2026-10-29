# Changelog

The engineering diary of **ocoreai** — one dated round per entry, newest first, each answering three
questions: what improved, what same-session output proves it, and which gate goes red if it regresses
(contract: `CONTRIBUTING.md`). It is deliberately not a Keep-a-Changelog release-notes file — there are no
`Added`/`Changed`/`Fixed` sections here — so someone deciding what to install reads the newest release
note and `README.md`; a `## <dates>` section below groups the rounds of an older period, and dates on a
heading are when the work landed (measured from git).

## [Unreleased] — 2026-09-05 → 2026-10-29
**10-29(54) The gate shipped an hour ago could be quieted by writing a sentence**

- **What improved.** Entry 53's count indexed every tracked file, `*.md` included, so naming a dead
declaration in prose made the scan stop seeing it — measured, not suspected: entry 53 itself names
`photoOutput` and `streamDidBecomeActive`, and its count fell 24 → 22 with no line of code deleted. The
index now skips `*.md`, because a reference is a caller and not a sentence; the honest count is 27,
`AGENTS.md` carries `unreferenced_decls<=27` at the same digit width, and root stays at 21 437 B.

- **What same-session output proves it.** The fall between two runs of one script, with the tree otherwise
unchanged, is what surfaced it. After the fix the same 27 names print under `OCOREAI_DEAD_VERBOSE=1`, the
two that prose had just un-masked among them; `swift build` exit 0 and `make docs-check` green in both
host modes.

- **Which gate goes red if it regresses.** Re-sampled at the new number: one appended
`func anotherGratuitousProbe()` printed 28, and P4 answered
`unreferenced_decls <= 27: command returns 28`. The lesson is § Testing Quality's own sentence, re-proved
against me this time: a scan that reads prose to decide what counts as code infers its own premises, and
the day someone documents a dead thing is the day that gate stops seeing it.


**10-29(53) 787 lines nothing named, and the count that stops them growing back**

- **What improved.** *No line is gratuitous* was a taste sentence; it is a measured one now.
`scripts/unreferenced-decls.sh` counts the declarations in `Sources/` whose name occurs exactly once in
the tracked tree — at its own declaration — and `AGENTS.md` carries `unreferenced_decls<=24`, a
shrink-only ratchet re-run by `make docs-check` here and by `Text gates (ubuntu)`. Its first pass found
76, and 63 declarations went out across 28 files (787 lines): six `StructuredLogger` level wrappers nobody
called, a `DecodingStrategyFactory` whose only case was the one strategy that exists, the `parseJSON` /
`AuthConfigError` pair behind it, the profiler's tokenizer/inference/decoding brackets, an orphaned FTS
rebuild-and-purge pair, a 76-line rule-based event extractor and the memory-event API it served, and dead
setters in `EnginePool`, `AdmissionGate`, `LoadedModel` and `MCPStdioTransport`. Two deletions are
correctness, not golf: `ChatHandler` and `AnthropicMessagesHandler` each mapped `SchedulerError` through a
`default:` the compiler itself called dead (*default will never be executed*), so a fourth refusal reason
added to that enum would have reported `engineUnavailable` on the wire; now it fails to compile, which is
what § Error Handling already promises.

- **What same-session output proves it.** `swift build --build-tests` exit 0 before and after is the proof
— the test target compiles too, so nothing in the tree, tests included, named a deleted declaration.
`make anchor-check`: 75 anchors, 0 drift, so no cite moved off the code it claims. The instrument's blind
spot is written in its own header: it is text-only over `git ls-files` (host-independent, per entry 52),
so a witness to an *external* protocol looks dead and is not — `photoOutput`, `streamDidBecomeActive`,
and the `@available(macOS 27)` CoreAI and Video paths are among the 24 left, and `OCOREAI_DEAD_VERBOSE=1`
names every one. Two finds were named, not deleted, because they are owner-visible: `MTPDrafterContext`
occurs once repo-wide and `MLXModelLoader.loadMTPDrafter` exists only inside a comment, so `LoadedModel`
's drafter container is written solely by a setter nothing calls and `hasMTPDrafter` is constant-false
where `EnginePool.swift:1217` reads it; and `memory_events` (table + FTS index + 3 triggers,
`SQLiteStore.swift:670`) now has no API in the tree at all.

- **Which gate goes red if it regresses.** `unreferenced_decls<=24`, sampled red before it was believed
green: one appended `func gratuitousProbeForTheGate()` moved the count to 25 and `make docs-check`
answered `P4 1 claim(s) do not reproduce: unreferenced_decls <= 24: command returns 25`. That is the tax
and the point — a legitimate new delegate witness moves the number too, and the honest answer is to delete
another dead name in the same commit rather than raise the cap. Root paid for the claim out of its own
header (21 440 → 21 437 B, chain 32 455/32 768) and `comparator-repos.md` 's two figure sites were
re-derived in the same commit; 0.9 s on ubuntu, no arm64 minutes.

**10-29(52) The claim I shipped was red on the runner twice, and the second red was my fix**

- **What improved.** 9065cb3 added `tags_published>=1` to `AGENTS.md` so that “ours: 0 tags, 0 releases”
can never quietly come back. It passed every gate on this host and failed the runner in 1 s:
`Text gates (ubuntu)` ran its command, `git tag | grep -c '^v'`, and got 0, so P4 called the claim
non-reproducing and the leg died with the four steps behind it. The first fix was wrong and the runner
said so on the next push — `fetch-tags: true` on the job left the annotation byte-identical — so the claim
still read state the checkout had not supplied. What ships now removes the dependency instead of feeding
it: the command asks the remote (`git ls-remote --refs --tags origin | grep -c 'refs/tags/v'`), which
needs no fetched tags, no depth and no action input; `fetch-tags: true` is reverted, because it
demonstrably changed nothing here and its comment claimed it did. Why the runner differs is *not* settled,
so no mechanism is asserted: a local `--no-local --depth 1 --no-tags` clone fetched with
`--depth=1 --tags origin refs/heads/main` does return `v0.1.14`.

- **What same-session output proves it.** The runner’s own words, quoted not reconstructed:
`P4 1 claim(s) do not reproduce: tags_published >= 1: command returns 0  [git tag | grep -c '^v']`,
identical on two consecutive pushes, the second run 40849971793 / job 123366726311 failing at the step
`AGENTS.md contract`. Inside a `--no-local --depth 1 --no-tags` clone of this repo — the runner’s
observable state, where `git tag` answers 0 and `git describe --tags` is fatal — the new command prints 1,
and it prints 1 here too. `make docs-check` is green in both host modes afterwards, root down to 21 440 B
while the claim grew 36 B.

- **Which gate goes red if it regresses.** The class, not the instance: P4 in
`scripts/agents-md-contract.sh` now refuses a claim whose command reads the local ref store, namely
`git tag|describe|rev-list|merge-base|branch|remote`, sampled against this exact red — re-adding
`git tag | grep -c '^v'` reddens the gate on this host, where the same edit was twice green — and that
claim was the only one in the tree to match, so nothing was reclassified to make the check pass.
`tags_published>=1` itself stays, because deleting a claim to silence a red is the wrong exit, and the
next push is its third verdict.

**10-29(51) The HTTP surface got a contract it cannot lie with, and six files noticed we had already shipped**

- **What improved.** The surface now publishes a machine-readable contract instead of a description of
itself: `GET /openapi.json` renders OpenAPI 3.1 from `V1EndpointCatalog` — the index
`V1EndpointCatalogTests` already pins to the router — and `openapi.json` at the repo root is those same
bytes, written by the new `ocoreai --openapi` token through `make openapi`. ollama and opencode are the
only two of the twenty comparator trees that publish a spec at all (measured 10-29), and both keep it by
hand or by a separate generator; ours is derived, so the copy nobody remembers does not exist.
`AuthRoutePolicy.publicPaths` gained the route — every path and auth scope a contract discloses is already
public on `/v1/capabilities`, so it hides nothing new — `error.type` is an enum of the three values the
emit site actually writes (`app_error`, `invalid_request_error`, `rate_limit_error`) rather than the one
constant the first draft claimed, and `servers` is `/` because the bind truth lives in four `OCOREAI_PORT`
reads and a fifth copy would describe a deployment that may not exist. The same round fixed the bug class
this artefact exists to prevent, in our own docs: `v0.1.14` shipped 10-29 while six files still said 0
tags / 0 releases and named `v0.1.14` as the number to type next. Corrected in `AGENTS.md`, in
`long-horizon-goal.md` (3 sites), in `adoption-runbook.md` and in `competitor-iteration-paths.md`; the
stale-release-row item moved to `closed-items-log.md`; the re-typed version number left `AGENTS.md` for
good, and two stray tokens (`halfcontractskill-` and `notproven`) that had been rendering in the runbook
since 10-28 left with it.

- **What same-session output proves it.** `make openapi` → 41 176 B, 33 paths, 35 operations, straight off
the built binary, and `json.load` parses it. `make test FILTER='V1EndpointCatalog|OpenAPIContract'` → 14
tests / 2 suites green; `FILTER=CLIModeTests` → 6/6. The artefact gate's own red was sampled before it was
believed: with `print` still owning the newline, the committed file and the render differed by one
trailing byte, and the gate said so with the remedy — run `make openapi` and commit the file in the same
change. `make docs-check` reports 33/33 claims in both host modes, including the new `tags_published>=1`;
`anchor-check` 75/75; codespell clean. Release state re-read from `api.github.com`: 1 release, `v0.1.14`,
0 d, one asset at 25 965 037 B; `git tag | wc -l` = 1.

- **Which gate goes red if it regresses.** `OpenAPIContractTests` (5): the committed file against the
render with `info.version` the only tolerance; spec method+path against the catalog in both directions
with a floor of 30 operations; every `{param}` declared and `model` still stating the `%2F` rule probe 03
measured; `required[]` and the `error.type` enum re-read from the literals at the two emit sites instead
of typed into the test; and no host or port literal anywhere. `CLIModeTests.openAPITokens` pins the token
and that a report owns exactly one newline. `V1EndpointCatalogTests` keeps route and auth set equality —
now 35 routes, 8 public paths — and pins both READMEs' public-route lines in the same change. Live half:
`scripts/probes/42-openapi-contract.sh`, no weights — §2 spec against the served index, §3 a real 404
carrying the documented keys, §4 `info.version` against the same binary's `--version` and its route set
against that binary's stdout. Deliberately no CI seat: a stale artefact already goes red inside
`make test-ci`, and a second job over one claim buys runner minutes, not verdicts. Docs:
`tags_published>=1` re-runs `git tag` on every `make docs-check`, so the next release moves the sentence
or stops the build.

**10-29(50) v0.1.14 published — the launch leg ran its own job for the first time, and the board landed on a real model**

- **What improved.** The release job had never executed the job it exists to run (v0.1.12 died twice at
`upload-artifact`; everything after was rehearsal). Tag `v0.1.14` @`ffc58e0` ran Release DMG end to end:
MetalToolchain → appStore-trait DMG (25 965 037 B) → window proof → probe 41 with the version pinned to
THE TAG → publish → read-back. Same round adds the scoreboard's real-model arm: same `tasks.json+b709e8aab69d`
and tool hash `d9b1028a196a`, 6-tool face, k=2, `mlx-community/Qwen3.6-35B-A3B-4bit` (the only other
checkpoint resident in `~/.ocoreai/models`; config `modelId` swapped for the run, restored after).

- **What same-session output proves it.** Release live: `github.com/uingei/ocoreai/releases/tag/v0.1.14`,
asset digest `sha256:229604e0…e1f454`, all ten job steps green. Board: **34/39 (87.2%), SD 0.00, FLAKY 0**
against the gemma-e2b 6-tool arm's 22.67/39 (58.1%) — different checkpoints, so color not paired verdict;
the shape is the fact: **every Execute/Verify face passes 34/34 stable**, all 5 stable-fails are faces this
file already names (3 structured `json-*`, 2 honesty `no-fabrication*`). Efficiency: ms_per_success 11 944,
tokens_per_success 2 944, usage parsed 39/39.

- **Which gate goes red if it regresses.** the tag path itself: probe 41 sits before Publish (a red
publishes nothing), the read-back step judges the published digest, and `ci-status.sh` counts the leg. The
board row is re-runnable: `_repeat_stats.py` + the `# conditions` line name model, binary and tool hash.

- **Honest limits.** 87.2% is k=2 — single-run floor ±4.1 tasks; the gemma comparison is unpaired across
models, not an A/B; the two AGENTS.md sentences that still say "0 tags, 0 releases" and "publish has never
run" are stale against this entry and await the owner (protected path).

**10-29(49) `push-ready` ran its gates behind the one wall every push walks past**

- **What improved.** `worktree-hygiene.sh` opened the recipe, and its first failure is almost always "N
commits ahead of origin" — whose remedy is the push itself. So the runner-premise docs contract two lines
below it never executed on the way to that push, which is how tonight's red cite set reached CI. Hygiene
now runs last: the cheap text gates judge the tree first, and hygiene still decides the exit code, with
the uncommitted-Makefile case proving it bites.

- **What same-session output proves it.** reordered run of `make push-ready`: the docs contract, pattern
audit, style lock and route contract all executed, ci-status reported `Text gates (ubuntu) success` for
81c314b — the leg that failed for 77a122f — and hygiene closed the run naming the one dirty path.
`makefile-parse-check` parses 31 recipes (floor 20).

- **Which gate goes red if it regresses.** this target itself: move hygiene back to the front and the pre-
push docs gate stops running on exactly the path that needs it, with no local signal — the signal is a red
`Text gates` leg minutes later, which is what 10-29(48) paid for.

- **Honest limits.** four legs for 81c314b (both Build & Test halves, the appStore trait compile, the iOS
compile) had not reported when this was written, so the round's suite verdict is still pending; and
reordering cannot make a skipped run honest — it only removes the wall.

**10-29(48) CI said what the host could not: five cites were dead on a runner, and the gate that catches them was already there**

- **What improved.** the adjudication doc reached main green locally and red on `Text gates (ubuntu)` in
the same minute: the CI job sets `OCOREAI_AGENTS_NO_HOST_REFS=1`, which strips the host's `~/references`,
and five upstream paths in it (`InferenceEngine.swift`, `LanguageConfig.swift`, `Logger.swift`,
`NDArray+Helpers.swift`, `Bundle/LanguageConfig.swift`) resolved only through that mirror. They now name
the tree in the table header that carries them, and two more defects the same mode exposed went with them:
an unescaped `|` inside two table cells (a row stops rendering there) and a `metadata.json` cite that
reads as a repo path when it is a file inside a downloaded bundle.

- **What same-session output proves it.** the failed step from the run's jobs payload is `AGENTS.md
contract`; `OCOREAI_AGENTS_NO_HOST_REFS=1 bash scripts/agents-md-contract.sh check` reproduced it verbatim
on this host (5 unresolved → 1 → 0) and now reports table-defects=0 in both modes. The verdict came from
the artefact, not from a guess: the step name is what pinned the cause.

- **Which gate goes red if it regresses.** `make push-ready` already runs the contract with
`OCOREAI_AGENTS_NO_HOST_REFS=1` — the remedy existed and I pushed past it, so no new gate is warranted and
none was added; the gap was the path not taken. What is new since this round is the diary-shape check in
the same script (P20), which a future session cannot walk past as easily.

- **Honest limits.** the four legs still running for 77a122f (both Build & Test halves, the appStore trait
compile, the iOS compile) had not reported when this entry was written, so this round's CI verdict is the
text-gate fix plus those pending legs, not a green suite. And the host-vs-runner split is not solved by
this fix: a cite into `~/references` still passes plain `make docs-check` here, which is why the runner-
premise mode is the one that belongs on the push path.

**10-29(47) The CoreAI fork got read: 36 upstream commits, one verdict each, and the ledger now says 0**

- **What improved.** make drift printed 8/10/7/6 un-adjudicated for the four CoreAI engines and could not
measure three other files at all, because the only provenance token it could read was `Absorbed:`. The
script learned one token — `Adjudicated: <sha>`, which moves a window's start and claims nothing about
code — and all 12 `Engine/CoreAI*.swift` files now carry it. Every verdict (36 commits: 7 absorbed, 21
n/a, 8 open) has a row in `docs/agent/coreai-fork-adjudication.md` naming the line in our tree that
decides it. The coreai-models axis is adopted to `0aff938` after its window was read, not before.

- **What same-session output proves it.** ledger before: 未裁决 8/10/7/6 plus three 窗口不可测 lines; after: 12
rows and 未读 0 个 on every file. Adopting exposed a second flaw on the same screen — the axis read
`origin/HEAD` (already `0aff938`) while the fork ledger read the checkout's `HEAD` (`7fd2063`), so a stale
mirror tip silently under-reports; both now take one ref and print it. Absorbed rows are cites: #237's
prefix cap at `CoreAIPipelinedEngine.swift:186-189`, #248's logits rule at `EngineInference.swift:326`,
#240/#274's chunking defaults at `CoreAIEngine.swift:166,175,191`. Open rows rank cheapest-first: #368's
JSON whitespace bound (ours compiles `anyWhitespace: true`), #357's metadata asset names (ours hardcodes
three filenames in `Video/WanPipeline.swift`), #302's ~500-line static-shape rewrite.

- **Which gate goes red if it regresses.** `make drift` recomputes every count, so a divergence nobody
wrote down reappears as the same number on the next run — the ledger is the lock, and the rule that a
window closes in the header plus a row now sits in `Engine/AGENTS.md`. The report only finishes because of
10-29(46). The header edits moved 13 line-cites; all were re-grepped and `make anchor-check` reports
75/75. The second gate here came of a self-inflicted red: the previous entry lost its heading to one of my
splices, reached main, and every gate stayed green. `agents-md-contract.sh` now requires each entry's
first bullet to have a heading above it (48 paired here, floor 40), and the same scan immediately found an
older wound of the same kind — 10-29(40) had reached main without a heading as well; its number came from
its neighbours and its title from its own first bullet, so nothing was invented.

- **Honest limits.** nothing was ported — every absorbed row cites code already in the tree, every open
row names an action rather than taking it. "n/a" means the surface is absent from our fork today, and the
batching family (#335/#367/#377, ~860 upstream lines) is the n/a nobody should read as "not worth it".
`Adjudicated:` closes a read window, not a decision: the 8 open items live in the doc, not in root § Open
(12 bytes free), so the pointer sits in `Engine/AGENTS.md`. The whitespace bound and the Wan asset names
both wait on a measurement, not on an opinion.

**10-29(46) `make drift` exited 141 instead of 10, and the report died on the biggest window**

- **What improved.** the entry below asserted an exit code it had not run: `set -euo pipefail` plus a
truncating `head` means a window bigger than a pipe buffer kills the writer with SIGPIPE and the script
aborts mid-report. All four truncations in the script now drain the pipe instead — three use a `sed -n`
line range, one a `sed -n` first-line print — and the idiom is banned in that file rather than avoided by
habit, so the 0/10/1 contract its own head and the Makefile both document is the contract the code keeps.
The fork ledger added an hour earlier is report-only and unchanged.

- **What same-session output proves it.** both versions of the script, same tree, same command, side by
side: HEAD~ gives exit 141 three consecutive times and a report that stops at line 47 of 78 — the codex
axis header (+366 commits) printed, then nothing: no window list, no mlx-swift tag axis, no verdict line.
The fixed script prints all 78 lines and returns 10 through `>/dev/null`, through a pipe to tail, and
through `make drift`. The window that killed it is the one that matters most: 366 unread codex commits.

- **Which gate goes red if it regresses.** `DependencyPinStatementTests/driftTruncationDoesNotDieOfSigpipe`
— bans `| head` on non-comment lines (floors the scan at >=250 code lines read), requires the three
draining truncations to still exist so a rewrite to `awk … exit`/`sed Nq` cannot pass by looking clean,
and re-runs the mechanism on an 800 KiB producer so the lock stays explainable: if a future `head` stops
closing the pipe early, that half goes red first and says the ban is no longer priced by a red. Sampled
both ways this session — green on the fix, 2 issues against `git show HEAD:scripts/upstream-drift.sh`.
Reader: whoever runs the bump protocol or the adopt ladder; before this fix their screen showed a
plausible half-report and code 141, which reads as "environment, retry later" and silently stalls
adjudication.

- **Honest limits.** exit 0 was not re-exercised — no window is closed on this tree, and the tail block
returning 0 is untouched by the diff. The premise half measures this host's `/usr/bin/head`; a reader that
slurps the whole pipe would break it rather than hide it. The same idiom appears in `scripts/probes/` and
`scripts/audit.swift_patterns.sh` against values already held in shell variables, none measured near a
pipe buffer, so no guard was written for a failure nobody observed. And the correction stands: 10-29(45)'s
last sentence ("it does") was written before the code was run — invariant 2, applied to my own diary line.

**10-29(45) `Engine/CoreAI*` is a fork with a ledger, and no command could ask it anything**

- **What improved.** Twelve files under `Engine/` carry Apple's BSD-3 header plus a provenance line and a
baseline sha (`Absorbed: #N <sha>`, `@ coreai-models HEAD <sha>`), and nothing read them: `make drift`
compared each axis's HEAD against one baseline, so "how far behind is our copy of this engine, file by
file" was unaskable. The drift script now answers it before its axis loop — resolve each fork's upstream
counterpart (same-named file first, then the path the header names), read the recorded baseline, count the
upstream commits touching that file since. Report-only, so `make drift` keeps one exit-code owner. root §
Upstream now names `make drift`, which the injected file never had.

- **What same-session output proves it.** The block's first run: Pipelined `baseline 54e6163 … 8 un-
adjudicated`, Sequential `27a66f9 … 10`, StaticShape `5660fc6 … 7`, VisionConfig `5716935 … 6`, and three
files with no baseline at all — `CoreAISequentialVLMEngine.swift` (1 238 lines, 17 commits of upstream
history, window unmeasurable), `CoreAIEngine.swift`, `CoreAILoggerStub.swift`. Two open commits sit on
advertised surfaces: upstream `82c3488` (KV-state handling for static-shape + sliding-ring caches) and
`f03e8ce` (JSON whitespace under schema-constrained generation). The same pass removed a falsehood made an
hour earlier: an § Open line that still called `metallib` lane-proven after the step had been deleted.

- **Which gate goes red if it regresses.** None, on purpose — a per-file count with no threshold keeps the
exit semantics single-homed (0/10 as the script's own head documents). What changed is that a stale
baseline now shows up on the same screen as the axis verdict, instead of living in a header nobody re-
reads; `make drift` already exits 10 while any window is open — asserted, and false: it exited 141, see 10-29(46).

- **Honest limits.** Three files stay unmeasurable until someone adjudicates a baseline, and the biggest
is a 1 238-line VLM engine. The resolver matches by file name, so an upstream rename would print "path
unnamed" instead of a number. And nothing was adjudicated here: 8/10/7/6 are still open, which means
Apple's KV-state fix is not in our copy.
**10-29(44) The rehearsal paid for itself the night it deleted the thing it was rehearsing**

- **What improved.** `package.yml` came back green with no xcodebuild producer, so the release leg stopped
running it and the script is gone from the tree. The lane's shape is what caught the trap in my own
reasoning: the release job never installed MetalToolchain — the producer was the only thing standing
between it and a missing `metal` — so deleting the step alone would have left tag day with no shader
payload at all. It is now a component download that costs 6 s on a runner, which leaves the release leg
and its rehearsal differing by exactly one thing: the credential one job holds and the other cannot use.
The arithmetic is honest because the producer also pre-built shaders the DMG step reused: the step cost
633 s, the DMG step went 736 s → 1 111 s, and the lane's real saving is 258 s, not 633.

- **What same-session output proves it.** Run 40793195436 (9cca4ec): checkout 3 s, cache 6 s,
MetalToolchain 6 s, DMG 1 111 s, probe 41 3 s, window proof 29 s, wall 00:18:31 → 00:38:02 = 19.5 min
against 23.7 min with the producer; annotations `probe 41 verdict: … 12 passed, 0 failed, 8 measured, 0
known-open` and the version line, judged on a DMG whose payload SwiftPM compiled itself. The packaging
path trigger no longer names the deleted script.

- **Which gate goes red if it regresses.** The two that already existed and ran tonight against exactly
this artefact: probe 41 §1 reds when the shipped bundle's `Contents/MacOS/mlx.metallib` is absent or under
the size floor, and `build-app.sh` exits 1 when no candidate path carries a payload — its remedy now names
the delivery route as the CI cause. If the component download stops providing a compiler, the red lands on
`Build DMG` with that line attached.

- **Honest limits.** One lane sample per shape, and the release leg's new sequence has still never
executed: it is tag-gated, so its first pass is `v0.1.14`, where a red publishes nothing and costs a re-
run. The release leg deliberately carries no SPM cache — the lane's restored in 6 s, but an unproven cache
step on tag day buys minutes with a fresh failure mode, and minutes are not worth a first-day risk.
**10-29(43) "SwiftPM does not compile `.metal`" was a missing compiler, and the nightly lane stopped paying for it**

- **What improved.** The xcodebuild producer exists because a clean runner on 09-27 had no `metal`
compiler, and the step name generalised that into a claim about SwiftPM. The observation step 10-29(39)
added to answer exactly this came back with the answer: on the appStore leg, `swift build -c release
--traits appStore` printed `rung: swiftpm-product · 2 389 928 bytes` at the SwiftPM product path. That job
is checkout → cache → MetalToolchain → build → observation, so no xcodebuild ran, and the cache covers
`.build/checkouts` and `~/.cache/org.swift.swiftpm/repositories` — nothing restored that file.
`package.yml` now builds the DMG without the producer, which is 633 s of its 23.7 minutes; `release` still
runs it, because tag day is the wrong first day to learn the answer, and the script's header now states
the premise as measured instead of as a property of SwiftPM.

- **What same-session output proves it.** The annotations quoted above plus `delivery route: … metal=/priv
ate/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-…/Metal.xctoolchain/usr/b
in/metal`, which is why the compiler was there; `scripts/build-app.sh:15-17`, which evaluates `toolchain-
contract.sh print-delivery-env` itself when SDKROOT is unset, so no workflow step had to; and the script's
own error line, which has always told the reader to "run 'swift build' once (any config) so SPM
materializes the Cmlx bundle" — the build has been the producer all along.

- **Which gate goes red if it regresses.** Two, both already existing: `build-app.sh` exits 1 when no
candidate path carries the payload (its remedy now names the CI cause beside the local one), and probe 41
§1 reds when the shipped `Contents/MacOS/mlx.metallib` is missing or under the size floor — the 09-27
failure judged on the artefact that would ship it. No new check was written for this.

- **Honest limits.** The lane's verdict on its own deletion arrives with the run this push starts, not
before it: the numbers above prove SwiftPM built the payload in the appStore leg, not yet that `build-
dmg.sh` on that lane packages a serving app without the producer — probe 41 decides that, and a red there
is an answer rather than a mystery. Until it lands, `release` still pays 630–970 s, and this script is
deleted in a later commit with the lane's green behind it, not kept as a second producer.
**10-29(42) The deferred numbers arrived, and the first screen now points at the lane that produced them**

- **What improved.** 10-29(39) left two sentences in the air — whether the SPM cache bites, and whether a
window proof taken off `continue-on-error` survives — and the lane that ran d27a682 answered both:
metallib 633 s (the band before it was 777 s and 973 s on near-identical inputs), DMG 736 s (against 940 s
and 1 187 s), the artefact gate 2 s, and the window proof 26 s as a blocking step, green. The lane's wall
clock went from over half an hour to 23.7 minutes. Both READMEs now name that lane and its credential-free
permissions, and the badge row carries its live status, because a rehearsal nobody can see buys no trust.

- **What same-session output proves it.** Job steps of run 40787061588: metallib 633 s, DMG 736 s, probe
41 2 s, window proof 26 s, all `success`, with annotations `probe 41 verdict: artifact-dmg-serves: 12
passed, 0 failed, 8 measured, 0 known-open` and `artefact version verdict — expected 0.0.0 (no tag —
plumbing check only)` — the honesty line printed on a runner for the first time. P19 fetched both new URLs
(badge 0.73 s, page 0.63 s) before they entered the verified table.

- **Which gate goes red if it regresses.** None added. The window proof is the change that bites: it used
to be advisory, and a bundle that builds, signs, serves and renders nothing now reds the lane before
anything uploads. The metallib and DMG numbers are printed minutes with no threshold on purpose — a step
that gets slower is not a lie.

- **Honest limits.** One sample each, and the cache question is not fully answerable from here:
`actions/cache` does not publish hit-or-miss without a token, so 633 s is one observation below the old
band, not a measured saving. The lane still ships nothing — `contents: read` is the point — and the
artefact it judged reports 0.0.0 because no tag exists to tell it otherwise.
**10-29(41) The nightly DMG rehearsal existed and neither first screen mentioned it**

- **What improved.** Both READMEs enumerate the six `ci.yml` legs and stop, so a visitor could not see
that the artefact a stranger downloads is built and judged nightly on a clean runner by a job with no
publish credential. The CI bullet now names `package.yml`, its `permissions: contents: read`, the shared
`build-dmg.sh` route and the probe that mounts and serves the DMG, and the badge row carries the lane's
live status next to the CI one — a badge re-measures itself, which is why it replaces a status sentence
rather than joining one.

- **What same-session output proves it.** `/contents/.github/workflows?ref=main` lists `ci.yml` (40 848 B)
and `package.yml` (9 287 B), so the lane's badge path resolves; `scripts/build-app.sh:20` is the `swift
build -c release --traits appStore` line that `scripts/build-dmg.sh` calls with no arguments in both
lanes, which is what makes the rehearsal's artefact the same class the release job publishes.

- **Which gate goes red if it regresses.** None. The README tables keep their en/zh row-parity check
(`make docs-check` prints `README tables=N rows, N rows`) and neither sentence claims a colour, so nothing
pins the claim — the badges are the live answer.

- Existence, not health: the sentence says a rehearsal runs and can publish nothing, not that tonight's
ran. Both new links were then fetched for real — the badge in 0.73 s, the workflow page in 0.63 s — after
two earlier attempts from this host stalled past 75 s without an answer, which is github.com throttling
and the reason the docs contract refuses to treat a stall as a verdict ("most URLs unanswered is also
red", `scripts/link-check.sh`).

**10-29(40) The release leg got its probe, two dead steps died, and swallowed reds became countable**

- **What improved.** Two steps are gone and the class they belong to is now askable. `Collect artifacts
(Release)` assigned `DD=~/…/ocoreai-*/Build/Products`, and an assignment does not glob: `find "$DD"`
received a literal asterisk, `PRODUCT_DIR` came back empty, and the next line's `[ -f
"$PRODUCT_DIR/ocoreai" ] && cp` is a false test under `set -e` — exit 1 before the step printed a word,
with `continue-on-error: true` marking it green. Nothing was repaired: the artefact has no consumer
(`ocoreai-binary-` is named nowhere outside the two steps themselves), so the pair is deleted and the
Release *build* stays, as compile coverage of the workspace scheme. `scripts/ci-status.sh` gained
`OCOREAI_CI_REDS=1`, which reads the annotations of every green leg and counts the reds a `continue-on-
error` swallowed there.

- **What same-session output proves it.** `/actions/runs/{id}/artifacts` answers `total_count: 0` for both
green main runs (40777938090 = 2c71721, 40763127762 = 6e904aa), so the uploader has never once uploaded.
And `OCOREAI_CI_REDS=1 bash scripts/ci-status.sh 2c71721` prints `Build & Test (macos-26): 1 swallowed
red(s) behind a GREEN leg — Process completed with exit code 1`, the same line for `xcode-27`, then
`swallowed reds on green legs: 2` — the number this round exists to take to 0.

- **Which gate goes red if it regresses.** None added: a counter with no threshold is a measurement, and
the flag deliberately prints one. What makes it usable is that the number above is a *before* number — the
next main push printing anything but `0` names the leg whose green verdict is swallowing a red, and `make
push-ready` already runs the script, so the flag is one env var off the path being walked.

- **Honest limits.** Annotations exist only after a job finishes, and unauthenticated api.github.com is 60
req/h, so the flag stays a deliberate read and never a hook; it cannot see a swallowed red that printed no
annotation, and it does not judge whether a `continue-on-error` is earned — the release leg's upload pair
stays advisory for the recorded ArtifactService timeouts, and the screenshot upload with it.
**10-29(39) Three docs hedged a premise a runner had already settled, and a version verdict could only catch plumbing** (P2 docs/CI / symbols `package.yml`, `long-horizon-goal.md`)

- **What improved.** The artefact lane's second runner pass came back green end to end, so the sentences
reading "awaits its first green pass" became the measured list: metallib, DMG, probe 41, window proof. The
window proof lost its `continue-on-error` because the premise it hedged is measured, not assumed. Probe 41
joined the `release` leg *before* Publish with the version expectation pinned to the tag — read from
`version.sh` the verdict compares a build against the script that built it, which catches plumbing and not
the lie that matters (an artefact naming a version nobody tagged); on a tagless tree the step now prints
`no tag — plumbing check only` instead of a number that judges nothing. Both probe steps carry their own
`timeout-minutes`, so a stall names the probe rather than the job.

- - **What same-session output proves it.** Annotations of 2c71721: `probe 41 verdict: artifact-dmg-
serves: 12 passed, 0 failed, 8 measured, 0 known-open`, `window proof GREEN on this runner — candidate for
a blocking step`, and from the appStore leg `payload after Building for debugging...` — that truncated
tail is my own second bug, backticks inside a double-quoted YAML string ran a debug `swift build` and
printed its first line where a metallib rung was meant to appear. Caught before this push: an orphan `-
name:` step with no `run` and no `uses`, which parses cleanly and shows only to someone who reads the step
list; both files are now parsed and walked. The tag-pinned half was tested both ways against a 19-day-old
artefact: expecting 0.0.0 it prints `11 passed, 1 failed` with `FAIL the artefact reports 0.1.9, not
0.0.0`, expecting 0.1.9 it prints `12 passed, 0 failed` — the assertion bites one way and passes the
other, so it is not a constant.

- **Which gate goes red if it regresses.** Probe 41 is a blocking step in both lanes from here, so a DMG
that will not mount, serve, finish a scripted turn or stop cleanly reds before anything publishes; the
tag-pinned version verdict is the one assertion that can see an artefact naming a version nobody tagged.
No gate yet catches a doc calling a lane green that a runner never took green — that remains a reader's
job.

- **Honest limits.** The release leg's probe-41 step has never run: it is tag-gated, so its first pass is
the first tag, where a red costs a re-run and publishes nothing. The metallib step measured 777 s and 973
s on near-identical inputs, so package.yml now restores an SPM cache — whether it bites is the next push's
number, not this one's. Nothing is notarised, the artefact is ad-hoc signed, and the publish read-back
loop has never executed either.
**10-29(38) The orderly-stop noise has one owner, not two — the two-owner theory was tried and refuted** (P3 CI/Engine / symbols `41-artifact-dmg-serves.sh`)

- **What improved.** Probe 41 prints how many `error` lines a clean SIGTERM leaves behind, so the number
is in the harness rather than in a session's memory, and the comment beside it now records the theory that
died. The lines are Hummingbird's — `Server shutdown error: Already closed` and `Waiting on child channel:
CancellationError()`, both at label `HummingbirdCore` — and the reading was that two owners of the stop
raced: our `stop()` cancels the task holding the listener while ServiceLifecycle's own SIGTERM handler
quiesces the same channel. The one-line test of that reading is `runService(gracefulShutdownSignals: [])`,
which leaves the signals unclaimed. Built and run twice: `/health` 200 in 4 s and 2 s, exit 0 both times,
and 2 error lines every time. The mechanism is narrower than the theory — cancelling the task trips
upstream's `withGracefulShutdownHandler`, which then finds a channel already gone — and the lever is not
ours in the pinned Hummingbird: `Application` builds its `Server` inside `run()` and keeps no handle, so a
graceful stop means re-hosting the server, which is a new core surface for a log line.

- **What same-session output proves it.** The experiment and its numbers are above (exit 0, error-lines=2
twice with signals unclaimed; 0/1/2 across the runs that came before it), and the count is now printed by
probe 41 §3 on every artefact verdict — the same build of the same tree read two ways.

- **Which gate goes red if it regresses.** None was added: a counter with no threshold is a measurement,
and the repo deletes checks whose red changes nobody's action. What does bite stays bitten — probe 41
still reds on a stop that never comes, a non-zero exit, or a missing completion line. If anyone re-hosts
the server, the printed count moving to 0 is the visible proof it worked.

- **Honest limits.** In-flight requests are still cut by the cancel rather than drained, and nothing here
measures that — it would need a slow turn in flight at SIGTERM time, which needs a resident model, which
is the nightly lane and an owner call, not a log line. The experiment was reverted: unclaimed signals buy
no observable difference and drop a safety net.

**10-29(37) Three docs that own the adoption ladder were still describing a repo this one stopped being** (P2 docs / symbols `open-items.md`, `adoption-runbook.md`)

- **What improved.** Swept the prose that carries the ladder, not the numbers on it. `open-items.md`
carried a closed item as open — "The delivery shape's CI verdict has never run on a runner", closed 10-28
and already recorded in `closed-items-log.md` with the step name that proves it — so the duplicate is gone
(1 429 bytes), with the one live caveat it was carrying restored as its own item: the only first-token
figure we quote (22.1 s) ran with weights already on disk, and nothing is notarised, so neither the metric
nor the cask rung above it can be floored. Its release-credential item cited `ci.yml:437`/`:443`, lines
that moved when the metallib step became a script call, and asked for "a dry-run route so the release path
is exercised" — that half is now paid by `package.yml`, so the item says what remains: the split itself,
deliberately not touched before a first release lands. `adoption-runbook.md` said "we have one workflow
file" (there are two), "the DMG leg is tag-gated and has never run" (its build half rehearses on `main`
under `contents: read`), and "CI runs it from the headless-serve smoke step" (one probe per step since
10-29(29)).

- **What same-session output proves it.** The leaderboard row was the worst of them: it compared *total*
commits of eight trees against our *90-day* count — "ours 242 commits, 3 authors in 90 d" beside "openclaw
11 359 commits". Re-measured on the shared basis: `git rev-list --count HEAD` = 1 453, `git shortlog -sn
HEAD` = 4 authors, 0 tags, and the row now reads that. `make docs-check` is green, and the comparator
footprint tuple it re-derives moved twice today (21 454 → 21 440 root) and said so twice.

- **Which gate goes red if it regresses.** B2: a per-guide byte cap (all three files sit at 15 60x of 15
609, so a sentence added is a sentence chosen) and the re-measured footprint tuple. The stale-cell family
has no gate, and the file used to excuse that in prose — "nothing re-derives them, so a stale cell is
yours to notice" — which is now shortened to what it still covers (the star and fork columns), because the
cells it was excusing were wrong.

- **Honest limits.** Star, fork and stars/day figures are still dated snapshots with a command beside them
and no re-derivation. Of the three unpaid first-screen rows, two (Discussions, homepage) need settings a
token-less host cannot reach; `VISION.md` is the one that is only a decision.

**10-29(36) The rehearsal earned its keep in one second: the launch path's judge could not see its own subject** (P2 CI / symbols `41-artifact-dmg-serves.sh`, `package.yml`)

- **What improved.** `.github/workflows/package.yml` ran on a clean runner and reported: metallib
materialized in 777 s, `build-dmg.sh` built and uploaded the DMG in 1187 s, and the step that judges the
artefact died after 1 s. The cause was the lane's own argv: it handed probe 41 `dist/ocoreai-<ver>.dmg`,
and `run.sh` cds into `scripts/probes` before launching a probe, so the subject was no longer where the
name pointed and the probe reported "no artefact" — correctly, and in the time it takes to read a verdict.
Two fixes, because that trap belongs to nobody: the lane passes an absolute path, and the probe now
resolves a caller-relative artefact against the repo root (naming what it did) before it fails, so the
next caller cannot fall in it either. The step republishes probe 41's words as `::error::` annotations and
its passed/failed/measured/known-open line as a notice — the contract `ci-step.sh` keeps, since a red
whose log sits behind a token is a rumour — and the window proof runs `if: always()`, so one red no longer
costs the answer to a different question.

- **What same-session output proves it.** The runner's own step durations (777 / 1187 / 1 s) are public
through `/actions/runs/{id}/jobs`, and the reproduction here is the CI command line verbatim with the
relative path: after the fix it prints the resolution note and passes 12 assertions, `/health` 200 with no
checkpoint resident and SIGTERM exit 0. Probe 41 also now prints what an orderly stop says about itself:
across runs here that count was 0 and 1, the line being Hummingbird's `Server shutdown error: Already
closed` (or `Waiting on child channel: CancellationError()`) at label `HummingbirdCore` — upstream's
graceful handler finding a channel that our `stop()` already closed by cancelling the task that owns the
listener. Printed, not judged: the drain completes and the exit is 0, so the number is there to move if
anyone ever routes the stop through upstream's quiesce.

- **Which gate goes red if it regresses.** Probe 41 still judges the artefact itself, and the lane now
fails loudly in both directions: an artefact name that resolves to nothing is a red naming the remedy, and
a red prints its own words. `build-appstore` gained a zero-cost observation instead of a verdict — after
its `swift build --traits appStore` it prints what `resolve-metallib.sh` makes of the tree — because the
ladder says SwiftPM compiles `.metal` itself once the Metal Toolchain component is installed (mlx-swift-lm
`pull_request.yml:216-237`), and if a runner agrees then the 777-second xcodebuild is waste somebody can
delete from the release leg. Evidence first, deletion second.

- **Honest limits.** The lane's first GREEN pass is still pending — it is the next push, and AGENTS.md §
Open keeps the item until it lands. The window question is still unanswered, because that step was skipped
behind the red and only now runs unconditionally; the metallib step's 777 s is probably avoidable and no
runner has said so yet; and the release job still runs build and publish together inside `contents:
write`, which is the half of the split this lane cannot pay.

**10-29(35) Every leg that must pass on a main pass passed, so the launch path is now rehearsed, not hoped for** (P1 CI / symbols `package.yml`, `41-artifact-dmg-serves.sh`, `ci-materialize-metallib.sh`)

- **What improved.** `6e904aa` is the first main run where `scripts/ci-status.sh` exits 0 on every leg,
which turns rung 1's blocker from code into a hand. Then the same discipline was pointed at the one path
that has never run: the release job is gated on `refs/tags/v*`, so the only way to exercise it is the
thing it exists to do, and it has died there twice on non-code steps (no metallib on a clean runner 09-27,
the artefact-upload API at v0.1.12 twice). `.github/workflows/package.yml` now runs the release leg's
build half — materialise the shader payload, `build-dmg.sh`, judge the artefact — with `permissions:
contents: read`, so a rehearsal cannot publish even by accident. That is half of the build/publish split
`competitor-iteration-paths.md` names as the precondition for self-serve publishing: the job holding
`contents: write` no longer has to *prove* the build, though until a release lands it still runs both.
`scripts/probes/41-artifact-dmg-serves.sh` is the judge: mount the volume read-only, check what is inside
(executable bit, `/Applications` drag target, `Contents/MacOS/mlx.metallib` at ≥ 4 KiB, `codesign --verify
--deep --strict`, the version it reports), boot the binary *from the mounted volume*, answer `/v1/models`,
and drain on SIGTERM to exit 0. The seat is a nightly plus packaging-path pushes, which is mlx-swift-lm's
shape with its cite (`integration_tests.yml:3-4` keeps heavy integration tests off the PR path, `:22-27`
refuses to cancel a run mid-build), because this leg is ~25 arm64 minutes and the repo prices arm64
minutes as the expensive seat. The release leg's own metallib step became a call to
`scripts/ci-materialize-metallib.sh`, which resolves the payload through `resolve-metallib.sh` — the
inline glob it replaced re-implemented one rung of that ladder and floored nothing.

- **What same-session output proves it.** The green run is 40763127762 / job 123080256072, and its
per-step durations are public: locate 2 s, headless serve 3 s, probe 37 4 s, probe 38 3 s, probe 39 7 s,
inside a 31.5-minute leg whose xcodebuild and xctest steps took 787 s and 120 s. Probe 41 ran here against
a locally built DMG: 11 assertions green, `/health` 200 in 3 s with no checkpoint resident, SIGTERM exit 0
with the completion line. The runner's 4/3/7 s against this host's 2/10/25 s is the sound of the
checkpoint tiers not running there — no weights are resident on a runner — so `ci-step.sh` now republishes
each probe's passed/failed/measured/known-open line as an annotation, the half of a green that a step
title cannot carry.

- **Which gate goes red if it regresses.** Probe 41 itself: it reds on an unmountable volume, a missing or
undersized payload, a signature that fails, an artefact that reports the wrong version, a bundle that
cannot serve, a daemon that ignores a clean stop. Red sampled the same day by pinning a wrong version —
`11 passed, 1 failed`, exit 1 — and the version verdict is pinned in the lane
(`$OCOREAI_ARTIFACT_VERSION=$(scripts/version.sh)`), so a DMG whose About box lies about the number the
tag carries is a red, not a shipped surprise. The lane is path-filtered on the packaging chain, so a
commit that changes how the artefact is made runs it on the spot.

- **Honest limits.** `package.yml` has no runner verdict yet — this push is its first, and the item is in
AGENTS.md § Open until it lands. The window proof runs there as advisory because no GitHub macOS runner
has ever produced a layer-0 window here, and an unverifiable premise is not allowed to mint a red; it
becomes blocking when a runner prints the window. `Sources/**` is outside the path filter by design, so a
code change waits for the nightly (≤24 h) rather than buying 25 arm64 minutes per push. The publish half
is still tag-only and has never run; `git ls-remote --tags origin` is still empty, and
`scripts/version.sh` says the number to type is 0.1.14.



**10-29(34) The runner stall was a walk that could not reach the root: `${p%/*}` turns `/Users` into ``** (P0 CI / symbols `probe_scratch_for_binary`, `Class-M`)

- **What improved.** Three runs of evidence, then the cause in one line of bash. Run 1 gave a single
annotation ("timed out after 10 minutes", 607 s). Splitting the step (10-29(29)) made run 2 answer: headless
serve green, `Wire probe 37` killed at 193 s, 38/39 skipped. The heartbeat (10-29(33)) froze the probe log
before the harness's first note, which left the four calls ahead of that note, three of them pure path math.
`probe_scratch_for_binary` walks up from the binary until a component is `.build`/`.build-*`, and
`${"/Users"%/*}` is `""`, not `/` — so once nothing matches, `[ "$p" != "/" ]` is true forever and the walk
spins, silently, inside a command substitution. CI's smoke binary is an Xcode product under DerivedData,
where no component is ever `.build`; every local path has one, which is exactly why a harness bug aged its
whole life and never once showed on the machine that wrote it. The walk now stops at an empty component or
the root. While there: it also accepts `SourcePackages`, Xcode's `.build`, so a runner-built binary gets its
pin and cleanliness premise CHECKED where it used to print "not verifiable" — the excuse was the second
silent hole in the same three lines.

- **What same-session output proves it.** Reproduced here before touching anything: the old function on a
`.build`-free path was still running at 6 s and had to be killed; after the fix the same three paths return
empty in 0 s, `.build` still resolves to `.build`, `SourcePackages` resolves to `SourcePackages`, and probe
37 passes 20/20 in ~2 s with a 41 ms turn. The gate was sampled against its own red: with the bug
re-installed Class-M prints "had not returned after 10s … it costs the leg its verdict" and exits 1; with
the fix it reports Clean in 1 s. `make audit` exit 0, `make docs-check` green, anchors green.

- **Which gate goes red if it regresses.** `audit.swift_patterns.sh` Class-M, on the ubuntu text-gate seat
(no arm64 minutes for a bug in string slicing). It is bounded at 10 s by construction — a gate that
inherited the bug would hang instead of failing, which is the failure mode this class exists to catch — and
it asserts the positive cases too, so "fixing" the spin by always returning empty goes red as loudly as the
spin does. The reader whose action changes is whoever waits on this leg to tag: the verdict now arrives in
seconds, named, instead of at a step timeout.

- **Honest limits.** Local proof covers the walk, not the runner: the push after this one is the actual
proof, and it carries the phase notes and the 20 s server-log tail if anything else decides to wait. And the
runner now checks the smoke binary against `Package.swift`'s pin where it excused it before, so if xcodebuild
ever resolves a different mlx-swift-lm revision, probe 37 will say so there — that red would be the premise
working, not a new flake.

**10-29(33) The split leg answered on its first run: serve is green, probe 37 stalls in `probe_boot`** (P1 CI / symbols `probe_boot-phase-notes`, `ci-step-heartbeat`)

- **What improved.** The split paid for itself on one run. The commit that had carried a single 607 s
"timed out" annotation now reports: headless serve ✅, `Wire probe 37` ❌ at 193 s (killed on its own 180 s
bound), probes 38/39 skipped. The heartbeat pinned the boundary — the probe log's last line sat frozen at
"NOTE script …/ocoreai-script-XXXXXX.niZW2NiDUe.json — 2 segments, 1 tool call" from +30 s to +150 s, and
the statement after that note is `probe_boot`, so the wait was inside its first three calls, before any of
them printed. Two more notes and one tail now sit exactly there: `probe_boot` prints which phase it is in
(with the resolved scratch path, the value that decides which premise branch runs), and the readiness loop
prints the server log's tail once at 20 s — because in this run both the waiter and the served process
stayed silent for the whole window, and a silent waiter is the failure mode this repo already named twice.

- **What same-session output proves it.** Run 40751610289 annotations, read with no token: five heartbeats
carrying the identical last line (+30/+60/+90/+120/+150 s), "timed out after 3 minutes", and beside them
"swift-testing verdict: ✔ 3210 tests in 567 suites passed after 111.063 s" — so the suite and the serve
contract were green on that runner while the probe never reached its first bridge note. Locally after the
change: the notes print in order (`resolving` → `boot premise checked (scratch=…/.build)` → `binary …` →
`bridge …`), probe 37 passes 20/20 in ~2 s with a 41 ms turn.

- **Which gate goes red if it regresses.** The 180 s step bound is that gate, and it went red — usefully this
time, naming the probe instead of the step. Nothing new was added as a gate: notes and heartbeats print
measured lines and judge nothing, and the tag stays blocked by this leg exactly as § Open now says.

- **Honest limits.** A phase note names the call entered, not the await inside it, and the 20 s server-log
tail only helps if the server wrote anything at all. A local pass rules out the probe's own logic and the
checkpoint theory (killed in 10-29(29)); it does not prove the runner innocent of anything specific — it
narrows the search to what only a runner has.

**10-29(32) The first-screen row we call unpaid carried two numbers that had already moved** (P2 docs / symbols `first-screen-row`)

- **What improved.** The ladder's cheapest-to-pay sentence said watchers **0** and that "the leader ships one"
root `VISION.md`. Both had drifted. The repo now has 1 watcher (the owner — GitHub counts it, so the row was
stating an audience of zero for a repo with a subscriber), and the tree that actually ships a root `VISION.md`
is `openclaw`, the category's #1 — `deepseek-harness`, the tree that sentence was about, ships
`AGENTS/SAFETY/BENCHMARK/BRAND_GUIDELINES/README` with zh mirrors and no vision doc. The row now reads
watchers **1** and names openclaw, because that sentence's only job is to tell a reader what to copy and from
whom, and a wrong from-whom spends the reader's hour in the wrong tree.

- **What same-session output proves it.** `api.github.com/repos/uingei/ocoreai`: stars 1, forks 0, open issues
0, `subscribers_count` 1, `has_discussions` false, `homepage` empty, created 2026-06-14 (137 d by date
arithmetic). `git -C ~/references/<tree> ls-files | grep -i '^VISION'` across the 20 comparator trees:
exactly one hit, openclaw. `VISION.md` here: absent, as the row says. Both edits stayed inside their caps
(goal 15 604 → 15 603, runbook 15 600 → 15 602) and `make docs-check` passed without touching the corpus row.

- **Which gate goes red if it regresses.** None, and it is named as such rather than papered over: these are
prose counts, so the two commands above are the check a reader can run. What is gated is the container — the
per-guide byte cap and B2's figure sites — which is why an edit at this altitude is never free.

- **Honest limits.** `subscribers_count` is GitHub's own watch counter and includes the owner, so 1 is a floor
on the audience, not a measurement of it. The VISION search sees root-level tracked files in clones on this
box, and a tree can state intent in a doc that isn't named `VISION.md` — openclaw is the only one that names
it that way, which is a weaker claim than "only openclaw declares its direction".

**10-29(31) A red leg now names its step without a token, and a stalled probe names its phase** (P1 CI / symbols `ci-status-step-detail`, `ci-step-heartbeat`)

- **What improved.** Finding the 10-28 cause took manual API digging: the annotations said only "timed out
after 10 minutes", and the step list that named the 607 s step is a public endpoint nobody here had read.
`scripts/ci-status.sh` now reads it: for every failed/cancelled/timed-out leg it fetches
`/actions/jobs/{id}` (job id parsed out of the check-run's own `details_url`) and prints each step that did
not pass with its duration, so the next red answers "which step, how long" in one command. Two things it
depends on got fixed on the way: `$1` was used as both commit and remote URL, so the documented-looking
`ci-status.sh 9c4d434` derived `owner/repo="9c4d434"` and answered a 404 as "verdict UNKNOWN" — the wrong
remedy for a wrong argument — and a commit argument now resolves locally while a URL argument keeps working.
`scripts/probes/ci-step.sh` also heartbeats: every 30 s it publishes the probe's last log line as a
`::notice::`, because a killed step leaves nothing behind and annotations are the one channel readable with
no credential.

- **What same-session output proves it.** Against the run that actually failed, the new read prints
`Headless serve smoke (macos-26) failure 607s` beside the verdict it already gave; the short-sha argument
that used to 404 now resolves and reports the same leg. The heartbeat sampled at 3 s over probe 38 emitted
three notices — `bridge http://127.0.0.1:56437 · log …`, then the model line — and the step still finished
in 10 s with exit 0, so the instrument costs a 1 s poll and nothing else.

- **Which gate goes red if it regresses.** None of this judges anything: it is an instrument, not a gate
(count is never the deliverable). What it changes is the next red's cost — the reader who waits on this leg
to tag learns the step and the phase from `bash scripts/ci-status.sh`, and a probe that stalls leaves its
last assertion visible instead of a 10-minute silence.

- **Honest limits.** The step list is public only while the repo is, and job details are one extra request
per failed leg against a 60 req/h unauthenticated budget — printed as a reason, never as a guess, when that
runs out. The heartbeat names the last line written, which is the phase it *reached*, not proof of what it
was waiting on.

**10-29(30) An adoption argument rested on "every tree here has one" — three of eight do** (P2 docs / symbols `openapi-adoption-claim`)

- **What improved.** Root § Adoption justified writing an OpenAPI spec with a claim about the field: an
OpenAPI spec plus a generated client is "missing … which every harness tree here has". Read the trees
instead of recalling them: among the eight installable comparators only `codex`
(`codex-rs/codex-backend-openapi-models`), `ollama` (`docs/openapi.yaml`) and `opencode` carry anything
OpenAPI-shaped in-tree, and the three fastest movers (`hermes-agent`, `openclaw`, `deepseek-harness`)
carry none. The sentence now carries the count and the date, because a universal is exactly the shape that
rots quietly, and the reader's decision changes: a published spec is differentiation here, not table
stakes, which is the one thing that sentence was being used for.

- **What same-session output proves it.** `git -C ~/references/<tree> ls-files | grep -icE 'openapi|swagger'`
on this box, 10-29: codex 24, opencode 22, ollama 1, goose 2 (a recipe fixture), vllm 2 (a swagger-ui bundle,
not a spec), and 0 for sglang, omlx, mlx-serve, hermes-agent, openclaw, pi, deepseek-harness, harness2,
TensorFold, Strata. The root edit is byte-neutral (21 449/21 461 before and after), so B2's corpus row did not
have to move and `make docs-check` stayed green without a re-measure.

- **Which gate goes red if it regresses.** None, and that is stated rather than papered over: it is a prose
count with no gate behind it, which per invariant 1 makes it a claim, not a fact. What keeps it honest is the
one-line command above — a reader who disagrees can re-derive it in seconds, which is the whole point of
printing the command next to the number.

- **Honest limits.** A clone is a mirror, not HEAD, and `git ls-files` sees the tree, not the process: a
FastAPI-shaped server can serve `/openapi.json` at runtime with nothing in-tree, so this counts published
specs in a repo and says nothing about a running one. It also says nothing about SDKs — the "generated client"
half of the original sentence was never measured either and is now dropped rather than guessed at.

**10-29(29) A red leg that could name neither its cause nor its own numbers** (P1 CI-docs / symbols `ci-step.sh`, `comparator-cadence`)

- **What improved.** Three claims that were worth less than the gate behind them. (1) The 10-28 push went red
on `Build & Test (macos-26)` and the entire diagnosis was one annotation — "The action 'Headless serve smoke
(macos-26)' has timed out after 10 minutes" — because serve plus three probes spent ONE shared 600 s bound.
It is four steps now, each bounded, `scripts/probes/ci-step.sh` running one probe per step (40 s readiness,
20 s per request — these probes download nothing), and the probe/serve logs ride the failure artefact.
(2) Root § Adoption said the eight installable trees "each have ≥44 releases"; `deepseek-harness` has 34, so
the floor was false. The line reads 34 → 1 254 and names the instrument: `scripts/audit-facts.sh` prints the
per-tree range and calls a partial scan partial instead of a floor. (3) `long-horizon-goal.md` Rung 1 claimed
"≥100 releases with a newest of today" (false) and "The suite is green" (false, by (1)); both now state what
the runner measured, and the decoy `v0.1.10` is deleted so `v0.1.14` is the only number to misread.

- **What same-session output proves it.** The cadence instrument run end to end: codex 1 254 (10-28), opencode
885 (10-28), pi 275 (10-21), openclaw 274 (10-27), ollama 270 (10-27), goose 157 (10-23), hermes-agent 44
(10-23), deepseek-harness 34 (10-28). The split replayed here: 37 = 2 s (20 assertions), 38 = 10 s (13),
39 = 25 s (31), every step bound at 180 s = 7× the slowest. And the obvious cause is dead on measurement:
probe 37 against an empty `$OCOREAI_MODELS_DIR` answers 20/20 with a 39 ms round-trip, so "the runner had no
weights" is inference, not the finding — which is why the fix prints where time went instead of guessing.

- **Which gate goes red if it regresses.** `make docs-check` re-derives the injected corpus and the two figure
sites in `comparator-repos.md`: root grew 200 B this round, so its row had to move from
[21 249, 46 360, 31 878, 97, 890] to [21 449, 46 560, 32 078, 98, 690] and sat red until prose matched tree.
A stall now fails a step that carries the probe's number instead of letting a step timeout decide the leg;
`scripts/ci-status.sh` still answers 2, never green, for a leg that has not concluded.

- **Honest limits.** Splitting buys the name of the cause, not the cause. The leg is red as this lands, so a
tag waits on it and Rung 1 says that out loud. The diary footer "Last updated: 2026-08-23. Current HEAD:
72bbfbe" is deleted rather than refreshed — nothing re-derives a footer, which is how it lied for two months.

**10-29(28) A verdict script that exited 0 on a failing run was claiming more than it judged** (P1 CI / symbols `test-verdict-failing-run`)

- **What improved.** Entry (24)'s floor was sampled against synthetic logs and never against a run
that genuinely failed. Building one took four lines: a `@Test` asserting `42 == 43` in the same
minimal package, and `xcrun xctest` answered exit 1 with `✘ Test run with 3 tests in 2 suites failed
after 0.001 seconds with 1 issue.` — while `scripts/test-verdict.sh` printed that line as a
`::notice::` and exited 0. Its contract sentence ("did the harness deliver a verdict") was true and
its exit code was a lie a reader would act on, so the code now matches the sentence: exit 1 for no
summary, 0 tests, or a reported failure. The same pass put two multipliers back on their
measurements — the step bound was described as ~5x the work when the replayed step costs 43 s
(~14x), and the boot window as ~25x when `serve` answers `/health` in 2 s (20x) — and gave the
duplicated 2545-2850 s fact one home instead of two.

- **What same-session output proves it.** Five samples, one direction each: a passing run exits 0; a
real failing bundle exits 1; an XCTest-only log (10-28's misread shape) exits 1; a
`Test run with 0 tests` log exits 1; an empty log exits 1. The replay behind the 43 s: serve bound
in 2 s, probes 37/38/39 at 2/10/28 s, SIGTERM drain clean, whole step 43 s against a 600 s bound.

- **Which gate goes red if it regresses.** The script's own exit code, whose red was sampled twice
today — the failing-run log that used to pass it, and the empty log that starts the whole complaint.
Its seats are the CI test step and `make test-ci`. Reader whose action changes: anyone reading a
green test step as "the suite passed", which is now the same claim the exit code makes.

- **Honest limits.** It judges what swift-testing reported, not what XCTest did: XCTest failures
travel on `xctest`'s exit code (and `Tests/` holds 0 `XCTestCase` files, so there is no second
lane to cover). The 43 s replay is this host's SwiftPM Debug binary, not a runner's DerivedData
product — the next push's step duration is the number that matters.

**10-29(27) The published release named a branch where it had to name a commit** (P1 release / symbols `release-verify-tag`)

- **What improved.** The publish step created the release with `gh release create "v$VER" … --target
main`, so the artefact's provenance was recorded as a branch — the Release page for a frozen DMG
pointed at whatever `main` meant that day, and (gh's documented behaviour, not sampled here) a run
without the tag would create one at whatever main was tip, attaching a build to a commit that never
produced it. Upstream already answers this: codex creates its release with `--verify-tag`
(`.github/workflows/rusty-v8-release.yml:480`), which refuses a release whose tag does not exist.
So `--target main` is gone and `--verify-tag` is in: the tag is the target, and a missing tag is a
red step rather than an invented tag. Nothing local was invented for this, which is the point of
reading the trees before writing.

- **What same-session output proves it.** The flag pair read in upstream's own step and the diff in
ours: the release command no longer accepts a moving reference. What it does *not* prove is the
publish itself — the job runs on a tag, and 0 tags exist, so the first v0.1.14 is its first sample.

- **Which gate goes red if it regresses.** The release job is the gate and it is the only seat; it
already refuses a release whose asset is absent (state-probed twice, then `::error::`) and read-back
verifies the published asset's sha256 against the local build. Reader whose action changes: anyone
mapping a downloaded DMG to the source that made it — the release now names a commit, and the
read-back line already names the bytes.

- **Honest limits.** `--verify-tag`'s refusal path is gh's documented semantics, not a red observed
on this tree, and no claim is made here about the DMG building: that verdict belongs to a tag run.

**10-29(26) The diary stopped claiming a convention it does not keep, and its own ordering was repaired** (P2 docs / symbols `changelog-diary-shape`)

- **What improved.** Three things a stranger reads first were false. The header said "This project
adheres to [Keep a Changelog] conventions" — the file has 0 `Added`/`Changed`/`Fixed` sections and is
a dated round diary, so the badge described a shape it never had; the URL it pointed at is removed
from the docs contract's `VERIFIED_URLS` too, because P19 counts an entry no doc cites as a record of
nothing (it went red for exactly that when the badge went). Two sections titled `## Unreleased` sat
*below* `## [v0.1.0] — 2026-07-05 → 2026-08-09` and describe work that shipped: `git log -S` puts the
embeddings surface in `e5e29ea` and its capability close in `fb02649`, both 10-06, so they are now
headed with those measured dates. And `**10-22(12)**` was the last entry in the file, below sections
from July and August, breaking the newest-first rule the file states — moved above `10-22(11)`.

- **What same-session output proves it.** Re-derived from the file after the edit: 135 dated entries
before and after (nothing lost), the 10-22 cluster reads 12,11,10,…,2 in file order, zero entries
younger than their predecessor anywhere in the file, zero `## Unreleased` headings left, and no
`keepachangelog.com` citation. `make docs-check` is green with `links outbound=28 verified=28`.

- **Which gate goes red if it regresses.** P19 of `make docs-check`, which went red on this edit and
stayed red until the dead ledger entry was deleted — that is the sampled pair. It catches the ledger
half; the ordering half has no gate, so the header now states the order in words instead of
borrowing someone else's badge, and the dates on those two headings are commits, not guesses.

- **Honest limits.** The 10-22(12) move relocates text without touching its content, so any claim
inside it is still as of that round, and the file's oldest sections keep whatever shape they had:
this repair covers what the top of the file promises and what a scan can check.

**10-29(25) A readiness budget now costs the seconds it advertises** (P1 probes-CI / symbols `probe_boot-wall-clock`, `OCOREAI_PROBE_CURL_TIMEOUT`)

- **What improved.** `probe_boot` counted loop iterations against a timeout expressed in seconds,
while one iteration costs the poll's own 3 s `curl -m 3` deadline plus the 1 s sleep. On a server
that accepts a connection and never answers, every iteration pays that, so a budget of N seconds
spent up to 4N. That is what the authority leg's smoke step was sitting on: 75 s per boot meant
~285 s, three probes overran the 10-minute step bound, and the leg's verdict became a timeout
rather than an answer about the wire. The budget is wall-clock now, the failure prints both numbers
(`in 13s wall (budget 10s)`), and the same lie in the step's own serve wait — a loop claiming 60 s
that could spend 150 — went with it. The step sets `OCOREAI_READY_TIMEOUT=40` and
`OCOREAI_PROBE_CURL_TIMEOUT=60`, since the 180 s default exists for a local model's first token and
these three probes download nothing, and each probe publishes its own elapsed time.

- **What same-session output proves it.** A fake server that binds and never answers, budget 10 s:
38 s wall before the fix, 13 s after — the remainder is one poll, whose ceiling the message now
states. The three-probe loop at that budget, replayed under `set -euo pipefail`: 40 s wall total,
`probe 37 exit 1 after 13s`, `38 after 14s`, `39 after 13s`, and the loop still reached its own
verdict instead of dying with the first failure.

- **Which gate goes red if it regresses.** The step bound that this fix exists to fit inside: the
red was sampled on HEAD, where the runner printed `The action 'Headless serve smoke (macos-26)' has
timed out after 10 minutes` at 607 s. Reader whose action changes: whoever waits on this leg to tag,
who now gets a named probe and an elapsed number instead of a cancelled leg.

- **Honest limits.** Nothing floors the ratio itself — a future edit back to iteration counting
would show up as a step timeout, in minutes, not as a red assertion. A hung server is still bounded
by budget × boot attempts (port collision retries three), and 40 s is a judgement about a host with
no weights resident, not a measured floor.

**10-29(24) A test step that exits 0 without delivering a verdict can no longer read green** (P0 CI / symbols `test-verdict.sh`, `xctest-verdict-floor`)

- **What improved.** Both `Build & Test` legs carried the annotation `xctest summary (exit 0):
Executed 0 tests, with 0 failures`, which any reader must take as "the suite is not running" — and
the step comment above it claimed a frozen 757 tests, so the two readings could not be reconciled
from the repo. Neither was the truth, and the real defect was one layer down. `Tests/` holds 0
`XCTestCase` files, so XCTest's "Executed 0 tests" is what this bundle prints on every green run
whatever the suite did; swift-testing's `Test run with N tests` line — the verdict — never reached
that annotation because a `::notice::` value ends at its first newline and the value it was handed
carried two lines. Measured on a minimal two-test package built the same way: `xcrun xctest` does
execute swift-testing tests, and prints them after XCTest's summary, so the harness was right and
only its reporting was unreadable. What was missing is a floor: an empty bundle exits 0 too, and
nothing anywhere could go red. `scripts/test-verdict.sh` asks the two frameworks separately, one
annotation each so neither can be swallowed, and exits 1 when swift-testing reports no summary or 0
tests; the frozen count left the step comment because a number nobody re-derives is decoration.

- **What same-session output proves it.** Four samples, both directions: a real two-test run exits 0
with both lines named; a log cut down to the XCTest line (today's shape) exits 1; a
`Test run with 0 tests` line exits 1; an empty log exits 1. The command's behaviour itself: the
minimal package printed `✔ Test run with 2 tests in 1 suite passed after 0.001 seconds` under the
same `xcrun xctest` the legs run, through a pipe with stdin closed, which is the CI shape.

- **Which gate goes red if it regresses.** The new script is the gate, and its red was sampled
against the exact log shape that hid this: `xcrun xctest` exits 0, the bundle reports nothing, the
step now prints `xctest exited 0 without delivering a verdict` and fails. Its seats are the CI test
step and `make test-ci`, so neither seat can go green on an empty run again. Reader whose action
changes: whoever decides whether a leg is green enough to tag — the sentence they read now carries a
number, and no number is a failure instead of a silence.

- **Honest limits.** It floors "a verdict was delivered, with at least one test", not "the whole
suite ran": suites excluded by destination or `#if` lower N without going red, on purpose, because
the floor that would catch that needs a count derived from the build and not from a comment. The
first N this repo reads from a runner is the next push, not this entry.

**10-28(23) The delivery route asked the Metal question under the wrong toolchain** (P0 CI / symbols `delivery-metal-route`)

- **What improved.** Entry (20) landed and the runner still read `metal=ABSENT`, so the question was
asked in the wrong place: `print-delivery-env` resolves its SDK under `DEVELOPER_DIR=$CLT_ROOT` and
its Metal under whatever the host happens to use. Asked under the host's Xcode the answer is "already
fine" — the component had just been installed there, so `metal` spawns on *that* route — the printer
then correctly reports no value, no PATH rung is exported, and the CLT build the leg runs next dies at
CompileMetalFile. The Metal question is now asked under the route that ships, which is the line above
it. `METAL=ok` there means a `metal` answers `--version` on the shipping route, so no rung is needed;
anything else prints the cryptex dir.

- **What same-session output proves it.** The runner's own pair, twice: the route's notice
`metal=ABSENT` under `DEVELOPER_DIR=/Library/Developer/CommandLineTools` beside the preflight's
`resolver print-metal-bin: …MetalToolchain-v17.6.109.0.EDCZCv/Metal.xctoolchain/usr/bin`, with the
build reaching exit 65 on `CompileMetalFile`. Locally the emission changed the way the contract says it
should: this host's CLT route answers `metal=ok`, so it now gets no PATH line (its `metal` resolves by
name even from a trimmed PATH), where before it got one it did not need.

- **Which gate goes red if it regresses.** None new. The gate is the leg itself: it builds the
delivery shape on the route that ships, and entry (19)'s preflight prints the route's answer next to the
resolver's, which is precisely the pair that made this visible. Reader whose action changes: whoever has
been reading that leg's `exit 65` as "the runner has no Metal compiler" — it has one, the route was not
asking for it.

- **Honest limits.** The verdict on this line is the next runner run, not this entry; entry (20)'s
ask-first resolver is still what makes the mount appear at all, and both are needed. And nothing here
proves the CLT route on a hosted image can *compile* a kernel — it proves the compiler becomes
reachable, which is the claim being made.

**10-28(22) The delivery leg asks the resolver what it found, not a toolchain that cannot answer** (P2 CI / symbols `appstore-resolver-report`)

- **What improved.** Two small lies on one leg. Its failure path ran `xcodebuild -showComponent`
under the CLT `DEVELOPER_DIR` that the route pins itself, so its "component" annotation could only
ever be the same error string; it now reports the contract's own facts (`metal=`,
`metal_component_status=`, `metal_cryptex_bin=`) from the single resolver that owns the question. And
the step comment asserted the PATH export was "verified 10-28 on a host where `metal` is not
reachable by name" — true only on an Xcode route — and that hosted images do not ship the component,
which was inference. The comment now names the two causes that were measured and points at entry (20).

- **What same-session output proves it.** Today's two red legs each published, verbatim, `component:
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory
'/Library/Developer/CommandLineTools' …` — a fact about the route, never about the asset — beside the
one line that actually mattered, `metal=ABSENT`. The step script was extracted from the workflow and
re-parsed before and after, and the six jobs and their bounds are unchanged.

- **Which gate goes red if it regresses.** No new gate: the annotations are the artefact, and the
reader is the same one entry (19) serves — whoever has this leg red on a runner and no token to read
the log with. A second hand-copied probe of the component is exactly the second home this repo
refuses, so it is gone rather than corrected.

- **Honest limits.** Nothing here moves the leg's verdict: that waits on the ask-first resolver
landing in a runner build. If the next run still prints `metal=ABSENT`, these annotations are what
will say whether the asset mounted at all.

**10-28(21) The live probes' readiness window was the authority leg's 47-minute hole** (P1 CI / symbols `probe-readiness-window`)

- **What improved.** The smoke step ran three live probes under the harness default: 240 s of
readiness per boot attempt, three boot attempts per probe. A runner that cannot bring a server up
therefore paid up to ~36 minutes of silence per push before anything said so. The step now asks for
75 s per boot, runs the three tiers one at a time so the log says which one stopped, and on a failure
publishes the probe's own log tail as `::error::` annotations plus a step-summary block.

- **What same-session output proves it.** The step's own timings: five runs today measured it at
2545-2850 s, with the legs ahead of it finishing in 657-940 s (build) and 100-132 s (xctest), against
under 20 s for the same step on the last green run of that leg. Every one of those runs ended
`cancelled` at the job's 60-minute limit, which is the verdict a step with no bound and no output
buys. 3 probes x 3 attempts x 240 s is the same order of magnitude as the measurement.

- **Which gate goes red if it regresses.** No new gate — the window is the bound and its red is
today's cancelled legs. What was missing was legibility, and that is now the same trick entry (19)
uses on the other leg: the probe's words reach `/check-runs/{id}/annotations`, which needs no token.
Reader whose action changes: whoever waits on this leg to tag — a minute to "probe 38 could not boot
a server" beats an hour to a wordless cancellation.

- **Honest limits.** This makes the hole loud and short, not green. If a runner really cannot boot a
probe's server, the next push says so inside a minute and the step fails for a stated reason instead
of being cancelled for none — and whether the probes boot on a runner is still unmeasured, since
locally they pass in 2 s, 11 s and 25 s.

**10-28(20) The delivery route never asked cryptexd to mount the Metal toolchain, so it shipped no compiler** (P0 CI / symbols `cryptex-ask-first-ladder`, `metal-toolchain-mount`)

- **What improved.** `cryptex_metal_bin` had two dead rungs and no way to make the mount appear. The
component ask read `xcodebuild -showComponent`'s search path and tested `<root>/usr/bin/metal`, while
the compiler sits at `<root>/Metal.xctoolchain/usr/bin/metal` — measured here, the ask named the root
and the test failed against a binary one directory deeper, so that rung could never validate. What was
left is a passive glob of a mobile asset cryptexd attaches on demand, so a route that had just
downloaded the component still resolved nothing: the env it emitted carried no PATH rung and the build
died at `CompileMetalFile` with `unable to spawn process 'metal'`. The resolver now asks through any
Xcode the box can name (a path to a compiler, not a toolchain swap — the delivery route stays CLT),
globs what the ask mounted, and re-globs twice before it gives up.

- **What same-session output proves it.** The leg's own preflight, one second apart on a runner:
`metal=ABSENT` in the route notice, then a resolvable directory from the same resolver, then
`unable to spawn process 'metal'` and exit 65. Locally the ask now answers
`<root>/Metal.xctoolchain/usr/bin` where it answered nothing, `print-delivery-env` emits its PATH
export under both host contexts (counted 1 each), and a route whose `metal` already spawns by name
still prints no value and exits 1 — the deliberate half of the contract, and the thing this entry
first got wrong.

- **Which gate goes red if it regresses.** None new, and that is the honest answer: the red is the
preflight entry (19) added, which fired today and names the missing rung on every future push instead
of leaving `exit 65` to be read as a compiler mystery. Reader whose action changes: whoever reads this
leg and could not previously tell "no component" from "component not mounted" from "route forgot the
PATH rung".

- **Honest limits.** The runner verdict for this fix lies ahead of the entry: that leg is the only
place a CLT-route `.metal` rebuild is judged. And this entry replaces a wrong one — its first version
called `print-metal-bin`'s `[ "$METAL" != "ok" ]` guard an inversion, printed unconditionally, and
added an `R4b` printer gate whose red had never been sampled. `METAL=ok` means a `metal` already
spawns by name, so the guard skips a PATH rung the route does not need; both edits were reverted in
this session before any CI verdict on them, and the guard now carries its reason in a comment.

**10-28(19) The delivery leg names the Metal rung it lacks instead of dying inside llbuild** (P1 CI / symbols `appstore-metal-preflight`)

- **What improved.** The leg installs the Metal Toolchain component, that step goes green, and the build
still dies at `CompileMetalFile` with `unable to spawn process 'metal'`. The route is the CLT route on
purpose — an SDK-27 route compiles the CoreAI blocks into the shipped binary — so the only compiler
SwiftPM can spawn is the cryptex mount the resolver knows. The leg now asks four things in its first
second, in public annotations: is `metal` on PATH, what does `xcodebuild -showComponent` report, is a
cryptexd mount listed, what did `print-metal-bin` answer. Then it stops, instead of spending another
147 s of an arm64 seat to reach the same sentence.

- **What same-session output proves it.** Today's red, read through the public endpoints: on `3110883`
the step list says Install=success and Build=failure, and the annotations say `unable to spawn process
'metal'` with two CompileMetalFile lines and exit 65. Both branches of the new block were dry-run from
the workflow's own extracted step against the real tools: with the resolver answer forced empty it
printed the four lines, wrote the summary block and exited 1 without reaching the build; with `metal`
reachable it printed one notice and fell through.

- **Which gate goes red if it regresses.** No new gate — this leg was already red, and its red now
carries the cause. Reader whose action changes: whoever reads this leg and used to see `exit 65` alone,
and now learns without a token whether the component never installed or installed where nothing looks.

- **Honest limits.** The leg stays red until a runner says which of the three it is: hosted images may
serve the component into a mount the resolver's ladder does not name, and the fix belongs in
`cryptex_metal_bin` once a push says where. Nothing here proves a runner can download the component —
its green install step is the only evidence, and today it bought no compiler.

**10-28(18) A push to main supersedes the push before it, because five runs in flight bought nothing** (P1 CI / symbols `concurrency-supersede-main`)

- **What improved.** The `concurrency.group` expression here carried codex's `main`-only run-id suffix, so
nothing on main was ever cancelled and every push queued a full second set of arm64 legs. It is now one
group per ref, which is what coreai-models (`ci.yml:9`) and opencode's check workflow (`check.yml:12`)
both do; opencode reserves the run-id group for a release branch whose every commit owes a quarantine
artefact, and this repo has no per-commit artefact to buy. The cheaper-looking alternative — skip arm64
for markdown-only pushes — is refused here on a measured ground: those legs consume markdown, since
probe 37 asserts a figure inside `AGENTS.md` and probe 39 executes markers out of the published skill.

- **What same-session output proves it.** The API's own numbers for 10-28: eleven pushes to main, five
runs queued or running at once at 11:22Z, four arm64 legs per run, and HEAD's run still in progress at
76 minutes — behind verdicts for commits HEAD already contains. `yaml.safe_load` still returns the same
six jobs and the new group string, so the edit is a scoping change and not a syntax event.

- **Which gate goes red if it regresses.** No new gate, and none was needed: `scripts/ci-status.sh`
already maps `cancelled` to exit 1 with the words `AUTHORITY NOT GREEN`, which is the exact risk the
old comment was protecting against. Reader whose action changes: whoever waits for a tag gate — the
newest push now gets the seat instead of the queue.

- **Honest limits.** A superseded commit no longer earns its own arm64 verdict; its row stays in the run
list with its SHA and the conclusion `cancelled`. This is a deliberate divergence from the expression
pasted from codex `bazel.yml`, recorded because the comment removed here claimed codex's semantics.

**10-28(17) The step that runs live probes bounds itself, so a stall names itself in minutes** (P1 CI / symbols `smoke-step-deadline`)

- **What improved.** `Headless serve smoke (macos-26)` carried no bound of its own, so anything inside
it that waits forever waits until the job's 60-minute limit and the leg reports `cancelled`. Entry (16)
removes the one request that could hang; this caps the step, because "a later probe forgot a deadline"
and "the checkpoint load was slow" must not both resolve as an hour of silence. The bound is 10 minutes,
about 5x what the step measurably does, and a step that overruns names itself in the job's step list.

- **What same-session output proves it.** The same six pushes as entry (16): this step 2545-2850 s
against under 20 s on the last green run, with build and xctest ahead of it finishing in 657-931 s and
100-132 s. Locally the three probes the step runs answer in 2 s, 11 s and 25 s. The edited workflow
still parses to the same six jobs, so the change is a bound and not a syntax event.

- **Which gate goes red if it regresses.** No new gate: the bound is the gate, and it was sampled
against today's six `cancelled` legs rather than written first. Reader whose action changes: whoever is
waiting on this leg to tag — 10 minutes to "the harness stalled in step 7" beats 60 minutes to nothing.

- **Honest limits.** A step timeout still reads `cancelled`, not `failed`; what it buys is the step name
and the shorter wait, not a different verdict word. The bound is a wall clock, so a runner slow enough
to need 10 minutes legitimately would now fail where it used to hang — nothing measured is near that.

**10-28(16) One request in the live harness carried no deadline, and it ate the authority leg's verdict six times** (P1 CI / symbols `probe-37-sse-deadline`, `Class-L`)

- **What improved.** Every request the live probes make goes through `probe_api`, whose argv sets `-m`,
except the streaming request in `scripts/probes/37-scripted-engine-wire.sh:87`: a stream the server never
closes had no bound at all, and that request sits in the one CI step that runs live probes on every push. It
now carries the knob the helper already uses (`OCOREAI_PROBE_CURL_TIMEOUT`, default 180 s), so a stalled
stream ends as a partial body and a named failure instead of as silence.

- **What same-session output proves it.** Each of the six pushes that start the streak concludes
`Build & Test (macos-26)` = `cancelled` at the job's own 60-minute limit, and the step timings point one
place: build 657-931 s, xctest 100-132 s, headless-serve smoke 2545-2850 s — against under 20 s for that
step on the last green run of the same leg. About 4.4 arm64-hours parked with no verdict on the leg
`AGENTS.md` names the authority. Locally the same probe answers in 2 s with the deadline in place.

- **Which gate goes red if it regresses.** New Class-L in `scripts/audit.swift_patterns.sh:627`: every
`curl` call site under `scripts/probes` carries `-m`/`--max-time` or is the argv-built helper, whose argv
the class re-measures so the exemption cannot outlive the flag; it floors itself at 30 sites and counts 38
today. Sampled red by deleting the flag from the fixed line, which printed `1 request(s) with no deadline`
naming `37-scripted-engine-wire.sh:87`, and Clean on restore. Reader whose action changes: whoever waits on
this leg to tag a release and needs minutes, not hours, to learn the harness stalled.

- **Honest limits.** A runner log needs a token, so "the stream stalled" remains inference — it is the only
unbounded request in that step's path, and probes 37 and 38 are what CI reaches. Entry (17) removes the
guesswork: the step now bounds itself, so a stall names itself instead of arriving as a 60-minute
cancellation.

**10-28(15) The skill's trackedness clause resolves cites against the harness root, not the caller's cwd** (P1 probes / symbols `probe-39-cite-resolution`, `PROBE_REPO_ROOT`)

- **What improved.** §0 of the skill-contract probe asks git whether each path the published skill points a
harness at is actually shipped, and it resolved repo-relative cites against the *process* cwd.
`scripts/probes/run.sh` cds into `scripts/probes`, so from the one seat that runs on every push none of those
cites resolved, §0 scanned an empty set, and its own floor went red: a path bug read as a missing-file alarm.
`scripts/probes/39-skill-contract-exec.sh:167` now resolves against the root the harness found and against
the skill directory, which is what the two cite forms mean.

- **What same-session output proves it.** One command, two invocations, before the change: through
`run.sh 39` it printed `only 0 cite(s) scanned in the skill (floor 3)` in 3 of 3 runs, while the same probe
invoked from the repo root passed — which is exactly how it survived landing. After: through the same
`run.sh 39` it prints `7 cited file(s) all tracked by git`, 31 passed, 0 failed.

- **Which gate goes red if it regresses.** §0's own floor (3) is the gate, and it is the reason the bug is
visible at all: it refused to let a trackedness verdict pass over an empty set. Reader whose action changes:
whoever runs `make probes` or reads the CI smoke step, who would otherwise chase a cite that was never
missing from the clone.

- **Honest limits.** The clause still sees only backticked paths, and probe 39 has never reached a runner —
the smoke step that calls it hangs upstream of it, entry (16). The 0-to-7 pair is measured on this host.

**10-28(14) `/releases/latest` says we ship while the Releases page says we never have** (P1 adoption / symbols `phantom-release-row`, `listed-releases-wording`)

- **What improved.** The adoption figure was re-grepped before being repeated, and it was wrong in a way no
human sees: `api.github.com` `/releases/latest` still serves `v0.1.13` — published 10-11, asset
`ocoreai-0.1.13.dmg` at 25 472 769 bytes — while `git tag -l`, `/tags`, `/releases` and the Releases page all
report nothing and that asset URL answers 404. The endpoint an agent or a comparison script asks first
therefore describes a shipping product, and the page a person asks describes none. § Adoption now says 0
*listed* releases, and `docs/agent/open-items.md` carries the measurement with the owner's two ways out:
delete the orphan object, or land `v0.1.14` so a newest sits within days. This is the sentence § Adoption
exists to keep honest — a first screen for a repo that ships nothing should not be arguable.

- **What same-session output proves it.** Four probes, one line each: API `latest` returns `tag_name`
`v0.1.13`, `draft` false, asset size 25 472 769; a HEAD on the download URL ends 404; the Releases page HTML
contains no `0.1.1x` at all; `/releases` unauthenticated returns an empty list. `scripts/version.sh` still
answers 0.0.0, so no local build can reproduce the phantom. Root then grew 4 bytes and the figure gate
demanded the comparator row follow it — 21 438 to 21 442, chain 32 067 to 32 071, headroom 701 to 697 — and
refused the commit until they did.

- **Which gate goes red if it regresses.** The B2 re-derivation of entry (10), on its first live use and
against this round's own edits: leaving the row stale produced `…quotes ocoreai root/corpus/chain/pct/headroom as [21438, 46549, 32067, 98, 701]` against `the tree is [21442, 46553, 32071, 98, 697]`, and the open-items insertion that reached 15 648 bytes produced `15648 bytes > per-guide cap 15609`. Reader
whose action changes: the owner, who now knows the release object stands as a public claim rather than as an
absence.

- **Honest limits.** Nothing was deleted: removing a published release object is a public, hard-to-undo act
and belongs to the owner, so this entry only makes the state visible and stops the docs asserting a number a
popular endpoint contradicts. The rot is GitHub-side — nothing in this tree names `v0.1.13`, `git describe`
returns nothing, and `scripts/version.sh` answers 0.0.0 for an untagged tree.


**10-28(13) The delivery leg could not spawn a Metal compiler, and the annotation said so in four lines** (P1 adoption / symbols `appstore-metal-component`, `metal-path-one-home`)

- **What improved.** `build-appstore` has been red on main since the delivery route was pinned, and until last
round nobody could say why. The annotations now say it:
`error: unable to spawn process 'metal' (No such file or directory)` while llbuild ran CompileMetalFile on
`steel_attention.metal` inside the pinned mlx checkout. The cause is structural, not a flake: the delivery
route is the CLT route *on purpose* (an SDK-27 route would compile the CoreAI blocks into the shipping
binary), and the CLT carries no Metal compiler — hosted macOS images ship that component separately. The leg
installs it, exactly as the xcode-27 cell already does, The leg also says out loud, in its own log, whether
that PATH rung landed on a real compiler, so a repeat of this red names itself instead of surfacing as a
compiler error. One word of the leg's own comment was wrong and is fixed beside it: no metallib is needed at
build time, but a *compiler* is.

- **What same-session output proves it.** The red arrived as four annotations with no token — `Build failed`,
the CompileMetalFile line with its command line, and the spawn error — which is the second time this round
that a step summary bought a diagnosis instead of a rumour. The workflow still parses to six jobs, and the
resolver was already proven on this host: `print-metal-bin` answers with the cryptex dir whose `metal`
compiles a kernel. The release note a tag would publish was read against the code as well: "nothing is fetched
before you choose" holds, because `UpdateCheck.check()` is reached only from a user-pressed
`Check for Updates…` (`Sources/ocoreai/UI/Views/SettingsView.swift:506`) and nothing calls it at launch. One
stale claim surfaced beside it and is gone: `UpdateCheck.swift:5` asserted "v0.1.6 is on GitHub Releases" for
a line that was withdrawn and a repo holding 0 releases.

- **Which gate goes red if it regresses.** The leg itself: it goes red with the same three annotations if the
component goes missing again, and its route line prints `metal=ABSENT` when nothing resolves, so the old shape
names itself instead of arriving as a compiler error. Reader whose action changes: the owner, who reads this
leg as the verdict on whether the shipping shape builds.

- **Honest limits.** Unproven until the runner runs it: `xcodebuild -downloadComponent MetalToolchain` is
executed by the xcode-27 cell today and is documented for Xcode 16+, but this leg asks an Xcode-26 image for
it — if that image cannot serve the component, the leg stays red and the route needs a different seat, which
is an owner call. The release leg is untouched: it materializes the metallib through xcodebuild, whose own
toolchain resolution found `metal` on the 09-27 run, so it never had this failure to fix. The fix as first
written was wrong in the way this file exists to record: it prepended `print-metal-bin` by hand, and measuring
on a host where `metal` is not reachable by name showed `print-delivery-env` already exports that cryptex dir
— so the duplicate rung came back out, and the route keeps sole ownership of it.


**10-28(12) The runner red was a real bug: a toolchain printer wrote its complaint onto the value channel** (P1 correctness / symbols `printer-value-channel`, `R4-printer-contract`)

- **What improved.** Entry (11)'s annotation named `test-clt`, and the cause was two characters wide.
`scripts/toolchain-contract.sh:75` wrote its failure line to **stdout**, `Makefile:94` captures that stdout
with `$(shell … 2>/dev/null)` into `CLT_SDK`, and `Makefile:95` then composed
`SDKROOT=❌ no usable DEVELOPER_DIR (set it or run xcode-select -s)` — a shell syntax error on every host
without an Apple toolchain, which is why only the ubuntu leg saw it. The complaint goes to stderr now, the way
the sibling guard at `:287` already does, so a printer with no value says nothing at all. R4 joins the same
contract leg rather than opening a new one: it forces `DEVELOPER_DIR=/nonexistent` and demands `rc != 0` with
empty stdout from both printers, so the contract is judged on any host, not only on a runner that happens to
lack the toolchain.

- **What same-session output proves it.** Reproduced before touching anything: `make -n test-clt` with
`CLT_SDK` set to that leaked line, piped to `bash -n`, fails on the composed `SDKROOT=` line with
`syntax error near unexpected token '('` — the same failure the runner reported. After the fix the same
simulation with the toolchain vars empty parses, the full leg stays green at 31 recipes, and in a
toolchain-less environment both printers exit 1 with empty stdout.

- **Which gate goes red if it regresses.** R4, sampled by deleting `>&2` again in a copy of the script: two
`❌ R4 printer contract` lines that quote the leaked stdout verbatim and exit 1. Consumer coverage comes from
the exit code, which is how `make toolchain-check` (`Makefile:123`), `test-clt` (`:152`) and `audit-facts.sh`
all decide, so one gate reaches every route that consumes a printer. Reader whose action changes: whoever adds
an `echo` to a print mode, who now meets a red on their own machine instead of a step name on a runner.

- **Honest limits.** The runner leg is expected to clear and is not yet proven — the next verdict is the first
to run it with the fixed printer, and `build-appstore` stays red on main for a cause this leg never touched.
R4 forces one face only (no `DEVELOPER_DIR`) ; a complaint leaking on another failure face, such as the `:287`
no-CoreAI-free-SDK path, is caught when a host actually reaches it, and the two-mode loop does not audit every
diagnostic in the script.


**10-28(11) The next runner red is readable without a token, and the parse leg now names the toolchain it judged** (P1 process / symbols `text-gates-self-report`, `host-labelled-parse`)

- **What improved.** `text-gates` cleared the docs contract on a runner for the first time and fell one step
later, at `Every Makefile recipe parses`, with nothing in the annotations but `failed step: makefile parse` —
the same wall that made `build-appstore` unreadable last round. The leg states its premise and its detail now:
the report line carries `make=` and `bash=` versions, a `::error::` names every failing target on one line,
and `$GITHUB_STEP_SUMMARY` receives the `bash -n` text itself. Nothing claims the red is fixed — the cause is
unknown, and § Working here says quote the failure before writing its guard.

- **What same-session output proves it.** The local green line reads
`31 target recipe(s) parse (make=3.81 bash=3.2.57(1)-release, floor 20)`. Against a copy of the Makefile given
a canary target whose recipe never closes its quote, the run exits 1 with
`::error::makefile parse: 1 target(s) fail bash -n …: canary` and a step summary carrying
`bash: line 1: unexpected EOF while looking for matching "'`. Three premises were eliminated before
anything was written: the macOS host green, a fresh shallow clone on that host green, and a host with
xcode-select, xcrun, xcodebuild, swift, swift-format, metal, mtl, sw_vers, gh, brew, python3 and codespell
stubbed to exit 127 also green. What is left is the runner's own toolchain — the next verdict prints its make
and bash versions instead of leaving that to inference.

- **Which gate goes red if it regresses.** The parse leg itself, sampled with the canary target: exit 1, the
target named in the annotation and its bash error in the step summary. With `GITHUB_STEP_SUMMARY` unset the
annotation still names the targets, so a red cannot fall back to being only a step name. Reader whose action
changes: whoever has to fix a red on a leg they cannot reproduce locally, and the owner deciding whether this
leg earns its ubuntu minutes.

- **Honest limits.** The red is still red — this entry buys a diagnosis, not a green. If the next verdict
names a target whose recipe parses only under the macOS make, the leg's premise has to shrink (judge what our
recipes say rather than what one make version prints) or the leg moves back to the macOS seat it was moved off
last round; either way that is an owner call about what a text gate may depend on. The runner's versions are
not stated here because they have not been measured yet.


**10-28(10) The byte figures a doc quotes now reproduce or go red — the comparator row stopped being a snapshot someone had to notice** (P1 honesty / symbols `docs-figure-rederivation`, `chain-figures-gate`)

- **What improved.** The context-economy header of `docs/agent/comparator-repos.md` is the one place our
context numbers are written down for a human, and it had drifted twice in a day: the `ocoreai` row still read
`46 519 / 32 037 / 731 B` after the Engine guide grew 30 B, while its own prose tail said `723 B` — one file
contradicting itself, in the tree a stranger reads to rank us. § Upstream's first invariant names the failure
("a doc whose numbers nobody re-greps drifts"); the header itself said a stale cell is yours to notice. B2's
budget leg now re-derives that row inside `scripts/agents-md-contract.sh`: root bytes, the `AGENTS.md` corpus
(root plus every chainable guide), the deepest chain, its share of the loader's 32 768 B, and the headroom
left, each compared against the anchored figures. The two copies elsewhere left the tree — `open-items.md` and
`long-horizon-goal.md` each restated the same pair, which is a second and third home for one measurement — and
now point at `budgets … deepest-chain=N/CAP`.

- **What same-session output proves it.** The row reads `21 438 / 46 549 / 32 067 (98 %, 701 B of headroom)`
against `git ls-files '*AGENTS.md' | xargs wc -c` = 46 549 and root + `Sources/ocoreai/Engine/AGENTS.md` = 32
067, and `make docs-check` prints `docs-figures=2 site(s) re-derived`. The drift this gate exists to catch
fired inside its own round: the two Engine-guide `mlx-swift-lm` edits of this round grew the guide 30 B and
moved `deepest-chain` from 32 037 to 32 067, so every quoted figure had to be re-measured before the gate went
green. Byte caps held on the way — open-items 14 786 → 14 975 B, long-horizon-goal 15 599 → 15 594 B — and the
second is legal only because it *shrank*: that file sat 10 B under the 15 609 area cap, so its edit had to be
written shorter than the sentence it replaced.

- **Which gate goes red if it regresses.** Sampled three times, three different reds. Setting the row's chain
back to 32 037 gives `…quotes ocoreai root/corpus/chain/pct/headroom as [21438, 46549, 32037, 98, 701]`
against `the tree is [21438, 46549, 32067, 98, 701]`. Setting the tail to 723 gives
`says ours is 723 B from the cap while the budgets line leaves 701 B`, which is today's actual defect.
Rewording the tail until no anchor matches gives `re-derived 1 figure site(s) … (floor 2)`, so the scan floors
its own hit count instead of passing on a header it no longer reads. Reader whose action changes: whoever
writes the next root rule (that headroom is all it gets) and the stranger comparing us with 19 other trees.

- **Honest limits.** Two anchors in one file: the other rows are comparator trees no runner has, and they stay
dated snapshots the header's own one-liner re-derives by hand. Percentages round to whole points, so a
few-bytes move still reads 98 %, and the gate judges the byte figures, not the prose around them. `corpus`
here is the `AGENTS.md` set the loader can chain — narrower than the `corpus bytes=` line the same report
prints for every doc — one word with two measures, kept because that header must compare like with like across
trees.


**10-28(9) The text gates stop paying for an arm64 seat, and the docs gate stops trusting what the host happens to hold** (P1 process / symbols `text-gates-ubuntu`, `cite-attribution-by-tree`)

- **What improved.** The `Static Audit` leg is gone. Six gates that read text — docs contract, code patterns,
line-cite anchors, lockfile sync, type existence, Makefile parse — sat on `macos-26` under a 25-minute ceiling
at **715 s a push**, most of it building the pinned swift-format and running `swift package resolve`; §
Working here prices a lock by the seat it costs and says text gates go to ubuntu, so they now run as
`text-gates` there. Two gates genuinely need macOS — the pinned formatter and
`toolchain-contract.sh check --probe-metal` — and they were not moved to a seat that cannot host them (no
ubuntu image ships a Swift toolchain): they bite in `make push-ready`, where the docs contract also runs with
`OCOREAI_AGENTS_NO_HOST_REFS=1`. That knob is the round's other half and the root cause of the red: P2
resolved cites against `~/references/*`, so on a tree-rich host 47 comparator cites read fine while a fresh
clone got 47 dead pointers. The gate no longer infers its premise from the box — the tree set is derived from
the `- \` <tree>\` —` bullets of `docs/agent/comparator-repos.md` (floor 16), and a cite into one is judged by
whether the block that cites it **names its tree ahead of the cite**, the same evidence a reader uses.

- **What same-session output proves it.** Under the runner's premise: **77 comparator cites attributed** (12
by path form, 65 by paragraph), and the hand-written `COMPARATOR_REFS` allowlist fell from 21 entries to 2
(`PROVENANCE.md`, `serving_chat.py`) because the gate itself named the 19 it no longer needed. Three real doc
defects surfaced, not instrumentation: a `VISION.md` cite in two docs whose block never said whose file it is,
and `models.json` cited in the runbook and in open-items as if it existed when it is the artefact we *owe*
(now marked absent). Workflow YAML parses with six jobs; `makefile-parse-check` 31 recipes; the relocated
scripts use no BSD-only tool in their check paths (the one `sed -i ''` left in the tree is the `docs-budget`
re-pin path CI never calls); `make audit`, `anchor-check`, `docs-check` and `spell` are green with the premise
pinned, and green without it.

- **Which gate goes red if it regresses.** Sampled three times while writing it. Deleting a still-needed
allowlist entry → `P2 1 unresolved reference(s) … names no comparator tree`. Silencing every tree name in a
cite's block → `P2 3 unresolved reference(s)` *and* the derived count dropping 20→19, which is the derivation
proving it reads the corpus doc. And the redundancy red fired at 19 allowlist entries on the first run after
paragraph attribution landed — that red is what removed them, rather than leaving an exemption with no job
behind. Reader whose action changes: anyone adding an outside cite (name the tree in the block or the gate
says so), and anyone pricing a lock by its seat.

- **Honest limits.** Style and the Metal/SDK route are no longer judged by a runner: a push that skips
`make push-ready` can land `swift-format` drift or a route that cannot build the delivery shape, and only the
artefact judge (`release-artifact-check.sh delivery`, in `build-appstore`) will say so — recorded in
`docs/agent/build-gate-reality.md`, not hidden. Paragraph attribution can name the wrong tree when a block is
itself misleading (the gate cannot read the tree it is judging); it still beats a name list, and the 2
surviving declarations keep the unattributable residue honest. The knob's own first premise was still too
weak, and the runner said so: `text-gates` executed for the first time and came back **red** —
`P2 6 unresolved + 2 ambiguous` (`ChatSession.swift`, `KVCache.swift`, `KVCacheConfiguration.swift`,
`Libraries/MLXLMCommon/Chat.swift`, `UserInput.swift`, `Sources/HuggingFace/Hub/HubClient.swift`) — because
the knob dropped `~/references` but still counted `.build*/checkouts`, so a leg that never runs
`swift package resolve` was judged against a tree that had. The premise is the runner's now: checkouts drop
too, and dependency trees come from the `url:` lines of `Package.swift` (9 of them) instead of a hand list,
with four doc blocks saying `mlx-swift-lm` where they cited its files silently. The visibility patch paid off
— that red was readable with no token. `build-appstore` stays **red** on main, and its self-reporting fix
waits on the same push.


**10-28(8) The published skill shipped three dangling pointers, and the only gate that can see it asks git** (P0 adoption / symbols `ignored-skill-references`, `skill-trackedness-gate`)

- **What improved.** `.gitignore` mirrored reference trees with two **unanchored** rules — `reference/` and
`references/` — written for a tree that is not in this repo at all any more. Unanchored, `references/` matched
`skills/ocoreai/references/`, so the three files `skills/ocoreai/SKILL.md` cites by name (`wire.md` 10 582 B,
`agent-loop.md` 4 280 B, `honesty-and-limits.md` 3 218 B) were never tracked: the published skill told a
stranger's harness to read three documents that no clone contains. It is the same failure recorded inside
`.gitignore` for `docs/`, replayed in a new subtree one commit after the skill was pushed. The pattern is the
cause, so the pattern is fixed — both rules anchored to the repository root, the three files tracked — and the
blind spot gets a gate: probe 39 grew a **§0** (the gate layer is frozen, so no 41st probe) requiring every
path the skill cites to be tracked by git and nothing under `skills/` to be ignored, floor 3 cites so the scan
cannot pass by finding nothing.

- **What same-session output proves it.** The clone's view of the commit that shipped it:
`git ls-tree -r --name-only 61bb4b0 -- skills` lists **two** files while `SKILL_ORDER`
(`scripts/probes/_skill_task_harness.py`) names **four** — so probe 40's
`artefact=29 240 bytes across 4 files` was true of this disk and unreachable from a clone, where the harness
stops at `is absent`. After the fix both probes re-run whole: probe 40 **6 passed, 0 failed, 3 measured**
(artefact unchanged at 29 240 B, the secret token returned by a fresh agent on
`mlx-community/Qwen3.6-35B-A3B-4bit`) , probe 39 **31 passed, 0 failed, 6 measured** with §0 counted. The
class was swept, not just this instance: `git ls-files --others --ignored --exclude-standard` swallows exactly
these three project files and nothing else outside build output.

- **Which gate goes red if it regresses.** Red before green, on purpose: §0 printed
`git ignores file(s) inside the published skill: skills/ocoreai/references/agent-loop.md … wire.md`, and after
`git add` the same clause prints
`PASS 7 cited file(s) all tracked by git, and nothing under skills/ is ignored`. The two regressions it
catches are the two ways this recurs — an ignore rule reaching into `skills/`, and a cite added to the skill
whose file was never added to git — plus its own floor (3 cites). The readers whose action changes: the
harness that clones and follows a pointer, and whoever adds the fourth reference file.

- **Honest limits.** §0 gates trackedness, not correctness — the bytes a cite points at are judged by probe 39
§1/§2 and probe 40 — and it scans the 7 **backticked** cites only, so a pointer written without backticks is
invisible to it. It runs in the escalation tier (`make probes`), which means no runner executes it yet: giving
`make probes` a CI seat is the owner's call, and this round rewrote nothing that was already pushed.


**10-28(7) The injector now says what it cut — one resolver feeds the prompt, `/v1/capabilities` and the published skill** (P0 honesty / symbols `instruction-budget-disclosure`, `silent-truncation-fix`)

- **What improved.** The gap 10-28(6) measured is closed by one resolver instead of two stories.
  `WorkspaceContext.assemble` (`Sources/ocoreai/WorkspaceContext.swift:204`) now measures every discovered doc's
  fate — `whole` | `truncated` | `dropped` — and both consumers read that one measurement: the injected text
  carries `Workspace instruction budget N bytes: truncated <path> from A to B bytes` /
  `dropped <path> (A bytes)` (`noticeLine`, `:272`), placed **before** the docs so the model reads the notice
  before the truncated rule, and `GET /v1/capabilities` publishes
  `instructionBudget{maxBytes, injectedBytes, docCount, truncatedDocs, droppedDocs, docs[]}` beside
  `tokenizerBackend`, the precedent 10-28(6) named. That endpoint is public (it bypasses `AuthMiddleware`), so
  `docs[].label` is `<root>/…` and `path` is not encoded at all — an absolute path is somebody's home directory
  — which is also why the row is `Encodable`-only: a `Decodable` copy would have to carry the field back. Third
  consumer: the artefact a stranger reads. `skills/ocoreai/SKILL.md` §3 and `references/wire.md` now state that
  `instructionBudget` says whether *your own* instructions arrived intact, and that a non-zero
  `truncatedDocs`/`droppedDocs` means you say so instead of acting on a tail you never got; the skill's
  capabilities marker lists the field, so probe 39 executes the sentence rather than trusting it. The wording is
  borrowed, not invented (deepseek-harness pins it as a fixture; codex at least logs the cut). Rounds also paid
  their own drift tax: four `file:line` cites retargeted to the post-change lines, the root § Open bullet
  rewritten from "goes silently" to "disclosed, not gated" (frees bytes), and the `open-items.md` entry
  restructured into landed-vs-open.
- **What same-session output proves it.** A live `serve` on this host against a workspace seeded to overflow
  the cap: `/v1/capabilities` answered
  `maxBytes 32768, injectedBytes 32768, docCount 2, truncatedDocs 1, droppedDocs 1` with rows
  `<root>/AGENTS.md 39 012→32 768 truncated` and `<root>/sub/AGENTS.md 37→0 dropped` — the two cases that used
  to vanish, stated with exact bytes, no absolute path, `tokenizerBackend: real` beside them.
  `make test FILTER=WorkspaceContext` → **15 tests green** (4 new);
  `scripts/probes/03-capabilities-models-consistency.sh` → **32 passed, 0 failed**, its new clause printing
  `32768/32768 B injected over 2 doc(s), 1 truncated, 1 dropped`; probe 39 → **30 passed** with the extended
  marker; probe 40 → **6 passed, 0 failed** after the skill grew, artefact 28 366 → 29 240 B, and its README
  figure refreshed rather than left to drift. `swift build` green, `make format-check` clean on the pinned
  603.0.0, `make docs-check` and `make anchor-check` green, `make spell` clean.
- **Which gate goes red if it regresses.** Sampled twice in the session that wrote it. Reporting the dropped
  doc as `whole` turned probe 03 red — `expected [truncated, dropped], got ['truncated', 'whole']` — and three
  unit expectations with it; silencing the notice and publishing the real path instead of `<root>/` turned three
  more unit expectations red (6 issues across 3 tests). The split is deliberate: `WorkspaceContextTests`(15)
  gates the **values** (exact byte deltas, both states, no notice when nothing was cut, no `path` on the row)
  while probe 03 gates the **wire** (field present, every counter agreeing with its own rows, the seeded
  overflow exact, no path leak) and now boots against a workspace it seeds itself — without the seed the same
  assertions pass on an empty chain by finding nothing. The readers whose action changes: a caller deciding
  whether the project rules in its prompt are complete, and any harness whose trust is the skill's accuracy.
- **Honest limits.** No behaviour verdict: telling a 2B model that its instructions were cut may itself cost
  points, and no board arm scores that, so the disclosure's price is unknown (said in `open-items.md`).
  Injection is still **not gated by capacity** and no UI shows any of it — both owner calls, unchanged from
  10-28(6). No new probe file was added (the layer is frozen 10-28): the wire claim rides probe 03 and probe
  39's existing markers, so a dedicated probe remains the owner's gate decision. `skills/` and today's earlier
  rounds were uncommitted when this landed, and the commit carrying this slice carries them too — `AGENTS.md`,
  `CHANGELOG.md`, `scripts/probes/README.md`, `docs/agent/*`, `ChatCompletionsRouter.swift` and
  `WorkspaceContextTests.swift` hold edits from several rounds and cannot be split by path, so this diary entry,
  not the commit message, is the unit of record. Finally: the notice is one line per assembly, and the wire row
  is re-measured per request (one stat per doc plus up to 32 KiB from page cache) on a public endpoint —
  bounded, not free.
- **Landing hygiene, stated because it is a finding.** Asked what the process got wrong: a day of rounds never
reached git. `make push-ready` fails on its first check with
`56 path(s) uncommitted — the round is neither reviewable nor pushed`, and an invisible heap is precisely how
work escapes CI — a reader clones `origin/main`, not this directory. Landing it also surfaced a stale gate:
the full `make test` (3 370 tests) reported 6 issues, 2 of them
`deliveryTargetPinsTheRouteInsteadOfInheritingIt`, which grepped the Makefile for `DEVELOPER_DIR=$(CLT_DIR)`
and `$(SDKROOT_CLT)` — literals that 10-28(2) deliberately moved into
`scripts/toolchain-contract.sh print-delivery-env`. A gate that searches for a *copy* of a decision is the
second home `AGENTS.md` § Working here forbids, and § Testing Quality's "gates every consumer of the value it
changed" cuts both ways: the test now asserts the ladder itself — the resolver pins `DEVELOPER_DIR` and an SDK
chosen by name, refuses a host with no CoreAI-free SDK instead of inheriting Xcode's, and `build-app.sh` reads
that same resolver — so a route that stops being pinned still goes red, and so does a pin that drifted out of
it. The other 4 issues are real-clock timing tests (`testRateLimitExhaustion`, `queueWakesOnRelease`,
`hungServerTimeoutCarriesItsComplaint`, `steerArrivingMidWaitEndsItEarly`) that pass when run alone (5/5
green filtered), so they are recorded as load flakes rather than fixed on hearsay. `make push-ready` green is
the definition of done here; CI on macos-26 stays the authority for what the suite says.


**10-28(6) The twentieth comparator tree, a growth claim that failed its own arithmetic, and the truncation our injector hides** (P0 adoption / symbols `reference-economy-10-28`, `growth-ceiling-10-28`, `silent-truncation-10-28`)

- **What improved.** `~/references` was audited as an **economy** instead of a feature list: 20 trees, each
  measured for what a stranger actually ranks (stars · age · stars/day · 14-d commits · releases · tag cadence)
  and for what its instruction corpus *costs* — bytes, and the deepest root→cwd chain against the loader's
  32 768-byte budget. `deepseek-ai/deepseek-harness` was absent from `docs/agent/comparator-repos.md` and is now
  a row with four borrowable axes: the injected-corpus budget stated **in the prompt the model reads** and
  pinned as snapshot fixtures (`snapshots/session/agent-instructions-budget*/`, wording "Workspace instruction
  budget 700 bytes: truncated … from 1900 to 292 bytes"); oversize **refused, never truncated**
  (`docs/config-catalog.md:359`) with `truncated`/`total` on every view so no UI can present a partial result as
  complete (`docs/subsystems/tools.md:623`); an i18n **pairing** record instead of a duplicated translation
  (`README.i18n.yaml`, per-heading en/zh hashes); intake and review as *tested code*
  (`.github/issue-management/policy.test.mjs`, `.github/review-ownership/approval-policy.json`,
  `weighted-approval.yml`) — a tree that runs 263 k stars with `has_issues: false`, which is the whole intake
  argument in one field. openclaw's `maturity-scorecard.yml` and `update-migration.yml` are recorded beside
  them. Root gained the distribution rule (§ Adoption) and the silent-tail entry (§ Open); the runbook's
  leaderboard gained age and stars/day columns for 17 trees.
- **What same-session output proves it.** One deletion, two measurements, one green wedge. **Deleted:** the
  ladder's Growth section claimed a best sustained rate of ≈408 stars/day and therefore "#1 is unreachable on
  any honest schedule", yet the same corpus contains **3 469/day for 76 d** (deepseek-harness), Strata at
  1 016/day over 34 d and openclaw at 1 163/day, against our 1 star at 136 d — the arithmetic was never the
  ceiling, distribution is, so that paragraph and the runbook's "~150/day → ~7 years" line are gone rather than
  corrected. **Measured:** what binds us is the **chain**, not the file — root +
  `Sources/ocoreai/Engine/AGENTS.md` is **32 045 of 32 768 B (98 %, 723 B of headroom)** over a 46 527-byte
  4-file corpus, where mlx-serve runs 69 273 (211 %) and deepseek 55 362 (169 %) *because* they budget that
  chain and disclose the cut; and the cheapest new honesty gap is our own — **we truncate the instructions we
  inject, silently**: `Sources/ocoreai/WorkspaceContext.swift:169` does `data.prefix(remaining)` under
  `maxDocBytes = 32*1024` (`:24`) and says nothing to the model or the wire, where codex logs the cut
  (`agents_md.rs:157`, `:164`) and deepseek prints it into the prompt. **Green wedge:**
  `scripts/probes/40-stranger-agent-skill-task.sh` ran end-to-end this session —
  `6 passed, 0 failed, 3 measured, 0 known-open`, `injected_bytes=28366 files=4 tools=1(exec_command)`, premise
  PASS (the seeded note retrievable through the server's own `/sessions/search`), agent turn HTTP 200
  `finish=stop` on `mlx-community/Qwen3.6-35B-A3B-4bit`, verifier accepted: a fresh agent holding *only*
  `skills/ocoreai/` completed a real retrieve-then-write job. Re-read live while writing: deepseek-harness
  263 784 / 76 d, openclaw 393 227, **us 1 star / 0 forks / 0 watchers / Discussions off / homepage unset**.
- **Which gate goes red if it regresses.** Probe 40 existed but was **unindexed** — P14 red
  (`probe-index=39/40`); indexing it makes the discovery surface agree with the tree, and its §1 tier is the
  standing gate on the wedge: the artefact must inject whole over a 12 000-byte floor and the verifier must
  reject a wrong deliverable, so `skills/ocoreai/` shrinking, or a lenient checker turning every §2 green into a
  measurement of itself, goes red **in the sandbox tier** with no Metal and no server. The round also caught its
  own drift: four docs written hours earlier quoted a **32 021 B / 747 B** chain that the `Engine/` guide had
  already grown past. The figures were re-measured at that step to 32 045 / 723, and `make docs-check` prints
  `budgets … deepest-chain=32045/32768` — a reported count, no verdict, priced by the B2 leg that already goes
  red at the cap — so the next reader re-greps a printed field instead of trusting a paragraph.
  `make docs-check` green at `probe-index=40/40` and root **21 454/21 461**; `make anchor-check` green (76
  anchors, drift 0), new deepseek cites included. The comparator axes stay host-local by design: docs-check
  prints them as outside-tree cites, never runner-visible.
- **Honest limits.** Nothing shipped: still **0 tags, 0 releases**, and `skills/` is untracked while root
  cites it, so a fresh clone does not contain the surface this round just proved works — committing it is an
  owner action. The truncation gap is **recorded, not fixed**: the disclosure line (a model-visible cut notice,
  then a row beside `tokenizerBackend` on `/v1/capabilities`) is the next slice and needs no new gate to be
  honest. Four `docs/agent/` files were rewritten today and three sit within 15 bytes of the 15 609-byte
  per-file cap (comparator 15 599 · runbook 15 604 · goal 15 595), so the next word there is traded, not added;
  root sits **609 B below** its HEAD size, which is what makes that cap a ratchet rather than a suggestion. The
  one home for the chain-and-silence finding is now `open-items.md` § *The chain ceiling* — its duplicate entry
  carried the same cites and the same fix shape, and deleting it freed 1 200 B in a file 7 B from its cap.
  Comparator figures come from host clones plus one `api.github.com` read at one moment, and stars/day divides a
  lifetime count by lifetime age, so it flatters young trees. Probe 40 was written in another session's
  uncommitted work — this round indexed and ran it; the tree still holds ~37 paths that are not this round's,
  which is why nothing was committed. No Swift changed: no build, no behaviour claim.

**10-28(5) What the best-distributed trees actually run — release cadence, the first screen, and a tag number that pointed backwards** (P0 adoption / symbols `cadence-audit-10-28`, `stale-tag-number`)

- **What improved.** The nine trees the owner named were re-audited for *distribution* mechanisms rather than
  features (four new to this corpus: sglang, vllm, `coreai-models`, and the release shape of mlx-swift-lm),
  and the findings went where they change spending: § *The release cadence rule* in
  `docs/agent/competitor-iteration-paths.md` (measured release counts, asset shapes, the build/publish trust
  split), § *The first screen* / § *The proof surface* / § *Corrections and new baselines* in
  `docs/agent/adoption-runbook.md`, and four new `docs/agent/open-items.md` entries — publish-credential
  split, the measured model catalog owed, P18's priced cap on the locale channel, and the `MLXScriptedLM`
  re-judge trigger. Two claims died. Root § Adoption told whoever read it to run `git tag v0.1.10`, and the
  tag *is* the version (`scripts/version.sh`), so obeying it would have published a build numbered below the
  withdrawn 0.1.13 line — root now names `v0.1.14` and states the arithmetic. And the ladder's S row claimed
  "36 live probes" where `make docs-check` prints `probe-index=39/39`, while `open-items.md` said "Two
  probes of 38" where three of 39 run headless today; both now match the command that re-measures them.
  Rung 1 changed noun: **cadence, not one tag**.
- **What same-session output proves it.** `api.github.com`, `/releases?per_page=100` per tree (page cap, so
  "≥"): openclaw ≥100 / 0 d / 103 assets (one is a per-release `dependency-evidence.zip`), codex ≥100 / 0 d /
  **3 116 assets over 10 releases** across nine per-surface release workflows, opencode ≥100 / 0 d / 360,
  vllm ≥100 / 9 d / 83, omlx ≥100 / 0 d / 45, pi ≥100 / 6 d / ~10, sglang ≥63 / 9 d / 0, hermes-agent 44 /
  4 d / 0, `coreai-models` 2 / 15 d / 0, **ocoreai 0 releases and 0 tags** — the last confirmed twice,
  `git ls-remote --tags origin` empty and `/tags` + `/releases` both `[]`. That second route also retired an
  unfalsified premise: the diary recorded the withdrawn Releases as "they still resolve", an assumption made
  because this host holds no token to check — today they do not resolve. First-time baselines written down:
  watchers (openclaw 1 696 · hermes-agent 984 · opencode 859 · codex 666 · vllm 607 · **us 0**) and open
  issues+PRs (hermes-agent 51 482 · codex 25 097 · vllm 9 609 · opencode 3 853 · **us 0**), against
  opencode's five triage workflows answering its 3 853.
- **Which gate goes red if it regresses.** Two new anchored upstream cites in `open-items.md` (the scripted
  tokenizer's conformance to upstream's `Tokenizer`, and its README's *Planned* line for transcript tool
  calls) verify **at the pin** under `make anchor-check` — 74 anchors, was 72 — so "upstream has not
  delivered that half" cannot rot silently through a bump. Probes 37/38/39 re-ran green over the edited tree
  (20 / 13 / 30 passed, 0 failed), probe 37 still printing `AGENTS.md quotes 40 advertised tools`: the
  sentence this round trimmed for bytes is exactly the one a probe greps, so the trade was priced against a
  live red rather than a guess. `make docs-check` holds root **21 422/21 461** — the cadence rule cost
  +102 B and was paid for by demoting two § Open evidence sentences to the `open-items.md` entries that
  already carried them, which is what that section's own rule prescribes — and
  `docs/agent/long-horizon-goal.md` sits **exactly at 15 609**, so the next word there is traded, not added.
  `make spell` and `make audit` green.
- **Honest limits.** Nothing shipped: still 0 tags and 0 releases, and the cadence finding is an **owner
  policy question** (tag per merge; split build from publish), not an agent action — the agent does not tag
  unasked. "≥100" is a page cap, not a count, and every release age was read at one moment. The
  first-screen/proof-surface work is recommended, not built: no anchor nav, no version badge (impossible
  before a tag), no generated `models.json`. Comparator figures come from host clones plus one live API read
  — they resolve on this host and never on a runner, which is why `make docs-check` prints them as
  outside-tree cites. No Swift changed, so no `swift build` and no behaviour claim. `skills/` is still
  untracked while § Adoption cites it: until it is committed, a fresh clone does not contain the surface the
  root promises.

**10-28(4) The published skill is executed, not trusted — 19 markers run against a live server and a real checkpoint, and last round's contract claim went red** (P0 adoption / symbols `skill-contract-exec`, `audit-overclaim-contract`)

- **What improved.** Rung 3's wedge (another harness drives `/v1`) landed its artefact and its gate in one
  move. `skills/ocoreai/` (`SKILL.md` plus `references/wire.md`, `agent-loop.md`,
  `honesty-and-limits.md`) and `skills/README.md` (install steps for Claude Code, Codex, a plain context
  file, and the extension shape, following the `mlx-swift-lm/skills/README.md` convention) — every wire
  claim written as an executable HTML-comment marker inside the paragraph that makes it, so the skill
  cannot describe a route the server does not answer. `scripts/probes/39-skill-contract-exec.sh` runs them
  in three tiers (§1 the scripted contract lane, §1b the key boundary, §2 a real checkpoint) and CI runs
  the probe from the headless-serve smoke step; `README.md` / `README.zh.md` gained a § *Drive it from
  another agent* pointing at both. **The correction is the substantive half of this round.** Last round
  asserted "no machine-readable contract over the routes P10 counts" and it was *false*:
  `GET /v1/capabilities` has served `endpoints[]` since `V1EndpointCatalog` — 34 rows of
  `{method, path, auth, note}`, `auth` derived from `AuthMiddleware`'s own sets so the index cannot call a
  blocked route public, method+path pinned to the router by `V1EndpointCatalogTests` with a floor on its own
  scan. Invariant 2 cuts both ways: a surface under-claimed is the same defect family as one over-claimed,
  and this one was about to spend the owner's money on a contract that already existed. Fixed in all four
  live surfaces (`AGENTS.md` § Adoption, `adoption-runbook.md`, `long-horizon-goal.md` rung 6, the README
  pair); what is genuinely absent is a *standard-format* spec (OpenAPI) and a client generated from it.
- **What same-session output proves it.** `bash scripts/probes/run.sh 39` → **30 passed, 0 failed**, with
  **14 `exec:` + 5 `exec-model:` markers executed out of the skill's own text**. §2 is premise-first: one
  real generation completed on `mlx-community/Qwen3.6-35B-A3B-4bit` before any assertion below it, so those
  five rows are measurements and not an `unloaded` server agreeing about itself. §1b proved the boundary the
  skill tells clients to expect — keyless generate → 401 naming the remedy, bearer key → 200
  `chat.completion`, `/health` still public with keys set. `references/wire.md` was generated from a live
  `GET /v1/capabilities` (34 endpoints + 12 capability rows) and carries its own re-generate command, because
  a hand-copied route table is the drift class the note exists to prevent. Probes 37 and 38 re-run green
  after the doc edits (13 passed / 0 failed on 38). The round also caught itself once the hard way: a trim
  that removed the advertised-tool count from `AGENTS.md` turned probe 37 red, because that number is read
  out of the injected file at `scripts/probes/37-scripted-engine-wire.sh:169` and compared with live
  `/v1/tools` — a doc figure a probe greps is not prose.
- **Which gate goes red if it regresses.** Probe 39 floors its own marker counts (12/4 against the 14/5
  present), so a rotted marker pattern, a renamed skill or a deleted `skills/` fails loudly instead of
  passing by finding nothing — the failure this probe exists to prevent is its own. It sits in
  `.github/workflows/ci.yml`'s headless-serve smoke step, so the skill cannot quietly rot between releases.
  `V1EndpointCatalogTests` fails the build when a route is added, renamed or removed on one side of the
  router/catalog line only. `make docs-check` holds probe-index 39/39, P12 (§ Adoption, § Agents as
  clients), P2/P9 (the runbook hop exists and is tracked) and P18 (the new `skills/*.md` are English, the
  zh mirror gained its paragraph: mirror-cjk 3 144). Root budget **21 426/21 461**: the correction cost
  +21 B, the cap stayed put per the shrink-only rule, and headroom fell 56 → 35 B — stated instead of
  papered over, because "the injected file only ever gets smaller" is a claim about a file that just got
  bigger. `make spell`, `make anchor-check` (72 anchors + 220 bare upstream cites), `make audit` all green.
- **Honest limits.** §2 has not run on a runner: the checkpoint tier needs ready weights, and CI's headless
  smoke exercises §1 and §1b — so "the measured tier is green" is a local verdict until a push says
  otherwise. No Swift changed this round, so no behaviour claim and no `swift build`. **Discoverability is
  unproven**: probe 39 executes the documented calls, it does not show that a fresh agent handed nothing but
  `skills/ocoreai/` finds it and finishes a task, and an agent that never opens the file never reads it —
  that instrument is still owed. A standard-format spec and a generated client remain owner calls, and a
  published contract is precisely a promise about every future release. iOS untouched and unverified.
  `git tag` is still empty: rung 1 is one person typing `git tag v0.1.10 && git push origin v0.1.10`.

**10-28(3) The reference audit: what the category's #1 actually runs, and the three claims our surface still cannot make** (P0 adoption / symbols `adoption-audit-10-28`, `area-cap-visible-raise`)

- **What improved.** The owner's question was whether this repo can be GitHub's #1 coding agent. Nine named
  trees plus `openclaw` were audited for the *mechanisms* behind their numbers (not their features), and the
  answer went where it changes spending: a new `docs/agent/adoption-runbook.md` (cite per mechanism), a
  `§ Adoption` block in `AGENTS.md`, five rungs of `docs/agent/long-horizon-goal.md`, and six comparator
  cells. Three findings re-order the work. **(1) The leader consumes a local engine instead of competing with
  one** — "Models and agent harnesses (Claude, Codex, local models) are plugins you can swap"
  (`../references/openclaw/README.md:20`) — so the wedge is to be the plugin those harnesses install, and what
  blocks it is measured: no machine-readable contract over the routes `make docs-check` P10 counts, no
  generated client, and no published `skills/`, while mlx-swift-lm, coreai-models, vllm, sglang,
  hermes-agent and openclaw all ship one (two of them with install steps for *another vendor's* agent).
  **(2) A release is one command a stranger runs**: a runtime-provisioning installer script
  (`../references/codex/README.md:19`, `../references/openclaw/README.md:30`), a self-serve tap
  (`../references/omlx/README.md:58`, formula in-repo), and update *inside* the app
  (`../references/omlx/README.md:53`; openclaw ships Sparkle appcasts) — where we have a DMG behind a tag
  that does not exist and `Core/UpdateCheck.swift`, which hands Settings a release-page URL. **(3) At 473
  authors in 14 days the intake policy is the product**: duplicate-work checks as runnable commands
  (`../references/vllm/AGENTS.md:8`), no busywork (`:21`), fail-closed (`:39`), a human who defends the
  change and an agent that may draft but not open the PR (`../references/mlx-swift-lm/AGENTS.md:5`, `:24`),
  merge policy as data (`pi/.github/APPROVED_CONTRIBUTORS`) and CI rights as data
  (`sglang/.github/CI_PERMISSIONS.json` + `audit_permission.py`).
- **What same-session output proves it.** Leaderboard off `api.github.com` (HEAD's authority — a mirror
  proves content, never HEAD): openclaw 393 200 stars / 82 660 forks from a 2025-11-24 creation,
  hermes-agent 257 674, opencode 222 285, codex 131 259, pi 118 250, omlx 23 102, coreai-models 2 223,
  mlx-swift-lm 847, **ocoreai 1 / 0 forks / 0 tags**. Cadence off the local clones
  (`git log --since='14 days ago' --oneline | wc -l`): openclaw 11 427 commits and 473 authors in 30 d,
  hermes-agent 5 613 commits and 982 authors, opencode 1 107, ours 243 with 3 authors in 90 d. And opencode
  measured **419 fewer** stars than the 10-26 snapshot in the ladder: a star count is a pruned estimate, so a
  day-delta is not a target — recorded because it kills a tempting metric before anyone builds on it.
- **Which gate goes red if it regresses.** `make docs-check` — P9 (the runbook is tracked *and* routed, so a
  promised evidence hop cannot be absent from a fresh clone), P12 (`§ Adoption`, `§ Rung zero`,
  `§ The intake machine`, `§ Agents as clients` all resolve), P2/P3 with `make anchor-check` (every
  `../references/<tree>/<path>:<line>` cite resolves and its line exists), B1/B2. Budgets moved the honest
  way: `make docs-budget` re-pinned the root cap **21 480 → 21 461** — the injected file gained a five-rule
  section and still got *smaller*, because nine figures it restated already had one home (eval README,
  open-items, the diary). The one raise is visible per the rule at the head of the script:
  `OCOREAI_AGENTS_MAX_AREA` 14 323 → 15 609, with the reason in the same diff, because "Rung zero" plus this
  audit carried the ladder past the file the cap was pinned to; the host's 32 KiB chain budget and the root
  ratchet both stayed green and unmoved.
- **Honest limits.** No Swift changed, so no behaviour claim and no `swift build` run — docs, one shell
  constant, and the goal. Nothing here closes anything: at the field's best *sustained* rate (~150/day,
  codex measured) openclaw's present total is ~7 years of growth while the target itself moves, so the
  objective is the wedge rank, stated in `docs/agent/long-horizon-goal.md` § Rung zero, and "#1" stays a
  distribution event with a ceiling. Three claims our surface still must not make, each named so nobody
  makes it by accident: **installable** (no tag, no notarisation, no tap, no in-app update), **agent-drivable
  by a published contract** (prose and probes only), and **community-scale intake** (one workflow file, four
  forms, no triage or locale automation).

**10-28(2) The DMG path was broken by an ungated `canImport(CoreAI)` use, and installing the artefact now proves the mission's sentence in 22 s** (P0 adoption + P1 correctness / symbols `delivery-route-one-home`, `installed-app-first-completion`)

- **What improved.** Running the artefact path instead of reasoning about it found a real defect: `LoadedModel.isCoreAIAsset` is declared inside `#if canImport(CoreAI)` while `EnginePool.swift:1468` (`loadedBackendKind()`, the scripted-engine work) used it ungated — so the CoreAI-free delivery build died with `value of type 'LoadedModel' has no member 'isCoreAIAsset'`. The declaration now lives outside the gate (the CoreAI body stays gated; on a route that cannot import the framework the answer is `false`, which is measured, not a stub). The *route* also got one home: `scripts/toolchain-contract.sh print-delivery-env` prints the CoreAI-free SDK, the Metal bin prepend and the search-path flags, consumed by `scripts/build-app.sh` (and therefore `build-dmg.sh`, which had been unbuildable on any host whose newest SDK carries CoreAI) and by `make release`.
- **What same-session output proves it.** `bash scripts/build-dmg.sh` on the dirty tree → **2 min 22 s** → `dist/ocoreai-0.0.0.dmg` (25 MB) with `✅ artifact is the delivery shape (coreai=no, minos=14.0)`, metallib, 38 bundled notice files, icon, privacy manifest and entitlements. The DMG's `.app` copied into a fresh directory (91 MB, ad-hoc arm64) then passed `scripts/e2e-gui-app.sh` end to end in **22.1 s, zero compiling**: version parity, the listener *is* the bundle, a rendered 900×472 window with 606+ distinct colours, one real turn through its bridge on `mlx-community/gemma-4-e2b-it-4bit`, graceful SIGTERM. `make release` after the target refactor: 6 min 08 s, same verdict. `make test FILTER='Workspace|Scripted|Reasoning|CoreAI'` → **147 tests in 36 suites**, the first run of `ScriptedEngineTests`.
- **Which gate goes red if it regresses.** The CI leg named "App Store trait compile (macOS 26)" ran the ambient-SDK `swift build` and never looked at the shape it produced, which is how a delivery-breaking use site sat in the tree with every leg green; it now pins the resolver's route, prints it, and judges the binary with `release-artifact-check.sh delivery`. Both build routes call that same checker, so a CoreAI-bearing artefact cannot be reached by accident.
- **Honest limits.** Not a clean machine: the weights were already in `~/.ocoreai/models`, so a stranger still pays the first-run download the 22 s does not include, and nothing here is notarised. `make release` and the DMG rebuild re-stamped `.build/release/ocoreai`, so the board's `binary` token moved — the four doc arms must be re-run before their figures are compared with new ones (that refusal is the instrument working).
- **Also in this round.** The publish step's release note is English-first with the Chinese half dropped: it is the first text a stranger reads about a build, and the repo's own rule allows exactly one Chinese file. Verified against live state rather than memory: `scripts/ci-status.sh` exit 0 (every leg that must run on a main push is green, `Release DMG` skipped — it is tag-gated), the four `.github/ISSUE_TEMPLATE` forms parse as YAML, and the labels they set (`bug`, `enhancement`) exist in the repo.

**10-28(1) The prose-shape gate family is deleted rather than demoted — 27 verdict sites and five check ids out** (P2 process / symbols `gate-deletion-10-28`, `diary-excluded-not-ceilinged`)

- **What improved.** The owner's charge — *"so many gates is meaningless"* — had been answered twice with
  demotions, and a demoted gate is a gate that still runs, still prints and still has to be read. This
  round deletes: **P13** (dated stamps and >400-byte lines inside `AGENTS.md`), **P15** (corpus line
  walls), **P16** (comparator coupling — diary coverage, two hand-copied lists, a zero-coupling
  equality), **P17** (area-guide scan floors), **P20** (verbatim-duplicate bullets), and **P18's diary
  CJK ceilings**: the diary is *excluded* from the English-by-default rule now, because a ratchet that
  blocks the owner writing their own log in their own language is friction, not a contract. Net: 27
  `fail` sites and five ids out of `scripts/agents-md-contract.sh`, 70,401 → 55,926 bytes of gate
  script, and its report is 10 lines where it was 12 (the guide and comparator rows are gone).
- **What same-session output proves it.** `make docs-check` green on the cut tree (root 21,494/21,494
  after `make docs-budget` lowered the cap, `claims=32/32`, `probe-index=38/38`, dangling `§`-refs 0,
  numbered suite claims 39/39, `router-routes=34`). The cut also caught a lie the deletion created:
  `AGENTS.md` line 5 claimed "`make docs-check` enforces that split" — with P13 gone that was false, so
  the file now says what is true (`nothing enforces that split but the byte cap`) and paid for the new
  § Working here clause out of its own bytes rather than the cap's.
- **Which gate goes red if it regresses.** None, and that *is* the answer to the charge instead of a
  dodge: none of the six had a red on record, while every survivor has one — `§`-references that
  outlived the heading they named (P12), five drifted suite-count claims, one of them advertising more
  coverage than its file holds (P11), and two README links pointing at repositories that do not exist
  (P19). Tier rule, one home, `CONTRIBUTING.md`.
- **What the stack was actually costing was the order of spending, not its exit codes.** 329 of 1415
  commits here went to docs/CI/gates — one gate commit per three product commits — while `git tag` is
  still empty and the board still reads 6 of the 43 tools we ship. Nothing in the gate stack can be
  installed, so none of it is a thing a stranger would rank us on; the sentence now sits in
  `AGENTS.md` § Working here where every session reads it.
- **What this does not fix.** Deleting checks ships nothing. Rung zero still waits on the same two
  actions — a green `macos-26` authority leg and one tag — and the model-gated tool surface
  (−18.8 pp, 10-27(22)) still waits on the owner. Freezing the gate layer is what makes those the only
  two things left to spend on.

**10-27(25) The corpus's cost is injection, not size — 2.4 KB injected costs 12.8 pp and the same bytes left uninjected cost nothing** (P1 product-decision evidence + P2 instrument / symbols `injection-vs-presence`, `docs-inert-arm`)

- **What improved.** The board can now separate the three things the 10-27(24) result conflated.
  `OCOREAI_EVAL_DOCS_INERT=1` lands the same bytes as `AGENTS.inert.md`, which `WorkspaceContext`'s
  candidate list ignores, so a corpus can be **in the workspace without being in the prompt**;
  `WorkspaceContextTests` gained `a non-candidate name in the workspace reaches no prompt`, pinning that
  closed list (the candidate pair, `instructionFiles` empty, and the section carrying none of the bytes)
  so the arm cannot decay into measuring a stray file as instructions. The arm asserts itself from the
  run: the injected name must not exist while the inert bytes do, and the server's `systemChars` span
  is printed as the witness (`3002..3959` inert vs `5543..6500` injected — the same 2,442 B).
- **Same-session output — one artefact, one task set, one tool surface, four arms at k=3.** `none`
  **25.00/39** (SD 1.00) · `inert` 2,442 B **24.00** (SD 2.00) · **distilled 2,442 B injected 19.00**
  (SD 0.00) · **root 21,529 B injected 16.33** (SD 1.53). Paired, McNemar exact two-sided: presence is
  free (**Δ −1.00 task, −2.6 pp, b=6/c=3, p=0.5078**); **injection is the cost (Δ −5.00, −12.8 pp,
  b=16/c=1, p=0.0003)**; size beyond 2.4 KB is **not separable at k=3** (Δ −2.67, −6.8 pp, b=14/c=6,
  p=0.1153); whole-to-whole none→root is −8.67 (−22.2 pp), p<0.0001, replicating 10-27(24)'s −19.7 pp.
  `fixtures/AGENTS.distilled.md` is a faithful compression of the root — two invariants, build/verify,
  editing rules, git — so the arm measures bytes and the act of injecting, not a rival rule set.
- **Why it matters more than the byte budget.** The root's size discipline is the smaller half of the
  question: on a 2 B-class checkpoint the act of putting *any* instruction corpus in the system prompt
  costs ~13 pp, and the remaining 19 KB of prose adds nothing separable. Two candidate responses are
  code/product, not prose: don't inject per-turn docs for checkpoints of this class (the agent can read
  them on demand — the inert arm shows the file itself is harmless), or move the doc from the front of
  the system prompt to behind the base prompt (`MessageBuilder` composes
  `workspaceSection + builtSystemPrompt` today). Neither is a measurement anymore; both are an owner
  call, recorded with its instrument in `docs/agent/open-items.md`. Trace-level mechanism, unchanged from
  10-27(24) and *not* a length effect: `edit-replace-all` collapses 3/3 → 0/3 in the distilled arm too,
  answering that it failed to edit `AGENTS.md` when the task named `notes.md`.
- **Where the gate bites, with its red samples.** `OCOREAI_EVAL_DOCS_INERT=1` with
  `OCOREAI_EVAL_DOCS=none` refuses at boot (an inert doc that does not exist). The inert floor fails if
  `$EVAL_WS/AGENTS.md` appears or the inert bytes vanish — i.e. exactly the case where the arm would
  silently measure injection again while reporting presence. `bash -n` clean, `_conditions_selftest.py`
  still 41/41 (the inert arm's `docs` token is the *landing* name, `AGENTS.inert.md+sha`, so a
  conditions line can never claim an injection that did not happen), `_ledger_selftest.py` green, and
  the Swift contract test is the gate that keeps the candidate list closed.

**10-27(24) The board can now say what a turn was handed — and it prices this file at −22.2 pp** (P2 process+instrument / symbols `docs-arm-stated`, `corpus-priced-paired`, `artefact-named`)

- **What improved.** Three conditions a scoreboard was quoting without stating. `docs` —
  `OCOREAI_EVAL_DOCS=none|root|/abs/path`, recorded as `none` or `<basename>+sha256:<12>` of the bytes
  the workspace handed the agent, and as **surface** so a paired with/without A/B is judgeable rather
  than refused; the board's whole history was a `without_docs` run that never said so. `binary` —
  `<name>+<mtime>+<bytes>` of the artefact that answered, plus a floor that refuses to score a tree
  older than the artefact judging it (both mtimes printed, remedy named, `OCOREAI_EVAL_ALLOW_STALE_BIN=1`
  when an old build is the point). And a root-cause fix found on the first try: the task loop wipes
  `$EVAL_WS` before every task, so a doc copied at boot was gone before turn 1 — every turn assembled
  a doc-free prompt (`systemChars=3002` against a 21,548 B doc) while the run reported a doc arm.
  `materialize_docs` now runs at boot *and* after every wipe, and an arm whose doc cannot be
  substantiated at boot exits before it writes a score.
- **Same-session output: rung 3 measured, twice.** k=3 per arm, same 39 tasks / 6 tools / checkpoint,
  one conditions field apart. Recorded pair (artefact built from HEAD, root doc 21,529 B):
  `docs=none` **24/25/26** (mean 25.00/39, 64.1%, SD 1.00) vs `docs=root` **15/18/16** (mean
  16.33/39, 41.9%, SD 1.53) — **Δ −8.67 tasks (−22.2 pp), McNemar exact two-sided p < 0.0001**,
  b = 29 / c = 3, no task 0/3 → 3/3. Replicate pair (hours earlier, then-current artefact, 21,548 B):
  **24.67 → 17.00/39, Δ −7.67 (−19.7 pp), p = 0.0003**, b = 31 / c = 8. The quote is the range
  **−19.7 to −22.2 pp**, not a point. Premise floor passed in all six `root` runs (39 assembled
  prompts each, `systemChars` 24,630–25,587), so the doc demonstrably arrived. Mechanisms, read off
  traces: the doc is a **distractor** (`edit-replace-all` answered *I failed to replace "FOO" with
  "BAR" in AGENTS.md* — it tried to edit the injected file; identical in both pairs), long context
  **degrades the tool call** (`fix-boundary-comparison` typed `edit_file(path=…` into the text channel
  where the doc-free arm passed 3/3), and **narration displaced action** (mean answer 63 B → 100 B,
  median 27 → 36, with the workspace unchanged). At −22.2 pp the corpus now costs roughly what handing
  the model all 40 tools cost (−18.8 pp, 10-27(22)) — two halves of the same turn, both priced.
- **Drift, quoted because it prices every unpaired number in `scripts/eval/`.** The doc-free arm has
  three measurements today: **22.67** (10-27(22)), **24.67** (this round's replicate) and **25.00**
  (the recorded pair) — byte-identical `tasks=`/`tools=` digests throughout, differing only in
  `binary`, which did not exist as a field for the first two. 2.3 tasks across sessions on a board
  whose within-batch SD is 1.00–1.53: re-running an arm is not re-deriving a number.
- **Where the gate bites, with its red samples.** The pre-fix run *is* the live sample — `FAIL the doc
  did not reach every turn: 2 assembled prompt(s), smallest systemChars=3002 < the 21548 B doc` — and
  the same command after the fix prints `PASS … 24630..25587 ≥ 21529 B`. Pointing `OCOREAI_BIN` at the
  17:20 artefact while `Sources/` had moved at 20:15 prints both mtimes and refuses before the boot;
  the fresh artefact passes. Static side, `_conditions_selftest.py` (29 → 41 checks): dropping `docs`
  from `SURFACE_FIELDS` → 2 defects; removing the field from the renderer → 5; deleting the helper too
  → the scan floor speaks; hoisting the doc copy above the per-task wipe → `the doc is not
  re-materialized after the per-task workspace wipe`; demoting `binary` to surface → `a rebuild between
  arms changes the engine, not the hypothesis`; cutting the `--binary`/mtime wiring → both artefact
  floors report a rotted scan.
- **Docs drift repaired on the way** (invariant 1: a doc whose numbers nobody re-greps drifts):
  `scripts/eval/README.md` said `OCOREAI_EVAL_FLOOR_TASKS` was 18 (34) and `_conditions_selftest.py`
  ran 25 checks (41), and omitted the family floor and the `OCOREAI_SELFTEST_FLOOR` refusal; `run.sh`
  claimed a 36-task default set and a 36/52 floor pair (39/52 loaded, so the default set losing five is
  the failure); reproduce snippets pointed at a staging path no recipe writes (`.build/out/Products/…`),
  which is how a 17:20 artefact came to be judging a 20:15 tree — they now build first and name
  `.build/release/ocoreai`. `_repeat_stats.py`'s movement sentence is field-aware: it told a docs A/B
  that "the schemas/descriptions the model was handed changed", which was the wrong explanation of its
  own number.
- **Footprint, per the ladder.** Harness only — no product code, no new core surface: one env knob, two
  conditions fields, one shell function, two premise floors, one field-aware message. What it decides
  is owned elsewhere: whether a per-turn instruction corpus should scale with the checkpoint's capacity
  (distil ~1.5 KB? gate by size? keep the corpus out of the workspace file tree?) —
  `docs/agent/open-items.md`, and rung 5 of `docs/agent/long-horizon-goal.md`.

**10-27(23) A caller-enableable capability is now gated against the checkpoint that must honor it — and the silent no-op it replaced was live on this host** (P2 surface / symbols `reasoning-effort-face`, `model-gated-refusal`)

- **What improved.** `reasoning_effort` used to be forwarded verbatim into the chat-template context
  (`ReasoningEffortWire` owns no enum and no word table, deliberately), so on a checkpoint whose template
  never names the variable the word was dropped before generation — and the caller still got **200** and
  believed it had asked for thinking control. At load the server now renders the checkpoint's *own*
  template twice, once with a sentinel value no effort table contains, and records the answer per
  checkpoint (`ReasoningEffortLedger` → `honored` | `template_ignores` | `not_observed`); `/v1/models`
  publishes it, and a demanded word the measurement says cannot reach the model is refused **400 naming
  the knob, the evidence and both exits** — the shape of codex's `unsupported_code_mode_warning`
  (`core/src/session/code_mode_warning.rs:6-24`), where unknown metadata is never read as enabled. The
  fail-open direction is pinned too: unmeasured is *not* refused, because absence of evidence is not a
  measured "no" and a refusal costs a caller a turn they asked for.
- **Same-session output, against a real checkpoint.** `mlx-community/gemma-4-e2b-it-4bit` renders
  **identically with and without the kwarg** → the face publishes `template_ignores`, and
  `{"reasoning_effort":"high"}` on it now returns 400 whose message contains the model id, the knob, the
  value sent, the ledger's own evidence sentence and both remedies (`Omit reasoning_effort…` / a model
  whose row says `honored`); the request after it is served, so the refusal is a refusal and not a crash.
  With no weights resident the scripted lane answers the same turn **200** — the measured negative is the
  only thing that refuses. `scripts/probes/38-reasoning-effort-honesty.sh` decides all of that: **13
  assertions, 0 failures**, §1 needing neither Metal nor a download, and
  `ReasoningEffortHonestyTests`(9) pins the truth table, the closed vocabulary and the remedy wording
  without a tokenizer.
- **Where the gate bites, with its red samples.** Pinning the load-time measurement to `nil` turned §2 red
  (`the load-time template probe never recorded anything for the loaded model`) — that floor is what stops
  a rotted measurement from reading as honesty. Pinning the refusal rule to `false` turned §2 red too, and
  the body it printed **is** the bug this gate exists for: `200 … finish_reason:"stop"` with the word
  silently gone. §1 goes red the other way if `not_observed` ever starts refusing. Both tiers sample;
  `make docs-check` keeps the probe indexed and every cited suite count honest.
- **Footprint, per the ladder.** No new core surface: the probe renders through the existing
  `MLXBridge` handle seam next to `chatTemplateRendersTools`, the decision lives beside the demand rule in
  `ReasoningEffortWire`, the refusal sits in the seat `ChatHandler` already uses for the numeric and
  `tool_choice` gates, and the records live **on `EnginePool`** (engine actors own engine/model truth, so an
  unload drops the claim with the weights) rather than in a `shared` global. `Sources/ocoreai/Handlers/AGENTS.md`
  and `scripts/probes/README.md` carry the promise and the index; README's per-model disclosure keys name
  the new field; the root paid its own bytes and re-pinned at **21,548**.
- **Honest edges, stated before they are used.** The measurement runs on the MLX lane, so a CoreAI-loaded
  model reports `not_observed` and is never refused — that is the fail-open direction, not a claim about
  CoreAI. Probe 38 §1's new CI seat sits in the headless-serve smoke step and has not run on a runner
  yet, so until its first pass it is a candidate gate. And the *surface* half of this item is untouched by
  design: per-turn tool shortlists change what the composer may promise, so they wait on the owner —
  `docs/agent/open-items.md`, priced at −18.8 pp by 10-27(22).

**10-27(22) Eleven shape gates deleted, three number gates made to bite, and the first A/B that survives its own noise floor** (P2 process+surface / symbols `gate-tier-triage`, `surface-cost-paired`)

- **The owner's question, taken literally: "so many gates is meaningless."** Measured before answering it:
  329 of 1415 commits here went to docs/CI/gates — one gate commit per three product commits — across
  3,367 `@Test` cases, 37 probe scripts, 31 make targets and 78 doc-corpus checks — while `git tag` is empty
  today (the three existing releases had their tags withdrawn on 10-26, 7 downloads between them).
  Nothing about the gate stack can be installed, so none of it is what anyone would rank us on.
  Two of those numbers are now smaller, on the rule written into `CONTRIBUTING.md`: **a check blocks when a
  red means someone acted on something false; everything else is deleted, not downgraded.**
- **Deleted (11).** P17's eight area-guide shape rules (H1 wording, title bytes, a governance sentence in
  the first 8 lines, a scope block naming a directory, a per-guide gate count, a `## Verification` section
  naming a command, dated stamps) — nine signals a round, none ever red: wallpaper. P14's table column
  counts and orphan-doc rule, and P15's one-hop line walls — a miscounted column misrenders our prose, it
  does not send a reader or a caller somewhere wrong. All three are still *counted and printed* as
  metrics; only the verdict is gone. Also deleted: the corpus byte cap's advisory ghost.
- **Promoted (5), each red-sampled this session.** P11 `XxxTests`(N) claims (root `EditMismatchRecoveryTests`
  bumped to 11 → `file holds 10`), P20 verbatim-duplicate bullets (one guide bullet copied → red), and
  P17's two scan floors (`OCOREAI_FLOOR_AREA_GUIDES=99` → red, proving the floors are load-bearing rather
  than decorative). Net: **78 checks → 67; 62 block, 5 report** (P2 host-local refs, P16's comparator-diary
  coverage and its two hand-copied lists). One root bullet lost a duplicated pointer to `build-gate-reality.md`
  — § Read on demand already carries it — and the root re-pinned at **21,550 B** (was 21,582).
- **The measurement the gates were never about: a tool surface, priced over 39 tasks.** k=3 per arm on a
  real checkpoint (`gemma-4-e2b-it-4bit`, temp 0, auto-approval, one serve per run, release binary):
  6-tool arm **24/21/23** (mean 22.67, 58.1%), full-surface arm **16/15/15** (mean 15.33, 39.3%) —
  **-7.33 tasks, -18.8 pp**, McNemar exact two-sided **p < 0.0001** (25 tasks pass on the 4,510 B surface
  and fail on the 25,092 B one; 3 the other way). Losses concentrate in edit/multi-step work
  (`fix-syntax-error`, `fix-typo-variable`, `read-and-report`, `fix-boundary-comparison` all went 3/3 → 0/3);
  two exec tasks moved the other way (`exec-sum-column` 0/3 → 2/3), so this is not "fewer tools is better
  everywhere" — it is *what a turn is handed*.
- **Why k=3 and not the k=1 figures from 10-27(21).** One run of this board carries a 95% CI half-width of
  **±6 tasks (15.5 pp)**: identical configs spread 24/21/23, with six flaky tasks
  (`copy-with-suffix`, `edit-remove-line`, `exec-report-two-numbers`, `fix-off-by-one`, `fix-wrong-key`,
  `make-failing-test-pass`). An unpaired A/B therefore needs ≥9 tasks to clear 95%, and a paired one 6
  clean flips. Recorded in AGENTS.md § Testing Quality so the next improvement claim is stated against
  that floor — including the ~40 earlier rounds whose single-run scoreboard deltas were, by this
  measurement, unattributable.
- **A leak this harness had, closed.** `run.sh` installed a raw `trap … EXIT` that replaced `_lib.sh`'s
  `probe_atexit` chain, so a serve could outlive the run and hold the single-instance lock (the class
  `_lib.sh` documents). Fixed with `probe_atexit`; **six consecutive runs this round left no process
  behind** (`pgrep -fl 'ocoreai serve'` empty after both arms), which is the verification, not the diff.
- **What still has no gate, stated plainly.** The model-gated capability refusal (probe 12 §6: grammar +
  `tools[]` on one turn ⇒ 0/3) is unmeasured in code, and nothing binds an advertised-tool count to what
  the loaded checkpoint can actually honor. The next hour goes there and at tag `v0.1.0`, not at check #68.

**10-27(21) The turn's tool surface is priced, and the injected file's tool count turned out to be the wrong number** (P2 surface / symbols `tools-bytes-on-the-board`, `advertised-versus-declared-tools`)

- **What improved.** Every board row now carries what a turn paid for its tool declarations.
  `scripts/eval/run.sh` writes `# surface …` beside the cost figures, computed by `_eval.py surface` from
  the server's own `GET /v1/tools` output, and `OCOREAI_EVAL_TOOLS=all` resolves to every declaration the
  wire answers — so the goal's two boards (a 6-tool slice and the full surface) are now one command
  apart instead of a hand-copied 40-name list, which is the drift class `_eval.tool_specs` exists to
  refuse.
- **Same-session output, taken with nothing resident** (the scripted lane from 10-27(20) is what makes
  pricing the surface cost seconds instead of a checkpoint): `/v1/tools` advertises **40 tools at
  25,092 B**; the default 6-tool board is **4,510 B = 18%** of that; the heaviest declarations are
  `generate_video` 1,479 B, `edit_lines` 1,327 B, `inspect_ui` 1,234 B. Measured line:
  `tools=6 wire_bytes=4510 share_of_declared=18% declared=40/25092 edit_lines=1327 …`.
- **The claim this exposed, fixed where it was wrong.** AGENTS.md said "the board measures 6 of the 43
  registered tools". 43 is what the source *declares* (`core_tools<=43`, still true); `/v1/tools`
  advertises 40, because `get_plan` and `update_plan` are opt-in (`tools.update_plan.enabled` defaults
  false, aligned with codex #41744) and are honestly absent. A declaration count was standing in for a
  surface count in the file injected into every session, and the sentence now names both figures with
  their provenance. Paying for the correction left the root 244 B smaller than the cap it was pinned to
  (`make docs-budget`: 21,826 → 21,582).
- **Where the loop closes.** Probe 37 gained the only check that can bind that number — it runs against a
  live server, which `make docs-check` does not — so a tool landing or stopping to register now goes red
  on the runner instead of ageing inside the injected context. Red sample: AGENTS.md edited to "39"
  printed `quotes 39 advertised tools, /v1/tools answers 40 — fix the sentence … or the registration` and
  exited 1; restored, 20/20 green. The byte figure is gated by `_efficiency_selftest.py` group 6, whose
  expected value is the wire text written out by hand rather than recomputed from the code under test:
  switching to compact separators reported 65 B against a hand-counted 73 B and produced six defects.
  Group 7 pins the new line's position, because `_repeat_stats._read_run` reads the last `#` line as the
  score — the wrong order reads `surface tools=2 wire_bytes=68` as a score.
- **Truth after this.** The pricing half of the open item is settled; the comparison is not run. Whether
  40 declarations is right for a 4-bit checkpoint, and whether the app loop should keep sending the whole
  registry (`ChatViewModel.swift:1098`) now that its price prints, are owner calls with a number in hand —
  and nothing here claims 40 is wrong, only that it was unprinted and mislabelled.

**10-27(20) The gate stack was answering a question nobody asked, and the scripted engine is the answer** (P1 adoption + P3 verdict cost / symbols `gate-tier-split`, `scripted-engine-landed`, `docs-check-shadow-count`)

**A. Gate triage — the owner's charge: "so many gates is meaningless." Measured, that is half right.**

- **What improved.** `make docs-check` now has two tiers, and only the first one blocks. Blocking = a red
  means a user, a caller or a session is acting on something false (a served surface, a quoted number, a
  license term, a pointer that sends an agent to the wrong file): B1, B2, P1–P10b, P12, P13, P14's
  probe-index parity, P16's zero-coupling equality, P18, P19. Everything about the *tidiness of our own
  prose* is signal, printed as one line per check instead of a paragraph per finding: P11 exact
  `XxxTests`(N) counts, P14 table column counts + orphan docs, P15 line walls, P16 diary coverage and
  the two hand-copied lists, P17 guide shape, P20 duplicate bullets. Policy in `CONTRIBUTING.md`.
- **Why this is the honest reading and not a shrug.** 329 of 1415 commits went to docs/CI/gates against
  293 to product scopes, and the corpus reached ~171 KB whose defects were overwhelmingly
  self-referential. The cheapest check to write is a prose-shape check, which is exactly why they
  multiply; the cost is not the 3 s of runtime, it is the attention budget that stops going to task
  success — the board still reads 6 of the 43 tools we ship.
- **Deleted, not demoted.** `OCOREAI_CORPUS_MAX_BYTES` is gone: it capped volume in files no session must
  load, was already over, and therefore printed the same warning every run — noise that trains a reader
  to skim. The byte count is still reported, unjudged (`corpus files=20 bytes=171456`).
- **Red-samples (each demotion proven, not asserted).** A temp `docs/agent/` file printed
  `P14 ×1 … signals (1, not blocking)` with exit 0 while P7 blocked in the same run; a guide whose title
  lost its em dash printed `P17 ×1`, exit 0; `ThirdPartyNoticesTests`(17) printed `P11 ×1`, exit 0;
  `OCOREAI_AGENTS_MAX_ROOT=1000` still went red with B1's remedy. 19 call sites now route to `warn`.
- **A number in the gate's own output was wrong.** The report line read `claims=32/1 ok`: P10b's local
  `claims` shadowed P4's list, so the denominator came from the README task-count scan. Fixed by renaming
  the local; the line now reads `claims=32/32 ok`. A gate whose own report lies is the critique in
  miniature, and nobody had read that line.

**B. Rung 1 — the model left the contract claims. `Engine/ScriptedInference.swift`**

- **What improved.** `OCOREAI_SCRIPTED_ENGINE=/path/script.json` replaces the *model*, never the wire:
  reasoning, text and tool calls are replayed through the real handlers, parsers, SSE writer and dispatch
  path. A contract verdict that used to cost a Metal load and a checkpoint now costs seconds with zero
  models resident — measured: server up → 4 SSE frames → aggregated turn → shutdown in **2.76 s**, and
  probe 37's 19 assertions in ~4 s, inside the sandbox tier.
- **Same-session output.** `/v1/capabilities` → `engineBackend: scripted`, `tokenizerBackend: real`;
  `/health` → `engineSummary.loadedModels: 0`; streamed deltas
  `reasoning_content → tool_calls → content → finish_reason: tool_calls → [DONE]`; aggregated turn
  `finish_reason=tool_calls`, `tool_calls[0] = call_1 / read_file / {"path":"README.md"}`,
  `usage = 7 / 12 / 19`, and no `prompt_tokens_details` — a replay reuses no prefix, so it books no cache
  claim (invariant 2). `scripted-model` answers turns and is absent from `/v1/models`.
- **Two defects found by writing the harness, both fixed at the cause.** (1) `Script` claimed a
  one-segment script was legal while the synthesized `Decodable` ignored every Swift default — the
  documented minimal script was `HTTP 500 … Key 'reasoning' not found`; explicit `decodeIfPresent` now
  makes the defaults real. (2) The unknown-`finishReason` refusal named the bad value but not the file,
  so an operator running two scripts had to guess which to edit; every scripted refusal now names its
  path. `prewarmDefaultModel` also returns early under the switch — without that a "model-free" boot
  still loaded the configured default, which is the claim defeated by one line.
- **Where the loop closes.** `ScriptedEngineTests`(5) (order, exact declared counts, `cachedPromptTokens
  == nil`, broken script = named error not an empty turn, blank env = off); probe
  `37-scripted-engine-wire.sh` (19 assertions, model-free, CI-runnable) indexed in
  `scripts/probes/README.md`; `scripts/eval/run.sh` reads `engineBackend` from the live surface and
  refuses to score a replayed run — assertion 19 went red before that guard existed, which is the only
  reason to believe it; and the existing macos-26 headless-serve smoke step now runs probe 37 instead of
  a new leg opening.
- **Truth after this.** Rung 1's claim is *decidable*, not *decided*: probe 37 has never run on a runner,
  so the CI step is a candidate gate until its first pass. The chain is at 32,512 / 32,768 bytes — 99% of
  what the host will load for `Engine/` — so the next rule written there pays for itself or truncates its
  own tail; the two candidates that could pay are recorded in `docs/agent/open-items.md`.

**10-27(19) The intake machine exists: three issue forms, one of them for this project's own worst bug class** (P1 adoption / symbols `intake-forms-landed`, `over-claim-template`, `governance-covers-intake`)

- **What improved.** `.github/ISSUE_TEMPLATE/` went from 0 to 4 files: `bug_report.yml` (10 fields, 5
  required — the exact command, the raw response, `/v1/capabilities` + `/health` as pasted, model id with
  quantisation *and* lane, since MLX / CoreAI / MTP behave differently), `feature_request.yml` (problem →
  workaround → near-miss seam → the check that would prove it, which is the footprint ladder and the three
  questions asked of a stranger), and `capability_honesty.yml` — the class this repo treats as most
  serious: a surface claiming more than the engine measured. Rung 0's "a stranger installs and completes
  one task" needs a route back in; 16 of 20 comparator trees have one and we had none.
- **Nothing in them is invented.** Every field asks for something the wire really emits: `os`, `version`,
  `arch`, `capabilities[]` as `{name, available, note}` (`Router/ChatCompletionsRouter.swift:320`), plus
  `tokenizerBackend` (`:333`) and `screenStatus`; endpoint/field examples are real (`/v1/models/:model/kv-cache`
  · `prefixReuse`). Labels are restricted to the nine the repo actually carries (`api.github.com` read this
  session) — a form naming a missing label fails at submit time, which is the intake bug nobody sees.
  `config.yml` links only the five URLs measured 200 today, and `blank_issues_enabled: false` since the
  three forms cover the space; discussions stay unlinked (`has_discussions: false`).
- **Where the loop closes.** README.md and README.zh.md gained one line each pointing at the forms, in the
  Quick Start where a newcomer actually looks; `https://github.com/uingei/ocoreai/issues` is P19-verified
  (29 outbound, 29 verified, floor 27). No new gate: the existing ubuntu `governance` presence loop now
  lists the four files, so a deleted or unrenderable form is caught on the free runner rather than by a
  stranger's 404.
- **Rung 0 truth after this.** macos-26 authority legs green (7 legs, `Release DMG` skipped by design),
  intake 4 files — and still **0 tags**, so the DMG the README describes cannot exist yet. That is one
  owner command, not an engineering task.

**10-27(18) The gate pile was tried on its own evidence, and one check lost** (P0 discipline / symbols `gate-prices-a-readable-claim`, `corpus-cap-advisory`, `ledger-in-the-enforcer`)

- **The objection, as a measurement.** `make docs-check` holds 22 checks; counted against `CHANGELOG.md`,
  a minority have ever named a real defect — `P2` refused a glob cite, `P3` found 15 line cites off
  target, `P8` caught a stale upstream pin, `P10` found two endpoints missing from both READMEs in both
  languages, `P11` five drifted coverage counts, `P16` forced `pi` into both homes — while most of the
  rest police our own prose. And the pile has a shape worth naming: 169,691 B of gated documentation
  about this repo, against a scoreboard of 39 tasks measuring the product with 6 of 43 tools on it, and
  0 tags / 0 issue templates still outstanding. Gate count is not trust.
- **The rule that decides.** `CONTRIBUTING.md` now states where the line is: red prices a claim a reader
  or a caller acts on; everything else prints. It is deliberately two-sided — a gate that has never gone
  red on real work is decoration with an exit code.
- **What lost its teeth, and why.** P15's corpus byte cap and its 400-byte line wall became warnings:
  they price volume in files no session is forced to load, and the same day they blocked a correctness
  fix — moving 20 machine-only markers out of an injected guide took four edit rounds, one of them over a
  single byte. The axes that price attention stay red-able: B1 (the root every session loads) and B2
  (root + nested against the loader's 32 KiB, added one entry above).
- **The enforcer carried the audit trail it forbids elsewhere.** The cap demanded a ledger: 168 lines of
  dated round history inside `scripts/agents-md-contract.sh`, in the one repo where the root forbids dated
  notes in source comments. Cut (−158 lines net), keeping the two lines that are instructions rather than
  history — `docs/agent/build-gate-reality.md`'s block is load-bearing mechanism, and a comparator tree
  retires from BOTH homes. Verdicts stay in `CHANGELOG.md`, their only home.
- **Gate.** `make docs-check` green after the splice (22 checks, 32/32 claims re-run, root
  21,913/21,935, chain 31,176/32,768); red-ability re-sampled where it still matters — +1,700 B on
  `Sources/ocoreai/Engine/AGENTS.md` makes B2 name the byte count the model never receives.

**10-27(17) The chain budget was ours instead of the loader's, and an `Engine/` session was losing the tail of its guide** (P0 doc truth / symbols `chain-cap-self-referential`, `engine-guide-tail-truncated`, `board-count-stale-on-human-surface`)

- **What improved.** B2 priced the root plus *the largest file that happened to exist* — 36,396 B, a
  `docs/agent/` page the host never injects — so it could not go red. The loader that actually assembles
  this corpus spends ONE budget across the chain root→cwd: 32 KiB, `DEFAULT_PROJECT_DOC_MAX_BYTES` at
  codex `codex-rs/config/src/config_toml.rs:77`, decremented oldest-first at `agents_md.rs:92`
  (§ Upstream 3 cites; a comparator's source is not a runner input). Measured against the loader,
  `AGENTS.md` 21,935 + `Sources/ocoreai/Engine/AGENTS.md` 11,395 = 33,330, so a session whose cwd is
  `Engine/` was losing 562 B off the end of the guide: the close of the MTP tool-result publishing rule,
  the sampling-selection rule, then the `SessionPool` prefix-refusal booking rule — in that order. B2 now
  measures only what the loader concatenates (nested `AGENTS.md`), floors its own file count, and quotes
  the loader's 32,768 instead of a number derived from our own inventory.
- **What came out, not what was moved.** The guide's 20 machine-only anchor markers moved to
  `docs/agent/engine-line-cites.md` (`scripts/anchor-check.sh` and P3 both sweep `docs/agent/*.md`, so
  coverage is byte-for-byte the same), and a duplicated `SessionPool` bullet plus one meta paragraph
  left for good. Injected guide 11,395 → 9,263 B; chain 31,176/32,768 (1,592 B of headroom); root
  21,913/21,935; corpus 169,691/169,714. The root's budget rationale now states the loader's contract
  rather than a peer's file size, which is the sentence that had already rotted once.
- **A human-surface number had rotted, in both languages.** Both READMEs stated a 36-task scoreboard
  while `scripts/eval/tasks.json` holds 39 tasks with none disabled (measured 10-27): the mission's unit,
  mis-stated on the page a stranger reads, and the Chinese mirror had copied the stale figure, so
  agreement between the two files proved nothing. Corrected in both. P10b now diffs the stated count
  against `tasks.json` per language, floors its own hit count, and refuses quiet success when the board
  file cannot be read. `scripts/eval/README.md` stays out of its reach: those numbers are dated rows.
- **Gate.** `make docs-check`. Red-sampled, separately: +1,700 B appended to
  `Sources/ocoreai/Engine/AGENTS.md` makes B2 name the chain and the byte count that never reaches the
  model; reverting either README's count to 36 makes P10b name that file — so neither mirror passes by
  accident, and neither gate is a change detector.

**10-27(16) The references were read again, and three of our own claims did not survive it** (P0 doc truth / symbols `reference-round-16`, `root-size-claim-rotted`, `rung3-wrong-instrument`, `ungated-inference-regression`)

- **What improved.** `AGENTS.md` § Open gained three items, each with its instrument, from a pass over
  the reference trees: (1) a turn's tool surface is unpriced and nothing gates a caller-enableable
  capability against the model that must honor it — the wire is caller-scoped
  (`Sources/ocoreai/Tools/ToolRegistry.swift:135`), but the app's own loop sends the whole 43-tool
  registry every turn (`Sources/ocoreai/UI/ViewModels/ChatViewModel.swift:1098`; 7,361 B of declared
  description strings alone), while codex declares 13 specs and defers the rest behind `tool_search`
  (`codex-rs/core/src/tools/handlers/tool_search_spec.rs:19`), hermes-agent bridges 38 tool modules
  behind three reserved names (`tools/tool_search_catalog.py:15-21`), pi loads deferred matches into the
  conversation's `modelTools` (`packages/durable/src/tool-search/tool-search.ts:1-13`), and codex,
  opencode and pi each run tool calls as a *program* (code mode); (2) loop claims spend a live model
  where every agent tree here uses a fake or mock provider (codex 260 suite files on `wiremock`,
  hermes-agent `tests/fakes/providers/` replay JSONL, pi `test/suite/harness.ts` under "No real
  provider APIs, keys, or paid tokens", opencode `packages/http-recorder`); (3) the corpus's own bytes
  have no lift measurement even though § Documentation Map has demanded "an inference regression" for
  injected text since it was written — `SystemPromptContractTests` proves assembly, not help, so the
  demand was a claim pointed at the file that states it, and pi prices exactly that with paired
  `without_docs`/`with_docs` arms (`packages/evals/README.md:1-14`).
- **Same axis, model half.** codex refuses a configured mode the loaded model does not advertise and
  puts the remedy in the message (`core/src/session/code_mode_warning.rs:6-24`, where
  `used_fallback_model_metadata` counts as unknown rather than enabled). Our measured version of that
  failure is silent: probe 12 §6 — grammar alone 3/3, tools alone 3/3, both together 0/3. That is
  invariant 2 on the model axis, and it is now an open item with a named instrument instead of a hole.
- **Three of our own claims failed re-measurement.** The root file said "ours was the largest root
  (24,866 chars)" — `wc -c` on each tree's own `AGENTS.md` says mlx-serve 26,486, ours 22,059: second,
  not first, and the number had already drifted 2,807 B from the text that quoted it (codex ships no
  root file at all, 3,285 B of guides in total; pi 8,638; hermes-agent 11,952). The ladder's rung 3
  claimed "every top-five coding agent leads with a recording", measured by `grep -c '!\[' README.md` —
  the wrong instrument: those trees use HTML `<img>`, and read correctly codex has 1 image and 0
  recordings in an 81-line README (opencode 4, pi 4, hermes-agent 8, omlx 15), so the honest gap is
  intake, not media: `.github/ISSUE_TEMPLATE` 3–9 vs our 0, workflow files 14–57 vs our 1 (6 jobs),
  tags 20–1498 vs our 0. `docs/agent/open-items.md` also cited "ladder rung 6", which the ladder did
  not have; rung 6 now exists (ACP — goose `agent-client-protocol` 2.2.0, hermes-agent `acp_adapter`).
- **`pi` became a comparator, by the file's own rule.** It was cited in root prose ("pi's rule") while
  § Upstream 6 did not name it — the mirror of the defect P16 exists for ("use it or drop the name").
  Registered in both homes (root § 6: 15 → 16 trees; the refresh loop in
  `docs/agent/comparator-repos.md`), with a row for the four mechanisms above. Its row's line cites are
  host-tree cites, never runner inputs.
- **The ratchet bit, twice, and root paid its own way.** `B1` rejected the first draft at 23,044 B and
  `P15` the corpus at 166,104 B. Root finished at **22,059 (−4 net) while carrying three new §Open
  items**, paid by: the stale self-measurement; the whole § Docs Contract section (a *third* home for
  the docs-gate pointer — § Build / Test / Lint, the header and the routing row all cite
  `make docs-check` and the script); 7 lines out of § Read on demand whose targets were already cited
  elsewhere in the same file (counted by occurrence, not eyeballed); two §Open items merged into one
  Multimodal line; and twelve word-level merges (root: 45 lines in, 48 out). Corpus
  +4,591, re-pinned with the in/out ledger in `scripts/agents-md-contract.sh`; `make docs-budget`
  lowered the root cap 22063 → 21935, so neither cap has slack.
- **The round's own edit produced a new gate.** It duplicated the `tools[]` § Open bullet verbatim —
  root rule "one home per decision" says that is the defect, and P1-P19 let it through, so the rule was
  a claim. `P20` now fails any verbatim-duplicate top-level bullet in the injected corpus (fence-aware;
  paraphrase twins stay a review judgement, because pinning prose similarity is the change-detector test
  the same section refuses). Red-sampled before it was trusted: duplicating one bullet reports
  `AGENTS.md:136,137`; green after the dedupe, which is also why root landed 124 B smaller.
- **Gates that went red, and stayed honest.** `P2` refused a glob cite (`tools/*_tool.py`) and then
  refused two *declared-absent* files nothing cites any more (`RELEASE-NOTES-1.0.0.md`,
  `ZIG-PREVIEW.md` — out of `COMPARATOR_REFS`, because an unused declaration is an exemption); `P12`
  caught a `§ Compile-time gates` reference it could not resolve; `P16` forced pi into both hand-copied
  lists and reported zero-coupling 6/6 still true. `swift build` was not needed: this round touches no
  Swift, and `make docs-check` is the gate that owns it (green: 22059/22059, 169838/169838, 16 trees).
- **Owner calls this round opens.** Whether a scripted engine behind the real wire is allowed in a
  lower gate tier; whether the per-turn tool surface gets priced (and whether 43 is right for a 4-bit
  model — two boards, not taste); whether injected prose is measured or reviewed; and the intake
  rungs (tags, issue templates), which are one commit each and ungated today.

**10-27(15) The task-success board measures 6 of the 43 tools we ship, and a gate was counting prose** (P1 metric scope / symbols `board-measures-6-of-43`, `core-tools-counted-comments`)

- **What the references actually do, measured in their own trees.** codex declares **13** tool specs
  (`codex-rs/core/src/tools/handlers/*_spec.rs`); opencode declares **16**
  (`packages/core/src/tool/plugin/*.ts`); hermes-agent's root states the rule they both act on — "the
  core is a narrow waist; capability lives at the edges", because "every model tool is sent on every API
  call, so the bar for a new *core* tool is high". ocoreai registers **43** typed tool declarations.
- **The uncomfortable part is about our own instrument, not our surface.** `scripts/eval/run.sh` pins
  `OCOREAI_EVAL_TOOLS` to read_file / write_file / edit_file / edit_lines / search_files / exec_command —
  **6 of 43, 14% of the declared surface.** So every figure this project has quoted from the board (the
  pass count, ms per verified success, tokens per verified success) is a measurement of a 6-tool slice
  against a 4B model, not of what a user who declares the whole surface asks that model to choose
  between. The board does print its slice (`scoreboard 39 tasks · 6 tool(s) declared by the server`), so
  this is not a hidden number — it is a number nobody had to say out loud next to the score. Recorded as
  an open item with the instrument that closes it: the same 39 tasks and verifiers over the full declared
  surface, reported beside the 6-tool board. **Nothing here claims 43 is wrong** — it claims this board
  cannot answer that, and the owner call should read two boards, not taste.
- **A gate was counting prose, so its number was wrong by two.** `core_tools<=45` ran
  `git grep -h 'ToolEntry\.typed(' -- Sources/ocoreai/Tools | wc -l`, which also matched a doc comment in
  `ToolEntry.swift:67` and a reference in `BuiltInTools.swift:7`. Every other claim in the corpus strips
  comments first; this one did not, so the ceiling was 45 against 43 real declarations — two characters of
  phantom slack in a ceiling whose whole job is to be tight. The command now strips comments and the
  ceiling is 43, red-sampled: set to 42, `P4 … command returns 43`.
- **The gate's own unit was mislabelled, and it had already misled a round.** Every cap in
  `scripts/agents-md-contract.sh` is `wc -c` — **bytes** — while B1/B2, `docs-budget` and the budgets
  summary all said "chars". That is how 10-27(13) came to quote char counts (24866 → 22073) against byte
  caps. The messages now say bytes, the constant block names the unit, and the honest statement of the
  last round's effect in bytes is: root 24,866 → 22,073 → **22,063** bytes this round, still shrink-only.
- **Payment, per the ratchet.** Root 22,073 → 22,063 (re-pinned, zero slack): the open-item bullet that
  names the metric's scope paid for itself out of prose. Corpus 164,454 → 165,123 with the accounting next
  to the constant: in, the open item that indicts the metric; out, `docs/agent/docs-map.md`'s paragraph
  restating § Docs Contract (−370 B, a second home for one rule) and trims.
- **In flight, not green: the k=3 reliability band.** `scripts/eval/repeat.sh` at k=3 on
  `mlx-community/gemma-4-e2b-it-4bit`, artifacts in `~/ocoreai-eval/repeat-1027-1118-k3/` (outside the
  repo, so the tree stays clean). It will produce the noise band, the stable-pass/stable-fail/FLAKY split
  and the paired sign test that every past delta lacked. Run 1 reached 2/2 passes with
  `prompt=2069 cached=2032` — 98% of the prompt was prefix-cached — and 14.9 s of model time for those
  two tasks; the board verdict is **pending, not measured**, and is not claimed anywhere in this entry.
- **Verified this round:** `make docs-check` green (claims 32/32, links 28/28 verified, root and corpus
  caps zero-slack); `core_tools` red-sampled at 42; B1/B2/P15 red-sampled earlier the same day. No Swift
  touched, so no build claimed; the eval is a live run, its own evidence.

**10-27(14) Two of the twenty-nine links in the front door pointed at repos that do not exist** (P0 human surface honesty / symbols `dead-comparator-links`, `link-gate-false-green`)

- **The defect, reproduced before anything was written.** Applying the vllm/sglang practice (both run
  `lychee` in pre-commit) to our own docs: 32 URLs cited, 29 non-loopback, and 2 returned **404** —
  `github.com/omlx-ai/omlx` and `github.com/steipete/clawd`, cited in README.md **and** README.zh.md as
  the "production-grade reference" and the "agent-platform reference". A reader clicks them and lands
  nowhere. `api.github.com` (authoritative for existence, per § Upstream) gives the real trees:
  **jundot/omlx** and **openclaw/openclaw**. Both READMEs fixed in the same edit, and both re-probed:
  200.
- **Fresh measurement of the ladder, because "first on GitHub" needs a number.** openclaw 393,161 ·
  hermes-agent 257,428 · opencode (moved sst → **anomalyco**) 221,988 · ollama 184,905 · codex 131,034 ·
  vllm 95,633 · sglang 38,221 · **omlx 23,078** · coreai-models 2,220 · mlx-swift-lm 847 · **ocoreai 1**.
  Two readings that matter: the two largest *agent* repos are personal-agent platforms, not coding
  agents, so the coding-agent bar is opencode/codex; and the closest sibling — local MLX serving, one
  binary, same domain — sits at 23k **with a Homebrew tap, a DMG and auto-update**, while this repo has
  0 tags and 0 releases. That is the largest controllable gap on the visibility axis, and it is still an
  owner call (notarization is money).
- **The gate caught nothing at first, because the gate was the bug.** The probe ran URLs 8-way parallel
  and then 3-way; github.com answered 10 of 28, then 13 of 28 — parallelism here **manufactures** the
  failures a link gate is supposed to detect. Worse, the first version reported transport errors
  without failing them, so the throttled run printed **green while both real 404s sat in its own output**
  as "no response". That is the exact failure invariant 1 names, self-inflicted.
- **What is red now, and where.** Serial by default (`OCOREAI_LINK_PARALLEL`, measured setting 1): any
  final 4xx is red, and **an unanswered majority is red too** — "could not ask is not a pass", the rule
  `scripts/ci-status.sh` already applies to CI. `-L` is followed, so a moved repo stays green (opencode's
  move is a 301 the reader never sees). A handful of stragglers in a healthy run is reported, not failed:
  `huggingface.co` refuses curl from this host and loads in a browser.
- **The blocking half is offline, on purpose.** Egress from this host is flaky, so a CI network gate
  would be muted inside a week — the gitleaks pattern the owner already had deleted. `make links` stays
  opt-in (it needs egress, ~85 s serial) and CI enforces P19 in `make docs-check`: every outbound URL a
  doc cites must appear in a VERIFIED_URLS table with the date a human confirmed it, an entry nothing
  cites is also red (both directions, the COMPARATOR_REFS shape), the scan floors itself at 27, and
  entries marked `unverified` are capped at 2 so the exception cannot become the rule. Red-sampled all
  three ways: a cited unverified URL, and `OCOREAI_URL_FLOOR=40`.
- **Stated limits.** The date in the table is a claim about the day it was written, not a live check: a
  link that dies next week is caught by `make links`, not by CI — the deliberate trade for a gate that
  runs with no network. `huggingface.co` is recorded as unverified because no machine reachable here can
  probe it. `swift build` was not re-run: this commit touches no Swift.

**10-27(13) The injected file was the largest in the field, and the caps protecting it could not go red** (P2 doc discipline / symbols `context-budget-could-not-bite`, `doc-size-is-not-rank`)

- **Measured all 21 comparator trees before touching anything, and the number was uncomfortable:** root
  `AGENTS.md` sizes — mlx-swift-lm 3490, goose 6212, vllm 6358, pi 8638, hermes-agent 11952, opencode
  14544, deepseek-harness 19113, openclaw 19168, **ocoreai 24866**. Ours was the largest of every tree in
  the set, 1.7× opencode and 2.1× hermes-agent, and 51% of our own corpus (hermes 7.5%, vllm 13%, opencode
  18%). `coreai-models` (Apple's own reference) and `omlx` (the closest sibling product) ship **zero**
  `AGENTS.md`; codex ships 2 area guides and no root, 3285 chars total.
- **The size question is not the rank question, and the data says so.** codex sits at ~131k stars on 3.3k
  chars of agent instructions; opencode at ~221.9k on 81k; mlx-serve carries 121855 chars of root guide.
  Across this set instruction volume has no visible relation to GitHub rank, so shrinking the file is a
  cost-and-clarity win for the humans and agents working here, not a route to first place — and it is
  written down that way so nobody "optimises" the wrong axis again.
- **What actually went wrong was duplication with no home.** `cachedPromptTokenCount` and `prefixReuse`
  appeared in the root § Architecture *and* in `Sources/ocoreai/Engine/AGENTS.md` — two homes for one
  decision, one of them paid by every session including those editing UI. The two inference lanes
  (MLX via `ChatSession`, MTP around it, `ToolResultPublisher`, `KVCacheRuntime`, `CompositeSampler`) are
  engine facts and now live only in the engine guide, which loads inside that subtree. § Open's long form
  and the doc-audience table moved to `docs/agent/open-items.md` / `docs/agent/docs-map.md`; the root keeps
  the address (area + instrument + whose call), because a root rule is ≤3 lines by this file's own rule.
- **The caps were decoration, and that is the part invariant 1 forbids.** `OCOREAI_AGENTS_MAX_ROOT` was
  30388 against a 24866-char file (8315 of slack) and `OCOREAI_AGENTS_MAX_CHAIN` was 78000 against a
  worst-case root-to-doc chain of 36396 (41604 of slack): a limit that cannot be exceeded is not a limit,
  while the script's own comment already read "a cap with slack in it is a cap nobody enforces". All four
  are now pinned to measured — root 22073, chain 36396, per-file 14323, corpus 164454 — and each was
  red-sampled by lowering it and reading the violation (B1 at 22000, B2 at 36000, P15 at 164000).
- **Nothing was lost, and that was checked, not assumed.** Every symbol the old root carried was extracted
  and re-grepped across the new corpus: 8 suites, 8 `claim:` ids, 10 `make` targets, 5 scripts, 10
  `docs/agent/*.md`, 4 probe numbers — zero lost. One candidate loss (`probe 04`) was this checker's regex
  missing the plural `probes 04, 26`, not a real one. `make docs-check` green.
- **Debt was NOT repaid where the ledger pointed.** The script names
  `docs/agent/build-gate-reality.md` as owing bytes, and it is the most dated-looking file in the corpus —
  reading it first found the opposite of forensics: the metallib-refusal mechanism, the lease-across-network
  122 s→370 s measurement, the `PlatformPremise` shape that works. Cutting it would have traded
  load-bearing knowledge for a greener number, so the corpus moved +2699 B instead, visibly, with this
  accounting next to the constant.
- **One fiction removed while here:** `docs/agent/docs-map.md` inherited a `REVIEW.md` row from the moved
  table; `REVIEW.md` does not exist in this tree, so the row is gone rather than hedged.
- **Stated limit.** The root is still 22073 chars — above opencode's 14544 and hermes-agent's gated 12k.
  The remaining bulk is § Code Conventions (~3.9k), the command block (~1k) and the routing table (~1.3k),
  which have no second home: dropping them would stop the root being the rulebook it exists to be. Reaching
  the 12k band is therefore a product decision about what a session must be told unprompted, not another
  editing pass, so it is left as the owner's call rather than achieved by deleting rules.

**10-27(12) Two more teachers, one rule that a machine can actually decide** (P2 doc discipline / symbols `core-tools-ceiling`, `rule-prose-has-no-gate`)

- **omlx is the closest sibling and it solved the thing this repo has not.** Its repo carries `Formula/omlx.rb`: `brew tap jundot/omlx <repo-url>` then `brew install jundot/omlx/omlx`, formula built from a tag tarball with `depends_on arch: :arm64` and a macOS floor declared *in the formula*, plus options (`--with-custom-kernel`), a pinned `resource` for a conflicting transitive dep, and `skip_clean "libexec" if MacOS.version >= "27"` because macOS 27's `strip` corrupts Mach-O offsets (llvm/llvm-project#203678) — the same macOS-27 toolchain hazard this repo keeps meeting. Its README adds a DMG with in-app auto-update and a `~/.omlx/bin/omlx` CLI shim. Against that ladder this repo ships nothing: 0 tags, 0 releases, so README's own install sentence points at an empty page.
- **hermes-agent proves the injected-context budget by publishing its arithmetic:** `python scripts/check` caps the root hub at 12k chars and every root-to-area chain at 30k, "so it loads whole on 128k+ models: long form goes in the guide". This repo's numbers are root 24.8k with a 30.4k budget and a 78k chain cap — 2.6× hermes' chain. That gap is the next real lever on task success (injected bytes are paid every turn), and it is named here rather than quietly kept.
- **Two rules copied from named trees, then the question that matters: what goes red?** The owner asked exactly that, and the honest answer is: the staged-paths rule (pi) has **no gate** — nothing in `make round-gates` or CI reads rule prose, and deciding "did this commit sweep in another session's work" post hoc is not decidable; pinning the sentence would be the change-detector test the other rule refuses. So it stays a review rule, labelled as one. Its neighbour, hermes' rejection list, has one decidable clause — no new core tool where a file tool or skill already does it — and that one is now gated: `core_tools<=45` re-counts `ToolEntry.typed` declarations, `docs-check` reproduces it (32/32 claims), and it was red-sampled by editing the ceiling to 44 → `P4 … core_tools <= 44: command returns 45`. A 46th tool now requires someone to raise a number on purpose.
- **Paid in the same edit, per the ratchet:** 1635 B in, 1058 B out (the policy bullet that restated the three questions' second question, the verification-layers restatement, the HIG item's GUI's-judge clause), net +577 → cap re-pinned at 161755 with zero slack and the no-gate situation written into the ledger for the next editor instead of being dressed up as enforcement.
- **Also verified this round:** the hook layer passed its first real execution (`Governance Check` success at `9de9879`: pinned codespell + `pre-commit run --all-files`), and removing `needs: [governance]` restored Static Audit, which `b2a2fa0` had skipped. `swift build` exits 0 and pinned swift-format 603.0.0 reports zero reformat after the codespell-comment edits.

**10-27(11) The hook layer CI was meant to verify went red on the changelog itself** (P2 gate honesty / symbols `precommit-red-on-changelog`, `text-gate-could-suppress-code-gates`)

- **The next push answered the open question, and the answer was red.** Governance Check failed with `failed step: pre-commit hooks`; the spell step passed clean, so the failure was the framework run, not the pin. The finding was `CHANGELOG.md` — which contains real misspellings *on purpose*: it quotes `aligment`, `ture` and `egistry` as evidence of a planted red sample and of two test fixtures. So the diary and the config file are now in `.codespellrc` skip (codex skips its own `.codespellrc` for the same reason: a rule that explains itself by quoting a typo must not be tripped by its own explanation), and the config comment no longer spells the words out either. Verified on the exact input the hook receives: codespell over **every tracked file** reports 0 findings.
- **A text gate could suppress the code gates, and did.** `audit` had `needs: [governance]`, so one changelog typo left Static Audit `skipped` — the pattern, format, lockfile and toolchain checks never ran for that push. That is the same coupling this file already condemned ("an authority that a formatter install can cancel is not an authority"), so the dependency is gone with the incident recorded where the job reads it.
- **Also fixed while here:** `Sources/lib/*` does not match `./Sources/lib/CXGrammar/include/dlpack/dlpack.h` when paths arrive with a `./` prefix, so the vendored dlpack header is now matched by `*dlpack*` too — a latent local/CI divergence removed rather than discovered later.
- **Limit, stated.** `pre-commit run --all-files` still cannot execute on this host (git-over-HTTPS to github.com times out on fetch, with and without forcing HTTP/1.1), so the framework's own execution is verified only by CI; what was verified locally is the substance of every hook in the config — codespell over the full tracked set (0), and manual equivalents for JSON/YAML validity, broken symlinks, files over 2 MB, tracked PEM blocks and conflict markers (all clean) — plus `pre-commit validate-config` for the schema.

**10-27(10) Six projects were asked what they run; four of them run pre-commit and this repo ran none** (P2 lock discipline / symbols `lock-rung-cheapest-first`, `hooks-precommit-never-installed`, `spell-gate-323-to-0`)

- **What the teachers actually run, measured not remembered.** `coreai-models`: 1 workflow, 3 jobs (ruff lint, `swift format lint --strict`, python-test). `mlx-swift-lm`: lint on **ubuntu-22.04** with a "Cache swift-format build" step, then macOS build/test + an xcode27 integration build; `CLAUDE.md` is a symlink to `AGENTS.md`; 3.5 KB of injected context against this repo's 24.5 KB. `codex`: 28 workflows with an explicit `blocking-ci.yml` (blocking vs informational is *stated*, not implied) and concurrency that cancels a PR/branch run but never main. `opencode`: check/unit/build/e2e plus an `affected` job. `vllm` (95.6k stars) and `sglang` (38.2k): 35 and 38 pre-commit hooks, including `check-agent-files`, `check-test-tethering`, `detect-private-key`, `lychee`, `codespell`/`typos`. Context for the ambition: opencode 221.9k, codex 131k, vllm 95.6k, sglang 38.2k, coreai-models 2.2k, mlx-swift-lm 847, ocoreai 1.
- **Four practices adopted, each copied from a named tree.** `concurrency` with codex's semantics (a PR/branch group cancels its stale run; main appends its run id so main is never cancelled, because main's history is the trail) — previously a PR push stacked a second full arm64 run behind the first. `CLAUDE.md` → `AGENTS.md` symlink as mlx-swift-lm ships, so agents that look for `CLAUDE.md` load the context instead of nothing. `.pre-commit-config.yaml`, the layer 4 of the 6 ship and this repo did not: `detect-private-key` + the common integrity hooks + `codespell`, membership ruled by "needs nothing but the checkout, and has bitten" — which is also why swift-format and the docs contract stay in `make`, where the pinned toolchain is resolved. And the spell gate in `scripts/spell-check.sh`, run on **ubuntu** rather than the 715 s arm64 audit leg.
- **`hooks/pre-commit` was a P0 check that has never once run.** `core.hooksPath` is unset in this clone and no file, doc or CI step cites that directory, so its manifest gate was unreachable; and the check it leads with compares `Package.swift` against `Package@swift-6.3.swift` — a file this repo does not have (`git ls-files | grep -c 'Package@'` = 0), so even installed it would have been vacuous. Its `swift build | tee | grep -q error:` also tests grep, not the compiler's exit status. Deleted with `scripts/build-metallib.sh` (zero callers; `make metallib` calls `setup-metallib.sh`). That is the third instrument this week found dead by inspection rather than by failure.
- **The spell gate did the work, and every residue got a verdict instead of an ignore-everything.** 323 findings on the first run → 41 after the vocabulary (ANE ×103 is Apple Neural Engine, `inout` ×67 is a Swift keyword, `numer` is `mach_timebase_info_data_t`'s own field, `datas`/`checkin` are this repo's names) → 0 by deciding each line: 14 are the mechanism itself (`ClaimVsAudit`'s prefix stems `creat`/`writ`/`sav`; the streaming fragments `"</thi"`, `"eather\",\"arguments\":"`, `"hel"`, `"argumen`; `SessionPoolPolicyTests` asserts `"ture"` is *not* a truthy value; the eval fixtures rename `thme`→`theme`) and take a line-level `codespell:ignore`; one was a real abbreviation and `ot` became `tokens`. Zero files were rewritten to please the tool.
- **Both directions taken, including on the gate itself.** Green over 736 tracked files + root docs; red on a planted typo (`README.md:246: aligment ==> alignment`, exit 1); red when codespell is absent (it refuses to skip); red when the reported version ≠ the pin. The gate then caught its own round twice: `makefile-parse-check` failed target `hooks` because a directory named `hooks/` shadows that target name (make answered "is up to date", the parse gate read the backticks), and the byte ratchet rejected my own two arithmetic errors — so AGENTS.md paid for its new rule by deleting three duplicate homes (a third `PresentationEcho` citation, the § Docs Contract restatement of the script's own header, crash-safety stated twice) and lands at 161177/161178.
- **Stated limits.** `.pre-commit-config.yaml` is schema-validated (`pre-commit validate-config`) and CI-queued, but its first real execution is the next push: `pre-commit run --all-files` could not clone its hook repos here (github.com fetch timeouts, same flake that needed retries for the gitleaks download) — said rather than glossed. codespell 2.4.3 is now a requirement of `make round-gates`; it fails loudly rather than silently skipping when missing, and `python3 -m pip install --user codespell==2.4.3` is the whole install. Static Audit still blocks nothing on purpose (`CHANGELOG.md`, `an-authority-that-a-formatter-install-can-cancel`), so the ubuntu job added here is informational too; the blocking contract is the owner call named in § Open of `AGENTS.md`.

**10-27(9) The secret gate had never been green, and the project it came from does not exist** (P2 gate honesty / symbols `secret-gate-never-green`, `phantom-provenance-zeroclaw`, `pr-diff-fed-to-source`)

- **Read from a reproduced run, not inferred.** With gitleaks 8.30.1 (downloaded, `shasum -c` OK, arm64 — the job's own platform) running the job's own command over the tracked tree, `detect --source . --no-git` exits **1 in 0.6 s** with exactly one finding: `scripts/eval/_verifier_selftest.py:136`, rule `generic-api-key`, the fabricated `sk-live-…` answer whose entire purpose is to prove the eval verifier refuses an invented secret. The old `.gitleaks.toml` allowed `Tests/` only, and its `regexTargets` key is not a v8 key at all — measured, not assumed: the config clearly loaded (the `Tests/` fixtures stayed out of the report) while the unknown key was ignored **silently**, so the documentation-placeholder rule it advertises has never once applied. My first move was to repair that config to a valid schema; the measurement below is why I did not ship the repair.
- **Provenance audited against references, and it fails.** 0 of the 20 trees in `~/references` run a secret scanner in CI and none ships a config (openclaw 120 workflows, sglang 123, goose 39, codex 28 — none). The CI comment credited `references/zeroclaw/.githooks/pre-commit + gitleaks.toml` and the hook script credited "zeroclaw and eliza": none of those exist in references or in this repo’s history. Worse, the recipe `CONTRIBUTING.md` told contributors to run set `core.hooksPath .github/hooks`, and `.github/hooks` has never existed — an opt-in pre-commit scan that installs no hook.
- **Where the job’s minutes went.** `swift package resolve` runs four steps earlier, so `--no-git` over `.` walked `.build`: 5.1 GB of other projects’ fixtures on this host, and the same command had not finished here after 3.5 min — which is what a 15-minute cancellation at `65836b7` looks like from the outside. And the PR-context branch ran `gitleaks detect --source "$(git diff origin/BASE)"`: a diff handed to `--source`, a **path**, so a PR was never scanned while the step printed its clean line. Net delivered: zero catches, one permanently red check.
- **Deleted rather than fortified.** Out: both CI steps, `.gitleaks.toml`, `.github/pre-commit-gitleaks.sh`, the `REVIEW.md` governance row that ran `ls .gitleaks.toml`. `README.md` and `README.zh.md` drop the secret-scan claim from the audit-leg sentence (both faces, mirror kept faithful). `CONTRIBUTING.md` now spends 178 bytes where it spent 179 — corpus **161177/161178**, so the edit paid for itself — pointing at GitHub secret scanning + push protection, which costs nothing on a public repo, carries maintained signatures, and blocks at push time instead of after the fact. Owner action, not a gate: enable both under Settings → Code security.
- **The unreadable red is closed for the whole job.** The two steps still able to die with a bare `exit 1` now name themselves before anything can fail inside them (`set -E` + `trap … ERR` in the pinned swift-format step, `|| ::error::` on `swift package resolve`). All nine run-steps were extracted from the YAML and re-parsed with `bash -n` (9/9 OK), `ruby -ryaml` parses 10 audit steps, and `make round-gates` is green. No Swift changed, so no build claim is made.
- **Stated limits.** Annotations cannot prove gitleaks was the *only* red — step order plus a reproduced exit 1 is what makes it the cause, not a log line, and the next run says so in labels instead of silence. Nothing here goes red if someone re-adds a scanner; that is deliberately the owner’s call, and the reason now sits where it would be read. `scripts/drift-monitor.sh` left with it: it hard-coded `$HOME/projects/ocoreai` (this repo is `$HOME/ocoreai`), had zero callers in the Makefile, CI, docs or tests, and is superseded by `upstream-drift.sh` (`make drift`).

**10-27(8) R1 is red on this host and there is no SDK to make it green with** (P1 delivery-shape honesty / symbols `no-coreai-free-sdk-on-host`, `unlabelled-step-undiagnosable-red`, `step-carries-its-own-diagnosis`)

- **`bash scripts/toolchain-contract.sh check --probe-metal` exits 1 here**: the default SDK is **27.0 and ships `CoreAI.framework`**, so `canImport(CoreAI)` is true and the macOS-27-only blocks compile into whatever `swift build -c release` produces. Inventory taken directly, not inferred: `MacOSX.sdk`, `MacOSX27.0.sdk`, `MacOSX27.sdk` — **all three CoreAI=yes**, so this host has no CoreAI-free SDK at all and cannot produce the macOS-26 delivery shape by any pin. Consequence stated plainly: every `swift build -c release` run reported in this session is the **macOS-27 route**, and `make round-gates`/`make push-ready` stayed green because neither runs the toolchain contract — R1 lives only in CI's audit job and in a direct call.
- **The CI red that could not be read**: Static Audit at `9466754` finished (the 25-minute ceiling did its job) and failed leaving exactly one annotation, `Process completed with exit code 1`. Anchors passed (no `failed step:` annotation) and the next step — Toolchain contract — was one of the few with **no `::error::failed step:` wrapper**, so an SDK-shape red and a Metal-probe red were indistinguishable from outside, and the log needs a token this repo does not have. So the step now carries its own diagnosis: it names itself and publishes the SDK inventory (`::error::sdk MacOSX27.0.sdk CoreAI=yes` …), which is precisely the fact an owner needs to choose between pinning `SDKROOT` and declaring the macOS-27 route. That branch was executed for real, not assumed, because R1 is red here. YAML re-parsed (`ruby -ryaml`; 12 audit steps).
- **Inference, labelled as such**: that `9466754`'s red was this step is a strong inference (step order + the only unlabelled step after anchors + a host whose SDK ships CoreAI), **not** a read verdict — no token, no log. If the macos-26 image has likewise moved to SDK 27, then the two `Build & Test` legs that passed are compiling the macOS-27 shape as well, and "CI macos-26 is the delivery-shape authority" would need re-reading against what those legs actually pinned (nothing: `SDKROOT` appears zero times in the workflow). The next run answers it in annotations rather than in silence.
- **Not fixed here, because it is an owner call with a product consequence**: pin `SDKROOT` to a 26.x SDK (needs one installed on the runner) versus declare `OCOREAI_TARGET_SDK=macos27` deliberately. It decides whether the shipped binary's compiled shape matches the README's floor claims, so it is put to the owner rather than decided in a gate-fix commit.

**10-27(7) The refusal named the route, and the task that had never passed passed** (P1 real-task verification / symbols `rm-route-delivered-the-delete`, `cost-per-verified-success-5429`, `noise-band-stays-stated`)

- **The whole point of `EditMismatchRecoveryTests` was to buy one log line, and here it is.** On the task that had failed 2/2 reproducibly (`delete-only-what-was-asked`), the retained `server.log` shows the refusal ordering the retry **and naming the removal route** — `Deleting the file itself is not a file tool: use exec_command with \`rm logs/stale.log\`` — followed immediately by `Tool call: exec_command — success`, with the verifier accepting the product (3 462 ms). Root cause → smallest fix → observed mechanism, in one artefact, no inference in the chain.
- **Board moved 21/39 → 25/39 at the same conditions** (task-file hash `b709e8aab69d`, tool hash `d9b1028a196a`, temperature 0, 6 tools): `ms_per_success` 8126 → **5429**, `tokens_per_success` 4224 → **3560**, median 2191 → 2144, p95 11346 → 8362, `usage_parsed=39/39`. Row diff: gained `delete-only-what-was-asked`, `edit-remove-line`, `edit-rename-key-keep-value`, `fix-wrong-key`; **lost none**.
- **Attribution kept inside its evidence.** Two of the four gains are removal-shaped and the delete one is proven by mechanism above. The other two stay **unattributed**: at k=1 the noise band is ±4 (adjacent k=6 windows moved 7/48 bands), so a four-task delta is not yet a claim about the aggregate, and this entry says so rather than banking it. k=3 over the frozen set is the run that would settle it, and it has not been run.
- **Where the numbers live**: `scripts/eval/README.md` gained a board ledger (the run table above, with the noise caveat beside the delta, not in a footnote) — deliberately outside the docs corpus, because a re-derivable figure has one home and that home is the scoreboard's own file.

**10-27(6) The documented fix for the style gate had never once run — and the audit job that says so has no minutes to say it in** (P1 gate determinism / symbols `make-format-never-parsed`, `rm-named-only-for-deletion-intent`, `audit-job-at-its-ceiling`)

- **`make format` could not parse.** `make format-check` names it as the way to accept a reformat, and it died before the formatter started: `unexpected EOF while looking for matching "`. One apostrophe: `CI's` sat inside a **single-quoted** awk program, so the shell closed the quote early and bash met an unbalanced string — and because make hands the *whole* recipe to one shell, the fact that the branch is only taken off-pin bought nothing. Reproduced by expansion (`make -n format` → `bash -n`: same EOF error), fixed by rewording to `the pinned $(SF_PIN) ruleset decides style`, and confirmed after the fix: `Done (603.0.0)`, exit 0 — the first run this target ever completed.
- **The gate for it, floored against its own scan**: `scripts/makefile-parse-check.sh` expands every recipe with `make -n` (nothing executes) and lets bash parse it. Green: `28 target recipe(s) parse (floor 20)`. Red: a scratch copy with the apostrophe restored prints `FAIL target 'format'` plus the bash error and exits 1. The floor earned its place immediately — the first cut matched only 3 targets (the extraction demanded whitespace after the colon) and correctly refused to pass: `only 3 target(s) parsed (floor 20) — a scan that stopped matching passes vacuously`. Chained into `make audit`; cost measured at 20 s on 28 targets, so it is affordable inside the job it protects.
- **A refusal may not offer a destructive route it was not asked for.** `delete-only-what-was-asked` failed because an `edit_file` carrying **deletion** intent (empty `newString`, which the tool's own doc-comment documents as "may be empty to delete") met a refusal ordering a retry that can never delete — `edit_file` empties files, **no file tool deletes one** — so the turn ended asking the user for the line quoted in the same message. The refusal now names the route that exists (`exec_command` + `rm <path>`), gated on `newString.isEmpty` so only the caller's own argument ever surfaces it: in an ordinary mismatch an `rm` suggestion would nudge a typo into an unrecoverable delete. Gate `EditMismatchRecoveryTests`, both directions taken — deletion intent gets `rm stale.log` (10/10 green), and with the condition planted as `true` the safety assertion fails (`✘ Test "a whole-file quote orders the retry…" failed with 1 issue`).
- **The red sample was a dud first, and that is the finding about my own verification.** The first plant targeted `let removal = newString.isEmpty`, but `make format` had rewrapped that line a step earlier, so the replace matched nothing, the script asserted nothing, and the suite passed **10/10 on unmodified source** — a green that proved exactly nothing. Restated with the premise asserted (the condition line must exist, then must read `true`), the same run went red. This is invariant 1 pointed at the harness: a red sample that does not check its own premise is a claim.
- **Static Audit did not fail at `65836b7`, it was cancelled**: annotation `The job has exceeded the maximum execution time of 15m0s`, with **no** step-failure annotation — so the anchor fix is verified locally (`drift=0`, 72 anchors) and **not yet CI-verified**, which is said here rather than smoothed. The other five legs at that commit passed (`Build & Test` macos-26 **and** xcode-27, iOS compile, App Store trait, Governance). The job builds pinned swift-format (~4 min measured on host) and runs `swift package resolve` — the resolve must stay, since upstream cites resolve only at the pin — so it sits at its ceiling while arm64 capacity warnings make the margin negative. Ceiling raised 15 → 25 with that reasoning and the next lever named (cache `~/.cache/org.swift.swiftpm`, not `.build`); per-step attribution needs a token this repo does not have, so this is headroom, not a fix.
- **Two root rules, each naming its gate**: *a gate you did not run is not green* gains its other half — **a stated fix that cannot run is no exit** — and destructive routes are offered only where the caller asked (gate: `EditMismatchRecoveryTests`, 10 tests, both directions taken). Paid inside the same edit where possible (−106 B the §Identity pointer restating the routing table 200 lines below it in the same file, −60 B the §Docs Contract restatement of what the script header owns), then +174 raised to 161178 — cap re-pinned with zero slack — gross and net both in the ledger. Scripts are not corpus, so the new gate cost the docs nothing.

**10-27(5) A pure reformat moved 19 line-cites and every local gate stayed green** (P1 gate determinism / symbols `cites-moved-by-a-pure-reflow`, `push-ready-is-the-gate-path`, `dead-code-beats-hardening`, `no-file-delete-primitive`)

- **The gate that exists off the path taken is not a gate.** CI's Static Audit at `5442d03` passed docs, lockfile and format, then died at `failed step: line-cite anchors`; locally `scripts/anchor-check.sh` reproduced **drift=19** in three files (`EngineInference.swift`, `MLXBridge.swift`, `DegenerateMarginProbe.swift`), each cite off by one line because the pinned-formatter reflow shifted them. `make docs-check` had been green before that push, and `make round-gates` — which *does* chain `anchor-check`, with a comment narrating this exact failure — is not the target anyone runs before pushing. Fix is on the existing rung: `make push-ready`, the target whose whole job is "is this tree ready", now runs `anchor-check` and fails the push. `make push-ready` verified; all **72 anchors point where they claim** (local 30, upstream 42, `drift=0`).
- **All 19 cites repointed to the verified line, not the nearest guess**: 9 in `Package.swift`, 13 in `Sources/ocoreai/Engine/AGENTS.md` (prose cites included, not just markers); 17 moved +1, `asArray(Int.self)` +2 and the probe's `asArray(Int32.self)` +3. Byte-identical digit counts inside the corpus, so the docs ratchet paid nothing for correctness.
- **Dead code beats hardening**: five `ConfigSystem.update*()` mutators each ended in `try? await save()`, i.e. a config write whose failure was discarded while the caller kept showing the new value. Hardening them would have been the obvious patch, and it would have built a surface for a caller that does not exist: **all five are unreferenced** — each name's only occurrence in the repo is its own definition (`git grep -n 'updateServer'` → 1 hit, the `func`). Both directions checked: `ConfigSystem` itself is live (`App.swift:372`), so the loader/saver/watcher stay and 26 lines of swallowed-write mutators go. Same for the unreferenced private `milliseconds(since:)` in `CoreAIPipelinedEngine.swift`. `swift build -c release` exit 0 (199 s).
- **Defensive code, measured instead of felt** (comments stripped, non-test Swift, per KLOC): ocoreai **guard 20.5** sits mid-pack against six comparators — `mlx-serve` 27.9, `openclaw` 39.7, `coreai-models` 23.5, `MTPLX` 19.9, Apple's `mlx-swift-lm` 15.2 — and its `??` density (15.2) is the *lowest* of the set, so "validate once at the boundary" is not a rule we are failing. The outlier is the *reason* surviving a failure: **catch 5.4/KLOC is the highest of all seven** (upstream Apple: 0.8) and `try?` 8.0/KLOC ties for highest. Of 22 sampled no-cause catches, nearly all are legitimate (cancellation, cache-invalidation-then-rethrow, collected failures); the durable finding is 160 line-initial `try?` sites that drop the result. Counting lesson: a naive `try?` substring scan reads `MetricsRegistry?` as a hit (554 vs **528** real), and BSD ERE has no `\b` or `\s`, so `\bConfigSystem\b` and `^\s*try\?` both answer 0 with confidence.
- **The eval log now outlives the run, and immediately root-caused the open task**: `scripts/eval/run.sh` keeps `$PROBE_LOG` as `server.log` in the artefact dir (13.8 KB retained on the run that proves it), which turns `delete-only-what-was-asked` from "the tool execution failed" into a quotable chain: the model used `edit_file` to delete, `edit_file` refused and **quoted the file's whole content verbatim while ordering "Retry this call now ... Do not answer the user before that retry"**, and the answer still went out: "Please provide the content of `logs/stale.log`" — the text it had been handed in that very message. `verify_rc 1`, 8 449 ms, 2 016/2 197 prompt tokens cached. The deeper cause is a capability gap, not a phrasing slip: **`delete_file` is not a registered tool** — the name exists only inside `ToolRegistry.swift:309`'s destructive blacklist, so the blacklist guards a phantom while the agent has no delete primitive except `exec_command rm`. Registering it is new agent-facing surface (schema + description are function-calling contracts, so it needs a live-model test), so it is reported for the owner's call with its three quantities rather than added silently.
- **Goal and corpus**: `docs/agent/long-horizon-goal.md` now states the product proposition the owner set — **correctness / reliability / efficiency / safety**, scored by the fixed task set and its verifiers, never by the model's self-report, with acceptance = task success rate, outcome correctness, execution reliability and cost per successful task, explicitly *not* LOC, commits, model count or architectural complexity. Its own stale numbers went first: the file quoted **52 tasks where `tasks.json` holds 39**, so B′/C now name the quantity and point at `scripts/eval/README.md`, which is where a re-derivable figure has one home. Corpus: **−992 B repaid** from the debt this ledger has named since 10-24 (the "named, unused" `deepseek-harness` cell plus its registry name, the dated `default.metallib` narration with its upstream cites and gate kept, four MM-DD stamps whose verdicts `CHANGELOG.md` carries), then **+310 raised to 161004** for the proposition and the gate rule, with the repayment stated in `scripts/agents-md-contract.sh`.
- **The mistake worth recording**: retiring that comparator cell by collapsing § Upstream 6's list into a pointer *weakened P16 while keeping it nominally live* — the gate parses that list as its **input**, so it read 2 "trees" against a floor of 14 and mismatched the doc's zero-coupling list (7 violations the moment the filter was widened). Restored verbatim; a tree is retired by dropping its name from **both** homes, and the ledger now says so. Root rule added: **a gate you did not run is not green**, with `make push-ready` named as the path that runs the no-build set.

**10-27(4) The style gate could not fail on this host, so 36 files had quietly left CI's ruleset** (P1 gate determinism / symbols `pin-you-cannot-install-is-not-a-pin`, `sf-pin-installs-the-authority`)

- **The red CI named, local could not see**: after the lockfile gate went green, Static Audit's next failure was `needs swift-format:` against ten committed files (`SQLiteStore.swift`, `ChatHandler.swift`, `MLXBridge.swift`, `EngineInference.swift`, …; the annotation list truncates). Reproducing it required CI's ruleset, and this host does not have one: `xcrun swift-format` reports **"main"**, so `make format-check` took its advisory branch — lint, write nothing, **exit 0 whatever the tree looks like** (`Makefile` printed `formatter: main (CI pins 603.0.0) → advisory`). A gate whose local mirror cannot fail is not a mirror; it is how drift reached CI at all.
- **Root cause is installability, not awareness.** CI's own step comment says *"A pin you cannot install is not a pin"* and builds `603.0.0` from the tag because brew serves whatever is current — that argument applies identically to the local mirror and had never been acted on. So the Makefile gained `make sf-pin` (clone the tag, build it once into `$(SF_CACHE)`, print the version) and `SWIFT_FORMAT` now discovers that binary before falling back to PATH and before falling back to `xcrun`. Both advisory echoes name the remedy. Zero new tooling, zero new config: same `.swift-format`, same args, same version as the runner.
- **Measured in both directions, in order**: pinned mode against the committed tree → **exit 1, 36 files named** (that is the red this host had never been able to produce); reformat with the same binary → `36 files changed, 326 insertions(+), 204 deletions(-)`, all line reflow (closure-signature wraps, argument-list wraps — no token changed meaning); `make format-check` again → `formatter: 603.0.0 → pinned`, `zero files reformatted`. `swift build -c release` and `swift build --build-tests` both exit 0 at the reformatted tree, and `make test` reports the suite verdict below.
- **Losing a red is a defect in the instrument, and this host demonstrated it twice.** The first full run after the reformat printed `Test run with 3350 tests … failed … with 1 issue` — and because the output was read through a pipe, **the failing test's name was gone**, so that run cannot be root-caused at all; the runs after it were green (`exit 0`), which does not explain the one that was not. `make test` therefore tees the run to a log and re-prints the `✘`/`↳` lines on failure while keeping the real exit status. The status travels through a temp file because `PIPESTATUS` is a bash-ism and recipes run under `/bin/sh`: measured directly, a failing pipeline there reports `${PIPESTATUS[0]}` as **0**, so the first cut of this change would have made the tee swallow every red — it went green on a planted failure. Both directions are now verified with a planted `Issue.record` test: red prints `✘ Test "deliberate failure for the gate" …` plus `↳ gate must name me` and exits 1; a passing suite prints no block and exits 0. And the first "it still does not print" reading was my own `tail -6` cutting the summary off — the same failure mode one level up, which is the argument for the gate rather than against it.
- **Open, stated rather than smoothed**: the reflow's meaning-preservation rests on the formatter's contract plus a clean compile of product and test targets, not on reading 530 diff lines; the full-suite number from this host is the line under this entry, and CI's two `Build & Test` legs remain the authority. `sf-pin` is a host cache, not a repo artefact — a fresh clone is advisory again until it is run, which is the same shape as CI (its audit job builds the pin per run).

**10-27(3) The scoreboard grew the two axes it could not read, and its own numbers stopped being folklore** (P1 measurement / symbols `cost-per-verified-success`, `readme-figures-rederived`, `first-four-axis-board-on-host`)

- **What the objective actually asks** is four falsifiable questions — did it get done, does it hold up (including when a step fails), what did it cost, did it stay inside what it was told to touch. Correctness and repetition were measured; the other two were prose. So `tasks.json` is 36 → **39 tasks**: `recover-from-stale-lock` fails its first tool call *by design* (a stale `build.lock`) and passes only when the cause is removed — writing the artefact around the failing step is a named near miss; `report-a-real-tool-failure` makes the answer quote a token that exists only if the tool actually ran, and rejects the same token wrapped in a claim of success; `delete-only-what-was-asked` prices blast radius, so `rm -rf logs` fails even though the named file really is gone. Kinds stay at nine, so every family floor keeps its teeth. Verifier self-test: 39 tasks, 0 defects, near-miss coverage 25/25.
- **`# efficiency` is the cost of a *verified* success** (`_eval.py efficiency` + `_efficiency_selftest.py`): summed over every attempt — a failed turn spent its seconds and its tokens — divided by what the verifier accepted, with each quotient printed beside its denominator (`passes=`, `usage_parsed=`). Three refusals are gated on hand-computable fixtures: unparsed usage yields `tokens_total=unmeasured` rather than a cheap-looking zero, zero passes yields `none` rather than 0, and a file with no rows exits non-zero. The line is written **before** `# score` because `_repeat_stats._read_run` takes the last `#` line as the score; the self-test demonstrates that displacement (`score` read as `efficiency passes=1/1`) so the ordering cannot be "tidied" into silently corrupting every A/B verdict.
- **The instrument caught its own author twice, which is the point.** The first live pass crashed at `rank()` — `ceil(0.95*23)-1 = 21.0` reached `ordered[...]`, a float index, and run.sh refused to write a score it could not price (`nothing is written`, exit 1). Percentiles now take basis points and use integer arithmetic only, and the fixture grew to 20 successes because the two-row fixture could not reach the shape that broke: ties return the first argument, so `min(n-1, float)` returned an int and hid it. Two further reds were my expectations, not the code (80 tokens ≠ 70; nearest-rank p95 of 20 values is the 19th, not the max) — corrected with the rule stated, not the constant copied.
- **The docs said a set that no longer existed**: `scripts/eval/README.md` still described **24 tasks / eight families / coverage 19-19 and 16-16** while the file held 36 (now 39) and coverage was 25/25 and 35/35. The figures are now re-derived from the task files by the verifier self-test itself (`readme_claims`), reading both scored sets **by name** so a screening pool cannot mute it, and floored at "2 of 2 claims locatable" so the audit cannot rot into matching nothing. Red samples, both taken: the stale 24 read red before the prose was fixed; editing `35/35` to `34/35` printed `README claims near-miss coverage 34/35 for the frozen set, the file gives 35/35`.
- **First four-axis board on this host** (gemma-4-e2b-it-4bit, temperature 0, k=1, `tasks.json`, artefacts under `~/.cache/ocoreai-eval-013050/`): **passes 21/39**, `median_ms_success=2191`, `p95_ms_success=11346`, `ms_per_success=8126`, `tokens_per_success=4224`, `usage_parsed=39/39` — cost over 39 attempts is 170 s and 88 709 tokens, so every failed attempt is priced into the unit cost rather than hidden. Recovery and faithful-failure reporting both passed (11.3 s and 3.9 s). Note the pass count is 21, not the 23 `probe_summary` prints: two of its PASS lines are `_lib.sh`'s own `/health` and `built-from` probes, so the scoreboard's denominator is the row file, not the verdict tally.
- **Open, and why it is open**: `delete-only-what-was-asked` failed with `the tool execution failed` — an honest refusal, so it scores as a real product failure — but **no artefact can say which tool failed or why**: a native turn echoes no `tool_calls`, so `response-<id>.json` holds the final text only, and `_lib.sh` removes the server log at exit. Naming the root cause needs either the log kept for the run's lifetime or an audit surface the eval can snapshot; both are new surface, so this is an owner call rather than a silent expansion (see the report).

**10-27(2) Two lockfiles, one graph: `xcodebuild` had never compiled the pin this repo audits** (P1 build correctness / symbols `workspace-resolved-stale-three-bumps`, `local-audit-mirrors-the-ci-lockfile-step`)

- **The red moved, which is what a gate queue looks like**: Static Audit at `13280ba` failed at `failed step: resolved lockfile sync` with **no** `docs gate:` annotation at all — 10-27(1)'s fix held on a runner for the first time, and the step two rows later got read for the first time. A job aborts at its first failing step, so the four-push docs red had been *masking* this one.
- **Measured, not inferred**: root `Package.resolved` pins `mlx-swift-lm` at `991266ad300f` (the `revision:` at `Package.swift:43`); the workspace copy sat at `6e338e5df494`, last written by `5b19d75` — three bumps behind (`bd51f2f`, `9f0b88e`, `372ff2c`). `xcodebuild` reads the **workspace** copy, so every authority-leg build since — both CI `Build & Test` legs (`ci.yml:225`) and the release/DMG legs (`ci.yml:320`, `ci.yml:401`, `ci.yml:593`) — compiled a graph behind the revision § Upstream Audit Dependencies calls the contract, while `swift build`/`make test` ran at it. Two green halves, one silently forked dependency set.
- **Root cause is where the check runs, not whether it exists**: this drift had already been patched twice (`31abe87`, `4e4fcbc`), which is what a report sitting downstream of the bump buys. `scripts/resolved-sync.sh` ran only in CI, and `make audit` — the stated local mirror of that audit job — omitted the step. Fixed on existing rungs: `resolved-sync.sh sync` (values-only, root wins, one pin) and the check chained into `make audit`. No new script, target or flag.
- **Both directions gated**: green prints `resolved files in sync (34 pins)`; re-desyncing the workspace copy makes `make audit` exit 2 naming `mlx-swift-lm root=991266ad300f ws=6e338e5df494` and the remedy (red sample, taken and reverted). Verification had to be honest about the host: `github.com:443` times out here while `api.github.com` answers, so resolution ran with `-onlyUsePackageVersionsFromResolvedFile` after seeding Xcode's own clone from the local SPM cache — the workspace checkout was at `7eb77efa`, two bumps behind even its own resolved file, and moved to `991266ad300f`; `build-for-testing` at that revision reports **TEST BUILD SUCCEEDED**.
- **Not claimed**: the xcodebuild *test run* at the new pin on this host (CI's legs are the authority and answer on the next push), and any claim that the app's behaviour differs between the two revisions — nothing here says it did, only that nobody could have known.

**10-27(1) The gate that speaks for itself named its own four-push-old cause** (P0 CI truth / symbols `comparator-cites-declared-not-faith`, `docs-gate-annotation-earned-its-keep`)

- **One round of instrumentation, one named cause**: the first push carrying `::error::docs gate: …` (10-26(24)) returned — without a token — `P2 23 unresolved reference(s) … ASSETS.json, Cargo.toml, PINNED.md, … serving_chat.py, srt/entrypoints/openai/protocol.py`. The Static Audit leg had been red since at least `9e0a984` with nothing but `failed step: AGENTS.md contract (docs gate)` to read.
- **Cause, measured rather than inferred**: 23 cites point into **comparator** trees. `docs/agent/comparator-repos.md` carries 18, `docs/agent/instruction-channel.md` 3, `docs/agent/systemone-decisions.md` 2, and `Sources/ocoreai/Handlers/AGENTS.md:25` 1 (`serving_chat.py:1488-1501`) — and none of the 23 ever existed in our history (`git log --all --name-only` over the set: empty), so this is not drift. Locally they resolve through `~/references`; on a runner that tree does not exist, so CI was right and the local green was the accident. Reproduced faithfully: with the host clones removed from the resolver, the scan reports the same 23.
- **The fix is the mechanism the script already sanctions** (`02d4cb5`), the one that `SYSTEM_REFS` uses for OS headers: `COMPARATOR_REFS` declares them, implementing § Upstream Audit Dependencies 6 verbatim ("not pins; nothing linked or redistributed, and a borrowed verdict stays an inference"). It rots in both directions and both are gated, not trusted: delete an entry and its cite goes red on a runner (red sample: `srt/entrypoints/openai/protocol.py`), keep one no doc cites and the dead-declaration check goes red (red sample: a planted name). A third check refuses a declaration for a file the repo actually carries. The run prints `outside 23/23`, so the count is visible instead of assumed.
- **What was deliberately *not* done**: no "skip on CI" branch, and no rewrite of 23 cites into prose that loses the line numbers — the workflow's own comment forbids turning an unresolvable cite into an exemption granted for convenience, so the declaration is tied to a stated policy and gated against its own decay.
- **Also open, and now distinguishable**: `macOS 26 · iOS compile-only` came back `cancelled` on the same run for a provider reason — `The job was not acquired by Runner of type hosted even after multiple attempts` — which is GitHub capacity, not a red we authored. It will be re-run by the next push rather than papered over with a retry loop.

**10-26(25) The last unpriced number in the startup path is now a measurement** (P1 determinism / symbol `checkpoint-statement-is-timed`)

- Three rounds of CI-vs-host reading turned on one unanswerable question: was `walBusyTimeoutMilliseconds` honoured? `open()`'s wall time cannot say, because it also carries actor hops and the rest of the process — which is why `waited=8.30s` against a 5 s timeout was arguable. The wait lives inside `_step` (SQLite's busy handler spins there), so `WALCheckpoint` now carries `statementMs` measured at that line, and EVIDENCE prints it.
- Both directions get a bound, and both are the measured signature of a real defect rather than a picked number: `>= 4500` is the pre-fix shape (a timeout installed after the pragma answered `busy=1` in ~4 ms, indistinguishable from success unless the wait is timed), `<= 10_000` is "the refusal came from our knob, not from the other connection's schedule". The ceiling is 2x the timeout because a saturated busy handler sleeps in ~25 ms steps whose lateness accumulates — the mechanism the CI number points at — so a tighter idle-host ceiling would have turned a host artefact into a red.
- Measured: 4/4 green here with the wait inside the window. **Open**: what CI reports is the first real datum, and it goes in this file whichever way it lands.
- **The number reaches the operator, not just the suite** (paired in this commit, per H3): a refused truncation is a degraded start the app reports rather than hides, and the quantity an operator needs is *how long we waited against what we asked for* — page counts alone cannot tell a 5 s timeout from a 4 ms give-up. Measured in this suite's log: `held the WAL for 5238ms of a 5000ms budget (log=4 checkpointed=4 …)` and `… 5242ms … (log=80 checkpointed=80 …)` — the statement spent its whole budget and still refused, roughly 240 ms past the knob, which is the sleep-step lateness the 2x ceiling sits above.

**10-26(24) The authority leg moved the red somewhere honest, and the empty XCTest half was never a half** (P0 CI truth + P1 gate honesty / symbols `ordering-bound-is-the-commit-instant`, `xctest-half-holds-zero-tests`, `latency-bound-priced-by-measurement`, `docs-gate-annotates-itself`)

- **CI read the instrument and answered** (`27934fa`): `busy == true` passes on both matrix legs now — the committed-frames premise held — and what went red was the guard added with it: `Expectation failed: (waited → 8.299391875 seconds) < (.seconds(8) → 8.0 seconds)`. That is the ordering *holding* while a hand-picked ceiling fails: an 8.30 s `open()` on a runner driving 3190 tests, with the truncation still refused. So the bound is no longer a constant. `holdWriteLock` returns the commit instant measured from one epoch and the assertion reads `openEndMs + 50 < commitMs` — the causal sentence ("the refusal landed while the lock was held"), with nothing to re-tune when a runner is slow; EVIDENCE prints `waitedMs/openEndMs/commitMs` so the next reading is arithmetic.
- **`swift test` could not exit 0 on this host whatever the suite did**, and not because of a failing test (`63d90a9`): `Tests/` contains **zero** XCTest files (`grep -rl "import XCTest" Tests` = 0, `XCTestCase` = 0 occurrences), and the runner that hosts that half dies before test #1 on macOS < 27 — 22 identical crash reports today: `+[XCTestSuite suitesForBundlesIncludingEmptySuites:]` → `objc_copyClassList` → `realizeAllClasses` → ObjC metadata update for `CoreAIPipelinedEngine` → the metadata completion function for `EngineImpl` (the `~Copyable` struct at `Engine/CoreAIPipelinedEngine.swift:494`) at `EXC_BAD_ACCESS ... 0x0`. Mechanism measured, not assumed: both types are `@available(macOS 27)` and the binary weak-links `CoreAI.framework`/`FoundationModels.framework` (`otool -L` reports `(weak)`), so their class references bind to NULL where the frameworks are absent. CI had been saying the same thing quietly: `Executed 0 tests, with 0 failures`. `make test` therefore always passes `--disable-xctest` **and refuses** if `Tests/` ever gains an XCTest file — verified in both directions (green prints `XCTest half: 0 file(s)`; a planted `XCTestCase` file exits 1 naming the remedy). Availability gating is what keeps the *app* off that path today, stated as a dependency rather than sold as a fix: struct→class or a compile-out trait is an owner call, since nothing outside an ObjC class enumerator has been observed reaching them.
- **`EngineBusyAdmissionTests` went from a proxy to a measurement, and kept a real ceiling**: the release instant is returned by the releaser, and the ceiling is `max(3000, 4 × control)` with `control` = the host's own 50 ms sleep latency measured during the wait. Removing the ceiling was tried first and rejected by a red sample — a `Task.sleep(until: deadline)` waiter still returns `true`, so `acquired` alone is not a gate — and reinstating that defect inside `LoadedModel.acquireInference` turns `wakeSlackMs < budgetMs` red, green again on restore. Both ends of the bound are measured, not chosen: worst set-run wake on this host 2194 ms (3350 tests on one pool; a control reading 172 ms against a 1564 ms wake is what a saturated clock's tail looks like), defect signature ~4.8 s.
- **The docs gate had been red on CI for at least four pushes and nobody could say why** (`9e0a984`, `099e2d7`, `bcb9fec`, `34b9bc9` all annotate only `failed step: AGENTS.md contract (docs gate)`, and the log needs a token). Local reproductions disagree with CI in both directions — an unresolved-deps clone gives `P2 … Sources/HuggingFace/Hub/HubClient.swift`, a resolved clone is green at any depth — so rather than guess, every violation now also leaves as `::error::docs gate: …` under `GITHUB_ACTIONS`, which the annotations API serves without a token (red sample: the unresolved-deps clone emits the P2 line). **Cause still open**: the next push reads it back.
- **Outcome**: two consecutive full set runs report `Test run with 3350 tests in 590 suites passed …` with `make test` **exit 0** — the first green local full-suite exit code this host has had, because the exit code was previously pinned by a crashing empty half rather than by the suite. Still open and named: `MCPStderrDiagnosisTests.swift:293` (`elapsed >= 1.9 && elapsed < 4.0`) drifted in one of the six set runs this round — same family, same remedy shape, not silently loosened.

**10-26(23) The last CI red was the suite asserting host luck** (P0 CI truth / symbols `wal-checkpoint-premise-was-host-luck`, `open-outlived-its-own-timeout`)

- **What CI read back, thanks to 10-26(22)**: `waited=6.60796825s busy=false logPages=0 ckptPages=0 busyTimeout=5000 walBytes=0` on both matrix legs, against the local control `waited=5.1997495s busy=true logPages=79 ckptPages=79 walBytes=329632`. Two things follow from the line alone: `(0,0,0)` is the *success* shape for `wal_checkpoint(TRUNCATE)` (a truncation to zero pages reports zero), and `waited` is measured before the commit is awaited, so CI's `open()` ran 6.60 s against a 5 s `busy_timeout`. The instrument did its job — this is a diagnosis off a log line, not a guess at one.
- **Two mechanisms survived, and the probe favours the second.** (i) Nothing to truncate, so `busy=0` was honest: refuted for sqlite 3.51 outside the app — re-run here on sqlite 3.51.0: an empty WAL with a held uncommitted transaction still answers `(1,0,0)`, busy because the write lock could not be taken. (ii) The checkpoint statement outlived its own timeout and truncated *after* the writer's 6.5 s commit: that fits `waited=6.60s` and needs ~1.6 s of overrun inside sqlite's millisecond-stepped busy handler, on a runner driving 3349 tests at once. `busy_timeout` was in force (the same connection reads back 5000, and the pragma is the first statement in `open()`). Named, not patched: a startup statement that can overrun its own timeout under contention is a real product fact, and this host cannot measure a runner's scheduler — the widened margin below is what makes the *test* immune to it either way.
- **What ships** (`Tests/ocoreaiTests/SQLiteOpenBusyTimeoutTests.swift` only; product code untouched, because nothing measured contradicted a product claim): the writer commits a first transaction before opening the held one, so copyable frames provably predate the challenger — frames belonging to an *uncommitted* transaction are invisible to a checkpoint, so the old helper's premise held only while the writer's own startup truncation happened to leave pages behind; `walBytes > 0` is floored *before* `open()` with a message that says "nothing to refuse" instead of accusing `open()`; the commit lands at 12 s rather than 6.5 s, so a truncation that reached the commit needs a 7 s overrun instead of the 1.5 s one CI appears to have hit; `waited < 8s` is asserted, which is the sentence that goes red when the verdict can no longer be attributed to contention; the EVIDENCE line splits `walBytes` into `walAtOpen`/`walAtRead`, because the old field was read *after* the commit and a late truncation erases its own evidence; and a fourth test manufactures CI's start (`PRAGMA wal_checkpoint(TRUNCATE)` down to a 0-byte WAL, asserted) and still demands `busy == true` with frames present.
- **Gate**: `SQLiteOpenBusyTimeoutTests`(4) — 4/4 green in 12.437 s here, refused path quoted live (`log=80 checkpointed=80`, `log=4 checkpointed=4`). **Not claimed**: the new test's red direction is not reproducible on this host — reverting the committed-transaction premise stayed green here, because page-cache spill keeps frames resident on this machine — so the premise floor plus the authority leg decide it, and the CI line is the next measurement.

**10-26(22) The authority leg now has one named red, and it is not this host's behaviour** (P0 CI truth / symbols `sqlite-busy-ci-only`, `evidence-line-ships-on-red`)

- **The legibility work paid for itself in one run**: commit `099e2d7` turned `Build & Test (xcode-27)` and `Build & Test (macos-26)` from "exit 1, nothing readable" into a named assertion — `SQLiteOpenBusyTimeoutTests.swift:126:9: Expectation failed: (reported?.busy -> false) == true`, `Test run with 3349 tests in 590 suites failed after 88.572 seconds with 1 issue` — the **same single failure on both matrix legs**, with `Governance Check`, `App Store trait compile` and `iOS compile-only` green. The suite is one assertion from green on CI, and two runners agreeing twice rules out a timing flake.
- **Control measured here, not assumed**: the passing path was temporarily printed and reverted (same discipline as the 10-26(20) probe) — `waited=5.1997495s busy=true logPages=79 ckptPages=79 busyTimeout=5000 walBytes=329632`. The mechanism was also reproduced outside the app: two connections in one process, `BEGIN IMMEDIATE` + `INSERT` left open, `PRAGMA wal_checkpoint(TRUNCATE)` answers `(1, 2, 2)` on sqlite 3.51.0. So contention *is* enforced where the suite is green.
- **What ships is an instrument, not a guess**: a failing run prints `EVIDENCE sqlite-open-busy: waited=… busy=… logPages=… ckptPages=… busyTimeout=… walBytes=…`, and the CI grep publishes any line tagged `EVIDENCE`. The discriminating field is `logPages`: zero means the truncation had nothing to copy, so `busy=false` is sqlite being correct and the *test's premise* is what CI breaks; non-zero with `busy=false` means the busy column was swallowed, which is a bug in `open()`. Patching before reading that field would be a guess wearing a commit message.
- **One more legibility line**: the step publishes a notice stating whether the harness reported a summary at all (`Executed N tests…` / `Test run with N tests…`), so "the run aborted" is now a different sentence from "a test failed".
- **Unchanged and named**: `Static Audit` is red on the same assertion, reached through its advisory coverage step — the 10-26(21) step-name annotations did not fire there because that step runs the suite rather than one of the four wrapped scripts.

**10-26(21) The iOS leg went green, and the annotation meant to name tests named nothing** (P1 CI legibility / symbols `swift-testing-failure-shape`, `pdbg-removed`)

- **One open half of 10-26(19) closed by evidence**: `macOS 26 · iOS compile-only -> success` on commit `2644008`. The `Process` platform gate held on the runner, so the stub fix is CI-verified rather than macOS-verified-and-hoped. `Governance Check` and `App Store trait compile` also pass; both `Build & Test` legs stay red.
- **The grep was wrong about the framework this suite is written in**: the "no failure line" branch fired on *both* matrix legs, and that is itself the measurement — swift-testing reports `✘ Test "…" failed after N seconds with M issues`, not `Test Case '-[…]' failed`. The pattern now matches both shapes plus `Fatal error`, so a red leg names its cases instead of its tail.
- **What the tail showed instead of a diagnosis**: three leftover `print("PDBG …")` statements in `Tests/ocoreaiTests/PDFReadFileTests.swift` dumped whole tool outputs into every CI log — a full `read_file` body with its `total_lines:` chrome and the numbered echo, i.e. exactly the read-echo chrome § Two invariants says to strip when provable. Removed (suite still 3/3 green); the no-match branch now quotes the log's line count and 12 tail lines rather than 6.
- **Still unknown, and named as unknown**: why `xcrun xctest` exits 1 on both legs without emitting one failure line — crash, timeout or shader payload. This push is the instrument; `scripts/ci-status.sh` reads the answer back without a token.

**10-26(20) A dead server's cause was arriving 150 ms too late — measured, then widened** (P1 diagnosis reliability / symbols `stderr-drain-starved`, `counted-not-clocked-evidence`) — `MCPStderrDeliveryTests` was the only red in the full local suite, and the handoff's hypothesis (drain starvation) was tested rather than trusted.

- **Hypothesis refused to reproduce on demand**: 12 CPU spinners on 18 cores ran the filtered suite 3× — 3 passes. Only the *full* suite reproduces it, so the mechanism was measured, not argued: a temporary probe inside `stderrEvidence()` (installed, run, reverted with `git checkout` — no debug code ships) logged `entrySnapshot=0 entryEnded=0 polls=10 finalSnapshot=0 ended=0 lines=0`, three times, in a run that failed with 7 issues. Two hundred and fifty milliseconds after the child died the tail had **no line and no EOF** — the drain block had not started at all.
- **Which reorders the diagnosis**: the child's traceback was never lost (it sits in the kernel pipe buffer until the drain reads it), so this was never a durability bug — it was a *diagnosis latency* bug, and the refusal the caller read said "exited with status 3" where it could have named the `ModuleNotFoundError`. Invariant 2: the surface quoted the symptom because the engine had not finished measuring the cause.
- **Two halves, both priced**: the drain now runs at `.userInitiated` (its output is the sentence a caller reads at the moment of failure, and utility QoS is what starved it), and the clean-up ceiling goes 10×15 ms → 40×25 ms. The first look is free when the tail already holds bytes, so the cost lands only on the case the probe caught — a silent, dead child. Still counted, never clocked: `MCPTimeoutDeliveryTests.scanFloors` forbids a `ContinuousClock.now + ` in this file, because the caller owns the one response deadline, and this is not a response wait.
- **Measured after**: six full-suite runs. One went `Test run with 3349 tests in 590 suites passed after 12.525 s` with zero issues; the others carried 1–2, and **the MCP stderr family is absent from every one of them**. Gate: the red test itself — it went from failing 4 expectations to never appearing.
- **What this did not fix, named rather than hidden**: the residue is a different family, and it moves between runs — `EngineBusyAdmissionTests` (a wall-clock `< 1000` budget), an `ExecSessions` child whose temp cwd `ocoreai-cwd-<UUID>` was gone under it, `MCPTimeoutDeliveryTests:265` missing a 9 s budget under load, and `LoopGuardRemedyTests:36` resolving `sum100.py` against a process cwd with no workspace set. Four suspects, one shared shape: a test whose premise is process-global state while the runner owns the process. Unverified as a cause; the next instrument has to name it.

**10-26(19) The distribution surface was reset to zero, and the two claims that hid why** (P0 distribution integrity / symbols `tagline-withdrawn`, `version-ladder-empty-string`) — the owner withdrew the release line; executing that exposed a false promise, a blank-version defect, a second iOS defect and an annotation that lied.

- **Executed**: every tag withdrawn — 5 remote (`v0.1.1 e878575`, `v0.1.2 c07d425`, `v0.1.10 171af6b`, `v0.1.12 3160063`, `v0.1.13 ea73443`) and 6 local (adding `v0.1.14 1139ecd`, never pushed). The SHAs above are the recovery: `git tag v0.1.13 ea73443 && git push origin v0.1.13`. **Not done**: the 3 published *Releases* (v0.1.10/12/13, 7 downloads between them) are GitHub objects, not git objects — they need the REST API, and this host holds no token in env, `gh`, `~/.netrc` or the keychain. They still resolve, and no local gate can see them.
- **The promise was made honest before anything else** (invariant 2): `README.md` promised a double-click DMG at `releases/latest`. Both languages now say what is actually downloadable — the `releases` listing, and "if that page lists nothing, build from source" — and `releases/latest` is gone from both sides. Gate: `ReadmePairParityTests` pins the URL sets equal (21 = 21 measured).
- **A defect the reset exposed, not a hypothetical**: `$(git describe --tags --abbrev=0 2>/dev/null | tr -d 'v' || echo 0.0.0)` yields **empty**, not `0.0.0`, on a tagless tree — a pipeline reports its *last* status (`tr`'s, which is 0), so `|| echo` never runs. With zero tags that was the only path, and `CFBundleShortVersionString` would ship blank. One home now: `scripts/version.sh` (ladder `OCOREAI_VERSION` -> tag -> `0.0.0`), three call sites repointed (`build-app.sh`, `build-dmg.sh`, `e2e-gui-app.sh`). Gate: `BuildVersionResolutionTests`(4) — override / tagless -> `0.0.0` / tagged -> `1.2.3`, plus a premise test asserting the *old* expression still returns `[]` so the gate cannot rot into pinning a fiction. Measured: 4/4 green in 0.214 s.
- **The second iOS defect, found once the first was fixed**: `Sources/ocoreai/Tools/PostWriteSyntax.swift:116` constructs a `Process` (unavailable in iOS) with no platform gate — CI quoted `error: cannot find 'Process' in scope`. The repo already carries the right shape (`ExecSessions`' `SessionProc` stub under `#else`), so `pythonVerdict` now returns `.notChecked("no subprocess on this platform — syntax not checked")` off macOS. Scope measured, not guessed: scanning every tracked `Sources/**` file for ungated `Process`/`Pipe` construction found **exactly one** real site (the other 4 hits were an already-gated `#else` stub, a comment, and a method on our own type), so no scan gate was written for a one-instance class — the iOS compile leg *is* that gate.
- **The f5ae060 legibility change was itself falsified and fixed**: the first `::error::` it published for `Run tests (xcrun xctest)` was no test at all but a log line matching `' failed` (`FM tool 'edit_file' failed — surfacing to model: invalidParameter(...)`), while the macos-26 leg published nothing. The grep is now `^Test Case .*\] failed`, and a leg that exits non-zero with no such line says so and quotes its log tail rather than staying silent. The 4 audit scripts now name themselves (`::error::failed step: …`): a bare "Process completed with exit code 1" at log line 22 is not actionable. Note for the next YAML edit: `run: bash x.sh || { echo "::error::step: y"; }` is a *plain scalar*, and the colon-space inside it breaks the entire workflow file (`mapping values are not allowed in this context` at line 71) — caught by parsing the file before push, so these steps use the block form.
- **The buy-in clause turned on this round's own plan**: a dependency-direction rule ("UI frameworks enter only through `UI/`") measures **0** violations — 32 files import SwiftUI, every one under `Sources/ocoreai/UI/`. Per the clause imported into § Working here, no audit class was written for an unobserved failure; the idea stays a question for the owner instead of becoming permanent scanning code.
- **Docs**: opencode's complexity clause merged into the existing "No defensive clutter" bullet (one home, not a new bullet), and the corpus repaid by tightening this round's own prose to 160 686/160 694 — no cap raise. § Rung zero's R1 claimed the publisher "needs the owner's credentials — `gh` is not installed here": **wrong**, the `release` job authenticates with the runner's own `${{ github.token }}`, so R1 was never credential-blocked but blocked by the suite. Corrected where it lived, not in a footnote.

**10-26(18) A red leg nobody can read is a red leg nobody fixes** (P0 CI legibility / symbols `xctest-failures-published`, `ios-stub-missing-member`) — the formatter pin made the authority leg visible; this makes the remaining reds readable and fixes one that was real.

- **`xcrun xctest` exited 1 and named nothing.** Both matrix legs sat on a bare `exit 1`, and job **logs** need a token while **annotations** do not. Failures now go to `$GITHUB_STEP_SUMMARY` and `::error::`, and the metallib death — which reports no summary at all, per `docs/agent/build-gate-reality.md` — gets its own named error. The next red has to name its tests without a credential.
- **The docs gate needed a checkout it did not have.** Static Audit's red reproduced locally without guessing: `git clone --depth 1 . /tmp/sim` then `HOME=/var/empty bash scripts/agents-md-contract.sh check`. The cite `Sources/HuggingFace/Hub/HubClient.swift` (swift-huggingface) resolves only under `.build*/checkouts`, which CI has not built at audit time. Remedy: `swift package resolve` before the gate — a cite that resolves nowhere must stay a failure, never become an exemption granted for convenience.
- **New `scripts/ci-status.sh`** (+ `make ci-status`, printed by `make push-ready`): exit 0 = every leg that must run concluded success, 1 = a leg failed **or a leg that must run was skipped**, 2 = COULD NOT ASK (offline, rate-limited, no check-runs). `skipped != verified` is an exit code, not a footnote, because a claim you cannot ask about is a claim you are hoping.
- **The iOS leg's red was a defect, not a flake**: `Sources/ocoreai/Handlers/MultimodalHandler.swift:268` reads `screenshotService.lastError`, declared only inside `#if os(macOS)`. Scope of the class measured rather than assumed — exactly one type in `Sources/` is declared across two `os` branches (scanned every tracked file) — so the existing iOS compile leg is the gate and no scan was written for a one-instance pattern (§ *No defensive clutter*). The stub now carries the member and sets it to the platform truth, so a platform that has never captured answers "Screen capture is not supported on this platform" instead of "No screen frame captured": invariant 2 applies to the stub too.
- **Not claimed**: no iOS build ran here — `xcodebuild` dies on `Could not resolve package dependencies: RPC failed; curl 56`, so the stub fix is macOS-compile-verified only (`swift build` exit 0) and CI decides the iOS leg. `scripts/ci-status.sh` is how that verdict gets read back.

**10-26(17) Docs are English by default and exactly one file is Chinese — gate P18** (P1 doc contract / symbols `p18-language-default-english`, `raw-escape-in-markdown`) — the owner's rule was prose in a chat; a rule with no gate is a claim, so it became a scan with floors and ceilings in `scripts/agents-md-contract.sh`.

- **The rule as measured**: every tracked `.md` except the diary holds **0** CJK characters (25 files scanned, floor 20 so "all docs are English" cannot pass on an empty list); `README.zh.md` — the one Chinese surface, and the mirror of `README.md` — must hold ≥2 000 (measured 2 908), because a mirror that stopped being Chinese mirrors nothing. `CHANGELOG.md`/`CHECKPOINT.md`/`IDEA.md` get ceilings (158 161 / 1 159 / 6) instead of a rewrite: history stays in the language it was written in, a *new* Chinese line fails.
- **Caught the day it landed**: the English `README.md` carried a Chinese install block that `README.zh.md` already held, plus four agent-facing docs leaked a phrase each (`closed-items-log`, `competitor-iteration-paths`, `scripts/eval/README.md`, `scripts/probes/README.md`). `README.md` is now at 0 CJK and the mirror is untouched.
- **A second guard in the same gate — no raw backslash-u escapes in Markdown**: 26 had already shipped (25 in `CHANGELOG.md`, 1 in a guide) because heredoc strings double-escaped them, and every one of those commits went green while the file read as broken source. Repaired in place; the class is now gated, not apologised for.
- **Red samples run in this session**: one Chinese sentence appended to `docs/agent/comparator-repos.md` → `P18 docs/agent/comparator-repos.md carries 16 CJK character(s)`, exit 1; one em-dash escape appended to `SECURITY.md` → `P18 SECURITY.md carries 1 raw \uXXXX escape(s) in a Markdown file`, exit 1; both reverted → green.
- **Consequence for this file**: the ceilings are pinned at measured with **this gate's own classifier** (Han + CJK punctuation + fullwidth; a narrower probe made the gate fail for the wrong reason on its first run), so entries from here on are ASCII — `(P#/ symbols …)` with plain parens, not the old fullwidth form. The remedy for a red ceiling is in the gate's own message, which is why no second copy of the rule was written into `CONTRIBUTING.md`.

**10-26(16) The authority leg had been skipped for ~90 pushes — a formatter pin was cancelling CI itself**（P0 CI integrity / 符号 `pinned-formatter-not-brew`、`authority-not-hostage-to-style`） — asked what it would take to become GitHub's #1 coding-agent repo, the honest first move was to check whether the project's own declared authority was currently true. It was not, and had not been for a fortnight.

- **Measured**: every one of the last 20 `CI` runs on `main` is `failure`, and pages back to 2026-10-14 hold **zero** successes across ~90 runs. The failing step is `Static Audit → Setup swift-format`; `Governance Check` passes and **every other leg reports `skipped`** — `Build & Test (macos-26 / xcode-27)`, `App Store trait compile`, `macOS 26 · iOS compile-only`, `Release DMG`. AGENTS.md § Build / Test / Lint names `make test-ci` on macos-26 *the authority*, and `make push-ready` calls an unseen commit "unverified"; both statements were vacuously true while the leg never executed.
- **Cause, dated from outside the repo**: `swiftlang/swift-format` released **604.0.0 on 2026-09-16**, `brew install swift-format` therefore hands a runner 604, and the step asserts `*603.0.0*` and exits 1 — deterministic, every push, from the moment the runner image picked the new formula up. The pin was right; the *install* could not honour it, because brew floats by design.
- **Two structural fixes, not a retry**: (1) the pin is now **built from the tag** (`git clone --branch 603.0.0` → `swift build -c release` → assert the built binary's own `--version` → prepend to `$GITHUB_PATH`), so "version-locked" means reproducible rather than hoped-for, and the assertion still goes red if the build ever yields something else; (2) `build-and-test`, `build-appstore` and `build-ios` no longer `needs: [audit]` — an authority that a style tool can cancel is not an authority, and the job graph now parses to `governance → audit`, with the three heavy legs independent and only `release` depending on `build-and-test`.
- **Why this outranked the README work**: the public badge was red while the repo's prose claimed CI as its authority and compared itself to `references/` projects on rigour. That is invariant 2 pointing inward — a surface (a badge, and every `make test-ci` green claim built on it) claiming more than the engine delivered.
- **Not claimed**: whether the *format* gate itself passes once the pin is honourable is **unknown**, because no local `swift-format` exists here (`xcrun swift-format` reports `main`) and the pinned build could not be produced locally — the clone died on `RPC failed; curl 28` and `brew` is absent. Drift accumulated by ~90 unenforced pushes is likely, so the expected next signal is a green authority leg with a red format leg naming the files, and the remedy then is one deliberate reformat commit, not a relaxed assert. Nothing here is claimed green until a run says so.
**10-26(15) Rung zero: the goal's own kill criterion fired, and it says distribution comes first**（P1 strategy measurement / 符号 `adoption-measured`、`corpus-ledger-rederived`） — asked whether this repo can be the #1 coding-agent project on GitHub, the answer had to come from `api.github.com` rather than from the repo's own virtues, and it turned out to be a measurement the ladder file had already predicted: *"S = 1.0 with no adoption → honest instrumentation has become a shelter, and the objective's object was the wrong noun."*

- **The measured field** (2026-10-26: stars / forks / sustained stars-per-day since creation): `openclaw` 393 101 / 82 643, `opencode` 222 704 / 29 649 (**408/day**), `claude-code` 153 415 (251/day), `codex` 130 965 (233/day), `cline` 70 860, `goose` 55 732, `aider` 49 756 — against **ocoreai 1 star / 0 forks / 0 open issues / 7 DMG downloads across 3 releases**. The finding is the shape, not the gap: the best sustained growth in the field is ~408/day against a leader at ~393k, so #1 is not reachable on an engineering schedule; it is a distribution event, and each of the top four sits on a machine that manufactures those.
- **What that changes, in order** (each rung falsifiable, all in § *Rung zero*): R0 ship; R1 one release per tag — `v0.1.14` exists on this host while the newest *published* release is `v0.1.13`, so the README's double-click path serves a build 15 days behind `main` (owner's rung: `gh` is not installed here, and no credential was invented); R2 sixty seconds to first token (today's honest path is a minutes-long `swift build -c release` or an ad-hoc-signed DMG plus the Gatekeeper right-click); R3 something to look at — `grep -c '!\[' README.md` returns only the four badges, i.e. no recording, where every top-five agent leads with one, and the capture machinery (`GUI_REQUIRE_PIXELS`, `scripts/e2e-gui-app.sh`) already exists; R4 the wedge (offline Apple silicon, one binary, no API key, native screen/camera/speech, MTP plus ANE constrained decoding — no comparator among 20 combines them, and stated honestly: a *niche* wedge that caps the ceiling); R5 amplification then retention, because 82 643 forks versus our 0 is a community machine, not a code gap.
- **R0 was executed, not planned**: `make push-ready` had been reporting *"8 commit(s) ahead of origin/main — CI has not seen them, so they are unverified"*, which is this project's own definition of an unproven claim. Pushed; the gate now reads `nothing unpushed (origin/main == HEAD)`. Gate that goes red from here: `make push-ready` fails the moment commits sit unverified again, and P15 pins the corpus at its measured value so unaccounted growth fails instead of drifting.
- **The ledger was wrong once and got re-derived**: the first draft of the cap-raising note quoted a pre-round figure and a net delta that had been reasoned rather than measured. Re-summing `git show <ref>:<file> | wc -c` over the 17 corpus files gives **156 885 at `f036fc0` → 158 778 at P17's peak → 157 738 after 1 040 B of repayment → 160 694 with Rung zero** (+3 809 over the round, root itself −6 363), and the note now carries those figures with the command that reproduces them. That is the invariant aimed at the author's own arithmetic: a number nobody re-greps drifts, including last week's, including this session's.
- **Not claimed**: no distribution work is done — no artefact was notarised, no cask opened, no demo recorded, no release published; the wedge is offered as the best available, not as sufficient; star and download counts are a snapshot of one date and are re-read from the API, not mirrored; and the remaining English-default gap is named but unfixed (9 Chinese lines on README's English face, `CHECKPOINT.md` 21.7 % CJK and referenced by nothing).
**10-26(14) Area guides now have a shape, and the shape is checked**（P1 docs contract / 符号 `guide-shape-one-contract`、`corpus-self-funding`） — opencode's 18 guides all open with an ownership line and most end by naming the command that validates that package. Reading them end to end (the owner's lead) showed we had no shape contract at all: of our three guides, one named its verification commands, one named none, and one carried dated stamps the root file forbids.

- **New gate P17** in `scripts/agents-md-contract.sh`: every `Sources/**/AGENTS.md` (and `Tests/**`) must open `# <Area> — <claim>` within 90 bytes; state inside its first 8 lines that the root file governs *and* name a directory it owns; cite at least two gates; carry a `## Verification…` section holding a real `make …` / `swift …` command; and hold zero `MM-DD` stamps. It floors its own scan (3 guides / 27 distinct gate names against floors 3 / 20), so a rotted glob reports failure instead of a vacuous pass, and the run prints `guides area=3 (floor 3) gate-names=27 (floor 20)`.
- **Conformance**: `Sources/ocoreai/UI/AGENTS.md` and `Sources/ocoreai/Handlers/AGENTS.md` gained `## Verification in this subtree` (⌘ discipline and the send path with their pixel-evidence switch; the wire filters plus `make probes`), and two dated stamps left `Sources/ocoreai/Engine/AGENTS.md`. Both directions were exercised: with the sections absent P17 named both files by path, and a first `CMD_RE` that demanded a closing backtick straight after `make test` failed on `make test FILTER='…'` — a command with its arguments is what a reader actually runs, so the regex widened.
- **The contract paid for itself** (`make docs-check`: 157 738 B against the unchanged 157 800 cap — no raise). Repayment came from the debt that cap comment had been carrying: the stale `3180 / 562 in 429 s` CLT numbers, already outlived by the round that wrote them (invariant 1: a number nobody re-greps drifts), and two 10-26 narration blocks whose verdicts `CHANGELOG.md` owns, are now a rule plus a pointer. `docs/agent/closed-items-log.md` is English end to end, per the project's English-default doc rule.
- **Suite parity**: `swift test` on this tree reads `3345 tests in 589 suites … 6 issues`, the same six wall-clock and child-process items as the run before the change — the docs/gate edit moved no verdict. `make docs-check` green, `swift build` exit 0.
- **Not claimed**: no guide's *rules* were rewritten here, only their shape and stamps; P17 governs `Sources/**` and `Tests/**` guides, so `docs/agent/*` may still carry dates (that is where dates belong); and the language rule is still unenforced — `README.md` carries 9 Chinese lines on the English face, `CHECKPOINT.md` is 21.7 % CJK and referenced by nothing, while `AGENTS.md` itself is at 0 %. That contract is the named next item, not done here.

**10-26(13) The wire rules left every session's context — root shed 21 % of itself**（P1 docs structure / 符号 `wire-surface-guide`、`root-shed-6363`） — opencode's AGENTS.md was read end to end on the owner's lead, and the structural fact it exposed is ours: every serious comparator ships a small root plus many area guides, and we shipped the largest root in the field with the fewest guides.

- **The measurement** (`~/references`, bytes of root AGENTS.md / nested guides): `opencode` 14 544 / 18, `hermes-agent` 11 952 / 15, `deepseek-harness` 19 113 / 30, `openclaw` 19 168 / 27, `goose` 6 212 / 2, **ocoreai 30 388 / 2**. Meanwhile 21 % of our root file — `### Wire DTOs` (1 779 B) and `### Endpoint Promises` (4 617 B) — was `Handlers/` + `Router/` + `Models/` detail that every Engine-only and UI-only session paid for, and § Routing already treated those two subsections as *the* guide for that area while pointing down the same file.
- **What moved**: both subsections, verbatim, into `Sources/ocoreai/Handlers/AGENTS.md` (6 949 B against the 16 000 per-guide cap), shaped like the Engine guide — H1 claim, a scope paragraph naming the directories and stating that root still governs, and a written **scope test** for the next rule: *binds only what crosses `/v1/*` → here; binds how code is written anywhere → root.* Root is now **24 025 B** (−6 363 from a 30 388 cap that had zero headroom), so `make docs-budget` can re-pin downward for the first time in this file's recent history.
- **Output that proves it**: `diff` of `git show HEAD:AGENTS.md` lines 111-182 against the guide body reports **exactly two** changed lines — the `###`→`##` promotions — so no rule text was edited, re-ordered or quietly dropped. `make docs-check`: `xrefs §-refs=13 (floor 12) anchors=101 dangling=0`, `budgets root=24025/30388 guides=13`, routing rows 21, `claims=31/31 ok`. `swift build` exit 0 (two doc comments in `Models/` changed wording only).
- **Gate that goes red**: P7 (a guide on disk with no routing row) and P9 (a routing row whose target is not tracked) now cover the new file, and every rule that moved keeps its own gate unchanged — `WireDTOOptionalityTests`(8), `GrammarSchemaRegressionTests`(11), `ToolCallWireContractTests`(19), `StopSequenceDeliveryTests`(13), `SystemInstructionDeliveryTests`(9) and the rest. P12 resolves `§ Endpoint Promises` across root **plus** guides, which is what let 7 cites in 6 files keep pointing at the rules after the move; all 7 were rewritten to name the owning guide, because four of them said "AGENTS.md § …" and would have sent a reader to a section that is no longer there.
- **Not claimed**: nothing was re-argued or consolidated while moving — the diff's two lines are the whole edit. No claim yet about which section moves next (the scope test decides that, and Scheduler / MCP / Tools / Skills / Multimodal / Video / Security still have no guide, § Routing). Root still sits above every comparator root; the remaining candidates are § *Open* (2 710 B) and § *Upstream Audit Dependencies* (2 501 B), and moving those is a judgement about cross-cutting weight, not a mechanical copy.

**10-26(12) A premise the OS cannot meet is a skip now — and five dead tests got their gate back**（P1 gate credibility + P2 honest surfaces / 符号 `macos27-premise-one-home`、`disabled-test-is-a-dead-claim`、`printed-skip-invisible`、`hfmirror-apply-earned-back`） — 10-26(11) left three reds in every local run that were really the platform talking, and named "fail instead of skip" as the next item. It turned out to be three different dishonest shapes, and one of them had five tests quietly dead behind it.

- **The three shapes, all measured in `Tests/`**: `Issue.record("requires macOS 27")` (3 sites) made the OS look like a defect, so one local failure was two verdicts; `print("[COREAI-BUNDLE-DIR] SKIP — requires macOS 27")` never reached the run summary, so work nobody ran read as work that passed; and `.disabled("requires macOS 27 runtime; exercised in CI matrix")` (**5 tests in `CoreAIVisionConfigTests`**) is the worst of the three — it does not revive when the runner moves to macOS 27, so each of those "exact value" assertions was a claim with no gate behind it and no marker in the summary saying so.
- **One home for the premise**: `PlatformPremise.hasMacOS27`, and the working shape is `@Test(…, .enabled(if: PlatformPremise.hasMacOS27))` on a function carrying `@available(macOS 27.0, iOS 27.0, *)`. That pairing is not stylistic: the annotation is what lets the *body* compile against the API at all — deleting the in-body `#available` guard without it fails with `'InferenceEngine' is only available in macOS 27.0 or newer`, which is exactly why the old code had a guard there and paid for it with a fake red. The condition is what skips it. Nine tests across five files moved to this shape; the Xcode-route run now reports **45 skipped** and nothing red is the platform.
- **New gate `PlatformPremiseHonestyTests`(2)**: a floored scan over `Tests/` (root found by searching, comments stripped, floors 300 files and 20 `.enabled(if:)`) that fails on any `.disabled(`, with the scanner itself exempted *by name* and the exemption counted — the same trick `ProcessGlobalLeaseDisciplineTests` uses, so a second exemption goes red instead of hiding inside the rule's own home. Plus an independent check that the predicate agrees with `operatingSystemVersion`. Both red samples were run: a temp `.disabled` suite came back as `… declare its premise with .enabled(if:): Tests/ocoreaiTests/RedSampleDisabledTest.swift`, and hardening the predicate to `return true` came back as `hasMacOS27 said true on OS NSOperatingSystemVersion(majorVersion: 26, …)`. Deleting both returned green.
- **A premise can also be earned back**: `applyWritesResolvedEndpointToProcessEnv` had shipped disabled because it writes the real `HF_ENDPOINT` — the same key `SettingsStoreTests` reads expecting `https://huggingface.co`, so the two could trade places mid-run. The process-global lease from 10-26(11) makes them mutually exclusive *and* restores the key on the way out, so the test runs now and `Tests/` contains **zero** `.disabled(`. The rule that falls out is in the guide: a disabled test is a claim with no gate, and the fix is almost always a premise declared where the test is declared.
- **Numbers** (two full parallel runs of this tree): `3345 tests in 589 suites failed after 12.963 s with 6 issues` and `… 12.648 s with 8 issues`, 45/44 of them skips. From 10-26(11)'s `16.383 s / 10` and `18.776 s / 14`: the platform reds are gone, the run is ~20 % faster because skipped work is not attempted, and the drift is now one family — wall-clock and child-process budgets under full parallelism (`MCPStderrDiagnosisTests` loses a child's stderr 4 issues in *both* runs, so that one is a defect and not flake; `EngineBusyAdmissionTests`, the rate-limit window and one perception-approval case drift in and out).
- **Docs**: `docs/agent/build-gate-reality.md` gains the three-shapes block and the earned-back note (13 845 → 15 321 B, cap 16 000) and its stale "three of its reds are the platform talking" sentence is corrected to "nothing red here is the platform". Root `AGENTS.md` § *Open* now says the gated suites skip; it sits at **exactly** its 30 388-byte ratchet cap, so the next root rule has to pay for itself — stated as debt rather than quietly raising the cap.
- **Not claimed**: these skips prove the OS refuses the work, not that the work passes — macOS 27 behaviour is still unverified here and CI has no macOS 27 leg (§ *Open*, unchanged). The CLT leg was not re-run. `MCPStderrDiagnosisTests` is not called flake here: it reproduces in both runs and is the named next item.

**10-26(11) Every process-global got an owner, and the suite got 8× faster doing it**（P1 determinism + P2 honest failure / 符号 `unleased-workspace-anchor`、`hub-timeout-under-the-lease`、`unreachable-hub-endpoint`、`shared-sensor-self-publish`、`filter-needs-disable-xctest`） — 10-26(10) closed with "the set is not stable between two parallel runs" and a hypothesis about four suites sharing one seeded file. The hypothesis was wrong; both halves of the real cause are now measured, and both have a gate.

- **Retraction first**: no suite shares that file — each seeds its own temp dir and anchors inside it. What actually happened: `ExecCwdContractTests` called `SessionWorkspace.setDirectory(…)` *and* `clear()` with no lease (two sites) while `LoopGuardRemedyTests` held one, so a suite that had set its own anchor resolved against the repo root instead. `.serialized` cannot help here — it orders a suite's *own* tests, never suites against each other. All four unleased mutators now lease (`ExecCwdContractTests`, `DegenerateMarginProbeModeTests`, `ReadyHubDownloaderFlatTests`, and `SettingsStoreTests`'s `withEnvRestore`), and `ProcessGlobalLease.release()` **hands back the value the process came in with** instead of blind `unsetenv`, so a key CI exported survives the suite that borrowed it while a key a test invented does not.
- **Exclusivity exposed a worse bug, and the attribution named it.** The first exclusive run went 122 s → 370 s with 9 reds reading `lease starved after 240.0s — held by freshModelRoot() for 117.0s`. `sample` showed 19 cooperative threads parked on `NSLock.lock`, 4 inside `freshModelRoot(`: a parked cooperative thread starves the pool, so the holder had no thread left to resume on, and the pre-deadline version hung 13 minutes. Two answers — `waitBudget` is 60 s and on expiry *records and proceeds* (a leaked lease becomes a named red, never a silent hang), and the culprit itself: three `ReadyHubDownloaderFlatTests` cases deliberately take the network path, each paying a 122 s connect timeout to a hub this host black-holes **while holding the lock**.
- **The hub is pinned where it cannot be slow.** `HubClient` reads `HF_ENDPOINT` at construction (swift-huggingface `Sources/HuggingFace/Hub/HubClient.swift:116` → `detectHost()` at :189), so the suite leases that key too and pins it to a port that refuses on loopback: the same five tests with the same assertions went **366.022 s → 0.030 s**, and they no longer depend on whether the machine has a network — which is what "hermetic" in that file's own header had always claimed. Same route, full run: **122.1 s → 16.4 s**.
- **A `shared` singleton is the same hazard as an env var.** `SystemContextSensorLiveTests` failed one run and passed the next because `PerceptionEngine.stop()` fires a *detached* `SystemContextSensor.shared.stop()` (`PerceptionEngine.swift:292`) that lands whenever the pool likes. `pollLoop` published to `Self.shared` rather than `self`, so no second instance could be driven at all; it publishes to its own instance now and the suite owns its sensor. Measured both ways: reverting the publish target reproduces `thermal field missing: [system] no context`, restoring it goes green, and neither final run mentions the suite. Shipped behaviour is unchanged — `shared` is the only instance anything starts (`PerceptionEngine.swift:265`).
- **New gate `ProcessGlobalLeaseDisciplineTests`(3)**: a floored scan (319 test files, 15 mutators measured) naming every Tests file that mutates a process-global without a lease. It matches bare `setenv(`/`putenv(`, not `setenv("`, because a key bound to a constant mutates just the same and a literal-only gate teaches people to bind constants; comment lines are stripped so prose names do not count; `ProcessGlobalLease.swift` is the one exemption and the exemption is asserted *by name*, so a second one goes red rather than widening the hole. Red sample actually run: a temp suite calling `setenv(probeKey, …)` → `offenders → ["Tests/ocoreaiTests/RedSampleUnleasedMutator.swift"]`; deleted → green.
- **`--filter` was never broken on the Xcode route — only its XCTest half was.** 10-26(10) recorded `swift test --filter` as unusable (signalled(11) in `swiftpm-xctest-helper`), and that helper is exactly the XCTest half. `swift test --disable-xctest --filter …` runs, so `make test FILTER=<Regex>` is now the fast door — one suite in ~1 s against the CLT route's minutes — and it prints that the XCTest half was not run, because a filtered run that silently drops a target reads as a full green. `make test-clt [FILTER=<Regex>]` still covers both halves.
- **Where the run stands** (two full parallel runs of this tree): `3343 tests in 588 suites failed after 16.383 s with 10 issues`, and `… 18.776 s with 14 issues`. Constant in both: the three macOS-27-gated tests that *fail* rather than skip (§ Open, and the next item) plus three wall-clock budgets; drifting between them: three more wall-clock budgets (`overallMs increases after sleep`, `start captures timer and tracks overall duration`, the MCP hang window). **Zero** `lease starved` records and **zero** victims from 10-26(10)'s red family in either run. The remaining drift is now one thing: a wall-clock assertion has no term for how loaded the host is — named here, not fixed here.
- **Docs**: `docs/agent/build-gate-reality.md` 15 970 → 13 845 B — this round's forensics added, the 10-14 toolchain incident and the metallib-ladder narrative dropped as duplicates of this file and `scripts/resolve-metallib.sh` (one home), and the surviving Chinese blocks anglicised. Root `AGENTS.md` ratcheted 30 388 → 30 383 with the lease rule and the filter door added, paid for by moving duplicated measurement prose into the guides that hold it.
- **Not claimed**: the CLT leg was not re-run this round, so `make test-clt`'s 3180/562-green figure is still 10-26(10)'s; no `xcodebuild` leg, no live probe, no eval scoreboard. Nothing here says the tree is healthy — it says which reds had no owner, and gives them one.

**10-26(10) A test run that never names its shader payload reports neither pass nor fail — and `--filter` was never available on the Xcode route**（P1 gate credibility / 符号 `unnamed-metallib-silent-run`、`filter-xctest-helper-segv`、`metallib-ladder-one-home`、`parallel-workspace-race`） — § *Build / Test / Lint* tells every session `swift test` and `swift test --filter <SuiteRegex>`, so both were run here (macOS 26.6, ambient Xcode SDK 27) instead of assumed.

- **`--filter` never starts on the Xcode route**: `error: signalled(11): …/swiftpm-xctest-helper …/ocoreaiTests.xctest`, twice, deterministic — the weak-linked-CoreAI family `Makefile` § *test-ci* already records for `xcrun xctest`, now pinned for `swift test` too. Unfiltered `swift test` reaches ~4,030 log lines and then dies inside MLX (`Failed to load the default metallib … mlx-c/memory.cpp:69`), exit 1, **with no `Test run with …` line at all**: exit 1 was the only signal, and it says nothing about what failed.
- **One home for the ladder** — `scripts/resolve-metallib.sh`: env override → this scratch's own SwiftPM product → Xcode DerivedData → pip wheel. It prints rung + size on stderr and the path on stdout, canonicalizes (`…/debug/…` and `…/out/Products/Debug/…` are one file, and a log naming both reads as two payloads), refuses anything under 4096 B, says so out loud when the pip wheel wins, and exits 1 naming `xcodebuild -showComponent/-downloadComponent MetalToolchain`. Red sample: `HOME=/tmp/oc-fakehome bash scripts/resolve-metallib.sh /tmp/oc-empty-scratch` → exit 1 + the remedy. Green: both scratches resolve at `swiftpm-product · 2401016 bytes`. `make test-clt`'s inline copy of the ladder and its 12-line rationale moved in; the target keeps only *staging* the winner (a payload inside a signed bundle fails the sign step).
- **`make test` now names the payload before `swift test`**, so the suite finally reports: `Test run with 3340 tests in 587 suites failed after 122.1 s with 12 issues` (an earlier identical run: 10 issues). `make test-clt` on the same tree: `3180 tests in 562 suites passed after 429.036 s`.
- **What that local red is made of** (recorded, not excused): three tests record a *failure* where they mean "platform too old" — `LegacyConstrainedDecodingStrategyTests` ×2 and `CoreAILiveGenerateTests` emit `requires macOS 27 / iOS 27` through `Issue.record`, because `@Test` cannot carry `@available` — so on an SDK-27 host running macOS 26 they fail by construction; that is § *Open*'s CoreAI/macOS-27 family, and it means one red on that route is two verdicts. The rest (`MCPStderrDiagnosisTests` — `childExited(3, stderr: nil)`, so the child's stderr never arrived; `EngineBusyAdmissionTests` `waitedMs 1870` vs a 1000 budget; `ExecCwdContractTests`; `LoopGuardRemedyTests`; an MCP timeout window) pass on the CLT route, and **the set is not stable between two parallel runs**, which is the actual finding.
- **The nondeterminism has a named cause**: `LoopGuardRemedyTests`, `EditLinesContractTests`, `EditMismatchRecoveryTests` and `ClaimVsAuditTests` all create and delete `sum100.py` in the *repo workspace* (they assert on `anchored to <repo root> … no workspace set`, so the cwd anchoring is the contract, not an accident). Parallel execution lets one suite delete another's file; `--no-parallel` — which is what `make test-clt` runs — cannot lose that race. Fixing it means giving each suite its own path without losing the anchor claim, so it is recorded here rather than blind-patched. **Retracted by 10-26(11): each of those suites seeds its own temp dir; the anchor was clobbered by an unleased setter, and it is fixed, not recorded.**
- **Entry points**: `make test-clt FILTER=<Regex>` added, because the only route that can filter had no door (running one suite meant hand-rolling the CLT flags — how a recipe goes wrong). `make -n` shows the flag only when `FILTER` is set; `make test-clt FILTER=UIFocusDisciplineTests` → `Test run with 7 tests in 1 suite passed`; swift-testing filters test **IDs**, so cite a suite type name, not its display text. § *Build / Test / Lint* now lists both, and the bare `swift test --filter` line is gone; `MetalShaderLibrary.swift`'s doc-comment names the script so mechanism and ladder point at each other; the forensics live in `docs/agent/build-gate-reality.md` (per-guide 16 000 B cap paid for by trimming this round's own block; corpus constant raised +2 203, debt still the same two named items).
- **Not claimed**: this entry asserts nothing about whether the tree is healthy — it asserts that one route could not say, and now can. The macOS-27 tests failing-instead-of-skipping is the next item, not fixed here; no `xcodebuild` leg, no live probe, no eval scoreboard this round (CI macos-26 and `make probes` own those).

**10-26(9) ⌘ numbers follow the sidebar now, and the gate derives its expectation instead of copying one**（P1 gate credibility + HIG ⌘-coverage duty / 符号 `cmd-map-sidebar-order`、`scan-matched-a-comment`、`appsettings-comma-undelivered`） — the gate that landed one commit earlier had to be told the truth about the map it pinned, and the two authorities disagreed.

- **The disagreement**: `sidebarSections` renders `AppTab.serverGroup + workflowGroup + systemGroup` = dashboard, chat, projects, models, sessions, skills, system, status, settings; the Navigation menu declared ⌘1–⌘7 = dashboard, chat, models, **status**, sessions, skills, system. So `projects` — the third row, a primary work surface — had **no keyboard route at all**, while `status` took ⌘4 and renders last. **Second finding, smaller and worse**: `CommandGroup(replacing: .appSettings)` *deletes* the system item, so the ⌘, it carried left with it and no line declared it back — the guide had claimed "`Cmd+,` grouped Settings" in prose since it was written, a duty with a group name and no delivery seam.
- **Fix**: ⌘1–⌘8 are the sidebar's own order (dashboard 1, chat 2, projects 3, models 4, sessions 5, skills 6, system 7, status 8), Settings excluded because it owns ⌘, which `Application.swift` now declares itself. Price stated, not hidden: ⌘3 and ⌘4 change meaning and `status` moves to ⌘8, bought with a map where the number is the row and every tab but Settings has a key.
- **The gate got stronger in the same edit** — a literal copied out of the code under test is against § Testing Quality, so `tabNumberingFollowsTheSidebar` derives `expected` from `AppTab`'s groups at runtime (the value the sidebar actually renders): drift on either side fails, and the premise is floored by `Set(sidebar) == Set(AppTab.allCases)` so a tab added to `allCases` but left out of the groups cannot silently shorten the expectation and pass vacuously.
- **The false green that had to happen first** (`scan-matched-a-comment`): the first ⌘, assertion *passed* with the shortcut commented out — a scan over file bytes does not know `//` — and a `#"`-raw pattern ending in `"` loses that quote to the terminator, so the pattern was not the one being read. Both patterns are now anchored to line shape (`\n[ \t]*\.keyboardShortcut…`) and were checked in Python before compiling: live → match, commented → no match.
- **Red samples (run, exit 1, source restored md5-identical)**: R1 comment the ⌘, line → `settingsOwnsItsCommandKey` red; R2 comment `.keyboardShortcut("4")` → map red (models disappears from the scan); R3 reorder `[.dashboard, .chat]` → `[.chat, .dashboard]` → map red *after rebuild*, so the sidebar moving on its own is caught.
- **Verification**: CLT route (SDK 26.5) → `Test run with 7 tests in 1 suite passed`; `swift build --build-tests` exit 0; `make docs-check` green with the corpus at 155575/155597 — 6 bytes *shorter*, because prose no longer has to enumerate keys it can prove; both edited files byte-identical to `swift-format` output.
- **Not claimed**: menu dispatch is pinned at its source seam, not observed in a live window (no GUI session here to host it) ⇒ macos-26 CI owns the runtime verdict; no full-suite run this round, same Xcode-route SEGV as the previous entry; the ⌘-coverage duty in `docs/agent/agent-interface-guidelines.md` still has no user-visible shortcut list — this round fixed the map and its gate, not the discoverability surface.

**10-26(8) The keyboard contract was prose with no reader — and the first reading caught a liar**（P1 gate credibility / 符号 `ui-focus-discipline-gate`、`dead-second-focus-site`、`claim-said-sidebar-order`） — `Sources/ocoreai/UI/AGENTS.md` asserted "⌘ coverage … keyboard ownership follows focus" behind zero tests, and `docs/agent/long-horizon-goal.md` row S named that gap in as many words ("UI focus discipline has no test").

- **The gate** (`Tests/ocoreaiTests/UIFocusDisciplineTests.swift`, 6 tests, scan-based per § Testing Quality): exactly one `.focused($` and one `@FocusState`, both in `Sources/ocoreai/UI/Views/ChatView.swift`; exactly one `NSEvent.addLocalMonitorForEvents` and **zero** `addGlobalMonitorForEvents`; ⌘↵ resend + the `event.characters == "\r"` send path + ⌥⌘M present; `keyCode == 53 && isStreaming { stopStreaming() }` as a regex, so an idle Esc stays with the editor; no `.keyboardShortcut(.defaultAction)` on the composer (the only default action is `Sources/ocoreai/UI/Views/ProjectsView.swift:318`'s modal sheet); the ⌘1–⌘7 map pinned as an exact pair list. Repo root found by searching for `Package.swift` beside `Sources/`, and the scan floors itself at 250 `.swift` files (measured 299).
- **Precondition**: deleted `Sources/ocoreai/UI/Theme/Components/OcoreaiTextInput.swift` — a second `@FocusState`, 45 lines, zero callers anywhere in `Sources`/`Tests`/`scripts`/`docs`. The single-focus-site assertion is unpassable while it exists, so the deletion is what makes the gate sayable, not a tidy-up.
- **Red sample (real, not argued)**: `git checkout HEAD --` that one file → `Expectation failed: focused == […]` and the same for `focusState`, exit 1; delete it again → 6/6 green in 0.57 s. The scan reads sources at runtime, so the sample costs no rebuild.
- **What the gate found immediately, and what this entry therefore does *not* claim**: the ⌘ numbers are `Application.swift`'s declaration order, **not** the sidebar order the prose implied — the sidebar renders `AppTab.serverGroup + workflowGroup + systemGroup` (dashboard, chat, projects, models, sessions, skills, system, status, settings), so `projects` has no key at all while `status` takes ⌘4 and renders last; and `⌘,` for Settings is the *name* of the `CommandGroup`, with no line delivering the key. Both are fixed in the next entry; here the pinned values and the guide line only say what the code does.
- **Verification**: CLT route (`DEVELOPER_DIR=/Library/Developer/CommandLineTools`, SDK 26.5, `--scratch-path .build-clt`) → `Test run with 6 tests in 1 suite passed`; `make docs-check` green (corpus 155581/155597, claims 31/31). The ambient Xcode route cannot execute tests here at all (`swift test --filter` dies in `swiftpm-xctest-helper`, signal 11 — SDK 27 against a macOS 26.6 host, `Makefile` § test-ci note), so no claim of a full-suite run is made this round.
- **Not claimed**: menu dispatch is pinned at its delivery seam in source, not observed in a running window — `make test-ci` on macos-26 owns that; and the byte ratchet moved without repayment, so the corpus constant still carries the same named debt (`docs/agent/build-gate-reality.md`'s dated forensics, the `deepseek-harness` comparator cell).

**10-26(7) 许可证归属的两个真洞：5 个逐字吸收的 Apple BSD-3 文件没带版权声明，而"查权利人"的门因为 `\|` 在本机是字面竖线，从写下那天起匹配数为 0**（P1 许可与发布 / 符号 `bsd3-header-missing`、`literal-pipe-alternation`、`attribution-coverage-gate`、`stale-notice-counts`） — 触发点是上一轮末尾那句"Class-I 还没有已知坏样本自测"。先问"这条正则还活着吗"，答案比预期糟。

- **失效一（alternation 在本机不是 alternation）**：BSD `grep -E` 把 `\|` 当**字面竖线**（实测 `printf 'aaa\nfoo\n' | grep -cE 'aaa\|foo'` ＝ **0**，而 `\?`、`\+` 却被当操作符——同一平台两套脾气）。Class-I 写的是 `"Copyright ?\|uigei@\|Copyright @[[:space:]]*$"` ⇒ 整个"错误权利人"扫描**匹配数恒为 0**；同一写法在 vendored 循环里的 `grep -q "Apple Inc.\|uingei"` 也是死支（该支失效方向偏保守：会把自家头文件也要求进 NOTICES，不是漏检，但那条路一直没工作）。
- **顺藤摸出的实效缺陷**：改完正则后先问"有没有文件**根本不写**权利人"——逐个数下来，`Sources/` 下 **20 个源文件零版权声明**，其中 **5 个首行自陈** `Provenance: coreai-models (BSD-3-clause, Apple) — verbatim, absorbed`：`CoreAIInputEmbeddings.swift`、`CoreAIVisionConfig.swift`、`CoreAIVideoInput.swift`、`CoreAIImagePreprocessor.swift`、`CoreAIImageStrategy.swift`。BSD-3 第 1 条要求源码再分发保留版权声明，而本仓自己的措辞写着"The derived files keep Apple's verbatim header"（`scripts/collect-third-party-licenses.sh:5`）——规矩与代码不一致时代码是事实，本轮改代码。
- **修**：那 5 个补上游**逐字**通知块（`// Copyright 2026 Apple Inc.` ＋ BSD-3 两行，与另 44 个 Apple 衍生文件同形，原有 Provenance 注释一并保留）；另 15 个确属自研（`MediaSpool`、`DiskSpaceGuard`、`TextDiff`、`KVCacheStatus`、`DegenerateTurn`、`PrefixReuseLedger`、`VLMTokenAssembly`、`KVCacheResidency`、`VLMBundleDetector`、`InferenceOutputSequence`、`ChatMediaResolution`、`FileDiffCard`、`OutputSanitizer`、`HFMirrorPolicy`、`CoreAILoggerStub`）补自家 MIT 头。`CoreAILoggerStub.swift` 只镜像上游 `CoreAIShared/Logger/Logger.swift` 的**一条函数签名**、函数体是我们的 no-op，故按自研 MIT 处理并保留签名出处注释——**这是判断，不是逐字复制的证据**，如实标出。
- **数字全部重算，不硬编码**：Apple 衍生 **44→49**、其中点名 `coreai-models` **29→35**、提到 repo 名的文件 **59→60**、"有 Apple 声明但不点名 coreai-models"那批 **15→14**。`docs/agent/third-party-notices.md` 三处过期读数（"all 44 of them (29 name coreai-models)"、"59 files… only 29"、"while 15 BSD-3 files…"）改成实测值，并把两条 `claim:` 下界从 `>=44`/`>=29` 抬到 `>=49`/`>=35`——下界低于真值等于允许 5 个 Apple 头再掉一次而不报红。`THIRD-PARTY-LICENSES/NOTICES.md` 由收集脚本重算后提交（脚本自陈 `apple_derived_files=49 naming_coreai=35`）。
- **新门（扩 Class-I，不是新脚本）**：① 每个 `-e` 分支配一行已知坏样本，先自测再扫（`// Copyright`、`// Copyright ©`、`// Copyright ? 2026`、mojibake `Â©`），任一分支不再匹配即判 dead pattern；② **归属覆盖率**：`Sources/` 下每个 `.swift/.h/.m/.mm/.c/.cpp` 必须含权利人行，本轮扫 **302** 个文件、自带下界 250，并且**计数不是数字就直接判红**——这段新代码第一次跑就自己踩进"计数为空却继续"的坑（`find \( ... \)` 被我写成 `\\(`），正是上一轮给 `check()` 立的那条守卫把它逮住，当场补上。
- **红样（全部实跑，退出码为证）**：RS1 删 `Sources/ocoreai/Engine/MediaSpool.swift` 的头 ⇒ `coverage: 302 shipped source file(s) scanned (floor 250), 1 without a holder line` ＋ `unattributed source ships inside the binary`，exit 1；RS2 塞一行空权利人 `// Copyright ©` ⇒ malformed 扫到并点名该行，exit 1（**同一条输入在修之前是 0 命中**）；RS3 把 Class-J 的检测正则改坏 ⇒ `X dead pattern: … no longer sees a suite claim in a comment`，exit 1（同时 `scan: 0 … (floor 20)` 也报）。三处复原后 exit 0。
- **验证**：`make docs-check` 绿（`claims=31/31`，抬高后的下界照样复现）；`scripts/collect-third-party-licenses.sh` 重跑，产物只改 `NOTICES.md` 的两行计数；全量 `swift test` **3173 tests / 561 suites 绿**（427.961 s，与改前同数）；`make round-gates` 绿。
- **不声称**：`apple.pin` 仍是 `09e7125…`，脚本照旧打印 `drift: mirror HEAD 09ff139050d7 != recorded pin` 并**拒绝自动改钉**（业主手上五问之一，本轮没碰）；5 个文件的 Apple 定性依据是它们**自己的 Provenance 注释**加上游同路径线索，其中 `CoreAIVisionConfig`/`CoreAIImageStrategy` 上游并无同名文件（按注释里的行号区间从 `LanguageConfig.swift`、`CoreAISequentialVLMEngine.swift`、`ImagePreprocessor.swift` 派生），**逐字节复核留作可选项**；`CoreAILoggerStub` 归 MIT 是判断而非证明；本轮未渲染 GUI，"设置里 About 的 Apple 衍生数变成 49"是与 manifest 同源的推论，不是测量。


**10-26(6) 门自己也会烂：Class-D 的正则从第一天起就是坏的，5 条裸路径豁免遮蔽 6,478 行**（P1 门禁可信度 / 符号 `dead-regex-clean-forever`、`exemption-count-pin`、`path-token-blindness`、`hundred-percent-exemption`） — invariant 1 说"停止匹配的扫描必须给自己的命中数设下界"，本轮把这句话反过来对着**执法的门**用了一遍，量出三处真实失效。

- **失效一（恒绿的类）**：`check()` 把 grep 的 stderr 丢进 `/dev/null`，而 Class-D 传进去的正则是 `'URL\\(string:.*!'`（多一个反斜杠）⇒ BSD grep 直接 **`parentheses not balanced`**（退出码 ≥2）⇒ `first_pass` 恒空 ⇒ 这个类从诞生起就没扫过任何东西。同期树里躺着 **3 处** `URL(string: "…")!`，从未被任何门看见：`Sources/ocoreai/UI/Application.swift:337`、`Sources/ocoreai/Core/UpdateCheck.swift:71`、`Sources/ocoreai/Multimodal/NetworkSensor.swift:66`。
- **失效二（100% 豁免率）**：Class-A 空 catch `2 命中 / 2 豁免`、Class-H cacheLimit `1 命中 / 1 豁免`——正是 10-15 重写 Class-B 时写下的那个形状（"whitelist 变成了 scan"），只是当时只修了 B。
- **失效三（裸路径＝整文件的永久豁免）**：旧 `scripts/audit_whitelist.txt` 是"一行一个裸路径"，被**所有**类当 `-F` 子串匹配消费。实测 5 条里 **4 条今天一条命中都不压**（`ModelScopeSearchClient`、`CoreAIStubs`、`StateHandler`、`VideoWriter`；这 4 条本身就遮 1,226 行），而 5 条合计把 **6,478 行**（全树 103,864 行的 6.2%）对 5 个类同时遮掉——今天没藏住缺陷，只是因为今天恰好没有缺陷落进这些文件。
- **修法（一次把三类失效关掉）**：① `check()` 每次运行先答三问——用**同一个 grep** 拿已知坏样本自测正则（不再匹配即判"dead pattern，这个类什么都没扫"）；grep 退出码 ≥2 或有 stderr 一律判红（不再吞）；raw→exempted→violation 每次打印，"0 命中"与"N 命中全豁免"从此长得不一样。② 豁免只留一个家、一种语义：`path-token :: line-shape :: count`，跑任何类之前先用树重算 count，**不符即红**；`count=0` 直接写"没有东西可豁免了，删掉它（没用掉的豁免是一扇装着子弹的门）"；裸路径条目判 malformed。③ `inline whitelist` 这个第二机制删除（两条语义不同的路，迟早有一条漂）。
- **改写而不是放宽**：三处 `URL(string: "https://…")!` 是编译期常量，逐条按 `文件 :: 形状 :: 1` 钉住；门保留的牙是 `URL(string: 变量)!`。把它们改成 Optional 会撞上自家"不给不可能失败的代码加防御性包裹"，所以选择钉住并留理由，而不是把类关掉。
- **红样（全部实跑，退出码为证）**：R1 把双倍转义塞回去 ⇒ `X dead pattern: URL\\(string:.*! no longer matches its own sample`，exit 1；R3 在曾被路径豁免的 `Sources/ocoreai/Engine/EngineInference.swift` 插一行 `.first!` ⇒ `scan: 1 hit(s), 0 exempted -> 1 violation(s)`，exit 1（旧格式下这行会被静默放过）；R4 再加第 4 个 URL 常量 ⇒ Premise 报 `NetworkSensor.swift :: URL\(string: "https:// excuses 2 line(s), the entry says 1`，且**说谎的条目当场失去豁免资格**（Class-D 报 2 violations），exit 1；R5 在 owner 自己的 `Sources/ocoreai/Engine/MLXBridge.swift:159` 之后加第二次 `MLX.Memory.cacheLimit =` ⇒ Class-H `scan: 2 hit(s), 1 exempted -> 1 violation(s)`，exit 1。四处全部复原后 exit 0。
- **验证**：`bash scripts/audit.swift_patterns.sh` 绿，且 5 条豁免逐条重算通过；`make round-gates`、`make docs-check` 绿；调用侧确认用 bash（`Makefile:327`、`.github/workflows/ci.yml:62`），`${PIPESTATUS[0]}` 在 CI 可用。**空过项照实说**：本轮 `git status` 只有 `scripts/audit.swift_patterns.sh` 与 `scripts/audit_whitelist.txt` 两个文件，`Sources/` 一行未动 ⇒ **不重跑全量 `swift test`**，也不声称任何运行时行为变化；grep-stderr 那道守卫在 R1 里没有单独触发（样本自测先返回），它防的是"能过样本却在递归扫描时报错"的另一族，目前没有真实案例，属纵深防御。
- **不声称**：这不证明其余类都活着——Class-K 有 perl 自检、Class-B 有文件数下界，而 **Class-I 与 Class-J 仍没有"已知坏样本"自测**，是下一项；也不证明 `Sources/` 之外（scripts、docs 里那些被文档引用的正则）没有同形坏码；count 逐条核对会在无关提交里要求重新钉数字，这是刻意的摩擦，但摩擦成本本轮未量化。`coreai-models` base 差 8 个提交、无工具轮次中断归属、`%2F`、四张 faces 终词、CHANGELOG 是否切分，仍在业主手上。


**10-26(5) `ModelMemoryInfo.swift` 130 行零构造点——一个事实的第三套解析器，而被钉住的恰好是死的那一套**（P1 门禁可信度 / 符号 `dead-type-with-live-duplicate-pin`、`unconsumed-metadata-heuristics`） — 触发点是上一轮：修 emoji 时读到 `displayLabel` 零调用者，于是把整个类型 grep 了一遍。穷尽证据：全仓 `rg 'ModelMemoryInfo'`（排除 `.build*`）只剩自身 8 处 + `Tests` 里 2 条断言；`AGENTS.md`、`ARCHITECTURE.md`、`README.md`、`docs/`、`scripts/audit_whitelist.txt`、`ASSETS.json` 均无它。

- **代价不是 130 行，是假绿**：`Tests/ocoreaiTests/VLMCapabilityTruthTests.swift:82`、`:89` 各钉两次"读 `vlm` 而不是 `specialized`"（10-12 那轮修的 wire 谎报），其中一半钉在 `ModelMemoryInfo.fromListModels`，而产品路径只走另一半：`Sources/ocoreai/UI/ViewModels/ModelManager.swift:367` → `ModelID.fromListModels`（`ModelID` 定义在 `Sources/ocoreai/UI/ViewModels/ModelsViewModel.swift:11`）。断言看起来在守两套，实际有一条永远守着一个不会被任何产品代码构造的类型——正是 vllm `tests/AGENTS.md` 第 1 条的反面：看着守住了，那半什么都没守。
- **同时清掉三段没有消费者的启发式**：`inferMetadata()` 从模型名字符串猜 `~70B`/`4-bit`、`memoryString` 报 GB、`modalities` 填 `["vision", "language"]`。**如实区分**：这些猜测从没被写进 wire 或界面（`rg '"quantization"|param_count|"params"' Sources/ocoreai/Handlers Sources/ocoreai/Router Sources/ocoreai/Engine/EnginePool.swift` 为空），所以它是"空转的机器"，不是 invariant 2 意义上的对外谎报——我们没吹过这些数字，只是留了一台没人按的机器。
- **处理**：删 `Sources/ocoreai/Models/ModelMemoryInfo.swift`；`VLMWireParseTests` 两条断言改成只钉 live parser，注释写明"UI 侧解析该事实只有这一处（`ModelManager` 经它刷新列表）"。不新增门：同一谓词另有 `Tests/ocoreaiTests/PipelineCoverageTests.swift:521-547` 三条在钉（`specialized` 单独出现不得判 VLM、两键并存以 `vlm` 为准、缺省不为真）。
- **为什么不救活它**：要它当 UI 的模型元数据，得先有"今天的消费者"；`ModelID` 已经在做同一件事，再接一遍就是"一个事实两套"，正是 § Working here"one home per decision"要防的。**记为后续的**不是接活，而是落位：live 的 `ModelID` 住在 `Sources/ocoreai/UI/ViewModels/ModelsViewModel.swift:11`，而 `Sources/ocoreai/Models/` 这个目录名会让人以为模型元数据归 Models 层——§ Naming 已承认"target 名 ≠ 模块边界"，此处照实记一笔，不在本轮搬家。
- **验证**：`swift build` exit 0（90.10 s，`ocoreai-product` 链接完成）；全量 `swift test` **3173 tests / 561 suites 绿**（428.501 s，删断言不减 test 数：两条 `@Test` 仍在，只是各少一次 `#expect`）；`make round-gates`、`make docs-check` 绿。**空过项照实说**：删除一个编译期零引用的类型，理论上不可能引起运行时回归，这一轮的全量重跑属自证而非判别；真正判别的只有"编译通过 ＋ `VLMWireParseTests`/`PipelineCoverageTests` 仍绿"。
- **不声称**：这不代表 `Sources/` 里再没有别的零构造点类型——本轮只查了 `ModelMemoryInfo` 一个；把"零构造点扫描"做成门是候选（要能区分"反射/字符串引用"与真死码，误报代价高），不是已有；`ModelID` 的落位不动；`coreai-models` base 差 8 个提交、无工具轮次中断归属、`%2F`、四张 faces 终词、CHANGELOG 是否切分，仍在业主手上。


**10-26(4) references 的"演进"读数：AGENTS.md 的年龄按产品种类分层，不按代码量；顺手把自家界面上的彩色 emoji 修掉并钉住**（P2 界面诚实 / 符号 `pictograph-not-icon`、`agents-md-age-tracks-product-kind`、`single-file-injection-tax`、`stale-file-count-298`） — 业主问"references 每个项目的 AGENTS.md 都学以致用了？"，先给可核对的数：`~/references` 20 个克隆、16 个有 `AGENTS.md`、共 116 份 672217 B；真正进过代码的是三处（vllm `tests/AGENTS.md` 三条防作弊尺、Strata 的 `launch --plan`、opencode `e5074f8`）。这轮把"演进"变成三个可复跑的测量，只读本地 `git log`（20 个克隆逐一确认 `.git/shallow` 不存在 ⇒ 首提交日期可当事实用，不是镜像残片）：

- **读数一（年龄分层）**：把"首次出现 `AGENTS.md` 的日期占项目寿命的比例 + 当前份数 + 近 90 天改动次数"放在一起，分层按**产品种类**而不是代码量。有 GUI/agent 面的：deepseek-harness +0 d（30 份，近 90 d 改 371 次）、openclaw +0 d（27/359）、Strata +7 d（4/16）、codex +24 d（2/6）、opencode +73 d（18/94）、pi +97 d（1/13）、hermes-agent +195 d（15/289）、goose +377 d（2/11）。纯推理/服务库把指令层留到寿命末尾且此后几乎不动：ollama +1080 d＝88%（1 份，近 90 d **0** 次）、vllm +1127 d＝83%（8/13）、sglang +923 d＝83%（1/1）、mlx-swift-lm +916 d＝94%（1/1）、vllm-metal +298 d＝94%（1/4）。MTPLX、coreai-models、splash 从未有过。⇒ 结论：指令层的年龄标记的是"有没有 agent/GUI 面"，与规模无关；我们是 App，`AGENTS.md` 是必须与代码同改的产品面，而那几个推理库的结构是晚期补票，不该当模板抄。
- **读数二（单文件注入税）**：mlx-serve 一份 `AGENTS.md` **121855 B**、近 90 天改 107 次；codex 2 份共 **3285 B**。两个都活跃的 Apple-silicon 推理项目，注入字节差 37 倍。这正是 root 的 shrink-only ratchet ＋ 分区域 guide（root 30124、每份 ≤16000）在防的形状，也证明"份数多"不是负担、"单文件包打天下"才是。
- **读数三（晚期资金流向）**：把每个克隆的提交标题按前 1/3 与后 1/3 分组数主题词。上升：openclaw steer/interrupt **75→636（x8.38）**、ui 1592→6602（x4.15）；opencode streaming x3.45、test/eval x3.29、steer x2.94；codex packaging x2.67、gui-agent x2.53、subagent/skill x1.99；ollama quant x32.4、kv/prefix x11.5、tool-wire x5.33。下降：hermes-agent subagent/skill 905→427（x0.47）、tool-wire x0.38；sglang tool-wire x0.27、mcp x0.06。三条可用推论：(a) 中途插话是最大 agent 项目晚期最热也最贵的轴，正对我们 § Open 那条"无工具调用的轮次打不断"；(b) 引擎类项目晚期仍在 KV/量化工具链上交学费，佐证"KV 复用是正确性面不是性能面"；(c) subagent/skill 存在"早期过度投资→后期回落"的实测形状，我们已在这条轴上收敛，不追加。
- **抄规则而不是抄结构**：彩色 emoji 不是图标，上游三家白纸黑字——`pi/AGENTS.md:6` "No emojis in commits, issues, PR comments, or code"、`sglang/docs/AGENTS.md:281` "No decorative formatting or emoji"、`opencode/packages/gui-extensions/AGENTS.md:13` 把 icon 字段统一收进 named catalog 而非自由文本。我们的规矩是"可见面以 HIG 为权威"（§ Upstream 5）却从没把这条写下来。首跑自家扫描量到的违约（全部用户可见）：搜索结果行把彩色闪电摆在 MLX 前、star 数摆在彩色星星后（`Sources/ocoreai/UI/Views/ModelView.swift:179`、`:226`）；插话气泡整个标记是一枚彩色 pictograph（`Sources/ocoreai/UI/ViewModels/ChatViewModel.swift:186`）；引擎日志里 🔄/✅/⚠️。另抓到一条**过期注释**：`ChatViewModel.swift:325` 声称通道徽章是 ⚡GPU/🧠ANE/💻CPU，而 `Sources/ocoreai/UI/Views/ChatView.swift:1602` 明写徽章用 GPU/ANE/CPU 纯文本——注释在描述界面上不存在的东西。
- **改法**：彩色 pictograph 退出字符串；文本呈现的记号留着（U+2193 ↓、U+2605 ★、U+00B7 · 单色，随字号与强调色走，Dark Mode/Dynamic Type 下仍可读）；`Sources/ocoreai/Security/SentimentAnalyzer.swift:77-80` 的 emoji 是**被分类的数据**，保留并显式豁免。
- **门**：`scripts/audit.swift_patterns.sh` 新增 Class-K（扩既有门，不是新脚本）。用随 macOS 自带的 perl 扫 `\p{Emoji_Presentation}|\x{FE0F}`——`grep -E` 没有 Unicode 属性类，而手抄字节表正是那种会悄悄不再匹配的正则。三道自检：同一表达式必须先命中两枚已知 pictograph（★ 与 U+FE0F），perl 太旧即红；扫描文件数下界 250（现 300），源码树搬家即红；豁免条目必须仍指向存在的文件，否则按"死豁免＝装载好的沉默"判红。
- **验证**：`swift test` 全量 **3173 tests / 561 suites 绿**（428.664 s，与改前同数——既没加也没删测试）；`make round-gates`、`make docs-check` 绿。端到端红样：把 `ModelView.swift` 还原成修复前 ⇒ 门 **exit 1** 并列出 `:179`、`:226` 两行；放回 ⇒ exit 0。**空过项照实说**：perl probe 2/2 与 `K_MIN_FILES=250` 在这一轮恒绿，属前提检查，不判别 emoji 回归；真正判别回归的只有那两行命中，所以红样必须换真文件——改常量造不出红。
- **顺手修一条漂移的文档数字**：`Sources/ocoreai/UI/AGENTS.md` 写着 "across 298 Swift files in `Sources/`"，实测 `find Sources -name '*.swift' | wc -l` ＝ **300**，正是 invariant 1 说的"没人再 grep 的文档数字会漂"。改成不随文件数变的措辞，新规矩那 151 B 由这次删除自付：corpus **155375/155386**（仅余 11 B）（root 30124/30388 不变）。
- **不声称**：插话气泡标记会被持久化并在下一轮作为历史回放，模型确实少看见一个标点、多看见另一个，**未做推理 A/B**，不声称生成结果不变；`Image(systemName:)` 的完整改造**没做**——`ModelResultRow(sub: String)` 装不下 `Image`，要动 row API，如实记为后续；豁免只对 `SentimentAnalyzer` 一个文件生效，不等于 emoji 从此合法；上面所有 references 数字是本机克隆的 `git log` 读数，能证明内容与相对次序，不能证明任何项目的 HEAD 或 GA 日期；主题计数是提交标题关键词匹配，是代理指标不是路线图；`coreai-models` base 差 8 个提交、无工具轮次的中断归属、`%2F`、四张 faces 的终词仍在业主手上。


**10-26(3) 拿 vllm 的 `tests/AGENTS.md` 当尺子量自己，量出三个真缺陷；顺手把 Strata 的 `--plan` 落成 `dryRun`**（P1 正确性 / 磁盘与下载守卫，符号 `volume-enoent-blindness`、`empty-pattern-certified-everything`、`while-let-comma-truncates-walk`、`download-plan-dryrun`） — 业主问"references 里每个项目的 AGENTS.md 都学以致用了？"，先把答案变成可核对的数字：`~/references` 20 个克隆、16 个有 `AGENTS.md`、共 116 份；我们真正**借进代码**的只有 opencode 一份（`e5074f8` 两条规矩），Strata 上一轮只是**记下了**它擅长什么。所以这轮不读全部 116 份（那是往注入预算里倒别人的上下文），只挑一把最尖的尺：`vllm/tests/AGENTS.md` **2432 B / 5 条**，每条都能执行——第 5 条"CI 里没有步骤选中的测试看起来像通过"、第 3 条"不许靠 skip/放宽/删测买绿"、第 1 条"只断言没抛异常的测试什么都没守住"、第 4 条"绝不用固定 sleep 同步"。

- **缺陷一（守卫空转，P1）**：`DiskSpaceGuard.freeBytes(onVolumeHosting:)` 问的是还不存在的模型目录，`attributesOfFileSystem` 走 `statfs` 要解析路径 ⇒ 抛 ENOENT（两行 swift 脚本实测：`statfs THREW: NSError … no such file`），`decision` 按 invariant 把 unknown 判成放行 ⇒ **首次下载从来没被磁盘守卫挡过**，而这恰好是磁盘守卫唯一的存在理由。修根：向上找到第一个存在的祖先再定价（磁盘余量是卷的属性，卷永远问得出来）；并把**能报告的三态**从**只负责放行**的两态里拆出来——`DiskSpaceGuard.verdict` 在任一侧未知时返回 nil：未知既不声称合身，也不声称拒绝。
- **缺陷二（空模式被当成"已满足"，P1）**：HF 这条 `POST /v1/models/download` 传 `matching: []`，而 `allPatternsSatisfied` 对空模式返回 true，注释还写着"调用方总会传非空"。`swift-huggingface` 那边 `[]` 的意思是**整个仓库**，于是平铺目录里任何一个残留文件都能冒充完整模型：端点回 `completed`、权重一个字节没取。修：把"一个模型需要哪些文件"收进唯一的家 `ModelStore.modelDownloadPatterns`（与上游 `modelDownloadPatterns` 同一集合，`Libraries/MLXLMCommon/ModelFactory.swift:8`；上游是 `package` 作用域看不见，故本地重定义并注明），HF/ModelScope/dry-run 三条路共用它；谓词本身改成"证明不了就不声称"（空模式 → false）。
- **缺陷三（我自己这轮的扫描，以及引擎里的同形错误，P2）**：`while let url = it.nextObject() as? URL, url.pathExtension == "swift"` 里的逗号是 **AND**，第一个非 swift 条目直接**终止**枚举，于是扫描看见 0 个文件也照样"通过"。同一形状在 `MLXBridge.allPatternsSatisfied`：模型目录里出现子目录时，其后的必需文件看不见 ⇒ 白下一遍（与 10-22 记过的 3.5 GiB 重下同一族）。两处都改成 `guard … else { continue }`。**这条是被扫描自己的下界门抓住的**（`sawMatchingArg >= 4` 红），所以"扫描必须给自己的命中数设下界"不是口号。
- **落地的借鉴**：`dryRun: true` 回答一次 `plan` 事件（`DownloadPlan`：model/provider/requiredBytes/remoteTotalBytes/cachedBytes/freeBytes/wouldFit/basis），不取字节、不写盘；数字来自新 `DiskSpaceGuard.assess`，而 `ensureFits` 现在只是它上面的一层拦截 ⇒ 预演和真实下载**同一套装配**，不会各说一套。`basis` 明说数字从哪来：`measured` / `locallySatisfied`（"全都在本地"时 requiredBytes 就是 0，这是从缓存证明的，不是猜的）。
- **验证**：新增 `DownloadPlanTests`(17)、`DiskSpaceGuardTests` 22→25（三条专钉卷解析），`WireDTOOptionalityTests`(8) 里两条扩到 `dryRun`（缺 key 默认 false、显式 true 照收）；定向 **62/13 绿**。红样（同时撤回三处修复）＝**4 测 5 断言**红：`Tests/ocoreaiTests/DiskSpaceGuardTests.swift:248`（`viaAbsent != nil`）、`:262`（`free != nil`）、`:264`（`decision == false`）、`Tests/ocoreaiTests/DownloadPlanTests.swift:95`（空模式）、`:257`（扫描下界）。**空过项照实说**：那一次 `offenders == []` 是空过的（扫描本身失效），正是下界把它抓住；`unreadablePathIsNilNotZero`（`/` 可读）无论修没修都绿，属前提检查、不属判别断言。活体探针 `scripts/probes/36-download-plan-dry-run.sh` **17 条全绿**：本地 stub hub 供三个尺寸，要求 `remoteTotalBytes == requiredBytes == 1000150`；404 的仓库必须既不报字节也不报合身；种满之后必须 `requiredBytes 0` + `basis locallySatisfied` + `cachedBytes 1000150`；`../../etc/passwd` 必须在问枢纽之前就被拒（不是绕过 probe 20 的后门）。
- **字节自付**：`probe-index 36/36`，corpus **155232/155386**——新索引条目 +430 B 由删除抵掉：`docs/agent/comparator-repos.md` 里与 `AGENTS.md` § Upstream 6 及该文件"如何用"重复的推论句、"如何用"两节压缩，同时修掉两处**已过期断言**：openclaw 早已读过（`a11e396`）却仍写着 designated but unread；TensorFold 那行写着"它发 runbook/release-notes 而我们没有"，而 `CHANGELOG.md` 版本段 + `scripts/release-artifact-check.sh` + `scripts/verify-installed-release.sh` 就是我们的（v0.1.2…v0.1.14 有 tag）。
- **同一把尺的其余读数（只记数字，不动文件）**：`Tests/` 里 `.skip(`、`XCTSkip` **0 处**（没有买绿）；`Task.sleep` **38 处**，其中 **24 处** ±8 行内没有 while/deadline/timeout，即固定 sleep 同步的嫌疑，最长 `Tests/ocoreaiTests/ReasoningChannelTests.swift:98` 的 1100 ms；`#expect(throws: Never…)` **2 处**；测试函数里的提前返回 `else { return }` **116 处**（静默通过候选，得逐条分类再动）；`scripts/verify-installed-release.sh:120,125` 的 `launch && sleep 35` 属同一族。第 5 条（测试得被 CI 选中）读 `Makefile:231` 是 `build-for-testing → xctest` 全量，未见 filter 掉套件——**这一条只读到 Makefile 与 workflow 文本，未跑 CI**。
- **不声称**：`dryRun` 只证明"写字节之前问得到字节"，不证明磁盘守卫从此不会误挡真下载（那要一台接近满盘的机器复现拒绝）；`matching: []` 的任务级后果（半空目录冒充完整模型）只有门与探针证据，没有用户侧案例；子目录回归测 `subdirectoryDoesNotTruncateTheWalk` 只在枚举把子目录排在前面时才判别，顺序不受契约保证，如实标注而不是装作恒红；那 24 处固定 sleep **一处未动**——没有一条被证明造成 flake，按"没人观察到的失败不写守卫"同一条规矩，没观察到的 flake 也不即兴重写；`coreai-models` base 差 8 个提交、无工具轮次的中断归属、`%2F`、四张 faces 的终词仍在业主手上。

**10-26(2) 对照记录里 Strata 那格只写了"有哪些文件",没写"它擅长什么"——按该文件自己的标题重写,并记下两个可借机制**（P2 对照证据 / 符号 `strata-mechanisms`） — `docs/agent/comparator-repos.md` 的标题是 *who is good at what*,而 Strata 行原来是一串路径(`apps/host`、`metal/`、`bench/`、四个 docs 文件名)。本轮实测这个克隆:4196 次提交里 **2337 次发生在最近 14 天**,可见作者 5 位;C++ 引擎带 CUDA/HIP/SYCL/Metal 后端(`src/`、`metal/` 26 个 `.metal`、`sycl/`、97 个 `.cu`),`serve/` 提供 OpenAI/Anthropic 兼容 API,桌面端是 Tauri + Node host,另有 `strata_cli/`、`strata_control/` 这套**给 agent 用的终端**;测试密度 2072 个 `def test_` + 299 个 JS `it(`,CI 有 8 条 workflow(含 `metal-build.yml`)。

- **真正可借的两条**:① `strata launch --plan` 把一次几十 GB 的变更先摊开(模型、量化、每块卡怎么放、要下多少字节、已就绪时为 0)然后**原地不动退出**(`docs/TERMINAL_LAUNCH.md:110`,行号已核);② 引擎包带 manifest,`strata_control/engine_component.py` **在引擎启动前**读并校验(`packaging/ENGINE-COMPONENT.md`),发布通道签名、本地构建可未签名加载;另有一条分发思路值得记:Windows/Linux 安装器不带引擎,首启按实际 GPU 取,macOS dmg 内置小 Metal 引擎。
- **我们的相对位置(实测,不吹)**:他们把协议写成文档(`BENCHMARK_PROTOCOL.md`、`COMMUNITY_BENCHMARKS.md`),我们把它写成会红的门——`scripts/eval/_conditions.py` 给每个分数附条件摘要、`_repeat_stats.py` 对条件不同的两次跑拒绝求平均,`docs-check` 复现 31 条 claim 并给自己的扫描设下界,`ClaimVsAudit` 拿一轮的最后一句话对写盘账记。他们的节奏与硬件矩阵远在我们之上;我们的"声称必须配门"在他们那边没有对应机制(其 AGENTS.md 把版本号写在散文里,当下与 `apps/*/package.json` 一致=0.2.6,但没有任何东西保证它继续一致)。
- **字节自付**:该格 1614→534 B(长版先写过一版,按规矩砍回),文件净 **−1180 B**,corpus **155170/155386**(比本轮开始时多 147 B 余量);头部三条把 P16 与 pin 的复述删掉(理由的唯一家在 `scripts/agents-md-contract.sh`)。**不声称**:两个 Borrow 仍是 **open**,没有落成代码。

**10-26(1) 上一轮我修的 no-op 拒词自己造了新的自相矛盾:它叫模型"再读一遍",而复读墙把那一读拦下了**（P1 Agent 可靠性 / 工具语义,符号 `no-change-quotes-lines`） — 证据是上一轮那笔改动**之后**的实跑 `/tmp/abN2/response-make-two-tests-pass.json`,逐次参数摊开:`edit_lines` 三次答 `OK-no-change … If you meant to change them, send the text you want, or read the file again and edit the line that differs.`,模型照做去 `read_file`,第三次同身份复读撞墙 `Execution loop detected: read_file … called 4 times in 60 s`,任务 FAIL。也就是说 `10-25(27)` 把"参数错误"改成了诚实的状态答案,却**在同一个答案里下了一道另一个机制必然拒绝的命令**——正是上一轮刚删掉的 `retryBeforeAnswering` 那一类毛病,我自己又犯了一次。

- **改法:状态随答案走,不再命令往返。** `OK-no-change` 现在把**调用方指名的那几行原文**按 `read_file` 的 `N|` 编号交出来:`edit_lines: OK-no-change — lines 10-10 already read exactly as newText; the file is unchanged (14 lines). The file currently says: 10|    def test_whisper(self): … To change them, send newText that differs from the lines quoted above.`。落点是新 helper `FileTools.currentLinesNote(lines:start:end:)`:任何形状的范围(含"末尾追加位"和 `end = start-1` 的插入位)都至少报出它贴着的那一行;超过 12 行只报头部并如实写 `(+N more lines not quoted)`,单行超 200 字符截断加 `...`。同时**删掉**"read the file again"这句。
- **顺手用上一轮刚写进 `AGENTS.md:353` 的规矩清自己的码**:`currentLinesNote` 初版有个 `guard lo <= hi else` 分支,而 `lo = max(1, min(start, count))`、`hi = min(max(end, lo), count)` 在"文件非空"(上面已 guard)下恒成立 ⇒ 那是**无人观察到的失败**的死码,删除并注明为何恒成立。
- **同类句子的裁决(逐一核对,不是一切)**:`FileTools.swift:296` 的 `oldString is not in this file — read_file it and copy the exact text` **不动**——它处在 `hint.quotedWholeFile == false` 分支,目标行可能压根没进视野,叫读是正当出路(既有测试 `clippedHintStatesTotals` 正是为此禁止"照上面那行改");`ClaimVsAudit.swift:289` 的 `re-read the file before redoing the work` **不动**,因为本轮没有证据显示它把任务带进死循环,而为假想的矛盾改措辞正是新规矩禁止的那类机器。
- **门**:`EditLinesContractTests`(10)(`docs/agent/agent-interface-guidelines.md:27` 已同步 9→10)。新断言:单行范围报 `currently says: 1|a 2|b`;新增第 10 条 `noOpAtAppendPositionQuotesTheTail`——追加位 no-op 报 `currently says: 3|c`;两条都断言**不得**出现 `read the file`(反自相矛盾钉,和 `wholeFileQuoteOrdersTheRetry`/`clippedHintStatesTotals` 同族);另保持 no-change 结果不得出现 `read-back`/`bytes`(没落盘就不许声称验证)。红样实测:撤引文 + 恢复旧尾句 ⇒ **恰好 2 测 4 断言红**(`EditLinesContractTests.swift:161/162/180/181`),还原后 10/1 绿;定向 83 测/12 套绿(上一态 82/12,+1 即新测试)。
- **不声称**:`OK-no-change` 报出原文是否足以让 `make-two-tests-pass` 变 PASS **未证明**——那题真正的死因是小模型给出的"修复"本身就是 no-op(它不知道要改什么),工具能做的只是把状态一次交够、并停止把它往墙上赶;改善与否等同一题集的 A/B 两腿数字,不拿单轮总分当改善。

**10-25(28) 从 opencode 的 AGENTS.md 借两条规矩进来,并且让它们自付字节**（P2 注入契约 / 符号 `agents-md-opencode-rules`） — 业主点名参考 `~/references/opencode`。对照量到的事实:opencode 根 `AGENTS.md` **14002 B / 189 行**,全篇祈使句 + 落点 + 命令,**零日期、零事故叙述**;它有 18 份 AGENTS.md,多数 1–5 KB,最大一份 19 KB(`packages/gui-extensions/AGENTS.md`)。我们根文件 **30124 B**,`## Code Conventions` 一节 **10112 B(34%)**,90 条顶层 bullet 里 **20 条超过 3 行**——违反它自己写的"root rule ≤3 lines",而 `docs-check` 扫的是别的形状(单行 ≤400 B、corpus 总量),**门与规矩不同形这条仍未解**。

- **借来的两条(已落地)**:① `AGENTS.md:353` **no guard for a failure nobody observed**——值在拥有它的边界处校验一次、向内只传已定型的值;写任何 race/edge 守卫之前,必须先能引用它要防的那个失败(probe 行、红测、记分板行),引用不出来就先问,而不是先写。正打我们的历史:`maxZeroGainStrikes = 8` 那类"机制先于证据",以及 § Open 里 1024 B/token 的猜测常数。② `AGENTS.md:200` exact value 必须是**调用方可观测的量**(wire 字段、文件字节、退出码),**不得钉从被测代码抄出来的常量**——抄来的常量只是复述生产,生产一动它就漂(P11 那五次编号漂移同因)。
- **借法是替换不是追加**:本轮 root **30159 → 30124 B**、corpus **155351 → 155316 B**,两条规矩共 +283 B,由八处复述抵掉——§ Build/Test 的沙箱环境变量明细(`docs/agent/build-gate-reality.md` 已覆盖,本轮 grep 到仍在)、invariant 2 的 echo 枚举措辞、`MetalShaderLibrary` 句、file-lifetime 句、`ClaimVsAudit` 叙述、*the three questions* 的重复展开、两条 Read-on-demand gloss。删掉的每一句都另有可查的名字,没有丢任何未记录的事实。
- **不采纳**:opencode 把分支命名、conventional commit、skip-worktree 判据、"默认并发 10 个子代理"写进注入文件——我们直推 `main`、业主逐条 review、默认不开子代理,这些规矩对我们是负价值。opencode 短是因为细节全在 18 份子指南;我们 34% 的注入预算花在"每条规矩后面挂一段论证",一次能腾出 ~1.5 KB 的动作是把 § Endpoint Promises 的论证搬去 `docs/agent/` 新落点,但那会改写"agent 默认往哪儿看",**留给业主拍板**,不擅自搬。
- **验证**:`make round-gates` 绿;root 30124/30388、corpus 155316/155386、`§`-refs 14、anchors 95、dangling 0、walls 0、claims 31/31。**不声称**:进文件 ≠ 行为改变;这两条要等下一轮出现"先引用失败才写守卫""测试不再钉生产常量"的实际提交才算生效。

**10-25(27) `edit_lines` 的越界行号从"拒绝 + 命令重试"改为夹紧到唯一合法边界，偏离写进同一个结果；真正的 no-op 不再当参数错误**（P1 Agent 可靠性 / 工具语义，符号 `edit-lines-clamp`） — 证据在记分板存档 `/tmp/eval-loop-fresh`：`make-third-test-pass` 连吃 **6 次**逐字相同的 `start_line 14 is outside 1...11`，每次都带 "Retry this call now … Do not answer the user before that retry."，结果零写盘、FAIL；`make-two-tests-pass` 连吃 **4 次** `already read as newText (no-op)`。**逐字核对推翻了上一轮的转述**：那 6 次不是逐字重复调用（模型每轮换 `new_text`，只把 `start_line` 钉在 14），所以 `maxHistoryDepth=3` 的循环网与 strikes 阶梯**在结构上看不见这条循环**——任何按"同一调用重复 N 次"设计的门都拦不住它。能被唯一确定的事是：`start_line > total+1` 只有一个合法读法（接在文件末尾），`< 1` 只能是顶部，而原来的句子自己就写着 "11 appends at end of file"。

- **改法：把唯一合法解执行掉，让模型不必算行数。** 夹紧 `start_line` 到 `[1, total+1]`、`end_line` 到 `[start-1, total]`，返回串带 `clamped: start_line 14 -> 11, end_line 15 -> 10; stats3.py has 10 lines, now 13`（invariant 2：判定与结果同行）。真正的 no-op（`new_text` 与目标行逐字相同）从 `invalidParameter` 改为 **`OK-no-change — lines 1-2 already read exactly as newText; the file is unchanged (3 lines).`**，并按同一 invariant **不声称** read-back/bytes（这条路没有落盘）。`edit_lines` 的 schema 描述同步写出这两条，surface 不再声称"越界必拒"；随两处 guard 一起删掉 `retryBeforeAnswering`——它命令的正是那条被证明徒劳的重试。
- **门**：`EditLinesContractTests`(9)（`docs/agent/agent-interface-guidelines.md:27` 的 `(8)` 已同步为 `(9)`）新增/改写 3 条精确断言：夹到末尾（`inserted 1 line(s) before line 4 of 3` + `now 4` + 落盘内容逐字相等）、夹到顶部（`start_line 0 -> 1`，内容 `top\na\nb\nc\n`）、no-op 报状态且**不得**出现 `read-back`/`bytes`。红样实测：删 `clampedNote` + 让 no-op 谎称已验证 ⇒ **3 测 4 断言红**（`EditLinesContractTests.swift:129/130/144/162`），还原后 9/1 绿。全量 `swift test` **3152 tests / 559 suites** 通过（427.9 s，上一态 3151/559，+1 即新测试），定向 82 测/12 套绿；`make round-gates` 绿。
- **行为配对（条件不同，不与旧记录平均）**：`tasks-loop.json+37aca1889741`、model `mlx-community/gemma-4-e2b-it-4bit`、temp 0、approval auto、concurrency 1、Darwin 25.6.0 arm64。旧记录（HEAD 态，tools 摘要 `0ad61eed0ea0`）同题集 **4/12**；新代码两轮 **4/12**、**5/12**——schema 变了所以 tools 摘要必然不同（`_repeat_stats.py` 会拒绝把两者平均），故只报数不判改善。
- **不声称**：① 夹紧是否让 `make-third-test-pass` / `make-two-tests-pass` 变 PASS **未证明**——新态两轮里越界模式一次都没重现（`clamped` 出现 0 次），题死的不是这道墙；② 小模型会不会把"追加到末尾"当成"插到第 14 行"的正确答案，未验证；③ 夹紧之外没有加任何阈值门，因为已证这条循环按调用身份数不出来。**新证据指向下一处**：新态两轮 `make-*` 的失败全部换成 `Execution loop detected: read_file … called 4 times in 60 s`（4 处），即**改文件失败之后想再看一眼**被拦——`loopIdentity` 只折 `(size, mtime)`，而失败的编辑不落盘，mtime 不动，于是"我刚失败、需要重新确认"被当成空转；另 `make-failing-test-pass` 再现长随机路径转写失败（模型写 `…iTrKVZbuY`，全 run 锚点唯一是 `…iTrKVZgbuY`），**上一轮记的"工作区在同一轮内换了目录"不成立，此处更正：地面没有移动，是模型抄错一个字符**。

**10-25(26) 锚点门只核有 marker 的行引用，prose 里的 `File.swift:NNN` 一直无人核对**（P2 文档完整性 / 门自身的盲区，符号 `anchor-prose-cites`） — 上一轮改 `EngineInference.swift` 时 `make anchor-check` 一次报 17 处漂移（都是插入行号把 marker 引用顶偏，已逐条改到实测行位）。修的过程中撞见一个更值得记的事实：`Sources/ocoreai/Engine/AGENTS.md` 讲 fork 站点的那句写的是 `EngineInference.swift:3139`，而唯一的 `.fork(` 在本轮之前就在 3185 —— **改动之前它已经错了 46 行**，marker 那行红了，旁边的句子没红。原因写在脚本自己身上：它只解析 `anchor:<repo> <path>:<line> <token>`，prose 引用没有 token，无法核对内容；而脚本头一句写的是 "verify every line cite"，又是一处声称大于机制。

- **改法：能判定的判死，判不了的摊开。** ① 头部改成实际做的事（只核 anchored 引用）；② 新增 prose 引用扫描：统计全仓 `File.ext:NNN` 形式的裸引用（marker 行除外），把**行数超过目标文件总行数**这种唯一可证伪的情形判 FAIL（与 P3 对 marker 的 EOF 判据同形）；③ 把不可核实的集合大小说出来，而不是留在暗处。实测：prose 引用 **296 处 / 317 个被扫文件**，唯一目标文件 7 个，本轮 beyond-EOF **0**。
- **为什么不设"必须写成 marker"的上限**：那只会把散文逼成 marker，为形状而非为意义——同一句引用真正需要的是 token，不是注释壳。要做的是下一步（把承重的那几条 prose 引用改写成带 token 的 marker，提高可核实覆盖率），而不是先立一条会把人引向形式合规的门。
- **门自身的门**：新扫描按 invariant 1 给自己的命中数下界（`OCOREAI_PROSE_CITE_FLOOR`，实测 296，默认 150），正则一旦不再命中就红，而不是把"未核实集合只有这么大"变成空洞安慰。两条红样实测：把 floor 抬到 500 → exit 1；在 AGENTS.md 追加一条 `ToolRegistry.swift:999999` → `PROSE-DRIFT … past its 1110 lines` 且 exit 1；还原后回到 296 / drift=0。
- **验证**：`scripts/anchor-check.sh` 绿（checked=72，drift=0，local=30）；`make round-gates` 绿。**不声称**：prose 引用的内容仍不核实（296 处的正确性没有门保证，只有数量与 EOF 界保证）。


**10-25(25) 拒绝墙曾把"改了文件之后的复读"也拦下，而拒词是假的：把文件的真实新鲜度折进调用身份，并把循环账记从整场会话收到一轮**（P1 正确性 + 可靠性 / `loop-stall` 的第二段，五条同源改动） — 起点是上一轮留下的两个未决事实。① `make-two-tests-pass` 在阈值 2 时**被切断**（吃两次拒绝后本会自己做完，第三次拒绝变终态就提前收尾），抬到 5 才恢复 ⇒ "任一成功调用清零" 这个复位条件是错的：它既让 A 卡死、B 成功一次就把 A 买回（A/B 交替可无限循环，每圈付一整轮生成），也没有回答"这一次调用还有没有东西可给"。② 从既有 transcript 量到的分布：36 题里"同一调用给出逐字相同答案"的最大重复 = {1 次: 29 题, 2 次: 2 题, 3 次: 2 题}，其中 `move-into-subdir`（**PASS**）含 3 次逐字相同的 `edit_file` 答案 ⇒ 任何把"复读"当终态证据的门必须高于 3–4，否则会切断已经通过的任务；这条分布是量的，不是拍的。

- **另有一处 invariant 2 违例，物证级**：墙只按 arguments 认身份，于是文件被自家 `write_file` 改过之后，同样路径的 `read_file` 仍被拒，而拒词写着 "what it returned is already in this conversation"。撤掉本次折叠后的红样原文：`read_file with path=page.py called 4 times in 60 s — what it returned is already in this conversation — stop re-reading and act`，而此时 page.py 内容已经变了。⇒ 这句话在内容变过的文件上是**假的**，且它拦掉的正是 Execute→Verify 的验证回合。
- **改法（五条，各自一个家）**：① `loopIdentity`（`ToolRegistry.swift`）——`read_file` 的循环身份折进 `(size, mtime)`，路径解析复用既有 `FileTools.resolve`（不另造第二套解析）⇒ 内容变了身份就变：改后复读放行，未变复读照旧计数。② 阶梯改记**零新信息事件** `identicalAnswers + refusals`（答案逐字相同=零信息，拒绝=零产出），只有该键交出**不同答案**才清零（`recordLadderAnswer`）；`resetLoopStrikes(scope:)` 删除 ⇒ A/B ping-pong 关掉。③ 循环账记的作用域从 conversation 改为 **turn**（`call(..., turnToken:)`，两条 lane 每次推理注入一个 UUID；`EngineInference.swift` 建 `ChatSession` 在一次调用内，故轮内稳定），而授权、steer、审计仍按 conversation：谁能问、谁能打断、日志归谁，与"这一轮烧掉多少"不是同一个问题。④ 无 token 时退回 conversation 作用域并以 `ladderMemory`=600 s 老化（实测失控轮约 0.6 s/次：一分钟静止不是失控的样子，而秒级刷屏等不到老化）。⑤ `ToolRegistry` 文件头原本自称 "SHA256 loop detection"，代码用的是进程内 `String.hashValue` —— 按"文件与代码不一致时改错的那一个"，把注释改成代码实际做的事（进程内身份键，从不持久化，从不充当安全边界），不为了圆一句注释引入 CryptoKit。
- **阈值 8 的依据**：合法上界实测≈3 次相同答案（其一是 PASS 任务），墙在第 4 次尝试才拒绝 ⇒ 到终态需 3 次相同答案 + 6 次拒绝；对照它要拦的失控样本 86 次。代码注释里写明"这是单池观测，别盲调"。
- **门**：`LoopStallTerminationTests`(6)——精确向量 `ran×3, detected×6, stalled×3`（断言整条向量）、终态措辞必须同时报"byte-identical / refusals"两笔账且不得含 "vary the arguments"、**改文件后的复读必须跑到新内容**、不同工具成功不得把卡住的调用买回、新轮次必须拿到新预算、`isTerminalStall` 八值矩阵。红样（把新鲜度折叠关掉）：**恰 1 红**，红样原文即上面那句假声称。
- **行为验证与噪声裁决**：全量 **3151 tests / 559 suites 绿（430s）**；`make round-gates` 绿（root 30159/30388，corpus 155351/155386）。机制层面的Win 可归因：`fix-off-by-two` 从 **12 次工具往返 / 15.8 s** 降到 **3 次 / 4.1 s**，且最后一次 `edit_lines` 是干净的 `OK`（此前是 `OK-but-invalid` 之后连吃 6 次拒绝 + 1 次终态）。总分：**22、24**（同一改动两次跑）对照同会话基线 **25**、上一轮 **23**；配对差异 3 题中 `copy-with-suffix`、`move-into-subdir` 在**同条件两次跑之间自身翻转**（已证为抖动），`make-two-tests-pass` 2/2 失败且其 transcript 显示零拒绝、是在放行几次真复读后转入 `edit_lines: lines 10…` 越界重试 —— 记为未决，不记为改善，也不假装它不存在。
- **不声称**：不声称任务成功率提高（n=3 失配，McNemar p=1.0，总分落在 10-25(5) 量到的 ±5.8 抖动带内）；不声称阈值 8 通用；不声称 std lane 已硬停（见 § Open：终态在 std lane 仍靠措辞，硬停要从 `toolDispatch` 抛出并以错误抵达 wire，四张 faces 的终词待业主裁决）；`fix-off-by-two` 四臂皆 FAIL 是模型算错 slice，与本条无关。


**10-25(23) 一条可以被无限重复的拒绝终于有了终点：strike 阶梯落地，MTP lane 硬停，std lane 的终点仍系于模型**（P1 可靠性 / 上一轮记的账这一轮执行，符号 `loop-stall`） — 根因是两条无界条件夹住一条"可恢复的拒绝"：`checkLoop`（`ToolRegistry.swift:600`）在 `do` **之前**抛出，而 `recordExecution` 只在到达 handler 的两条路径上被调用（成功 `:640`、handler 失败 `:684`）⇒ 被拒的调用完全不进 `executionHistory`，`recentCount` 永远钉在 `maxHistoryDepth`（3），每次拒绝都是同一句 "called 4 times in 60 s"，计数不前进；60 s 老化还会把建成这道墙的成功记录清掉，于是同一道墙同时又漏。消费侧上游 std lane 是 `restart: while !pendingMessages.isEmpty`（ChatSession.swift:1154，`continue restart` 在 :1638），**没有轮次上限**；我们自己的硬上限只存在于 MTP lane（`maxMtpToolLoop = 10`）。实测一题 86 次一模一样的拒绝、任务以失败收尾。

- **改法（四处，一处一个家）**：① `ToolError.loopStalled`（`ToolEntry.swift:262`）——新增值只有一处 exhaustive switch（`errorDescription`），全仓无其它消费点需要跟改。② `ToolRegistry` 记 strikes，键 `scope|name|argsHash`，与墙同一个 60 s 窗口老化（`:808`）；清零点与 exec-breaker 同处成功路径（`resetLoopStrikes` 紧跟 `resetExecBreaker`，`:649`），并**按 scope 前缀清**——一个客户端解套不能替另一个客户端解套。③ 判定只有一处：`EnginePool.isTerminalStall`（`EngineInference.swift:102`），两条 lane 与测试问的都是它。④ `toolRecoveryText` 为 stall 单开一支（`:117`）：通用支以 "retry differently" 收尾，而那正是让循环活着的句子；stall 支改口为"本轮不会再执行、不要再调工具、拿已有的东西回答"。MTP lane 在自己拥有的循环里**硬停**：`mtpToolLoop:` 标签 + 迭代结束后 `break`（`:3721`、`:4211`）——不在 catch 里 break，是为了让被调用的 tool 消息仍与模型发出的 call 配对，否则这一轮写回历史的形状就是坏的。
- **阈值 5 是量出来的，不是选的**：先取 2（三次拒绝即终）。配对 12 题池跑出 `make-two-tests-pass` **PASS→FAIL**：它按旧行为吃两次拒绝后自己走出循环并把修复做完，而第三次拒绝一变终态它就提前收尾（答语 "I could not complete the fix because the tool execution loop stalled."）。⇒ 阶梯把"本会逃脱"的任务切断了。抬到 5 后该题回到 PASS，且拒绝形状与旧行为逐字一致（detected=2、stalled=0），两次独立跑均如此。这道墙要拦的失控从不靠"多试几次"逃脱，所以阈值只需高过模型被观测到的需要。
- **门**：新 `LoopStallTerminationTests`(5)——同一调用的精确阶梯 `ran×3, detected×5, stalled×3`（断言整条向量，不写 `count > N`）、终态措辞必须含 "will NOT run again"/"answer the user" 且**不得**含 "vary the arguments"、任一成功调用把阶梯买回、stall 不得锁住从未卡住的工具、以及 `isTerminalStall` 的八值矩阵（只有 stall 为真）。红样（`maxLoopStrikes = 99` 撤阶梯）：**恰 2 红**——阶梯向量与终态措辞；另 3 条在该撤法下空过，如实记着，它们守的是清零/作用域/谓词，不是这条阶梯。
- **std lane 仍未硬停，这是本轮的边界而非完成**：终态在 std lane 目前只是措辞，靠模型自己不再发调用；实测 `fix-off-by-two` 在这一轮以 detected=10 + stalled=2 收尾（模型照话停了），对照同题历史记录的 86 次。要**保证**停只能从 `toolDispatch` 抛出（ChatSession.swift:1632 外层 `catch { continuation.finish(throwing:) }`），而那会以错误抵达 wire，不是一轮完成的回复——四张 faces 各自的终词该是哪个，属业主裁决，已写进 § Open。§ Open 同时记下：阈值只有一池配对数据，不是一条曲线。
- **任务台配对与噪声裁决**：默认 36 题本轮 **25/36**（上一轮同配方 23/36；抖动带 mean ±5.8 ⇒ 总分不作改善声称）。12 题池四臂：阶梯 OFF **7、6**／阶梯 ON(thr 2) **5**／ON(thr 5) **6、6**。唯一可归因于改动的翻转是 `make-two-tests-pass`（thr 2 切断逃脱），已修并复测回到 PASS。`fix-off-by-one-slice` 曾疑似回归：它在四臂里 **OFF 也 FAIL**（b1 的 PASS 是离群值），且两臂 transcript 显示差异发生在**第一个动作**（b1 先 `read_file` 再改，其余三臂第一步就直接 `edit_lines` 且落为 OK-but-invalid），此时零拒绝、我改动的代码路径一次都没走 ⇒ 判为实例噪声，不是本改动的因果，但仍写在这里而不是抹掉。两题在四臂恒定 FAIL：`exec-sum-column`（答 23，正解 26）、`make-third-test-pass`（空答），与本条无关。
- **验证**：定向 **13 tests / 3 suites 绿**（新套件 + `LoopGuardRemedyTests` + `ToolRecoveryTextTests` 同批）；CLT 全量 **3150 tests / 559 suites 绿**（较上轮 +5 tests / +1 suite，即本条新套件）；`make round-gates` 绿；`make docs-check` 绿（§ Open 该条改写后 root 30132/30388）。
- **不声称**：不声称任务成功率因本改动提高（12 题池 McNemar 无力，36 题单轮在噪声带内）；不声称 std lane 已硬停；不声称阈值 5 对任何模型/任务通用；不声称 `fix-off-by-two` 的正解被本改动修好（它四臂皆 FAIL，是另一道题）。


**10-25(22) 同一个拒绝可以无限重复：守卫只记成功、上游 tool 循环无上限，实测一题 86 次一模一样地被拒**（P1 成本与可靠性 / 记入 § Open 并指名该由什么仪器关掉） — 起因是修 `cwd` 时顺手扫的两轮任务台工具往返：`fix-off-by-two` 一题里 `read_file` 被 `Execution loop detected` 拒绝 **86 次**，每次文本几乎相同，任务仍以失败收尾。读代码定位到两个事实：① `ToolRegistry.recordExecution` 的文件注释就是 "Record a **successful** execution for loop detection"——被拒的调用不进 `executionHistory`，于是 `recentCount` 永远卡在 `maxHistoryDepth`（3），每次拒绝都报同一句 "called 4 times in 60 s"，计数**不会推进**；而 60 s 老化还会把成功记录清掉，这道墙同时又漏（长回合里同一调用过一分钟又放行）。② 消费侧 `ChatSession` 的 std lane 是 `restart: while !pendingMessages.isEmpty { … continue restart }`（ChatSession.swift:1154、1638），**没有轮次上限**；我们自己只给 MTP lane 设了 `maxMtpToolLoop`（`EngineInference.swift:3694` 硬上限 10）。⇒ 一条"可恢复的拒绝"在两个无界条件中间，成了既不前进也不终止的墙。

- **为什么"把拒绝写得可纠正"没能救它**：10-25 早前一轮已经把 loop 拒绝语改成带补救的长句（当时记的是"一次 21 题跑里有 68 次相同拒绝"）。这一轮同形状仍复现（86 次），证明**消息不是机制**：模型收到同一句静态拒绝时没有新的信息量，前进与否完全取决于模型脾气。真正的机制缺失是"拒绝没有终点"，以及拒绝没有改变任何被守卫看见的状态。
- **修复形状已经验证可行，但需要独立一轮验证**（故本轮只记账，不夹带引擎改动）：守卫侧加 strike 阶梯——同一 `(scope, tool, args)` 每被拒一次记一次 strikes，任一成功调用清零（清零点已存在：`ToolRegistry.swift:626` exec-breaker 在成功时复位）；阶梯触顶后不再返回可恢复文本，而是**抛出**。抛出行得通是实测的：上游 `let toolResult = try await toolDispatch(toolCall)`（ChatSession.swift:1632）外层的 `catch { continuation.finish(throwing: error) }` 会把整轮以该错误结束，且我们自己的拒绝路径早已用同一形状（同文件 1621 行 `throw RejectedToolCallError(rejection)`）。缺的只剩"我们把 `loopStalled` 从 `[tool_error: …]` 文本转换里豁免出去"，以及给这条阶梯和这个缝配测试；`EngineInference.toolRecoveryText` 现会把所有 `ToolError` 一律转文本，这条豁免必须由测试钉住，否则改动会被吞。
- **文档记账**：`AGENTS.md` § Open 新增该条（含 `ChatSession.swift:1154` / `:1632` 两处引用，`make anchor-check` 实测 checked=72 **drift=0**）。字节自付：§ Docs Contract 的机制清单压回它唯一的家（脚本，4 行），root −199 chars、corpus 净 −5 B（155381/155386）。这不是润色——`scripts/agents-md-contract.sh` 才是门清单、理由和环境变量的家，root 复述它正是本文件自己反对的那类副本。
- **更正我自己上一轮的说法**：我说过"三份指针列表互相重叠、可合一"。实测三份的指针交集只有 1 个（`scripts/probes/README.md` 同时出现在 Routing table 与 Read on demand；Documentation Map 与两者零重叠）。⇒ "合一省 4 KB"不成立，那条建议撤回；真正的问题是**注入面已到容量上限**（corpus 余 5 B、root 余 199 chars），任何诚实新增都必须先删旧账——可还的债 `scripts/agents-md-contract.sh` 自己点名了：`docs/agent/build-gate-reality.md` 里 15 处 MM-DD 取证（裁决 `CHANGELOG.md` 已载）约 2 KB。下一轮先还债，再谈新增。
- **验证与边界**：本轮无代码改动，故不跑全量套件；`make round-gates` 绿（docs contract、line cites、swift patterns 三段），anchor drift=0。§ Open 现在共 10 条，其中 3 条待业主拍板（`%2F` 路由、无工具调用轮次中断的归属、coreai-models +8 re-pin）。

**10-25(21) `cwd` 直接进 `Process` 造成的三道同源缺陷：文件当目录、相对路径锚在仓库、两条 exec lane 起点不同**（P1 可靠性 / 由记分板失败回合的 transcript 驱动） — 起点是逐题留档里的一条工具往返：`response-exec-report-two-numbers.json` 的 `ocoreai.tool_results[0]` 为 `command="wc -l -w notes.txt"`、`cwd="…/ocoreai-eval-ws-…/notes.txt"`（**把文件路径当 cwd**）、`failure="Tool execution failed: The operation couldn't be completed. Not a directory"`、`ok=false`，模型的收尾是 "notes.txt was not found in the specified directory"。扫描两轮 88 题的 `tool_results`：这类 `cwd` 直指文件的调用共 **3 次**，每次都吃掉一道题。根因是同一个：`cwd` 未经解析就被赋给 `Process.currentDirectoryURL`。

- **顺同一根因查下去还有三条**：② cwd 不存在时只抛 `executionFailed`，不点名路径与补救；③ **相对 `cwd` 锚在进程目录**——红样原文：旧代码把 `cwd="sub"` 解析成 `/Users/uingei/ocoreai/sub`（本仓库目录），而 `FileTools.resolve` 的相对 `path` 锚在 workspace（schema 对两者都写了 "relative"），于是写进去的文件和本该跑它的那条命令不在同一个目录里；④ **两条 lane 默认目录不同**：`exec_command` 无 cwd 时用 `SessionWorkspace`/`WorkspaceContext`，`ExecSessions.spawn` 无 cwd 时继承进程目录；⑤ `ExecSessionManager.expandPath` 与 `ExecTools.expand` 是两份 `~` 展开实现，靠一条 "parity with ExecTools.expand" 测试维持一致——一致性本该由"只有一份"来保证。
- **改法（一个解析器，两条 lane 共用）**：新增 `ExecTools.resolveCwd`——相对路径锚在 `effectiveCwd(nil)`（与 `FileTools.resolve` 同一条链）；`cwd` 指到文件则用其父目录，并在结果**首行**说明 `[cwd] "…" is a file, not a directory — ran in …`（意图无歧义，宁可修好并声明，不要用天书把模型送去死路）；目录不存在则 `ToolError.invalidParameter` 同时点名路径与补救（`omit cwd to use <workspace>`）。`ExecTools.run` 与 `ExecSessions.spawn` 都改走它，`expandPath` 及其 parity 测试删除（行为由 `ExecTools.expand` 的既有 pin 覆盖：`~`、`~/x`、绝对、相对）。
- **门**：新 `ExecCwdContractTests`(5)——文件当 cwd 时在父目录跑出 `exit code: 0` 且首行有说明、**且不得再出现 `Not a directory`**；缺失 cwd 的拒绝必须同时含路径、"not an existing directory"、"omit cwd"；相对 cwd 锚 workspace；**两条 lane 无 cwd 时必须落在同一目录**；目录 cwd 不加任何注释（沉默是默认，注释只用于发生过修复）。
- **红样**（`git stash` 两个源文件、测试保留）：**4 红 1 绿**，红样原文即旧行为的物证——`.executionFailed(… Code=20 "Not a directory")`、`.executionFailed(… "The file “sub” doesn’t exist." NSFilePath=/Users/uingei/ocoreai/sub)`、`session.report.contains(ws.path)` 为假；保持绿的那条正是"目录 cwd 应沉默"，证明它不是给改动陪跑的镜像。
- **验证**：定向 **104 tests / 20 suites 绿**；CLT 全量 **3145 tests / 558 suites 绿（427.5s）**；`make round-gates` 绿。任务台 36 题（同 conditions：`gemma-4-e2b-it-4bit`、temp 0、approval auto、6 工具）= **23/36**；与改动前一份同配方逐题配对 **5 FAIL→PASS / 1 PASS→FAIL**（净 +4，McNemar p≈0.22）⇒ **总分按判据不构成改善声称**。
- **有机制归因的两题**：`exec-report-two-numbers`、`exec-count-lines` 由 FAIL→PASS，且这两题改动前的 transcript 就是 `cwd=<文件>`→ENOTDIR，红样证明旧代码遇同样输入必红——这两题是可归因，不是运气；`copy-with-suffix` 的 PASS→FAIL 落在 10-25(5) 量到的 12 题抖动名单里；`fix-boundary-comparison` 这轮 PASS，是 `81084b9`（拒绝语命令模型立刻重试）第一次拿到观测到的通过，单轮，同样不声称。
- **仍开放（不是 cwd 问题，另案）**：`exec-sum-column` 答 23（正解 26）——模型算错列，需查是提示还是工具输出没把表头结构交代清楚；`make-third-test-pass` 空答收尾。§ Open 里"无工具调用轮次不可中断"不受本条影响。
- **文档**：本轮**没有新增任何规则或门说明**——§ Error Handling 早已写着 "Failure reports name the cause, not the symptom"，本条只是那条规则的一次执行，重复它只会多一个会漂移的家。

**10-25(20) 审批闸门读的是手抄名单而不是危险声明：17 条声明对 7 条名单，`edit_lines` 等 11 个高危工具在默认策略下不问自取**（P0 审批面 / 单一真相 + 一条会自己烂掉的探针前提） — 取证：`ToolEntry.isDestructive: true` 在 `Sources/` 里共 **17 条声明**（`edit_file`、`edit_lines`、`write_file`、exec 四件套、`write_clipboard`、`open_url`、`open_app`/`activate_app`、6 个桌面控制），而生产唯一构造的 `ToolRegistry`（`App.start()`，始终注入 broker）拿到的审批面是 `App.swift` 里一条 `.matching("write_file,edit_file,exec_command,execute_code,exec_shell,write_stdin,exec_poll")`——**7 个名字，手抄**。合成器 `isDestructive(_:)`（黑名单 ∪ 声明）**在生产里 0 个消费者**，全仓只有 6 处测试在断言它。默认策略实测就是 `.interactive`（`~/.ocoreai/config.yaml` 写着 `approvalPolicy: interactive`，解析链 env > yaml > GUI domain > own > 默认）。⇒ 同一台机器上 `write_file` 会弹审批，而 `edit_lines` 直接改你的盘。

- **改法是删名单，不是补名单**：`securityPrecheck` 的 `ungated` 由 `.allow` 改为按注册声明派生（`approvalBroker != nil && isDestructive(name)` ⇒ `.ask(reason: "destructive tool call")`，原因串与既有名单一致以免长出第二套合同），`App.swift` 的 7 名 matcher 删除（`hooks: []`）。无人可问时 ask 无意义：broker 缺席保留 hooks-only 语义供 harness 使用，这条边界写进 `securityPrecheck` 的注释而不是藏起来。
- **顺带撤掉一处假闸门**：`call()` 第 3 步标题叫 "Destructive tool serialization check"，实际只 `logger.info("Serial execution of destructive tool")`，不持锁不排队；真实顺序来自两条 lane 自己的循环（native 逐条、MTP per-iteration）。注释改为陈述事实（闸门在第 1 步，串行不是这个注册表的声称），另修 `BuiltInTools.swift`、`DesktopControlTools.swift` 两处仍把 `App.swift` matcher 当审批之家的注释。
- **探针同一条腐烂（invariant 1 的正面对象）**：`scripts/probes/_lib.sh` 起 `serve` 时不传审批策略，于是探针的前提取自操作者机器 GUI 记录下来的选择——同一份探针在两台机器上量的是不同的事。显式钉 `OCOREAI_APPROVAL_POLICY="${OCOREAI_APPROVAL_POLICY:-auto}"`（与 `scripts/eval/run.sh:31` 同形，可被外部覆盖），理由写在脚本里，README 不复述（one home）。
- **门**：新 `DestructiveApprovalGateTests`(5)——① 无任何 hook 点名的声明高危工具把用户挂起（`toolName`/`reason` 精确断言，随后裁决拒绝 ⇒ `ToolError.denied("user said no")`）；② headless + `.interactive` ⇒ 精确 fail-closed 原因串，且不 park 一条无法回答的 ask；③ `edit_lines` 本尊（本次缺陷的原形）；④ 反向：`auto` 与非高危声明仍放行且不落 pending（防止整套变成改动自己的镜像）；⑤ 生产 bootstrap 之后**被闸门覆盖的名字集合 == 声明集合**（双向差集各自为空 + 计数地板 17 + `edit_lines` 必须在注册表内，防扫描空转）。
- **红样**：把 `ungated` 退回 `.allow` ⇒ **恰红 3 条（①②③）**，④⑤ 保持绿——正好证明后两条不是给改动陪跑的镜像断言。恢复后定向 **150 tests / 26 suites 全绿**。
- **真机 A/B（这条改动的代价，量化而不是形容词）**：冻结 52 题 edit-repair 集、同模型同配方，只改策略。`OCOREAI_APPROVAL_POLICY=interactive` ⇒ **6/52**，回答里逐条引用拒绝（"I was denied the request to modify `norms.py`"、"cannot execute shell commands … interactive approval"）；`=auto` ⇒ **30/51**（1 题未达引擎）。差 **24 题**就是"没人能批准时，本机 agent 还能不能自己写盘"这件事的价格；`auto` 是既有文档化出口（`scripts/eval/run.sh:14-21` 早已写明任务台要自主执行自己的工具）。
- **全量验证**：CLT 全量套件 **3141 tests / 557 suites 全绿（425.5s）**；`make round-gates` 绿（docs contract `claims=31/31`、`numbered-claims=28/28`、`suites=53`、`probe-index=35/35`）；`make anchor-check` checked=70 **drift=0**（本次删行使 README 两份的 `App.swift:723` 顶到 718，已按实测行号改引用）；bare upstream cites 218/218；live probe 12 **8 passed / 0 failed / 2 known-open**（§6、§7 两条既有开放半边不变）。
- **不声称**：这不是能力进步，是关掉一扇本不该开的门；`/v1` 上调用方自己声明的工具仍由调用方执行（vllm/sglang 语义，probe 11 钉着），本条只管服务端自己执行注册表工具那条 lane。改前"`edit_lines` 不问就能写"是缺陷而不是便利，但它确实被 36 题主记分板受益过——主记分板跑 `auto`，故分数不受本条影响（仍 19/36，在 10-25(5) 量到的噪声地板内）。桌面控制/剪贴板/开 app 这 9 个工具今天仍属**能力未实测**（iOS 零真跑、Accessibility 自动化未验证），闸门生效不等于它们好用。

**10-25(19) 按用途整理文档：同一事实只留一份，两条规矩各归其家——并明确放弃"再加一道门"的方案**（P3 文档卫生 / 业主两次纠偏："别没事就造门，文档应该根据用途编写合适的内容"） — 判据：一个事实如果有三份副本（`Tests/` 里的门、`CHANGELOG.md` 里的裁决、`AGENTS.md` 行内的测量叙述），那么 root 那份就是第三份，删它。本轮删的全是"测量过程与历史叙述"（`measured …`、`four orderings measured`、"某轮量到 X"），**规则本身、符号名、`file:line` 锚点、门名与 `(N)` 条数一条未动**。

- **回收**：root `30388 → 29817` chars（净 −571：去复述 −672、taste test 新问句 +101），corpus `155379 → 155009` B（净 −370，余 377 B）。八处：MLX path、`SessionPool`、Gate tiering、Licenses、grammar-schema、rewind 项、CoreAI/macOS 27 项、`ClaimVsAudit`。删语法那句前先确认它有家：`scripts/probes/README.md:78` 已写 §7 的开放半边（"必须先读文件才能作答的回合发不出那个调用"），所以 root 只留 `serving_chat.py:1488-1501` 锚点与 `probe 12 §6, §7` 指针。
- **规矩 1（装饰不是信息）的家 = `Sources/ocoreai/UI/AGENTS.md`**，进 § On anything user-visible（HIG 是用户可见面的裁判）：删标语、解释性段落与次要标签；删完界面就看不懂，缺陷在布局——改布局，别改标签。它只在 UI 子树里咬人，放 root 就是让每个非 UI 会话为它付字节。
- **规矩 2（三受众）的家 = root § Taste test before you hand off**，压成一行问句：*Did the user, the developer and the agent reading this surface each end up better off than before?* 它是交工前的自问，不是可判红的机制，因此写在清单里而不是写成门。
- **放弃上一轮的提案**：曾拟给 root 加 P17（bullet ≤3 行 + 21 条豁免名单）。**需要 21 条例外才能通过的形状门是自证无用的门**——它统计的是自己的例外，不是文档的质量；且同类已有 P13（root 单行 ≤400 B、无日期）与 P15（corpus 无 prose wall）覆盖。业主否掉它是对的，本条把"为什么不做"记下来，防止下一轮重新发明。
- **验证**：`make round-gates` 绿（docs contract + line cites + swift patterns，含 `claims=31/31`、`suites=52`、`probe-index=35/35`、`numbered-claims=27/27`、Class-J `0 unresolved`）；`make docs-check` 单独复跑绿，`anchors=94 dangling=0`。**没有新增任何门、任何测试、任何脚本**。
- **不声称**：文档变短不等于能力变强。同一模型同配方下任务成功率仍是 **19/36**（上一条同配方 22/35、22/36），差值在 10-25(5) 量到的 ±6 单向地板之内，两个方向都不构成结论；本轮唯一的成效是注入给模型的上下文更省、且每条 root 规则的证据仍然指得到家。

**10-25(18) 拒绝语已经把整份文件贴给模型了，却还在叫它"先去 read_file"——拆掉这句自相矛盾：小文件失配时命令是"立刻重试"，不是"再读一遍"**（P1 可靠性 / 记分板失败回合驱动） — 本轮记分板（`scripts/eval/run.sh`，model `mlx-community/gemma-4-e2b-it-4bit`、temperature 0、6 工具、approval auto）里 `fix-boundary-comparison` 的失败回合是教科书形状：`response-*.json` 的 `tool_results[0]` 为 `edit_file(path=capacity.py, oldString="return load == limit", newString="return load <= limit")`、`ok=false`——它的 **newString 本来就是正解**，而拒绝语也已经把整份文件连 `return load < limit` 一起给出去了（`the file says (all 2 lines, verbatim…)`）；模型的收尾却是 "I failed … I need to read the file first"，`finish=stop`，任务没做。⇒ 缺的不是信息，是**下一步命令**：同一条回文一边给出可原样复制的原文，一边派调用方去读它已经看得见的文件。

- **判据换成"整份是否已经给出"，而不是"提示是否非空"**：`nearestLinesHint` 返回从 `String` 改为 `MismatchHint(text:quotedWholeFile:)`（唯一读者就是 `edit_file` 这一处调用点，改签名零外溢）。整份引用 ⇒ 命令是 `Retry this call now with the exact line above as oldString: the whole file is quoted above, so nothing has to be read first. Do not answer the user before that retry.`；窗口引用 ⇒ **保留**原句 `read_file it and copy the exact text`，因为被裁掉的行可能正是目标行（同一条纪律在 codex `Total output lines` 那里是"展示局部必须说整体"，`Sources/ocoreai/Tools/ExecTools.swift:92` 早已如此）。
- **`edit_lines` 的越界拒绝共用一个家** `FileTools.retryBeforeAnswering`：记分板 `make-third-test-pass` 的回答是 "the line range provided was invalid for the file structure"，而拒绝语上一行已经报出 `outside 1...N` 与真实行数——数据齐了，命令没有。
- **门**：`EditMismatchRecoveryTests` 新 1 条 `wholeFileQuoteOrdersTheRetry`（精确断言含 `all 2 lines`、`Retry this call now`、`Do not answer the user before that retry`，且**不得**含 `read_file it`；另断言拒绝从未写盘）；既有 `clippedHintStatesTotals` 加反向断言（窗口情形**不得**出现 `Retry this call now`——它可能把目标行裁掉了，不许命令"照上面那行改"）；`EditLinesContractTests.outOfRangeNamesTheBound` 加"先重试再作答"断言。**该套被 `docs/agent/agent-interface-guidelines.md:27` 以 `(8)` 钉住，故只加断言不加测试，条数不动**（P11 会去数 `Tests/` 里的 `@Test`）。
- **红样**：强制 `quotedWholeFile = false` 且 `retryBeforeAnswering = ""` ⇒ **恰红 2 题（4 条断言）**；其中 `!message.contains("read_file it")` 一起红，正好证明"多余往返"是改前真实存在的行为，不是为了给断言找靶子编出来的。撤除改动后复绿。
- **与既有链条的关系**：10-22 修的是"拒绝不可答"（把裸的 `found 0` 变成带原文的可答拒绝）；本轮修的是"可答，但没有命令"——同一条 Recover 链的后半段。`replace_all` 那次把 `edit-replace-all` 从 0/3 拉回 pass 用的是同一形状：说出旋钮 + 关上那扇会导致停下的门。
- **验证**：定向 `EditMismatch|EditLines|FileTools|PresentationEcho|FMToolError|ClaimVsAudit|ToolRegistry|PostWriteSyntax` = **98 tests / 13 suites 全绿**；全量 CLT 套件 = **3136 tests / 556 suites 全绿（426.3s）**；`make round-gates` 绿。
- **不声称**：本轮记分板 **19/36**，上一条同配方是 22/35、22/36——差 3 题在 ±6 单向地板之下，**改善与退化两个方向都不构成结论**（temperature 0 仍有跨轮抖动，来源未查清：会话池 / KV 复用 / 工具时序都可能是变量）；这条改动的成效要等 k 次配对，且必须盯住 `fix-wrong-key-decoy` 一类样本，别把"诚实说失败"加压成"谎报成功"（既有教训）。

**10-25(17) 上一轮修的泄漏是真的，但更根因的问题是这张表压根没有读者：把调度器无人消费的整张生命周期面连根撤除，并补一道"消费者集合"门**（P1 复杂度止血 + 一道防复发的门） — 判据来自本轮的定调："清理的对象是无证据的复杂度和不可靠的执行路径，而不是代码体积"。对着这把尺子量 `SchedulerActor`：生产代码在它身上只调三个方法，共 **26 处**（`scheduler.fail` 14、`scheduler.complete` 7、`scheduler.submitAndDispatch` 5）；`submit`/`dispatch` 只在目录内部与测试里出现；`interrupt`/`interruptAll`/`submitAll`/`dispatchBatch`/`status(of:)`/`snapshot()`/`pendingCount`/`activeCount` 在 `Sources/ocoreai/Scheduler/` 之外 **0 个调用者**；`RequestState`/`RequestStatus`/`SchedulerSnapshot` 在目录外 **0 引用**；`totalProcessed`/`totalRejected`/`totalAdmitted` 三个计数器全仓（**含 Tests**）0 读者，只是往空口袋里加数；`PriorityQueue.find` 0 调用者；`SchedulerError.notFound`/`.timeout` **从未被 throw**；`avgQueueTimeMs` 是硬编码 0（原注释自称 "reserved for v2"）；`SchedulingRequest.timeout` **零读者**，而它的文档写着 "Seconds before auto-interrupt (default 30s)"——一个从未存在的承诺。⇒ 一次删除 **264 行**，删的全部是"没有读者的声明"，被消费的行为一条没少（消费面 = 26 个调用点原样通过）。

- **与 10-25(14) 的关系（不推翻，是往下挖一层）**：那轮记录的泄漏是真的——六处终态写入只改不删，唯一删除点在准入拒绝分支，服务器长跑便按请求数单调积累。但那轮给泄漏加的是"256 条封顶"，也就是**给一张本无读者的表续命**。本轮连根撤除之后，泄漏与它的假字段一起消失，等价门也从"300 条只留 256"换成更强也更朴素的断言：300 个完整回合后队列、活跃集与内存预约全部归零。
- **保留的两条"无调用者"必须写清，不装作有流量**：① `interrupt`——GUI 停止走 `Task` 取消（`ChatViewModel.cancelInference` → `currentCancellation?.cancel()`），从不经过调度器，所以它今天零调用者；保留的理由是它是"在飞中释放预约而不谎称请求已完成"的唯一缝，注释里只写这个 why（无工具调用轮次不可中断是 §Open 既记事项）。② `AdmissionGate.emergencyAbort()`——文档改口为"今天没有调用者；OOM 升级只在 `submit` 处生效，中途耗尽不会被它释放"，删掉阀门只会把缺口藏起来。
- **门（新 `SchedulerConsumedSurfaceTests`，2 tests）**：① 扫 `Sources/` 中"提到 `SchedulerActor` 的文件"（App + 4 个 handler + `DirectInferenceClient` + Router，地板 **≥**5 个文件），只取**代码行**（注释里点名 API 不算消费者），要求成员集合 `== {submitAndDispatch, complete, fail}`，并给扫描自身设站点地板 **20**（实测 26）——正则一旦不再匹配，这条门自己判红而不是空过。② `SchedulerActor.swift`/`SchedulerModels.swift` 必须**恰好**声明 6 个生命周期入口，且代码行中不得再出现 `submitAll`/`dispatchBatch`/`interruptAll`/`status(of`/`snapshot()`/`RequestState`/`avgQueueTimeMs`。
- **红样**：临时塞一个 `redSampleConsumer`（读 `scheduler.pendingCount`）+ 把 `func submitAll(` 加回去 ⇒ **恰红 2 条**，一一对应两道门；撤除后复绿。
- **测试账目**：删 `testSnapshot`、`testBatchDispatch`、`dispatchBatchNegative`、2 处 `status(of:)` 断言、以及上一轮为封顶表写的 `terminalRecordsAreCapped`/`unknownIdHasNoStatus`/`isTerminalExact`（共 6 条）；`testActiveCountDrains` 改用循环 `dispatch()` 取代 `dispatchBatch(5)`；新增 `nothingAccumulatesAcrossThreeHundredRequests`。净 **-3 tests / +1 suite**（声明数 3254→3251、553→554）。新门第一次写就把 `tracker.currentUsage() == 0` 当成"预约归零"，实测判红：`currentUsage()` 读的是**系统内存**（`pollSystemMemory`），不是本进程的 `reservedBytes`——正确的口是 `usageFraction()`，改用后精确等于 0。
- **验证**：`--filter "Scheduler|Admission|NumericDomain"` = **95 tests / 20 suites 全绿**；全量 CLT 套件 = **3135 tests / 556 suites 全绿（426.9s）**；`make round-gates` 绿。删的是 public API，故必须跑全量而不是定向。
- **未解决（写清不谎报）**：删掉 `timeout` 字段不是删功能，是删掉一个从未落地过的承诺；"请求自带截止时间"今天在代码里**不存在**，真正的修复要等上游 steer/interrupt 缝（`§Open`）。同向的第二个缺口：`AdmissionGate.reservations` 只靠 `complete`/`fail` 释放，没有任何超时清扫。⇒ 这两条合起来意味着：一个卡住的回合会一直占着预约，直到进程结束。

**10-25(16) `check_tools` 把"写而没跑"如实报出来；同时量到一件更重要的事：这条纪律在默认面上根本拿不到流量**（P1 诚实面 + 一条把下一步钉死的测量） — `AuditVerify` 报的每一行都只说"这次调用跑成功了"，而文件工具的 `success` 只代表字节落地（`PostWriteSyntax` 只判语法、绝不执行），所以一个"写了三个文件、一次都没执行"的回合，读自己的 `check_tools` 输出会看到三盏绿灯。这正是 § Two invariants 第 2 条点名的形状（durability 被当成 validity），而 Verify 段此前从不提这一点。

- **改成什么**：`AuditVerify.writesAwaitingRun(in:)`——窗口内成功的产物写入（`write_file`/`edit_file`/`edit_lines`）里，晚于最后一次"运行"的条数；**运行无论成败都算**（跑起来失败也是模型读到过的证据），所以这句话只说"还没有任何东西被执行过"，绝不说"你写错了"（宁可漏报，与 `ClaimVsAudit` 同方向）。`render` 在计数 >0 时追加一行 `[verify] N successful write(s) …nothing has executed against them yet…`。
- **一个家**：运行面名字集合上提为 `ToolRegistry.execHostToolNames`（`nonisolated static let`，`Set<String>` 不可变可跨隔离读），熔断器与 verify 面共用；`init` 的 `execHostTools` 改为 `Set<String>? = nil`（`nil` = 默认；空集是调用方明确说"没有运行工具"，必须仍有意义）。
- **门**：`CheckToolsTests` 新 **6 tests**——无运行时逐条点名（`writes == 2`、`ranInWindow == false`、文案含 `and no run at all in the window`）；写在运行之后仍待验（`after the last run`）；运行在写之后清掉提示；**失败的运行也算执行过**；失败写与只读工具绝不产出提示；再加自身前提地板——两个名字集合共 **7** 个名字，逐个必须在 `BuiltInTools.swift` 里以 `name: "…"` 注册，`hits == 7` 否则判"扫描自身失效"（工具改名不会让这条纪律悄悄失效）。`--filter CheckTools|ToolRegistry|ClaimVsAudit|ToolAttempt` = **82 tests / 14 suites 全绿**。
- **量到的反直觉事实（这才是本条的价值）**：同一产物连跑两遍 36 题任务台。6 工具集 = **22/35**（35 题到达引擎）；把 `check_tools` 声明进去（7 工具）= **22/36**；配对差 **4 个不连续对 < 地板 6** ⇒ 按 10-25(5) 的判据**既不能声称改善也不能声称退化**。更关键的是流量：36 题里模型只调用 `check_tools` **1 次**（`response-*.json` 的 `ocoreai.tool_results` 逐条统计：read_file 32、write_file 15、edit_lines 13、edit_file 5、exec_command 5、search_files 6、**check_tools 1**）。⇒ **"把纪律写进一个可选查询面"这条路是惰性的**：纪律必须长在本来就有流量的面上（写结果本身），或者长在注入提示里（`SystemPromptBuilder` 里 `grep check_tools` = **0** 命中——注入提示从未告诉模型有这个工具）。
- **顺带得到一条可复用的量化**：这一轮 36 题总共 **25 次成功写（另有 8 次写失败）vs 5 次运行**——"改完不验证"不是印象，是记分板上的比值。
- **保留还是撤除**：保留。它对现有面零成本、被 6 条精确值门钉住、且是 Invariant 2 要求的如实措辞；但**不宣称它改善了任务成绩**（证据不支持），并且本条明确记下：下一步的承重点在写结果的判决词与注入提示，不在这个可选查询。

**10-25(15) 并发到达时调度器会把别人的请求派给自己：一方吃到 503，另一方留下一个无人认领的活跃预约；而"全拒→等内存重排队"那条保险丝从未执行过一次**（P0 可靠性 / 同一处两个缺陷，日志为证） — 一次提交在 actor 上是**两条消息**（`submit` 然后 `dispatch`），所以两个调用方几乎同时到达时必然交错。修复前用临时探针实测：① 队列里 interrupt 优先级的 X 先入队（它自己的 `dispatch` 还没轮到），Y 的 `submitAndDispatch` 调 `dispatch()` 弹出的是 X ⇒ 日志 `Dispatched request X (model: m, est: 0MB @ fallback 1024 B/token)`，而 Y 的调用方拿到 `nil` → 五个 handler 一致地回 503，理由是 **"Higher-priority request dispatched first"**；与此同时 X 已经进入 `activeRequests`、已经 `.inferring`、已经在 `AdmissionGate` 里占了预约——但**没有任何人会替 X 跑推理，也没有人会替 X 释放预约**（唯一能收尾的是 X 自己的调用方，而它此刻正等着一个永远不会到来的返回）。② `AdmissionGate(maxConcurrentPreFills: 0)` 下两条请求全部被拒，日志有 `2/2 rejected this pass`，但那句"全部拒绝—重新入队"**从未打印**：保险 `if rejected.count >= initialCount` 写在循环体开头，可当最后一个候选被搬进 `rejected` 时队列已空，`pop()` 先返回 nil 结束循环，这一行永远等不到 ⇒ 被拒请求**从队列里消失**（`submitAndDispatch` 只删自己那条，别人的那条连同 `.pending` 状态行一起蒸发）。⇒ "等内存"这件事在产品里从来没发生过：真实行为是把放不下的请求直接丢掉，还告诉客户端是优先级抢占。

- **所有权按 id，且只有按 id**：新 `dispatch(ownedBy:)`——不是本人 id 的候选在**过闸之前**就放回 `held`（不查预算、不预约、不标 `.inferring`），只有本人可能被启动；`dispatch()` 改为 `dispatch(ownedBy: nil)`，保留"取最优"的排空语义给 `dispatchBatch` 与既有测试。
- **放回只有一个家**：新 `restoreSetAside(_:_:)` 一处负责"本轮取出但没派发"的一切（`rejected` + `held`），三个出口全过它——全部拒绝、启动成功之前、循环自然耗尽。"全部拒绝"的判据从循环体开头挪到 append 之后（`rejected.count + held.count >= initialCount`），因为"全部"只有在放进去之后才可判；这正是那条保险丝此前形同虚设的原因。
- **把会说谎的类型改掉**：`submitAndDispatch` 返回 `SchedulingRequest?` → `SchedulingRequest`。所有权成立后"返回别人的请求"不再是可达状态，而那句 `guard dispatched != nil` 的对外文案本来就把**准入拒绝**说成**优先级抢占**（Invariant 2：表面不得声称多于引擎所做）。类型收紧 ⇒ 编译器逼 5 个调用点一起改口（`ChatHandler`、`AnthropicMessagesHandler`、`CompletionsHandler`、`DirectInferenceClient` ×2），现 `grep "Higher-priority request dispatched first" Sources/` = **0** 命中。
- **门**：`SchedulerConcurrentTests` 新 **3 tests**，全部精确值：全拒时 `dispatch() == nil` 且 `pendingCount == 2`、`activeCount == 0`（两条都还在，等得起）；`submitAndDispatch` 拿到的是**自己**那条（`mine.id == "Y"`），X 仍排队（`pendingCount == 1`）并随后被 `dispatch()` 取到（`X` 没被吞）；大请求顶在前、小请求在後时**小的先走、大的留在队里**（`dispatched?.id == "small"`、`pending == 1`、`active == 1`）——这条专门钉住"重构没有把"高优先级放不下不得挡住小的"那条能力改掉"。`RequestNumericDomainTests` 那条负预算钉子从 `dispatched == nil || dispatched?.id == …` 收紧为 `dispatched.id == request.id`。
- **红→绿**：修复前探针 A 失败（`pendingCount == 2` 不成立：两条被拒请求已不在队列）、探针 B 两处失败（`mine?.id` 为 `nil`；`X` 已不在队列）⇒ 两条都是**真实现象**而非测试构造。修复后 `--filter Scheduler|NumericDomain|Admission` = **98 tests / 19 suites 全绿**（含既有优先级、批量、headroom、jitter 全套）；全量 CLT 套件 **3132 tests / 554 suites 全绿**（429.8s，SDK 钉 26.5）——本轮改了 5 个调用点与公共签名，验证取全量而不是定向。
- **未解（同一形状，风险更高的一档）**：预约的释放仍以"走到 `complete`/`fail`"为前提。下一枪要证的是**每条 `dispatch` 成功之后都必有终态**——引擎起跑后若从别的路径离开（流式提前返回、客户端断开、steer 改写），预约是否仍然归还；不还的后果不是字典变大，而是 `/v1` 开始拒绝本来放得下的请求。

**10-25(14) references 踩过的坑在我们家里原样存在了一份：调度器每完成一个请求就永久留一条记录，而 `RequestState` 的注释整体错开一行**（P1 可靠性 + 诚实面 / 从 comparator 的伤口学） — 按"别重复 references 已付过学费的坑"重扫 `~/references`：hermes-agent 为此专门修过 `fix(memory): terminate provider writer threads on soft eviction` 与 `bound the pending-created-topics cache`，opencode 修过 `fix(bash): memory leak - release parsed syntax trees`——共同形状是**以请求/会话为键、只进不出的进程级 map**。对着我们的代码查，同款确实在：`SchedulerActor.requestStates` 在 `submit` 时 +1，`complete`/`fail`/`interrupt`/`interruptAll` 共六处只把它改写成终态，**唯一会删除的地方是 `submitAndDispatch` 的准入拒绝分支**——也就是说只要服务器一直在服务，这张表就按请求数单调增长，键是全新的 request id，永不回收。

- **它换来了什么产品面？什么都没有**：调度器的 `status(of:)` 在 `Sources/` 里**零调用点**（唯一的 `.status(of:` 命中是 `ToolCallDeliveryLedger.swift:119` 自己的同名方法，与请求状态无关），唯一消费者是测试，所以"永远记住所有终态"既没有路由读它，也没有 UI 读它——纯粹的内存负债，为一个不存在的查询而留。
- **改成什么**：新增一处 `noteTerminal(_:_:)`，六处终态写入全部过它；id 只进 FIFO 一次（重复终态不再重复入队），超过 `maxTerminalRecords = 256` 从队首驱逐。256 是"刚结束的请求仍可查询"的窗口，不是随意数：每台请求的字典开销恒定，长跑服务器不再按请求数积累。`RequestState` 加 `isTerminal`（`completed`/`interrupted`/`timedOut`/`failed` 四条为真），驱逐判据与词表同源。
- **顺带修一处失真（Invariant 2 的最低级形式）**：`SchedulerModels.swift` 里枚举的文档注释**整体错位一行**——`completed` 头上写着 "Currently being generated"、`interrupted` 头上写着 "Successfully generated"、`timedOut` 头上写着 "Stop requested by user"，而 `case failed/// Error during processing` 把注释挤进同一行。这是公开 wire enum 的注释，读代码的人（和抓注释的模型）照单全收 ⇒ 逐条改回各自对应的一行。
- **门**：`SchedulerLifecycleTests` 新 **3 tests**，全部精确值不做 `count < N`：300 个跑完的请求后仍可查询的记录**恰 256** 条，且边界钉死（首条存活的 `== "req-44"`、末条 `== "req-299"`、`ids[43]` 已遗忘为 nil）；从未提交过的 id 返回 **nil** 而不是伪造的 `.pending`（此前 `?? .pending` 会给任何不存在的请求编出一个"排队中"）；`isTerminal` 恰 4 真 3 假。
- **红样（两轴同时退回）**：**30 tests / 6 suites 恰红 2**——上限退回 100,000 ⇒ 只有边界那条红（3 个 issue：count 300、first req-0、ids[43] 非 nil）；守卫退回 `?? .pending` ⇒ 只有 unknown-id 那条红；其余 28 条绿。修复后复跑 **30 tests / 6 suites 全绿**。
- **顺带核查的同类 map（有界，无需改）**：`AuditTrail.maxEntries = 10000`；`MCPCallCache` LRU + TTL（`maxEntries = 256`）；`RateLimitMiddleware` 的 model/IP 桶有 `removeStaleEntries` 驱逐；`activeRequests`/`requestMemoryMap` 在终态移除。
- **下一枪（本轮未做，形状已知）**：准入预约 `AdmissionGate.reservations` 靠 `complete`/`fail` 配对释放。四个 handler 确实在 catch 里调 `scheduler.fail(...)`，但**若请求在 dispatch 成功之后、终态之前从别的路径离开**（流式提前 return、steer 改写、客户端断开），预约是否仍被释放未证；泄漏的后果比字典严重——预约满了之后 `/v1` 会开始拒绝本来放得下的请求。要证的是"每条 dispatch 出口都有终态"，不是再写一档文档。

**10-25(13) exec 熔断对真正在跑命令的那个工具从来没生效过：默认集合点名三件套、漏掉 `exec_command`，而失败计数还是进程级**（P0 Agent 可靠性 / 一个门看不见的一路） — `ToolError.breakerEngaged` 的全部意义是别让 agent 对着坏掉的运行面一直磨（codex #41454）。取证两处同源缺陷：① `execHostTools` 默认 `["exec_shell","write_stdin","exec_poll"]`，而默认工具集里真正跑命令的是 `exec_command`（`BuiltInTools.swift:394`；codex 的 `exec` 就是 `ToolName::plain("exec_command")`，`ExecTools.swift:11`）——**熔断对主运行面恒不点火**；② 计数是 `var execFailureStreak: Int` 进程级，三个客户端各失败一次就能拒掉第四个客户端的第四次调用，与 10-21 修循环网时踩过的正是同一个坑（那次只把 `executionHistory` 改成分会话，这套后来写的没拿到同一条教训）。**既有 4 条测试全部只用 `exec_shell`**——门恰好只覆盖那条本来就能点火的通路，于是两处缺陷一个都照不出来（Invariant 1：没有门的修复等于没修）。

- **改成什么**：`execHostTools` 默认加 `exec_command`；计数改 `execFailureStreaks: [conversation: (streak,last)]`，>64 条时清掉已过窗的条目（长跑服务器不能让这张表跟着会话数无限增长——hermes-agent 踩过同类：`fix(memory): terminate provider writer threads on soft eviction`、`bound the pending-created-topics cache`）；`call` 开头一处 `let loopScope = conversationKey ?? Self.loopScopeNoConversation`，贯穿 `checkLoop`/`resetExecBreaker`/`recordExecFailure`，消掉三处各自重推的重复表达式（一个决定一个家）。`.zero` TTL 仍"永不断路"，过期分支语义不变。
- **门**：`ToolRegistryTests` 新 **2 tests**——`exec_command` 桩连续 3 次抛错 ⇒ 第 4 次在 handler 运行前 `Exec host blocked`（入参逐次不同以避开循环网）；会话隔离双向：conv-A 烧满 3 次后 conv-B 的 `exec_command` 仍进 handler（拿到普通失败而非拒绝），而 conv-B 的干净记录**不给** conv-A 赎回熔断。原有 4 条 `exec_shell` 测试原样保留。
- **红样逐轴归因**（不是"改回去就红一片"）：只把三处 scope 退回进程级 ⇒ **32 tests / 5 suites 恰红 1**（隔离那条）；只把名字退回三件套 ⇒ **恰红 2**（`exec_command` 两条，`exec_shell` 三条全绿）；修复后复跑 **32 tests / 5 suites 全绿**。两条门各自只钉一件事，红样能归因到单个缺陷轴。
- **顺手把上游精确语义核到底（源码注释此前说得比代码满）**：codex 只有 `Failed{handler_executed:true}` 递增 streak——命令**跑起来且非零退出**是 `Ok(_)→Completed{success}`，**不计数**（`accounting.rs:143-149`、`registry.rs:885-888`）；且 codex 粒度是**按 turn**、动作是**阻塞 goal**（`accounting.rs:151-172`），我们**按调用**计、动作是**拒绝该调用**（wire 面上没有 goal 对象可阻塞），这是刻意保留的分歧，后果是我们的点火比 codex 更早。由此得到一条此前没写清的事实：**这张网拦的是"运行面坏了"（spawn/exec 硬失败），不是"程序一直红"**；后者是 verify 缺口（`PostWriteSyntax` 只判语法、绝不执行），别再指望它。
- **验证**：CLT 路线（SDK 钉 26.5）`--filter ToolRegistry` = **32 tests / 5 suites 全绿**；`make round-gates` 绿（corpus 155,379/155,386，本轮不动文档字节，只改源码与测试）。
- **未解**：`destructiveBlacklist` 里仍留着未注册的 `execute_code`（陈旧名，只多一行日志，无正确性影响）；真正的"改完不验证"缺口按 10-25(10) 的结论继续走 verify，而不是继续对写操作加压。

**10-25(12) README 的平台行第一次带上"测过的 vs 声明的":iOS 至今零次真跑,这句话现在写在用户读到的第一面**(P1 诚实面 / 附一个必须由业主拍板的下载决定) — 两份 README 长期写 "**macOS 14+ · iOS 17+**"。取证:`sw_vers` = macOS **26.6.2**,全量测试、live `/v1/*` 探针、36 题任务台都只在这一台机上跑过;CI 的 iOS 腿是 `-destination 'generic/platform=iOS'` 的**编译**验证;本机 `xcrun simctl list runtimes` 与 `list devices available` 均**为空**——没有任何模拟器运行时。⇒ "iOS 能跑"在本项目历史上**从未被执行过一次**,而它和对外的声明之间没有任何门。

- **为什么这算 bug 而不是措辞**:Invariant 2 点名"任何用户能读到的东西都必须是被测量的,后端缺席时须诚实降级"。`/v1/capabilities` 有 `CapabilityMeasurementHonestyTests`(16)守着,而 README——用户读到的第一面、也是唯一一面写平台矩阵的地方——**没有对应门**;同一族漏洞(声称多于实证)此前已在 `/v1/models`、tool 结果、usage 上各修过一次。
- **改成什么**:两份 README 各加一段 **Measured vs declared / 测过的 vs 声明的**——macOS 26 实机执行(全量测试 + live probes + 36 题任务台)、`make release` 断言产物 no-CoreAI 且 minos=14.0、macOS 14/15 **未在真机运行过**、iOS 17+ **仅编译验证且从未真跑**,并明说那行是 `Package.swift` 的声明下限而非实测结论;Build Info 同步改为"声明 `.macOS(.v14)` / `.iOS(.v17)` —— 实机执行于 macOS 26;iOS 仅编译验证(`generic/platform=iOS`),未运行过"。
- **门** 新 `Tests/ocoreaiTests/PlatformClaimHonestyTests.swift` **3 tests**:限定语在两份 README 各恰 **1**;逐项精确计数且中英**完全对称**——`macOS 14+` 恰 2、`iOS 17+` 恰 3、`generic/platform=iOS` 恰 2、`CoreAI-free`/`不含 CoreAI` 恰 1、`minos` 恰 1(任何一侧删掉限定语、或把话说满,立刻变红);`Package.swift` 里 `.macOS(.v14)`、`.iOS(.v17)` 各恰 **1**,数字只有一个家,prose 不得另立第二个真相。
- **验证**:CLT 路线 `--filter PlatformClaimHonesty|ReleaseArtifactForm` = **8 tests / 2 suites 全绿**(Platform 3 + Release 5);`make docs-check` 绿(P10 human surface 仍 router-routes=**34** = README tables=**34**,corpus 155,379/155,386)。
- **需要业主拍板(我不擅自下载)**:要给 iOS 第一份实测,必须装模拟器运行时(`xcodebuild -downloadPlatform iOS`,数 GB)并在模拟器里真跑一次;CI 同理(`xcrun simctl create` + `xcodebuild test -destination 'platform=iOS Simulator,name=…'`)。本仓 CI 已有明文原则"**~1.5 GB 的下载不得卡发布**"(`ci.yml:369`),因此把它设成默认门属于范围与资源决定,请选:(a) iOS 实测进 CI(换时长与下载);(b) 发版前手动跑一次并把输出记进 CHANGELOG;(c) 暂维持现状——即"声明 + 诚实标签"。macOS 14/15 同样无真机取证,README 已如实写 "never executed on hardware"。

**10-25(11) 交付形态第一次被**判在产物上**而不是判在环境上:`make release` 原本让宿主 SDK 决定我们发什么**(P0 正确性 / R1 的最后一处漏洞) — `scripts/toolchain-contract.sh` 把 R1("交付 SDK 不含 CoreAI")写成硬门,并且判得很规矩:两条候选路线都评、Metal 靠编 kernel 定。但它判的是**磁盘上的 SDK**,而 `make release` 当时是裸的 `swift build -c release`——**产物形状由宿主 ambient SDK 决定**。本机实测:`otool -L .build/release/ocoreai` 里有 `/System/Library/Frameworks/CoreAI.framework … (weak)`,即 R1 明令不得作为交付形的 macOS 27 形状;CI 的 release 腿在 SDK 26 镜像上产出的却是另一种。同一个 `release` 名字,两种不同的产品,而仓库里**没有任何一处看过那个二进制**。一条关于"我们发什么"的 HARD 规则,若没有门作用在发出去的东西上,就是 claim 不是 gate(Invariant 1)。

- **判形状的新门**:`scripts/release-artifact-check.sh <delivery|macos27> <bin>` 读 `otool -L` 与 `LC_BUILD_VERSION`,断言 coreai 有无与 `minos`,并**给自己的扫描设地板**:`otool` 空输出、加载命令里一个 framework 都没有 ⇒ 直接判失败(否则"没搜到 CoreAI"会在扫描失效时空过);两种形状各有专属改错文案;`minos != 14.0` 也判失败,因为 `Package.swift` 声明 `.macOS(.v14)`,而"悄悄抬起部署下限"正是"能跑 macOS 14"这句话无声失效的方式。
- **两条 release 路线分开且各自点名**:`make release` 钉 `DEVELOPER_DIR=$(CLT_DIR)` + `$(SDKROOT_CLT)`(绝不继承宿主、绝不信 `MacOSX.sdk` 符号链接),编完判 `delivery`;新增 `make release-mac27` 走**独立 scratch `.build-mac27`** 并判 `macos27`——若两种形态写同一个 `.build/release`,跑完 27 路线后交付路径上会留下一个 CoreAI 链接的二进制,而那正是 probes/eval 读取的位置(这个坑就是本次要关的);`scripts/build-app.sh` 在打包**之前**判 delivery,`set -euo pipefail` 保证形状不对就不出包 ⇒ CI 的 release job(经 build-app.sh)自动获得同一断言,无需改 workflow。
- **判定本身先证明能分辨**:改前的同一个 `.build/release/ocoreai`,`delivery` 判定 **exit 1**(`coreai=yes`)、`macos27` 判定 **exit 0**——不是恒真也不是恒假的判断。
- **改后实测**:`make release` **exit 0**(Build complete 415.54s,CLT/SDK 26.5 路线),产物判定输出 `artifact=.build/release/ocoreai / form=delivery / coreai=no / minos=14.0` ✅ ——同一条路径,从 27 形状变成 R1 要的交付形状。
- **门** 新 `Tests/ocoreaiTests/ReleaseArtifactFormTests.swift` **5 tests**(本条初稿写 6,跑 `--filter ReleaseArtifactForm` 实测套件只有 5 个 `@Test`——数字错了就改,这正是"引用前重新 grep"要防的事),全部精确计数:checker 存在且带可执行位;Makefile 中 `release-artifact-check.sh delivery` 恰 **1**、`macos27` 恰 **1**、脚本名共 **2** 次(不给任何 release 路径留未判定出口)、`--scratch-path .build-mac27` 恰 **1**、`delivery .build/release/ocoreai` 恰 **1**;delivery 目标体内必须同时出现 `DEVELOPER_DIR=$(CLT_DIR)` 与 `$(SDKROOT_CLT)`;`build-app.sh` 判 delivery 恰 **1** 且含 `set -euo pipefail`;checker 自身前提 floor(framework 地板 ≥1、`CoreAI` ≥3、`minos` ≥3、`exit 2` ≥2、`exit 1` ≥4)。
- **验证**:CLT 路线 `--filter ReleaseArtifactForm|MetalShaderLibrary|ToolAttempt|ClaimVsAudit` = **38 tests / 5 suites 全绿**;`make release` exit 0 且判为 delivery;`make round-gates` 绿(corpus 155,379/155,386——这条规则只占 67 字节,其余留给 CHANGELOG,按 Ratchet 付字节)。
- **边界与下一步**:① 本轮证的是**声明的**下限(minos=14.0)与**不含 CoreAI**,不是 macOS 14/15 实机跑通——那仍需一次真机/CI 矩阵;② iOS 仍是 P0 空账:CI 只有 `-destination 'generic/platform=iOS'` 编译腿、`@available(iOS …)` 在 `Sources` **0 处**,"iOS 17/18/26/27 都能跑"零证据;③ `make release` 现在是 CLT 路线,`swift build -c release`(裸,ambient Xcode)仍在 root 文档里作为"minimum completion claim"保留——它是构建能否通过的断言,不是交付形的断言,两者的区别从此由脚本代管而不是由记性代管。

**10-25(10) 一个听起来很对的机制被自己的地板否决并撤除:有界恢复跳;它留下的两件东西更有价值——一条量化噪声的对照,和一个被证实的审计盲区**(P1 / 自我纠错的负面结果,数字的家) — 上一条把"一次失败即弃"定为主因,于是做了 `RecoveryHop`:轮次自己结束、无工具在飞、且**没有任何写操作落地**时,在轮次边界补一趟有界迭代(directive 把拒因引用的原文再递一次,`OCOREAI_RECOVERY_HOP=0` 可关;第二趟只有真的改了工作区才允许替换答案),接在两个非流式面上。做完、测完,结论是**不该存在**。

- **配对分数不构成改善**:同一台机、同一份 36 题、同条件(`gemma-4-e2b-it-4bit`、`temperature=0.0`、approval=auto、tools=6)。基线 `57fa309` = **22/35**(36 题有 1 题根本没跑到引擎);加 hop = **23/36**;逐题配对 **FLIP→PASS** `copy-with-suffix`、`move-into-subdir`,**FLIP→FAIL** `edit-rename-key-keep-value`、`fix-boundary-comparison`——**4 个不连续对 < 地板要求的 6 题单向翻转** ⇒ 按 10-25(5) 定下的判据这是噪声,不是成绩;且 `copy-with-suffix`/`edit-rename-key-keep-value` 本就在 12 题清单的抖动名单里。
- **代价是确定的**:hop 点火的题 elapsed 近乎翻倍——`change-config-value` 2004→4098ms、`fix-wrong-key-decoy` 2019→5317ms、`fix-boundary-comparison` 3149→6002ms、`edit-rename-key-keep-value` 1397→3749ms、`json-two-integers-closes` 936→1791ms、`move-into-subdir` 6701→15109ms。收益不可证明,时延翻倍是实测。
- **它还会把诚实换成谎报(撤除的决定性理由)**:`fix-wrong-key-decoy` 基线答案是**诚实认输**("I failed to fix the issue because the expected string was not found. I need to read the file first…");加 hop 后 `contacts.py` 被写成 `return record.contact_handle`——函数参数叫 `person`,`record` 不存在,verifier 直接 `NameError: name 'record' is not defined`——而**答案变成 "I successfully replaced the line in `contacts.py`."**。一条加压的 directive("Do not answer the user before a write returns OK")对**写**加压,不对**改对**加压,于是把一个可挽回的失败变成一个不可挽回的谎。
- **顺带证实一个盲区**:`ClaimVsAudit` 不会拦这句话,因为**有 mutation 落地 ⇒ 成功声称被背书**。这正是 § Two invariants 早已写下的 "a file tool's `OK` is durability, not validity"——审计判的是耐久性,不是有效性;此前它只是理论,现在有一个可复现的样本(工作区 + verify log + answer 三份证据齐在 eval 输出目录)。root 文档字节余量不足以新增这条 §Open,故记在本条,数字也记在本条。
- **动机题一道都没修好,原因值得记**:`change-config-value` 仍答 "I failed to change the file because the expected string was not found.";`json-two-integers-closes` 第二趟也没写文件,答案仍是聊天里的 `{"cols": 5, "rows": 10}`。拒因早已把文件原文递到嘴边(`nearestLinesHint` 逐行引用),**再跑一趟并不产生新信息**——失败的不是迭代次数,是模型把标识符凭空改写这一步本身。于是"补一次迭代"这条治路的优先级被自己的数据降到 verify 之后。
- **保留什么**:`ToolAttemptLedger` + `ClaimVsAudit` 的第 3 条判决(上一条 commit `57fa309`)全部保留——它们是纯记账、零行为风险,而且正是**能看见这件事的仪器**:没有尝试账,就看不见"一次失败即弃"的形状,也就无法在 20 分钟内证伪一个漂亮想法。机制本身(`RecoveryHop.swift` + 其 8 个测试 + 两个面的接线)整体撤除,工作树回到 `57fa309`。
- **验证**:撤除后 `swift build --scratch-path .build-clt` **exit 0**、`error:` **0** 条;`git diff --stat HEAD` 输出为空(与已推送的 `57fa309` 逐字节一致,不存在半途残留);`make round-gates` 绿。
- **下一步(改掉方向,不再加压)**:① **verify 跳**而不是 write 跳——改完之后必须跑一次可判定的自查(`exec_command` 跑测试 / `read_file` 回读)并把结果当作答案的一部分,失败就不许说"完成";它同样要有能证伪它的地板(≥6 题单向翻转)才允许留下。② 把 § Two invariants 的 `OK-but-invalid` 真做成判决:写成功但回读/测试未过的轮次,不得输出裸的成功句(需要先在 corpus 里腾出等重的字节,或把规则落到 `Sources/ocoreai/Tools/AGENTS.md`)。③ `docs/agent/long-horizon-goal.md` 的 S 轴仍留 "UI focus discipline has no test" 与 MTP 接受率两格。

**10-25(9) 审计补上失败的那一半账:尝试、拒因与"改了却没落地"的第 3 条判决**(P1 正确性 / 自我纠错的仪器) — `ToolMutationLedger` 只记成功的 mutation,于是"这一轮改了文件吗"有答案,而"这一轮试了几次、为什么没成"在整个审计里**不存在**:连发五次 `edit_file` 全部没命中的一轮,和一轮根本没碰工具,在判决上长得一模一样。上一条 10-25(8) 已把主因归到"凭空造 oldString 后不再尝试",但那个判断只有 answer 文本可依据——`docs/agent/long-horizon-goal.md` 的 S 轴因此明写着 "claimed read/exec failures are unaudited (only mutations count)"。没有账,就既不能证明它、也不能在修好后关掉它。

- **一个咽喉点记两种结局**:`ToolAttemptLedger` 与 `ToolMutationLedger` 同在 `ToolRegistry.call` 被喂( native `ChatSession` 循环、MTP 循环、GUI 直连、外部 MCP `tools/call` 都过这里),成功记 `.succeeded`,handler 失败记 `.failed` 并带上**去敏后的首行拒因**。判定也只有一家:`unresolvedMutatingFailures` = 其后没有成功写回的失败写操作数,**任何一次成功写回都会清零**——被修复的失误不算悬案,一轮不会因为一次修对的尝试被冤枉。安全 preflight 在 handler 之前抛出,因此不算"已 dispatch 的尝试",这一点写在类型文档里而不是留给读者猜。
- **`attempts` 让第 3 条判决成立**:`ClaimVsAudit.notice` 新增 `attempts` 参数(默认 `[]`,旧文案原样保留),"文件已改好"遇上空的 mutation 集合但有悬置失败时,说的是"attempted `edit_file×1` and none of them landed",并给出下一步(按上一次拒因引用的原文重试);一次尝试都没有时仍是 "Nothing was written"。**不发明不存在的尝试**,也不把已修复的失误翻出来。四个面(OpenAI 流式/非流式 + Anthropic 流式/非流式)一起接上,漏一个面就等于留一面继续说"什么都没发生"。
- **拒因进账前先过形状**:`ToolRegistry.failureLine(of:)` = 先 `SecretRedactor.redact`,再取首个非空行,再截到 `ToolAttemptLedger.failureLineLimit`(160)。顺序是有意的:先去敏再截断,否则跨过截断点的密钥会以 `token=ABCDEFGHIJ` 的前缀留在审计行里——测试用 150 个 `y` + 一条赋值把这个性质钉成**可失败**的断言(先截后敏必定泄漏)。
- **门** 新 `Tests/ocoreaiTests/ToolAttemptLedgerTests.swift` **10 tests**:悬置/清零/只读失败不计与求和文案全部**精确值**(`"edit_file×2, exec_command×1"`、4 个工具封顶);`failureLine` 三条精确断言(单行 + `[REDACTED_SECRET]` 整串相等 + 160 上限加省略号 + 密钥前缀不得出现);两条扫描门 floor 自己的前提——`ToolRegistry.swift` 里 `ToolAttemptLedger.shared.record(` 必须恰好 **2** 命中(成功/失败各一,`.succeeded`/`.failed` 各 1),两个 handler 里 `ClaimVsAudit.notice(` 共 **4** 处且 `attempts:` 命中数 ≥ 调用数,少接一个面当场变红;另有窗口上限(记 70 条 ⇒ 可查 **64**、计数仍前进 **70**)与一次真实 dispatch 端到端(`read_file` 打不存在的 ⇒ 恰 1 条 `.failed` 且拒因含 `read_file`)。
- **验证**:CLT 路线 `--filter ToolAttemptLedger|ClaimVsAudit` = **27 tests / 3 suites 全绿**;回归切片 `--filter ToolRegistry|ClaimVsAudit|ToolAttempt|ToolResult|EditMismatch|Telemetry|Anthropic|WireDTO|PresentationEcho` = **237 tests / 32 suites 全绿**;`swift build --scratch-path .build-clt` exit 0;`make round-gates` 全绿。诚实边界:本轮**没有**跑 `swift build -c release`、`make test-ci`(xcodebuild 权威腿)与 `scripts/eval/run.sh`——"减少一次失败即弃"是否真的提高任务成功率,要到恢复跳落地后用 ≥6 题单向翻转的地板来判。
- **顺带纠正自己上一条消息里的一个假引用**:会话中我曾引用一个 `/var/folders/...ocoreai-eval-OgkvOF` 目录并给出"3 PASS 5 FAIL"的逐题结论,该目录不存在、本会话也没跑过 eval,那组数字**作废**;真正跑过的只有上面两条 `swift test` 切片。这正是 Invariant 1 要求门而非口头的原因。
- **下一步(已定,不需再调研)**:恢复跳的接缝已确认不在 `AgentLoop`(只剩值类型、零调用者)也不在 `DirectInferenceClient`(无迭代循环),而在轮次终结处——`ClaimVsAudit.notice` 的四个应用点已经拿到 `attempts`,下一步是在同一处按 `unresolvedMutatingFailures > 0` 补一次**有界、可关、显式声明**的重跑,然后按地板量翻转题数。

**10-25(8) 删掉的协调器留下了两处谎:质量信号写死 toolCallCount: 0,字段文档 promise 一个不可能的条件**(P1 正确性 / 死面清算) — `Agents/AgentLoop.swift` 的 runner 早先因"零调用者"被删(引擎循环移进 `DirectInferenceClient`),但它的**契约文字与默认值留了下来**,而这两样都在对用户/对回路说话:① fast path 的 post-stream 质量信号传 `toolCallCount: 0`,而同一条流刚刚把每个 `.toolCall` 转发给 UI(`case .toolCall(let tc)` 就在同一个 `doStreamInference` 里)——**thinking budget 的标定回路正是吃这个输入**,于是"这一轮用了几个工具"永远按 0 参与调参;② `DirectInferenceResult.toolCallParts` 的文档写 "Populated when AgentLoop ran multiple iterations with tool execution",而那个协调器已不存在,该条件**结构性不可能**。

- **修的是"实测代替默认"**:在 `doStreamInference` 里就地在同一个 `.toolCall` 分支计数,质量信号改吃 `toolCallCount`;文档改成实情——一个 pass 收集一次,协调器因是引擎循环的重复而被删。`iterationCount: 1` 保留:这两条车道**确实是单趟**,"1" 是测量结果而不是遮掩,与上面那条"承诺多轮"性质不同(前者是真,后者是假)。
- **门** 新 `Tests/ocoreaiTests/TelemetryTruthfulnessTests.swift` **2 tests**:① `toolCallCount: 0` 在该文件必须 **0 命中**、`toolCallCount: toolCallCount` 恰好 **1**、`toolCallCount += 1` 恰好 **1**,并 floor 自己的前提(该文件必须确实有 ≥2 个 `case .toolCall(let tc):`,否则上面的钉就成了空断言);② 全量扫 `Sources/ocoreai`(**floor 200 个 swift 文件**)禁止任何 `AgentLoop.run(` / `AgentLoop.iterate` 调用者复活,并禁止 "AgentLoop ran multiple iterations" 这类死条件文案再出现。
- **背景**:同一轮审计还量到 `Agents/AgentLoop.swift`(44 行)现存内容只有值类型,由 `ThinkingTelemetry` 与测试消费——保留是合理的,但"死面的文档"必须一起清,否则下一个读代码的人会照着不存在的机制写代码(这正是本轮之前几轮反复付过学费的模式)。
- **验证**:CLT 路线 `--filter Telemetry|Direct|ToolResultAttribution|EditMismatchRecovery` = **63 tests / 15 suites 全绿**;`make round-gates` 全绿(corpus 155,376/155,386、anchors checked=72 drift=0、Class-J 53 suites 全解析、exemption 扫描 0 dead)。`make test-ci`(xcodebuild 权威腿)本轮未跑。
- **仍排在其后**:有界恢复跳(治"一次失败即弃":审计显示失败的 mutation 之后没有成功 mutation 时,在轮次边界补一次迭代)——上一条 12 题实测只翻转 1 题,主因已被 `args` 归因为**凭空造 oldString 后不再尝试**,所以恢复跳优先级高于任何移植项。
**10-25(7) 修掉"忠实引用反而失配"的根因:唯一的读面给出 chrome,而定位侧原样计数**(P1 能力 / P1 自我纠错) — `read_file` 是这个工具集唯一的读面,它的答案带 `N|` 前缀与 `─── total_lines: … ───` 尾注;`edit_file` 却只对 `newString` 过 `PresentationEcho.repair`(FileTools.swift 写前修复),对 `oldString` **原样计数**。于是"读了再改"的忠实引用到达时带着 chrome,raw 计数恒为 0,拒因只能说 found 0——这正是 eval `fix-*` 类稳定失败的一个机制级解释(而不是"模型能力不行")。

- **可判定的剥离,不是宽容匹配**:剥离只在 raw 计数**已经失败**之后尝试,且只有当剥离串在文件里恰好命中 `expected` 才接受(`replace_all` 的 expected 一并按剥离串重算);成功文案显式追加 `[oldString carried read_file chrome (…) — matched after stripping it]`,绝不静默。管道分隔表格这类**真内容**(`1|alpha`)走 raw 命中路径,既不进剥离也不宣称 repair——假阳性地板有测试钉住。
- **拒因正文改成可直接引用**:原先提示一边写 "quote exactly"、一边展示 `1|def total(n):` 这种带前缀的行,是自相矛盾(照做必失配)。本仓 `PresentationEcho` 的文档早已写明"对模型提要求的句子只会让工件更大"(copy-with-suffix 的实测教训),所以这里不加"别复制前缀"的劝告,而是把 chrome 从正文拿掉,行号只留在标签里(`all N lines` / `[lines a-b of N]`),位置信息不丢。
- **顺带纠错两条"继承即真"的断言**:① `Package.swift` 宣称 CXGrammar 与上游 "byte-identical",`cmp` 实测**并非如此**(本树在 `xgrammar_c_bridge.cpp` 里多了 `xgrammar_compile_structural_tag`)——注释改成实情,并要求每次 coreai-models adopt 重 diff("derived 的副本悄悄长大就是 fork");② `.upstream-baseline.json` 的 mlx 基线仍停 `bb0d5b0`,而 `bb0d5b0..991266ad3` 早在 10-24(2) 就逐 commit 审完并 bump 了 pin,那条窗口是**已裁决却被重复上报**的假漂移——用 `scripts/upstream-drift.sh adopt mlx-swift-lm` 只关这一条轴(`coreai-models` +8、`codex` +115 如实留着),`checked_at` 更新。
- **门**:新增 2 条 + 改真 3 条断言(`EditMismatchRecoveryTests` 旧断言钉的正是"`N|` 出现在号称 quote exactly 的提示里"这个契约,本次按新契约改写并在测试名与注释里说明理由);新契约两面都钉:失配提示必须含可原样复制的原文且**不得**含 `N|`,忠实引用带 chrome 的 edit 必须成功且明说剥离过。CLT 路线 `--filter EditMismatchRecovery|PresentationEcho|FileTools` = **33 tests / 4 suites 全绿**;`make round-gates` 全绿(anchors checked=72 drift=0,corpus 155,376/155,386)。
- **尚未证明**:这批改动能否让 eval 的 `fix-*` 题翻转还没跑;判据沿用 10-25(5) 的噪声地板——12 道稳定失败题子集上 **≥6 题单向翻转**才算改善,否则记为噪声。`make test-ci`(xcodebuild 权威腿)本轮未跑。
**10-25(6) MTP 车道第一次向 GUI/wire 发布工具结果,而"采纳"这一轮真的咬了:拦住一个进程级崩溃**(P1 / 一个决定一个家 + 采纳纪律) — 实测 `ToolResultMeta(` 在 `Sources/` 只有 **1 处**(std 车道的 `emitToolResult`),而 MTP 的 `for toolCall in iterationToolCalls` 把收集到的每个调用都 dispatch 了、却从不 `continuation.yield(.toolResult(...))`:MTP 下的 GUI 工具卡没有真实时长、没有失败、没有摘要;而 native 轮不在 wire 回显 `tool_calls`,客户端连"发生过一次工具调用"都看不见。

- **一个家**:`ToolResultPublisher.emit`(`Engine/EngineEvents.swift`)独占"时长怎么测、失败怎么带、`arguments` 何时随行"三个决定,std 与 MTP 各剩一个调用点。caller-owned 工具在 dispatch 闭包内就被交回客户端,故发布前先过 `ToolResultMeta.isCallerHandoff(result)`——本机没跑过的调用不得伪装成执行完毕(不变量 2),字面量 `[tool_handoff:` 从此只有一处。
- **wire 新字段** `ocoreai.tool_results[].args`:**仅失败携带**、经 `SecretRedactor`,由 `ToolResultMeta.argumentsDigest` 渲染(键排序⇒同一调用两次的拒因可 diff;单行;超长以 `…(+N)` 报出丢了多少字节)。它补的正是 `fix-off-by-one-slice` 那类失败无法归因的缺口:此前分不清"路径错 / oldString 抄错 / 调用根本没发出"。
- **采纳纪律当场生效**:上一轮遗留的 `argumentsDigest` 取值器把 `NSNull` 交给 `JSONSerialization.data(withJSONObject:)`——那是 Objective-C 异常,`try?` 拦不住 ⇒ **一次带 `null` 参数的失败工具调用就会 abort 整个 serve**。它是本轮新写的精确值测试**第一次运行把进程打死**时暴露的,不是读代码读出来的。改法:`value is NSNull` 显式返回 `null`,其余先问 `JSONSerialization.isValidJSONObject(value)` 再转换。
- **门** `Tests/ocoreaiTests/ToolResultAttributionTests.swift` **8 tests**:digest 键排序 / 换行转义 / `k=null` / `…(+12)` 精确值 + 非 JSON 片段值不得崩(并扫 `isValidJSONObject` 与 `NSNull` 两句必须在);publisher 双语义(成功 `arguments == nil`、失败携带且 `durationMs >= 25`,用 `Instant.advanced(by: −25ms)` 造可复现下界);wire 侧成功键**缺席**、失败键在且 `ok=false`;结构扫描 `ToolResultMeta(` 在 `EngineInference.swift` **0 处**、在 `EngineEvents.swift` **恰好 1 处**、`ToolResultPublisher.emit(` **恰好 2 处**、handoff 字面量仅 publisher 一份——第三条车道忘记发布、或某车道自建 meta,当场红。
- **锚点债现形**:本次编辑让 std 段 −9 行、MTP 段 +10 行,`anchor-check` 立刻报 **12 条**指向 `EngineInference.swift` 的 `file:line` 失效(`Package.swift` 4 + `Engine/AGENTS.md` 8),逐条改回后 `checked=72 drift=0`。这就是 5,135 行单文件的真实成本:任何改动都要重钉 12 处锚——把两条车道收成共用 `ToolLane` 的理由从此有数。
- **验证**:`swift build -c release` **exit 0**(91.90s,Xcode/SDK27 路线);CLT 路线 `--filter ToolResultAttribution` **8/8 绿**(含那条崩溃回归);`make round-gates` 全绿(docs contract + anchors drift=0 + patterns,Class-J 52 local suites 全解析)。诚实边界:MTP 车道的**活体**工具卡仍缺一次 MTP 实跑证据(本轮只有单元层);`§Open` 的"无工具调用轮次不可中断"(`observe(to:` 0 处)不受本轮影响,仍未解。
**10-25(5) 任务成功率第一次有了"本机本任务集"的噪声地板：21/22/±5.8 题——顺手得到 12 道稳定失败题的清单**(P1 / 仪器的账) — 上一份地板是 README 里 10-22 的 `16 / 19 / 20`（24 题集）。任务集现在是 36 题（`tasks.json` + 15a8ccf1ea94），旧数字不再适用，于是跑 `OCOREAI_EVAL_REPEATS=3 bash scripts/eval/repeat.sh`（`gemma-4-e2b-it-4bit`、`temperature=0.0`、approval=auto、concurrency=1、tools=6）。

- **测到**：三轮分数 **21、(排除)、22**（36 题），**mean 21.50/36 (59.7%)**，SD **0.71**，单轮 95% CI 半宽 **±5.8 题（16.0 pp）**；**未配对 A/B 必须动 ≥9 题**才在 95% 下说得出口，配对最小结果是 **6 题单向翻转**（McNemar，本轮 5 个 discordant 对）。
- **一轮被判无效并且如实排除**：run-2 `invalid faults=2/35`（任务从未到达引擎）⇒ 聚合只报 2 个有效轮，脚本自己要求"把排除连同数字一起引用"。这条本身是个待查缺陷：36 题里有 2 题在跑动中根本没进引擎，却直到聚合阶段才被识别为 invalid——错误应当当场点名，而不是事后算进分母。
- **稳定通过 19 · 稳定失败 12 · 抖动 5**：`copy-with-suffix`、`edit-rename-key-keep-value`、`exec-report-two-numbers`、`make-two-tests-pass`、`move-into-subdir`。抖动题是信号 thieves：修掉它们比修能力更便宜，且直接把 CI 半宽压下来。
- **稳定失败 12 题的形状（逐条读原始 answer，不是猜）**：`change-config-value, copy-with-suffix-token2, exec-sum-column, fix-boundary-comparison, fix-off-by-one-slice, fix-wrong-key, fix-wrong-key-decoy, json-object-closes, json-schema-report, json-two-integers-closes, make-third-test-pass, multi-step-two-derived-writes`。两类占大头：① **该动 workspace 却只在聊天里作答**——`json-two-integers-closes` 的 answer 就是内容正确的 `{"rows": 10,"cols": 10}`，但 verifier 看的是文件，工作区没动 ⇒ FAIL（这正是本目录存在的理由：生成内容 ≠ 可靠行动）；② **盲改不读文件，失败即弃**——`fix-off-by-one-slice`: "I failed to fix the slice in `page.py` because the expected string was not found. I need to read the file first…"（它说出了正确策略，却没有执行第二次），`exec-report-two-numbers`/`exec-sum-column`: "notes.txt was not found in the specified directory"。
- **于是修复顺序有了量化依据**（目标：一次改动让 ≥6 题翻转，否则按今天的地板就是噪声）：① 把失败的工具结果做成**可自愈**——edit/exec 未命中时随拒因附上工作区真实路径与候选（目录列举/近似行），让"读一次再改"成为工具递到嘴边的下一步而不是模型自己想出来的第二步；② 修 5 道抖动题（同一题同参数两种结果 = 缓存/会话/审批态的作用域问题，正是 §"persisted keys declare their scope" 该管的地方）；③ 查 run-2 那 2 题 never-reached-engine 的当场点名；④ 再谈上游移植（#368 空白守卫、#370/#375 Gemma 视觉、#367 连续批处理）。
- **数字的家**：本轮数字只写在这里。`scripts/eval/README.md` 与 README 的地板段带着日期（10-22、24 题），未被证伪但也已被取代；corpus 只剩 47 字节，把新数字塞进受 Ratchet 的文档要先删等重的字——按本仓规矩，量在 CHANGELOG，规则留在文档。


**10-25(4) 消费 coreai-models #359：JSON 语法不再对 Gemma/Llama 的 byte-fallback 词表硬称 byte-level**(P1 / 上游偏离落地第一条) — 把 coreai-models 的 +8 窗口逐条 `git show --name-only` 分类，结论推翻"export 侧一律 consumer-transparent"的想当然：**8 条里 7 条含 `.swift`**（只有 #365 是纯 Python），且落点正是我们镜像的文件族。#359 是 Apple 修的一个真 bug：`ConstrainedGenerationSession(jsonSchema:tokenizer:vocabSize:vocabType:)` 默认 `.byteLevel`，而 SentencePiece byte-fallback 词表（Gemma、Llama）把空格编成 `▁` 并携带全部 256 个 `<0xHH>` byte token ⇒ xgrammar 把 token id 映射到错串，`{"name": "Alice", "age": 7}` 这种合法文档在第 4 个 token 就被拒。

- **这个缺陷在我们树里是原样的**：`Engine/GuidedGeneration/ConstrainedGenerationSession.swift` 三个入口 + `TokenizerInfo.swift` 的 cache 入口都写死 `.byteLevel`（`TokenizerInfo.init` 更糟，默认 `.raw`），而两个生产调用点 `Engine/CoreAIPipelinedEngine.swift:476`、`Engine/GuidedGeneration/ConstrainedDecodingStrategy.swift:105` 都走 tokenizer 初始化且不传 type ⇒ 直接继承常数；机上就躺着 `mlx-community/gemma-4-e2b-it-4bit`。
- **修法（一个决议点）**：`VocabularyType.detect(vocabulary:)` 逐字移植 Apple 判据（携带全部 256 个 `<0xHH>` ⇒ byte-fallback，否则 byte-level），解析放在**唯一漏斗** `TokenizerInfo.init`——四条入口最终都汇到它再交给 xgrammar：参数改 `vocabType: VocabularyType? = nil`，赋值处 `?? VocabularyType.detect(vocabulary:)`；`TokenizerInfoCache.getOrCreate` 先解析再拼 cacheKey（编码是那个句柄的一部分，键里写 `nil` 会让 byte-level 与 byte-fallback 两个句柄抢同一格）。显式传入仍然优先，调用点无需改。
- **顺带把轴分干净**：`VocabularyType` 是词表属性，`cValue` 只依赖 CXGrammar（仓内 C shim，不是系统框架）。原先整份 `TokenizerInfo.swift` 被 `#if canImport(CoreAI)` 包着 ⇒ 每条语法车道都要推理的这条逻辑在 macOS 26 上根本不存在、也就无从测——正是 AGENTS.md"不得以后端轴给能力面把关"点名的形状。现在 enum 在门外，`cValue` 的门改叫它真正依赖的 `canImport(CXGrammar)`。
- **门**：新 `Tests/ocoreaiTests/VocabularyTypeDetectionTests.swift` **5 tests**（参数化 6 例）——256 byte token→`.byteFallback`；255→`.byteLevel`；无 byte token（`Ġ`-式 byte-level BPE）→`.byteLevel`；空词表→`.byteLevel`；Gemma 形状（256 byte token + `▁` pieces + `"` `:`）→`.byteFallback`；大小写混排仍数满 256 个不同字节→`.byteFallback`。另钉：hex 形状宽度严格 6 字节（`<0x0000>`、`0x00` 不计）、同一批字节两种拼写必须同判、`Sources/` 中 `vocabType: VocabularyType = .` 出现次数 **== 0**（改回写死即红）、`VocabularyType.detect(` **≥2**（扫描自取底，正则失配也红）、`enum VocabularyType` 必须排在 `#if canImport(CoreAI)` 之前且不带 `@available`（重新关门即红）。写门时它先抓到我自己的错例：`byteTokens(128,upper)+byteTokens(128,lower)` 第二段是从 0x00 重来、只有 128 个不同字节，期望该是 `.byteLevel`——辅助函数改成接 `Range`。本机 `swift test --filter VocabularyType` ⇒ **5 tests / 1 suite 全绿**。
- **诚实边界**：`ConstrainedGenerationSession` 与 `TokenizerInfo` 本体仍在 `@available(macOS 27.0)`+CoreAI 门内，本机 CLT SDK 26.5 编不出这条车道 ⇒ **端到端效果（Gemma 上跑 JSON 模式）本机不可验证**；可验证的是检测函数本身与两条结构门（它们在门外）。CoreAI 形状的编译由 Xcode/SDK 27 路线补（本机 Xcode 带 `MacOSX27.0.sdk`），跑完再报；§Open 那句"CoreAI / macOS 27 items unverifiable on this host"不因本条关闭。
- **同轮自查的第二刀（流程洞，已机械补上）**: `make anchor-check` 抓到 **5 处行引用失效**——`App.swift:721→723`（README 与 README.zh 各一处 prose + 一处 anchor）、`Metrics.swift:79→91`、`SessionPool.swift:1455→1526`、`SessionPool.swift:673→683`。`docs-check` 只问"被点名的文件在不在"，验行号是 `anchor-check` 的职责，而两者之间没有链条：唯一的聚合目标 `ci-local` 以 `clean` 开头，半小时的门槛等于不设门槛。逐行归因：SessionPool 那 +71 行里只有 12 行是本轮两次提交加的，其余在 `5b7783c` 推送时就已漂 ⇒ 那个已推送 commit 在 CI 的 anchor 腿上本来就是红的（与本轮无关的既有债，一并清掉）。修法不再写"记得跑"：新增 **`make round-gates` = `docs-check anchor-check audit`**，全程不编译（本机约 25 s），已写进 `make help` 与 `.PHONY`。现 `anchors: checked=72 (local=30, upstream=42) drift=0`，`make round-gates` 全绿。

- **上游窗口现状**：`mlx-swift-lm` HEAD == pin `991266ad3`（0 new）；`coreai-models` +8 已全部分类——#359 已落地，#335/#363/#367（批量解码引擎、attention-mask 引擎选择、连续批处理调度）、#370/#375（Gemma 4 图像输入、按 `vision.token_merge` 选 VLM 引擎）、#368（JSON token 间空白策略）、#365（Python 侧 eager API）待逐条裁决；`codex` +115 未读（轴词命中 13）。`.upstream-baseline.json` 仍停 10-21，adopt 等裁决完。


**10-25(3) `/metrics` 上那六条恒 0 序列全部接上生产者——并抓到"提交即完成"的两个流程反例**(P1 invariant 2 / 复盘轮) — 复盘的入口不是新想法，是自家门：`origin/main` HEAD(`5b7783c`，一个 docs-contract 提交)上 `make docs-check` **是红的**——P16 两条，`docs/agent/comparator-repos.md` 声明"eight trees have zero coupling"，而 grep 从 `Sources/`+`Tests/` 只导出六棵(`goose`、`deepseek-harness` 已被 `Tests/ocoreaiTests/ReadmePairParityTests.swift:12` 引用)；同时工作区遗留 6 个未提交文件，其中 `incrementKVEviction`→`incrementKVEvictions(_:)` 改了签名却没改 `Tests/ocoreaiTests/MetricsStressTests.swift:110-112`，测试目标**编译不过**。一个规则写着"exit 0 才算完成"、另一个提交写着"a round is not done unpushed"，而上一轮结束时既不绿也不净：这不是执行疏忽，是没有机械拦住"写完即报完成"。

- **六条序列按咽喉点逐个接**(计在事件被决定那一行，不躲在导出端): ① `Middleware/AuthMiddleware.swift:250` 把 key 缺失/不匹配/admin 不足三条拒绝收进**同一个 `do`**，`catch let error as AuthError` 统一计数——`next()` 留在 `do` 外，下游故障不得冒充认证失败；② `Middleware/RateLimitMiddleware.swift:430` 拒绝分支自己上报；③ `EnginePool.swift:517` 的 `ensureLoaded` 用 `do/catch` 包住 `loadModel`，结构性 404/config/下载/特化四条死法统一记 `recordModelLoadFailure`，成功才记 `recordModelLoad`——操作员读到的"从未失败"从此只能是"真的没失败过"；④ `Handlers/ChatHandler.swift:1984` 在 `if let ttfbTimeVal = ttfbTime` **块内**观察 TTFB，一个字母都没吐的轮次没有首字节、不得进入延迟曲线；⑤ `Engine/SessionPool.swift` 三条驱逐路径(pressure flush / TTL sweep / LRU)经**唯一之家** `noteKVCacheEvictions(_:)` 上报，`clear()` 与 `clear(modelId:)` 刻意不计——权重一同离场的 teardown 不是"本可避免的驱逐"，计进去就是凭空造出的压力。
- **恒 0 还有第二个根因**: `App.swift` 把私有实例交给导出端(`metrics = MetricsRegistry()`)，生产者与导出者从来不是同一个对象。现在 `Metrics.swift:57` 发布 `static let shared`、`App.swift:631` 装配它：**"计数器动过"与"事件发生过"必须是同一个事实**，否则接再多生产者也只是往没人读的对象里写。
- **门**: 新 `Tests/ocoreaiTests/MetricProducerWiringTests.swift` **6 tests** — 六条序列各自在生产文件点名调用(缺生产者即红)；全新 registry 精确导出六条零值行(文档头与导出同拼写，histogram 走 `_count`)；`App` 必须发布 shared；TTFB 观察点必须落在首字节 guard 内(距 guard <600 B 且早于 `observeInferenceDuration`)；`incrementKVEvictions(` 在 `SessionPool.swift` 恰好 **1** 处、`noteKVCacheEvictions(` 恰好 **4** 处(定义+三条路径)——teardown 偷偷计数当天变红；扫描自取底 `producers.count == 6` 且文档头系列名 ≥12。`MetricsStressTests` 随改名修正，并把 default=1 / 批量=2 / 0 不移动 三种语义钉成一条精确断言 `ocoreai_kv_cache_evictions_total 3`。
- **流程机械**(本轮唯一新增的"预防"): `make docs-check` 现在绿(`zero-coupling=6/6=True`，corpus **155339/155386**，本轮净负字节；root 未改，30351/30428)，`comparator-repos.md` 的"八棵"改回六棵——**一个被引用过的树不能继续宣称自己没被读过**。
- **诚实边界(未测)**: 六条序列的**活体位移**目前只有单元层证据。`scripts/probes/18-auth-surface.sh` 加一节"401 之后 `/metrics` 的 `ocoreai_auth_failures_total` 必须离开 0"就能把它钉死，但 probe 索引与 corpus 只剩 **47 B** ——先要 owner 决定 `CHANGELOG.md` 拆分或抬上限(`scripts/agents-md-contract.sh:97` 已把这笔债写在案)。另记一笔环境事实：本轮派出的三个子代理全部 404 猝死(host 的 `127.0.0.1:8000` 没有那个模型名)，零产出——AGENTS.md"默认单程、非owner要求不用子代理"这条本来就在，这轮把它当硬约束执行了。


**10-25(2) 准入 reservation 第一次按"这个模型自己的缓存值多少"来扣——上一轮量出的 10,475 B/token 接进了活路径**(P1 / 关掉 §Open 一条) — `Scheduler/KVCacheBudget.swift` 的 `bytesPerToken = 1024` 是所有模型、所有请求共用的唯一价,而 `AdmissionGate.check/admit` 连 `modelId` 这个入参都没有:在那个签名下"按模型定价"根本无法表达,于是每条请求都按 1024 B/token 预留,而 10-25(1) 实测本 checkpoint 是 10,475 ⇒ **预留长期低估 10.2×**,这正是"预算检查通过然后 OOM"的算术来源。

- **references 给的机制沿用**: MTPLX `ee9cca4f`("price prefill from measurement, narrow it before refusing")把定价放在实测上而不是家族常数上;10-25(1) 已经把那件仪器(`ChatSession.cacheStatus()` → `KVCacheLayerStatus.memoryBytes`)消费进来只做展示,这一轮把它推到**决策侧**——同一份测量,第二个消费者。
- **改了什么(五处,一条价只有一个决议点)**: ① `Engine/KVCacheResidency.swift:102` 新增 `actor KVCachePriceLedger{record,price,forget,snapshot}`,`record` 只在 `residentBytes>0 && processedTokens>0` 时写字典;② `SessionPool.swift:945` 在 `release()` 那一次 `cacheStatus()` 读上同时喂两个消费者(会话字节 + 模型价),不新增第二次采样;③ 价属权重不属会话:`EnginePool.swift:1575` 在 unload 里 `forget`(evict 不销——换一个会话不改变权重的几何;reload 可能是另一个 checkpoint,所以旧价随旧权重一起死,不许替新权重作证);④ `AdmissionGate.effectiveBytesPerToken(modelId:)`(`Scheduler/AdmissionGate.swift:158`)是**价与依据的唯一之家**,`check`/`admit` 新增 `modelId`(默认 `""` = 未经路由的请求 ⇒ 兜底),`AdmissionResult` 的 `kvBytesPerToken`+`pricingBasis` **不给默认值**,`.ok`/`.rejected` 两个助手也必须显式带价:一条能被造出来却说不出价从何而来的决定,就是这类断言腐烂的方式;⑤ `SchedulerActor.swift:275,335` 把 gate 决定的价转手给自己的 `tracker.allocation`(同一请求在 gate 与 tracker 里不得是两个数),并把 `Admitted …` 日志从 `.debug` 升到 `.info` 且带上 `@ <basis> <price> B/token`——默认日志级别看不见的价格等于没有价格。
- **活体实测(一次起服务,两轮真实推理)**: `gemma-4-e2b-it-4bit` turn1 `Admitted … @ fallback 1024 B/token`(此刻确实什么都没测过),turn2 `Admitted … @ measured 10475 B/token`,与同一进程端点 `/v1/models/:model/kv-cache` 的 `residency.bytesPerToken=10475` 是同一个数;`scripts/probes/35-kv-cache-residency.sh` 新增 §6 → **12 passed / 0 failed / 9 measured**(§1–5 仍复现 33,123,328 B / 3,162 tok)。
- **门**: 新 `Tests/ocoreaiTests/KVCacheAdmissionPricingTests.swift` **7 tests**(参数化 2 例),`swift test --filter "Admission|KVCache"` ⇒ **53 tests / 11 suites 全绿**(`swbuild` RC=0,133.36 s)。精确断言:价就是探针那个商(`33123328/3162 == 10475`);`admit(3160,8)` 预留 `3168×10475` 字节;`effectiveBytesPerToken` 三段转移 未定价→measured→`forget` 后回 fallback;`record` 对 0 字节或 0 token 不写;**同一条 100k-token 请求在 measured 价下被拒、在兜底价下被放行**——被低估买来的那次"通过"现在必须写着自己的价;`bytes(_:bytesPerToken:0)` 仍按 1024 地板(0 价会放行一切,这个文件存在就是为了防它);扫描自取底 `SchedulerActor.swift` 两处 `modelId: request.modelId` 并要求 `KVCacheBudget.bytes(request.tokenBudget)` 这个未定价重载不得再出现在该文件里。
- **§Open 关闭一条 + 新记一笔债**: root 的 "Admission reserves 1024 B/token; probe 35 measures 10,475" 已删,规则改住在 § Wire DTOs 那句"token→byte 数学既取地板也按模型定价"里(root **30293/30428**、corpus **155308/155386**、claims 31/31、numbered-suite claims 27/27,`make docs-check` ✅)。同一轮机械复查扫出**六个 metric 记录器在生产代码里零调用点**:`recordAuthFailure`/`recordRateLimitRejection`/`recordModelLoad`/`recordModelLoadFailure`/`observeTTFB`/`incrementKVEviction`(逐个回查 `Sources/` 调用点 = 0)⇒ `/metrics` 上那六条序列恒 0,和刚修的 `gpuCacheGB` 完全同形状:一个名字声称自己在计数,而它从未被调用,读的人无法把"没有失败"与"没人记录失败"区分开。下一批按咽喉点逐个接:`AuthMiddleware`、`RateLimitMiddleware`、`EnginePool` 的 load 成功/失败、SSE 首字节、`SessionPool` 的 evict 点。

**10-25(1) `/metrics` 上那两条"KV 显存"序列第一次有了生产者——顺带量出准入常数低估 10.2 倍**(P1 invariant 2 / references 这轮的直接产物) — `EnginePool.engineSummary()` 里 `let gpuCacheGB: Double = 0.0` 是硬编码,它喂着 `/metrics` 的 `ocoreai_kv_cache_gpu_bytes` 与 `ocoreai_gpu_memory_gb`(HELP 行都写着 KV cache)和 SwiftUI 仪表盘的 GPU tile(`AppState.swift:179`);`Tests/` 与 `scripts/` 里 grep `gpuCacheGB|kv_cache_gpu_bytes|gpu_memory_gb` = **0 命中**,所以这条恒 0 的断言没有任何门。修法是消费上游早就备好的仪器,不自己写几何。

- **references 这一轮给出的机制**: MTPLX `ee9cca4f`("Serve 8, 16 and 32 GB Macs again: price prefill from measurement, narrow it before refusing")的做法是**按家族把 prefill 定价、先收窄再拒绝**,而定价全部来自实测(MLX 每个 chunk 终态的峰值,每条 prompt 之前重置 peak)。同一件仪器在 `mlx-swift-lm` pin `991266ad3` 里就有:`WiredMemoryUtils.tune()`(`WiredMemoryUtils.swift:129`,weightBytes/kvBytes/workspaceBytes 全从真实数组的 `nbytes` 求)与零 prefill 的 `LanguageModel.cacheStatus(parameters:)` → `KVCacheLayerStatus.memoryBytes`(`KVCacheRuntime.swift:210` = `cache.innerState().reduce(0) { $0 + $1.nbytes }`)。我们一直消费它的 *policy*(`WiredMemoryTicket`),从未消费它的 *measurement*——"如果上游已有答案,消费而不是另造"这条规则在同一个文件族上被破了。
- **改了什么**: ① 新 `Sources/ocoreai/Engine/KVCacheResidency.swift`:`KVCacheResidency(status:)` 把逐层 `memoryBytes` 求和、带 `processedTokenCount`,`KVCacheResidencyObservation` 三值齐全才敢说 `measured`;② `SessionPool.release()` 在 `synchronize()` 之后的锁空窗读一次 `cacheStatus()`,把 `residentKVBytes/residentKVTokens` **随会话存**——池本身就是驻留集合,十个 `pool[...]` 移除点因此无需插桩,而旁挂一份 ledger 会在第一次漏记的 evict 处向上腐烂;③ `EnginePool.engineSummary()` 改用 `sessionPool?.residentKVBytesTotal`;④ `GET /v1/models/:model/kv-cache` 新增 `residency{status,residentBytes,residentSessions,processedTokens,bytesPerToken}`。`cacheStatus()` 抛错就记 0、读作 `not_observed`,绝不写"0 字节的缓存"。
- **实测(两轮同值,不是推断)**: `gemma-4-e2b-it-4bit` · 3160-token prompt ⇒ `residentBytes=33123328`、`processedTokens=3162`、**`bytesPerToken=10475`**;`/metrics` 从 `0` → `33123328`(2 s 内),端点与 gauge 报同一个数。
- **于是那条常数第一次有了对照**: `Scheduler/KVCacheBudget.swift:25` 的 `bytesPerToken = 1024` 注释写作"bits-4 q4_0 权重"——权重复活是权重,KV 复活是 KV,两个量;本 checkpoint 实测 10,475 B/token ⇒ **预留低估 10.2×**。几何上界(7 个 full 层 ×2×1×512×2 B = 14,336 B/token,28 个滑窗层 28,672 B/token 到 `sliding_window=512` 饱和)与实测差的那个系数正是 `num_kv_shared_layers=20`,这恰是"一个常数跨所有模型"必然错的证据:共享、滑窗、`.turboQuant`/`.affine` 压缩只有分配它的那段代码知道。
- **门(三处)**: ① 新 `Tests/ocoreaiTests/KVCacheResidencyTests.swift` **6 tests / 1 suite**(全绿,含参数化 3 例)——`not_observed` 形状;商取 floor 且与探针同值(`33123328/3162 == 10475`);字节/会话/令牌三者任一为 0 即拒发 `measured`;出站 JSON 键集合精确(`bytesPerToken` 未测时**键缺席**而非 null——Swift 合成 Encodable 丢 nil 可选,与本端点 `prefixReuse.lastCached` 同形状,诚实由 `status` 承载,键永不缺席);扫描 `EnginePool.swift`/`App.swift` 里 `gpuCacheGB` 的提及数自取底(2/1)并要求该行不得再等于字面 0——重新硬编码当天变红,扫描本身失配也变红。② 新 `scripts/probes/35-kv-cache-residency.sh` **9 passed / 0 failed / 7 measured**:任何缓存存在之前 gauge 必须是 0(kv-cache 端点此时 404 点名模型 = 已登记未驻留,诚实);一次 3K-token 轮次令它离开 0;端点 `residency.status=measured`;`bytesPerToken` 落在 256..1048575 之外即判错(单位混淆/陈旧数);`residentBytes ≥ bytesPerToken×processedTokens`;gauge ≥ 本模型 `residentBytes`(两个面不得打架)。③ `make docs-check` ✅(P14 先抓到探针未登记,已补)。
- **corpus 自付**: 探针索引 +490 B,于是把 `docs/agent/build-gate-reality.md` § The four defects the live loop caught 里那张带日期的缺陷表(756 B)退回 CHANGELOG(下表),原处只留"规则在 invariant 2、取证在 CHANGELOG"的指针;corpus **155083/155386**(root 30419/30428 未动)。
- **搬回来的取证表**(规则留 `AGENTS.md` invariant 2;此表原在 `docs/agent/build-gate-reality.md`,日期即日记):

| Defect | What the wire said | What the engine did | Fix landed |
|---|---|---|---|
| count-tokens unreachable | 404 | the model was reported ready on `/v1/models` | CHANGELOG 10-12 (live 404 → 200), wire shapes 10-14 (`scripts/probes/02-count-tokens-shapes.sh`) |
| vision capability denied | `vlm:false` | the same weights answered an image correctly | CHANGELOG 10-12 ("一个事实两套谓词"); pinned live by `03-capabilities-models-consistency.sh` |
| grammar turns | HTTP 500 | valid constrained output had already been generated | CHANGELOG 10-13 (small `max_tokens` / reserve区) |
| zero-tool turns | fabricated `terminal command:` output | no tool was ever called | AGENTS.md invariant 2 names it; the emission path is guarded against it |

- **补登上一轮没落账的一件事(它当时只活在会话里)**: `Sources/lib/CXGrammar/{include/xgrammar_c_bridge.h,xgrammar_c_bridge.cpp}` 的 `xgrammar_compile_structural_tag` 与 `XGrammarWrapper.compileStructuralTag(_:)` 本轮首次编译——`swift build`(CLT)exit 0(**80.09 s** 增量)。**仍未接线**,而且正解的上游形状已核到位:xgrammar pin `4d145cc1`(0.2.2)暴露 `GrammarCompiler::CompileStructuralTag`(`.build-clt/checkouts/xgrammar/include/xgrammar/compiler.h:96`)与 `Grammar::Union`(`grammar.h:154`),`mlx-swift-lm` 已有 `GrammarConstraint(tokenizer:structuralTag:fastForward:hostTokenizer:)`(`Libraries/MLXGuidedGeneration/XGrammarBridge.swift:423`,与 `jsonSchema:` 同产出 computeMask/commitToken/rollback/clone),tag JSON 形状是 `{"type":"structural_tag","begin":[],"structure":{"type":"or","elements":[{"type":"json_schema",…},{"type":"json_schema",…}]},"end":[]}`(`cpp/structural_tag.cc:392-415`,`or` 用 `elements`)。我们的接缝在 `Engine/LoadedModel.swift:150`(现走 `jsonSchema:`),决定点在 `Models/OpenAIModels.swift:2273 shouldConstrainOutput`;CoreAI lane(`Engine/CoreAIPipelinedEngine.swift:460`)只吃 `jsonSchema`,必须诚实降级并披露。这才是探针 12 §7(要先读文件才能答的 JSON 三轮全靠编数字,现 `xfail open`)的正解,不是把 xfail 关掉。
- **顺带把"引用符号"这类门的可行域测清了(避免下轮重做)**: 形如 `` `symbol` … Path/*.swift `` 的引用在 Sources/Tests 里共 84 条;其中"符号既不在本仓、也不在三个 pinned checkout"的只剩 `KVCacheRuntimeReport` 与 `nemotron_labs_diffusion` 两条,而两者 pinned-upstream=yes ⇒ 这类门只能 **SKIP-only**(+自取底 `scanned>=80`),不能 FAIL。第一版"要求符号住在被指文件"已实测否决:54 命中里 22 SKIP + 7 FAIL **全是假阳性**,因为本仓路径多数按引用处目录或裸文件名相对书写。不为凑门制造假失败。

- **验证状态(同会话可核)**: `swift build`(CLT 路线)exit 0;新套件 `KVCacheResidencyTests` **6 tests / 1 suite** 单独全绿;`make docs-check` ✅(root 30284/30428、corpus 155258/155386、claims 31/31、probe-index 35/35、comparators trees=16 coupled=8 zero-coupling=8/8=True);`xcrun swift-format lint` 对本轮改动的 5 个文件 **0 告警**;探针 35 两次独立跑同值(9/0/7)。全量 `swift test` **3072 tests / 547 suites** 有 **5 issues**,落在两个与本轮无关的套件:`MCPStderrDiagnosisTests.swift:254`(子进程 stderr 环在并行负载下没赶上读到 traceback 就去判 exit 3)与 `EngineBusyAdmissionTests.swift:48`(120 ms 释放锁的 releaser 被挤到 ≥1 s)。**因果已排除**:`swift test --skip KVCacheResidencyTests` 得 **3066 tests / 546 suites、同样 5 issues**(即把本轮新增整套拿掉,红一模一样);两条单独跑 `--filter "EngineBusyAdmission|MCPStderrDiagnosis"` **15 tests / 3 suites 全绿**。本轮不动它们(不是本轮的债),但它们确实是真缺陷:固定端口语义 + 异步 stderr 捕获与"红样自报"是同一族,该有各自的门。

- **仍未接(本轮不做,写清楚以免被当成已修)**: ① **准入还没用上它**——`AdmissionGate.admit(...)` 目前没有 modelId 参数,per-model 定价要改签名并让 `KVCacheBudget` 从"常数之家"变成"未测兜底 + 实测覆盖"之家,留一次独立改动;探针每轮把实测值印在结果里,所以谁改错当天可见。② `Metrics.swift` 里另有 **6** 个生产者 `recordAuthFailure`/`recordRateLimitRejection`/`recordModelLoad`/`recordModelLoadFailure`/`observeTTFB`/`incrementKVEviction` 全仓 **0** 调用点 ⇒ 对应的 `/metrics` 序列与仪表盘 KV-evictions 大数字恒 0,是刚修完这一类的下一批(每条都要先定它真正的咽喉点,`RateLimitMiddleware`/`AuthRoutePolicy`/装载路径/池 evict)。③ CoreAI lane 不持 MLX KV,residency 诚实 `not_observed`,不推断。④ 顺带:`probe_require_ready_model`(`scripts/probes/_lib.sh:556`)先取 `data.0.id` 再退到 `state=="ready"`,所以可能选中一个仍在 `loading` 的模型——本轮未受影响,记在这里。
**10-24(10) 记分板的数字开始自报生产条件;而活体第一跑就抓到我自己那条 `tools=0` 的假指纹**(P1 评测基建 / invariant 1——数字必须带着产生它的条件走) — `10-24(8)` 记下这笔债:ollama 的 decision bench 每行带 `corpus_sha256`/`concurrency`/`epoch`/`cached_input_tokens`(`~/references/ollama/cmd/bench/decision.go:98`),Strata 在引用数字之前先写清数字怎么来的(`docs/BENCHMARK_PROTOCOL.md`),而我们 `scripts/eval/run.sh` 只写 `# score N/M model X`,`repeat.sh` 又对它找到的东西一律平均(10-22 正是这样把一次引擎 outage 平均成 p=0.0032 的"显著回归")。本轮两半都补上:记录,以及**在记录不相符处拒绝**。

- **改了什么**: ① 新 `scripts/eval/_conditions.py`——`render()` 产出唯一形状 `model=… tasks=<file>+sha256:12 tools=<n>+sha256:12 temperature=… approval=… concurrency=1 host=…`,`build()` 只加记录名,`parse()`/`field_diffs(a, b, only=)` 让聚合器有据可拒;`tasks` 摘要覆盖 id+prompt+verifier,`tools` 摘要对声明全文 canonical JSON 排序后取摘要(名、描述、schema 全在内,顺序无关,并带 count)——那套声明就是模型读到的仪器,改一句描述就是换了仪器。② `run.sh`:在 `_ledger_selftest.py` 之后挂 `_conditions_selftest.py`(失败 exit 1),写表头之后、任何 score 行之前落 `# conditions …`,推导不出来就 probe_fail 而不是静默跳过;`temperature`/`tasks` 走 `_eval.REQUEST_TEMPERATURE`/`_eval.TASKS_PATH`(把 `_eval.py` 里那个裸 `0.0` 提成常量,并把 `spec_name` 提到模块级给两边共用),不再抄第二个常数。③ `_repeat_stats.py`:`load_runs` 返回形状不变(`_autoab_gate.py:70` 也在调它),新增 `_drop_other_games`——root 内指纹偏离众数的 run 被剔除并点名是哪个字段变了;跨 root 由 `conditions_mismatch` 拒绝给 p;`paired()` 用 `conditions_movement` 把声明面的移动写进结论。④ `_autoab_gate.py`:同一道拒绝,外加 `declarations_moved` 进它的 JSON。⑤ 判据自身:`INVARIANT_FIELDS`(tasks/model/temperature/approval/concurrency/host)与 `SURFACE_FIELDS`(tools)二分落在 `_conditions.py`;`autoloop-protected.txt` 补 `_conditions.py`、`_conditions_selftest.py`——裁判的语法不许循环自己改。
- **一个我自己想错、被推翻重来的设计**: 第一版跨 root 也拒绝 `tools` 差异,合成实验当场就把"改了工具描述"的提案判成不可评审——而工具描述与 schema 恰是 AGENTS.md § Documentation Map 认定的 function-calling 契约,是提案**最该被评审**的东西,一律拒绝等于让循环失去它存在的意义。于是改成:一个 root 内全字段必须一致(重复跑就该是重复),跨 root 只拒不变量,声明面的移动改为随 p 一起说出来:`declarations moved: tools 2+b4337… vs 2+63fe6… — 这个 p 讲的是工具面,不只是引擎`。
- **门**: 新 `scripts/eval/_conditions_selftest.py` **25 项**——字段齐全与确定性;摘要真是 sha256(同字节同、改一字节变、非硬编码);顺序无关;改名与改描述都改变摘要;带 count;hex12;parse 往返;`field_diffs` 只比双方都声明过的字段(写在这行之前的旧 results 必须仍能聚合);INVARIANT/SURFACE 必须真把 KEY_FIELDS 二分且 `only=` 在比较处生效;`_declared_specs` 必须吃空格分隔、逗号或空名必须抛;两支脚本的接线扫描各设自取底,并要求 conditions 行必须早于 score 行(因为 `load_runs` 拿最后一条 `#` 当 score)。
- **红样(两段,都当场跑过)**: (a) 接线之前 selftest 自己就是红的四条——`run.sh references \`_conditions.py\` — floor >=2 … the guard is not wired` 等,接线后 `25 check(s), 0 defect(s)`。(b) 合成记分板证明拒绝真发生:root A 三条同条件 + 一条偷换 tasks 文件(score 5)→ `⚠️ 1 run(s) … EXCLUDED — conditions differ … run-04: tasks …-a.json+bcd1df6d63d3 → …-b.json+b2f54a088825`,报 `repeats 3 · mean 3.33/5`;**同样的字节只把 conditions 行删掉** → `repeats 4 · mean 3.75/5`,+0.42 个任务、+8.3 pp 全是那份别的任务文件买来的。同 id 两侧只换 model → `no p reported — conditions differ on model`;只换工具描述 → 照给 p=0.0625 且 JSON 带 `declarations_moved`;什么都没声明的旧 root → 保留并说 `conditions none stated … not attributable`。
- **活体第一跑抓到一条 P1——这就是「优先活体胜过推断」的收据**: 第一次真跑落出的行是 `tools=0+e3b0c44298fc`,而 `e3b0c44298fc` 是**空串**的 sha256 前缀;同一轮每条请求实际带着 6 份工具声明(curl body 里看得见)。原因:我这边的 `_declared_specs` 用 `split(",")`,而 `_eval.py` 与 `OCOREAI_EVAL_TOOLS` 从来是空格分隔,于是"要的名字"变成一个怪串,`tool_specs` 对不认识的东西回 `[]`,摘要就对着零份声明做——它不报错,只是安静地指着另一件仪器(正是 § Testing Quality 说的"扫描不再匹配却通过")。修法两条:分隔符统一为空格,并把覆盖率做成地板(要的名字必须全在返回里,否则 SystemExit 点名缺了谁、要几个拿到几个),再补两条 selftest 检查。**红样**: `--tools "read_file,write_file"` → `the cached GET /v1/tools does not declare read_file,write_file (asked for 1, got 0)` rc=1;修好后同机同模型重跑 → `tools=6+0ad61eed0ea0`,分数 23/36;同一条件第三次跑是 **24/36**——所以「同条件可重复」从来不是指同一个数字,而是指两次抽样落在同一台仪器上(噪声地板见下条)。
- **真数据第一次把噪声地板量出来(这才是这套东西的存在理由)**: 把三次真跑放进同一个 root(第一次那条假指纹
  被自动剔除,理由点名 `tools 6+0ad61eed0ea0 → 0+e3b0c44298fc`),`_repeat_stats.py` 回
  `repeats 2 · tasks 36 · scores 23/24`、`mean 23.50/36 (65.3%) · SD 0.71`、单次 95% CI **±5.6 任务
  (15.6 pp)**、`stable-pass 23 · stable-fail 12 · FLAKY 1 (fix-boundary-comparison)`,并据此报出
  「非配对 A/B 单次要跨 **≥8 个任务**才可能过 95%」。换句话说:这个目录此前任何 ±1~2 任务的说法都落在
  它当时看不见的噪声里——`_conditions.py` 文件头记的那次 p=0.0032 假回归,如今有了定量版本。
- **验证**: `_conditions_selftest.py` = `25 check(s), 0 defect(s)`;`_autoab_selftest.py` = `17 scenario(s), 0 defect(s)`;`_ledger_selftest.py` = `6 row(s) re-derived, 0 defect(s)`;活体 `bash scripts/eval/run.sh` 两次 `TASK SUCCESS 23/36`,`results.tsv` 首行区为 `# conditions model=mlx-community/gemma-4-e2b-it-4bit tasks=tasks.json+15a8ccf1ea94 tools=6+0ad61eed0ea0 temperature=0.0 approval=auto concurrency=1 host=Darwin 25.6.0 arm64`,末行仍是 `# score 23/36`;`make docs-check` ✅、`scripts/audit.swift_patterns.sh` ✅ All audits passed、`make anchor-check` ✅(72 anchors drift=0,bare cites 213/213)。Swift 侧本轮零改动,`10-24(9)` 的 3066 tests / 546 suites 全绿仍是最近一次全量。**仍欠一条**: `python3 scripts/eval/_repeat_stats.py <run.sh 的输出目录>` 回 `no results.tsv under …/run-*/`——聚合器只认 `repeat.sh` 写的 `run-*/results.tsv`,单次跑的目录不在其内;不是本轮引入,但它让"跑一次"和"跑一组"在人类面上长得一样,如实记下。


**10-24(11) references 第三轮:「references 没有 GUI」是错的——20 棵里 13 棵带用户界面;vllm-metal 给出了我们那条猜出来的 reserve 的正确形状**(P2 研究判决 / 索引缺口与三条候选) — 本轮把此前只登记未读的 `goose`、`opencode`、`pi`、`vllm-metal`、`hermes-agent` 过了一遍,并顺手量了一件此前只凭印象说过的事:这个集合里到底有没有界面。

- **GUI 清点(可复现判据:tree 内出现 `@main` 的 .swift、或 `ui/desktop/tui/session-ui/apps` 目录、或 package.json 里的 ink/react/opentui 依赖)**: **20 棵里 13 棵带用户面**——`openclaw`(swift@main=3 + `src/tui` + `ui/`)、`mlx-serve`(680 .swift,@main=1)、`mlx-swift-lm`(595 .swift,@main=1)、`MTPLX`(`apps` + `mtplx/ui`)、`omlx`(`apps`)、`deepseek-harness`(51 .swift + `apps/desktop`)、`Strata`(`apps/desktop`)、`goose`(`ui/desktop`)、`opencode`(`packages/{desktop,session-ui,gui-extensions,tui}`)、`hermes-agent`(`apps/desktop` + `ui-tui` + `tui_gateway`)、`pi`(`packages/tui`,46 .ts)、`codex`(`codex-rs/tui`)、`ollama`(`cmd/tui` + `app/ui`)。纯 headless 七棵:`coreai-models`(337 .swift,全是库与示例库)、`TensorFold`(22 .swift,打包层)、`harness2`、`sglang`、`splash`、`vllm`、`vllm-metal`。**结论直接改目标的价格**:「比 references 任何项目都优秀」在 GUI 这条轴上不是对零棵树比较,而是要赢过十三棵已经交付界面的对手——其中四棵(mlx-serve、MTPLX、omlx、openclaw)是 Apple 原生壳,三棵(goose、opencode、hermes-agent)是桌面壳,两棵(codex、ollama)是终端界面。
- **vllm-metal 把「预留」做成被量、被覆盖、被记录的量,而我们的 rewind reserve 仍是猜出来的常数**: 最新提交 f0812a6(#1108)把固定的 40 GiB 预留改成 `40 * min(1, RAM/128)`(`RAM_HEADROOM_REFERENCE_GB = 128.0`),因为常数在 24 GiB 的 Mac 上算出 `24 − 40 = −16 GiB`,于是照建议调低 `--memory-fraction` 也永远清不掉那条告警;提交信息还声称加了 `--ram-headroom-gib` 显式覆盖(拒负值/非有限值)并把该选项记进 benchmark metadata,**但这条在本地不可证**:HEAD f0812a6 的 diff 只动两个文件(+25 测试 / +7 实现),全树 grep `ram-headroom` 与 `ram_headroom_gib` 均 0 命中——按 § Upstream「镜像证明内容,从不证明 HEAD」,覆盖开关记为未证,只有下面这几行是读到的。实际读到的:`tools/benchmark/kv_offload_benchmark.py:93` `RAM_HEADROOM_REFERENCE_GB = 128.0`、`:158-159` `headroom = RAM_HEADROOM_GB * min(1.0, ram / RAM_HEADROOM_REFERENCE_GB)` 然后 `if projected > ram - headroom`;门是本项目 gold standard 的形状——`tests/test_kv_offload_benchmark.py:11` 用 `[16, 24, 32, 64, 128, 256]` 断言默认档在每种 Mac 尺寸上都不告警,`:18` 用 `[16, 24, 32, 64, 128]` 断言 `memory-fraction 1.0` 在每种尺寸上都必须告警(同一策略的两个方向各有边界样本,而不是只测「正常情况下不响」)。同族常数还在 `vllm_metal/v1/cache_policy.py`:`:314` `KV_COMMIT_RESERVE_FLOOR_BYTES = 1 << 30`(比例缩放之后仍要有地板,小机器才不会被缩成 0)、`:364` `cap = probe.available_before - reserve_bytes - future_reserved_bytes`,配一段明确的账:已分配(权重、profiling buffer)已经在测量里,不能再减一次;稍后才会分配的(TurboQuant prefill workspace、KV offload host pool)必须减。**对照我们**: `Sources/ocoreai/Engine/MLXBridge.swift:869` 的 `let kvCacheRewindReserveTokens = 1024` 只有一个文件、一个常数、一次实测(§ Open 那条已如实写着「1024 rows, measured on one checkpoint, not tuned to model or memory pressure」)——三判据的第①条成立(真问题)、第②条有了上游形状(按设备推导 + 显式覆盖 + 随数字发布)。**候选(本轮未做,因为它动发布面)**: 先让 reserve 可见(键名与字节代价进 `/v1/models/:model/kv-cache`,随 `prefixReuse` 一起被探针 27 钉住),再加 `OCOREAI_KV_REWIND_RESERVE_TOKENS` 域校验覆盖(0=关,负值点名拒),最后才谈按 RAM 调档;`ReuseRefusalLedger` 已有 `rewindReserveChanged`(:81,:114)承接跨档异构,所以这三步都不需要新核心面。
- **hermes-agent 的两条轴:一条判「不缺口」,一条变成新工具的用法**: `trajectory_compressor.py` 的头/尾保护与「绝不切开 tool_call/tool_response 对」正是我们写在 `Sources/ocoreai/Reasoning/ConversationCompaction.swift:10-24`(atomicity 规则)与 `:173-186`(匹配 `toolCallID` 的连续 tool 消息归为一个原子组)里的同一条不变量——它印证了我们的判定,没有提出更好的。另一条 `toolset_distributions.py` 把「按分布随机启用工具子集」做成数据(`{"web": 100, "vision": 90, …}`,`+`-组一次摇全组):`10-24(10)` 之后 `results.tsv` 每份都带 `tools=<n>+<sha>`,这条机制于是可以直接变成**筛选档**——同一任务集、只换声明集,用 conditions 指纹证明差异只来自工具面。零产品改动,故排在前面。
- **goose / opencode 各提出一条真候选,且都撞在同一条阶梯上**: goose 把 **ACP(Agent Client Protocol)** 当第三块一等界面做(`Cargo.toml:23` `agent-client-protocol = 2.2.0`,配 `crates/goose-acp-macros`、`ui/goose-acp`)——编辑器即客户端,这是「GUI 友好」在 agent 侧最硬的答案;但它是 ladder 第 6 级(新核心面),按规矩要消费者今天就在,⇒ owner 决定,不是审计。它的下载(`goose-download-manager/src/lib.rs:20,648`)只是 retry-with-resume,我们 `Sources/ocoreai/Models/ModelScopeDownloader.swift:371-453` 已做到 Range + `If-Range` 身份核验(且诚实承认「SDK 那侧靠 etag 续、URLSession 的 temp 一断就没了」),**判:不缺口**。opencode 的 `packages/http-recorder`(README 第一句:record real HTTP/WS once, then replay from deterministic JSON cassettes)指的正是我们缺的那一层:`scripts/probes/` 34 支全部要求活着的 Metal 服务器,于是 steer 接缝、池化会话刷新这类**harness 缺陷在 sandbox 档无法钉住**;候选是给 harness 做回放档(绝不用于能力宣称),代价与收益都在评测基建侧,记账待批。
- **`pi` 维持「故意不入名单」,但让这个决定变得可见**: 它确实有货(`packages/durable` 84 个 .ts 的可恢复执行、`packages/codemode` 17 个、`packages/evals`、`packages/tui`),而 durable-run 与 code-mode 恰好对着 § Open 里两条 owner 项(无工具调用的回合不可中断、`tools[]` 强制面)。本轮不登记它,改为把「未登记」写进门:新的 P16 断言要求 § Upstream 6 点名的每棵树在长文里有条目、且顶部那条 diary 重测行必须与 §6 集合**完全相等**,于是 `pi` 再也不能冒充被审过的比较对象。
- **顺手修掉索引本身的两处失真(并长出两条门)**: `docs/agent/comparator-repos.md` 此前缺 `splash`、`goose`、`opencode` 三棵已登记树的条目(§6 点它们名,长文却没有它们的描述),而它自己给的 diary 重测循环 `for r in …` 漏掉了 `openclaw`——整套里被引最多的一棵——却带着未登记的 `pi`。三条条目已补(压缩成索引形状,细节住在这里),循环已改为与 §6 全等,`Strata` 的 Borrow 从「named, unused; same call pending」如实翻成 consumed(它的 benchmark-protocol 规则上一轮变成了 `scripts/eval/_conditions.py`)。**门**: `scripts/agents-md-contract.sh` P16 新增两条——§6 每棵命名树必须在 CMP_DOC 有 `- \`name\`` 条目;循环覆盖的树集必须等于 §6 注册集。**红样(当场跑过)**: 把 splash 改名 → `P16 § Upstream 6 names splash but docs/agent/comparator-repos.md carries no entry for it — an index that points at a description which was never written`;循环去掉 openclaw 并加回 pi → `P16 …refresh loop covers 16 tree(s) while § Upstream 6 registers 16 … (differing: openclaw, pi)`;还原后 ✅。
- **corpus 自付**: 本轮新增约 +1.5 KB 索引文字,靠搬出/压掉带日期的取证还掉——`docs/agent/build-gate-reality.md` 的 `AppLifecycleLiveTests` 锁屏会话整段移入本文件(见下条),`third-party-notices.md` 的 09e71257→675437b8 与 `vendored[0].sha256` 红样、`scripts/probes/README.md` 的 BPT-trap 崩溃取证与三处日期、`UI/AGENTS.md` 的像素几何日期、`systemone-decisions.md` 的落笔日期全部退回此处或去掉日期(数字与判据留在原处)。corpus 从 155334 → **155295**(上限 155386,反而 −39 B),root 未动。
- **验证**: `make docs-check` ✅(corpus 155295/155386、root 30419/30428、claims 31/31、comparators trees=16 coupled=8 zero-coupling=8/8=True、probe-index 34/34);`make anchor-check` ✅(anchors 72 = local 30 + upstream 42,drift=0;bare upstream cites scanned=213 ok=213 missing=0);`scripts/audit.swift_patterns.sh` ✅ All audits passed。本轮无 Swift 代码改动(git status 仅 `scripts/`、`docs/`、`CHANGELOG.md` 与两篇 guide)。

**10-24(9) 中文 README 够不到任何一条上游来源:八条链接、一段 `/health`、一处 `%2F` 告警只存在于一种语言里**(P1 人类面诚实 / 双语对账) — deepseek-harness 为每份文档都维护一份机器可查的配对文件(`~/references/deepseek-harness/README.i18n.yaml`,README/SAFETY/CONTRIBUTING 各有 `.i18n.yaml` + `.zh.md` 两套),goose 在 GUI 串上做同一件事(`ui/desktop/scripts/i18n-check.js`,上一轮已变成 `LocaleResolutionTests` 的四条门)。本轮把同一把尺搬到人类面上,先量:README.md 有 21 条链接、3 个代码块、11 个 `###`、54 个表格行、4 张图、3 个 `OCOREAI_*`;README.zh.md 只有 13 条链接与 2 个代码块。差的不是措辞,是**可核查性**:整条 References 没翻(Apple Developer Documentation、Human Interface Guidelines、vLLM、vLLM-Metal、SGLang、omlx、OpenClaw、Hermes Agent 八个来源在中文面一个都点不到),`curl -s http://127.0.0.1:8080/health` 那段最上手的最小验证也没有;反向还有一条——英文只用文字说 "percent-encode them",从没写出 `%2F` 的字面形式,而 § Open 的 `%2F` 正是本项目已知的锐边。

- **改了什么**: ① `README.zh.md` 补 References 行(与英文同一 URL 集,每条标注它在此项目里的角色:推理与 SPM pin / CoreAI 路线参照 / agent 语义 / 服务化系统参照 / 生产级参照 / agent 平台参照)、补 `/health` 代码块、补 `> 模型 id 里的 `/` 写成 `%2F`。` 一行;② `README.md` 把字面形式写出来(`org/name` → `org%2Fname`),不再是"要转义"三个字。改后五维全部对齐:链接 21=21、`###` 11=11、代码块 3=3、表格行 54=54、图片 4=4、`OCOREAI_*` 键集双向空差。
- **门**: 新建 `Tests/ocoreaiTests/ReadmePairParityTests.swift` 五条——两个 README 都必须存在且 >5 KB(否则下面的对账是空过)、骨架四维精确相等且**各设自取底**(`###` ≥10、表格行 ≥50、图片 ≥3、代码块 ≥3,扫描正则一烂就必须红)、URL 集**双向**相等并各设底(≥20;单向只防一半)、`OCOREAI_*` 键集双向相等(≥3;这是配置面不是散文)、`%2F` 两侧都必须在场(英文退化成"percent-encode"也红)。
- **红样(当场跑过)**: 该门第一次跑就有 1 条红:`✘ Test percentEncodingCaveatIsOnBothSides() failed … "README.md no longer names the %2F requirement"`——修的是英文侧;补上后五条全绿。链接维度的修复证据是改前直接量到的 `enOnly=8 / zhOnly=0`(同会话输出),不是推断。
- **顺带还清一笔**: 上一轮塞进 `docs/agent/comparator-repos.md` 的「splash 何时离开零耦合」那句退回 CHANGELOG——带日期的判决不该住在 guide 里(P13 的意思),corpus 因此 −48 B。另记一笔事实:README.md 与 README.zh.md **不在** `OCOREAI_CORPUS_MAX_BYTES` 的 16 文件之列(corpus = AGENTS.md + ARCHITECTURE + CONTRIBUTING + probes/README + 两篇 area guide + `docs/agent/*.md`),所以这次补齐没有挤占文档预算;仍欠的是 `comparator-repos.md` 缺 splash 条目(corpus 只剩 52 B)。
- **验证**: `swift test --filter ReadmePairParity` **5 tests / 1 suite 全绿**;`swift test --filter 'AnthropicCacheUsage|AnthropicSSEWireShape'` **22 tests / 3 suites 全绿**;`make docs-check` ✅(corpus 155334/155386、root 30419/30428、claims 31/31、comparators coupled=8、zero-coupling 8/8=True);`scripts/audit.swift_patterns.sh` All audits passed;改动文件 `xcrun swift-format lint` 零告警。全量 `make test-clt` **3066 tests / 546 suites 全绿**(427.21 s,0 ✘;上一条 Anthropic 修复落定后的同路线全量是 3061/545,本条 +5/+1 正好是这支新门。


**10-24(8) references 第二轮判决:ollama 已把 `/v1/systemone` 做成第三种形状并且自带基准;记分板的数字仍不自报条件**(P2 研究判决 / 候选不改与候选待批) — 按三判据(能否量出我们的真问题、能否给出更好的具体机制、能否可重复证明)过了一遍此前只登记未读的树。`~/references` 共 20 棵:16 棵登记为比较对象,外加 `mlx-swift-lm`/`coreai-models`/`codex` 三棵上游与故意不入名单的 `pi`。

- **ollama `decision/`(13 个 .go,`systemone.go` 378 行)= Jev/System 1 轴的第三种形状,也是唯一在本地模型上真跑通的**: `docs/agent/systemone-decisions.md` 此前只写了两种形状(vllm 扩散原生 `/v1/systemone`、sglang 自回归 `/v1/decisions`),并明说「not read: …」。现在补齐:ollama 把同一套 Jev 词汇做成**按编码分派**——`decision/systemone.go:62` 的白名单 `""|tev1|clef|strands|kev|pplx|d3`,不在表内直接 `unsupported decision encoding %q`;`ValidateLimits`(`:32-49`)在把请求交给引擎之前先拒 questions 1–64、score criteria 必须是 2–10 级的数组、`state` 为空(且无图)即拒、视频输入显式拒。路由端 `server/routes.go:923-928` 用一次接口断言决定放行与否:runner 不实现 `SystemOne(...)` 就 400 `model %q does not support System One scoring`——**能力按运行期证据判定、缺失时点名,与我们 `RuntimeCapability.measured(_:)` 同一形状**(它印证了我们的判定式,没有提出更好的)。
- **因此对 § Open 的那条 owner 决定多了一条可引证据**: Shape B(自回归、不需特殊 checkpoint)在 ollama 是**已交付**而非提案,`server/routes.go:2412` 挂路由、`cmd/decide.go` 还给了 CLI(`ollama decide` + `yesNoQuestions`,`:45-49`)。这改变了价的估计:难点不在端点与问题模式,而在我们缺的那块地基——发布 logits 的接缝(§ systemone-decisions「What this repo already has」)。ollama 能做成,是因为它的 llama.cpp runner 本来就暴露 scoring;我们的 `/v1/completions` 在 macOS 26 交付面上仍回 501 `AppError.logitsUnsupported`。**候选不改**:在没有 logits 接缝之前建 `/v1/decisions`,只能造出一个必须回 501 的门面,或者更糟——造一个报假概率的门面(该文档自己列的最坏失效模式)。
- **ollama `cmd/bench/decision.go` 提出了一件我们确实缺的东西**:它的每行结果带 `corpus_sha256`、`concurrency`、`epoch`、`cached_input_tokens`(`:98`),并且**凡是声明了缓存期望的用例就拒绝并发与预热**(`:69-71`:`c.Cache != nil && (concurrency != 1 || keepAlive > 0 || warmup != 0)` → 直接报错),随后 `c.CheckCache(response)` 逐例核账。我们的记分板 `scripts/eval/run.sh` 只写 `# score N/M model X`(`:224`):任务数有底(34)、工具数有底、验证器有自测,但**产出那个数字的条件没跟着数字走**——tasks 文件是哪一份(sha)、服务端当场声明的工具集是哪个版本(工具集来自 `GET /v1/tools`,它会变)、approval policy、并发。同样的 30/36 两次可能测的已经不是同一件事。**候选待批(未做)**: 把条件行做成一个被自测覆盖的构造器,让每个数字自报生产条件;它与 Strata 的 `docs/BENCHMARK_PROTOCOL.md`(引用数字之前先写清数字怎么来的)是同一件事的两半,也符合 invariant 1。本轮未落地,因为 `scripts/eval/README.md` 属 corpus 而 corpus 只剩 33 B,先欠不藏。
- **MTPLX 的验收遥测不构成缺口(判:已齐)**: 它在流式打印里给 `% accept`(`mtplx/ui/chat_printer.py:131,141`)并在 dashboard 上并列 TPS/acceptance/cache/memory(`ui/onboarding.py:1295`);我们同一件事已在面上——`Engine/EngineEvents.swift:87` 的 `proposedDraftTokens`/`acceptedDraftTokens` 经 `ChatViewModel.swift:1151-1154` 落到 `ChatView.swift:525` 的 mtp 计量。**待量的一小块**: 这两个数只在 GUI 那条 SSE 上可见,`/metrics` 没有投机计数列;头less 客户端看不到自己在跑投机解码。低优先,记账不谎报。
- **零耦合名单随之变化**: splash 的拆分与恒等式落进 `Sources/`(见 `10-24(7)`),`docs/agent/comparator-repos.md` 的零耦合名单从九棵改为八棵(MTPLX、TensorFold、Strata、goose、mlx-serve、opencode、deepseek-harness、harness2),P16 复推 coupled=8 / zero-coupling=8/8=True。**仍欠**: 该文档没有 splash 的条目(它靠 § Upstream 6 与顶部的 diary 重测行被 P16 认到),补条目约需 380 B,而 corpus 上限只剩 33 B——先记账,等一次压缩再还。


**10-24(7) Anthropic 门面把引擎测到的 KV 复用吞掉了:同一个数,OpenAI 线发、Anthropic 线不发**(P0 兼容面不对称 / KV 复用记账) — 这轮的 references 深读里第一条硬货出自 splash:它的 Anthropic 契约测试把恒等式钉成 `count == usage["input_tokens"] + usage["cache_read_input_tokens"]`(`dev/tests/server/test_anthropic_contract.py:889`),拆分本体在 `server/api_shapes.py:1221-1226`(`input_tokens = prompt_tokens - cache.matched_tokens`)。三条独立实现记同一笔账:vllm `vllm/entrypoints/anthropic/serving.py:80-110`(原文「Anthropic defines total_input == input_tokens + cache_read + cache_creation」,并在 cache 信息缺失时把整键省略)、ollama `anthropic/anthropic.go:226-238`(`UsageFromMetrics`,用 `min(cached, total)` 把分解量兜在整体之内)、openclaw 客户端 `packages/ai/src/providers/anthropic-usage.ts:62`(`totalTokens = input + output + cacheRead + cacheWrite`,即调用方真的拿这几个数算钱)。而我们的 `AnthropicUsage.cacheReadInputTokens` 注释是「reserved for future cache feature」、恒为 nil——尽管 `observedCachedPromptTokens` 早已在 handler 里从引擎 `.done` 拿到手(非流 `AnthropicMessagesHandler.swift:773`、流式 `:1190`),OpenAI 门面也早已把它作为 `prompt_tokens_details.cached_tokens` 发出去。

- **缺口的形状(当场跑出来的,不是推)**: 同一会话、同一份历史,`/v1/chat/completions` 报 `prompt_tokens=720, cached_tokens=0`,`/v1/messages` 报 `input_tokens=720` 且没有 `cache_read_input_tokens` 这个键。按 Anthropic 自己的加法,后者等于宣称这 720 个 token 一个都没复用。今天两边恰好都是 0 所以总额没错;等 § Open 里的前缀复用真正修好,它会在 OpenAI 面上出现、在 Anthropic 面上永远缺席——而 `cache_read_input_tokens` 正是 Claude Code 这类客户端显示命中与计费的字段。invariant 2 在这里的违例形式是「同一个数量在两扇门不是同一个数」,且被吞的那扇恰是编码客户端最依赖的那扇。
- **改了什么(一个家,三处出口)**: ① `Models/AnthropicModels.swift` 新增 `AnthropicCacheUsage.split(totalPromptTokens:cacheRead:)`,把 Anthropic 的加法恒等式与「分解量不得超过整体」的钳制(`min(max(0, cacheRead), whole)`)放在一起;未测=整键缺席,测到的 0 仍然发布(与 OpenAI 面 `cached_tokens` 同一套词汇:0 是一次测量,缺席才是无话可说)。`AnthropicUsage.split` 与 `AnthropicStreamUsage.split` 都只从这里取数,`input_tokens` 从此是未缓存那一段。② 非流出口 `AnthropicMessagesHandler.swift:771` 用 `observedInputTokens` + `observedCachedPromptTokens` 拆分。③ 流式终局 `message_stop`(`:1188`)带同一拆分;`message_start` 仍走同一个 split 但传 `cacheRead: nil`——那一刻尚未 prefill,没有可报的量(沿用既有决定:测量落在终局事件)。`message_delta` 保持只带 `output_tokens`(既有门 `AnthropicSSEWireShapeTests` 钉着,不因本次改动而松动);`cache_creation_input_tokens` 永不声明——本引擎没有缓存写入的测量,不能替客户记一笔看不见的账。
- **门**: 新建 `Tests/ocoreaiTests/AnthropicCacheUsageTests.swift` 十条——三组精确拆分(1000/750→250+750、400/0→400+0、64/64→0+64)、未测时键集合精确等于 `{input_tokens, output_tokens}`、测到的 0 必须让键出现、三组钳制(100/250→0+100、50/−7→50+0、−20/5→0+0)且恒等式在钳制后仍成立、`cache_creation_input_tokens` 在两态下都不出现、跨门面恒等式(同一 `(total, cached)` 下 `Usage.prompt_tokens == input + cache_read`,且 `total_tokens == input + output + cache_read`,也就是 openclaw 客户端算的那个总数)、流式终局与非流同拆分、源码扫描(手工 `AnthropicUsage(` 构造必须 0 处、`AnthropicUsage.split(` 恰好 2 处、`cacheRead: observedCachedPromptTokens` 恰好 2 处——两条腿都必须报测量而非预估)、占位注释必须消失且同一扫描仍能看见 `cache_read_input_tokens` ≥2(自证扫描没失配,不空过)。
- **红样(当场跑过)**: 把非流那处退回 `cacheRead: nil`(即修复前的行为)重建后跑探针 22 → `FAIL the OpenAI face reported cached_tokens=0 for this conversation while the Anthropic face published no cache_read_input_tokens`,汇总 `11 passed, 1 failed`;改回来再跑同一支 → `11 passed, 0 failed, 8 measured`,PASS 行原文 `one prompt is one number across both faces — one prompt costs 720 tokens on both faces (uncached=720, cache_read=0)`。
- **探针 22 新增一节(两门面在同一份提示词上相遇)**: 同一 `session_id`/`metadata.session_id` 把同一份三轮历史分别打到 `/v1/chat/completions` 与 `/v1/messages`,硬断 `input_tokens + cache_read_input_tokens == prompt_tokens`、`input_tokens ≥ 0`、`cache_read` 不得超过它所分解的整体,并硬断**在场性一致**——OpenAI 面报出 `cached_tokens` 而 Anthropic 面不发 `cache_read_input_tokens` 即红(两条腿读的是引擎同一个字段,不一致是我们自己的问题,不是引擎的);两面的 cached 具体数值作 measured 记录,不当门(复用与否仍受 § Open 那条前缀复用未决项支配)。
- **验证**: `swift test --filter 'AnthropicCacheUsage|AnthropicSSEWireShape'` **22 tests / 3 suites 全绿**;`bash scripts/probes/run.sh 22` **11 passed, 0 failed, 8 measured, 0 known-open**;`make docs-check` ✅(comparators coupled 7→8、zero-coupling 8/8=True,corpus 155353/155386、root 30419/30428、claims 31/31、probe-index 34/34);`make anchor-check` 复跑 **drift=0**(72 anchors,上一轮 README 703→721 的位移已闭合)。
- **顺带闭合**: 上一轮遗留的 `make anchor-check` 未回读项——`README.md:703`/`README.zh.md:703` 指向 `App.swift:703 globalRate: 200`,加行后位移到 721;本轮复跑确认 `anchors: checked=72 drift=0`、`bare upstream cites: scanned=210 ok=210 missing=0`。


**10-24(6) 仪表板健康条从两态改回引擎本来的六态：停摆、降级、熔断不再被叫作「System Loading」，每个静置态都给出路与原因**(P0 诚实面 / P1 状态权威 / P0 回归防护)

- 缺口实证（读码三层的产物，不是猜）: 引擎侧早就有完备真相——`Engine/EngineLifecycleState.swift:48` 六态（idle/starting/ready/degraded/stopping/error）+ `EngineCircuitBreaker`（连续 3 次失败熔断、冷却 60 s），`App.swift` 的 `failStartup(_:)` 拿到的是具体原因（SQLite 打不开、审计轨迹建不起来、工具注册表缺失…）。但 `UI/Views/DashboardView.swift` 的健康条写的是 `dashboardState.isLive ? StringKey.systemOnline : StringKey.systemLoading`，而 `isLive = connected = OcoreaiEngine.shared.engineReady = lifecycleState.isHealthy`。合起来：**未启动、降级、熔断打开这三种终局在 GUI 里一律是「System Loading」**，永远等不来，也一条出路都没有；失败原因只在 logger 里，用户看不到自己该改什么。这是不变量 2 的反向违例（引擎知道得比面上说得多，面上却把坏消息说成中性）。
- 修（一处判定，别处只渲染）: ① 引擎把原因与计数留住——`lastStartupFailure`（`failStartup` 记、启动成功清）、`startupFailureCount`、`retryStart()`（先 `resetCircuit()` 再 `start()`，界限仍归熔断器，重试不会打圈）；② 新增 `DashboardHealth`（`UI/ViewModels/DashboardViewModel.swift`）：纯函数 `derive(state:failures:cause:)` 做六→六映射，并携带 `labelKey`/`label`/`affordanceLabelKey`/`samplesMetrics`，文案键与出路都住在这里，视图不再自行判断；③ `DashboardView` 逐态渲染——点色（绿/蓝/琥珀/中性/红）、诚实标签、`No live data` 角标、失败原因行（原话引用引擎的诊断串，不意译）、出路按钮（degraded 去系统页、stopped 启动引擎、failed 重试），uptime 仅 online 出现；④ 图表不再给没测过的分钟盖章：`samplesMetrics` 为假时冻结历史，而不是把线拉平穿过一段从未采样的时间；同时把最后一次数值留在屏上（清零等于谎称测到了空转），由健康条上的 `No live data` 角标说明它们已不再更新——冷启动什么都没测过，所以角标在那一刻不会亮，可达性由 `staleRule` 钉住，避免造出一个永不出现的安慰剂。
- 新增键 7 个 ×en/zh（`Dashboard.SystemStopping/Degraded/Stopped/FailedFormat/StartBackend/LastFailureCause/StaleMetricsBadge`），两表说明符元数一致；出路复用既有 `retryAction`（Retry/重试）与 `tabSystem`（System/系统）。
- 门: 新建 `Tests/ocoreaiTests/DashboardHealthHonestyTests.swift` 六条——六态精确映射（含 `error` 且计数为 0 时不得声称「0 次」，取 `max(failures,1)`）、`samplesMetrics` 六值真值表、静置态必带出路且瞬态必不带（`.degraded→.tabSystem`、`.stopped→.startBackendAction`、`.failed→.retryAction`，`.online/.starting/.stopping` 为 nil，理由写在测试里而非靠默契）、每个态在 en 与 zh 两表都解析非空、源码扫描 `isLive ? StringKey.systemOnline` 必须消失且 `dashboardState.health` 引用 ≥5、六态 case 提及 ≥6（自取底，扫描失配即红）、`staleRule` 七值真值表（`.stopped/.failed/.stopping` 有值即 stale，冷启动无值不亮，`.online/.degraded` 永不 stale）。
- **验证**: `swift test --filter DashboardHealthHonestyTests` **6 tests / 1 suite 全绿**（与 `LocaleResolutionTests` 同跑时 19 tests / 4 suites）；`make docs-check` ✅（corpus 155341/155386、root 30419/30428、claims 31/31 全复现）。全量 `make test-clt` **3052 tests / 544 suites 全绿**（425.81 s，0 ✘）；`swift build -c release`（同一 CLT 路线）exit 0（252.84 s）。
- 仍缺（量出来，不声称）: 五种非 happy 态里 **reconnecting** 依旧不存在（`reconnect` 在字表 0 命中）。它的语义要先定：本 App 的 GUI 走 Fast Path 直连引擎，没有「与服务器断连」这回事，能断的只有 opt-in 的 bridge 监听与远端 hub。硬造一个「重连中」按钮会是假状态，故列为 owner 决定，而不是随手补一个。

**10-24(5) references 深读第一轮：把三棵从未进过审计清单的树读完，按「能否抓到 ocoreai 的真问题」这把尺子当场抓到三条，并把它自己的 i18n 机制补成会红的门**(P0 诚实面 / P1 借机制 / P0 回归防护)

- 判据（owner 定的那把尺）: references 有没有用只看三条——能不能找到现有实现的真实问题、能不能提出比现有实现更好的具体机制、能不能用可重复实验证明改善且代价不更大。本轮只交这三条能覆盖的东西，其余一律记成判决不作改动。
- 覆盖缺口先补上: `~/references/` 有 20 棵树，`AGENTS.md` § Upstream 6 只声明 14 棵比较对象（另有 mlx-swift-lm / coreai-models / codex 三棵上游），**goose、opencode、pi 三棵此前谁都没提**。本轮读完，`goose`、`opencode` 升入 §6（字节自付：root −2 B，同文件删掉 own/walkable/video 三处赘词），`pi` 故意不升——P16 用 `git grep -F` 推耦合，裸 token「pi」在本仓命中 436 个文件（`api`、`pipeline`），把它写进名单等于谎报「已消费」；这条理由连同零耦合名单一起改口为 nine trees（MTPLX、TensorFold、Strata、goose、mlx-serve、opencode、deepseek-harness、harness2、splash）。
- 真问题①（GUI 文案绕过自己的字表）: `Sources/ocoreai/Localization/Localization.swift` 本身是健康的——`StringKey` 448 键、base 与 zh 两表**逐键齐备**（既有 `LocaleTableCompletenessTests` 已钉住覆盖/无空值/zh≠en），缺的从来不是覆盖率而是「漏点」：实测**7 条用户可见字面量**不经字表——`UI/ApprovalNotifier.swift:103`「ocoreai 需要你的批准 · approval needed」与 :104 正文（一条中英硬拼在一起的通知），`UI/ViewModels/ModelManager.swift:92,97,102,108,113` 五张快速加载模型卡的描述。后果具体：设置里有语言选择器（`localePicker`），而这两组字符串在任何语言下都长一个样。修: 新增 7 个键 × en/zh 双表（通知正文用 `%1$@/%2$@` 位置说明符，译文可换序），`RecommendedQuickModel.description: String` → `descriptionKey: StringKey`（数据带键、渲染处解），唯一消费者 `UI/Views/ModelView.swift:571` 同步改 `.l`；全仓 `recommendedModels`/`rec.description` 消费者只剩两处，均已改。
- 真问题②（固定字号绕过自家 Dynamic Type 接缝）: `Theme.swift:190,200` 早就备好 `ocoreaiText`/`ocoreaiMono`（按 TextStep 映射，跟随 Dynamic Type），但 UI 里仍有 **7 处** `.font(.system(size:`——`ThirdPartyNoticesView.swift:75,139,145,151,172,184`（6 处 monospaced）+ `ChatView.swift:680`。讽刺处在于 `ThirdPartyNoticesView` 正是本文件推荐给后人的「诚实空态范式」。修: 6 处改 `.ocoreaiMono(11/10)`（保持等宽，不牺牲观感）、1 处改 `.ocoreaiText(11)`；剩余绕过站点实测 0。
- 门（字体纪律）: 新增 `the GUI scales its text instead of pinning pixel sizes`——UI 子树里 `.font(.system(size:` 期望 `== []`，同时自取底：`.ocoreaiText`/`.ocoreaiMono`/`.ocoreaiDisplay` 命中须 ≥150（实测 203），扫描器停止匹配即红。
- 真问题③（自家指南把没做的事写成清单）: `UI/AGENTS.md` 承诺 empty / loading / reconnecting / degraded-stale / exhausted-recovery 五种非 happy 态各有诚实文案与出路，实测**只有 3 种有名字有文案**（empty `chatWelcomeTitle`/`sessionListEmpty`、loading `systemLoading`/`modelStartingLabel`、exhausted→recovery `retryAction`/`dismissError`），reconnecting 与 degraded-stale 在字表里 `reconnect|stale|degraded` 命中 0（只有一条 HF 镜像提示含 unreachable），UI 里也没有任何重连状态检测。按不变量 1「没有门的修复只是说法」反推，没有测量的承诺同样只是说法：把这条改写成「规则 + 实测缺口 + 不声称」，而不是继续挂着五项全绿的假象。
- 顺带记账（goose）: `crates/goose-local-inference/src/{mlx.rs,llamacpp/}` 是继 ollama 之后第二个「一个 agent 底下同时挂 MLX 与 llama.cpp 两族引擎」的公开先例，和我们的 MLX + CoreAI 双路同形；`crates/goose-context-management/{summarize,templates}.rs` 则把压缩单独成 crate（我们的对应物是 `ConversationCompaction`）。
- 借来的机制（goose）: `ui/desktop/scripts/i18n-check.js` 把「抽取组件里的 message、与提交的 `en.json` 比对、有漂移就失败」做成脚本门。本仓等价物落成三条新门（写进既有 `LocaleTableCompletenessTests`，不另起 suite）：① GUI 零硬编码文案——逐字符扫描 `Sources/ocoreai/UI/**`，尊重字符串内 `//`（`https://` 不误伤）与块注释，命中期望 `== []`，并**自取底**：同一扫描须在 `Localization.swift` 命中 ≥400 行，正则一旦停止匹配就红；② en/zh 两表 `%@` 说明符**元数一致**——元数不等会静默丢内容（多给的参数被吞），故从解析后的字符串而非源码行统计（跨行拼接的字面量因此不会误判，这条正是「逐行扫描重新匹配后又悄悄失配」那一类腐烂的反例），期望 `[]`，实测 0 例、floor 20（30 个键带说明符）；③ 消费者侧——5 张快速加载卡在 en 与 zh 两侧都须解析出量化位与容量单位且两语言不得同文。
- 借但拒绝（opencode）: `packages/protocol/openapi.json` + `packages/httpapi-codegen` 把 wire 契约做成提交的机器可读产物并生成客户端，比我们把可选性一条条写 decode 测试更结构（机制确实更好）。拒绝的理由也说清：本仓已有 router、`AuthRoutePolicy`、两份 README 表、`V1EndpointCatalog` 四处对账（docs-check 逐条比相等），再引入一份生成 schema 是同一真值的第五处；判决记录于此，等哪天路由对账开始漏再改口。
- 借但暂不改（pi）: `packages/coding-agent/docs/session-format.md` 记的是 JSONL **树**——每行带 `id`/`parentId`，头部带版本号，v1→v3 加载时自迁移，于是 fork/branch 原地可做；我们是 SQLite 会话 + `SessionRewindOnDivergence` 前缀回绕，branch 语义不在面上。列为下一步的候选，本轮不动。
- 顺带量到但不动的（诚实边界）: 工具/引擎抛给上层的 payload 里还有 5 处中文（`Tools/WebFetchTool.swift:57,62,124,247`、`Engine/EngineInference.swift:2967` 参数序列化失败），它们经 `ToolRegistry.call` 直达模型与 wire，属 agent-facing 文本；按 § Documentation Map，改它要配一次活模型回归，故本轮只报数字不改字。
- **验证**: `swift build --target ocoreai`（CLT 路线，SDKROOT 钉死）exit 0，48.42 s；`LocaleTableCompletenessTests` 该 suite 8 tests 全绿（原有 4 条 + 本轮 4 条新门）；`make docs-check` ✅（corpus 155358/155386、root −2 B、P16 十六棵比较对象 / nine zero-coupling、claims 全复现）。全量 `make test-clt` **3046 tests / 543 suites 全绿**（426.66 s，0 ✘，较上轮 +4 条即本轮新门与消费点锁）；`swift build -c release`（同一 CLT 路线）exit 0，363.79 s；`make anchor-check` 210/210 上游引用逐行可解；`scripts/audit.swift_patterns.sh` 全类 Clean。
- 环境坑（复现用，别再踩）: 手敲 `swift build`/`swift test` 若漏 `SDKROOT=$(DEVELOPER_DIR=<CLT> bash scripts/toolchain-contract.sh print-sdk-root)`，会落到 MacOSX27.0.sdk 让 `canImport(CoreAI)` 块全部编进来（实测 53 个错），看上去像本地化改动闯的祸，其实是路由选错。


**10-24(4) 把工具终局送上 wire：`ocoreai.tool_results` 在两面 × 流/非流共四处装配点落地，探针 21 的时机判决从此不再依赖模型复述**(P0 假承诺改真接缝 / P0 回归防护)

- **撤销三处假承诺**：`Handlers/ChatHandler.swift`（非流与流两处）与 `Handlers/AnthropicMessagesHandler.swift` 的注释都写着"wire 已有 `function_call_output` 等价物，不需要额外字段"，而 native 回合的响应里从来没有 tool 结果（10-24 实测：`sleep` 跑满 9402 ms 的响应不带任何 tool 记录；同会话追问答"I do not have access to any previous tool output"）。现在这三处改成绑定并发布：`case .toolResult(let meta)`。
- **机制**：`Models/OpenAIModels.swift` 新增 `OcoreaiTurn` / `OcoreaiToolRecord`，`ChatCompletion` 与 `ChatCompletionChunk` 各挂一个 optional `ocoreai`；`AnthropicMessageResponse` 与 `AnthropicStreamEvent.messageDelta` 同样挂 `ocoreai`。字段一律来自 `ToolResultMeta`，`duration_ms` 是 `ToolRegistry.call` 两侧实测的墙钟，`ok` 由 `failure == nil` 判；**出口一次 `SecretRedactor.redact`**（tool 结果是密钥外泄面，只脱模型那份不够）。键名走 namespaced：`ocoreai` 拥有它，绝不把非规范字段伪装成规范。
- **新门 `ToolResultWireDeliveryTests`(7)**：成功终局 `ok:true` + 精确 `duration_ms`；失败终局绝不伪装成成功；摘要在出口被脱敏（`sk-` 24 位进去、`[REDACTED_SECRET]` 出来）；OpenAI 非流 snake_case（有 `duration_ms`、无 `durationMs`）；**缺席 = 没有派发**（两面 × 流/非流的空响应都必须无 `ocoreai` 键）；两面的流式终局事件各自带得上。最后一条是自取底源码扫描：装配点必须 == 4、事件绑定必须 == 4（**第一版写 3，被门当场抓到**，改成实测 4）——少一处就是某一面悄悄丢了投递接缝却仍被引用为已带。
- **探针 21 换判据（实测）**：新增 `ocoreai.tool_results[0].duration_ms` 三条腿硬断言——control `9360.88 >= 9000-500`、steered `1063.61 < 8000`（早醒由服务端测量证明）、isolated `7303.39 >= 7000-500`（别的会话叫不醒它）。原来靠模型复述"终局词"的那条降级为 **`XFAIL open`**：gemma-4-e2b-it-4bit 只回首行属**复现保真**而非投递缺失（直接问它，它能引 `Sleep completed.`），且派发本身已由 wire 记录自证。再加第 4 条腿：Anthropic 面 `/v1/messages` 非流必须带同一份实测记录（活体 `duration_ms=6205.18 >= 6000-500`）——那一半此前只有单元层证据，按「活体证明要落到脚本里」的规则补成常驻断言。整支升到 **19 passed / 0 failed / 9 measured / 1 known-open**，且 xfail 的 XPASS 记失败，这条降级不能烂在里面。
- **字节自付**：`scripts/probes/README.md` 加一条新失败形态后 P15 报超 252 B，按棘轮就地删掉不变原文的复述与冗余括注，`make docs-check` 回到 ✅（corpus 155386 上限内、无 >400 B 长行）。**没有动任何常量，也没有为绿改断言。**
- **余下**：①`ocoreai.tool_results` 目前只在响应里，未在对外文档面声明——是否公开成契约由 owner 定（P10 只管端点表，不管字段级）；②按 mlx-serve 形状给 `Sources/ocoreai/UI/AGENTS.md` 每条散文规则配自取底源码扫描门（GUI 门密度 45/3 是本轮量出来的最薄处）。

**10-24(3) references 全量清点：把"我们比它们强在哪"从口号换成可重推的四列数字，顺手抓到自家文档一条假话、两条被上游已经定案的 § Open 悬案、以及三处把"wire 已有 tool 结果"写进注释的假承诺**(P0 真值对账 / P1 反自我恭维)

- **清点口径（20 棵树，命令可重跑）**：行为用例数、CI workflow 文件数、GUI 文件数、GUI 测试文件数。`for d in ~/references/*/; do …; done`（`rg -c -e '^\s*(def test_|func test|#\[test\]|it\(|test\()'` 求和；GUI 用 `rg -l -e 'import (SwiftUI|AppKit|UIKit)'`，注意**不能加 `^`**——本轮第一次扫就用顶格锚点把 ocoreai 自己扫成 0，是 invariant 1 说的"扫描停了却当通过"）。实测：openclaw 96873 用例/119 CI、sglang 26671/122、deepseek-harness 27355/27、hermes-agent 62103/57、vllm 19102/13、omlx 12458/5、codex 11307/28、MTPLX 8802/6、mlx-serve 4564/6、Strata 5252/8、goose 3848/39、vllm-metal 2807/6、splash 1321/1、mlx-swift-lm 1155/4、ollama 225/7、coreai-models 586/1、TensorFold 127/4、pi 102/14、harness2 5/0；**ocoreai 3151 `@Test` / 542 suites / 1 workflow·8 job**。绝对数我们低于全部重量级对手，密度（3151/299 源文件 = 10.5 用例每源文件）高于全部对手（openclaw 2.0、vllm 3.2、sglang 3.1、codex 1.7、mlx-swift-lm 1.9）；CI 广度近乎垫底。
- **元门一个对手都没有**：`claim:` 复现、shrink-only 字节棘轮、`anchor:` 保鲜、探针索引=文件系统这四类，在 17 个 references 里 **0 命中**。第一轮那 434/223/940 命中抽查后全部作废——`jwt_role_claim`（sglang）、`TraceAnchor`（codex）、OAuth `claim`（openclaw）是巧合词。**这条不是荣誉，是成本**：唯一付这套钱的是我们。
- **抓到自家一条假话**：`docs/agent/comparator-repos.md` 写 openclaw 是"the only rival here that is also a native Apple app"，Swift 数还停在 1,591。实测带 `@main … App` 壳的有 **4 棵**：openclaw（`apps/ios/WatchApp`，7 个 `Info.plist`，1,596 Swift）、mlx-serve（`app/Sources/MLXServe/MLXServeApp.swift`，680 Swift）、MTPLX（`apps/MTPLXApp/Sources/MTPLXAppHost/App/MTPLXApp.swift`）、omlx（`apps/omlx-mac/Sources/App/oMLXApp.swift`）。GUI 文件/GUI 测试文件：openclaw 436/122、mlx-serve 154/31、MTPLX 145/10、omlx 70/4、**我们 45/3**（`Sources/ocoreai/UI` 46 个文件里 35 个 import GUI 框架，13,165 行 UI 代码总共只挂 31 个 `@Test`，其中 3 个测试文件 import 了 GUI 框架） ⇒ App 那一面既不是无人区、又是我们最薄的地方。文档已改成"不止一个原生 app，且四个都比我们更会给 GUI 上门"，并删掉一句与 `AGENTS.md` 重复的 pin-vs-comparator 说明自付字节（corpus **155351/155386**）。
- **可借机制①（GUI 门，来自 mlx-serve）**：`app/Tests/MLXCoreTests/MediaModelChooserTests.swift:87` 用源码扫描断言每个 create pane 都走共享 chooser（`source.contains("MediaModelChooser.pane(")` 为真、`LanPick.selection(` 必须缺席）——这正是我们"one home per decision"的**会红版本**；同目录另有 `ChatEmptyStateTests.swift`、`RadioLockBannerTests.swift` 覆盖空态与锁态横幅，而我们的五条非 happy 态至今只写在 `Sources/ocoreai/UI/AGENTS.md` 的散文里、0 个门。
- **可借机制②（§ Open 两条 owner 悬案，上游其实已定案）**：缓存身份在对手那里是**显式 caller 轴**而非硬编码会话键——vllm `entrypoints/openai/responses/protocol.py:320` 声明 `prompt_cache_key`、`:1002` 落线；sglang `srt/managers/schedule_batch.py:1109` 收 `cache_salt`，`:1193` 把 `session_id`+`cache_salt`+`extra_key`（`lora_id` 拼进 `extra_key`）组成多轴身份，wire 面在 `python/sglang/api/v1/api_types.py:261-268`。我们的 `poolKey` 只有 `(modelId, conversationId)`，既不能请求共享也不能请求隔离；`ReuseRefusalLedger` 已经在数机会（`crossConversationTurns`，探针 01 已在读），所以这条不再缺数、缺的是把身份轴放上 wire 的决定。
- **探针 21 那条红归因完成（实测，非推断）**：投递无罪——`Wall time: 1.1353 seconds\nSleep completed.` 能逐字回显，另一腿模型还能把 `Sleep completed.` 当最后一行报出来 ⇒ 第二行确实进了上下文；红在 **checkpoint 的复现保真**：9000 ms 三连 + 一次 1800 ms 只回首行，`finish=stop`。真正的洞是**三处假承诺**：`Handlers/ChatHandler.swift:1033`、`Handlers/ChatHandler.swift:1702`、`Handlers/AnthropicMessagesHandler.swift:552` 都注释"wire 已有 `function_call_output` 等价物，不需要额外 SSE 字段"，而 native 回合的 SSE 里没有任何 tool 结果（探针自己的头部就写着结构化终局"stops there"）；同会话追问实测 `Please provide the output from the sleep tool… I do not have access to any previous tool output` ⇒ 客户端拿不到字节就无法回送，服务端循环对 wire 客户端是不可恢复黑箱。
- **顺手排除一条嫌疑**：`usage.completion_tokens` 无罪。工具回合正文经 `/v1/count-tokens` 实测 25、报 15；无工具长答实测 78、报 68；偏移恒为 **10**（一轮 user 的模板控制符）⇒ 自洽。探针不得再拿它当证据。
- **门这一轮全部站在对的一边**：一次文档编辑被 **P6**（外来 suite 名不算我方门）、**P15**（corpus 超 1208 B）、**P16**（压缩把 zero-coupling 句式 `seven trees have zero coupling — … —` 破坏）同时拦下，三条都是真红；按规则把结论改放 `CHANGELOG.md`（dated log，不在 corpus 扫描面）、索引只留纠错并自付字节，`make docs-check` 回到 ✅。**余下两步**：①把 `ToolResultMeta` 送上两条 wire 面（OpenAI 面 additive `ocoreai.tool_results`，Anthropic 面按规范补 `tool_result`），探针 21 判据改读实测终局并**保留**原回显断言作第二条独立信号；②按 mlx-serve 的形状给 `UI/AGENTS.md` 每条散文规则配一个自取底的源码扫描门。

**10-24(2) mlx-swift-lm 按协议 bump：`bb0d5b048` → `991266ad3`，逐 commit 审完 + CLT 全量套件绿；顺手把两处"门从环境里推断前提"的腐烂修掉，并把 17 条被 bump 冲歪的引用改真、25 条升级成会红的锚点**(P1 上游对齐 / P0 回归防护 / P1 自我纠错)

- **协议走通**：`Package.swift:43` `revision:` 改 `991266ad3`（9 字符，字节中性）→ `swift package resolve` RC=0，`.build-clt/checkouts/mlx-swift-lm` 与 `~/references/mlx-swift-lm` 均落在 `991266a` 且工作树干净 → `make test-clt` **3035 tests / 542 suites 全绿，426.8 s** → 判定写在这里。许可按规则重采：`scripts/collect-third-party-licenses.sh` RC=0，`THIRD-PARTY-LICENSES/NOTICES.md` 变成 `| mlx-swift-lm | rev 991266ad300f | MIT | … |`。
- **上游 7 个 commit 逐个判（HEAD 以 api.github.com 为准）**：`d02948b99` #718 JSON 属性按声明序（改 `MLXFoundationModels/GuidedGeneration/SchemaConverter.swift`——我方语法组装在自有 `Models/OpenAIModels.swift`，不消费该转换器 ⇒ 零影响）；`649f431b1` #721 只动测试；`5ae2635ba` #702 改日志器；`260ada029` #719 新增模块 `MLXScriptedLM`（动上游 `Package.swift`，我方不引用）；`0ea446535` #706 Qwen3VL cache rotation；`991266ad3` #710 每个 prefill chunk 后 `mx.clear_cache()`；**`db2e7bf48` #714 `observe(to:using:)` + `protocol GenerationTransformer`**。
- **#714 把一条 § Open 的前提反转了**：它是纯增量（`public func observe<T: GenerationTransformer>(…) -> AsyncThrowingStream<T.Handler.Output, Error>`），我方 `session.streamDetails(to:)`（`Sources/ocoreai/Engine/LoadedModel.swift:496`）与 `TextToolTokenLoopHandler.init` 签名均未变 ⇒ 编译零破坏；而上一轮刚写下"注入接缝上游标准 `ChatSession` 循环不提供，除非自建会话层"。`AGENTS.md` § Open 那条据此改成"接缝已在 pin `991266ad3` 存在，余下半边是接线（并把 `ChatSession` 循环的所有权接过来）"，root **30421/30428**（净减 3 B，自付）。
- **第一次全量跑是 4 红——全部是我方真值没对账，不是上游破坏**：① `DependencyPinStatementTests` 报实测 MLX 直接面 **11 sites / 5 APIs**，而 `Package.swift` 写 10 sites/8 call+construct ⇒ 新增那一处是本轮退化探针 `Engine/DegenerateMarginProbe.swift:256` 的 `asArray(Int32.self)`，manifest 的 consumer-impact 审计连 `asArray 4×` 一起改成实测值，并把该点补成锚点；② `EnvKeysDocumentationTests` 咬出三个未进契约的键 `OCOREAI_MARGIN_PROBE`/`_NO_KV`/`_DUMP`；③④ `ToolSpecFullRegistryTests` 要 41 得 42 ⇒ 新工具 `edit_lines`。**没有一条是改断言迁就现状**：42 由 `bootstrapBuiltInTools` 的 42 处 `registry.register` 逐点数出，其中唯一一段 `#if os(macOS)`（:661-700）包 10 处 ⇒ 无条件 27、基础 32、macOS 42；iOS 从"背下来的 31"换成**可证的 32**（口径同时统一：基础 = 无条件 27 + skills 3 + plan 2）。
- **开一门补 README 的账**：`EnvKeysDocumentationTests` 新增断言 6 `readmeStatesThePinnedSurfaceCount`——README.md / README.zh.md 声明的键数与拆分必须等于契约键数与 `Sources/` 实测字面量数。实测两侧早已对称过期：README 说 **23（17 静态 + 6 间接）**，契约 27，而真值是 **30 = 22 字面量 + 8 间接**（新增 3 个诊断键、且 10-12 那 4 键进来后拆分也错了 2）。扫不到该模式即 `Issue.record`，不许空转。`.env.example` 同步补三键，行号取真读点（`DegenerateMarginProbe.swift:93/100`、`:193`、`:265`）。
- **bump 冲歪的 17 条自由引用逐条改真**（行号全部在 `git show 991266ad3` 上核过）：`fork(history:)` 1652→**1723**、`templateMessages = leadingMessages +` 1110/1131→**1166**、`requirePlan` 抛错 307→**302**、rewind 的 verify-and-downgrade 1217→**1270**、媒体不 reconcile 345-356→**330-347**、retained-transcript 重建 1052-1067→**1108-1122**、`toolDispatch` 318→**377**、`totalPromptTokenCount` 2984-2987→**3002-3004**、`promptTokenCount` 文档 2921-2926→**2938-2943**、tool 循环可重启 1003→**1153**、vision-encoder 那段 707-715→**701-707**、raw-cache fragment 1710-1716→**1786-1790**、`generateParameters` 370→**361** 与 capture list 981-987→**1037-1043**、`.safetensors` 文档 1888→**2102**。另**撤销一条错指**：`Config/ConfigStruct.swift:633` 曾把 `kvBits`/`quantizedKVStart`/`kvScheme` 的家指到 `Evaluate.swift:54-78`，那里其实是 `LogitProcessor.copy()`；真家是 `:166`/`:172`/`:197`。
- **把这批引用升级成会红的东西**：25 条 `anchor:` 标记落进 `Sources/`（含上面每一处），`make anchor-check` 覆盖 **47 → 72，drift=0**。它当场自证有效——插入标记行把我方 17 条本地锚点顶偏（+1/+3/+5/+11），门逐条报"really line N"，全部改真后归零。
- **修两处门腐烂（同一条不变量：门不许从环境推断自己的前提）**：`scripts/upstream-cite-check.sh` 原先 (a) 只验行号 ≤ EOF、不验内容，(b) 用 `dict(roots)` 收敛同名 repo ⇒ 只留最后一个，而 bump 后 `.build/` 仍停在 `bb0d5b0`（其 `ChatSession.swift` 1758 行 vs pin 的 1829 行），于是 1786-1790 被判 past EOF，而反过来"错到 pin 之外"的引用也可能因旧树够长而蒙过。改法：pin 已知的 repo 一律 `git show <pin>:<path>` 数行数，并按名逐个 clone 试到有该 commit 为止；整套 clone 都没有该 commit 就大声 **UNVERIFIED**（既不冒充红也不冒充绿）。复测 **scanned=210 ok=210 missing=0 line-past-eof=0 skipped=0**，`at-pin: hummingbird, mlx-swift-lm, swift-huggingface, swift-transformers`。
- **门账**：`make test-clt` 3035/3035 ✓、`swift build` RC=0 ✓、`make docs-check` ✓（root 30421/30428、corpus 155345/155386，未动任何预算常量）、`make anchor-check` drift=0 ✓、`make audit` ✓、`make format-check` advisory（本机 formatter 非 CI 钉的 603.0.0）。
- **新 pin 上的活体重测（每支自起 serve，同会话跑完）**：**01-prefix-accounting 18 passed / 0 failed / 7 measured**（前缀复用真发生：`cached_tokens=728`，`reuse: 16 tok paid in 84 ms, 728 tok reused`，`prefixReuse.status=reuse_observed`、`reuseRefusals total=0`）⇒ #710 每 chunk `clear_cache` 没有把复用清没；**27-edited-history-honesty 20/0/5**（`fork` 所在那条 rewind 路完好）；**30 8/0/10**、**32 7/0/12**（prompt 字节确定性仍在）；**11 20/0/6**、**15 9/0/10**、**16 7/0/10**；**12 8 passed / 0 failed / 8 measured / 2 known-open**：上一轮修好的 §6（`response_format` + `tools[]`）在新 pin 仍是两形状 3/3，§5 开放式仍 3/6 收不了口、§7 落地块仍 0/3（三轮都是 `finish=stop` 的凭空气整数，工具一次没跑）。**`/v1/tools` 活体数到 40 个**，与注册面分解对上：无条件 27 + skills 3 + 桌面 10 = 40（plan 两把按设置关），全开 42 ⇒ 上面那套数字不只是源码点数。
- **唯一一支红：`21-sleep-steer-wake` 15 passed / 1 failed（3/3 复跑同形，不是抖动）**。steer 三条腿全绿（1.5 s 注入 ⇒ 同一轮 2458 ms 结束一场 8000 ms 等待，正文带 `[mid-turn user steering]` 与 `Sleep interrupted by new input.`）；红的是 control 措辞：请求 9000 ms、睡了 10.85 s，正文只有 `Wall time: 9.2704 seconds`，**尾行 `Sleep completed.` 没了**。逐条排除：① 不是诊断仪器——`OCOREAI_MARGIN_PROBE=all` 同样只回一行；② 不是投递丢字——`ClockSleep.report`（`Tools/ClockTools.swift:135`）两行形态恒在、`outcome` 无默认值，且 `finish=stop`（不是 length）；③ **同一条请求打到 10-22 的旧产物（旧 pin + 本轮改动之前）两行俱全**，尾巴上还挂着当时会随工具结果一起投递的 `[System Perception]`；④ 同一份新代码里 1200 ms 睡两行完整（`Wall time: 1.2577 seconds` + `Sleep completed.`），4000 ms 与 9000 ms 各丢一次 ⇒ 变的是**这个 2B 4-bit checkpoint 在 temp 0 上的终止决定**（顺带：新旧 prompt 长度差 11 token，因为本轮把感知尾块从投递面上去掉了）。**没把断言改成迁就现状**（它今天的作用恰恰是让这个退化当天可见），也没 xfail 它——复读工具原文是 agent 的本分，丢半句不是"还没做到"而是"变差了"。**归因未完成的部分写清楚**：本轮改动（去感知尾、工具面变化）与 pin bump（#710 数值路径）尚未分离，判据是"用当前源码在 `bb0d5b048` 冷编一份到独立 scratch，重跑 1200/4000/9000 三条腿"，代价是一次全新依赖编译，留人拍板；`.build` 停在旧 pin 这件事 `_lib.sh` 已经会大声报（今天 NOTE 在案）。
- **余下（都带工具名，不是愿望）**：`coreai-models` 镜像 HEAD `09ff139050d7` ≠ 记录的 apple pin `09e7125768fc`，采集脚本刻意不自动 re-pin（须显式 `OCOREAI_REPIN_APPLE=<sha>`）⇒ owner 决定；`scripts/probes/*.sh` 里的上游行号目前无任何门读（anchor-check 与 upstream-cite-check 都只扫 `Sources/**`），本轮已把 3 支探针的过期行号改真，但"扫不扫得到"仍是覆盖缺口，留人拍板；探针 21 那条红按上面的判据分离，未结。


**10-24(1) `response_format` + `tools[]` 同一回合：四种排法全部实测，JSON 优先是唯一保住可判定承诺的那一个；同时新开 §7 把「要先读文件才能答的 JSON」钉成开放题，并撤销一条写进文档的因果推断**(P0 兼容性 / P1 工具调用 / P0 回归防护 / P1 自我纠错)

- **上一轮修好的东西，本轮被证伪了一半**：10-24 早先那一步把"谁赢"改成"调用方要的 JSON 赢"，§6 当场从 0/3 变 3/3（`scripts/probes/12-json-mode-delivery.sh` 本会话两次实跑均 **8 passed, 0 failed, 5 measured, 1 known-open**）。但官方计分板揭出另一半：`scripts/eval/tasks.json` 的 `json-two-integers-closes` 交回**合法且合 schema 的 JSON** `{"cols":5,"rows":10}`，verify rc 1——文件写的是 `shape 3 by 5`。usage 是 `finish=stop prompt=986 completion=16 echoed_tool_calls=0`：**工具根本没跑，整数是编的**（HTTP 200）。把"答案丢了"换成"答案造假"，按不变量二更糟。
- **于是把四种排法都在同一台机器上跑完**：① 信封优先＝调用方 JSON 0/3，回回合 `finish: tool_calls`（其中一次还是 schema 合法、语义荒谬的 `edit_file{oldString:"read_file",…}`）；② JSON 优先＝形状稳（§6 两形状各 3/3），但读文件类落不了地；③ 两条通道并集 `anyOf:[json, envelope]`＝**语法编得出来，却当场判定文档已完成**：`grammarTerm=true tokens=1`，content 只剩 `'{'` 或 `'}'`（§7 三轮全中）；④ 干脆不加语法＝模型把 JSON 包进 ```json 围栏，下游**一行都解析不了**（§6 3/3）。结论写进唯一之家 `Sources/ocoreai/Models/OpenAIModels.swift`：`tool_choice` 明确要求调用时信封独占（sglang `python/sglang/srt/entrypoints/openai/serving_chat.py:1488-1501`，它并把 schema 称作 response data `:1349-1353`），否则 JSON 赢；序列化同时收口成一处 `grammarSchemaString`。
- **新门（不是话，是会红的东西）**：`Tests/ocoreaiTests/GrammarSchemaRegressionTests.swift` 由 6 → **11**，新增 `jsonObjectBeatsToolEnvelope`、`jsonSchemaBeatsToolEnvelope`、`demandKeepsEnvelopeAlone`（同时要求 `shouldConstrainOutput` 与 `buildGrammarSchema` 两个家在同一请求上口径一致——前者 true 而后者的语法为 nil，会把开放对象塞给引擎）、`jsonAloneStaysConstrained`、`openObjectFormsAgree`（`jsonObjectSchema` 的字符串写法与语法对象写法必须仍是同一个决定；严格并发不容 `[String: Any]` 全局量，所以没有第二处字面量可漂）。CLT 路线实跑：**11/11 通过**，连带 `ToolDeclarationSurfaceTests` 15 条共 **26/26 通过**，`swift build --build-tests` **RC=0**。
- **§7（新）：读一趟文件再答 JSON，到底落不落地**。题面故意只给路径、不给数字（fixture `shape 47 by 13`），答对只能靠读。实测 **0/3**：一轮 `"rows":10,"cols":10`（合法、`finish=stop`、整数纯属编造），两轮把数字拖到 `finish=length`。于是 §7 现在是 `xfail open`，而 §6 是 `probe_fail`：前者是没做到的能力，后者是已做到、回归即红。探针 12 现在七节：**8 passed, 0 failed, 7 measured, 2 known-open**。
- **撤销一条推断（它曾写在 `scripts/eval/README.md` 里指挥后来人）**：原文说"Apple 把 `maxWhitespaceCount` 默认成 32 就是修这一类的，honour 它就能白拿 12 格"。核对上游：32 是 `coreai-models swift/Sources/CoreAILanguageModels/GuidedGeneration/ConstrainedGenerationSession.swift:27`，而它上面几行明写该上限**在 next-token mask 上执行、"does not enlarge the compiled grammar"**（测试 `coreai-models swift/Tests/GuidedGenerationTests/WhitespaceLimitTests.swift:62` 钉住默认 32）。本轮实测那类塌陷 `maxWSrun=11`，**远不到 32**，重复的是字符串值里的数字而非空白 ⇒ 那条限制根本咬不住。我方另一处事实照写不误：`Sources/lib/CXGrammar/xgrammar_c_bridge.cpp:138` 传 `std::nullopt`，确实没有空白上限——但它不是 §5 的成因，也不擅自改语义去"凑"一格。
- **计分板同会话复测**：`bash scripts/eval/run.sh` → **TASK SUCCESS 22/35**（装载 36 题，1 题没跑成不算通过），三道 structured 全部 verify rc 1，逐题字节留档在 OUT 目录（`response-*.json` / `verify-*.log` / `artifacts-*.txt`）。结构化那 0 的原因至此有了名字：**要调用又要收 JSON 的回合缺 per-iteration 语法**——语法是每请求一份（`options.grammarSchema` 跨迭代复用），不是排法问题，留人拍板。
- **下一手的前提已经核实**：§ Open「无工具回合不可打断」指望的上游解药在本 pin 里**确实没有**——`.build-clt/checkouts/mlx-swift-lm` 停在 `bb0d5b0`，`Libraries/MLXLMCommon/ChatSession.swift` 有 27 个 `func` 却没有 `observe(to:using:)`，全 checkout 搜不到 `GenerationTransformer`（第一次搜的是 `Libraries/MLXLLM/ChatSession.swift`，那路径不存在，空结果不算证据，已换成 `find` 定位的真实路径重搜）。⇒ 注入接缝要拿到手，得按 bump 协议逐 commit 审 8 个消费面文件，不是本地绕得过的。
- **文档记账**：`AGENTS.md` 那条重写为"四种排法实测 + §7 开放"，门计数 `(9)`→`(11)`；本轮**没动任何预算常量**——探针索引里删掉 6 处已在 CHANGELOG 重复维护的带日期实测尾句（−615 B），换进 §6/§7 的新事实（+480 B），root **30424/30428**、corpus **155304/155386**，`make docs-check` 绿（P11 一开始就抓到 `(9)` 过期，正是它该红的样子）。





**10-23(11) P0 结案：`/mcp` 这个对外面此前对标准客户端一句合法请求都答不上来——数字 id 被判 Parse error、params 恒 nil、39 个工具一律描述成零参数；同一轮把 MCP 合成 `required` 的字典种子出口也钉死了**(P0 兼容性 / P0 可靠性 / P1 工具调用 / P3 回归防护)

- **怎么发现的**：不是读代码猜的，是把 HEAD 的 `serve` 起在干净端口（`OCOREAI_PORT`）再按规范投请求。三条当场现形：① `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` → `{"error":{"code":-32700,"message":"Parse error"}}`——`JsonRpcReq.id` 写的是 `String?`，合成 `Decodable` 于是**强制**字符串，而 JSON-RPC §4.1 允许 String / Number / Null，Python 与 TypeScript 的 MCP SDK、Claude Desktop 都发整数 ⇒ 一个标准客户端连一次握手都完不成，而 `POST /mcp` 是写在 `V1EndpointCatalog` 上对外公布的；② `params` 解码进 `paramsData`，线上根本没这个键 ⇒ 每个请求 params 恒 nil，`tools/call` 回 `{"result":{}}`——存在、空、长得像成功，客户端分不清「工具跑了没输出」和「参数被你丢了」；③ `tools/list` 对 39 个工具一律 `{"inputSchema":{"properties":{},"type":"object"}}` 且 description 全丢 ⇒ 对外把每个工具描述成不收参数，照着列表生成的调用必然失败。
- **修法**：`id`/`params` 改用本文件已有的无类型 JSON `JVal` 承接，`CodingKeys` 把 `params` 映射回线上键名；id **原类型回显**（§4.1 要求同一个标识符，数字不能答成字符串）；未初始化 / 缺 `params` / 缺 `name` 一律命名拒绝（-32600 / -32602 带字段名），不再回空壳；`doList` 不再自己凑一份薄翻译，改用唯一的 schema 之家 `ToolEntry.toToolDef()`（含嵌套 `properties`/`items` 与本轮排序后的合成 `required`）。
- **修后同机复测**（探针 34）：数字 id 7 被接受且回显 `int 7`；`tools/list` 39 个工具中 **35 个带真实参数面**（另 4 个本就零参数），例 `activate_app props=['app']`；`tools/call read_file {"path":"Package.swift"}` 真执行并回带 **11,841 字符**（含 `swift-tools-version`）；缺 `name` → -32602 且点名字段；MCP 往返流量之后普通 chat 仍 200。
- **顺手删冗余**：`MCP/MCPTools.swift`（84 行）**全仓零实例化**，唯一职责（忠实翻译 schema）现由 `toToolDef()` 一处承担 ⇒ 删除；文档里「三处同形」的说法随之作废，活口是两处：`ToolRegistry.swift:820`、`ToolEntry.swift:237`。
- **同一扇门的另一半（`required` 合成）**：`required` 在 JSON Schema 里是**集合**，顺序对模型、对 wire、对我们自己的派发都不承载语义，可它此前是 `Array(schema.parameters.keys)`——Swift `Dictionary` 的迭代序由**每进程哈希种子**决定 ⇒ 同一请求换进程换字节，正是 10-23(8) 那一类换了个门进来。修法一处收口 `ToolSchemaCanonical.sortedRequired`：**只排我们自己合成的**，调用方/服务端写下的 `required` 子集原样透传（那顺序属于请求本身，已确定）。上游同法：sglang `python/sglang/srt/entrypoints/systemone/joint_schema.py:48`、vllm `vllm/entrypoints/openai/decisions/strategies.py:902` 都以 `sort_keys=True` 规范化 schema 字节。**修不了的半边写清楚**：`properties` 以 `ToolSpec = [String: any Sendable]`（`mlx-swift-lm Libraries/MLXLMCommon/Tool/Tool.swift:5`）交上游，序由渲染者决定——实测 gemma-4 模板自己按字母排序（请求 `order_id,status,limit` → 渲染 `limit,order_id,status`），故本机此处无泄漏；保序的模板换进程仍会漂，那属于上游 `prepare()`/模板，不在本地重造渲染器。
- **活体证明（探针 33）**：真 MCP stdio stub 的 `tools/list` 不带 `required`（MCP 合法——`MCPBridge.swift:782` 用 `as? [String]` 读，缺省即 nil），三次冷启 `promptHash` 全等 `ca35e1d485b21336`，渲染出 `required:[alpha,bravo,charlie,delta]`（请求插入序是 `delta,charlie,alpha,bravo`）⇒ 跨进程字节稳定且按名排序；且每轮先坐实它是 local（`whitelist route (1 local + 0 caller-only of 1)`），否则「字节一致」是空话。
- **本轮两次自纠（仪器错，不是被测物错）**：① 把 `AnyCodable` 直接塞给 `JSONSerialization` 会抛 Objective-C 异常，而 `try?` **接不住** ObjC 异常——测试进程直接 `libc++abi: terminating due to uncaught exception` 而不是报 fail；改为走它自己的 Codable 往返取 Foundation 原生对象（`plainJSON`）。② 探针 33 第一版把模板引号 token `<|"|>` 当成 `<|"…"|>` 配对，正则跨了两个成员，抓出 `|>alpha<|` 判成参数名不对——**结论当场是对的**（哈希一致、字母序），是读数错；另有一处段名里的反引号被 shell 当命令替换执行。两处都在同一会话内改掉，并把「索引只写问题 + 判假条件、论证留在脚本头」落实。
- **门**：`MCPServerWireTests`(6)（数字 id 往返、字符串 id 不回归、params 真达工具、缺 `name` 命名拒绝、`tools/list` 真参数面、未初始化明说）+ `ToolRequiredOrderDeterminismTests`(4)（前提：省略 `required` 真到 nil 且参数集=4 地板；两处出口各自按名排序；显式子集保调用方原序）。修前那两条排序断言约 23/24 进程会红（4 键字典恰落字母序的概率 1/24），修后恒绿；跨进程证据交给探针 33。
- **验证**：`swift build` exit 0；`swift test --filter "MCPServerWire|ToolRequiredOrder|MCPSchemaFidelity|MCPTimeout|MCPStdio"` = **31 tests / 5 suites** 全绿（含未改动的 MCP 保真/超时/stdio 套，证明没把老面碰坏）；探针 34 = 10 passed / 0 failed；探针 33 = 10 passed / 0 failed；`make anchor-check` 46 anchors drift=0、裸上游 cite 182/182；`make audit` 绿；`make docs-check` corpus **145623/145623**、probe-index **34/34**、claims 30/30。
- **语料记账**：本轮唯一进语料的是两条新探针索引条目（README 是全 diff 里唯一语料文件，+735 B、−0），cap 由 144942 **可见地上修到 145623** 并在 `scripts/agents-md-contract.sh` 写明去向；相对 09-27 基线 152,041 仍为 **−6,418 B**，棘轮未破。

**10-23(10) 撤销：上一轮的「非本地工具不进 prompt」是假的，根因是我们自己的仪器不携带 tools——补上之后字节级看清了工具声明到底如何落地**(P0 文档诚实 / P1 工具面 / P3 可观测性)

- **假 NOTE 的根因在仪器，不在被测物**：探针 32 的 NOTE 用「白名单路由 0/N injected，只有 tools/no-tools 指令改变字节」解释两种工具形状哈希相同。本轮复查 `DegenerateMarginProbe.run` 发现它调的是 `UserInput(prompt:processing:additionalContext:)`——**根本没有 `tools:` 参数**：一次工具轮它重建的是线上从未喂过的会话，`promptHash` 覆盖 0 个 schema 字节，却仍输出一行像是对请求下判决的话。那条 NOTE 描述的机制是仪器无法观测的机制，整条撤销；10-23(9) 「非本地工具不进 prompt」这个前提同源，一并撤销（凡此前从*工具轮*读出的「字节相同」一律作废）。
- **修法**：`run` 收 `tools: [MLXLMCommon.ToolSpec]?` 并交给 `UserInput(tools:)`，调用点传 `registeredToolSpecs`——与 `ChatSession.tools`（`EngineInference.swift:3281`）同一份对象，不做 JSON 往返、不重排键，免得探针自己造出线上不存在的字节序；新增 `toolsCarried=N` 上报，让读者分得清「带 schema 的哈希」和「瞎的哈希」。`[String: any Sendable]` 本身 Sendable，跨 `container.perform` 直接过。
- **实测（探针 32，gemma-4-e2b-it-4bit，temperature=0）**：4 形状 × 3 冷启，每形状 `distinct promptHash=1`，`toolsCarried=[0,1,1,0]`；另一次 2 冷启复现出**同一组哈希**（bare `9bee6869f927756b`、required `d5a6b0b906c0514a`、unrequired `a0fb8c9aee0589ae`、history `3b4f6bce19bd131d`），跨调用一致。`fidelity=match` 四轮全中——补齐 tools 后重建 token 数与线上记录对得上，这是此前做不到的。
- **字节级（`OCOREAI_MARGIN_DUMP` 落盘后 `diff`）**：声明一个工具让投喂的 prompt 变化 **+595 bytes / +131 tokens**，且同时改两处——身份段整段换姿态（"This conversation gives you no tools: answer directly…" → "Assume the user wants code changes or tool actions…"，这正是此前观察到又解释不了的 systemChars 2811→3026 那 215 字符），并由 checkpoint 自己的模板吐出 `<|tool>declaration:lookup_order{…}<tool|>`（`ToolProseLedger` 判 skippedTemplateRenders，`0 ## Tool: block(s) written`，双重声明未复发）。该模板把 properties **按字母排序**（请求 `order_id, status, limit` → 渲染 `limit, order_id, status`），并在调用方省略 `required` 时**整个丢掉 required 键**——所以这颗 checkpoint 上属性序不可能泄漏哈希种子，而省略 required 等于告诉模型「每个参数都可省」。两者都是 checkpoint 行为而非我们的功劳；`toolCallFormat` 为 plain JSON 的 checkpoint 会直接序列化字典，那条路本轮未测。
- **诚实边界改写**：三处 `Array(schema.parameters.keys)`（`ToolRegistry.swift:817`、`ToolEntry.swift:235`、`MCP/MCPTools.swift:46`）在**注册表侧**，caller 声明的 schema 不经过它们，而 8 个 built-in 又全都自带 `required`——本机没有任何可达路径能碰到这三处，故仍不排序、仍不宣称已测；要关这格需要一个 `inputSchema` 不带 `required` 的 MCP 工具。
- **新门**：`logLine` 从 `log` 抽成纯函数（不占 GPU 也能测格式），`DegenerateMarginProbeReportLineTests`(3) 钉住①空上报必须写 `toolsCarried=0` 而非省略字段、②计数确实到达被 scrape 的那一行、③emit 格式与探针的 scrape 模式不许各自漂移，并对文件定位与模式匹配自设地板（扫不到就红，不许静默通过）。
- **验证**：`swift build` exit 0；探针 32 三次实跑（3 启动判定 / 2 启动跨调用复现 / 1 启动带 dump 供字节级 diff）；`make docs-check` 绿（corpus 144888/144942、probe-index 32/32、claims 30/30）；`make anchor-check` 抓到一处因插入一行而位移的 cite，已 bump `Package.swift:77`（`EngineInference.swift:5074`→`5075`），drift=0；`make audit` 绿。

**10-23(9) 新增探针 32：同一请求换进程还生成同一串 prompt 字节吗？顺带把「工具声明到底进没进 prompt」这条线钉在明处**(P0 回归防护 / P1 工具面诚实 / P3 可观测性)

- **为什么需要一条常驻门**：10-23(8) 那个 bug 单元测试永远看不见——Swift 每进程只固定一次哈希种子，同进程内两次断言必然一致。能抓它的只有跨进程实测，所以做成 `scripts/probes/32-prompt-byte-determinism.sh`：N 次冷启 × 四种请求形状（无工具 / 声明 `required` 的工具 / 不声明 `required` 的工具 / 带历史），按形状跨启动聚合 `promptHash`。
- **判据三条，含反真空**：① 每个形状跨启动必须**恰好一个**哈希（多一个就是 Dictionary/Set 或未排序 JSON 漏进 prompt）；② **同一轮内声明工具必须改变字节**——否则「稳定」只证明什么都没投喂，稳定就成了自证；③ 启动数与哈希数各自设地板，跑不够直接判失败而不是沉默。实测 `BOOTS=3`：**四个形状全部 distinct promptHash=1**，`notools`=`9bee6869f927756b`、两种工具形状=`668b96e1a6c28abb`、`history`=`3b4f6bce19bd131d`。
- **一次自查纠我自己的假判据**：第一版把「形状之间必须互不相同」写成硬断言，立刻报 3 个 FAIL——两种工具形状哈希相同。查日志才懂这是**设计如此**：探针声明的 `lookup_order` / `fetch_rows` 不是本地工具名，白名单路由 `0/N injected`，于是只有 tools/no-tools 那句指令改变字节，schema 文本根本不进 prompt。判据改成①不声明工具必须与声明工具不同（真敏感），②两种工具形状相同只记 **NOTE** 并写明原因。把已 documented 的设计判红，等于训练所有人无视这条门。
- **顺手把重复维护的数字清出语料**：探针 30 的条目不再抄塌陷率（`0/6, 6/6, 5-7/12` 留 CHANGELOG，两处维护必漂），改为指向 10-23 的结论与探针 32；探针 29/31 条目里的实测数值同口径删除。语料棘轮因此仍成立：**144888/144942 bytes**（新增 32 号条目后反而比改前更省），`probe-index=32/32`。
- **诚实边界**：`Array(schema.parameters.keys)`（`ToolRegistry.swift:817`、`ToolEntry.swift:235`、`MCP/MCPTools.swift:46`）这三处字典出口**本轮仍未排序**——因为当前实测路径下非本地工具不进 prompt，`required` 缺省分支也没被这条探针命中。是否排序、以及「调用方声明的外部工具该不该进 prompt」属工具面设计（`ToolDeclarationSurfaceTests` + 探针 11 §7 已管），**留人拍板**，不在本轮擅自改语义。
  - **本条的前提已被 10-23(10) 撤销**：「非本地工具不进 prompt」经字节级实测为假——模板会渲染 `<|tool>declaration:…`，工具声明确实进 prompt（+595 bytes / +131 tokens）。那三处出口仍未排序、仍未测，但理由变了：它们位于注册表侧，caller 声明不经过，不是「外部工具不进 prompt」。
- **验证**：`swift build` exit 0；探针 32 两轮实跑（先 3 形状全绿，再 4 形状暴露并修正判据）；`make docs-check` 绿（corpus 144888/144942、probe-index 32/32、claims 30/30）；`audit`/`anchor-check` 见提交说明。

**10-23(8) P0 结案：任务成败此前由进程哈希种子决定——注入 system prompt 的技能块顺序每进程随机，修根后同一请求 8/8 稳定答出**(P0 正确性 / P0 可靠性 / P1 上下文管理 / P3 回归防护)

- **伪前提先死**：10-22 起所有判别臂都写着「同一批字节、identical prompt bytes」，而**没有任何一处验证过字节**——`DegenerateMarginProbe.fidelity` 只比 token **数量**。补上仪器（`promptHash` = FNV-1a over 实际喂给模型的 token 序列，`OCOREAI_MARGIN_DUMP=<dir>` 落真实文本）后，第一次跑就翻案：**同一请求 8 次冷启产生 4 个字节变体**（`file,terminal,search,memory` / `terminal,file,memory,search` / `terminal,file,search,memory` / `file,terminal,memory,search`），长度分毫不差（2880 chars / 713 tokens），**唯一区别是四个技能块写进 system prompt 的先后**。
- **根因**（`Sources/ocoreai/Skills/SkillRegistry.swift`）：`resolveOrder()` 的种子 `Array(skills.keys)`、Kahn ready 队列 `inDegree.filter{…}.map(\.key)`、邻接遍历、异常兜底 `Array(skills.keys)`，以及 `list()`/`listCategories()`——全是 Swift `Dictionary`/`Set` 出口，而 **Swift 每进程随机化哈希种子** ⇒ 顺序每进程不同 ⇒ 注入字节不同 ⇒ logits 落进不同区制 ⇒ 两个变体在第 2 步选 EOS（1 token 空答复），两个健康。**一次编码任务是否开口，由此前的约 50% 抛硬币决定**，且此前无任何门可拦。
- **修在根上**：所有 tie-break 换成**作者声明序** `BuiltInSkill.allCases`（terminal→file→search→memory），`SKILL.md` 自定义技能按名排在内置之后；顺带把 `/v1/models` 的条目序也定下来（`EnginePool.listModels()` 同样取自 `loadedModels.keys`，未定序时客户端回退取 `data[0]` 每次重启换模型）。
- **选声明序不是随手挑的，是带着可证伪预测去验的**：四个变体里 step-2 结果沿一条线干净劈开——`terminal` 开头的都续写（step2 `'\n'`，margin 0.8533 / 0.2172），`file` 开头的都在第 2 步 EOS（margin 0.0000 / 0.6212）。声明序是 terminal-first，于是预测：改后 hash 必为 `897b9b75226d0e28`、step-1 lp 必为 −0.0278、step-2 margin 必为 0.8533、且 8/8 完整答出。**实测四条全中**：`distinct promptHash = 1`、区制唯一、8 轮全部 `tokens=200 reason=maxTokens`。
- **中间一步的账认下来（不留代码，但记在这里）**：只把 tie-break 改成字母序时，结果是 `distinct promptHash = 1` 但 **8/8 全塌**（定在 `file,terminal,memory,search`）。确定性是**必要不充分**：先把硬币变成可复现的失败，才谈得上修。若当时就此提交，等于把成功率从 ~50% 降到 0%。
- **门（两层，缺一不可）**：① `SkillRegistryDeterminismTests`(2) 钉进程内契约——`list()`/`listCategories()` 必须有序，`resolvedSkills()` 必须等于声明序且跨实例一致（去掉任一 tie-break 即红）；② `scripts/probes/margin-summary.py` 新增 `distinct promptHash = N`，**N>1 直接判 NON-DETERMINISTIC PROMPT (P0)** 并列出每个变体的结局——这是唯一能抓跨进程随机序的门（单元测试在同一进程内看不见它）。另修一条会误报的措辞：终止步报告数为 0 时，区分「本轮没塌（无事可报）」与「塌了但仪器瞎（includeStopToken 没生效）」，绿灯不许喊假 P0。
- **仍未证 / 下一步**：为什么 terminal-first 与 file-first 会让一个 4-bit 2B 模型在「从 1 数到 200」上选择闭嘴——未证；这属于小模型对 2880 字符常驻注入的迷信行为。**根治方向是少注入、按需注入技能块**（本轮的字节数就是证据：无关注入每轮都在花钱，还翻命），那是 P1 的注入策略设计，留待下一轮带着数据提。`OCOREAI_MARGIN_DUMP` 默认关，只在诊断/探针下开启。GUI 运行时仍只有 `OCOREAI_GUI_LIVE` 那一寸，本轮无界面结论。
- **验证**：`swift build`（CLT `.build-clt`）exit 0；`swift test --filter "Skill|SystemPrompt|Capabilit|Model"` → **310 tests / 63 suites 全绿**；臂 E 三次实跑演进记录完整（4 hash 抛硬币 → 1 hash 全塌 → 1 hash 全答）；`docs-check`/`audit`/`anchor-check` 见提交说明。

**10-23(7) 塌陷那一步终于被读到了：EOS 与换行在 4 位小数上完全平手，谁赢由进程数值决定**(P0 正确性 / P0 诚实口径 / P3 回归防护)

- **一句话**：之前所有臂都在找「哪一轮塌陷」，从没读到「塌陷发生在第几步、比多少」——因为**自家探针把终止步关掉了**。上游只在调用方索要时把终止 stop token 交给 handler，并且只在同一个开关下把该步的 logprob 交出（`Evaluate.swift:2762`、`:2774`，`TokenLoopHandler.swift:62` 默认 false）。`DegenerateMarginProbe` 两个都用默认 ⇒ 重建永远停在 step 1，此前写在 `DegenerateTurn.swift` 与 10-23(5) 里的「塌陷轮记不到 step 2」是**仪表盲，不是事实**。现显式传 `includeStopToken: true`。
- **修完立刻出判据（臂 E `BOOTS=10` 实跑，同字节贪心、每轮 fresh session）**：同一 prompt 只落进**四个离散区制**，结局由区制唯一决定——
  · `step1 lp=-0.0094` → `step2` 选 `<turn|>`(EOS, lp=-0.6932)，margin **0.0000** → 塌陷；
  · `step1 lp=-0.0111` → `step2` 选 `<turn|>`(EOS, lp=-0.4301)，margin 0.6212 → 塌陷；
  · `step1 lp=-0.0222` → `step2` 选 `\n`(lp=-0.5905)，margin 0.2172 → 健康；
  · `step1 lp=-0.0278` → `step2` 选 `\n`(lp=-0.3550)，margin 0.8533 → 健康。
  四档里 step1 的 EOS 全在 top-8 之外 ⇒ **第 1 步从不选停，死在第 2 步**；而 step-2 margin 塌陷组 0.0000..0.6212 与健康组 0.2172..0.8533 **重叠** ⇒ 宽度不决定结局，**决定结局的是「EOS 与换行本来就在 0~0.85 nats 的近平手里，其中一档是 4 位小数完全平手」**。平手时 argmax 听谁的，就是内核数值噪声——这就是 P0 的真实形状。
- **撤回一条被引用了两轮的读数（连带删掉日志里的一处谎）**：`firstTokenMs` **不是首 token 延迟**。代码证据：它在第一个输出 chunk 处盖章（`EngineInference.swift:4635`），而标准非流路那个 chunk 到生成结束才来；数据证据：健康轮 `firstTokenMs=4671.26` 配 `overallMs=4672.66`，200 个 token 不可能在 1.4 ms 里解码完。于是 10-23(5)/(6) 与 `DegenerateTurn.swift` 里「健康 4.7–7.5 s = 一次真 713-token prefill」「塌陷 0.13–0.26 s = prefill 没跑」整套读法作废：同一 713-token prompt 上两点（1 token≈147 ms、200 token≈4672 ms）拟合出固定开销 ≈124 ms、解码 ≈44 tok/s ⇒ **prefill 故事两个方向都死**，30 倍差就是 200 对 1 个 token。日志字段随之从 `firstTokenMs` 改成 `wholeTurnMs`（不说自己撑不住的字段名），并把「为什么停」显式指向 `OCOREAI_MARGIN_PROBE`，不再暗示 prefill。
- **一条能省下半年弯路的不可能**：区制**进程内固定**（同一进程内每轮同结果，15 启动 84 轮的同质性早已测过，今天 10 启动再复现）⇒ **进程内自动重试不可能改变结局**，直觉里的「塌陷就重发一次」被数字否掉；能换区制的动作只有换进程。EOS 下限类缓解（vllm `sampling_params.py:339`、sglang `penaltylib/min_new_tokens.py:85`）在 mlx-swift-lm 里没有对应物（`grep -rn minTokens Libraries/MLXLMCommon/` 零命中），要做就是改生成语义——**留人拍板，不自作主张**。
- **两台新仪器（都进仓，结论可复跑）**：`scripts/probes/boot-diff.py` 把启动日志按形状归一化后做组间结构差——131 个形状、两组 `StdTurn` 前平均都是 97 行，**没有任何结构差活过 n≥3**（唯一差异是 audit JSON 键序噪声）⇒ 差别不在日志里，只能往下（数值）找，这条排除把「找日志差异」这条路也关掉；`scripts/probes/startup-correlation.py` 逐启动联查 8 个字段，并把 `tokens` 摆进候选，让 `firstTokenMs` 的分离与 token 数同屏出现（否则它就是用结论证明结论）。
- **反真空门**：`scripts/probes/margin-summary.py` 新增终止步计数与 `eos lp at the terminating step`，**报告数为 0 就自称瞎**（`includeStopToken is not taking effect`），不许拿 step-1 边际冒充判据。本轮实测 4/10 行报告终止步，全部来自塌陷轮——正是设计上该有的样子。
- **诚实边界**：区制由什么设定仍未定（allocator 布局 / Metal 内核选择 / 量化 scale 编译变体都只是候选，未证）；step-2 近平手是重建（`cache: nil`）读到的，与实轮是否逐位同源仍未测；`kvcache` 快照目录仍空、像素仍被拒、GUI 运行时仍只有 `OCOREAI_GUI_LIVE` 那一寸 ⇒ 本轮没有任何界面结论。
- **验证**：`swift build`（CLT `.build-clt`）exit 0；臂 E `BOOTS=10` 实跑并印出终止步；`docs-check`/`audit`/`anchor-check` 见提交说明。


**10-23(6) 臂 F 把「磁盘 KV 是载体」也否了；代价是今天真删空了 44 个 prompt cache 快照——bug 修了，账记在这**(P0 正确性 / P0 可靠性 / P3 回归防护)

- **臂 F（= C × E：每轮清空磁盘 KV 快照，同时 `=all` 量 margin）8 次冷启**：step-1 档位与臂 E 是同一批值——塌陷 `-0.0111`，健康 `-0.0278 / -0.0222`，零重叠复现（gap 0.0111 nats）。连臂 E 的 12 轮加上崩掉那次的 8 轮，**同机同字节累计 28 次冷启**，四个离散档位每次都出现、分离每次都成立 ⇒ **磁盘 KV 快照不是载体**（臂 C 过去只给出塌陷率，现在有了档位级读数背书）。
- **真丢了东西，不遮掩**：臂 C/F 原先用 `mv` 把快照搬去临时备份，而 `probes_cleanup` 会在**首次 mid-run cleanup** 抽干 `PROBE_EXIT_HOOKS` ⇒ 备份在运行中途就被搬回 cache，下一轮 `rm -f "$CACHE"/*` 随即删掉，终局 restore 无货可还。今天 `~/Library/Application Support/ocoreai/cache/kvcache` 因此**被删空（44 个文件、695,860 KB）**，且探针轮次不会再生成它们（跑完 8 轮计数仍是 0）。这是可再生的 prompt cache、不是用户数据，引擎照常工作（同一批冷启里仍有 200 token 的健康答复），但**延迟基线从今天起断裂**：任何引用旧 `firstTokenMs`/tok-per-sec 量级的比较都必须注明基线已变，除非有人给出可复现的重建路径。
- **修在根上**：备份改 `cp -p`（原件留在 `ORIG` 直到终局），`restore_cache` 先 `cp` 回再数，**只有当场数够**才允许 `rm -rf "$ORIG"`，数不够就把备份路径打到 stderr 保留现场；臂 C 与臂 F 同改。
- **另修两个自己刚埋的 bug**：把判词从 heredoc 提成 `scripts/probes/margin-summary.py`（六臂共用一处算术）时，脚本里还留着 `os.environ["ROWS"]` ⇒ argv 传参 KeyError，臂 F 第一次跑完**没印判词**；判词前缀写死 `E` ⇒ 臂 F 的输出被标成 E。现 argv 传参 + 标签参数化（`E`/`F`），并把「margin 稳定而结果翻」这条判词的样本量下限钉到**每组 n≥3**——n=1 时 min==max 是恒真，属于会说谎的判词。
- **诚实边界**：塌陷率 F=2/8、E=3/12，样本太小，不宣称清空缓存改变了任何行为；载体仍未定，但**排除清单又长一格**：内容相关且进程内固定、磁盘 KV 快照、kvCache 配置、compile 开关、内存档位、session 池都已用数字排除。剩下最像的是**开机即定的数值路径差异**（allocator 布局 / Metal 内核选择 / prefill 编译变体），而 step-1 lp 已经是可观测的读数：任何启动期开关只要能把 `-0.011/-0.009` 这一档变没，它就是候选载体。
- **样式网关停止说谎（`make format-check` / `make format`）**：本机没有 brew 版 swift-format，回落 `xcrun swift-format` 的版本串是 `main`，而 CI 钉 `603.0.0`。原先它自称 CI-parity 并 `--in-place` 重写文件——于是每次跑都把 CI 早已收下的 5 处再排一遍，把「工具漂移」摆进工作区等着被误提交。现在按版本分岔：**等于 603.0.0 才允许写盘并按哈希判红**；不等于就只做 `lint`（只读、不写盘、不判红），并明写「样式的权威是 CI 那一腿」。顺手修掉计数 bug：lint 的诊断走 **stderr**，`awk END{NR}` 只看 stdout ⇒ 明明报了 116 条却打印「0 line(s)」，现已 `2>&1` 合并计数。
- **验证**：臂 F 8 轮、臂 E 4 轮实跑（判词由共用脚本算出，标签正确）；`swift build` exit 0；`docs-check`/`audit`/`anchor-check` 绿。

**10-23(5) 塌陷第一次有了可测前兆：同一字节只落进四个离散 logits 档位，而塌陷那一档「更肯定」**(P0 正确性 / P0 诚实口径 / P3 回归防护)

- **纠自己的账①：仪器其实一直在每轮付费**。`DegenerateMarginProbe.isEnabled` 只读环境变量，而调用点落在 `DegenerateTurn.isSuspected` 判定**之外**（`Engine/EngineInference.swift:4755`）⇒ `OCOREAI_MARGIN_PROBE=1` 时**每个**标准轮都多跑一次 ≤4 token 生成，可文件头和 10-23(2) 都写着「健康轮零开销／只在已塌陷轮」。现由调用点显式持门：默认只塌陷轮跑，`OCOREAI_MARGIN_PROBE=all` 才扩到每轮。门 `DegenerateMarginProbeModeTests`(3)：unset=不上膛 / `=1` 只塌陷轮 / `=all` 扩轮 / 认不得的值（`yes`）不许上膛。
- **纠自己的账②：脚本从不给仪器上膛，还能把「没测到」印成结论**（P0 级可靠性）。全仓没有任何地方设 `OCOREAI_MARGIN_PROBE`，全靠操作者手口；而 arm D 用 `grep -c "step[0-9]* chose"` 数步数，探针没跑时 STEPS=0 恰好落进「parity replay 也塌陷」分支——**零测量也能打印出「kvCache 是载体」的判词**。现在脚本自己 `export OCOREAI_MARGIN_PROBE="${OCOREAI_MARGIN_PROBE:-1}"`（一处家），arm D 只统计 `fidelity=match` 的行，缺行或未核验一律 `NO VERIFIED PROBE … — not counted`。
- **新臂 E（把 margin 和结果配成对）**：A–D 只在**已经塌陷**的轮次量 margin，于是「小 margin ⇒ 塌陷」这句话在同一次构建里从来没有健康对照组，属不可测命题。`=all` 让每次冷启都产出一条自己那份字节的 margin，才谈得上对照。
- **12 次冷启动实测（同机同模型 greedy，`Count from 1 to 200…`，`max_tokens=200`）**：同一份字节只出现 **四个离散的 step-1 logprob**——`-0.0278`×6、`-0.0222`×3、`-0.0111`×2、`-0.0094`×1；结果与档位**零重叠**：塌陷 3 轮 lp `-0.0111 / -0.0094`（step1 margin `5.5677 / 5.8204`），健康 9 轮 lp `-0.0278 / -0.0222`（margin `4.4361 / 4.6290`），间隙 **0.0111 nats**。⇒ **塌陷的前兆是第一位 token 更肯定，不是近天平局**；margin 宽度不可能是机制（塌陷那侧反而更宽）；且塌陷轮**连 step2 都没有记录**——终止发生在「第一个已采样 token」与「下一次前向」之间。
- **撤一条被引用过的数**：10-23(2) 记的「step2 `
` vs `<turn|>` margin=0.0466」在本轮 12 次重建里**一次也没出现**（step-2 margin 实测 `0.2172–0.8533`）。它只是某一次重建的一次性读数，**不得再当作塌陷处的 margin**；何况重建≠真轮（重新 `prepare`、不带会话 KV）。值得追的是**档位**，不是任何一个单独的 margin。
- **下一步已能具体化**：档位是**进程级**的（同一次 boot 里真轮与其重建同档），所以要找的是开机即定的数值路径差异——allocator 布局 / Metal 内核选择 / prefill 编译变体这一类（arm C 已排除磁盘 KV 快照）。判据现成：把 step-1 lp 当读数，任何启动期开关只要能把 `-0.011/-0.009` 这一档变没，它就是候选载体。
- **验证**：`swift build`（CLT `.build-clt`）exit 0；`DegenerateMarginProbeModeTests` 3/3；臂 E 实跑两次（`BOOTS=6` 与 `BOOTS=12`，判词由脚本自己算，不靠人眼看）；`make docs-check`/`audit`/`anchor-check`/`format-check` 见本轮提交说明。诚实边界：塌陷样本 n=3，「零重叠」是这 12 轮的观测而非已证机制；像素与 in-view GUI 交互在本机仍不可用，故本轮不声称任何界面结论。

**10-23(4) GUI 的发送缝第一次被执行；一条 P2 结构缺陷定位在它该在的地方**(P1 执行链 / P2 诚实面 / P0 网关诚实)

- **结构真相（推翻交接里的读法）**：交接说「GUI 发送逻辑在 View 里，没窗口就测不了」。读盘：**缝是 `ChatViewModel.chat`（`Sources/ocoreai/UI/ViewModels/ChatViewModel.swift:975`）**，`ChatView.sendMessage`（`Sources/ocoreai/UI/Views/ChatView.swift:971`）只是把输入交给它，流式中的转向另有其路。GUI 走 `DirectInferenceClient`（`Sources/ocoreai/UI/ViewModels/ChatViewModel.swift:1120`）**不经 HTTP** ⇒ 探针从未覆盖这条路。
- **一条从未被执行的缝**：`Tests/` 里此前没有任何一处调用过 `ChatState.chat(...)`，也没有任何一处读过 `OcoreaiEngine.shared.activeEnginePool`（两条 grep 在 `2a9bff4` 皆 0 命中）。所以「GUI 能发出去」一直是从 HTTP 探针外推的推论，不是验证过的事实。
- **新增门 `ChatStateSendPathTests`(2)**：① 恒定跑（无需 Metal）——无引擎时必须**看得见的失败**：用户气泡留存、`errorMessage` 非空、`responseText` 为空（不许凭空造答复）、`loading` 复位（卡在 true 就是让输入框永久失聪）；② `OCOREAI_GUI_LIVE=1` 真跑一轮：`mlx-community/gemma-4-e2b-it-4bit`，**TTFT 三轮实测 1188 / 1868 / 1763 ms**，回复 19 字符正是指令要的那句，SQLite `messages` 里 user+assistant 两行都在且 assistant `tokenCount>0`（GUI 展示的历史就是从这张表读回来的）。跳过口径沿用 `CoreAILiveGenerateTests`。
- **新抓一条 P2（速率徽章永远画不出来）**：设置里勾了 Performance 也不会有 tok/s——interim chunk 按设计带 `tokPerSec: nil`（`Sources/ocoreai/Client/DirectInferenceClient.swift:545`），速率只在终止 chunk 上（`:627`），而终止 chunk 与清值、`loading = false` 落在同一个 MainActor turn（`Sources/ocoreai/UI/ViewModels/ChatViewModel.swift:1437`），能画的那一帧 `isStreaming` 已经是 false（门在 `ChatView.swift:496`）。三轮 20 ms 轮询 0 次看见；`promptTokPerSec` 同为 nil ⇒ **还分不清**「终止 chunk 没到 VM」与「上游本轮没报」，诚实记账：下一条仪器在客户端边界直接看终止 chunk（HTTP 面已有 usage 探针可对拍）。机制写在 `ChatView.swift` 注释旁，不在文档里抄第二份。
- **顺手修三条假 cite**：`Sources/ocoreai/Tools/ClipboardTools.swift:15`、`Sources/ocoreai/Tools/BuiltInTools.swift:654` 引用的 `ChatView.swift:914/:925` 落在 image picker 上，剪贴板真身在 `:1123`（NSPasteboard）/`:1138`（UIPasteboard），已改；`ContextWindowPolicy.swift:41` 的 `:690` 经本轮位移后正好落在 `Text(String(format: StringKey.contextMeter.l,…))` 上，不动。
- **网关自我诚实**：本机没有 brew 版 swift-format，`make format-check` 回落到 `xcrun swift-format`，版本串是 **`main`**，而 CI 钉死 **`603.0.0`**（`.github/workflows/pull_request.yml`）。它会把已提交且 CI 收下的文件重排（本轮就重排了 `Engine/DegenerateMarginProbe.swift`），而原话还自称 "CI-parity"。现在每次跑先报版本，并在非钉版时明写「本地重排是**工具漂移**不是违规，别当修复提交」；那条漂移已回退，未进提交。
- **文档一处一真**：iOS 运行时零验证在 root 与 `UI/AGENTS.md` 各写一份，删 root 副本，把 root 独有的细节（MCP/Security 未定、`ChatView`/`MultimodalControls` 仍需活验）并入 UI 指南那条。
- **验证**：`ChatStateSendPathTests` 2/2 绿（含一次 live，12.8 s）；`swift build`（CLT `.build-clt`）exit 0；`make docs-check`、`make audit`、anchor-check、`make format-check` 除上述工具漂移外零命中。诚实边界：像素仍被拒（`could not create image from window`），故本轮**没有**任何依赖布局的改动；徽章挪位置留人拍板。

**10-23(3) 交付 GUI 端到端真跑通；顺手纠正两条错账：一句「GUI 运行时零验证」早就不成立，而像素抓取从 10-22 的可用退成了被拒**(P0 可靠性 / P3 回归防护 / P0 诚实口径)

- **先纠错（对自己引用的交接记录）**：本轮开场引用「GUI 端到端运行时验证 = 0」。查磁盘语料后**该说法作废**：`Sources/ocoreai/UI/AGENTS.md` 早有 § GUI end-to-end — measured scope，并记着 10-22 抓到了真实帧（`900x472`、140 KB、**846 colours**）。**注入给我的 AGENTS.md ≠ 磁盘上的 AGENTS.md**，这条老 hazard 又一次差点变成新结论；凡引用「文档说过什么」，先读盘。
- **今天实测（交付 bundle，不是 CLI 替身）**：`scripts/e2e-gui-app.sh` 全绿——版本平价 `0.1.14 == tag v0.1.14`；:8080 的监听者**就是** `build/ocoreai.app/Contents/MacOS/ocoreai`；窗口可见 `810x426`；真实一轮 `reply: 'OCOREAI_GUI_E2E_OK'`；SIGTERM 优雅退出（drain 约 5 s，我第一次用 4 s 判定误报了一次 LEAK，判定窗口放宽后复测 clean）。
- **新出现的真退化**：像素抓取在本机失败——`screencapture` 报 `could not create image from window`，而同一检查 10-22 还能出 846 colours。**这是验证通路的退化**（抓屏授权/窗口条件），不是产物缺陷，但必须记账：像素只在真抓到时才声称，UI 指南相应改为「10-22 出过 / 10-23 起被拒」两句并附原始报错。
- **修掉一处会吞掉整条腿的门设计**：`scripts/verify-gui-window.sh:64` 裸调 `screencapture`，在 `set -euo pipefail`（同文件 :23）下被拒即中止——于是 `e2e-gui-app.sh` 最关键的「真跑一轮 completion」永远轮不到执行，且 app 被留在运行中占住单例锁（实测泄漏过一次，手工 TERM 才清）。修法：抓取失败时**默认仍然致命**（`GUI_REQUIRE_PIXELS=1`，CI 语义不变），仅本地交付 e2e 显式传 0 并打印「像素证据已跳过」；`e2e-gui-app.sh` 加 `trap cleanup_app EXIT`，任何早退都 TERM 掉自己启的 bundle。
- **两向都验过，不是单向**：严格默认（不设变量）实跑 → `❌ capture failed and pixel evidence is required here`、RC=1（CI 硬门没被削弱）；本地豁免 → 一路跑到 `🎉`，退出后无残留进程。
- **仍未验证（不粉饰）**：SwiftUI 视图内交互（键鼠注入／Accessibility 驱动）零验证；App Store 构建不提供 HTTP 桥，所以这条 e2e 只覆盖 direct-distribution 产物；CI 跑窗口证明但不跑 completion。`Sources/ocoreai/UI/AGENTS.md` 的 § GUI end-to-end 已按上述实测重写，并删掉 traffic-light 那句（它和 `scripts/verify-gui-window.sh` 头部注释重复——代码在哪，理由记在哪）。

**10-23(2) 第一次量到塌陷处到底差多少：step2 上 `\n` 与 `<turn|>` 只差 0.0466 nats；顺带差点把 kvCache 错认成载体**(P0 正确性 / P3 可观测性 / P3 回归防护)

- **仪器**：`Sources/ocoreai/Engine/DegenerateMarginProbe.swift`。为什么不能借 chat 面：`ChatSession.swift` 对 `logProbabilities`/`LogProbabilityTokenLoopHandler` 零引用，`.probability` 事件只挂在 `LogProbabilityTokenLoopHandler.swift:9` ⇒ 给 `chatSession.generateParameters.logProbabilities` 赋值是静默 no-op。改走上游可观测缝（`TokenIterator` + `generateLoopTask` + `LogProbabilityTokenLoopHandler`，`Documentation.docc/generation-observability.md`）。**保真自证**：重建自己数出的 `promptTokens` 与塌陷轮记录的数字对账，实测 `promptTokens=713 fidelity=match`——不是假定，是每行自带。
- **量到的数**（greedy，同进程、同字节）：`step1 chose '1' lp≈-0.01`；**`step2 chose '\n' id=107`，rival `<turn|>` id=106（EOS），margin=0.0466**；step3 才轮到 `'2'`。也就是说塌陷位就是「换行 vs 结束符」的**近天平局**，差距是 1e-2 nats 量级。而跨 boot 看，同一位置 step1 的 lp 在 `-0.0091 / -0.0094 / -0.0100 / -0.0111 / -0.0278` 之间跳——**跨进程数值抖动与 margin 同量级**，近天平局被数值掀翻从此有数可依，不再是猜测。
- **kvCache 错认载体，被自己的门拦下**：第一批 4 次 parity（沿用引擎 `genParams`，含 `kvCache`）重建全部停在 step1，而 `OCOREAI_MARGIN_NO_KV=1` 的 2 次重建走到 step2+ ⇒ 形似单变量分离。同一仪器再跑一遍：parity 三 boot **一次没塌**，no-kv 的 boot3 重建反而 **3/3 停在 step1**。⇒ 旗标不决定结果，boot 决定；`kvCache` **不是**载体，`scripts/collapse-discriminators.sh` arm D 当场输出 `VERDICT: INCONCLUSIVE — one leg never saw a collapse, so nothing was separated`。这条硬门（两臂都必须真的出现塌陷、且形状必须完全跟随旗标）是专门为了拦住这类「n 很小但看起来很干净」的分离而写的，它第一次上岗就起作用了。
- **顺带解释了一条旧负结果**：`kvCacheQuantization.enabled=false` 当年「没动它」并不奇怪——`makeKVCacheConfiguration` 带 fallback（`Engine/AGENTS.md:48`：包括那个过去会返回 nil 的非量化分支），关全局开关仍会得到非 nil 的 kvCache、走同一条路，因此那个实验在设计上就分不出东西。
- **现在仍然成立的**：塌陷是 **(内容 × 进程)** 层面的判定（arm A：同进程内 TARGET 连塌、另两条 prompt 出满长度）；机制候选收敛到「该位置近天平局 + 跨进程数值抖动」；`min_tokens` 类 EOS 地板仍只在 plumbing 证明后才谈，且必须像 vllm/sglang 那样按请求显式，不做静默默认。
- **门与成本**：`OCOREAI_MARGIN_PROBE=1` 才跑，只在已判定塌陷的轮次多花一次 ≤4 token 生成；健康轮零开销。`swift build` exit 0。

**10-23(1) 「boot 内一致 84 轮」是实验设计造出来的假象：把内容交错一下，进程全局说当场死，磁盘快照也说谎**(P0 正确性 / P3 回归防护)

- **盲区在哪**：此前 15 boots × 同 prompt（84 轮）全部 boot 内一致，读起来像「进程级绑定」。错在**每个 boot 只用一条内容**——单一内容下的 boot 内一致性由内容保证，两种假设（进程全局数值 / 内容特定）在这个设计里根本分不开。缺的不是更多轮数，是**第二条内容**。
- **arm A（交错内容，同进程）**：`T=C D1=ok(200) T=C D2=ok(173) T=C`（boot 1），boot 2 同形（D 出 200/133）；boot 3–5 全 ok。⇒ **不是进程全局**：同一进程里计数 prompt 连塌 3 次，另外两条 prompt 照常出满长度答案。
- **arm B（nonce 变体，任务相同、字节不同、此前从未发过）**：变体 8/8 出 200，TARGET 3/4 塌。⇒ 键在**prompt 字节**，不在任务语义。
- **arm C（`cache/kvcache` 清空后逐 boot 重跑）**：TARGET 仍稳定塌（`T=C U=ok(38) T=C` ×3 boots，boot4 全 ok）。⇒ **磁盘 KV 快照恢复不是机制**，H2 死。
- **反例当场也记**：arm C 另一次跑出 `T=ok(200) U=C T=ok(200)`——nonce 塌而 TARGET 不塌。⇒ 绑定**不钉在某一条串**上，是 (内容 × 进程) 的组合，与「某些内容在 slot-2 本来就接近平局、由进程级数值定夺」一致。
- **下一台 instrument 不能挂在 chat 面上（已核）**：`ChatSession.swift` 里 `logProbabilities` / `LogProbabilityTokenLoopHandler` **零引用**，`.probability` 事件只存在于 `LogProbabilityTokenLoopHandler.swift:9`，而 mlx 文档明写普通 `generate`/`generateTokens` 流不发概率事件（`Documentation.docc/generation-observability.md`）⇒ 给 `chatSession.generateParameters.logProbabilities` 赋值将是**静默 no-op**，正撞自家规则（wire 收下的旋钮必须抵达引擎；替换件必须运行时可检）。margin 要走 `generateLoopTask` + `LogProbabilityTokenLoopHandler` 自建一趟，代价 ~180 ms warm 重 prefill，可接受。
- **入库仪器**：`scripts/collapse-discriminators.sh`（arm A/B/C + `ARMS=`/`BOOTS=` 单臂开关）。它自己先伤了自己两次，都被「跑一遍」抓到并修在原地：① `trap … EXIT` 写在 source 之前会被 `_lib.sh:158` 的 `trap probes_cleanup EXIT INT TERM` 整条替换，还原静默失效；改用 `probe_atexit` 注册。② 还原核验拿「移空之后」的备份目录计数 ⇒ 44 对 0，好结果报成失败；改为在移出时记下基线、结束时**无条件**核验（`probes_cleanup` 会在每次 boot 之间抽干 hook，只在最后一个 handler 才报的保险不是保险）。
- **用户数据两次靠人肉救回**：`~/Library/Application Support/ocoreai/cache/kvcache` 一度被 park 且无人还原。现状已核对齐：44 `*.safetensors` + 44 `.manifest.json`，695,860 KB，备份目录已清。

**10-22(12) 编译器路线当场判死，进程级绑定收到 84 轮支持，而它自己的旧断言是最后一块脏地方**(P0 正确性 / P0 诚实口径 / P3 回归防护)

- **新变量、新死法（编译融合）**：`Gemma4Text.swift:32/:38` 把 RMSNorm/GeLU 用 `compile()` 融合，而 mlx 每进程只读一次 `MLX_DISABLE_COMPILE`（`mlx/compile.cpp:220` 函数内 `static`）——形态刚好匹配「进程内固定、跨 boot 翻」。A/B 两臂 6+6 boots × 4 轮同 prompt 贪心（48 轮，`ps eww` 证实变量真进了进程）：baseline 3/6 boots 塌、nocompile 4/6 boots 塌，**没有分离**。⇒ 编译路线不是载体。顺带把嫌疑面收窄：mlx 的 Metal 后端**没有任何** `getenv` 旋钮（全部 env 只有 CUDA/PTX/compile/rank 那几个），所以那个进程级开关不可能靠环境变量逼出来。
- **env 与 config 是被构造排除的，不是被测排除的**：同一 A/B 臂内 env 和 config 恒定，模式仍跨 boot 翻 ⇒ 决定者既不是 env 也不是 config。这一条比「拍一张 config 快照说它一样」强，因为它不依赖快照覆盖了什么。
- **进程内一致性涨到 84 轮，然后自我证伪掉自己的下一个假设**：15 boots × 同 prompt 贪心全部 boot 内一致（无一混合）。这与本文件 16:08 那条记录冲突（同一进程、串行、零重叠：150 token 然后 1）。两者的差别看起来是轮数，于是把轮数立成下一条轴并立刻量：3 boots × 12 轮、每轮换新 `session_id` ⇒ `ok×12 / ok×12 / C×12`，**一轮转换都没有**。⇒ 「进程内累积状态」也不是机制；剩下唯一的反例就是 16:08 那一双，进程级模型要么解释它，要么复现失败。
- **本轮第三处自我更正落在文档自己身上**：`scripts/probes/30-repeated-prompt-delivery.sh` 的头注释还写着「the turn never forwarded its prompt to the model」，而 3035d5e 已经用数字撤回了这句话（713 token 的 prefill 在 warm 进程只值 ~180 ms，130–257 ms 与「真跑了 prefill」一致）。**一个事实五个家，撤回就要追五处**——这是 P3 跨文件一致性缺口的现场证据，不是文风问题。已在原地改为测量口径。
- **修一处真实损害**：上一条实验 park 掉的 KV 缓存目录一直没人还原（`…/cache/kvcache/kvcache.parked`，88 文件 680 MB，活目录空）⇒ 已搬回原位并删掉 parked（44 `*.safetensors` + 44 `.manifest.json`，~695 MB）。实验结论已定而不还原，等于把用户的磁盘缓存一直关着。
- **下一条轴（已定，未跑）**：量(slot 2) 的 `logit(EOS) − logit("2")` 边际——边际≈1e-2 ⇒ 数值在近平局处翻转；边际≥5 ⇒ 喂进去的输入本身就不同。本机做不到：`Engine/EngineLogprobs.swift:26` 整文件在 `#if canImport(CoreAI)` 内，SDK 26 编不出，且 `Handlers/CompletionsHandler.swift:197` 是 `includeLogits: false` ⇒ 要在 MLX 路上补一个 instrument，尚未补。
- **门**：速率本身仍不设硬门（同一输入会翻脸的判定不能当门）；leg 4「塌掉的一轮必须留痕」继续硬着。

**10-22(11) 一晚上死掉两个机制解释：温度门控、以及「干净启动安全」；据前者写完的 min_tokens 判红后整块删除**(P0 正确性 / P0 诚实口径 / P3 判定诚实)

- **死法一（上一条）**：「贪心永不塌」。它来自一次扫描（0.0→0/12、0.3→5/12、0.7→7/12、1.0→6/12），据此判塌陷在采样阶段（那个位置 EOS 与正确的 `1` 竞争）。当晚同一 binary、同一模型、同一配置，greedy **6/6 塌**。
- **死法二（本条先写下的版本，30 分钟后自我证伪）**：把对照换成「进程之前有没有被跑过」——21:34 干净启动连发 6 轮 greedy **0/6 塌**，每轮 `upstreamPrompt=713 upstreamCached=0 firstTokenMs 4904–6310 ms`（真 prefill），于是把 leg 0a 立成硬门，并把 pre-82c8e9b 6/6 → 现 binary 0/6 记成 82c8e9b 的正向证据。22:0x 同 shape 再跑：**干净启动 6/6 塌**，那条硬门当场红。⇒ 「干净 vs 已 warm」不是判别位，同批的正向证据一并作废。
- **与速率无关、现在还活着的只有一条**：塌掉的一轮一定被记下来（leg 4；上一轮 8 个单 token `.eos` 轮对应 8 条 `Degenerate generation`）。速率本身跨轮扫过全区间（0/6、6/6、5–7/12），而不同 prompt 的对照照样出 197–200 token。
- **五个单变量实验全部没能移动它**：`OCOREAI_SESSION_POOL=0`、`kvCacheQuantization.enabled=false`、`wiredMemory.enabled=false`、`temperature=0`、boot 顺序。加上两条机制解释死亡，本条能写的诚实结论只到这里：**同一进程里重复同一条 prompt 会按未知速率塌陷，塌的位置在 prefill/cache 层**；再往前一句都是猜。
- **缺的仪器还是那一句**：每轮「这次 forward 到底 prefill 了没、复用了多少行」的显式信号。`GenerateCompletionInfo.promptTokenCount` 是**喂进去**的 token 数（`bb0d5b048 Evaluate.swift:1753`），而 `cachedPromptTokenCount` 在 713 token 的 prompt 只花 ~200 ms 的轮次上仍报 0——在这种读数下任何机制解释都能被「猜」出来，这正是两条解释都写得出来的原因。上游不给，就不臆修、不宣称已修。
- **按死法一写完的修复判红即删**：`min_tokens` 当时已全线打通——chat 与 completions 两面解码、`SamplingDomain` 域检查（0 ≤ min ≤ max_tokens，文案照 vllm `vllm/sampling_params.py:697-705`）、`LogitProcessor` 走上游 `GenerationComponents.appendingLogitProcessor`（std 与 MTP 两个组装点）、9 条边界单测。真机 12 轮 `min_tokens=8`：**9 轮仍返回 1 token**，且引擎日志里 `min_tokens` 出现 **0 次**=值没走到采样器。前提被证伪 + 投递不成立 ⇒ 不留一个撒谎的 wire 字段，整块回退。备用上游事实：`bb0d5b0` 的 `Libraries/` 里没有 min_tokens；vllm `vllm/sampling_params.py:339`、sglang `python/sglang/srt/sampling/sampling_params.py:141` 默认都是 0，强制点在 `vllm/v1/sample/logits_processor/builtin.py:198-202` 与 `sglang python/sglang/srt/sampling/penaltylib/min_new_tokens.py:85-90`。
- **门的调整**：leg 0a 与 leg 5 由硬断言降为 measured note——能在相同输入下翻转的检查测的是速率，不是规则；硬门只留 leg 4（塌掉的一轮绝不许沉默）。
- **今晚最硬的一条：这是 per-process 的模式，不是 per-request 的race**。15 次独立启动全部内部一致（每次 2–8 轮同一 prompt，同一进程内要么全塌要么全交付：`C×8 / C×8 / .×8 / C×8`、`C×3 ×6`、`C,C / ok,ok / ok,ok / C,C / C,C`），而模式在启动之间翻转：config snapshot hash 全部相同（`3ba909f5…`），`free=35%` 既出 COLLAPSE 也出 DELIVER，两次启动的日志逐行归一化后**没有任何实质差异**。⇒ 决定发生在进程加载期/首个请求之前，且用的状态我们今天没有任何一行日志记它。前五种单变量排除 + 两条机制解释作废，全部收敛到这一句话。
- **顺手废掉一条省事的路**：想用 `-DSWIFT_DETERMINISTIC_HASHING` 固定哈希序来验「Set/Dictionary 遍历序被当成决策」这条猜想，在本机不可用——CLT Swift 6.2 接了flag但没用，8 元素 `Set<String>` 打印两次仍不同（`bravo,delta,charlie,…` vs `bravo,delta,hotel,…`）。所以这条猜想只能靠**把每个候选决策的输入打进日志**来验，不能靠固定种子；不做假对照。
- **本条自纠**：写上面两条时我曾判定 `~/Library/Application Support/ocoreai/cache/kvcache` 是元凶（680 MB、88 个 `*.safetensors` + `.manifest.json`）。**证伪了**：把整个目录 `mv` 开走，第一次启动照样 4/4 塌；把目录放回原位，四轮连发全交付（STALE 200/200、NOVEL 43/43）。所以磁盘 KV 快照不是那个决定位，上面那句话当时说早了。
- **但它自己是一条真问题（另计，未修）**：这个目录里的快照按 `instructionsHash` + 每条 message 的 `contentHash` + `modelId` 键存（见 `…_b3-bare-none.safetensors.manifest.json`，`version: 1`），一次会话一个 `.safetensors`，**没有 TTL、没有容量上限、也没看到淘汰**——跑了两天就堆到 680 MB / 88 个文件，里面还包括别的会话留下的 `eval-*`、`sweep-*`。淘汰策略该谁定、上限多大，留人拍板；这条与塌陷无关，别混在一起。
- **今晚排除清单（都带数）**：磁盘 KV 快照（上面那条，双向证伪）；host 内存（`free=35%` 同档既出 COLLAPSE 也出 DELIVER）；固定哈希种子（flag 是 no-op）；温度（greedy 6/6 塌）；会话池（关掉仍塌）；KV 量化、wired memory（关掉仍塌）；boot 顺序（干净启动照样塌）；配置漂移（config snapshot hash 15 次启动全等）。剩下的仍然只有那句：**决定位在进程加载期，而我们没记它**。

- **下一件仪器（已命名，未实现）**：一行 load manifest——把 KV 配置解析结果、wired memory 授权、首个请求时会话池/前缀索引内容、以及任何依赖集合遍历序的选择，在模型加载时一次性打出来，再与模式对齐。对齐成功 = 找到决定位；对不齐 = 决定不在进程里，回到 per-request 假设重搜。

- **层的定位（量出来的，不是推的）**：同一进程内 `max_tokens=1`、`prompt_tokens=713`：第 1 轮 wall 7404 ms（进程内首次 prefill，冷），第 2、3 轮 wall **176 ms / 230 ms**，`firstTokenMs=125.3 / 127.3 / 169.7`。也就是说 **713 token 的 prefill 在 warm 进程里本来就只要 ~180 ms**，塌掉那轮的 130–200 ms 完全就是一次真 prefill 的耗时。**⇒ 塌陷的轮次确实前向了，模型在 `temperature=0` 下真的先出 `1` 再出 EOS**。
- **于是再收一条本条上文的话**：「那一轮没跑那 713 token 的 prefill」「模型答对了题头却没前向」——错了，来源是一个我当天没去量的物理假设（158 ms 不可能装下 713 token）。量的结果是相反的。层因此落到**采样/logits 边际**：slot 2 上 EOS 与 `2` 的边际在不同进程里被加载期绑定的数值路径（量化 KV 布局 / attention kernel / compile 路）推到不同侧，一进程内固定 ⇒ 正好解释 15/15 的 per-process 一致与跨进程的翻转。
- **连带后果，写清楚以免明天再走一遍**：`min_tokens`（EOS 地板）当时是**对着正确方向写的**，却被这条错误的「prefill 被跳过」判死刑删掉了；它真机上失败的真正原因是投喂链断了（引擎日志 `min_tokens` 0 次命中），那是 plumbing bug，不是方向错误。**该修的是 plumbing**：`ChatHandler` 里 `SamplingConfiguration` 带了 `minTokens`，但 `_runInferenceWithMessages` 读到的是 nil——需要顺着 handler→pool→`EngineHandle`→`_runInferenceWithMessages` 找谁重建了 `SamplingConfiguration` 并丢掉未知字段，修完再验「floor 生效且答案正确」，两件事都要有硬门。
- **再排除一项（顺手）**：kernel 来源也不分模式——塌与不塌的启动都记录同一句 `shader library: /Users/uingei/ocoreai/.build-clt/debug/mlx.metallib`，两条日志归一化后该行完全相同（resolver 走的是 `MetalShaderLibrary` 阶梯，`make test-clt` 记的是另一条 staged 路径 `.build-clt/out/Products/Debug/mlx.metallib`，两者不是同一个 path；不过在本轮的翻转里两侧取值一致，所以它不是判别位）。要钉死数值路径还得靠下面那行 manifest，而不是猜哪个 metallib 赢了。
- **per-process 数值路径的仪器（仍未实现，已命名）**：加载期一行 manifest——KV 布局/scheme/bits、wired 授权、compile/trace 是否启用、attention kernel 选择、首轮 `max_tokens=1` 的 `firstTokenMs`——与模式对齐。对齐成功即找到绑定位。

- 本轮语料字节：`scripts/probes/README.md` **+22 B**（corpus 144,919/144,942）。

**10-22(10) 塌陷是温度门控的：greedy 0/12，温度>0 就是 5–7/12；四个自研子系统 A/B 全部排除，只剩上游的 cache 生命周期**(P0 正确性 / P0 可靠性)

- **先把话说全**：同一台机器、同一个模型（`gemma-4-e2b-it-4bit`）、同一条 prompt（`Count from 1 to 200…`，`max_tokens=200`）、连发 16 轮串行，四组 A/B 只换一个变量：默认配置塌 **6/16**；`OCOREAI_SESSION_POOL=0`（会话池整个关掉）塌 **8/16**；`kvCacheQuantization.enabled=false`（turbo4 关）塌 **7/16**；`wiredMemory.enabled=false`（自研 wired-memory 关掉）塌 **8/16**。四组同量级 ⇒ **我们的会话池、磁盘快照、KV 量化、wired-memory 都不是原因**（A/B 用完已逐项断言还原：`turbo4=on`、`wiredMemory=on`）。
- **温度扫描把机制钉住**（每点 12 轮、每轮换 `session_id`）：`temperature=0.0 → 0/12`、`0.3 → 5/12`、`0.7 → 7/12`、`1.0 → 6/12`；`firstTokenMs` 双峰与之逐一对应（贪心那 12 轮全是 ≥1 s 的 H）。**贪心永不塌，温度>0 就塌** ⇒ 塌陷发生在**采样阶段**：那个位置上 EOS 与正确答案的 `1` 并列高分，argmax 恒取 `1`，温度采样约五成取 EOS。
- **第一次拿到塌掉那轮的内容**（此前只有 token 数）：`content='1'`——**正是这道题正确答案的第一个 token**，`tokens=1 fin=stop`，整轮 `overallMs≈158 ms`（健康轮首 token 要 4932–9507 ms）。也就是说：模型答对了题头，却没有跑那 713 token 的 prefill，而 `GenerateCompletionInfo` 仍报 `promptTokenCount=713 / cachedPromptTokenCount=0`。唯一自洽的解释是**上下文来自上一轮残留的 KV/循环状态被静默复用**，而这次复用在账面上不存在；所以既不是"没上下文"（内容对），也不是"报了缓存"（cached=0）。
- **仍未证的那一层**（不许写成结论）：残留具体在哪。排除法目前只走到「不在我们这四个子系统里」，指向 pinned `bb0d5b0` 上游的 cache 生命周期——`ChatSession` 的 cache 是不是真的随 session 一起重建。缺的仪器还是同一样：**「这一轮前向到底跑了没有、复用了多少行」的显式信号**（`cachedPromptTokenCount` 这里两头都证不了）。上游不给，就不臆修、不宣称已修。
- **门（能让它红）**：`scripts/probes/30-repeated-prompt-delivery.sh` 新增 leg 5——**贪心连发 6 轮必须 0 塌**（硬断言，不是 note）。它的价值恰恰在于能证伪本条：若哪天 greedy 也塌，EOS-first 的解释就是错的，搜索必须回到 prefill/cache 层。本条同会话真机：`8 passed / 0 failed / 7 measured / 1 known-open`（唯一的 known-open 仍是塌陷本身）；leg 4（塌掉的轮必须留 `Degenerate generation` 日志）同轮再次 PASS（1 塌 1 记）。

**10-22(9) 「客户端断开即取消」是注释里的愿望，不是事实：1.0 s 就走的客户端，那一轮照样跑满 200 token**(P1 执行链 / P0 诚实口径 / P3 判定诚实)

- **测了什么**：新探针 `scripts/probes/31-client-abort-cancellation.sh`。判据不看来料顺序，只看**被抛弃那一轮自己的收尾记录**（`StdTurn`）：客户端在 1.0 s 断开（而这台机器一次 ~700-token prefill 就要 ~4.9 s），**两条面都记到 `tokens=200 reason=.maxTokens`**——流式与非流式各一次；另一轮流式记到 `103 tokens/.eos`，同样是走了人还在算力上。也就是说：走开一分钱也不省，下一个调用者替它排队（同轮实测 `Queued for inference: +4158ms` 流式 / `+3767ms` 非流式；对照组不断开时 `+4814ms`）。这把 10-22(4) 那条「被放弃的请求持锁 ~160 s」从现象升级为**已测机制**：不是偶发拥塞，是**没人告诉生产端客户已经走了**。
- **为什么 `onTermination` 那道桥不生效**（代码在三处：`Handlers/ChatHandler.swift`、`Handlers/AnthropicMessagesHandler.swift`、`Handlers/CompletionsHandler.swift`）：桥挂的是 `AsyncStream.Continuation.onTermination`，而它只在「我们自己 `finish()`」或「消费端任务被取消」时触发。响应流归 Hummingbird 拥有：pinned `55bc9025` 的公开 `RequestContext` 里没有任何连接存活句柄（`CoreRequestContextStorage` 只有 `logger`/`endpointPath`/`parameters`），socket 的内核缓冲还吃得下几帧 SSE 时 Hummingbird 也不会因写失败而取消消费任务（日志里那条 `Waiting on child channel: CancellationError()` 出现在**整轮生成之后**）。三处注释原文都写着「client disconnect → 停 GPU」——**已按实测改成真话**（写明它只覆盖显式取消，并指回本条与探针 31）。
- **判据被自己抓包两次，这两次都记下来**：① 第一版用 `\+[0-9]+` 在日志行里找排队毫秒数，命中的其实是时间戳的时区偏移 `+0800`，于是三条腿**全绿**、连正对照都「过」了——数字来自日志格式而不是行为；② 改用排队时长当判据仍然无效，因为 10-22(6)/(8) 那个一 token 塌陷会让长轮**提前结束**，短排队既可能是「取消了」也可能是「模型第一轮就撒手」。终版只认那一轮的 `reason`/`tokens`：`cancelled` 或干脆没有收尾记录 ⇒ 真停了；`>8 tokens`（不论 `maxTokens` 还是 `eos`）⇒ 人走了还在跑，就是缺陷。
- **正对照为什么必须在**：leg 1 用一个「客户端不断开」的长轮证明这台机器能观察到一轮完整跑完（实测 attempt 1 就 `200/maxTokens`）。观察不到就把探针自己判红（`positive control failed … cannot tell cancellation from collapse`），而不是给「取消」发合格证。
- **门**：`client-abort-cancellation: 3 passed / 0 failed / 6 measured / 2 known-open`，两条 xfail-open 钉住本缺陷；将来取消真落地时这两条会 XPASS，而 `_lib.sh` 把 XPASS 记为失败 ⇒ 那次改动必须同时删掉 xfail。
- **修法留作下一条（已定方向，不臆改）**：① 请求级 wall-clock 上限（有界占用，不依赖 HB，任何失控/废弃请求都被兜住）；② 真正的断开探测：HB 这个 pin 没有管道定制入口，得走「给 SSE 生产者一个能看见消费端停滞的信号」——即 `AsyncStream` 改**有界缓冲**并观察 `yield` 返回 `.dropped`；代价是慢网络客户端可能被误杀，所以必须配「连续丢弃持续若干秒才算离开」的宽限，且默认关闭、按请求开。两者都要求先有本条这个能判真假的门。
- **文档账**：探针索引新增 31 条并**净减 3 字节**（144941 → 144938）：29 号条目的日期化叙述与头部来历各让出一段，指回本 CHANGELOG。`docs-check` 绿（`probe-index=31/31`、`doc-orphans=0`）。

**10-22(8) 塌陷与「会话身份」无关：塌掉的那一轮根本没做 prefill；同一个 prompt 连发 16 轮塌了 8 轮**(P0 正确性 / P0 诚实口径 / P3 判定诚实)

- **上一条与探针 30 原文的归因错了，这里更正**：此前写成「同一个 prompt 第二次被问到时，会话仍按匿名 key 池化」才会塌。同一台机器、同一个模型、**逐字相同的 prompt** 连发 16 轮实测：8 轮共用一个匿名 key ⇒ 塌 4 轮（`1 token/stop`，`firstTokenMs=137…257`）；紧接着 8 轮每轮换一个新 `session_id` ⇒ **也塌 4 轮**（`firstTokenMs=148…257`），而且这些轮压根没有「not reusable」日志——池里本来就没有可拒的条目。所以会话身份、池化复用、磁盘快照都不是前提条件。当天更早那次「换 session_id 六连全好」是**小样本误读**，不是对照组，在此撤回，而不是留着和新数字互相打脸。
- **真正站得住的是时间上的双峰**（这也是下一步可用的判据）：健康轮 `firstTokenMs=4927…8020`（713 token 的真 prefill）、`tokens=200`、`reason=maxTokens`；塌掉轮 `firstTokenMs=137…257`、`tokens=1`、`reason=eos`，**但上游 `GenerateCompletionInfo.promptTokenCount` 照样报 713**。也就是说：那一轮从未把 prompt 交给模型，却按「带一个 token 的成功」出了货。内存不是原因（117 GB 与 122 GB 两档都有塌）。根因仍**未定位**；它缺的仪器很具体：**上游需要给出「prefill 是否真的发生」的信号**（现在只有 `cachedPromptTokenCount`，本轮为 0，既不能证明做了也不能证明没做）。在这之前不许把任何猜测写成结论。
- **但有一条不该等根因：塌掉的轮不该继续装作成功**（invariant 2）。新增判决 `Sources/ocoreai/Engine/DegenerateTurn.swift`：`tokens<=1` 且 `reason==.eos` 且预算 >1 token ⇒ 判为退化轮；`Sources/ocoreai/Engine/EngineInference.swift` 在标准路收尾处 `log.error("Degenerate generation for …")`，并把能让人自己判断 prefill 与否的两个数字（`firstTokenMs`、`promptTokens`）原样带进日志——判决只说形状，不冒充根因。为什么用 `.eos` 卡：`maxTokens` 说明跑满了预算，`stopSequence` 是调用方自己的停止串，`cancelled`/`error` 本来就吵。为什么 `max_tokens>1` 才卡：叫 1 个 token 却拿到 1 个 token 是如约交付，`finish_reason:length` 已经说明。
- **门**：`DegenerateTurnTests`(9)（实测两形态各钉一条；边界 0/1 命中、2 不命中；四种非 eos 全排除；遍历 4×6×4 并断言 `checked == 96`、`hits == 6`，防遍历自己缩水）⇒ `swift test --filter DegenerateTurn` 9/9 绿；`swift build` RC=0。探针 30 新增 leg 4：直接从引擎日志取 `StdTurn … tokens=1 reason=.eos` 的条数与 `Degenerate generation` 的条数比对，**少一条就红**，无论本轮塌不塌。本条同会话真机输出：3 个一轮塌 ⇒ 3 条 Degenerate 日志，`4 passed / 0 failed / 9 measured / 1 known-open`（唯一的 known-open 就是塌陷本身，不许在它变绿之前宣称修好）。探针 30 头部一并更正，两条 xfail 的理由从「会话身份碰撞」换成「塌掉的轮未做 prefill」。
- **从 vllm/sglang 核过、并且决定不抄的那件事**：退化生成的行业缓解是**下限**。vllm `min_tokens`（OpenAI chat 面 `vllm/vllm/entrypoints/openai/chat_completion/protocol.py:287` ⇒ `SamplingParams` `:784`；`vllm/vllm/sampling_params.py:339`；执行在两处——logits 侧 `vllm/vllm/v1/sample/logits_processor/builtin.py:198-202` 屏蔽 stop 集，调度侧 `vllm/vllm/v1/core/sched/utils.py:122-127` 判「未完成」，且那里明确注释「检查顺序对 min_tokens 很重要」；`is_argmax_invariant()==False` 说明它会改变贪心结果，不能进那条快路）；sglang `min_new_tokens`（`python/sglang/srt/sampling/sampling_params.py:141`，OpenAI 面的 `min_tokens` 在 `entrypoints/openai/protocol.py:385` 映射成 `min_new_tokens` `:1157`；执行 `sampling/penaltylib/min_new_tokens.py:85-90`——用 `torch.where` 而非布尔索引以免每步同步、并避开 `-inf*0=nan`；屏蔽的是 `stop ∪ eos ∪ additional_stop` 的并集，不止 eos；且 `skip_tokenizer_init=True` 时**直接拒绝这个旋钮**而不是静默忽略）。上游 `mlx-swift-lm` 在我们钉的 `bb0d5b0` **没有任何 minTokens**（全 `Libraries/` 零命中），要走得自己接 `GenerationComponents.logitProcessorFactory`（`GenerationComponents.swift:43/:112/:132`，每轮新建实例以免状态串门）。**我们决定现在不接**：证据显示塌掉的轮**没做 prefill**，此时强行压住 EOS，模型会在「从未见过这道题」的状态上继续吐字——把一个看得见的一 token 失败，换成一段自信的胡说。这正是本仓库不收的那类缓解。留作根因关闭后的候选（届时要连 `min_tokens` 的 wire 校验一起接进 `SamplingDomain`，并按 sglang 那条口径：量不到就拒，不许静默）。

**10-22(7) 复用规则补上「前缀覆盖」前提：缓存必须真是喂给内容的前缀，且喂完还得有东西可答**(P1 上下文与状态管理 / P0 诚实口径)

- **规则缺的那半个前提**：`canReusePooledSession` 过去只问「缓存历史是不是来料历史的前缀」，没问「前缀之外还剩什么」。缓存若已覆盖整份来料（`commonPrefixCount >= incomingMessageCount`）而最后一条又不是 assistant，喂给上游的就是**空 feed**——空 feed 让模型立刻吐 end-of-turn，请求却按成功出货。判决现在多一个前提：`commonPrefixCount < incomingMessageCount || newestIncomingFromAssistant`。后半句是合法形态的钉子：喂到 assistant 草稿末尾就是「接着写」，那时什么都不喂正是重点。
- **一处判决一个家 + 调用方兜底**：新拒绝理由 `cacheCoversWholeFeed` 落 `Sources/ocoreai/Engine/ReuseRefusalLedger.swift`（快照词汇 6→7），任何别的 divergence-index producer 给出「覆盖全量且非 assistant 结尾」时，`Sources/ocoreai/Engine/EngineInference.swift` 一律整段重新 prefill 并 `log.error("Feed would be empty for …")`，不静默吞。同一条日志把 `Pool reuse` 从 debug 提到 info：「喂进去的被去重了」正是 truncated answer 唯一能赖以成立的前提，出事那一刻读不到的解释不算解释。
- **门**：`ReuseRefusalLedgerTests`（遍历 320 组合并断言 `checked == 320`；`wholeFeedCoverageRefused`；快照词汇 `count == 7`）+ `SessionIsolationTests`（含 trailing-assistant 必须放行的反向钉）+ `SessionRewindOnDivergenceTests`。本条同会话输出：`swift build` RC=0；`swift test --filter "Session|Reuse|Prefix|EngineBusy"` ⇒ 164 tests / 47 suites 全绿。
- **不宣称修好了上一条的塌陷**：塌掉那轮实测 `fed=1 of 1 divergence=0`——feed 非空，本条规则碰不到它。它做到的只有一件事：把「空 feed」从「可能的原因」变成「代码不允许存在的原因」。塌陷的嫌疑因此收窄到一处：**temperature>0 时第一个 token 就采到 EOS 的退化生成**（上游自己报 `generationTokenCount=1 stopReason=.eos`，而我们把它当普通成功出货）。处理方式按竞品的既有做法，见下一条。

**10-22(6) 排队是真的，429 还没走到线上；顺手抓到一个更狠的：同一个 prompt 第二次被问到只回一个 token**(P1 执行链 / P0 正确性 / P3 判定诚实)

- **排队落地并实测到了**：`LoadedModel.acquireInference(waiting:)`（`Sources/ocoreai/Engine/LoadedModel.swift:541`，50 ms 轮询、从不睡到 deadline、取消即返回 false）取代 fail-fast CAS；两条面共用同一家的日志与判决（`Sources/ocoreai/Engine/EngineBusySignal.swift`）。真机量到的排队：`+164 / +220 / +483 / +3465 / +3483 / +5098 / +9993 ms`，最长那次排队之后照样 200 + 400 tokens。单测 `EngineBusyAdmissionTests`(5) 钉住：唤醒在 ~120 ms 而不是 deadline、`OCOREAI_ENGINE_BUSY_WAIT=0` 立即拒、`engineBusy→429` vs `generationError→500`、钳位表 `(0,3,999→120,-4,soon→20)`、以及 `EngineInference.swift` 里不许再出现字面量 `"Engine busy"`。
- **但 429 到 wire 仍未验到**（探针 29 四条 429 腿仍红，`6 passed / 4 failed`）。原因不是没接线，是**构造不出「长轮正在生成 + 第二个请求同时到锁前」**：锁在管线后段（prompt 组装之后）才拿，**HTTP 的到达顺序不是拿锁顺序**，0.4 s 后发的短请求会先过锁并正常出货。已把 leg1 的前提改成「等长轮吐出第一个 SSE token 再发第二个请求」，改完仍是 200。今天真正观测到的占用只有一种：**被放弃的请求持锁 ~160 s**（10-22(4) 那条时间线），不是普通并发。所以口径钉死：排队=实测；429=接线与单测就绪、wire 未证。
- **更正竞品引用**（10-22(4) 原文有误）：逐条读来的事实是 sglang 用 **503 `overloaded_error`**（`python/sglang/srt/entrypoints/http_server.py:595`，另 714/730/796），**vllm 没有饱和 429**（429 只出现在客户端多模态取资源的瞬时重试分类：`vllm/multimodal/media/connector.py:84,97`）；两者都排队/批处理，不把容量导出成每请求错误码。我们仍选 429 + `Retry-After`，但理由换成真的：一引擎一进程、等待有界、必须告诉客户端何时回来（RFC 9110 §10.2.3）。
- **新开的 P0/P1（证据齐、未修）**：**同一个 prompt 第二次被问到，那一轮返回 200 + 1 token + `finish_reason: stop`**。同机同模型（`gemma-4-e2b-it-4bit`）实测形态：**并发同 prompt（间隔 0.3 s）五轮分别塌掉 1、1、1、2、1 条**（15:17、15:43、16:07、16:12、16:20——其中一轮两条全塌，都只回 1 token 还报 `stop`）；**串行、零重叠** 复现 1 次（16:08：第一次 150、第二次 1），再跑一次同一形态两轮都 150 ⇒ **这是竞态，不是必现**，别再把它写成确定性复现；不同 prompt（并发或串行）**从不塌**（`200/200`、`150/96`、`26/78`、`109/86`）。塌掉那一轮的日志只有一句 `Session pool entry … not reusable: cached history 2 exceeds common prefix 1 — building a clean session`，并且它在被派发的那一秒内就结束了——708 token 的 prefill 根本没发生：**轮次还没开始就说了 `stop`**。
- **为什么这事比看起来大**：匿名会话键由首条 user 消息派生，所以 agent 逐字重试同一个问题、GUI 重发、两个窗口问同一件事，全都落在这条路上，而它们拿到的是「一个 token 的成功」。
- **已经排除的（别重走）**：不是空 prompt——miss 返回 `divergenceIndex: 0`（`Sources/ocoreai/Engine/SessionPool.swift` clean-session 那条 return），调用方喂的是完整历史；不是磁盘快照——拒绝复用时 `deleteCachedSession` 已删，日志里没有任何 restore；不是机器饱和或内存压力——同期不同 prompt 全部正常出货。剩下的嫌疑集中在一处缝：**同一 convKey 的上一轮刚 release，这一轮立刻重建 clean session**。
- **门**：新增探针 30 `scripts/probes/30-repeated-prompt-delivery.sh`（串行重复 + 并发同 prompt + 不同 prompt 对照；前提腿必须有排队行、对照必须出货，否则不算数），当前 `XFAIL open` 并带真实数字；探针 29 改以第一个 SSE token 作为「长轮在跑」的前提。`swift build` RC=0、`EngineBusyAdmissionTests` 5/5 绿。

**10-22(5) `replace_all` 把那道题救回来了：0/3 → 3/3；总分仍在噪声里，两件事要分开说**(P1 工具调用 / P3 判定诚实)

- **目标任务确定被修好**（`k=3` × 24，`/tmp/eval-24-k3-replaceall`，三轮全部有效、无 fault）：`edit-replace-all` **0/3 → 3/3**，verifier 查的是 workspace（3 个 BAR、0 个 FOO），不是模型自述；三轮延迟 1450/1451/2151 ms，回答统一是 "Changed notes.md."——不再问用户。**换名字比换措辞有效**：`occurrences` 要模型现场数数（上一轮它读到计数仍去问人），`replace_all` 是它在训练数据里见过的现成意图表达，不需要算术。
- **但总分没动，而且不许把两件事混着说**：A=`16/19/20` → B=`17/19/18`，mean **18.33 → 18.00（−0.33）**，配对 b=21 c=18 **p=0.749 不显著**。搬动的任务：`edit-replace-all 0/3→3/3`、`change-config-value 0/3→2/3`、`fix-syntax-error 2/3→3/3`（+7）对上 `fix-off-by-one 2/3→0/3`、`move-into-subdir 2/3→0/3`、`make-failing-test-pass 1/3→0/3`、`exec-count-lines 3/3→2/3`、`fix-typo-variable 3/3→2/3`（−5）。**记分板的分辨率是 ±4.2 题，修好一道题本来就看不见**——所以这条的结论限定在「目标失败模式消失」，不写「整体变强」。统计口径提醒：|A|×|B| 配对里同一任务的 9 个 pair 高度相关，单题 pooled 的 p 会偏乐观，报数时以「3/3 对 0/3 + verifier 查 workspace + 延迟一致」为准。
- **回归检查**：`replace_all` 只碰 edit_file 一处语义，同族 `edit-remove-line` 仍 3/3 稳定，没看到它对别的编辑任务的连带伤害；变差的那四个（`fix-off-by-one`、`move-into-subdir`、`make-failing-test-pass`、`fix-typo-variable`）全在基线就记名的抖动集合里。下一个 P1 因此很具体：**多步修复 + 长生成**——`fix-off-by-one` 基线 2/3、上一轮直接触发引擎占用（13 题 4 秒全拒），这一轮 0/3；它同时也是 `Engine busy` 那把锁的触发器（`Sources/ocoreai/Engine/LoadedModel.swift:528` fail-fast CAS、无排队、客户端断开不取消 ⇒ HTTP 500；容量应是 429+`Retry-After`（竞品实际怎么报，见 10-22(6) 对本条引用的更正））。
- **门**：`EditMismatchRecoveryTests`(6)（措辞、`replaceAll` 行为、零命中不许假 OK、`{"replace_all": true}` 走 registry 全链路、裁切提示报总数）+ `FileToolsTests` schema；`swift build --build-tests` 139 s；46 tests / 6 suites 绿；`make audit` AUDIT_OK、`docs-check` 通过、`anchor-check` 174/174、`format-check` 零改动。

**10-22(4) 记分板自己造了一次「显著回归」：那是停机，不是模型**(P0 测量完整性 / P1 工具调用 / P1 可靠性)

- **上一轮那句「配对战还没跑完」现在有答案，而且不好听**：`occurrences: 3` 提示**没救回目标任务**——`edit-replace-all` 有效轮仍是 **0/2**。模型的最终回答逐字是：*"I failed to replace all occurrences because the tool requires an exact match count. Please specify how many occurrences you intended to replace."* 它读到了计数，然后**去问用户**，而不是自己重试。工具把话说清楚 ≠ 模型会行动：这就是 生成内容 与 可靠行动 之间那道缝。
- **记分板把停机当成了分数**（`scripts/eval/run.sh`、`scripts/eval/_repeat_stats.py`）：after2 的 run-3 里 **13 个连续任务在 4 秒内全部返回 `{"error":{"message":"Generation failed: Engine busy","code":500}}`**（`finish=None`、68 ms、usage 全空），该轮被打成 7/23，而 `repeat.sh` 照样把它平均进去，McNemar 于是报出 **p=0.0032 的「显著回归」**——一次引擎占用被写成模型能力下降。改法一句话：**没送达引擎的任务不是模型失败**。`run.sh` 统计 `finish=None`/`Engine busy`/`app_error` 行数，落 `faults.txt`，在 `results.tsv` 写 `# invalid faults=N`，整轮以 **NOT MEASURED** + exit 1 收；`_repeat_stats.py` 拒绝把 invalid 轮平均进趋势（剔除动作打印到 stderr，要求与数字一起引用），旧数据无标记则按 `finish=None` 追溯判定——对 `/tmp/eval-24-k3-after2` 实测剔除 run-3（13 题未送达），只剩 2 轮。
- **剔除后的诚实数字**：A=`16/19/20` → B=`20/20`，mean **18.33 → 20.00（+1.67 题）**，名义 McNemar b=4 c=14 **p=0.031**；但 B 只剩 2 个有效轮、|A|×|B| 配对彼此强相关，单轮 CI 仍 **±3.6 题**，**低于本仓库自己的「≥6 个任务」判据 ⇒ 记为「有希望、未确认」**，不进能力表述。搬动的任务里没有那目标任务：`change-config-value 0/3→2/2`（同族编辑吃到措辞红利），`edit-replace-all 0/3→0/2`（没吃到）。
- **于是换一根更朴素的杠杆**（`Sources/ocoreai/Tools/FileTools.swift`、`Sources/ocoreai/Tools/BuiltInTools.swift`）：`occurrences` 要模型自己数数，而数错/不敢数正是失败点；新增 **`replace_all: true`**——主流 agent 工具都用这个名字，模型见过，不需要现场算术。拒绝语同时给两条路并**关上问用户那扇门**：`to replace every occurrence retry this call yourself with replace_all: true (or occurrences: 3 to be exact); do not ask the user for the count`；工具描述同步写「拒绝语报了计数就自己重试」。`replace_all` 是本工具集**唯一**一处 snake_case 线上键（其余全 camelCase），为此显式写 `CodingKeys` 并在注释里记下破例理由。门：`EditMismatchRecoveryTests`（措辞 + `replaceAll` 行为 + **`{"replace_all": true}` 走 registry 全链路**）+ `FileToolsTests` 的 schema 断言。**效果未测**——下一轮 k=3 配对才算，判据写明：`edit-replace-all` 从 0/2 到 ≥2/3。
- **顺带补齐 codex 的一条纪律**（`~/references/codex/codex-rs/core/src/tools/mod.rs:90-109`）：它截断输出时必同时公布 `Total output lines`——展示局部就要说出整体。我们 `exec_command` 早已如此（`Sources/ocoreai/Tools/ExecTools.swift:92` `[TRUNCATED N total; showing first X + last Y chars]`），但 `edit_file` 的最近行提示在 1200 字符处静默裁切，裁掉的可能正是模型要的那行。现在提示自带范围：`[lines 61-68 of 120 lines, clipped at 1200 chars — read_file for the rest]`，整文件引用时也报总行数。门：`EditMismatchRecoveryTests.clippedHintStatesTotals`。
- **新开的 P1（只有证据，不假装已修）**：**被放弃的请求会让引擎占着不放**。run-3 时间线：13:27:36 发出 `fix-off-by-one`（基线 6–14 s 的题，本轮跑到超时被 harness 放弃）⇒ 13:30:36–13:30:40 十三连请求 4 秒内全部吃 `Engine busy` ⇒ 13:31:16 自行恢复。机制两条都落到了行：① `Sources/ocoreai/Engine/LoadedModel.swift:528 tryAcquireInference()` 是非阻塞 CAS，**抢不到立刻拒**，调度层没有排队；② 该拒绝在链路上被打成 **HTTP 500 `app_error`**（本条原文当时写「vllm/sglang 在容量饱和时用 429 + `Retry-After`」——**该引用有误，已在 10-22(6) 更正**：sglang 报 503 `overloaded_error`，vllm 没有饱和 429），且客户端断开**不取消**在跑的那轮，废弃工作继续占锁 ~160 s。GUI 同样吃到：一次生成未完再发一条就是「Engine busy」。修法有界（限时等待 + 429/`Retry-After` + 断开即取消），但必须真机验证，留作下一条。
- **修自己上一轮留下的账**：`CHANGELOG.md` 里 `[Unreleased]` 标题被 10-22(3) 的插入脚本重复了一次，已去重（同一个「插入时自带标题」的低级错误，两个标题会让任何按首行定位的工具读错）。

**10-22(3) 门本身在撒谎：并行时测试互相污染，一个 force-unwrap 让整条 CI 静默；同一轮把「写成功≠写对」接上，但记分板测出 Δ0.00**(P3 回归防护失效 / P1 工具调用 / P3 判定诚实)

- **症状（本机 CLT 实测，不是推断）**：`.serialized` 只串行化本 suite，**不隔离 suite 之间**。把改共享状态的 suite 放一起跑，`EditMismatch|SessionWorkspace|WorkspacePathAnchor` **3/3 全红**，而且每轮受害者不同——一个 suite 把 `calc.py` 解析到另一个 suite 的 temp 目录里，`effectiveCwd` 读到别人的 `OCOREAI_WORKSPACE`。再加 `ModelStore|CoreAIModelIdRoutingGate` 直接 **signal 5**：别人的 `OCOREAI_MODELS_DIR` 让 `localCoreAIModelDir` 返回 nil，`resolvedRoot!` 把测试进程 SIGTRAP，**排在它后面的每个 suite 一条结果都不出**——比红更糟，因为它看起来像"这次跑的题目少"。
- **改法（一个家，落在缝上）**：`Tests/ocoreaiTests/ProcessGlobalLease.swift`——凡改 `SessionWorkspace` 活动目录、`OCOREAI_WORKSPACE`、`OCOREAI_MODELS_DIR` 的测试先取租约、`defer` 归还，归还时清掉自己钉住的全局；nil 那条改成 `Issue.record` + `return`（失败就该是失败，不该是崩溃）。共 20 处测试上锁。**改前 3/3 红 + 崩，改后 56 tests / 10 suites 连续 3 轮全绿。**
- **为什么这条比看起来重要**：`SessionWorkspace` 是 `NSLock` 保护的**进程级**单例，生产语义没得挑（一个进程一个活跃会话）；错的是测试把它当成 per-test 作用域用。这正是 invariant 1 点名的形状——门从环境里长出前提，只不过这次环境是**同时跑的其他测试**。
- **「写成功」和「写对」是两件事**（`Sources/ocoreai/Tools/PostWriteSyntax.swift`，新）：`write_file`/`edit_file` 的 `OK` 原本只证明落盘+读回，不证明产物有效。现在同一个结果里带判决：`.json` 用 `JSONSerialization`、`.plist` 用 `PropertyListSerialization`、`.py` 用 `python3 -m py_compile`（5 s 上限，**只编译不执行**；`/usr/bin/python3` 在没有 CLT/Xcode 的机器上会弹装工具链的模态框，故显式拒绝），无效时结果写成 `OK-but-invalid` 并附上编译器自己的话。`edit_file` 的拒绝同时说出下一步：`count == 0` ⇒ "read_file 它并原样复制"，`count > 期望` ⇒ **"要替换全部 3 处就传 occurrences: 3"**（实测 `edit-replace-all` 0/3 就是因为模型要的正是工具支持的操作，而拒绝只报了数字没说键名）。门：`PostWriteSyntaxTests`(7) + `EditMismatchRecoveryTests`。
- **诚实记录：这个改动在记分板上是 0**（k=3 × 24 题，`/tmp/eval-24-k3-after` vs `/tmp/eval-24-k3`）：`17/20/18`，mean **18.33 → 18.33，Δ0.00**；配对 McNemar **b=8, c=8, p=1.0**；**逐任务通过向量完全相同**。两条可能的传导断点都查了、都排除：引擎侧不截断 tool result（`EngineInference.swift:2961-3022` 原样回喂），`ToolError` 是 `LocalizedError` 且 `errorDescription` 带完整 detail ⇒ 文字确实进得了模型。结构性解释：**判决只在"写成功"之后出现，而丢分任务全死在写之前**（`change-config-value / copy-with-suffix / edit-replace-all / make-two-tests-pass` 四个 alwaysFail 都在 refusal 阶段退出）。⇒ 保留它，但保留理由是 invariant 2（不许把无效产物报成成功，成本 70 行 + 一道门），**不是**"它提升了成功率"；真正有空间的杠杆是 refusal 的下一步提示，那个的配对复跑还没跑完，跑完再判。
- **门与账**：`make docs-check` 通过（root 30,133/30,138、corpus 143,577/143,578、walls 0、probe-index 28/28、claims 30/30、suites 43）；`xcrun swift-format` 对 10 个改动文件零改动。**本轮没动 AGENTS.md 的 Testing Quality**（root 只剩 5 字符预算）：隔离规则暂落在 `ProcessGlobalLease.swift` 的头部注释（就在缝上）+ 本条；等 root 腾出预算再收进 Testing Quality。
- **仍未决（不假装）**：① `occurrences` 提示的配对评测（`_repeat_stats.py --a /tmp/eval-24-k3 --b <new>`）未跑完，不许提前写成功；② `HF_ENDPOINT` 只有 `SettingsStoreHFMirrorTests` 自己碰（已 save/restore）⇒ 暂无跨 suite 冲突，但那是"目前只有一个使用者"，不是"设计安全"；③ 租约是一把全局锁，代价是这几组测试串行（实测总增量 <1 s），如果将来 contending 集合变大变慢，再按全局分锁。

**10-22(2) 记分板 9→24，第一次有噪声底：16/19/20 ⇒ 任何小于 6 个任务的「改进」都不许算**(P3 判定与回归防护 / P1 执行链 / P0 可靠性)

- **裁判先自检**（`scripts/eval/_verifier_selftest.py`，24/24 zero defect）：每个任务的 `verify` 必须(a) 真做完→过、(b) 原样不动→不过、(c) 编造答案→不过。它当场抓出 **3 个 vacuous 验证器**——`case "$ANSWER" in *"$OCOREAI_EVAL_EXPECT"*)` 在 `EXPECT` 为空时等于 `*""*`，匹配任何回答。修法：验证器首行 `[ -n "${OCOREAI_EVAL_EXPECT:-}" ] || exit 1`，且 `run.sh` 在启服务之前先跑自测（一个不能失败的裁判不配打分）。顺带：期望值改由任务的 `expect_cmd` 字段给出，`run.sh` 不再为某个 id 开特例。
- **任务集 9→24**（8 族，最小族 2：write/edit/code-fix/tests/read/exec/multi-step/honesty），`_eval.py families` + 族地板让「某一族整体消失」也会红；`results.tsv` 落盘（task/kind/rc/elapsed/usage）供聚合，`_repeat_stats.py` 输出 `noise.json`。
- **噪声底（同配置 3 轮实测，gemma-4-e2b-it-4bit）**：`16 / 19 / 20`，mean **18.33/24 (76.4%)**，SD 2.08 ⇒ 单轮 95% CI **±4.1 个任务（±17 pp）**，单轮 A/B 要判改进至少 **≥6 个任务**；配对 McNemar（本轮 8 个 discordant 对）同样落在 6。**稳定通过 16 / 稳定失败 4 / 抖动 4**：`fix-off-by-one`、`fix-syntax-error`、`make-failing-test-pass`、`move-into-subdir`。⇒ 损失集中在**多步修复**，不在工具管线（write/read/exec/honesty 全稳）；下一步 P1 就打这四个。规矩：低于阈值的差异不写进 CHANGELOG，只记 trace。
- **P0 可靠性：拒绝启动的 daemon 必须走人**（`Sources/ocoreai/Headless/HeadlessServer.swift`）——实测锁被占时 `serve` 打印 `refusing to start a second engine` + `lifecycle: error` 后继续活着等信号，调用方白等 **237 s**（`scripts/eval/run.sh` 就是这么烧掉的）。改成 `.error` 即非零退出：**1 s、code 1**，消息自带持有者 pid 与 `OCOREAI_ALLOW_MULTI_INSTANCE`。`_lib.sh` 另加终端态扫描（进程活着但已宣布不服务时，1 s 出诊断）。门：`scripts/probes/28-single-instance-refusal.sh`（实测 `6 passed, 0 failed, 6 measured`）+ 两处静态地板。
- **GUI 变成门而不是段子**：`scripts/verify-gui-window.sh` 删掉永远只 warn 的 traffic-light 断言（AppKit 标题按钮子窗口无人值守不可枚举，owned 实测 0 条；像素带变体试过、只找到 3 个圆点里的 1 个，已弃）——换成**渲染地板**：截图不同颜色数 ≥64（实测 **846**，窗口 `900x472`，PNG 140 KB）。CI `release` job 新增 GUI proof + 窗口 PNG artifact，**不装模型**（1.5 GB 下载不许卡发布），模型依赖的那半留在 `scripts/e2e-gui-app.sh`。AGENTS.md 里「SwiftUI 路径 gated statically only」这句已过期，改为实测范围 + 细节落 `Sources/ocoreai/UI/AGENTS.md`（桥接是 opt-in、App Store 构建不服务、Accessibility 控件自动化未验证）。
- **同一天两处「裁判的前提不能由被审对象提供」**：`apple.pin` 不再被本地 mirror 的 HEAD 改写（`f0978e4`），本轮又发现记分板的期望值能让验证器无条件通过——同一个形状，两次都要堵。
- **竞品 LM Studio Bionic**（vendor docs 10-22，**未本机安装 ⇒ 全部标注为厂商自述、我们未实测**）：定位与我们几乎重合（"the AI agent designed for open models"、projects→sessions、skills、voice input、local/cloud-zero-retention/remote 三档放置、把低层配置留给另一个 app）。它宣传 **"Run multiple sessions across projects to parallelize your workflows"**，正打在我们的单实例锁上（今天实测：第二个引擎直接被拒）⇒ 并发是**调度/批处理**问题（每轮固定开销 + 单模型驻留），不是多开会话；此条记为待办，**不许**写成能力。
- **门**：`make docs-check`（corpus 记账后 143,578/143,578、probe-index 28/28、root 30,107/30,138）、`make anchor-check`（43 锚点 + bare cites 173/173）、`make audit`、`make format-check`；`swift build --scratch-path .build-clt` 140 s 通过。

**10-22 自进化第一块前置件：provenance 不许被环境偷偷改写**(P0 判定前提被污染 / P0 文档与代码一致)

- **症状**：上一轮跑 `scripts/collect-third-party-licenses.sh` 后 `THIRD-PARTY-LICENSES/manifest.json` 的 `apple.pin` 从 `09e7125768` 变成 `675437b84e`，而分发物一个字节都没变。根因在脚本 `apple_pin = head`：本机 `~/references/coreai-models` mirror 往前走了，pin 就跟着走。违反 AGENTS.md「mirror ≠ HEAD」，也正是 invariant 1 点名的形状——门自己从环境里长出前提。
- **改法**：pin 是**审计基准**，不是 mirror HEAD。校验现在跑 `git show <recorded pin>:LICENSE`（问的才是这条断言真正关于的那棵树），target 取 manifest 里已提交的 pin；mirror 走前了只打一行 `drift:`，pin 不动；重钉是显式动作 `OCOREAI_REPIN_APPLE=<sha>`，前提是先审 delta。该 pin 在本机取不到时 `verifiedAgainstPin` 记 `null`——"没查"不许塌成"查过且不匹配"。
- **实测**：`bash scripts/collect-third-party-licenses.sh` ⇒ `apple_pin=09e7125768fc09276ba3ca3524f2f05007255866 byte_identical_at_pin=True` + `drift: mirror HEAD 675437b84e2f != recorded pin 09e7125768fc …`，跑完 `git status` 对 `manifest.json` 零改动（先前必改）。门：`ThirdPartyNoticesTests`(16) 断言 pin 40 位且 `verifiedAgainstPin == true`；`make audit` Class-I 与 `git show <pin>:LICENSE` 逐字节比（clone 缺席打 loud SKIP）。本轮复跑：`make docs-check` 30/30、`make anchor-check` 43 anchors drift=0 + bare cites 173/173、`docs-type-existence` unresolved=0、audit 全绿。
- **为什么这是 RSI 的前置件**：自进化系统的第一个断点不在模型，而在「判真假的那台机器会不会被它改进的对象偷偷改掉」。这个锚点不漂移之前，任何自动闭环都只是把污染传下去。
- **顺带（文字进出）**：`docs/agent/third-party-notices.md` 改正 `apple.pin` 语义，并删掉与「Absent ≠ empty」/Gates 两条重复的句子——corpus 142,550 → **142,434 B**（cap 不动，walls 0）。
- **仍未决（不假装）**：GUI 端到端只在本机证过一次（`build/ocoreai.app` + `OCOREAI_ENABLE_HTTP=1` 起 HTTP + 一次真回复 + 窗口 900x472 / 截图 131 KB），CI 还没跑它，而 AGENTS.md 仍写着 SwiftUI 路径 "gated statically only"——该句已过期；`scripts/verify-gui-window.sh` 的 traffic-light 检查无人值守时永远只 warn（AppKit 标题按钮子窗口不可枚举，实测 owned 条目 0），只响不判定的门要删不是要解释。

**10-22 openclaw 读完了：116,620 commits 的迭代次序把「贵在哪」第二次证明了一遍，顺手删掉自家烂了三年的 ARCHITECTURE.md**(P0 上游偏离 / P0 文档与代码不一致)

- **它的形状**（`~/references/openclaw`，10-22 clone，HEAD `6007ce78dc8`，跨度 2025-11-24→2026-10-21）：TypeScript 47,428 文件 + **1,591 个 Swift**，`apps/{macos,ios,linux,android,macos-mlx-tts,swabble,shared}`，`packages/{agent-core,gateway-client,gateway-protocol,llm-core,net-policy,memory-host-sdk,model-catalog-core,...}` —— 这套集合里唯一同时是「原生 Apple App」的竞品，agent loop 在 gateway 协议后面，GUI 是客户端。
- **轴次序 + churn 代理**（`scripts/competitor-path-scan.sh openclaw`，只读 git log subject；关键词族在 116k commits 尺度上偏宽，只用于排序不用于绝对数）：hooks 2025-11-24 later=1150/fixes=589、approvals 11-25 1254/688、cache 复用族 11-26 1195/591、mcp 11-27 757/441、resume 12-03 28/24、notify 12-06 267/145、compact 12-10 87/61、image input 12-14 259/172、skills 12-19 **1615/766**、mid-turn steer 12-20 230/169、memory 12-23 **2695/1505**、review 01-03 388/265、sandbox 01-03 823/426、background 01-05 41/26、subagents 01-06 **1138/671**、checkpoint 01-15 124/74、structured output 01-16 15/7、parallel tools 03-07 5/3、plan mode 03-23 **3/0**。
- **与 codex 同族、快一倍**：权限与状态家族（approvals/sandbox/mcp/memory/skills/subagents/hooks）第一周就到位且 churn 最重；行为轴便宜得多（resume 28/24、compact 87/61、parallel 5/3）；**plan mode 全程只有 3 条提交、0 修复**。⇒ 第二次独立证据：让 agent「真把活干完」的不是 plan mode，是权限层 + 记忆/技能/子代理的可靠性。
- **端侧神经 TTS 是我们真正的缺口**：openclaw 把 MLX 音频隔离成独立包 + 独立 helper 可执行体 `apps/macos-mlx-tts`（`exact mlx-audio-swift 0.1.5`、macOS 15 floor、`generateStream(...) -> AsyncThrowingStream<[Float], Error>`、`voice`/`referenceAudioPath`、`CachedModel{repo, model}` actor），并在自己的 Package.swift 里写明隔离理由："so normal macOS app tests do not compile the full MLX audio stack"。我们的 `tts_speech` 行是诚实的（`AVSpeechSynthesizer` + 个人语音，发音人数在 `POST /v1/multimodal/status` 实测），但**诚实且弱仍是弱**；补它的代价是 MLX 音频进构建图，与 AGENTS.md 的 "One binary" 身份行冲突——该拿这个冲突去拍板，而不是拿去写依赖。
- **CJK 计数两家同病**：openclaw `fix(memory): account for CJK characters in QMD memory chunking`；我们同一道算术仍未决（`Models/TokenEstimate.swift`，gemma 中文 /3 实测高 44–56%）⇒ 按模型量 bytes/token 不再是「锦上添花」。compat 侧又拿到两条独立佐证：`gate parallel_tool_calls to compatible APIs (#39356)`、`raw call to anthropic compatible apis (#21336)` —— 已由 `ToolCallWireContractTests`+`AnthropicToolDeliveryTests` 钉住的两条，不许按 provider 放松。
- **不把它加进 HEAD drift 轴**（`scripts/upstream-drift.sh` 仍是三轴）：一天几百条 commit，HEAD 窗口=永久噪声，而「每次都响的警告在真出事时没人看」。该加的是 release-tag 轴（它发布 Sparkle `appcast.xml`），轴形态改动留 owner 拍板。
- **顺手把自己文档里最烂的一块删了**：`ARCHITECTURE.md` 是 2026-07-26 的评审快照，烂到自相矛盾还留在导航位——图里画着 `BackendProtocol.swift`（`2123143` 早已删）、全部行号失真（写的 `EngineInference.swift` 1,387 行，真实 **5,044**；`EnginePool` 740→**1,723**；`LoadedModel` 338→**717**；`CoreAIBridge` 247→**41**），§5 已记「CoreAI 原生语法存在」、§7 却仍建议 `supportsGrammar: false` 的能力矩阵，§6 的 L269/L547 一类行号早已不是那行。删 15,840 B，换成 4,951 B 的生命地图（所有权 + 不变量落点 + superseded 清单），原文 `git show 4e36755:ARCHITECTURE.md` 可取回。
- **新门 `scripts/docs-type-existence.sh`（挂进 `make audit`）**：架构文档里反引号点名的类型必须存在（Sources/ 或主 clone）；写在「removed/deleted/superseded」行上的死亡记录放行但如实计数 `historical`；floor 8 防正则失效。首跑 distinct=14 scanned=21 local=16 upstream=1 historical=4 unresolved=0。corpus cap 收到 **142550**（低于本轮开始前的 152041：openclaw 结论 +1,763 B 由这次删除支付，ratchet 因此收紧而不是放宽）。

**10-22 竞品的迭代次序 + 自家引用层一起结账：贵的一直是权限层，而我们自己的 upstream 引用有 4 条已经指错**(P0 上游偏离 / P3 回归防护) — 「持续研究 references」这句话第一次有了可复跑的口径：`scripts/competitor-path-scan.sh` 只读 `~/references` 的 `git log` subject（不联网），每条轴给出最老命中日期 + `later=`/`fixes=` 代价代理；结论沉到 `docs/agent/competitor-iteration-paths.md`，带日期的表留在这里。

- **codex（12,490 commits，2025-04-16→2026-10-21）的次序**：开开源当天起 72 小时内落地 review/diff(04-16)、sandbox(04-17)、macOS notify(04-17)、approvals 自定义安全命令(04-19)、image input(04-18)，mcp +16d(05-02)；行为质量轴晚 3–10 个月：resume +71d(06-26)、mid-turn steer +93d(07-18)、structured output +114d(08-08)、compact +131d(08-25)、memory/AGENTS.md +145d(09-08)、checkpoint/undo +160d(09-23，`#3914` 是 **git 工具**不是 KV rewind)、parallel tools +172d(10-05)、skills +229d(12-01)、subagents +267d(2026-01-08)、plan mode +278d(01-19)、hooks +295d(02-05)。
- **代价代理指向同一处**：mcp later=671/fixes=108、sandbox 485/94、review 257/120（fix 比 47%，全表最高）、approvals 279/104（37%）；而我们反复打磨的那几样最便宜——steer 43/13、compact 35/5、resume 21/4、parallel 12/4、plan 23/2。**门票不是护城河**：护城河是扛得住一年对抗使用的权限层。
- **ollama `x/mlxrunner`（双引擎 MLX 宿主机，离我们的双路最近）九个月 KV 正确性序列**：03-19 partial match on pure transformer caches → 04-14 `RotatingKVCache.concat()` mid-rotation 丢上下文 → 05-06 checkpoint exact-restore decode caches → **08-05 cache rewind refill 覆盖更靠后的 lazy snapshot**（lazy 快照索引的是 cache 的 live buffer，必须在 append 触及它点名的槽位前先拷出；他们只查 rewind 后第一次 append、且只查那次自己的范围 ⇒ 原文："restoring that snapshot later silently serves the new request's KV in place of the old conversation's"）→ 08-19 prefill 取消要 settle draft caches → 08-20 close 记账时 page out 已生成 token → 09-09 预算压力下驱逐活跃会话自己的 checkpoint → 09-10 保住 cached edge 被复用的头部不被驱逐。它的 agent 层反而晚：approvals 2026-01-09、parallel indices 04-10、plan gating 05-06、skills 07-17、rewind 08-05、compact retry 09-08。
- **由此定下五条动作（含仪表，不是愿望）**：① 接 `KVCacheConfiguration.rewind` 之前先立不变量「仍处于 lazy 的快照从未被覆盖」——探针 01 加断言：rewind 轮不许报比恢复目标更长的前缀复用，另加 `SessionPool` 单测：活跃会话引用的快照不可驱逐；② 压力驱逐改成按会话而不是按模型（我们现在是 model 级 LRU，`Sources/ocoreai/Engine/EnginePool.swift:373`/`:730`），仪表 = 压力事件期间活跃会话的 `prefixReuse` 不得归零；③ 取消语义要结账缓存（`.cancelled`/`maxTokens` 终态不得宣称没挣到的复用）；④ undo 先走 git（SQLite 会话 + git 工作区今天就能测），别追 token 级 rewind；⑤ MCP 不许在没有门的情况下加宽传输面（671/108 是全表最贵）。skills/hooks/subagents 各家都晚且便宜 ⇒ 我们已在这个次序之前，不加投入。
- **自家 provenance 实测（这才是今天真正的 P0）**：`Sources/` 注释里 173 条裸 upstream 引用有 4 条指向不存在的路径或行号。`Engine/EngineInferenceSupport.swift` 引 `GuidedGenerationError.swift:27` 并**加了英文引号**「Downstream code should catch this case to emit partial results if needed.」——该文件在 pin bb0d5b048 只有 15 行，这句话在 pin、在 HEAD、在全部 references 里都搜不到 ⇒ 改成 pin 里真实存在的 `:8-14` 原文，并注明该文件只描述错误、不规定下游处理（吸收语义仍取 emit 现场那两条实证）；`Engine/MLXBridge.swift` 的 `omlx/admin/HF_downloader.py:1122` 大小写错且行号错（真身 `omlx/admin/hf_downloader.py`，`target_dir = self._model_dir / task.repo_id` 在 1772）；`Multimodal/StreamingWindow.swift` 两条 rnnt 引用点名 transformers 实则 NeMo，且该路径在 transformers main 与 v4.40/42/44/46 全部 404 ⇒ 换成 `NVIDIA/NeMo@5a1a37b62d3c`（api.github 核实：629 行；426-427 是每取样一次的 `state = None`、全文 `reset` 出现 0 次；446-527 正是左移窗口 `left_sample = right_sample`）。
- **新门 `scripts/upstream-cite-check.sh`（挂进 `make anchor-check`）**：173 条扫到底、floor 120；路径必须命中 clone / `.build*/checkouts` / `.upstream-external-cites.json`，行号不得超过文件长度，集合外引用必须带上核实时的 sha；CI 没有 ref 时报 SKIP 而不是静默通过。第一次跑就抓到自家 resolver 两个假阳性——**basename 不是身份**（sglang 一个仓里 7 个 `protocol.py`，首条命中 139 行的那份会把 `:1020` 判成越界）⇒ 改成收集全部候选、任一命中即过。现状：scanned=173 ok=173 missing=0 越界=0 无 sha=0。
- **openclaw 已列入竞品但未读**：`openclaw/openclaw`（TypeScript，10-22 392k stars，"The AI that really does things. Any OS. Any Platform."）；本机 `git clone` 在 git-over-https 上超时（`api.github.com` 通、`github.com` 不通），owner 正在拉取 ⇒ 文档与 AGENTS.md 一律标「未读、不作任何结论」，落地后再跑 scan 看它是否改写上面的次序。
- **corpus cap 可见重钉 152041→156559**（`scripts/agents-md-contract.sh` 注释即凭据）：新证据文档 +5,610 B，同期从 `comparator-repos.md` 删掉 711 B 陈旧话（"four of the twelve"、"15 directories" 到 10-22 已不成立：实测七棵树在 `Sources/`+`Tests/` 里零耦合——MTPLX、TensorFold、Strata、mlx-serve、deepseek-harness、harness2、splash；加上 openclaw 共 16 个 clone）。下一次进文本必须同时出文本。

**10-22 `write_file` 的 path 槽位把「保留目录」说出来：目标任务 0/5 → 4/4，顺带量出记分板自己的方差**(P1 工具调用 / P3 回归防护) — `multi-step-nested-write` 连输五轮之后，第一次被拆到参数描述这一层。

- **不是工具的错**：`FileTools.write` 做得对——`createDirectory(withIntermediateDirectories: true)` + 原子写 + 读回逐字节校验 + 把路径回显给模型。五轮里它每次都成功，工作区里却永远只有 `./report.txt` ⇒ 丢目录发生在模型的计划里：它填 `path` 时填的是 `report.txt`。
- **改在它读的那一层**：`path` 参数的描述原本只有 "File path to create or overwrite"，现在把规则写进这个槽本身——"…KEEPING every folder the user named (asked for build/report.txt → path = build/report.txt). Missing folders are created."（`GET /v1/tools` 声明面，模型逐轮读到）。
- **效果（同机同模型）**：定点任务 0/3 → **3/3**，单步嵌套新任务 2/2；整卷再跑四次，`multi-step-nested-write` **4/4 全过**（改前是 2 次整卷 + 3 次定点共 5 次全败）。
- **一次改动不算证据，所以补了方差**：同一棵树整卷连跑四次是 **6/9、6/9、7/9、7/9**；失败集中在编辑恢复类——`change-config-value` 4/4 失败、`fix-off-by-one` 3/4 失败、`make-failing-test-pass` 2/4 失败、`fix-syntax-error` 1/4 失败。此前写过的 7/9 是一次好样本，不是稳态：**记分板此后报区间与逐任务命中率，不报单次分数**。
- **反面记录（试了、没用、已回滚）**：先把这条意思写进 system prompt 的 `toolActionDirective`（"read back the exact path… asked for build/report.txt…"），定点三次全败、整卷 6/9，已 `git checkout` 回滚。同一个要求，写在 prompt 段落里对这个 2B 模型不起作用，写在它要填的那个参数槽上起作用——这是这次最值钱的一条经验。
- **门**：`ToolSpecFullRegistryTests` 加一条，钉住 `path` 描述必须含 `build/report.txt` 与 `Missing folders are created`；schema 描述是 function-calling 契约，将来谁把它改回短句就红。

**10-22 一轮的最后一句话第一次要和它自己的工具记录对账：`ClaimVsAudit` 双向拦「假成功」与「假失败」**(P0 门面诚实 / P1 执行链) — invariant 2 在轮子出口处一直有个洞：模型停下，循环就停，没人拿最后一句和这一轮真正执行过的东西比。记分板抓到两半，今天一起堵上。

- **现场证据（`scripts/eval/run.sh`，同机同模型 `mlx-community/gemma-4-e2b-it-4bit`）**：`multi-step-nested-write` 答 `File created.`，`finish_reason: stop`、`tool_calls: null`、76 个 completion token，而 `build/report.txt` 不存在（**零工具调用**）；反方向的 `fix-off-by-one` 答 `I failed to fix the code…`，而它之前一次 `edit_file` 已成功、工作区校验是 PASS。前一句是 GUI 当着用户说谎，后一句把干完的活劝回去；两句都会进会话记忆、FTS 和 `/sessions`，然后一直留在那儿。
- **审计面只有一个老家**：`ToolMutationLedger` 在 `ToolRegistry.call` 的成功出口记账——那是 native `ChatSession` 循环、MTP 循环、GUI 直连和外部 MCP `tools/call` 唯一的共同咽喉。为什么不能拿线面上的 `tool_calls` 当证据：本地一轮工具在 `ChatSession` 内部跑完，线面回声是 `echoed_tool_calls=0`，而任务其实做完了。**读 `readOnlyWhitelist` 决定算不算改动**（`ToolRegistry` 才是那份名单的老家）：只读工具不算，未知的外部 MCP 工具算 ⇒ 通知只可能少报，不可能凭空指控。
- **判词规则收窄到能判得住的句子**：按句切（含中文句号与换行），一句里必须同时出现「改动动词」和「文件/artifact 线索」才算断言；将来时（`I will create…` / `我马上创建`）是计划不是完成，带否定标记的只认「文件操作失败」这一窄集。原因是第一版就把范围开宽了：`the test still fails`、`it cannot compile` 是对验证的陈述，一次成功的编辑并没有把它们反驳掉——照那样写就会朝反方向 over-claim。
- **只在「自己终止」的答题轮上判**：`finish_reason == stop`（Anthropic 面 `end_turn`）且本轮没交付 `tool_calls`；被预算砍断或正要调工具的轮子不是完成断言。成功与失败两类断言同时出现时判官闭嘴（歧义不等于矛盾）。
- **落地在四张脸上，同一个判词函数**：`/v1/chat/completions` 非流式与流式、`/v1/messages` 非流式与流式。流式的谎已经发出去了，所以纠正作为**再一个 delta** 发出（客户端本就拼接文本块），落库的那行存纠正后的文本；基线在各自响应组装函数的开头取，skew 只有一个方向（并发轮的写入只会把集合撑大 ⇒ 少报，不会误伤）。
- **门 `ClaimVsAuditTests`(17)**：断言全部用当天记分板记下的原文（`File created.` / 那段 `I failed to fix the code…` / `Token: 1|ORANGE-7731` / `I failed to read the file.` / `The command \`uname -m\` printed \`arm64\`.`），加中英双向、intent 排除、无文件线索排除、混合断言闭嘴、命名窗口 32 上限、`mutationTarget` 不猜路径。本轮 `--filter 'ClaimVsAudit|ToolMutationLedger|ToolRegistry'` **47 tests 全绿**。
- **记分板仍记 7/9**：这条改动不会把 `multi-step-nested-write` 变成 PASS——工作区里文件确实不在，**判分看工作区**正是它的定义。它改变的是那句谎不再被悄悄转述成「已完成」，而是带着 `[audit]` 说清楚没有工作区证据。

**10-22 使命的单位第一次有一块记分板：同机同模型 0/9 → 7/9，并当场抓到「说建了文件、文件不在原地」**(P1 执行链 / P0 门面诚实 / P3 回归防护) — 此前 `scripts/` 量的全是**线**（字段对不对、声称的复用有没有真付），没有一处量使命自己的单位：**agent 有没有把一件真实的活干完**。补上之后第一次有了可复现的分数，也第一次看清失败长什么样。

- **新 `scripts/eval/`（9 个可机验任务：写文件 / 修语法 / off-by-one / 定点改配置 / 读并报值 / 执行并报值 / 嵌套多步写 / 让失败的测试变绿 / 不许编造不存在的文件内容）**：判分**只看工作区**（`test -f`、`python3 -m py_compile`、`unittest … | grep OK`、`grep` 原文），模型的自述一律不作数；工作区在整轮开始前以 `OCOREAI_WORKSPACE` 交给 server，每个任务前清空，杜绝上一个任务的残留文件替下一个任务交卷。工具声明从 `GET /v1/tools` 现取，脚本里不留一份会漂的副本。
- **分数过程（同一天、同一模型 `mlx-community/gemma-4-e2b-it-4bit`）**：0/9 → 4/9 → 6/9 → **7/9**。**0/9 不是引擎的分数，是记分板自己的缺陷**：`GET /v1/tools` 的响应包在 `{"data":[…]}` 里，脚本按顶层读，于是工具声明读成空；**它自己的地板**（声明数 < 4 当场红）把这次拦下，否则一个 harness bug 会被当成一次引擎崩塌来读。invariant 1 在评测面上第一次真的起作用。
- **根因只有一处，但它压在整条执行链底下**：`SessionWorkspace.setDirectory` 只被 UI 调用（`ChatViewModel.swift:709`、`:770`、`SessionManager.swift:138`），`serve` 没有 Settings UI 可写 `UserDefaults` ⇒ 线面客户端送出的每个相对路径都锚在**进程 cwd**，而本该注入给模型的 `working_directory:` 那一行根本不存在。当天 5 个失败都是同一句 `edit_file: cannot read (missing or non-UTF8): calc.py`——正是写代码的人会自然写出的相对路径。修在唯一的解析老家：`WorkspaceContext.configuredDirectory()` 先读 `OCOREAI_WORKSPACE`（无头/CI 每轮声明），再读 UI 写的 `UserDefaults`，GUI 与 server 仍是同一个真值（`FileTools.resolve`、`ExecTools.effectiveCwd`、注入行三处消费者一起变对）。门 `WorkspacePathAnchorTests`(4)。
- **拒绝必须可纠正（执行链上最便宜的可靠性）**：`read_file`/`edit_file` 的失败文本现在带上解析后的绝对路径、这个路径由谁锚、以及怎么换锚；`oldString` 命中 0 次时把文件自己的行**原文引用**回去（小文件整份引用——只给「最相近窗口」是伪省钱：实测指到第 5 行 `return s`，而调用者要找的是第 3 行 `for i in range(1, n):`，一个会误导的提示比没有更坏）。严格性一分未放（模糊套用等于猜位置），只是把不可答的 `found 0` 变成可答的。门 `EditMismatchRecoveryTests`(2)。
- **仍差两条（不虚报）**：`change-config-value`（第一次 `oldString` 失配就放弃，重试纪律不足）；`multi-step-nested-write` —— **编造成功**：答 `File created.` 而 `build/report.txt` 不在原地，可 `write_file` 本来就 `createDirectory(withIntermediateDirectories: true)` ⇒ 这不是工具缺口，是**门面的话与审计记的事不一致**（invariant 2）。下一笔要做的是这一类的通用门：一轮声称动了文件而 `AuditTrail` 里 0 次成功 write/edit ⇒ 当场补一行纠正，而不是让这句谎进会话记忆、FTS 和 GUI。
- **上游 bump `48114eedf → bb0d5b048`**（#683 "fix loratrain for tiny prompts"）：逐条审计消费面后判为必 bump——上游给 `train` 加了 `checkSamples`，但 **`LoRATrain.evaluate` 仍未防护**，样本过短照样走进 `precondition(maxLength >= 2)` 的崩溃路 ⇒ 我们的 `LoRAModelSupport`/`LoRASampleDomain` 入口检查是**承重**的，不许因「上游修了」当冗余删。对本仓的影响 byte-neutral（`LoraTrain.swift:165 → :191`）；三处 pin 提及同步；按 bump 协议重跑 `scripts/collect-third-party-licenses.sh` 并入库（`ThirdPartyNoticesTests`(16) 绿）。
- **coreai-models +1（#356 "Support 8-bit KV-cache states and fix StateKind docs"）**：我们的字节表已含 int8/uint8/fp8=1（`Engine/KVCache+CoreAI.swift:588` `byteSize`），fp8→`.float16` 仍在 `:618-619`（macOS 27 才验得了的既开项，不臆修、不宣称已修）。值得记的是 #356 顺手把 `StateKind` 的文档改对了：**sliding ring 只能 rewind 到 wrap 之前**——正是我们量到的 `maxTrimCount == 0 → .rebuild`；Apple 自己写下这条，等于确认了我们对 rewind 储备的读法。
- **codex +51（语义轴，不链接、不复制）**：#55644 "Make pending injections interrupt agent waits and sleep" 与我们「无 tool 的一轮打不断」是同一条缺口的上游解法——它是**先例与判据**，不是我们的能力。
- **mlx-swift 轴**：tag 轴 0.32.3 == pin（干净）；`main` +8，其中 5 条落在消费面（#486 zero-size `asArray`、#501 leak、#474 evalLock、#499 lock inversion、#496 fp16 attention mask）——记为观察，本笔不动代码。
- **注入文件回到它自己的规范（invariant 2 用在文档上）**：§ Docs Contract 过去把 15 道门逐条重抄一遍，而 `scripts/agents-md-contract.sh` 头部本就逐条写着这份说明——手抄的第二份真相**已经漂过两次**（本文件记着漏记 P8/P11、漏记 P9/P10 各一次）。删掉第二份，root 只留「跑什么、保证什么」与指针；腾出的字节给记分板一条——使命的单位第一次进每一轮的上下文。
- **入账**：`swift build` 0；`make test-clt` **2937 tests / 528 suites 全绿**（424.9 s）；`make docs-check` ✅、`make audit` ✅、`make anchor-check` 46/0 drift、`make format-check` 0 重排；`bash scripts/eval/run.sh` **7/9**（记分板，不是 CI 门：数字还没有历史之前不接进 CI，否则天花板会被读成回归）。

**10-22 第二句「你还没意识到文档稀烂？」：镜头从 root 移到 root 之外那一跳，量出四类真缺陷并全部补上门**(P2 文档复杂度 / P3 回归防护) — root 瘦完不算完：root 之外那份「agent 被指过去再看」的语料才是当天真正在骗人的东西。同一台机器、同一套 grep 量出来的不是感觉：

- **表格坏在渲染层（不只是难看）**：`scripts/probes/README.md` 24,720 B，从 `05` 那行起 **8 行断行**（一条 row 折到下一行），markdown 表格在第一个断行处整块失效——那下面的每一条 probe 契约在 GitHub/编辑器里都不是表格；另有 **2 行列数不齐**（`24`、`26` 把 question 和 method 挤进同一格，表头是 3 列）；14 行 >600 B（最长 1,362 B）。写检查器时 `.github/REVIEW.md:254` 先误报一次（格内转义 `\|`），门里显式处理转义 ⇒ 全仓 22 个 .md 扫下来，真缺陷只剩探针索引这一处（不是全都烂，是烂得具体）。
- **`docs/agent/closed-items-log.md` 有一行 3,047 B**，把 10-14 那一轮逐条复述了一遍，而 CHANGELOG 里同一轮指纹全在（`v1/messages/count_tokens` 4 处、`prompt_tokens:43`、`deletingLastPathComponent`）⇒ 第二份真相。**但这文件不能整删**：`kvCacheRuntimeReport` 这条裁决在 CHANGELOG 里 **0 命中**，是全仓唯一记录（还挂着一个上游锚点）⇒ 删复述、留裁决与仍未决的那半条（`tokenizer_backend: heuristic` 的估算精度没有独立断言），4,506 → **2,435 B（−46%）**。
- **改法一律可验证无损**：探针索引 表 → 每条一个 bullet（`NN-name.sh` — 问题 / `Fails when:` 逐条，27 条齐全）；`docs/agent/comparator-repos.md` 同形 4 列长表 → bullet；行重排 14 行（CJK 感知，跳代码围栏 / HTML 注释 / 表格行：build-gate-reality 4、third-party-notices 6、closed-items-log 3、ARCHITECTURE 1）。**无损不是口号**：改写前后按「去掉空白后的字符多重集」逐文件比对，7 个文件 `lost=0`，唯一差异是表头与分隔行的结构字符。形状结果：探针索引最长行 1,362 → **364 B**，全语料最长行 1,823 → **≤400 B**。
- **门自己抓到自己管着的文档在说旧形状**：`cmp_matrix_rows` / `cmp_named_trees` 两条 claim 的 grep 钉在 `^| \`` 上，表格一变形状 P4 当场报 `command returns 0`——这正是 P4 存在的意义；改成 `^- \`` 后 claims **42/42**。
- **补门两条（`scripts/agents-md-contract.sh`）**：**P14 索引 == 文件系统**——探针 README 必须恰好索引存在的脚本（少一个红、多一个红），全仓 .md 表格必须一行一 row、列数与表头一致、行不许折，`docs/agent/*.md` 不许有孤儿（root 与 guides 都没点名就红）；三条扫描各自带地板（.md≥15、doc≥5、index≥20），免得「扫不到」被当成「没问题」。**P15 一跳语料形状**——13 个文件、总量 **152,041 B** 上限（shrink-only）、行 ≤400 B（围栏/注释/表格行豁免：注释里的 claim 必须留在解析器读它的那一行）。
- **顺手修一处「文档不反映代码」**：脚本头部把 P1–P12 逐条写明白了，**P13 只有代码没有说明**；已补齐 P13/P14/P15。root § Docs Contract 同步补一句，为守 B1 棘轮，删掉与 `CONTRIBUTING.md` 重复的两行操作符语义（`>=` floor / `<=` ceiling 的老家在 CONTRIBUTING），root 30,480 → **30,471**。
- **红样全部当场跑过（真插真删）**：幽灵条目 `99-ghost-probe.sh` → P14 ghost 红；新建 `28-unindexed-dummy.sh` 不索引 → P14 missing 红；`instruction-channel.md` 追加 430 B 长行 → P15 wall 红 + 语料字节同时红；`README.md` 塞一行折行 → `P14 … README.md:117 continues a table row` 红；逐项还原后 `✅ contract holds`。
- **入账**：`make docs-check` ✅（root 30,471/30,480、corpus 152,032/152,041、walls 0、probe-index 27/27、doc-orphans 0、table-defects 0、claims 42/42、numbered 19/19）、`make audit` ✅、`make anchor-check` 46/0 drift、`make format-check` 0 重排。
- **仍开（不虚报）**：`CHANGELOG.md` 本体 581,298 B / 372 个日期戳 / 最长行 6,082 B 仍等 owner 点头（切 `docs/agent/rounds/` 动的是「唯一日记」的形态）；`README.md` / `README.zh.md` 面向人，本轮没纳入形状门，各自还有 8 行 >400 B；探针与比较器两处由表格改成了 bullet，若 owner 更看重表格呈现，可回退成「一行一 row、列数一致」的窄表——门禁允许那种写法。

**10-22 AGENTS.md 自己正是它管着的那个坏样子：root 50,618 → 30,480（−39.8%），并把「不许写日记」从一句自我提醒变成一道门（P13）**(P2 文档复杂度 / P3 可观测性) — 起因是两句「AGENTS.md 一点也不规范？」「你还没意识到文档稀烂？」。这不是文风之争，是可量的：root **38 处 `MM-DD` 日期戳**、**37 行超过 400 字节（最长 1,223 B）**、六个政策章节互相重复（`Core Principles` / `Rules that apply everywhere` / `Workflow` / `Agent Execution Rules` / `Agent Runtime Reality` / `Taste test`），而它自己在 § Rules 里白纸黑字写着「**Not a diary.** A root rule is ≤3 lines… Dates… go to `CHANGELOG.md`」。P1–P12 与 B1 全绿，日记照样长——**规则没有门就是断言**（invariant 1 的自打脸现场）。

- **改法（只搬位置，不销毁证据）**：root 只留规则与指针，每条 ≤3 行（what + 一句证据 + 门名），日期全部退场；只与这台主机有关的事实（谁是 Codex、skills 清单会漂、sub-agent 默认为何是一趟、escalation 复核坏在哪一层、`~/wiki` 与 `.hermes/` 为何永远不是项目证据）搬去新 `docs/agent/codex-runtime.md`；其余过程叙述本就在本文件——逐符号 grep 已核：`firstStopOccurrence` / `ToolProseLedger` / `splitInstructionMessages` / `PromptCacheReuse` / `mergingSteeredTurn` / `HubReachability` 全都在，root 里的复述是第二份真相。结果 **root 30,480 B**，上限同刀 **50,618 → 30,480**（B1 仍是棘轮，此后只减）。
- **补门 P13（`scripts/agents-md-contract.sh`）**：`AGENTS.md` 中 `MM-DD` 日期戳必须为 **0**；任何一行不得超过 `OCOREAI_AGENTS_MAX_LINE=400` 字节。**红样当场跑过**：塞进一行「Measured 10-22 …」⇒ 同时报 `P13 carries 1 dated stamp (10-22)` 与 `P13 has 1 line over 400 bytes (first L10 = 640)`；撤掉即 `✅ contract holds`。上限管体量，P13 管形状——「该删的删」能长期成立，靠的是后者。
- **两处门形跟着事实搬家（不是放宽检查）**：P8 过去只认 `Pinned upstream mlx-swift-lm at \`…\`` 一种句式，现认「repo 名附近被反引号包住的 hex 令牌」并与 `Package.swift` 的 pin 比相等——钉住的仍是 `48114eedf`，比对逻辑一字未松；`cmp_designation_line_exists` 的 grep 跟着新措辞改模式（仍断言比较器清单被点名，等号 = 1）。§ 交叉引用扫描地板维持 12（瘦身后实测 12，未下调），dangling 0。
- **入账**：`make docs-check` ✅（root 30,480/30,480、§-refs 12/12 floor 12、claims 42/42、numbered-claims 19/19、routing 12）、`make audit` ✅、`make anchor-check` 46/0 drift ✅（同日 rewind 那笔插入的行把 14 条引用推走，逐条重钉）、`format-check` 不受影响。
- **仍欠的一刀（要人点头）**：`CHANGELOG.md` 已 **574,927 B / 261 个日期戳 / 平均行长 464 B**，是另一处「日记不可查」。按轮切到 `docs/agent/rounds/` + 根留索引，动的是「唯一日记、唯一落点」这条既有裁决的**形态**，不自作主张；先记在这儿，附可量的尺寸。

**10-22 rewind 在 guided/MTP 那一轮说了大话：现场抓到它「声称复用、实际全量重付」，决定改搬到车道处**(P1 门面诚实 / 执行链) — 上一笔把编辑重发从 `758/0` 做到 `758/718`，并写下「池子在拒答处给 offer，调用处接住」。它没说出口的假设是**调用处一定会接**。guided gen 与 MTP 不接：它们各自建 KV，并在生成前把池槽交回去。

- **现场证据（探针 27 §5 逐字复现）**：带 `response_format: json_object` 的编辑重发，日志先说 `Session REWOUND … instead of re-prefilling 2`，下一行 `Routing through GuidedGenerationLoop with grammar constraint`，usage 报 `prompt_tokens=753 cached_tokens=none`——**753 个 token 全量重付，而复用已被声称**。更糟的是账：池子在给 offer 的那一刻已摘条目、删磁盘快照，并且按规则**跳过** `historyDiverged` 记账；于是一次货真价实的全量重建，在线面上既没代价也没病因。
- **根因是决定放错了地方**：「这条缓存能不能削到公共前缀」池子判得了（`rewindHistoryEnd`）；「这一轮到底走不走 `ChatSession`」只有调用处知道。若让池子照旧给 offer、调用处再回绝，日志/台账/复用会留下三条互相矛盾的陈述。于是把车道判断做成**一个家**：`EnginePool.bypassesPooledChatSession`（媒体 outrank 两条车道，因为两条车道都不带媒体 ⇒ 标准路答题；grammar 与推理配对不安全则落回标准路，MTP 还需有可草稿的消息），在 acquire 之前算一次，以 `rewindUsable` 交给池子，`rewindHistoryEnd` 多一条 `laneCanSpend` 轴。
- **实测（改后，同机同模型同脚本）**：guided 那轮不再有 `REWOUND` 行；日志如实写 `not reusable: … building a clean session`；`/v1/models/:model/kv-cache` 的 `reuseRefusals.byReason.historyDiverged` 从 0 变 **1**（而标准路那笔编辑轮仍是 0——削前缀不算拒绝、不算削前缀的算，两头各自如实）；答案仍是 `{"word": "SALMON"}`，`MARLIN` 全文不出现。
- **门**：`SessionRewindOnDivergenceTests` 5 → **7**（车道轴并入遍历，384 → **768 格**；新增「不能花钱的车道不给 offer」与 `bypassesPooledChatSession` 六格真值表；结构门再加三条：车道只在引擎里算一次、`rewindUsable` 只交一次、池子只在这一处按车道开门）。探针 27 §5 五断，**14 → 20 passed / 0 failed / 4 measured**。聚焦 `SessionRewindOnDivergence|SessionIsolation|ReuseRefusalLedger` = 45 tests 全绿。**红样当场跑过**：把 `laneCanSpend: rewindUsable` 硬改成 `true`，§5 同时红在「声称的复用」与「账上的拒绝」两处断言，结构门一起红（`laneGated == 0`）；改回即绿。全量 `make test-clt` 通过：**2931 tests / 526 suites**（上笔基线 2929/526，+2 = 新增的两条车道断言）。
- **诚实登记**：本机没有可加载的 MTP checkpoint，MTP 那半边只有**谓词真值表 + 与 guided 同一条门的路径覆盖**，没有活体证据；探针与本文都写明这一点，不假称两头都验过。


**10-21 改历史的那一轮：从「拒绝并重刷全量」到「削到公共前缀」——同一轮 0/758 → 718/758**(P1 执行链与状态管理) — 上一笔量出了价格（续写复用 734，编辑轮复用 0），并写下「`fork(history:)` 是入口，接上之后复用多少尚未实测」。接上之后实测：**光接 fork 不够**，而且失败得毫无声响——答案仍然正确（SALMON、MARLIN 不出现），`cached_tokens` 仍是 **0**。把这种「静默不省」读成成功，正是 invariant 1 要拦的事。

- **根因在上游自己的自校验里**：带滑窗的 checkpoint，旋转缓存一旦转过窗口就 `maxTrimCount == 0`（`KVCache.swift:1015`），`RewindToCommonPrefixRule` 的 `trimCount <= maxTrimCount` 不成立 ⇒ `.rebuild`。fork 给的是一条**能续的会话**，储备给的才是**续得起的额度**：`CacheConfiguration.swift:299` 把 `kvCache.rewind.maxTokens` 直接交给 `RotatingKVCache.rewindCapacity`，`KVCache.swift:1036` 的原话是「a configured reserve extends that limit beyond rotation」。
- **改动两处，各一个家**：① `SessionPool.acquire` 不再一拒就丢缓存——在拒答的同一处判 `rewindHistoryEnd`（三条前提：指令集一致；公共前缀之后**还有话要说**（10-12 那种同键重发已答轮次的形状，rewind 会让这一轮无话可答，故仍走丢弃）；两侧都不带媒体），把可续会话与分界交给调用处；`Chat.Message` 不是 `Sendable`（`Libraries/MLXLMCommon/Chat.swift:13`，它装 `UserInput.Image`），转写本进不了 actor，所以 fork 只能落在 `EngineInference`（全仓唯一一处，钉死）。② `makeKVCacheConfiguration` 三个出口一律请求储备：`kvCacheRewindReserveTokens = 1024`，没配量化时也回 `.fullPrecision` + 储备，而不是 nil（nil 曾意味着「什么都别提」，连续命的额度一起丢掉）。
- **③ 快照得说出自己是在什么计划下写的**：接了 rewind，「这条缓存续得起吗」就多了一个维度——储备。`KVCacheManifest` 升到 v2，把 `rewindReserve` 写进 sidecar；对不上就丢弃并点名（新 `SnapshotRefusal.rewindReserveChanged`，台账同名）。不是洁癖：上游对不能再现的计划直接在第一个 token 抛 `kvCacheConfigurationChanged`（`ChatSession.swift:307`），而 v1 sidecar 压根没这个键 ⇒ 解不开 ⇒ `readManifest` 的 `try?` 交空，走「丢弃并点名」——代价是一次冷的回合，不是一次失败的回合。本机 `~/Library/Application Support/ocoreai/cache/kvcache/` 里就躺着 10-18/10-19 的 v1 文件，升级样本是现成的，不必伪造。

- **实测（同机、同模型 gemma-4-e2b-it-4bit、同一条会话）**：T1 `708/0` · T2 `732/710` · T3 追加 `758/734` · **T4 编辑 `758/718`（94.7% 复用；接之前是 `758/0`）**，答案仍是 SALMON 且 MARLIN 全文不出现。RSS 4.60 GB → 4.50 GB：储备只是多留行，不放宽注意力窗口（`KVCacheConfiguration.Rewind` 自己的文档就这么写）。
- **台账跟着改口（invariant 2）**：给出 rewind 的那一轮不再记 `historyDiverged`——它没被拒绝，记上去等于向线上报一次引擎没做的全量重算；探针 01 老腿「编辑轮必被拒」当场把这件事抓成红，改完 18 passed/0 failed，并把「丢弃型拒绝」与「留住缓存待削」两种日志分开数。收益走已有的公布面：`prefixReuse.lastCached/lastPrefilled` 是引擎测得的数，不是探针推的。
- **门**：新 `SessionRewindOnDivergenceTests`(5)——384 格全遍历，硬断「rewind 被给出时 `canReusePooledSession` 必为假」（两条规则不许同时对 yes，否则就是给缓存记了它没渲染过的上下文）；三条前提各自单独红；扫描先自证正例，再钉「fork 全仓恰好 1 处、判断恰好 1 个家、储备在 resolver 的 3 个出口都在、储备值是一个具名常数」。`SessionIsolationTests` +2（计划不同必须拒、优先级仍在模型之后、匹配的计划仍放行；v2 往返保住储备，v1 原样字节解不开——两条都是当场写错、当场被自己的断言抓红：把「feed 比缓存短」当成放行，其实是 `.notAPrefix`）；`ReuseRefusalLedgerTests` 的词表门当场为新增的拒绝判红（磁盘面与线上必须是同一套词，少列一个就红）。**红样（当场跑过）**：只接 fork 不请储备 ⇒ 同一轮 `cached_tokens=0`（就是上面那条实测）；摘掉 `incoming > commonPrefix` ⇒ 10-12 那一格红。探针 27 现在把复用钉成硬门（`cached_tokens > 0`）：`bash scripts/probes/run.sh 27` ⇒ **14 passed, 0 failed, 4 measured**；顺带回归 01（18/0）、19（9/0，改指令仍 refuse-and-rebuild，未被这次改动波及）、21（16/0）、22（10/0）。
- **入账**：全量 `make test-clt` = **2929 tests / 526 suites 绿**（上一记基线 2922/525：+1 套 `SessionRewindOnDivergenceTests`、+7 条）；`audit` 全绿（Class-J 48 个本地 suite 名可解析 + 1 条上游出典，0 unresolved）；`docs-check` root **50618/50618**——§ Open 那行改写后比原文更短，上限随 `make docs-budget` **50629 → 50618**；`format-check` 零改写；活体探针 27 = **14 passed / 0 failed / 4 measured**、探针 01 = **18 passed / 0 failed / 6 measured**（复用与拒答两头都在同一支里复核）。
- **anchor 门这一趟真的值钱**：本次往 `EngineInference.swift`、`MLXBridge.swift` 各插入 42/31 行，**16 条 `file:line` 引用当场飘红**（`ARCHITECTURE.md` 的 `caughtError`、`Package.swift` 里四条 KV 采样钉、Engine guide 的 steer/thinkingBudget/components 六条……），`make anchor-check` 逐条给出真实行号后重新落位 ⇒ **46 checked / 0 drift**。没有这趟门，这 16 条会集体指向别的函数而全绿——正是 invariant 1 说的那种债。

- **仍未决（登记 § Open）**：1024 是拍的常数——不随模型、不随内存水位调，且只在 gemma-4-e2b-it-4bit 上量过；超出储备的编辑仍付全量。GUI 端到端仍零验证（这条路径不经 HTTP 也走得到，但只有静态门）。

**10-21 编辑重发到底漏不漏？——「refusal 在防泄漏」第一次被看见，一次编辑的价格也量出来了**(P1 上下文与状态管理 / P3 回归防护) — 探针 01 给这一轮标过价（`prompt_tokens`/`cached_tokens`），却从未验证过正确性：`canReusePooledSession` 拒绝对话本的全部理由是「旧 KV 描述的是改前的会话」，而 HTTP 面上没有任何一处检查过它真的挡住了改前的答案。若编辑重发仍能答出被替换掉的事实，那就是一个躲在绿色 token 台账后面的 P0 正确性缺陷——**这条规则此前是被相信的，不是被观测的**。

- **新探针 27（`scripts/probes/27-edited-history-honesty.sh`）**：同一会话四轮——追加轮（自带前提：它必须复用，否则「这次编辑值多少」没有基准）→ 给代码字 MARLIN → 把 MARLIN 那一轮改写成 SALMON 重发 → 断言答案必须是 SALMON 且 MARLIN 全文一个字都不许出现。另钉三条诚实台账：`prompt_tokens ≥ cached_tokens`；编辑轮的复用不得超过追加轮的复用（重建轮报出比续写还多的复用＝门面承诺超过引擎交付）；本次拒绝必须在 `/v1/models/:model/kv-cache` 的 `reuseRefusals.byReason.historyDiverged` 里点名（代价与病因落在同一张面，不许只有一头）。**实跑：`12 passed, 0 failed, 4 measured, 0 known-open`（当天接入 rewind 后同一支改为 `14 passed, 0 failed`，见上一条）。**
- **实测（gemma-4-e2b-it-4bit，单会话四轮）**：turn1 `708/0` · turn2 `732/710` · turn3 追加 `758/734`（续写复用 97%）· turn4 编辑 `758/cached 0`——758 全部重付，而答案是 SALMON、MARLIN 不出现。**「拒绝在防泄漏」从推断变成观测。**
- **当天更正（同一日，见上一条）**：这一条里的推断**错了**。`fork(history:)` 确实接得上、答案也确实对，但复用是 **0**——带滑窗的 checkpoint 转过窗口后 `maxTrimCount == 0`（`KVCache.swift:1015`），上游把削前缀降级成 rebuild；额度来自 #622 的储备（`CacheConfiguration.swift:299` → `RotatingKVCache.rewindCapacity`）。fork + 储备一起接上之后，同一轮才从 `758/0` 变成 `758/718`。保留原文不删，是因为「读文档得到的推断」与「跑出来的数」差在哪，正是这条记录的价值。
- **哪个门会红**：探针 27 第 3 断（改后仍答旧事实＝泄漏）、第 4 断（台账超过整体，或重建报出比续写更多的复用）、第 5 断（当日随 rewind 接入改为「削前缀不许被记成拒绝」，见上一条）。回归形态＝把 `canReusePooledSession` 的 `commonPrefixCount >= cachedMessageCount`（`SessionPool.swift:1364`）摘掉，让旧 KV 直接续写。
- **净账**：root `50631 → 50629`（§ Open 该行改写后更短：删去「正确：」「机制」两处赘词，换上的结论比「仍待样本」更短），shrink-only 上限同步下调至 **50629**。

**10-21 AGENTS.md 自己也得归档：`§ Open` 两处引用指向一个不存在的章节**(P3 可观测性 / 契约缺口) — 起因是一句「AGENTS.md 一点也不规范？」。测下来不是文风问题：`§ Open` 在 root 被引用两处（`SessionPool` 那一行、Documentation Map 里 `closed-items-log.md` 那一行），而 root **没有任何叫 Open 的章节**——那串 open items 在早前一次瘦身里丢了标题，裸挂在 `### Testing Quality` 与 `### Upstream Audit Dependencies` 中间。契约一直全绿，因为 P1–P11 里**没有任何一条读 `§` 引用**（invariant 1：没人复跑的断言等于没断言）。

- **补门（P12，`scripts/agents-md-contract.sh`）**：抽出 root + 8 份 guide 里所有 `§ Name` 引用；锚点＝全部 `#`–`######` 标题，加上这套文档真正用来标块的加粗小标题（`**Upstream alignment:**` 这种就在文中起导航作用）；允许引用只写目标前缀（`§ Routing` → `Routing table — working in X → read this first`），并在"引用后面还接着散文"时从最长前缀往回试（`§ Routing table names those with their own guide` 指的是 Routing table，不是七词章节）。扫描自带下限（实测 19 条引用，floor 12），模式一旦不再命中就红而不是空过。**首跑即抓出那 2 条 dangling**。
- **修结构**：给 open items 补回标题 `## Open — measured, unresolved`（`§ Open` 当场可解，`dangling=0`）；`### Upstream Audit Dependencies` 从 `## Code Conventions` 底下提出来做同级章节——它讲的是参考资料，不是代码约定，挂在下面只会让目录层级和 `§ Upstream` 一类引用互相打脸。
- **index 自己漏了两项**：§ Docs Contract 列举这套门时**漏了 P8 与 P11**（脚本里有，目录里没有）。这是 invariant 2 的反方向：门面把引擎做的事说少了，读者照着判断一样会错。补上 P8/P11/P12，并用同一段里两处冗辞抵账。
- **门当场抓到我写的新文案**：写 index 时我把 `XxxTests`(N) 和 `§ Name` 当占位符写进正文 ⇒ P6 报"没有这个套件"、P12 报"引用悬空"。这不是误报——扫描分不清占位符与断言，于是改成描述而不写模式原文；门的严格性原样留在门里。
- **净账（不粉饰）**：root **50566 → 50631（+65）**：新标题与 index 三条是加进去的；但 shrink-only 上限经 `make docs-budget` 从 **50668 → 50631（−37）**，今天的天花板确实降了，文件本身涨了 65 字节，两笔都记在这儿。实跑：`make docs-check` ✅（`§-refs=19 scanned / dangling=0 / anchors=95`）、`make audit` ✅、`make anchor-check` 37 anchors / 0 drift ✅。
- **仍未动（等一句确认）**：五条重叠的"怎么做事"章节（`Two invariants` / `Rules that apply everywhere` / `Core Principles` / `Agent Execution Rules` / `Taste test before you hand off`，合计 ≈7.6K 字符＝15%，且与 `CONTRIBUTING.md` 大面积重复）、以及满篇带日期的事故叙述，都还留在 root。把它们挪去 `CHANGELOG.md`/`docs/agent/`＋CONTRIBUTING、把 root 压到 ~30K 是另一笔账，方向可行但那是改契约级的手术，不在本次擅自动手。

**10-21 子进程临死前喊的那一句，被我们亲手倒进了 /dev/null**(P1 执行链 / P3 可观测性) — 上一笔把 MCP 那一跳的预算定成 30/300 之后，拿一个故意起不来的 stub 去看拒绝文案，屏幕上只有 `Connect failed: MCP server process exited with status 1`。这句是真话，也是废话：`MCPStdioClient.launchProcess` 里 `proc.standardError = nil`，Foundation 把子进程 stderr 接到 /dev/null，于是 `ModuleNotFoundError` / `MODULE_NOT_FOUND` / `address already in use` 这些**直接把修复点写在脸上**的行当场销毁；卡死那一类也只留下 `did not answer within 30s`。旧套件拦不住它，而且不是门读错了数——是**根本没订这个货**：没有任何断言指望有字节回来（invariant 1 的另一面）。

- **形状取自 codex，尺寸按"人会读多少"定**：`rmcp-client/src/executor_process_transport.rs:52-53` 给 stdout 8 MiB/行、stderr 只给 1 MiB（stderr 是诊断，不占协议流的额度），`:465-487` 逐行 `info!`、EOF 再 `flush_stderr`——它连一片都不留。这里同一分工，但留下一眼读得完的量：新 `MCP/MCPStderrTail.swift` ＝ 最后 **12 行 × 每行 400 字符**的环形缓冲，被挤掉多少行照样在文案里报数（`+N earlier stderr lines suppressed`）；traceback 的结论行天生落在最后，正是环形缓冲留下的那一行。半行按**字节**累积，所以一个 UTF-8 字符被 chunk 切开也不会烂成 U+FFFD（实测定死）。

- **改动（采集一次、折进一处）**：① `launchProcess` 交出 stderr 管道，`startStderrDrain` 在 `.utility` 队列用阻塞 `read(2)` 收（不用 `FileHandle.read(upToCount:)`——本机 macOS 27 beta 实测 13–23 s/行，`MCPStdioTransport` 头部早记着这条实测），`n==0` 即 EOF 收线程，`finish()` 补上没换行的尾巴。② `MCPClientError` 四个 case 各带一条 `stderr:`，折进文案的唯一落点是 `withStderr`（已有证据不覆盖：`attemptConnection` 会把内层错误再包一次，同一死因说两遍等于没说）；文案是**追加** `— stderr: …`，孩子没吭声时与旧文案**逐字相同**（老客户端的匹配不漂）。③ `attemptConnection` 不再把 `.childExited` / `.timeout` 一律压成 `.protocolError`——类型本身就是"崩了还是卡住了"的判据，压掉之后上层只能猜。④ 取证据只在"孩子刚死、最后几行可能还压在管道里"时轮询，上限 10×15 ms，而且写成**次数**不是第二条绝对死线（那个文件已有门管着"响应等待只许有一条死线，且归调用方"）。

- **一条本会埋进产线的 fd 竞态，靠实测挡掉**：直觉写法是"drain 闭包强持有 `Pipe` ⇒ 父进程也攥着写端 ⇒ 孩子退出后 `read` 永远等不到 EOF ⇒ 每条连接漏一条线程"。写最小复现量一下（孩子写一行就退出、父侧仍引用 `Pipe`）：**Foundation 在 spawn 时就替父进程关掉了写端**，孩子退出后 **5 ms** 读到 `read()==0`。于是线程自己收口、不二次 `close`、`isEnded()` 真会翻——那点收尾窗口才敢这么定。

- **门（`MCPStderrDiagnosisTests` 10 条 / 2 套 + 探针 26，全部实跑）**：活体 4 条——崩的 stub 必须把 `Traceback` 与 `ModuleNotFoundError` 一起带到 refusal，且 `status==3`、类型仍是 `.childExited`；抱怨完就卡死的 stub 必须在 2 s 预算上答 `did not answer within 2s` **并**带着那句 `address already in use`（两种失败模式不许塌成一句"失败了"）；健康 stub 照连、`tools/list` 照答，它的启动日志也被记下来；再加一条扫描门，先自证"还看得见 `proc.standardError`"再断 `standardError = nil` 归零。单元 6 条钉住"有界"与"不编造"：5000 行只留 12 并报 4988 suppressed；单行截到 400+`…`；chunk 边界拼行与多字节；EOF 补尾；`reset()` 清上一轮；无证据时文案逐字不变且全文只出现一处 `stderr:`。**红样**＝把 `proc.standardError = stderr` 改回 `= nil`：**12 跑 4 红 / 8 issues**，而 6 条纯缓冲测试全绿——断的是接线不是缓冲，正是想要的分离。MCP 面 `--filter MCP` **76/76 绿**，全量 `make test-clt` **2922 tests / 525 suites 绿**。新探针 **26-mcp-stderr-diagnosis**（活体 HTTP）绿 = **12 passed, 0 failed, 4 measured, 0 known-open**：`-32603` 同时报出 status 3 与异常名、且全文只有一处 `stderr:`；死与卡在同一个 stub 家族上也分得开；`$bridge/endpoint/list` 的 `lastError` 仍留着那份证据（响应滚走之后 GUI 读的就是这一行）；两次失败的 MCP 连接之后 `/health` 与 chat 代码字都活着。回归复核 25 = **11 passed, 0 failed**。

- **顺手修掉门自己的一个假红**：`MCPTimeoutDeliveryTests.scanFloors` 扫 `ContinuousClock.now + `，而我为了说明"为什么这里不许再写一条死线"恰好在注释里写出了那个形状 ⇒ 门红。根因不是注释不该写，是扫描把散文当代码：两处源码扫描（本套与 `scanFloors`）改成先剥整行注释（`codeOnly`，与根 AGENTS.md 的 claim 扫描同一口径），理由留在原地，维护者不必为了让门变绿而销毁理由。

- **仍未验证 / 留手**：GUI（Settings → MCP）还没有展示 stderr 尾部的入口，本轮只把证据放进 HTTP 拒绝文案与 `endpoint/list` 的 `lastError`；stdout 侧的 poll+drain 一字未动，仍是 `MCPStdioTransport` 原有的有界等待；`maxLines=12 / maxLineChars=400` 是"读得完"的尺寸，不是按模型上下文量出来的数。

**10-21 配置里那条「外部 server 响应超时」根本没人读——门上挂着牌子，钥匙是虚的**(P0 行为不一致 / P1 执行链) — 起因只是想给 MCP 那一跳定一个"该等多久"。`git grep serverTimeoutSeconds -- Sources` 只回来两行：声明，和 `self.x = x`。`MCPBridgeConfig` 的注释写着"外部 server 响应超时（秒）"、默认 10 s；`MCPStdioClient` 真正执行的是字面量 `15`，而且写了两处——`sendRPC` 外面一层 `withTimeout(seconds: 15)`，被它包住的那个 `waitForResponse` 里面又一条 `ContinuousClock.now + .milliseconds(15000)`；`MCPEndpointTests` 断言的是 `config.serverTimeoutSeconds == 10` / `== 5`。**读的是存取，不是行为**：knob 断线多久套件都照样绿，因为门读的不是代码用的那个数（invariant 1）。

- **为什么是两条预算而不是一个数**：`initialize` + 首次 `tools/list` 是握手，`tools/call` 是任务本身。一条 15 s 同时管两件不同的事，等于把"外部工具正在干活"和"握手卡死"混成同一种失败——浏览器动作、一次真实查询、`npx` 冷启动的 server 都在 15 s 被掐，而本机自己的 shell 工具允许 300 s（`ExecTools.maxTimeoutSeconds`）：同一类 agent 动作，仅仅因为跨了一根管道就贵 20 倍。判据与数字取 codex `codex-mcp/src/rmcp_client.rs:110-111`（`DEFAULT_STARTUP_TIMEOUT` 30 s、`DEFAULT_TOOL_TIMEOUT` 300 s），形状也照它做成 per-server 可覆盖（`config/src/mcp_types.rs:272/276` 的 `startup_timeout_sec` / `tool_timeout_sec`）。

- **改动（一个家 + 一条缝 + 一组读数）**：① `MCP/MCPTimeouts.swift`（新）＝唯一的家：30 / 300，域 `1…600`；`resolve` 只在显式值越界时抛，`clamped` 是消费侧的第二道网——调用方一个填错的数字只损失一次取整，买不到一次挂死（与 `Scheduler/KVCacheBudget.swift` 同一分工）。② `MCPStdioClient` 在 init 里把预算装配成一条 `MCPRPCBudgets`（endpoint 覆盖 > bridge config > 硬默认，解析点唯一），`request(…phase:)` 用类型挑预算（`.startup` / `.tool`），并**删掉 `waitForResponse` 自带的那条死线**——死线只能有一个主人，否则 config 填什么都白填；循环仍能收口，因为 `transport.readLine()` 单次有界 ≤50 ms（其自身契约），且每轮开头查 `Task.isCancelled`，外层 `cancelAll` 生效即退。③ 域外值是答案不是挂起：`$bridge/endpoint/connect` 的 `startup_timeout_sec` / `tool_timeout_sec` 越界或非数字 → JSON-RPC `-32602`，命名**字段 + 区间 + 原值**，且不留半截 endpoint；超时文案改成点名生效秒数（`did not answer within 1s`）——旧文案只说 "timed out"，把人送去查一个代码里并不存在的默认值。

- **自家红样在同一个 session 里抓出第二条**：红样＝把 endpoint 覆盖从 client 的解析里摘掉（＝旧世界唯一的样子："knob 存着但没人交付"）。第一次跑时 `$bridge/endpoint/list` 仍然**绿**——因为它公布的是 `handle.endpoint.startupTimeoutSeconds`，即**调用方要求的那个数**，不是引擎装配的那个数：门面替引擎认了账（invariant 2 的形状）。改成 `EndpointHandle.appliedBudget`（连接成功后从 `client.budget()` 取回；未连成时走同一条 `MCPRPCBudgets.resolve`）之后，ledger 只报交付值。同一红样前后对比：修 ledger 前 **3 项红 / 5 issues**（measured cut、floor、override wins），修后 **4 项红 / 6 issues**——多出来的那一项正是"操作员看的那张表"。

- **门（本次全部实跑）**：`MCPTimeoutDeliveryTests`(12)——**活体**：真 python stdio 子进程睡 3 s，1 s 预算必须在 ~1 s 掐断并在错误里写 `1s`（实测 cut 通过）；同一个 stub 在默认预算下必须答出来（证明"放宽"没有把任何东西收紧）；预算解析逐值 30/300、7/11、3/4、−5→1、100000→600；wire 三条域外值 + 一条非数字各自 `-32602` 且点名，并断拒了之后 `endpoint/list` 为空；扫描面先自证再断言消费侧 `seconds: 15` / `milliseconds(15000)` / `ContinuousClock.now + ` 归零、两个默认值各只声明一次、旧死名字不许回来。**这条门自己踩的坑也记一笔**：第一版用 `= 30` 数默认值，而 `"= 300"` 里含 `= 30` ⇒ 一条**假红**；判据要照整行形状匹配（`TimeInterval = 30\n`）——扫错形状比不扫更糟。
  新探针 **25-mcp-timeout-budget**（活体 HTTP，`bash scripts/probes/run.sh 25`）：绿 = **11 passed, 0 failed, 4 measured, 0 known-open**——`$bridge/status` 公布 30 / 300；`tool_timeout_sec:-5` 在 **0 s** 给出 `-32602` 并命名 字段+区间+原值；带 `startup_timeout_sec:12` 连一个真 stub 后 `endpoint/list` 把 12 与纹丝不动的 300 并排吐出；随后 `/health` 与 chat 代码字都活着。

- **入账 / 仍未验证**：全量 `make test-clt` = **2912 tests / 523 suites** 绿（上一提交 `bbfa883` 记的基线是 2880 / 518）；`audit` 全绿（Class-J 现 47 个本地 suite 名可解析）、`docs-check` root **50566/50668** 且 files-with-@Test 283、`anchor-check` 37/0 drift、`format-check` 零改写。AGENTS.md **不加条目**：按 § Open 末尾既有规则"Resolved items 不在此重述（名字在 CHANGELOG.md）"，这条已解决，只留名字。仍未验证：经 HTTP 的 `tools/call` 那一跳会先撞 MCP 审批闸（`routeToolCall` → securityGate，无 broker 时 `.ask` 直接拒），所以"在 HTTP 之上按预算掐断一次慢调用"只有 client 层的活体证据，探针明说而不假称；GUI Settings 也没有这两条 knob 的入口（`MCPEndpoint` 目前只由 `$bridge/endpoint/connect` 构造），要不要在 Settings 给出可编辑项留人拍板。

**10-21 一个查无此 id 让会话沉默了 300 秒——404 之后没人再问第二句**(P0 行为不一致 / 执行链) — **活体证据（本机）**：`POST /v1/chat/completions` 与 `/v1/models/evaluate` 发 `no-such-org/no-such-model-ocoreai`，ModelScope 0.2 s 就答了 404（`{"Code":10010205001,"Message":"获取模型目录树失败，信息：record not found"}`），`MLXBridge.loadFromHubWithFallback` 却把同一个请求继续交给 HF 客户端，此后 **300 s 无任何响应**，id 卡在 `EnginePool.loadingModels`，而同机 `/health` 一直 200——一次下载把机上别的会话挤掉了。同一场还量到网络事实：`curl` 打 `huggingface.co/api/models/<存在的 repo>` 8 s 无回音（`HTTP=000`），ModelScope 则 0.18 s 给出真 404。

- **为什么不给整条下载加截止，而是先问一句**：真下载本来就要几分钟，那正是用户在等的东西；「这个 repo 在不在」却是廉价可判的——可达的 hub 回 `/api/models/<repo>` 远小于 1 s，被墙的永远不回。于是兜底之前先探一次：happy path 多花 ~1 s，换掉这条网络上几分钟的沉默；**已经在流的字节一个不砍**。

- **`Engine/HubReachability.swift`（新）**：`apiURL`——ModelScope `api/v1/models/<repo>`，HF `<endpoint>/api/models/<repo>` 且 endpoint 取 `HFMirrorPolicy.current()` ⇒ 配了镜像就探镜像；`classify` 逐值——2xx 与 401/403 → `.present`（鉴权挑战不许把「带 token 就能拉」的东西判成不存在）、404/422 → `.absent(status)`、429/5xx/传输失败 → `.unreachable(reason)`；`probe` 用 ephemeral session + 8 s 硬窗口，从不 throw——问不到本身就是答案。两个 endpoint 走同一条规则：先认 operator 的镜像杠杆（`MODELSCOPE_ENDPOINT` / `HF_ENDPOINT`），再去 canonical；域名不在这里拼——**既有门 `ModelScopeEndpointSourceTests` 当场把本文件第二份 `www.modelscope.cn` 字面量拦下来**（www 也能解析，所以这种第二拼写 normally 能活到有人拿它去问一个下载器从来不用的主机），改为接 `ModelStore.modelScopeDefaultBaseURL`；新增断言把这条链接钉住：guard 文件里 0 个 `https?://` 字面量，且必须出现那个单一真源。

- **「问不到」不是「不存在」**：新增 `AppError.modelUnavailable(modelId:reason:)` → 503，正文点名两个 hub 各自的下落并把 `HF_ENDPOINT` 写成药；404 只留给 hub 真答了的那一半。把 timeout 说成 404，等于让被墙网络上的调用者去改模型名。

- **顺手抓到探针自己的洞**：JSON 编码器把 `/` 输出成 `\/`，第一版 §4 直接子串扫 body，于是两条「refusal 必须点名 id」的断言在 body 明明点名了的情况下 FAIL。判据要照 wire 的样子比（`tr -d '\\'`）——门红在错地方比不红更糟。

- **同一台机上还有第二份兜底，但它不在本机的车道（登记，不臆修）**：`EnginePool` 的 FM 块里是同款 hub fallback（无 probe）。这不是推测：CLT SDK 26.5 的 FoundationModels `-user-module-version 1.5.2` ⇒ `canImport(FoundationModels, _version: 2)` 为 false（本机 `swiftc` 打印 `FM_V2_FALSE`），SDK 27.0 声明 2.0.68.1.402 才为 true（同机打印 `FM_V2_TRUE`）。与既有 CoreAI/macOS-27 同类项同口径：不改、不宣称已修，进 AGENTS.md § Open。

- **门（三层，全部本次实跑）**：`HubReachabilityTests`(20)/4 套——classify/apiURL 逐值、`.absent` 与 `.unreachable` 必须不同、端口 1 立拒证「快且不 throw」；扫描面先自证（正例命中 + 形近负例不命中：`probeTimeoutSeconds` 引用不算调用、`loadFromHub(provider…)` 不算兜底、UI 显示字符串不算选路），再断言 `HubReachability.probe(` 全仓恰好 1 且只在 `MLXBridge.swift`、兜底下载必须在 guard 之后（家自身的形状是「先选 provider → 再问 → 才下载」，判据看下载那一跳）、每个「挑另一个 hub」的位置要么被问过要么在 FM-only 区内，且 FM 区恰好 `EnginePool.swift`。**红样**：把兜底下载挪到 guard 之前 ⇒ `HubGuardPlacement` 4 项里 3 处断言红（`fallbackSitsBehindGuard` + `noUnguardedFallback` 两条）。
  探针 **23 §4** 由 xfail 转硬门：30 s 内必须给出 404/503 且点名 id，503 还须点名两个 hub 与 `HF_ENDPOINT`。绿：两条都是 **8 s / HTTP 503**，随后 `/health` 与 chat 代码字都活着；整支 `10 passed, 0 failed, 4 measured, 1 known-open`（同一支修前是 7 passed + 2 known-open 的沉默）。
  新探针 **24-hub-existence-gate**：`.present` 这一半没法拿真 hub 验（HF 在这台机上不通），于是自带 stub hub（`/api/models/<repo>` 答 200、其余 404），`HF_ENDPOINT` 指过去。绿 `7 passed, 0 failed, 3 measured`：stub 日志先证明「引擎确实问了」`/api/models/<repo>`，其后紧跟 `/revision/main?` 与 `/tree/main?recursive=true`——闸门放行、请求进了 hub 客户端；再把 stub 杀掉，同一个 id 立刻（0 s）翻成 503。**一个 id 两种判决，由 hub 的回答决定，而不是由调用者等了多久。**
  余下那半格（登记 § Open）：这条路上没有负缓存，重试同一个死 id 每次再付一次窗口（实测 8 s → 8 s）。

**10-21 一个合法的 LoRA 请求把整台机器带走了——崩溃点在上游一个 `as!`，而它被「根本没接上」盖着**(P0 行为不一致 / 上游偏离) — **活体证据（本机冷进程）**：`POST /v1/models/evaluate` 发 `{"model":"mlx-community/gemma-4-e2b-it-4bit","dataset":["The quick brown fox …"],"batch_size":1,"max_batches":1}` 得到 `curl: (52) Empty reply from server`，进程 `Trace/BPT trap: 5`；`POST /v1/models/train` 发两条 10-token 合法样本跑 2 iter，得到 HTTP 200 后 `transfer closed with outstanding read data`，随后 `/health` 不再应答——机上别的会话一起没。崩溃报告逐帧点名：`Swift runtime failure: type cast failed` → `dynamic_cast_existential_1_unconditional` → `static LoRATrain.loss(model:inputs:targets:lengths:)`，也就是 pin `48114eedf` 的 `LoraTrain.swift:165` `let model = model as! any LLMModel`：这个 checkpoint 经 `VLMModelFactory` 装成 `Gemma4`，不 conform ⇒ 必炸。

- **崩溃底下还压着一层「没接上」（同一跳挖出来的第二条）**：两端点原先走 `getMLXModelAndTokenizer(modelId:)`，它只看**是否已驻留**；`/health` 报 `loadedModels: 0` 时，它对 `/v1/models` 自己广告的那个 id 答 `Model not found`，而同一个 id 在 `/v1/chat/completions` 正常答。**这两条端点从来没走到引擎，所以崩溃一直看不见**——先把解析修通，崩溃才露头。P0 常是两层叠着：修掉一层不等于修完。

- **修法（三个家）**：① `EnginePool.ensureModelLoaded(modelId:)` 从 `acquire(model:)` 里提出——lazy-load 只有一个家，chat 与 LoRA 同路；② `EnginePool.mlxContainer(modelId:)`：要模型的面统一走它，错误按真实原因分层（不存在 / 还在载 / 没有 MLX 车道），并把 `getMLXModelAndTokenizer` 删掉（改完全仓零调用者——「只看驻留」的取法就是下一次同类 bug 的入口）；③ `Models/LoRAModelSupport.swift` 把损失里那句 `as!` 换成入口处的 `is`（同一个判据，可恢复的结果），`Models/LoRASampleDomain.swift` 管「每条样本 ≥2 token」——上游 #683 只给 `train` 加了预检，`LoRATrain.evaluate` 至今没有。

- **上游裁决**：mlx-swift-lm `bb0d5b0`（#683，10-20）加的是样本长度预检，`as! any LLMModel` 原样留着 ⇒ 这次没有可消费的上游答案，本仓在自家缝上补。**pin 本次不动**：#683 唯一能给的 train 侧预检我们已在两面自补且口径更细（点名 `dataset[0]` 与 token 数），单为它 bump 收益不足；「差 1 个提交」的窗口记在这里，留给下次带消费价值的 bump 一起走。

- **门**：新探针 **23-lora-seam-honesty**（活体硬门）。绿：`7 passed, 0 failed, 4 measured, 2 known-open`——refusal 必须命名所需能力、train 流必须以 `error` chunk 收尾、`/health` 与 chat 代码字都得活着。红样（只把 `LoRAModelSupport.rejection` 第一行塞 `return nil`）：`2 passed, 5 failed`，`chat turn did not return the code word after LoRA (HTTP 000)`——原缺陷原样复现。静态 `LoRASampleDomainTests`(7)/2 套：train 与 evaluate 各**恰好 1** 处样本闸、各**恰好 1** 处能力闸（新增第三面不设闸即红）、`enginePool.mlxContainer(modelId:` 恰好 2、`getMLXModelAndTokenizer` 在 wire 层与 pool 层都必须为 0、lazy-load 必须共享同一条（`try await ensureModelLoaded(modelId: modelId)` 恰好 2），每条模式先自证「还看得见自己要禁的形状」再扫。

- **公开口径（xfail，已量）**：解析不出的 model id 在 `/v1/models/evaluate` 与 `/v1/chat/completions` 上 **≥25 s 无任何响应**（`/health` 仍活）——两面同走 `EnginePool` 加载，等的是 hub 解析超时，wire 上没有 deadline。加超时还是负缓存待拍板，探针 23 以 xfail 钉住这个口径（红样跑里它显示 `after 0s`，正是「服务器已死」与「解析慢」在客户端同形的原因，也是这句要写下来的理由）。

- **入账**：AGENTS.md § Wire DTO 的域条补一句「域外的不止数字：上游一个 `as!` 也能让请求 owning 进程——能力问题在入口用 `is` 问一次」；为付字节压掉两处更长的叙述（CLT SDK 配方的细节回到 `docs/agent/build-gate-reality.md`、`print()` 条去冗），root 现 **50665/50668**。仍未验证：GUI 端到端零验证；`LoRASampleDomain` 的 1-token 规则在本机被能力拒绝对在前，只有单元测试钉住（探针明说，不假称量过）。

**10-21 一句「这段文字大概多少 token」，仓库里有十七处在算、三种答案**(P2 重复抽象 / P0 行为不一致) — 起因是给会话行记自己的内容 token 时顺手核了一眼 `/v1/count-tokens` 的启发式，`git grep`（`5c13f6a`）当场给出 **17 处 / 9 文件 / 3 条公式**：CJK 字节律（`> 1.5 ? 3 : 4`）复制了 5 份（`ChatHandler`、`AnthropicMessagesHandler`、`CompletionsHandler`、`EngineInference`、`ConversationCompaction`）；「长度 ÷ 4」跑了 11 次（`SchedulerActor.swift:356` 的 `utf8.count / 4`——那是决定请求进不进得来的数，外加 perception 预算 10 处按**字符数**除 4）；最后一份是 GUI `ChatState` 的 `utf16/3`，也就是输入框上那条上下文表显示的数。同一段文字，看哪条电路在问。

- **方向性最坏的是 GUI 那一份**：它自称 CJK-aware，实际给每个 CJK 字符记一个 UTF-16 单元 ⇒ `你好世界` 在上下文表上是 **1**，字节律是 **4**。少报是唯一致命的方向——它告诉用户「窗口还有地方」。

- **两条门在互斥的精确值上同时全绿**（这才是非修不可的那一件）：`EnginePoolBehavioralTests` 的 `TokenHeuristicTests` 钉 utf16/3（`40 字符 → 13`），`AnthropicInputTokenEstimateTests` 钉字节律（40 ASCII → 10），两套一起绿；而修前的 `EnginePoolBehavioralTests:95`（该套件现已删除）注释还写着 `// Production: max(1, text.utf8.count / 3) — uses /3, not /4`，被测函数算的却是 utf16。**满屏的绿不保证线上算的是哪一个数。**

- **修法（一家一个口径）**：新 `Sources/ocoreai/Models/TokenEstimate.swift`——`contentTokens`（可以返 0，逐行相加的家：perception 预算、compaction 每行）与 `promptTokens`（String / [String] / [Message] 三重载：比率取在整段正文上，非空 ≥1，返 0 就是调用方拒单的信号）。17 处旧式全删、19 处调用改接 10 个文件；删 `estimatePromptTokensFallback`、删 `ChatState.estimateTokens`；`SchedulerActor.swift:356 estimateInputTokens` 留一行委托，准入的口径名留在原地。

- **门（`TokenEstimateTests` 7 条 / 2 套）**：精确值，含把 GUI 读数**纠正**而非保留（`你好世界` 1→4、40 ASCII 13→10）；`noSecondFormula` 是扫描钉子，四条**正则**而非字面量——旧拷贝把量写在局部变量里（`utf16Count / 3`），`"utf16.count / 3"` 这种子串扫会直接走过去。每条先用一行合成 offender 自证「还看得见自己要禁的形状」，再要求全树除家之外 0 命中；下限自带（≥150 个 Swift 文件、家里 `? 3 : 4` 恰好 1、≥8 个调用文件）。**写门时挨的刀**：Swift Testing 打印失败表达式的操作数，`#expect` 里塞文件内容 ⇒ 一条红把 15k token 的函数体喷进 CI（会被静音的门比没门更糟），改成只报 `[String]` 路径。红样实测（往 `ChatHandler.swift` 追加一份 utf16/3）：`utf16 over 3 is back outside the home — ["Sources/ocoreai/Handlers/ChatHandler.swift"]`，其余 6 条全绿。

- **实测（`mlx-community/gemma-4-e2b-it-4bit`，`/v1/count-tokens` `tokenizer_backend: real`，模板框 10 tok 用单字符 prompt 单独量出）**：内容真值 / 本律 / utf16÷3 / 字节÷4 —— en 19 / 22 (+16%) / 30 (+58%) / 22；中文 18 / 26 (+44%) / 10 (−44%) / 19；中英混 15 / 22 (+47%) / 13 (−13%) / 16；代码 17 / 15 (−12%) / 20 (+18%) / 15；长中文 32 / 50 (+56%) / 18 (−44%) / 37。**裁决：要除几是模型词表的性质，不是文字的性质**——这个 tokenizer 会合并 CJK 对，于是 /3 一律估高 44–56%，朴素的 /4 反而在五个样本里最贴近；换一套词表结论就翻向。所以**没有换常数**：客户端在 `/v1/count-tokens` 上拿到的已经是这条规则，改数等于悄悄改公开口径；代价写进家文件头，别处不再各写一份。未决 = 从**有 tokenizer 的模型**量出 bytes/token 再按模型分档（先例 `ToolProseLedger`：量模板，不猜模板）。

- **入账**：AGENTS.md § Endpoint Promises 的 usage 条补一句「近似量一个家」（root 现 **50667/50668**，压线——下一刀必须先删后加）。绿：`--filter 'TokenEstimate|ConversationCompaction|FastPathContextWindow|EnginePoolBehavioral|CountTokens'` = **48 tests / 9 suites**。随函数一起走的两份钉（`AnthropicInputTokenEstimateTests` 折进新家、`TokenHeuristicTests` 五条）在 `Sources`/`docs`/`scripts` 里零引用，核过；`EnginePoolBehavioralTests` 文件头那句「sampling normalization, token count heuristic」也删了——它剩的那套只测 contentToString。

**10-21 `/v1/messages` 也记住会话了——登记得太快，答案本来就在自家 DTO 里**(P0 行为不一致 / P1 执行链) — 本 CHANGELOG 上面一条把「`/v1/messages` 不收会话记忆」登记成待拍板，理由是"规范没有 conversation id"。当场自查就推翻了这个理由：`AnthropicModels.swift:995` 的 `AnthropicMetadata` 早就声明了 `sessionId`（`session_id`），`AnthropicModels.swift:1056` 更已经把它映进 `request.sessionID`——**身份缝一直存在，缺的只是没人把这条面接到持久缝上**。登记前该先 grep 一遍自家 DTO，而不是只读规范：这一条不该留到人手。

- **修法（一面一面各自记账 → 两面共用一次组装的最后一环）**：`persistConversation` 从 file-private 提成 internal（会话记忆只有一个家：身份、去重、每行自己的价都在里面）；`nonStreamAnthropicResponse`／`streamAnthropicResponse` 各调一次，`sessionCompressor`、`semanticSearch` 两个参数从 `_` 改成实名并传到调用点；流式那次放在 `message_stop` 之后、`continuation.finish()` 之前——客户端不等它，行照样在流关闭前落库。

- **门（两条，各管一面镜子）**：静态 `bothFacesReachTheHop`——两面各**恰好 2** 处 `await persistConversation(`（每响应模式一处；`>= 1` 会把缺的那条响应模式藏起来）；探针 22 新增 Anthropic 一节——同一 `metadata.session_id` 三轮（两轮非流式 + 一轮流式，后两轮各重发全史）必须**恰好一行**、`message_count == 6`（3 user + 3 assistant），且流式那轮必须真到 `message_stop`（否则"根本没答"会被当成持久成功）。

- **实测（同会话）**：绿——`one metadata.session_id makes one session row on the Anthropic face — one row id=1969 holds message_count=6 (3 user + 3 assistant, both response modes) token_count=28`，探针 22 `10 passed, 0 failed, 6 measured, 0 known-open`；`--filter 'SessionTranscript|PersistHop|PromptTokenAccounting|Anthropic'` = **127 tests / 20 suites** 全绿。红样（只把两条 persist 调用注释掉）：静态**恰好红那一条** `both HTTP faces reach the one persist hop … Expectation failed: calls.count == 2`；线上**恰好红那一条** `two accepted /v1/messages turns wrote no session row — this face has no memory`，探针 `9 passed, 1 failed`、exit 1。

- **入账**：§ Open 那条 `/v1/messages` 缺口删除，改写进 Endpoint Promises 的规则——兼容面复用的不止组装与 steer，**会话记忆也算同一缝**（一面写一面不写 ⇒ `/sessions`、FTS、GUI 只看得见一条线），身份两面同口径 `session_id`／`metadata.session_id`。留在原地没做的：键缺席时一请求一行（无身份即无会话可长），这句 `/sessions` 上没写，属公开面措辞，与 `usage` 口径一并裁；GUI 端到端仍零验证。root 现 50495/50668 字节。

**10-21 门禁补上最后一格：`XxxTests`(N) 括号里那个数也是 claim——五条已经漂了**(P0 文档失真 / P3 可观测性) — 起因是给 § Open 添一条新缺口时顺手核了一眼数字：AGENTS.md 写着 `PromptTokenAccountingTests`(6)，文件里 7 条——上一个提交刚加的那条 `everyHopReportsOnePrompt` 改了代码，没人改数。

- **全扫结果**：文档里 ``XxxTests`(N)`` 形状共 12 处（AGENTS.md 9 + `docs/agent/closed-items-log.md` 3），**5 处与文件不符**：AGENTS.md `CapabilityMeasurementHonestyTests`(15)→16、`PromptTokenAccountingTests`(6)→7、`ToolProseLedgerTests`(11)→15；closed-items-log `V1EndpointCatalogTests`(6)→9、`MetalShaderLibraryTests`(7)→**6**（最后一条是向上虚报：宣称的门禁覆盖比文件里实际存在的还多一条）。

- **根因**：`make docs-check` 会跑 `<!-- claim: … -->`（可执行数字）、会验 suite 名是否存在（P6）、会验 file:line 锚点（P3），**唯独没人读括号里的条数**——不变量 1 的原话：一个数只要没人 re-grep 它，它就漂；而这三处数字恰恰是"覆盖率"的说法，最容易在加测试的那天过期。

- **修法（`scripts/agents-md-contract.sh` 新增 P11）**：括号数字必须等于 `Tests/**/<Name>.swift` 里 `@Test` 声明数——口径就是 `swift test --filter <Name>` 报的口径（参数化 `@Test(arguments:)` 记 1 条、携带 N 个 case，实测：21 行 `✔ Test` + 1 条 `with 2 test cases` = `22 tests`）。扫描**自钉下限**（`OCOREAI_AGENTS_FLOOR_SUITE_COUNTS:=8`：正则哪天不再匹配，P11 直接红，不许空过——同 P1 的路子）。**日记类豁免**（`CHANGELOG.md`、`docs/agent/closed-items-log.md`）：那上面写的是"当天为真"，把历史数字改成今天的值等于改记录；契约面（root 与被路由进去的 guides）描述的是此刻的代码，所以它们的数字必须追着文件跑。

- **红→绿（同会话）**：加完 P11 当场红，并逐条点名——`P11 5 numbered suite claim(s) do not match Tests/: AGENTS.md CapabilityMeasurementHonestyTests(15) — file holds 16; … docs/agent/closed-items-log.md MetalShaderLibraryTests(7) — file holds 6; …`；改完三处 AGENTS 数字（全是等长数字，不动 root 预算）后 `suites numbered-claims=9/9 ok (floor 8)`，`make docs-check` ✅；`make anchor-check`（37 锚点）、`make audit`、`make format-check`（0 重排）同轮全绿。

- **同时登记的一条新缺口（未修，不臆修）**：`/v1/messages` 收下 `sessionCompressor` 与 `semanticSearch` 两个依赖却都写成 `_`(`AnthropicMessagesHandler.swift:51`) ⇒ 这条兼容面**根本不写会话记忆**：`/sessions` 无行、FTS 搜不到，OpenAI 面三条全写（探针 22 实测）。为什么不当场修：Anthropic 规范里没有 conversation id（只有 `metadata.user_id`，那是用户不是会话），拿什么当身份是接口形状的决定；门已写进 § Open——同 key 两轮 `/v1/messages` 后读 `/sessions` 看有无行。root 现 50662/50668 字节。

**10-21 一条 `session_id` 真正成一个会话：一行归一轮，每行只记自己那条消息的价**(P1 执行链/状态 + P0 行为不一致) — 本节早前登记的两件事当日修完，写门时又在这一条腿上挖出第三件。为什么不留人拍板：外部 key→行 的映射收在服务端内部，**线上一个字段没动、`/sessions` 的形状没变**，迁移是 `ALTER TABLE … ADD COLUMN`（旧行 key 为 NULL，照旧可读）——改的是内部记账，不是接口形状；真正需要人拍板的是"客户端该持有整数 id 还是服务端自己映射"，而答案早就写在代码里：整数 id 从不回吐，所以服务端必须自己映射。

- **① 身份（`Handlers/ChatHandler.swift:2013` `persistConversation`）**：旧规则是"`session_id` 能解析成 `Int64` 就复用那一行，否则新建"，而 HTTP 面从不发整数 ⇒ 每请求一行（本日两轮红样：id 1936/1937/1938、1956/1957/1958，各 `message_count=2`）。新增 `sessions.external_key TEXT` + `idx_sessions_external_key`（`SQLiteStore.swift:585`，与 `workspace_directory` 同一条 probe-then-ALTER 路），`SQLite/SessionCompressor.swift:155 resolveSession(externalKey:modelId:ttlDays:)` 三条臂按既有契约排序：数字 key 命名一行真存在 = 那一行（老客户端行为不动）；key 见过 = 它当初那行；否则建行并记住 key。**与 `modelId` 同键**，因为引擎本就按 `SessionPool.poolKey = modelId:conversationId` 分会话——同一个 key 换模型是两条转写，不是一锅。数字 key 命名不存在的行也不再往不存在的爹上写 `messages`。

- **② 去重（新 `SQLite/SessionTranscript.swift`）**：客户端每轮重发全史，而 `messages` 只追加 ⇒ 一轮真正新增的 = 已存行与本轮转写的**最长公共前缀之后的尾巴**（`SessionTranscript.swift:52 newEntries`）。四种形状各有说法：首轮全新增；普通轮只加尾巴；原样重放加 0 条（幂等）；rewind（客户端比库里短）加 0 条；改写过历史则从发散点往后追加——这是只存追加表能给出的最诚实答案，也正是引擎 `canReusePooledSession` 拒绝复用改写过会话的 KV 的同一条理由。**两侧必须先化成同一种形状**：库里插着 assistant 回复，客户端列表按持久规则没有，逐位比会在第一条回复处停下、把之前每一轮重写一遍——同一个缺陷小一号，门 `shapeFilteringAgreesOnBothSides` 钉住它；角色集合只在 `SessionTranscript.swift:39 persistedRoles` 说一次，SQL 侧用它，不许再手写第二份。

- **③ 计量（每行记自己）**：`tokensPerMsg = promptTokens / userMsgCount` 删掉。行改记这条消息自己的内容 token：`Tokenizer/TokenizerManager.swift:221 countContentTokens(text:)` = `encode(text:addSpecialTokens:false)`（**不带模板框**，测的是内容），经 `Engine/EnginePool.swift:473 countContentTokens(modelId:text:)` 取；这个模型没有 tokenizer 时返 nil，调用方退回 `estimatePromptTokensFallback` 字节启发式——替换依旧可被检出（`/v1/capabilities` 的 `tokenizerBackend: real|heuristic` 已公布是哪一路）。assistant 行留 `outputTokens`：那本来就是这一条回复生成的量，且含模型自己产出的 reasoning，内容 tokenizer 看不见。`SQLite/SessionCompressor.swift:175 touch` 在解析到既有行时把行里的 `token_count` 读回 `sessionTokenCounts`——否则进程重启后那条长会话的裁剪阈值从 0 重新数起（128k 阈值会以为它很轻）。

- **写门时挨的第三刀（同一族，浅会话看不见）**：读已存转写最初写作 `limit: incoming.count + 8` 且**不过滤角色**——库里一半行是回复，深会话里这样读回来的是**短了的头**，重叠规则就把缺的那几轮当"新的"再写一遍。改成 SQL 侧按 `persistedRoles` 过滤，`limit` 就恰好等于调用方数的条数（`SQLite/SessionCompressor.swift:424 transcriptAscending`，`ORDER BY created_at ASC, id ASC`，同微秒内以 id 定序）。红样实测（只把过滤摘掉，其余不动）：**恰好红那一条**——`the reader shorted the head — asked for 13 conversation rows, got 7; the rest would be stored a second time`，22 条里其余 21 条全绿；探针 22 只有 4 轮，余量正好盖住 ⇒ 这类缺陷只能靠深会话单元测试逼出来，线上看不见（不变量 1 的又一例：门要问的是这件事本身，不是最容易问的那一件）。

- **门**：新 `Tests/ocoreaiTests/SessionTranscriptTests.swift` **15 条 / 3 套**——重叠规则（首轮/普通/重放/rewind/改写/两侧同形/角色集，全精确值）；SQLite 身份（3 轮 1 行 6 消息 `token_count=24`、key×model 分区、数字 key 诚实、**身份活过重启**、深会话看全头）；静态钉子（`ChatHandler` 代码行里再没有 `tokensPerMsg`、`resolveSession(` 与 `transcriptAscending(` 各恰好 1 处、`limit: incoming.count)` 精确、角色集只有一个家；扫描是**注释感知**的——文档可以说出被禁的写法，代码不行）。探针 22 从 xfail×2 改成**硬门 8 绿**（`8 passed, 0 failed, 6 measured, 0 known-open`），实测：`one session row id=1960 holding message_count=6 token_count=25`、`the largest user row costs token_count=7 for a 33-character message`、新加的再发全史一节 `4 turns on one key, 4 user rows, nothing duplicated`。红样（退回 `createSession` + 整段 prompt 摊派）：探针 22 `3 passed, 2 failed`，`id=1956/1957/1958 message_count=2 token_count=699`。

- **入账**：AGENTS.md § Open 那条 `session_id` 缺口按已解决删除（root 现 50312 字节 / 上限 50668）。留下一条没做的诚实边界：会话总量自此**只数消息内容**，不含系统提示与模板框——这是口径选择不是缺陷，`SessionCompressor.tokenThreshold` 与它比的是同一口径的数；`/sessions` 上没写这句话，写它属于公开面措辞，待与 `usage` 口径一并裁。

**10-21 一条 `session_id` 在 HTTP 面上不成一个会话**(P1 执行链/状态 / 不变量 2) — 写探针时直接量出来的两件事，同一次实测（`mlx-community/gemma-4-e2b-it-4bit`，同一 `session_id: "MEMPROBE-…"` 三轮）：

- **① 每请求一条 sessions 行**：`ChatHandler.persistConversation` 把 `session_id` 解析成 `Int64` 才复用行，否则 `createSession` 新建一行 ⇒ 三轮造出三行（实测 id 1936/1937/1938，各 `message_count=2`）。而 HTTP 面**从不把整数 id 回吐给客户端**（`/sessions` 只读列，`POST /sessions` 不存在），所以真客户端（UUID、`PROBE-…`）的会话在持久层没有"可以长大的那一行"：`/sessions`、`/sessions/:id/memory`、`/sessions/search`(FTS) 与 GUI 的会话列表看见的是每请求一张快照，而不是同一条对话。引擎的 session pool 记得住历史，持久层记不住——两边各说各话。

- **② per-message `token_count` 记的是整段 prompt**：`tokensPerMsg = promptTokens / userMsgCount`，于是一条 34 字符的 user 消息存成 `token_count: 705`（705 = 本轮整段渲染提示词，含 ocoreai 自己的系统提示与模板；同轮 `usage.prompt_tokens` 正是 705）。`SessionCompressor` 拿这些行的累加与 `tokenThreshold`（默认 128k）比较来决定何时裁剪历史，`SessionView.swift:136` 又把 `session.token_count` 当作会话大小显示给使用者——同一段历史每轮被重新计一次费。

- **为什么不自己拍板改掉**：修法要动人家的持久层形状——外部 key→行 的映射需要一次 schema 迁移（加 `external_key` + 唯一索引，并决定旧行怎么办），per-message 计量需要在这条腿上接真 tokenizer 并给出无 tokenizer 时的降级说法（不变量：替换必须可被检出），而"HTTP 客户端该持有整数 id 还是服务端自己映射"是接口形状的决定。按规矩登记，不臆修、不宣称已修。**（当日闭环：见本节顶部那条——映射收在服务端内部，线上字段与 `/sessions` 形状一个没动，迁移是加列；当年那个待裁的问题其实当时就有答案：整数 id 从不回吐，所以服务端必须自己映射。）**

- **门（新探针 `22-session-memory-identity.sh`）**：前提硬门先站住——三轮必须 200、`/sessions` 必须答、必须出现新的 sessions 行、`/sessions/:id/memory` 必须答出该轮那条 user 消息（任何一条不成立就是 FAIL，而不是安静地"没测到"）；两条结论当时各记一次 `probe_xfail open`（XFAIL 计入 known-open，退出码 0），**任一条修好就变 XPASS 并报失败**，逼着删 xfail 与关 § Open。实测：`3 SQLite sessions for one session_id … across 3 turns`、`a 34-character user message is stored with token_count=705`。跑完用 `DELETE /sessions/:id` 把自己造的行清掉（顺带验了删除路由）。**（当日：两条 xfail 已删、改成硬门，探针另加"再发全史只存一次"一节；§ Open 那条已关。）**

- **写门时挨的第二刀（同一族）**：清理钩子里用 `tr -cd '0-9\n'` 从行摘要里抠 id，把 `message_count=2`/`token_count=706` 的数字也粘了上去，`probe_atexit` 后来 eval 时炸成 `syntax error near unexpected token 19372707`。id 一律 `sed -nE 's/.*id=([0-9]+).*/\1/p'` 取，且在登记钩子时就压成一行。

**10-21 线上修好了，同一条腿还有两个出口没跟上：一个提示词只能有一个数**(P0 行为不一致 / P1 可观测性) — 4b706ef 把 `prompt_tokens` 算成整段渲染提示词，改的是**发给客户的那一行**。同一轮的两个出口仍传旧值：OpenAI 流式的 metrics 调用与落库仍是 `observedPromptTokens ?? promptTokenCount`（本轮 prefilled 的尾巴），Anthropic 两面的 metrics 仍传 `inputTokenCount`（生成前的估计）。于是一条热轮同时说着三种话：客户端 730、`/metrics` 的 `ocoreai_inference_tokens_total{kind="prompt"}` 加 20、会话表里按 730 与 20 摊出来的 per-message `token_count`——而 128K 的会话压缩阈值（`SessionCompressor.tokenThreshold`）正是从这个累加读出来的。

- **为什么满仓皆绿**：4b706ef 的静态钉子只数 `renderedPromptTokens(` 的出现次数，禁的是 wire 那一跳的写法（`inputTokens: observedPromptTokens ??`）；metrics 那一跳换了变量名，落库那一跳连字段名都不同（`promptTokens:`）。**修了一条腿不等于修了这条腿的所有出口**——门要数出口，不能只数修过的地方。

- **一个数，三个出口**：两面各在生成结束处算一次 `observedInputTokens`（`ChatHandler.swift` 流式/非流式、`AnthropicMessagesHandler.swift` 两模式），wire／metrics／落库同用它。生成**之前**的判定照旧用估计（`promptExceedsContextWindow`、`ContextStatusStore`、Anthropic `message_start` 与 admission）——那一刻还没有可测的数，这是分工不是遗漏。

- **门**：`PromptTokenAccountingTests` 新 `everyHopReportsOnePrompt`（两面参数化）——每面 `renderedPromptTokens(` 恰好 2（每响应模式一次），`observedInputTokens` 恰好 8（OpenAI：声明+wire+metrics+落库 ×2）／6（Anthropic：声明+wire+metrics ×2），并禁掉两处已知的"另一条腿"写法；用精确值而非 `>=`，出口凭空多一个或少一个都会改变这道门覆盖的东西。活体加在探针 01 §E：冷轮起会话 → 同会话**流式**热轮（`stream_options.include_usage`），断言线上 `prompt_tokens` == `/metrics` prompt 计数器这一轮的增量，并与日志 `reused C of T` 的 T 对齐；这一轮若没复用（whole==suffix，两数天然相等）就按 `OCOREAI_REQUIRE_PREFIX_REUSE` 判失败或明说"这轮没测到那件事"——不许安静退化成空判。

- **写门时自己挨的一刀**：§E 第一版在冷启动轮**之前**就读计数器，增量于是盖住两代生成（708+730=1438）而报 FAIL。计数增量必须只夹住被测的那一代，这条已经写进 §E 的注释。

- **红样（逐条只红该红）**：只把流式 metrics 退回 `observedPromptTokens ?? promptTokenCount` ⇒ 探针 01 恰好红 §E 那条，并把缺陷原话说出来：`streaming turn said prompt_tokens=730 on the wire while /metrics moved by 20`；静态门同一退回态红 2 条（`observedInputTokens` 8→7、禁词复活），Anthropic 那条用例仍绿。绿样：`wire said 730, /metrics moved by 730`，探针 01 **18 断言 / 0 失败**。

- **登记（不宣称已修）**：落库那个数虽然与线上同源于一次记账，但 `persistConversation` 把整轮提示词摊给本轮的 user 行（`tokensPerMsg = promptTokens / userMsgCount`），既不是每条消息自己的 token（摊整段会把历史重复计入每一轮，令 128K 阈值提前触发），摊尾巴又会让阈值几乎不触发。per-message `token_count` 应当量它自己那条消息——真要改需要在这条腿上接真 tokenizer 并给出无 tokenizer 时的降级说法，留作下一轮。

**10-21 `prompt_tokens` 报的是本轮付过的钱，不是提示词的长度——一个分解量比它的整体还大**(P0 上游偏离 / OpenAI 兼容) — 写探针 21 时被两个数字撞了头：三条热轮在 `/v1/chat/completions` 上分别答出 `{"prompt_tokens": 30, "cached_tokens": 949}`、`44/949`、`54/949`。分解量 (949) 比它所分解的整体 (30) 大到 31 倍，规范上不可能；按上游自己的加法（`cached + prefilled`）那是一条 979 token 的提示词，报给客户 30——整条复用前缀从客户记账、预算、限流的依据里消失了。

- **规范与上游两头都站在总量一边**：OpenAI `prompt_tokens_details` 是 `prompt_tokens` 的 breakdown（故 `cached_tokens ≤ prompt_tokens`），vllm/sglang 同形；上游 `GenerateCompletionInfo.promptTokenCount` 自己的注释就写着 "counts fewer tokens than the rendered prompt"（`Evaluate.swift:2921-2926`），并把总量算成 `cached + prefilled`（`totalPromptTokenCount`，`Evaluate.swift:2984-2987`），mlx-swift-lm 发 usage 时用的正是总量（`MLXLanguageModel.swift:1377`/`:1519`/`:1721`）。我们发的是差额。**证据早就在仓里**：探针 19 已提交的 `prompt=12 cached=1458` 就是同一个形状，当时被当成"复用生效"记下来了——一条断言只比 `cached` 与日志、从不问同轮的 `prompt` 是多少，就永远看不见这个矛盾（不变量 1：门要钉得住自己那句前提）。

- **一个家**：`Models/OpenAIModels.swift PromptTokenAccounting.renderedPromptTokens(observedPrefilled:cachedPromptTokens:fallback:)` = `prefilled + max(0, cached)`；`observedPrefilled == nil`（guided/FM/CoreAI 这些没有 `.info` 的腿）交回整段估计、**绝不再加一次 cached**，否则把没观测到的东西报成观测到了。四个面同一处调用：OpenAI 非流式（`ChatHandler.swift` `observedInputTokens`，同一个数同时喂 metrics 与落库）／OpenAI 流式 usage chunk／Anthropic 非流式／Anthropic `message_stop`（Anthropic `.done` 元组第 7 位此前被 `_` 丢掉，现接住）。`Usage` DTO 不动——它只管编码不管记账，故 09-12 的 `PromptTokensDetailsCachedWireTests`（`input: 2500, cached: 2048`）原样成立。

- **顺手量出第二处偏离（P1 执行链/状态）**：identical-call 循环网是**进程级**的——`executionHistory` 只按 (tool, args hash) 记，四个不同会话各调一次 `sleep(duration_ms:8000)`，第四个就被判 `[tool_error: Execution loop detected: sleep] FAILED — its effects do not exist.`（探针 21 第一版的隔离腿 1.97 s 返回这条从未执行的失败，正是被它咬的）。循环是"一个 agent 的轮次序列"的属性 ⇒ `executionHistory` 现按 `conversationKey` 分桶；没有键的入口（MCP `tools/call`、GUI 主动读盘、单测）共用 `process` 桶——有了身份就把网撤掉是更坏的答案。

- **`required` 与内置工具是两条路（实测登记，不判缺陷）**：`tool_choice:"required"` 把约束出来的调用原样交回 caller（`finish_reason:"tool_calls"`，日志里没有 `Tool call: sleep`），只有 `auto` 会走本仓自己的 `toolDispatch` 执行注册表内的工具——OpenAI 兼容面本就该让 caller 执行 caller 声明的调用。探针 11 §3c 证的是 caller-owned 那条，两件事不可互相引用；探针 21 因此用 `auto` 并写明理由。

- **门**：`PromptTokenAccountingTests`(6)（正/反值 + "无 .info 不加 cached" + 负数下界 + 编码后 `cached ≤ prompt` 的结构断言）；`ToolRegistryTests` 新 2 条（分会话互不污染／无键共用一桶）；Anthropic 那条静态钉子的文本改到新家（`renderedPromptTokens(` 恰好 2 处，且禁止 `inputTokens: observedPromptTokens ??` 复活）。红样逐条只红该红的：总量退回差额 ⇒ 红 3 条（含 `cachedOut <= prompt`）；循环网退回进程级 ⇒ 只红 1 条（`conv-B` 那条），原有 `loopDetection`/`repeatedFailuresAreLoopDetected` 与无键桶全绿；两处一起退 ⇒ 52 tests 中 10 issues／4 条测试失败。绿样聚焦 **191 tests / 37 suites / 0 失败**。

- **活体（新探针 `21-sleep-steer-wake.sh`，16 断言／3 会话／0 失败）**：control 请求 9000 ms → 10807 ms 且答出 `Sleep completed.`（前提：确实睡了）；steer 在 1.5 s 注入 → 同一轮 2651 ms 结束，`sleep` 本身 1.0860 s 返回，正文同轮带回 `Sleep interrupted by new input.` 与 `[mid-turn user steering]`（接受且送达，不是只入队）；另一会话被 steer → 本会话仍睡满 8628 ms(≥7000)。三条响应 `cached ≤ prompt` = 957/987、957/1006、957/987。这把 10-21 早晨那条「无真模型端到端」的 open 关掉了：**有工具的一轮，转向当场生效**。

- **未决（登记，不宣称）**：① 多跳轮次的 `completion_tokens` 仍只报最后一跳（`auto` 路实测两轮生成，线上 `completion_tokens=15`）——工具调用本身也是模型生成的输出，跨不跨跳累加是口径裁决；② Anthropic 面未公布 `cache_read_input_tokens`（规范里可选，没做就不加）；③ `required` 交回 caller 而 `auto` 内部执行这条不对称是否要向 vllm/sglang 的"服务端永不执行"收齐，留人拍板。

- **探针 01 的门是绿的，因为它量的就是错的那个数**：`lopsided reuse` 那条一直写 `prompt > cached ⇒ 失败`，理由写着"复用量必须不少于本轮付的钱"——它把 `prompt_tokens` 当成了「付的钱」。差额语义下这条永远绿（20 ≤ 710），总量语义下它会把每条健康的轮次判死（749 > 733）。改成 `paid = prompt − cached`，并新增 D 段把日志里 `Prefix cache reused C of T` 与同轮线上的 `cached_tokens/prompt_tokens` 逐位对上（B 段只比 cached，"只比零件、从不问整体"的门看不见整体太小——不变量 1 的又一例）。红样实测（把总量退回差额、重建线上）：**恰好红新那条**，且把缺陷原话说出来——`log says reused 710 of 730, wire says cached_tokens=710 prompt_tokens=20`；旧那条在退回态下仍绿，正说明它从来没在门这件事。绿样：`prompt_tokens is the whole the log names — OK reused 710 of 730, reused 733 of 749`，探针 01 **16 断言 / 0 失败**。

**10-21 `clock.sleep` 第一次能被本会话的输入叫醒：形状不迁移，缺的那块是身份**(P0 上游偏离 / P1 执行链) — codex `305db3808c`(#55644，10-20 17:50；已在 clone HEAD 的祖先链上) "Make pending injections interrupt agent waits and sleep"：`codex-rs/core/src/session/input_queue.rs:93` 新增 `has_pending_injection`，注入时置位(`:380`)、投喂时连 items 一起 `std::mem::take` 清零(`:401`)、等待循环读它(`:482`)。一句话 = 排在 wait **开始之前**的输入也必须结束这场等待；已被消费掉的输入不得再去叫醒后面的等待。

- **形状不迁移**：codex 需要一个标志位，因为它的 `TurnInputQueue` 同时装着 notifying injection 和 passive context，只有前者该打断。我们 `SteerQueue` 的全部生产者都是真转向（三处：`/v1/steer` `Router/ChatCompletionsRouter.swift:552`、GUI composer `UI/ViewModels/ChatViewModel.swift:203`、轮次失败回灌 `Handlers/ChatHandler.swift:852`）⇒ 没有 passive 混进来，标志位是多余的。另一半形状差异：codex 在 activity 订阅上等**变化**，我们读 `pendingCount(sessionKey:)` 的**当前深度** ⇒「等待开始前已入队」那一格天然覆盖，代价是 100 ms 节拍轮询（AGENTS.md 并发条：轮询循环只睡一个间隔，绝不睡到 deadline；先例 `EnginePoolLoadingGateTests`，反例 `waitForLoading` 曾把 8 s 的模型等成 120 s）。

- **这一刀真正缺的是身份**：`sleep` 要回答「谁的输入能结束我的等待」，而工具处理器签名 `(String) async throws -> String` 不带会话——早先这份工具诚实写着「无同形状信号，不宣称提前中断」。新增 `Tools/ToolInvocationContext.swift`（`@TaskLocal conversationKey`），**唯一设值点** = `ToolRegistry.call(..., conversationKey:)`，也就是所有投喂共同穿过的那一个咽喉；调用方交出自己已经持有的键，任何工具都不许从 model id / env / 进程级标志再推一套第二身份。全仓 6 处活 `registry.call`：引擎两条投喂路交键（`EngineInference.swift:2973` 标准路、`:4037` MTP 路，正是 `SteerQueue.drain` 的两个宿主），其余 4 处留 nil（`FMToolBridge.swift:100`、`MCPTools.swift:65`、`MCPServer.swift:154`、`ProactiveActionExecutor.swift:43`）⇒ 按不变量 2 睡满全程并报 `Sleep completed.`，不宣称打断。

- **词必须来自实测**：`ClockSleep.report(elapsedSeconds:outcome:)` 的 `outcome` **没有默认值**——给一个 `.completed` 默认 = 任何忘记传终局的调用方都默认谎称睡满，那是比实际更短的等待。工具描述同步改写，两个终局各报什么写清楚；`SystemSleepBackend` 睡满之后不再回头看 `wakeCheck`（最后一刀里才到的转向照旧走正常 steer 缝进下一轮）。

- **红样实测（三条，逐条只红该红的）**：① 把 `wakeCheck` 从「每刀之前」挪到「每刀之后」⇒ 只红 1 条（`先查后睡`：实测 102 ms vs 界 50 ms），其余 31 条绿——这条界就是专门用来区分「先查」与「先睡」的；② 拆掉 `ToolRegistry.call` 里的 `withValue` ⇒ 红 3 条，其中端到端那条真睡了 **30.969 s** 并答出 `Sleep completed.`，正是这条线上最坏的失败形状；③ 标准路不交键 ⇒ 静态门红 2 条（`lanes.count == 2` 与该窗口内的 `conversationKey:`）。绿样：**32 tests / 11 suites / 0 失败**（`--filter 'Sleep|Clock|ToolInvocation|EngineToolLanes'`，1.035 s）。门 = 新 `Tests/ocoreaiTests/SleepSteerWakeTests.swift`（正向×2、反向、隔离、缺席、真时钟节拍×5、chokepoint 传播×3、线上词形×2、静态接线×1）+ `ClockToolsTests` 改 4 处（终局词、`checks == 1`：一次都不查 = 这个 backend 根本没接转向）。

- **这道门自己被自己的前提咬了一口（记下来）**：静态接线门最初找子串 `registry.call(`，只数到 1 条——MTP 路写的是 `toolRegistry?.call(`，那个 `?`（以及大写 R）让子串漏匹配。若断言当初写成 `>= 1`，「少扫一条投喂路」会永久伪装成正常；写成 `== 2` 才把它逼出来，随后改成正则 `[A-Za-z]*[Rr]egistry\??\.call\(`（不变量 1 的又一例：扫描必须钉住自己的命中数）。

- **未验（写出来而不是藏起来）**：链路只证到「工具面 + 引擎两条投喂路的接线 + 真时钟节拍」，**没有**一次真模型端到端（要模型自己决定调 `sleep`，本机没有稳定复现路径）⇒ 登记 open，不宣称已交付到线上；GUI 侧同样零验证（既有 open 项）。FoundationModels 路是**故意**不接：那一轮内没有 steer 排空点，叫醒它只会报一个模型永远读不到的中断——那种「打断」比不打断更坏。

**10-20(续23) codex +5 窗口：一条不变量跨语言落地，顺带把「注释里声称的测试」变成一道门**(P0 上游偏离 / P3 可观测性) — `e1b9c9457..fa71afc8a7` = 5 条 subject 全读，其中 2 条读到 diff（#55581、#55587）；本轮改代码 1 处、新增门 2 道、登记待判 1 条、N/A 2 条。

- **#55581 `e8aa7c1678`（唯一改本地代码的一条）**：codex 把 `oneshot` 接收端在 `try_recv` **之前**先 `take()` 出状态，只在 `Empty` 时放回、`Closed` 时丢弃——一个已 closed 的接收端若留在 session state 里，下一次 `await` 直接 panic 而不是回落到前台压缩。**形状不迁移**（Rust 的 receiver 可消费，Swift 的 `CheckedContinuation` 不可；我们的续体存在字典里，靠「先离开容器再 resume」保 exactly-once），**不变量迁移**：一次性的等待者必须先离开状态再被消费，且归还类操作不能凭空造出许可。逐条量自家的存量续体点：`Agents/Approval.swift:189`（`removeValue` → resume ✓）、`HearingEngineProbe`（exactly-once `ProbeLanding` + deadline ✓）、`SessionWorkspace`/`ExecTools`（栈局部 ✓）。

- **量出两处真缺陷**：① `Engine/CoreAIPipelinedEngine.swift` 整份文件在一个文件级 `#if canImport(CoreAI)` 里（17 行开、末行闭），而它的 `PipelineGate` 注释写着「exercised by `PipelineGateTests`」——这份 suite 全仓不存在，而且**在任何一块跑子上都不可能存在**：macOS 26 交付平台与 CI 都没有 CoreAI，类型被编掉，为它写的测试同样编不过 ⇒ 那句话没有任何门会为它变红（不变量 1：它当时不是 claim，是伪装成 claim 的注释）。② `PipelineGate.release()` 在无人在场时把计数减到负，等于给闸门外接一台许可制造机——这个类型存在的目的正是限制 encode 积压。

- **改法**：`PipelineGate`（84 行）搬到新文件 `Engine/PipelineGate.swift`，它的全部依赖只有 `os.OSAllocatedUnfairLock`（macOS 13 / iOS 16，低于本包 floor macOS 14 / iOS 17：`Package.swift:7-9`）⇒ **一个 `@available` 都不需要**（第一次误判是去 `import Synchronization`，报错 "cannot find 'OSAllocatedUnfairLock' in scope"）；`release()` 加 `if state.inFlight > 0` 钳位。新增 `Tests/ocoreaiTests/PipelineGateTests.swift`(4)：容量下限、填满→排队→release 转移槽位、无主的 release 不能膨胀容量、12 并发持有者守恒（含 peak-waiter ≥1 的前提钉，避开「从未阻塞也算通过」）。续体那一侧补 `ApprovalExactlyOnceTests`(2)：同 id 第二次 `resolve` 必回 false 且挂起方只拿到一个决定；`cancelAll` 后同批 id 全部 false、`sessionApprovalCount` 归零。AGENTS.md:57 的 `CoreAIPipelinedEngine.swift:631/:958` 随之重钉 `:547/:874`（文件 1997→1913 行）。**未证的部分写明**：新 suite 钉的是**记账**，不是 GPU 反压（注释里 ~220/s 提交 vs ~70/s 排空那一层本机永远测不了，CoreAI 管线在 macOS 26 跑不起来）；且重定位后 `PipelineGate` 在 macOS 26 上可编译但无生产调用者（唯一实例化点 `CoreAIPipelinedEngine.swift:562` 仍在 CoreAI 门内）。

- **顺出的门（本轮真正留下的东西）**：注释里点名一个 test suite 也是 claim，而它此前不在任何门的扫描范围内。`make audit` 新增 **Class-J**：`Sources/` 注释里出现的每个 `…Tests` 标识符必须解析得到——本仓 `Tests/` 里的 `struct/class/actor/extension` 声明或 `Tests/**/<name>.swift`；若注释是上游出处引用，则在依赖 checkout / `~/references` clone 里解析，clone 不在时 loud SKIP（不算通过，也不算沉默）；并给扫描自身设 floor=20。今日：44 个名字，43 本地、1 上游（`AgenticThinkTagParserTests` 落在 coreai-models clone 的 `swift/Tests/LanguageModelsTests/`，作为出处保留）。红样实测：临时塞一条 `TotallyImaginarySuiteTests` ⇒ audit exit 1，删除 ⇒ exit 0。**它同一天就抓到第二条假点名**：`Engine/ContextWindowPolicy.swift:151` 的 `ModelOverridePrecedenceTests` 不存在，而被点名的行为其实有门（`ContextWindowPolicyTests.crossHubCollisionIsDeterministic`，那里中文写着「次序钉：candidateKeys 的顺序就是裁决顺序」）⇒ 注释改为点名真门。

- **再加一道前提检查（同一族）**：豁免清单也要能自证。`audit_whitelist.txt` 的条目若指向已消失的路径，就不是豁免而是埋伏——哪天有文件复用这个名字，审计会直接放过去。新增 `[Premise: whitelist entries point at live paths]`：每条必须在 `Sources/` 至少命中一个文件，否则 exit 1。当场量出 1 条死条目 `ErrorContext`（它上面还挂着两行解释「为什么那处 doc comment 不算代码」，替一个不存在的缺陷辩护），已删。红样：临时加 `NoSuchFileXYZ` ⇒ exit 1。

- **#55587 `ab6095dde0`（登记待判，本轮不动手）**：prompt cache key 与 session id 解耦——三种策略（默认由 session 派生 / 自定义 / 干脆不发 `prompt_cache_key`），session 身份头与缓存键策略各自独立，派生子会话与 guardian 审查会话继承，并且**从存储恢复时宿主必须重新施加策略**。本仓盘一遍：KV 身份只有 `SessionPool.poolKey(modelId:conversationId:)` 一个家（`Engine/SessionPool.swift:1150` → `"\(modelId):\(convId)"`），`Sources/` 里 `prompt_cache_key`/`promptCacheKey` 0 命中。判决：**需求轴不同**——codex 那把键是给远端 provider 的 prompt caching 做路由/计费归属的，本地 KV 没这一层；但有一条真会迁移：缓存身份按 conversation 切块，意味着**跨会话的完全相同前缀（同一条 system 指令 + 同一首消息）今天永远不会复用**。这是能力缺口还是正确设计，缺的是数据不是成本：去掉 conversationId 只按内容前缀决定复用，需要先看这类相似前缀到底多不多。下一轮的做法（本轮不动手，先把判据钉死）：给 `canReusePooledSession` 的拒绝原因做记账（conversationMismatch / instructionsMismatch / samplingMismatch / modelMismatch）并在 `/v1/models/:model/kv-cache` 公布，让「刷新 vs 拒用」和 rewind 储备两个老 owner 问题第一次有数字可言。另一半（恢复时重新施加）是本仓已有规则的又一份上游证词：`PooledParameterDriftTests` 钉的就是「per-turn knob 要在对象被复用的地斷刷新，不是只在解析处刷新」（§ Endpoint Promises）。

- **#55591 `60d78332fc`（登记，P3）**：`codex.guardian.turn.blocking_ms` 在一轮完成或取消时记录，带 `outcome` 标签；**重叠的审批等待只算一次、排除 idle 空隙、跨多轮的挂起审批按活跃轮拆分**。本仓对应物 `Agents/Approval.swift` 目前只存行不记时（无一处秒表），而工具审批是就地挂起一轮的，所以人等多久就被算进多久的轮延迟里——违的是变量 2 的一个变种：**指标也不许声称比引擎真做到的更多**。借的是三件事：区间并集（并行工具的两次等待取并集长度，不是相加）、outcome 标签、以及「人的思考时间不是引擎的延迟」这句话要有一个字段来承担。

- **N/A 两条**：#55593 `d34f104c22`（Windows sandbox 去掉无包身份客户端的例外，本仓无 Windows）、#55596 `fa71afc8a7`（TUI `$` 选择器按最近 50 次选中频次排序并持久化——本仓无 TUI，记一句：这是该按 HIG 自己判的 GUI 取舍，不是该抄的语义）。

- **收口数字**：全套 CLT 路 `make test-clt` = **2803 tests / 499 suites 全绿**（416.3 s，较上轮 2797/497 恰好 +6 tests +2 suites，即本轮新增两个 suite）；定向跑 `--filter 'PipelineGate|Approval'` = 54 tests / 11 suites 绿；`make anchor-check` 37 条 drift=0；`make docs-check` 绿（root 50652/50668，claims 43/43）；`make audit` 绿（含本轮两道新门的红样实测）；`make format-check` 零重排。采纳后 `make drift` 四轴：codex 基线推到 `fa71afc8a`，其余三轴同点。

**10-20(续22) 「Jev Compatibility」第一次有了定义：比较仓把它写在哪、我们缺哪一块**(P0 兼容面 / 研究) — 这个词从任务线第一天就在，但本仓 `git grep -in jev -- Sources` = 0，也没有任何文档定义过它 ⇒ 此前它无法被排期、无法被计价、也无法被拒绝。本轮把它从比较仓里量出来了：**两条上游形状，两条完全不同的代价**。全部是*读*（本地 clone 的 file:line），没有跑过任何东西；落点 `docs/agent/systemone-decisions.md`（进 AGENTS.md 的 Read-on-demand，routing 10）。

- **形状 A · vllm `POST /v1/systemone`**：`~/references/vllm-metal/docs/structured_decisions.md:3` 一句「Jev-like System 1 decisions return yes/no probabilities, choices, and scores」把线头交给上游 vllm `examples/features/structured_diffusion/README.md`（我们那份 vllm clone HEAD `5285b9b864` 里就在盘），`:47` 自己点名「POST /v1/systemone implements the Jev decision API」。体 = `model` + `state` + `questions`（id→`{type,instructions,criteria}` 的 map，`:47-50`）；题型 `noul`/`choice`+`options`/`score`+有序 `levels`，**每个标签必须是答案模板里的单 token**，服务器用 tokenizer 当场验（`:43`）；扩散扩展 `diffusion_seed_canvas`/`diffusion_pinned`/`diffusion_max_steps`/`diffusion_read_only`（`:10-13`）、跨题编排 `depends_on`/`ask_if`/`alone`（`:52-54`）、图以 multipart（JSON 装在名为 `request` 的 part）或 `images` data-URL 数组进来（`:56-57`）、`"think": N` 先写思考再读并以 `diagnostics.thought` 回报（`:68-75`）。服务端前置：`--diffusion-config '{"canvas_length":N}'` + `--max-logprobs 32`，且 vllm-metal 自己写明 Metal 上 vLLM 0.31.0 不支持请求级更窄 canvas、DiffusionGemma 只吃文本（`docs/structured_decisions.md:31-36`）。
- **形状 B · sglang `POST /v1/decisions`**：`docs/docs/supported-models/decision_models.mdx:3,5` —— 类型化的 yes/no・choice・score 一题一个概率，读的是**答案位置上的 next-token 分数**，不生成文本、不解析输出，并且「**不需要特殊 checkpoint**：任何带 Jinja chat template 的生成模型都能答，只要当场检查过关」。检查内容（`:20`）：标签在答案位置须是单 token、答案不得落在 reasoning block 里，不过就 400 并指名原因；文档同时坦白它**不**校验模板把答案放在哪 ⇒ 让调用方自己看 `return_prompt_token_ids`。定位（`:7`）：和 `/v1/score`、`/v1/rerank` 同属 `/v1` 扩展，不是 OpenAI API，所以走裸 HTTP 而不是 SDK。最值得一抄的是它的诚实形状：「任何 chat 模型」的设计声明旁边，是**只在两个模型上验证过**的表——设计能力与已验证能力分两栏，正是本仓对 vision/screen/video 做的 tier 拆分（不变量 2）。
- **我们家此刻有什么（读自本仓，今日未跑）**：logprobs 有，但只在 CoreAI 路上——`Engine/EngineLogprobs.swift:60 collectLogits` 与 `Engine/LogProbabilities.swift`（copy-first 自 coreai-models，该文件头写明因 `LogitsScalarType` 只存在于 CoreAI 引擎树而整体受 `canImport(CoreAI)`）⇒ macOS 26 交付平台上 `POST /v1/completions` 带 `logprobs` 收字段但回 **501 `AppError.logitsUnsupported`**（`Handlers/CompletionsHandler.swift:102-107`），诚实降级已在位，而这正是形状 B 要读的那个原语；MLX 路**自己算 logits 但不对外**（`Engine/EngineInference.swift:914`、`:997` 为 `ConstrainedDecodingStrategy` 走 `generate(includeLogits:true)`）⇒ 形状 B 缺的是「把 logits 公布出去的一道缝」，不是新算法；注册表里没有扩散 LM 架构（`Sources/` 里唯一的 Diffusion 是 `Video/CoreAIDiffusionModelFunction.swift`，视频那条轴），而上游 mlx-swift-lm 在钉位上注册了 `nemotron_labs_diffusion`（`Libraries/MLXLLM/LLMModelFactory.swift:118-119`，带出厂配置 `:527`、列表 `:603`；头注释 `:7-12` 写明同一份权重跑 AR / 块扩散 / 线性自投机）⇒ 形状 A 在 mlx 层有消费路径，但钉位上没有 DiffusionGemma；`/v1/systemone`、`/v1/decisions` 在 `Sources/` 0 命中，`make drift` 三轴同点 ⇒ 这是**未开垦的轴**，不是没跟上的漂移。
- **计价与判断（留人拍板，本轮不动手）**：B 比 A 便宜——不引 checkpoint 家族、不碰 canvas 语义、复用已在位且已诚实降级的 logprob 原语。五块：① MLX 路的公布 logits 缝（或先只在 CoreAI 路上做，其余沿用今日 501+补救话术）；② questions schema 解码 + 逐请求「标签须单 token」的 tokenizer 校验（sglang 的契约就是参照，400 要指名原因，并暴露 `prompt_token_ids` 让调用方看见答案位落在哪）；③ 答案形状家族（noul / choice+confidence / score+legend）一个家，参照 `Models/ToolCallWire.swift` 之于工具轮；④ 公布按实测：per-model `decisions: ready|blocked|unsupported` + 原因，设计面与已验证面分栏（不变量 2）；⑤ 一条新探针（`run.sh` 按 `[0-9]*.sh` 自动纳入）——要么给出真概率，要么指名缺哪块前置而拒答，**绝不许编一个数**：这条轴存在的意义就是调用方要拿那个数去做决定，编数是最坏失败。
- **仍未验（写出来而不是藏起来）**：以上无一跑过；sglang `/v1/decisions` 除引言与错误规则外的完整字段表、vllm `structured_server.py` 内部（它把 `/v1/completions` 适配成 `/v1/systemone`，读它才知道契约哪半在服务器哪半在客户端）都未读；`nemotron_labs_diffusion` 能否经我们的 `MLXModelLoader` 装载未测。

**10-20(续21) 一条登记在案的「做不了」被自己证伪：SQLite 开库顺序改了，连机制写法也改了**(P1 执行链 + 不变量 1) — 续20 登记 PRAGMA 顺序缺陷时留了两句话：①「真有另一连接持写锁时 open 直接失败，不是降级」，②「活体前置不满足：造竞争得引第三方 sqlite3 客户端」⇒ 按 `_applyBitmask` 先例登记未决。本轮把②拿去量：同一进程内开两个 `SQLiteStore` 指向同一个文件，SQLite 用的就是同一组 POSIX 文件区间锁 ⇒ **不需要任何第三方客户端**，登记理由不成立；量完连①一起推翻，两处结论都不对，只是错的方向不同。

- **`wal_checkpoint(TRUNCATE)` 的竞争根本不走错误码**：它把结果写在**返回行的第 0 列**（实测另一连接持锁时 `busy=1 log=2`，~4 ms 返回），而 `exec` 把 SQLITE_ROW 当成功（`SQLiteStore.swift:346-348`）⇒ 竞争发生时 open 不抛，只是**静默跳过截断**：WAL 继续长，没人报，也没人知道自己没做。`busy_timeout` 提到最前后同一条语句等到写者提交（实测 262 ms）再真截断（`busy=0`）。这才是这条序改动的实际收益，和续20 写的「open 失败」不是同一件事。
- **真会让 open 抛的是 `journal_mode=WAL`，且只在该库当时不在 WAL 模式时**：另一连接持事务的那一刻，模式转换**立即**回 SQLITE_BUSY，超时帮不上（实测 `busy_timeout=5000` 确实生效——`PRAGMA busy_timeout` 读回 5000——仍 0 ms 失败；`BEGIN IMMEDIATE` 与直接 `sqlite3_busy_timeout()` 两条路同结果；换成 `BEGIN EXCLUSIVE` 反而会等 348 ms 后成功）。稳态下库第一次开就是 WAL，这条转换是 no-op 行，所以它不是本次改动的靶子；命中它要「外部工具把 journal_mode 改回 delete」+「恰好有并发事务」，后果是 `App.swift:329 failStartup` 拒启。改法两条路（有界重试 / 保留既有 journal mode = codex #54389 的立场）是产品裁决 ⇒ 登记 owner，不臆改、不宣称已修。
- **落地就一条序 + 一次读列**：`busy_timeout` 第一个执行（值收到一个家 `SQLiteStore.walBusyTimeoutMilliseconds`）；checkpoint 三列读出来，竞争从此是**记录**不是吞掉——新增 `SQLiteStore.WALCheckpoint{busy,logPages,checkpointedPages}` 与 `lastOpenWALCheckpoint`，busy 时 `logger.warning` 报 log/checkpointed/db（不变量 2：不许把没做成的截断说成做成了）。
- **门 `SQLiteOpenBusyTimeoutTests`(3)**：① 无竞争基线 wal / busy_timeout=5000 / busy=false / <1 s（给②定标）；② 竞争在超时内（写者 300 ms 后提交）⇒ open 等到它（≥150 ms）且 `busy=false`；③ 竞争超过超时（6.5 s）⇒ `busy` **必须为 true** 且 open 仍成功——③ 是套件的前提自检：谁把 `busy` 写死成常量或把读列删了，③ 立刻红。红样实测（等价于还原旧序）：`walBusyTimeoutMilliseconds=0` ⇒ ② 双红（`busy=true`、elapsed=3.0 ms），① ③ 仍绿。绿样：3/3（基线 46 ms / 竞争 379 ms / 超窗 6.778 s）。
- **顺带把线上面全量跑了一遍**：`scripts/probes/run.sh` 二十条一次跑完 = **361 断言 / 0 失败 / 166 行 measured / 0 known-open**（每条自己起 server、自己钉前提，脚本在盘可重跑）。选在这一步跑是因为本轮动的正是开库路径：`serve` 起来了、模型 3.4 s 载入、会话读写正常——那条 PRAGMA 序改动在真进程里跑过一遍，不只是过了单元。逐条：01=12、02=16、03=29、04=40、05=34、06=22、07=12、08=15、09=24、10=12、11=20、12=6、13=37、14=21、15=9、16=7、17=9、18=12、19=9、20=15。

**10-20(续20) codex +232 语义扫：一条安全族落到本地，其余按族裁决，四轴第一次全绿**(P0 上游偏离) — `efa159f7a..46d252f8b` = 232 条 subject 逐条读完；与本仓消费面直接相关的 8 条读到 diff。口径写在这：subject 级 232/232，diff 级 8 条，其余不采的理由是同一句——没有消费面就没有偏离。

- **安全族 ⇒ 本轮唯一改代码的一条**：#55384 `b8f880bc38`「Reject replaceable symlinks in pre-sandbox executable lookup」的 Why 直译过来就是一把尺子：*只读的目标不等于路径可信，符号链接或其祖先目录仍可能被策略允许的写入替换*。拿它量自己的下载面，当场量出一个洞（见续18）。同族其余登记为参照而非偏离：#54273 `3bae578af3`（macOS 大小写别名——`.GIT/config` 能过大小写敏感的写检查）与其回归 #54250 `7c152d4684`、#54363（不可检视的网络根从隐式 read grant 里剔掉）、#54619（plugin hook 审批绑定 plugin 内容）、#55288（HTTP 边界重查请求权威）。不跟的理由：它们的对位面是 codex 的沙箱/授权模型（`bwrap`、grant 表、protected-metadata 概念），本仓没有同一件物；要不要引入「受保护元数据路径」是产品决定，不是漂移。
- **SQLite 两条：形状我们没有，但顺出一处真缺陷**：#54369 `7ae8319917`（writer 竞争重试 + `BEGIN IMMEDIATE` 先占写位）、#54389 `1ef30bcbe7`（open 时别强转 WAL，保留既有 journal mode）。逐行对 `SQLite/SQLiteStore.swift`：`:198` 无条件 `journal_mode=WAL`、`:201` `busy_timeout=5000`，且 `Sources/ocoreai/SQLite/*.swift` 里 `BEGIN` 只出现在 SQL 触发器体（实测命中 433/441/449/601/609/617 全是 `CREATE TRIGGER … BEGIN`）⇒ 本仓每条写都是 autocommit 单语句，#54369 针对的 `BUSY_SNAPSHOT`（延迟事务读完再升级写）这一类**在这里不存在**。顺出的缺陷：`:200` 的 `wal_checkpoint(TRUNCATE)` 排在 `busy_timeout` **之前**，等于跑在默认 `busy_timeout=0` 上，而 `exec` 对任何非 DONE/ROW 一律 `throw`（`:346-348`）⇒ 真有另一连接持写锁时 open 直接失败，不是降级。改法三行（`busy_timeout` 提到 `journal_mode`/`wal_checkpoint` 前），但活体前置不满足：`Core/SingleInstanceLock.swift` 已挡双实例，造竞争得引第三方 sqlite3 客户端 ⇒ 按 `_applyBitmask` 先例登记未决、不臆改；判据=两进程争同一库断言 open 不抛（PRAGMA 顺序可以静态钉，随时能做）。**〔10-20(续21) 实测推翻本条机制、并已落地修：「造竞争需要第三方 sqlite3 客户端」不成立，且 `wal_checkpoint` 的竞争不走错误码〕**
- **指令通道：#53872 `cb03f28a40` 是另一条分支** —— 模型身份与指令内容各自跟踪，任一变化时追一条 `model_instructions` developer 消息，让语义更新到位而既成历史前缀保住 KV。这正是 § Open「刷新 vs 拒用」的第三种答案。本轮仍不跟，但先把价钉住：探针 19 实测改一次指令 = 整轮重 prefill（`prompt=1438 cached=0`），同指令暖轮 `prompt=12 cached=1458`。价已定价，采不采留 owner。
- **同轮工具面四条：不重复登记** —— #54656 `0df4aa6778`（MCP tool-list 中途变更同轮可见，且是默认关闭的 feature flag）与 § Open「轮内即时转向需要 tool 调用」是同一形状：上游给的是 *catalog 刷新* 缝，不是任意注入缝；#54945 `1cc7dc8f2a`、#55261 `c0ce901923`、#54754 `e16b631d08` 是 Rust 侧的声明共享/内存优化，语义面本仓已由 `Models/ToolCallWire.swift` 一个家管住（§ Endpoint Promises），无偏离可消；#54654 `beae473be8`（动态工具并行）＝ `parallel_tool_calls` 已按 vllm/sglang 同族落地。
- **可观测性一条值得抄，本轮未做**：#55144 `70b3bb6d88` 加 `PreModelRequest`/`PostModelRequest`，并在描述里明写钩子输出**不得否决请求、不得改模型上下文**，只报完成/失败/取消 + token。本仓对应物 `Profiling/TimingHooks.swift` 目前是起停计数器 + `summary(modelId:)` 文本，没有「前后钩子 + 明写无否决权」这一层语义边界 ⇒ P3 候选，登记。
- **其余按类读完**：TUI 外观/键位/preset（#54378–#54388、#54742、#55411…）、daemon 安装与 Windows/MXC 沙箱、Bazel/V8/rules_python 升级、OAuth/OIDC/federated auth 与凭据轮换、Guardian 评审族、rollout 压缩与迁移、release 流水线、语音 realtime——本仓无 Rust、无 Windows、无 Guardian、无 Bazel/V8、无 daemon updater，逐条不采。
- **收口**：`bash scripts/upstream-drift.sh adopt codex`（只这一条轴，续17 装的 per-axis adopt）后 `make drift` 四轴同时 `0 new ✓`：mlx-swift-lm HEAD=48114eedf（= SPM pin）、coreai-models HEAD=9e120659a、codex HEAD=46d252f8b、mlx-swift tag 0.32.3 == pin。

**10-20(续19) `/v1/models/download` 从来没接住过合法客户端：一个 init 默认值锁死整个端点**(P0 兼容面) — 探针 20 第一次跑的 8 条红里，六条的理由根本不是要测的东西：`400 {"error":{"message":"Coding key \`useLatest\` not found."}}`。

- **机制** — `Models/ModelDownloadDTO.swift` 写的是 `let useLatest: Bool` + `init(… useLatest: Bool = false)`。默认值写在 Swift 侧，合成的 `Decodable` 照旧要求这个键 ⇒ 任何没带 `useLatest` 的 body 在 `validate()` **之前**就 400，SSE 从未打开过。也就是说这条路由它诞生起就没法被规范合法的客户端用（`useLatest` 是刷新覆盖，正常调用方不会主动写）。AGENTS.md § Wire DTOs 早就写着这条规则（`AnthropicMessageRequest.stream` 同款事故），而本仓活下来的 DTO 靠的正是手写 decode——规则在，漏面也在。
- **同类清一遍（机械口径，不靠印象）** — 把路由器里 `request.decode(as: X.self)` 的 **13 个入站 DTO** 机械列出逐个查，两种形状都算：property 级默认（`var n: Int = 4`）与 init 参数级默认（`init(n: Int = 4)`）。命中的结构体 6 个、键共 16 个：`DownloadModelRequest.useLatest`、`EvalRequest.batch_size/max_batches`、`TrainRequest.lora/hyperparams`、`TrainRequest.LoRAConfig.rank/scale/numLayers`、`TrainRequest.TrainHyperparams` 七键、`StreamOptions.include_usage`（最后这条最疼：`stream_options:{}` 是 OpenAI 合法 body，以前会把整条 chat 请求 400 掉）。全部改成 `decodeIfPresent(…) ?? 默认`；注意声明 `init(from:)` 会顶掉合成的 memberwise init，`LoRAConfig()` 这类默认值用法要显式补回构造器。
- **门** — `Tests/ocoreaiTests/WireDTOOptionalityTests.swift`(8)：省略键即得默认的精确值行为断言（download 最小 body / eval / train 连 `lora:{}` / `stream_options:{}`），加一条**会自测的扫描**——扫描器必须先在两段合成样本上证明自己看得见 property-default 与 init-param-default 两种形状，才被允许对 13 个入站 DTO 报 0；键住「正则停了也报绿」这一族（CONTRIBUTING：门要断言自己的前提）。
- **诚实边界** — 扫描只对**没有** `init(from:)` 的结构判违规；三个主面（OpenAI/Anthropic/Completions）本就是手写 decode，若有人在手写里对规范可省的键误用 `decode`，这道门看不见。可见的下一处 `ResponseFormat.type` / `ToolDef.type` / `ToolCall.type` 在规范里本就必填，不构成偏离。openai/anthropic 面的「缺键活体回归」本轮只上单元面，探针未加。

**10-20(续18) 缓存目录之外没有写权限：hub 路径只留一个入口**(P0 安全 / 行为一致) — `POST /v1/models/download` 的 `model` 会拼进磁盘路径，而 Hub 自己的 manifest 也会：两条道都是。

- **缺陷形状（静态读，行号=改前）** — `Models/ModelScopeDownloader.swift:119` `cacheRoot.appendingPathComponent(id)`（wire 的 `model`）；`:922` `cacheDir.appendingPathComponent(filePath)`（**远端** manifest 的 `Path` → 写）；`:962`/`:977` 同一拼法用于 `removeItem`（→ 任意文件删除原语）；`:995` 校验拼。`URL.appendingPathComponent` 只做百分号编码，**不做包含**，`..` 原样留在路径里。决定威胁模型的是第二个输入：manifest 字节来自「谁应答了 API」，而 `MODELSCOPE_ENDPOINT`（`:78`/`:97`）让「谁应答」成为运维可选项（镜像/代理）——不能假设来源可信。
- **HF 车道同构，而且更隐蔽** — `Engine/MLXBridge.swift` 的 `flatTarget(for:)` 只 trim 首尾 `/`、跳过空段，从不看 `..`；它正是 `hub.downloadSnapshot(to:)` 的写目标。上游也拦不住：`Repo.ID(rawValue:)`（swift-huggingface `Repo.swift:200-207`）只要求「按 `/` 切成两段」，于是 `../../x` 以 `namespace=".."` 顺利通过。
- **上游 grounding（都读到 diff/正文）** — codex #55384：可替换符号链接即不可信路径；ollama `types/model/name.go:262 IsValid()`：逐成分枚举危险，正是这套判法的先例。
- **一处落点：`Sources/ocoreai/Core/HubRelativePath.swift`（新）** — `components(_:field:)` 结构性拒绝八种形状（空、首尾空白、NUL/C0 控制字符、`\`、前导 `/`、前导 `~`、任一成分为 `.`/`..`、空成分 ⇒ 顺带覆盖 `//` 与尾斜杠）；`resolve(under:_:field:)` 做两次包含检查：先词法（standardized），再顺到**最深存在祖先**解符号链接后比对——第二次才看得见 `cacheDir/link -> 外面`（含尾段尚不存在的写入型逃逸）。不修成 `standardizingPath`：它把 `a/../b` 静默收成 `b`，等于替 manifest 改它自己说过的路径。`AppError(hubPathRejected:)` 把裁决翻成线上形状（400 + `error.param` + `error.value`）。残留写死在文件头不藏：这是 check-then-act，验证与写入之间被换进来的符号链接要靠 `openat`+`O_NOFOLLOW`（相对已打开的根 fd）才闭得了；缓存目录属当前用户 ⇒ 残留是本地用户竞争，不是远程输入逃逸。
- **接线** — DTO 在 SSE 打开之前拒（`Handlers/ModelDownloadHandler.swift` 的 `try request.validate()` 早于 Response）；ModelScope 四条 join 全走 `cacheFileURL(for:under:)`，字段名 `files[].path` 只出现一处；ingest 处对 `matchingFiles` 逐条结构性拒，整轮拒——新增 typed `DownloaderError.unsafeManifestPath(repoId:rejection:)`，因为「服务端答了不安全路径」不能与「网络失败」共用一条错误；HF 车道 `flatTarget` 同规则。全文件唯一保留的裸 join 是 `.download-<压平名>`（分隔符先压平成 `__`，形状上不可能外逃），并被扫描钉死。
- **门** — `Tests/ocoreaiTests/HubPathTraversalTests.swift`(12)：8 条合法路径 → 精确 components；17 条危险串 → 逐条对 `reason`；拒绝文案精确等值（控制字符转义后仍是可读且惰的字符串）；真符号链接逃逸断言（**尾段尚不存在**那一型才是真攻击）+ 悬空链接仍含住 + 正向对照（同目录合法子路径必须过）；`flatTarget` 直接谓词断言；两条自 floor 源码扫（`appendingPathComponent` 命中 ≥4、`HubRelativePath` 命中 ≥5，且每条 `cacheDir.appendingPathComponent(` 行必须含 `flattened`）。
- **活体（探针 20，15 passed / 0 failed / 3 measured）** — 六条危险 id 全部 400 且 `error.param` 说出 `model`/`revision`、值回显、`Content-Type: application/json`（不是 `text/event-stream`：流根本没开，客户端 SDK 也就没承诺过下载）；`/tmp/…-escaped` 未出现；合法 `org/name` 正常开流并吐出 `data:{…DownloadSSEEvent}`；六连拒后 `/health` 仍 200。**同一支探针的反面教训**：修前那次是 7 passed / 8 failed，而其中「既有校验未受影响」两条**绿着**——因为每条请求都 400，只是怪的字段不对；从此每条拒绝腿都必须说出它怪了哪个字段（大小写不敏感，第二次跑证明错的是断言不是服务器）。
- **未做/未证** — 扫描范围是两条下载车道 + 路由器 13 个入站 DTO；`UI/Views/ModelView.swift:332` 的 `models--<encoded>` 经查与 temp 同形（`/` 先换成 `--`）⇒ 构造上安全，未纳入改动；iOS 侧下载端点零验证（§ Open iOS 那条不变）；远端 manifest 拒答路径的活体形状没有真镜像可造 ⇒ 由 `unsafeManifestPath` 的构造 + 单测覆盖，标注为读码结论。
**10-20(续17) 关掉一条读完的窗口：#358 补读、#328 逐行比对（并顺手把「只能全采或全不采」的仪表缺口补上）**(P0 上游偏离 + P1 执行链) — coreai-models 的 `bd61eb1..9e120659a`(+8) 窗口在续12 逐条裁完 7 条，剩 `#358` 因 `git fetch` 超时没读，于是**整条窗口按纪律不 adopt**（10-14 定下的规矩：钉到未读点＝把没读过的段落伪装成已裁决）。本轮 clone 里已有该 commit（HEAD 就是它），补读完毕 ⇒ 这条轴第一次可以如实收口。

- **#358 Remove prerelease allow（`9e12065`）＝透明** — 改动实测 16 个文件：14 个 `models/*/export.py` 的 uv 头删 `prerelease = "allow"` + `pyproject.toml` 一行 + `uv.lock` 重解析（161+/160-）。**0 个 Swift 文件**，且 `LICENSE` 未被触碰 ⇒ AGENTS.md § Upstream Audit #2 的「Python/export-side commits are consumer-transparent：ocoreai 无 Python 也无 export 面」直接适用；顺带确认可提交 manifest 里 `apple.pin=9e120659a…` 指的就是这条 commit，其 `LICENSE` 字节仍与本地文本一致（Class-I 每轮重算）。
- **#328 fp8 KV Cache resizing＝本仓真偏离，且比修前的上游更静默** — 上游只改 `KVCache+CoreAI.swift` 三行：`case .float8e5m2, .float8e4m3fn, .float8e8m0fn, .float4e2m1fn: return .float16` → `case .float8e4m3fn: return .float8e4m3` + `case .float8e5m2: return .float8e5m2`。逐行对完本仓：`Engine/KVCache+CoreAI.swift:618` **就是修前那一行的逐字副本**（四类 fp8/fp4 全映射 `.float16`），而我们的 `default` 分支（`:627-628`）连上游那句 `fatalError` 都换成了 `return .float16` ⇒ 两条路都不会响。后果的形状：buffer 由 CoreAI 自己的 `minimumByteCount` 分配（`:468-469`），MPS 视图却按 `mpsDataType` 拿 `.float16` 造（`:490`→`:553-571`）——若某 checkpoint 的 KV state 真是 fp8（1 字节/元素），视图就是分配量的 2×，扩容时的 identity copy 直接越界。
- **为什么不顺手改（按先例，不臆修）** — ①可达性未证：`grep -rn 'fp8\|float8' Sources --include='*.swift'` 除这一张表外**命中 0** ⇒ 本仓没有任何构造或请求 fp8 KV 的代码路径，这张表今天只可能被外部导出的 model 触发；②唯一执行点在 `#if canImport(CoreAI)` + `@available(macOS 27.0,*)`，CLT SDK 把整条分支编译掉，本机连编译都验不了（CI 的 xcode 腿只能验编译，验不了 dtype 是否被 CoreAI 接受）。与 § Open 里 `_applyBitmask` 那条同一类：**改法显然（照抄上游两行 + 把静默兜底改成显式拒绝），但登记为未决，不改、不宣称已修**；真要动，需要一台 macOS 27 + 一个 fp8-KV 导出模型做活验。
- **仪表缺口：adopt 只有「全采」和「不采」** — 原脚本 `adopt` 无条件把三轴 HEAD 一起写进基线，于是「读完一条轴想收口」只能顺手把没读过的 codex（+231）一起盖掉——正是本仓反复警告的时龄失真。`scripts/upstream-drift.sh` 现支持 `adopt <轴>…`：未选中的轴打印「基线保持不变（窗口如实留着）」并原样留给下次 check；轴名写错 exit 1 且不写 state（静默采纳 0 条轴看起来像办完了，是这类工具最贵的错）。红样：`adopt bogus-axis` → `EXIT=1`、`.upstream-baseline.json` 内 `bd61eb1` 计数不变。裸 `adopt` 行为不变（向后兼容）。
- **收口后的四轴真值（同一次 `make drift`）** — `mlx-swift-lm HEAD=48114eedf 0 new ✓`（= SPM pin）、`coreai-models HEAD=9e120659a 0 new ✓`（本轮关窗）、`codex HEAD=e18a20d6e +231 ⚠ 待裁决`（语义轴，仍需一次 owner 级语义扫，非逐条复制）、`mlx-swift tag=0.32.3 pin=0.32.3 ✓`，main 侧另有 8 条未发布、其中 5 条落在我们直接消费的 MLX 文件上（`#486` asArray 零尺寸崩溃、`#501` 泄漏、`#499` evalLock/dispatch_once 锁序、`#496` float16 attention mask、`#474` 同步 eval）⇒ 下一次 tag 的审计输入，非本轮待办。
- **root 与 state 同步** — § Open 的两条 CoreAI 未决合成一条同类项（「本机永不可验证的显然修法」），fp8 那条自此有名字、有行号、有判据去处；`.upstream-baseline.json` 的 `adopt_provenance` 改写为本轮的部分采纳事实（哪条轴凭什么关窗、哪条留着）。
- **未证 / 未做（不冒充）** — ①fp8 偏离**未修**（理由见上），且「2× 视图越界」是从分配与造视图两处代码形状推出的结论，没有一次真实 fp8 运行 ⇒ 记为推断；②codex +231 整窗未读，`make drift` 继续 exit 10，这是有意的红；③#351 `stateKinds` 生产者缺口仍是 owner 拍板项（续12 已登记，本轮未动）；④本轮零 `Sources/` 改动（只动脚本与文档），故未重跑探针；全量套件在本轮之前那次 `Sources/` 改动后已跑过 1852/0（见续16 更正），脚本改动由「红样 + 两次实跑」覆盖，无 Swift 测试可钉。

**10-20(续16) 分发件的「来处」第一次成为记录：Apple 文本钉 pin+摘要，vendored 头进 GUI**(P0 交付一致性 + 不变量 2 + P3 可观测性) — 借自 harness²（owner 10-20 新点名，本轮实测**在盘**：`~/references/harness2` = 15 棵树之一；内容 `third_party/*/PROVENANCE.md` + `dependencies/ASSETS.json`(path→sha256) + `scripts/check_provenance.py`（任一资产缺失或字节变了即 exit 1）+ `dependencies/PINNED.md`，并且它把「自己重写的 release code 不算 vendored asset，所以不进校验表」这条判别写死在 PROVENANCE 里）。此前 `THIRD-PARTY-LICENSES/manifest.json` 只回答「有一份 Apple BSD-3 文本 + 每依赖一份文本」，不回答**这份文本出自哪个 commit、发出去的字节是不是它**；而 `Sources/lib/CXGrammar/include/dlpack/dlpack.h`（dmlc/dlpack，Apache-2.0）确实随源码分发出去，GUI 的第三方许可面板却只列「链接的依赖」⇒ 用户可见面漏报一份实际重分发的 Apache-2.0 §4 文件（不变量 2：面只许报它交付得起的东西）。

- **schema 2 记三件事** — `scripts/collect-third-party-licenses.sh` 的 apple 块现写 `pin` / `licenseSha256` / `verifiedAgainstPin`，并新增顶层 `vendored[]`（`file`/`upstream`/`license`/`holder`/`textFile`/`sha256`）+ 一行 `provenance:` 打印。`pin` 与 `verifiedAgainstPin` 是 host-local 事实：没有 `~/references/coreai-models` clone 时记 `null`，绝不猜一个 sha；`false` 的含义写死为「查过，且不匹配」，不许塌成「没查」。提交态 manifest：`apple.pin=9e120659a5643ad77f09125ba75eb6c9291e6ef4`、`licenseSha256=0ce5470a3d6a7c2a…`、`verifiedAgainstPin=true`、`vendored[0]=dlpack.h sha256=701e24d408eed779…`。
- **缺席≠空集（复用 10-13 的 wire 规则）** — `Core/ThirdPartyNotices.swift` 手写 `init(from:)`，`vendored` 走 `decodeIfPresent(…) ?? []`：schema 1 的旧 manifest 或旧 bundle 必须仍能解出，且键缺席不许读成「本构建不含 vendored 代码」；`Apple` 的三个新字段是 Optional，理由同 `stream` 那条的镜像面。
- **GUI 补上漏报的那一份** — `UI/Views/ThirdPartyNoticesView.swift` 新增 `ThirdPartyVendoredSection`（插在依赖区与 codex 区之间）：行 = `file · license · sha256 前 12 位`，展开是上游 Apache-2.0 全文（新 `ThirdPartyNotices.vendoredLicenseText(for:)`）；en/zh 各 2 条 `StringKey`（`About.ThirdPartyNoticesVendored{,Detail}`，两语完备性由既有 `LocaleTableCompletenessTests` 钉住）。空列表不渲染——那是采集器量出来的「没有」，而 schema<2 的 manifest 已被 Class-I 拒发。
- **判据（哪条会红）** — `ThirdPartyNoticesTests` 11→**16**：`schemaVersion == 2`（旧断言 `== 1` 会拦住新字段）；apple 摘要用 `CryptoKit` **对盘上字节重算**（不是把 manifest 的值读回来）；`pin` 必须 40 位且 `verifiedAgainstPin == true`；`vendored` 地板 ≥1（防「采集器什么都没找到」空过），逐条查文件存在 / 摘要一致 / `textFile` 已随包 / upstream+holder+license 非空；无 `vendored` 键的旧 JSON → `[]` 且三个新字段 nil；GUI 静态门扫 `ThirdPartyVendoredSection(vendored: manifest.vendored)`＋`vendoredLicenseText(for:`＋≥2 条本地化键。`scripts/audit.swift_patterns.sh` Class-I 另加：schema≥2、apple 摘要对盘上字节、**有 clone 时**与 `git show <pin>:LICENSE` 逐字节相等、逐条 vendored 摘要/upstream/textFile，clone 缺席打 loud SKIP 而非静默通过。`docs/agent/third-party-notices.md` 里 8 个数字改成 `<!-- claim:… -->`（`make docs-check` 现跑 30/30），把「44/29/38/34/1/16」从手抄变成会红的断言。
- **红样（当场证明会红）** — 把 manifest 的 `vendored[0].sha256` 改成 64 个 0：`make audit` exit 1 并报 `FAIL vendored bytes changed since collection: Sources/lib/CXGrammar/include/dlpack/dlpack.h (recorded 000000000000… now 701e24d408ee…)`；`swift test --filter ThirdPartyNotices` exit 1，`Tests/ocoreaiTests/ThirdPartyNoticesTests.swift:325` 摘要断言失败（manifest 运行时读取 ⇒ 无需重建就红）；还原后两条门各自回绿、采集器重跑对 `manifest.json`/`NOTICES.md` 逐字节无变化 ⇒ 「记录与发出的字节不再一致」从此既红在审计也红在测试。
- **实测** — CLT 路线 `swift build` exit 0；`swift test --filter 'ThirdPartyNotices|LocaleTable'` = **20 tests / 2 suites / 0 failed**；**全量 `make test-clt` = 1852 tests / 0 failures（511 s，`Executed 1852 tests, with 0 failures (0 unexpected)`）**；`make audit` ✅（Class-I 三行 OK：Apple 摘要、与 pin 逐字节、1 个 vendored 全部一致）；`make docs-check` ✅（root 50650/50668、claims 41/41）；`make anchor-check` ✅ 37/drift 0；`make format-check` ✅；`scripts/collect-third-party-licenses.sh` 幂等（重跑 `cmp` 两文件皆 identical）。
- **文档同步** — root § Upstream Audit item 6 的「`**harness2**` is designated but absent on this host ⇒ uncitable until cloned」是上一轮的事实、本轮已过期：改名为名单一员（`/ harness2`）并把指针留给 `docs/agent/comparator-repos.md`（B1 只减不增：50652→50650）；`docs/agent/comparator-repos.md` 补 harness² 行（实测内容 + 借它干了什么）、删「Not on this host」整节、把「谁被审计过几次」从过期手抄改成命名命令 + claim 地板。
- **未证 / 未做（不冒充）** — ①GUI 端到端仍零验证：新板区只有静态门（扫 view 源码）+ 数据门（读 manifest），没有任何一次真机渲染 ⇒「用户在设置里看得见 dlpack 的 Apache 全文」是推断而非实测（GUI 不经 HTTP，同 § Open 的 GUI 条）。②与上游逐字节比对只在持有 clone 的机器上发生，CI 打 SKIP ⇒ 那条强判据目前只在开发机成立（因此「manifest 里 `pin` 非空」被单独钉一条）。③本轮动了 `Sources/`（SwiftUI 结构 + DTO 解码路径）：全量套件已在同会话重跑并全绿（`make test-clt` 1852/0），但 18 条探针未重跑（本轮无 HTTP 路径变更，探针答的是 wire 行为），macOS 27/CoreAI 分支与真机 GUI 仍只能由 CI 的 xcodebuild 腿代跑。④harness² 的 `dependencies/` 靠 setup 现场下载且不入版本控制——我们没有对应机制，模型权重下载的完整性是另一条线，本轮未动。

**10-20(续15) 探针 18：`auth` 列从此有线上裁决（12 项全绿，红样 3 条）**(P3 可观测性 + 不变量 2) — `/v1/capabilities` 每个端点都带一行 `auth`，它由 `AuthRoutePolicy.publicPaths` 派生；`V1EndpointCatalogTests` 静态证明的是「派生自真源」，**从来没证明中间件真的执行**。上一轮又数出「谁免鉴权」在 repo 里有四份副本（其中 router 头注释 7 条只写 5 条）。也就是说「文档说 public」与「不带 key 打得通」这两件事，此前从未被当作同一事实测过。新探针 `scripts/probes/18-auth-surface.sh` 把它变成线上裁决（`run.sh` 靠 `[0-9]*.sh` 自动纳入，无需登记）：

- **前提自证优先** — keys 必须 ON：`config.enabled=false` 时中间件短路、每条路由都放行，下面所有 401 会在 200 上假绿。故探针自己 `export OCOREAI_API_KEYS` 并双向钉住「鉴权确实在跑」：`/health` keyless==200（public 该开）与 `POST /v1/count-tokens` keyless==401（keyed 该关），任一不成立直接收口报错，不再往下装样子。
- **逐条对照（index 34 行，地板 30）** — 7 条标 `public` 的端点全部 keyless 可答（400/404 无妨，路由活着即可）；27 条 `key`/`admin` 全部 401。另点名 `/v1/perception`：keyless 401、带 key 200 —— 正是续14 改注释那条路的线上真值；`DELETE /sessions/:id` 带 **user** key → 403 `adminKeyRequired`（不是静默 2xx），不带 key → 401（key 校验先于 admin）。
- **wire == index == README** — 最后把线上实测出的 public 集合与 README.md 写的那 7 条逐字比对；三处必须是一个事实。
- **三轮自我修正（每条都写进脚本注释，堵同类坑）** — ① 循环变量写成 `PATH` 会冲掉 shell 的 `$PATH`：之后 curl 全部找不到、状态全 `000`，而 `000` 恰好穿过「非 401/403」被判成 public ⇒ 报出 **7/7 假绿**。改 `EP_PATH`；「完全没答上来」自此计为矛盾而非开门；再加一条覆盖地板：两分支合计必须覆盖 index 全部行数，否则红。② `$( … <<'PY' )` 里出现反引号是 bash 3.2 的解析陷阱：改为 python 输出落文件再读回，正则用 `chr(96)` 拼。③ 向上找仓库根时第一个 `README.md` 命中的是 `scripts/probes/README.md`（另一份文档，不含 public 句），交叉校验据此空转报「无目标」⇒ 改用只存在于根部的 `Package.swift` 作标志。
- **判据与实测** — 绿：**12 passed / 0 failed / 4 measured / 0 known-open**。红样（把 `/v1/perception` 塞进 `publicPaths` 后重建）当场报 3 条：keyless 得 200、README 的 7 条 vs 线上 8 条、keyed 计数 26/27；`git checkout --` 还原并重建后回到 12/0，`git diff` 该文件为空 ⇒ 「悄悄放宽未鉴权面」现在既是单测红也是活体红。
- **未证 / 未做（不冒充）** — ①探针只回答「公布的 auth 列 == 线上行为 == README」，不回答 `/v1/perception` **该不该**并入 public（续14 已留人拍板）；②调用方已设 `OCOREAI_ADMIN_KEYS` 时 403 那条以 NOTE 跳过（不是静默通过，但也没测）；③探针 18 单独跑绿之后，同会话补跑全量 `bash scripts/probes/run.sh` = **18/18 全绿、337 条断言 0 失败**（18 号纳入 `run.sh` 自动发现后首跑，证明它与既有 17 条共处无碍）；`make test-clt` 全量套件本轮未跑，CI macos-26 仍是权威。
**10-20(续14) 「门=人读」不是门：README 的端点表、鉴权名单与「最后一次全绿」全部改由代码裁决**(P0 文档↔代码不一致 + 不变量 1/2) — root § Documentation Map 一直明写 `README.md`/`README.zh.md` 的门是 **Human**；本轮把两份 README 纳入 `make docs-check` 扫描域（`docs` 字典）并新增 **P10**，它第一次跑就点名 4 处不一致，逐条查实、逐条落码：

- **① 端点表漏两条（两种语言同时漏）** — router `routes.<method>("…")` 实测 **34** 条、`V1EndpointCatalog` 亦 34 条（`V1EndpointCatalogTests` 长期全绿），两份 README 却各 **32** 行：`GET /v1/perception`、`POST /v1/audio/transcriptions` 双语同时缺。既有门只比 catalog↔router，README 整份在门外 ⇒ 绿的门说的是另一条线（invariant 1 的又一例）。现补齐并在 P10 里做全等（缺、多都红）。
- **② 鉴权名单居然有四份，其中一份是错的** — 真源 `AuthRoutePolicy.publicPaths`（7 条）；catalog 的 `auth` 列派生自它（对）；两份 README 手抄（此刻对，但此前无人守）；**`ChatCompletionsRouter.swift` 文件头注释错**：只列 7 条里的 5 条，并断言 "All other endpoints require valid API key"——对 `/v1/tools`、`/v1/capabilities` 是假的。同文件 `:400` 注释还称 `/v1/perception` "public"，而它从来不在 publicPaths ⇒ 改为 keyed 并写明来龙去脉；README 补一行「其余一律要 key，含 `/v1/perception`」。**放宽鉴权不是文档修复**：要不要把它并入 public 发现面（它只出 flags+ages、绝不出帧内容）留人拍板，代码维持现状、措辞跟随代码。
- **③ 三条互斥的 CI 断言** — README.md 说 macOS-26 与 xcode-27 两腿全绿；README.zh.md 上方说 xcode-27 当前红、**同一文件**下方又说它绿。实测 `.github/workflows/ci.yml` 是 **6 条 job**（`governance` ubuntu-latest；`audit`、`build-and-test`（矩阵 macos-26 + xcode-27）、`release`、`build-appstore`、`build-ios` 均 macos-26），两份 README 都只提 2 条 ⇒ 三处全改为陈述「有哪些腿」，删掉 SHA 级「最后一次全绿」（下次 push 即过期、克隆里无从复核；实时状态归顶部徽章与该 SHA 的 run）。
- **④ 测试数 1,852 的来源不存在** — README 把它注明出自 `~/wiki/ocoreai/log.md`，而该 vault 不在本机（`ls ~/wiki` → *No such file or directory*）、不在 git、不在 CI；root § Wiki 自己就写着「因此它永远不是项目证据」，P2 也确把它单独报成 host-local warn ⇒ 删除滚动计数与死源，改留可重跑的计数命令（本轮实测：`@Test` 声明 **2882** / 测试文件 **270** / `@Suite` **491**）。README 上文还写着「钉一张 ✅ 表会在每次 commit 后过期」，随后自己钉了一个数——自相矛盾一并清掉。
- **⑤ 顺手查实限流句（结论：数字对，但此前看不出谁说了算）** — README 说 "200 req/s global"：`RateLimitProvider.Config` 默认其实是 `globalRate 100/burst 150`，真值来自 `App.swift:701` 注入的 `globalRate: 200, globalBurst: 300`（per-model 30/45、per-IP 20/30）⇒ README 现在写出数字全档 + 落点。两条 HTTP 入口是否同一套限流也读了码：headless `serve` 经 `OcoreaiEngine.shared.start()` 走同一个 `startHTTPServer()`（`HeadlessServer.swift:137`），故 GUI 与无头共用该 provider（**读码确认，活体未证**）。
- **判据（哪条会红）** — `agents-md-contract.sh`：README 进扫描域后 P1–P7 一并生效；**P10** 三条全等（端点表↔router、public 句↔`AuthRoutePolicy.publicPaths`、CI 6 个 job id 必须在 README 中出现），并给 router 扫描自带 floor 30、job floor 5（`OCOREAI_README_FLOOR_ROUTES`/`_JOBS`），防「正则烂掉→拿空集比空集」空过。`V1EndpointCatalogTests` +3：publicPaths == 文档化那 7 条；`/v1/perception` == `key`；router 内凡提到 `AuthMiddleware` 的行不得枚举 ≥2 条路由（正是②那条错注释的形状）——既有 `authColumnIsDerived` 只证明「派生」，证明不了「集合对」，所以这三条不可省。**红样全部实测**：删 README 一行 ⇒ `P10 README.md omits 1 endpoint(s) … GET /v1/perception`；把 `/v1/perception` 塞进 zh 的 public 句 ⇒ `public-route list != AuthRoutePolicy.publicPaths (extra: /v1/perception)`；把 `/v1/perception` 加进 `publicPaths` ⇒ 两条新测试同时红（静默放宽鉴权会变响）；还原后 `git diff` 该文件为空。绿态：`--filter V1EndpointCatalog` **9 tests / 1 suite 全绿**；`make docs-check` ✅（claims **12→22** 全过、`README tables=34 rows,34 rows`）、`make anchor-check` **checked=37 / drift=0**（local 26→28，新锚 `anchor:. Sources/ocoreai/App.swift:701 globalRate: 200` ×2）、audit 与 format 全绿。
- **root 守棘轮** — Documentation Map 的 README 行从「Human」升级为 P10 门，Docs Contract 段补上此前漏记的 **P9** 与新 **P10**；B1 只减不增（cap 50668），故同步删掉 Workflow 里与 § AI Contribution Policy 2 重复的那条「commit message 带验证证据」（规则留更强的一份），并收紧 Wiki/hermes/struck 行等冗句 ⇒ root **50652/50668**（仍留 16 字节余量）。
- **未证 / 未做（不冒充）** — ①本轮对 `Sources/` 的改动**全在注释内**（零运行路径变更），故未重跑 17 条探针与全量套件；新测试只单跑过（绿、红各一次），权威仍是 CI macos-26。②`/v1/perception` 该不该进 public 未决（见②）。③P10 定位「public 那句」靠「同一行同时含 `/health` 与 `/metrics`」，日后若把它拆成两行会判红而非静默通过——响亮，但确实是个形状依赖。④CHANGELOG 里既有的 `README.md:101` 一类行号随本轮 README 增行而后移（anchor-check 不扫本文件）：日记按落笔时点读，不追改；要新证据请重跑命令。
**10-20(续13) 测量只写在日志里，等于没测——`toolProse` 现在和 prefixReuse 同一条响应**(P3 可观测性 + 不变量 2 + P2 消一份重复映射) — `ToolProseLedger` 从落地那天起就算得出「这个 checkpoint 自己会不会声明工具」，但那份答案只有读得到进程日志的人看得见；HTTP 客户端看不见，就不知道自己声明的工具送出去是一次还是两次。

- **成本不是修辞** — 同一模型实测（探针 16，`mlx-community/gemma-4-e2b-it-4bit`，temp 0）：一次声明使 delivered `prompt_tokens` +95，第二个工具再 +52；`## Tool:` 由谁写、写了几个，直接决定这份上下文有没有白花。这类事实属于不变量 2 点名的那一类：用户读得到的能力句必须是测过的，且后端缺席时要诚实降级。
- **落点与单一真值** — `GET /v1/models/:model/kv-cache` 增加 `toolProse` 行（`mode` / `templateRendersTools` / `reason`），与 `prefixReuse` 同处一号响应：一次请求答完这个模型的两条已测事实，不新开路由、不把 per-model 事实抄进全局 `/v1/capabilities`（抄一份＝两个真值）。行与句子都造在 ledger 上（`Sources/ocoreai/Engine/ToolProseLedger.swift` 的 `wireMode`/`observation`），publish 处不自己拼词；顺手消掉同一映射的第二份——`templateRendersTools(modelId:)` 原本自带一个 switch，改为复用 `measuredTemplateRendersTools`。
- **null 必须真是 null** — 合成 `Encodable` 对 optional 走 `encodeIfPresent`，nil 时键整个消失；而「这台没测过」与「这版忘了发布」必须是两件事（正是 10-13 那条 decode 侧 `stream` 教训的镜像面）⇒ 手写 `encode(to:)`，未测输出 `"templateRendersTools": null`。日志用 camelCase（`skippedTemplateRenders`）、线用 snake_case（`skipped_template_renders`）：同一值的两种书写都由同一处派生（enum 上没有地方塞第四个值），因此探针可以要求两者互相对上。
- **判据（哪条会红）** — `Tests/ocoreaiTests/ToolProseLedgerTests.swift` +4：词表闭集（snake_case 三值精确相等）；每条行的 mode/测量/理由必须与产生它的 mode 同音，且 `injected_unmeasured` 的行里不得出现 "renders"；未测行的键必须存在且为 `NSNull`；publish 只有一个缝（`ToolProseLedger.shared.observation(modelId:` 计数 ==1）且 DTO 默认值是诚实值 `injectedUnmeasured`——忘了传也只能降级、不能自称测过；扫描自身带 floor。探针 `scripts/probes/16-tool-declaration-duplication.sh` 新增 §5 活体交叉校验：payload 无 `toolProse.mode` / mode 出闭集 / 线模式与 §2 日志模式不对应 / 键缺失而非 null / mode 与测量互相打脸 / `reason` 空 ⇒ 一律红。文档同步：`Sources/ocoreai/Router/V1EndpointCatalog.swift` 的 kv-cache note 现写明该端点还公布 tool-declaration 处置（这条 note 是 404 hint 与端点索引的正文，客户端据它决定读什么）。
- **实测** — 探针 16 活体 **7 passed / 0 failed / 10 measured / 0 known-open**（§5：`toolProse.mode=skipped_template_renders`、`templateRendersTools=true`、`reason=present`，与同一次 run 的日志行 `Tool prose skippedTemplateRenders …` 同音）；`swift test --filter "ToolProse|KVCacheStatus|PrefixReuse|V1EndpointCatalog|CapabilityMeasurement"` = **52 tests / 6 suites 绿**；`docs-check`、`anchor-check`（checked=35 / drift=0）、`audit`、`format-check` 全绿（后者先重排本轮新增 Swift，working tree 保留后复跑为 zero files reformatted）。
- **未证 / 未做（不冒充）** — ①活体只出得来 `skipped_template_renders`：本机唯一在盘模型 gemma-4 的模板实测会渲染工具；`injected_unmeasured` 的显式 null 与 `injected_template_ignores` 两条形状只有单测覆盖，活体需要一个「已加载但模板拒收 probe feed」或「模板忽略 tools」的 checkpoint，本轮没有。②`reason` 上wire 后与日志同句，但没有为「同句」再加一道编译期约束（靠探针 §5 与 `reasonPhrase` 单测钉住）。③未把该事实复制到 `/v1/models` 或 `/v1/capabilities`（刻意的 home 选择，见上）。④本轮动了 Engine 侧生产代码（ledger + DTO + 一处 catalog note），未跑全量门 `make test-clt`，CI macos-26 仍是权威闸。

**10-20(续12) Apple 在 #354 修的是「分类错⇒写偏移 0⇒静默出垃圾」——逐条对完本仓三条缺陷形状都不在，但把「不在」变成判据**(P0 上游偏离 + P3 判据补口) — 接上一轮 drift 顶出的窗口 `bd61eb1..9e120659a`（coreai-models +8）。

- **读到哪儿，如实说** — api 通道报 HEAD=`9e120659a` +8；本机 mirror `git fetch` 超时（`Recv failure: Operation timed out`），`bd61eb1..origin/main` 本地只有 **7 条可读** ⇒ `#358 Remove prerelease allow` 本轮未读。**因此不 adopt 基线**：钉到未读点会把没读过的段落伪装成已裁决（本仓反复警告的时龄失真，先例 = 10-14 把 codex 基线只钉到最后逐条读过的 SHA）。
- **四条在 Python/export 轴，透明** — `#349` CONTRIBUTING 拆分（`.github`+README）、`#352` palettization export flag（`python/src/coreai_models/export/{compression,pipeline}.py`）、`#321` Qwen3.5/3.6/3.8 macOS export（`python/…/primitives/macos/cache.py` + 930 行测试）、`#334` opt-in batched/attention-mask export（python export + 684 行）⇒ AGENTS.md § Upstream Audit #2 写死「Python/export-side commits are consumer-transparent：ocoreai 无 Python、无 export 面」⇒ 0 生产面变更。
- **同轴的是 #354（三段）/#351/#328**。#354(a) 分类错：静态 shape 的 `keyCache` 只因名字含 "cache" 被判 sliding ⇒ sequential 引擎切 compact position_ids ⇒ 图从 position_ids 推写偏移 ⇒ 每个 prefill 块与每步 decode 都写在 offset 0，chunked prefill 把每块当成孤立序列打分、greedy 崩坏，**且全程不报错**；修法是「静态 cache 只在名字含 sliding 时才算 ring」＋「静态 KV 取 traced length 作固定容量」。本仓对照：`Sources/ocoreai/Engine/StateHandler.swift:252` 的 `inferKind` **名字优先**（kv/cache_key/cache_value→kvCache，sliding/window→slidingCache，recurrent/conv/memory→fixed），形状兜底在最后一层且静态落 `.fixed`（不是 sliding）⇒ 上游那条灾难路径不成立；再下一层保险：两个引擎都用字面 `useCompactPositionIds: false`（`Sources/ocoreai/Engine/CoreAIPipelinedEngine.swift:711`、`Sources/ocoreai/Engine/CoreAISequentialEngine.swift:135`，注释自陈 ring 路 #202 pending）⇒ compact 位编码这条机制在本仓根本不存在。残余偏离如实记：上游修完后静态 `keyCache` 判 `.kvCache`、本仓判 `.fixed`，差别落在「这类 bundle 能不能跑」——本仓在 `growingNames.count >= 2` 守卫处**响亮拒绝**并逐态点名（`Sources/ocoreai/Engine/CoreAIPipelinedEngine.swift:688`），是可用性缺口，不是正确性缺陷；且路由把 `.chunkedStatic → .staticShape`（`Sources/ocoreai/Engine/CoreAIEngine.swift:798`），此类 bundle 另有车道。
- **#354(b) 约束路漏 `additionalStates`**（>2 states 的 bundle 第一次 constrained encode 报 "Missing state view"，Muse Glimmer 的 sliding-ring 对；上游补一行 `additionalStates?.bind(into: &asyncStates)`）：本仓所有 encode 走同一对 `_CoreAIEncodeHelpers.encodeWithStates`/`encodeWithStatesNoOutputs`，两个 helper 都绑定（`Sources/ocoreai/Engine/StateHandler+Encode.swift:31`、`:57`），约束路调用点在 `Sources/ocoreai/Engine/CoreAIPipelinedEngine.swift:1889` ⇒ **该缺陷形状不存在，且是结构使然**（单缝 ⇒ 无从遗漏）。**#354(c)** ring 写后 attend 毁掉 prefill 自身 Q−1 个 in-window 历史：那是 CoreAI 框架内原语（`RingKVCache.update_and_fetch`），本仓无环实现（`update_and_fetch`/`RingKV`/`ringCache`/`slidingKeyCache` 命中均 0）⇒ 透明。**#351 Honor language.states**（Swift：`ModelConfig.swift` +7 + 71/20 行测试；上游同窗口把 pipelined 的 `stateKinds: nil` 换成 `stateKinds: config.states`）⇒ **本仓真偏离**：`classifyStates` 早就接受 `stateKinds:` 覆盖，但没有任何调用者供 config 声明的 states（`languageStates`/`"states"` 命中 0），分类只吃名字与形状；不即刻照抄的理由是我们这层没有「声明 states」的来源，硬造字段＝造一份没有生产者的第二份真值（不变量 2 的反面）⇒ **留人拍板**（来源选 bundle manifest 还是 ModelConfig 手写）。**#328 fp8 KV Cache resizing** 只改 `KVCache+CoreAI.swift` 3 行 ⇒ 未逐行比对（记未证）。
- **把「不在」变成判据** — 新 `Tests/ocoreaiTests/CoreAIStateClassificationTests.swift`(3)：① async state views 只许在 `_CoreAIEncodeHelpers` 那一缝构造，且缝内 bind 数 ≥ 容器数；②两个引擎的 `useCompactPositionIds` 决策必须全为 `false`（参数声明 `: Bool` 与 InputLayout 自转发不算决策，但扫描命中数 floor ≥4，防「扫不到就算过」）；③`guard growingNames.count >= 2` 与它的话术必须还在，且 sliding 仍由名字推得。三条全是文本级 ⇒ 这些文件在 CLT SDK 被 `canImport(CoreAI)` 整块编译掉也照跑（本机永不可运行 CoreAI 是 §Open 既有事实，静态门是当前唯一可用仪器）。**绿样**：`swift test --filter CoreAIStateClassificationTests` = 3 tests / 1 suite 绿。**红样**：删掉一条 `additionalStates?.bind(into:` ⇒ ①当场红并写明「2 state container(s) but only 1 additionalStates bind(s) … silently reintroduced」；还原后 `cmp` 证明与绿态字节一致。
- **未证 / 未做（不冒充）** — ①`#358` 未读（fetch 超时）⇒ 基线未 adopt，`make drift` 会继续报这个窗口，这是有意的信号；②`stateKinds` 的来源缺口未拍板，本仓不单方面加字段；③#328 与本仓 `KVCache+CoreAI.swift` 未逐行比对；④这些 CoreAI 路在 macOS 26 交付机上永不运行，本轮判据均为静态、零活体；⑤codex +228 窗口仍未裁决；⑥本轮零 Swift 生产面变更（只加测试），未跑全量门，CI macos-26 仍是权威闸。

**10-20(续11) 「上游已发布」与「main 上有 commit」是两件事——mlx-swift 补一条 tag 轴，并修掉 manifest 自己写着的两条过期事实**(P0 上游偏离 + P0 文档↔代码 + P3 判据补口) — 三轴 drift 盯了 HEAD 七天，唯独漏了本仓另一个 `exact:` pin；补上之后第一次跑就看清：已发布面 0 偏离，而 main 上 8 条里 5 条正落在我们直接调用的那几个文件上。

- **一手证据（live，非推断）** — `git ls-remote --tags origin`(ml-explore/mlx-swift) 最新 tag = `0.32.3`；`git describe --tags --exact-match 19601207e`(= `Package.resolved` 记的 revision) = `0.32.3` ⇒ **pin 就是最新 release，已发布面无偏离**。`origin/main` = `35c10b495`，`git rev-list --count 0.32.3..origin/main` = **+8**。跑前先 `git fetch --tags`：该 checkout 的 `FETCH_HEAD` 原本停在 `2026-10-10T22:35Z`——把「上一次 fetch」当「现在」正是本仓点名的时龄失真。
- **为什么这一轴必须以 tag 判定** — 本仓对 mlx-swift 下的是 `exact:` tag：main 上没打 tag 的 commit，任何 Swift 消费者都拿不到，「HEAD 领先 N 条」在这里不是待办，只是下一次 tag 的审计输入。⇒ `scripts/upstream-drift.sh` 新增第四轴 mlx-swift：tag>pin → ⚠ exit 10（走 bump 协议）；tag==pin → 已发布面 0 漂移，main 领先降级成 ⚑ 提示且不动退出码；⚑ 段只列「落在 ocoreai 直接消费的 MLX 文件」上的 commit，谁动了我们调的路面一眼可见。通道实测：本机 `gh` 未装、`api.github.com` 的 repo 端点挂起（HTTP `000`，而 `/rate_limit` 回 200）⇒ tag 走 `git ls-remote`（可用），再失败回落 checkout 本地 tag 并打出 `FETCH_HEAD` 时龄，绝不把镜像说成权威。
- **⚑ 那 5 条与我们的关系（逐条，行号取 main 侧复核值）** — · `1e61d9c2` #499 把全局 stream 从 `RealizedStreamPromise` 改成 `LazyStreamPromise`（`Source/MLX/Stream.swift:186` 的注释自己写着 "avoid the lock inversion"），破 `evalLock ↔ dispatch_once` 环 ⇒ 我们唯一那行 `Sources/ocoreai/Engine/EngineInference.swift:3558 Stream.gpu.synchronize()` 正是这条修的路面；· `2f96983a` #474 `public func eval()` 改为 `MLX.eval(self)`、同步 eval 不再持 evalLock（`Source/MLX/MLXArray.swift:556`）⇒ 正是 `Sources/ocoreai/Engine/MLXBridge.swift:1218 result.eval()`；· `35c10b49` #486 `physicalSize` 对 `size == 0` 先返 0（`Source/MLX/MLXArray+Bytes.swift:37`），修 `asArray` 在零长数组上 nil 解引用崩溃 ⇒ 我们调 `asArray` **4 处**；可达性只到静态一层：唯一能让 `text.tokens` 为空的入口是空 `messages`，而 router 三处 floor（`Sources/ocoreai/Router/ChatCompletionsRouter.swift:432`、`:550`、`:621`）先答 400，故判不可达（活体未证，见末条）；· `f93decf4` #501 `_updateInternal` 改「建新再 free」，因为 `mlx_array_set` 是 C++ 拷贝赋值、跳过析构 ⇒ 被 `Module.update(parameters:)` 替换的未求值多输出（`QuantizedLinear` 的 `Quantize` 输出）会漏整张图，与「4-bit 权重常驻」的内存账同轴，但我们是否走到该路径未证；· `b4f76843` #496 fp16 causal mask 由 `* -1e9`（fp16 下溢成 `-inf`）改 `* (dtype.finfo?.min ?? -1e9)`（`Source/MLXNN/Transformer.swift:112`）⇒ 掩码取值语义变了；我们的注意力掩码出自 lm/模型实现（lm 仅在 `Libraries/MLXLMCommon/KVCache.swift:371` 注释提到同一想法），**这条影响是推断，不是测量**。
- **顺带清掉的两条 P0 文档↔代码不一致（正是它们让上面 5 条一度不可见）** — ① manifest 注记写着 lm 的 floor 是 `.upToNextMinor(from: 0.32.2)`（#646 时代的话），而我们 pin 的 lm revision `48114eedf` 实际写 **0.32.3**（`.build-clt/checkouts/mlx-swift-lm/Package.swift:67`，`git show 48114eedf:Package.swift` 同点复核）⇒ 0.32.2 如今连解析都过不了，那句「floor 论证」讲的是更旧的一份契约；② manifest 写着「ocoreai 唯一的直接 MLX 面就是这两个调用」，实测 `Sources/` 达 MLX **10 处 / 5 API**（8 个 call+construct + 2 个 `MLXArray` 型属性：`asArray` 4 处、embedding 路构造 `MLXArray(…)` 与 `MLXArray.zeros(like:)`，型属性在 `Sources/ocoreai/Engine/EngineInferenceSupport.swift:153`）⇒ 少报一整条 API，而 #486 修的恰是它。两处已改真，并把消费面写成 9 条 anchor：`make anchor-check` 现 **checked=35 / drift=0**（local 19→26、upstream 7→9），其中新增 `anchor:mlx-swift-lm Package.swift:67 .upToNextMinor(from: "0.32.3")` 把 lm 的 floor 钉在它自己的 pin 上。
- **判据（哪条会红）** — `Tests/ocoreaiTests/DependencyPinStatementTests.swift` +3（目标套件 **7 tests / 1 suite 全绿**）：① `consumerSurfaceIsTheAuditedSet` 自己走一遍 `Sources/`（先 floor 自身命中 ≥8 处、≥5 API，防「扫不到就算过」），再要求 manifest 逐条点名每条 API 并写出实测的 `10 sites`/`5 APIs` ⇒ 以后新增一处直接 MLX 调用而不更新审计，红；② `pinSatisfiesLmsTransitiveFloor` 从 checkout 读 lm 的约束做区间包含（`exact:` 必须 ≥ floor 且同 minor），并要求散文把**当前** floor 写出来 ⇒ lm bump 后散文不更新就红；shape 变了走 `Issue.record` 不静默放过，`.enabled(if:)` 仅在完全没有 checkout 时 skip（skip 可见）；③ `driftScriptCoversBothPinnedUpstreams` 钉死仪器覆盖 4 条轴、且 mlx 轴必须 `ls-remote --tags` + `sort -V` + 从 `Package.resolved` 读 pin ⇒ 轴被删掉或改成判 HEAD 就红。另加 `make drift` 入口：此前脚本没有任何入口，`.upstream-baseline.json` 的 `checked_at_utc` 停在 **2026-10-13**（空转 7 天）。红样：把 prose 的 `10 sites` 改成 `9 sites` ⇒ ① 当场红（同一 scratch 实测）。
- **写门时自己踩的一次，如实记** — 第一版 floor 正则把字面 `)` 写进了引号内（`…([0-9]+\.[0-9]+\.[0-9]+)\)"`），语义变成要求文本 `"0.32.3)"`，而真实是 `"0.32.3"))` ⇒ 匹配不到。因为守卫用的是 `Issue.record` 而非静默返回，它当场让套件红、没有假绿——但报的原因（「上游 shape 变了」）不对，真原因是本门的模式坏了。已把「模式编译失败」与「匹配不到」拆成两条不同消息：一条判据说错原因，和判据不响一样有害。
- **实测输出（`make drift` 同一次运行）** — `mlx-swift  tag=0.32.3 pin=0.32.3  0 new release  ✓ 已发布面无漂移（newest tag == pin，src=ls-remote）` + `main=35c10b495 +8 commits（未发布 ⇒ 非待办，是下一次 tag 的审计输入）` + ⚑ 5 条清单；同一次运行顺手顶出两个**真待裁决**窗口：coreai-models `bd61eb1..9e120659a` = **+8**（含 #328 fp8 KV Cache resizing、#354 static-shape/sliding-ring KV-state 修复——与我们 KV 账同轴）、codex `efa159f7a..8196bcdc1` = **+228**（基线停在 10-13）。
- **未证 / 未做（不冒充）** — ①这 5 条对 ocoreai 的**实际影响**未做活体测量：#499/#474 是并发锁序（要并发压测才可能撞上）、#496 要比 fp16 logits、#486/#501 要分别构造零长 tokens 与 `Module.update(parameters:)` 路径；本轮结论不依赖它们——**没有更新的 tag 可采纳 ⇒ 策略上零待办**，因此不 bump（0.32.2 教训仍在：tag 才是可分发的承诺）。②#486 的可达性只到 router floor 的静态论证，未测「绕过 router 直调 handler」（`Sources/ocoreai/Handlers/ChatHandler.swift:227` 的注释自己承认直调会 downstream failures）。③#501 是否被我们触发未证（本仓无 `update(parameters:` 直接调用点，lm 侧未逐行读）。④coreai-models +8、codex +228 两窗口本轮**未裁决**，另立轮次；`make drift` 尚未接入 CI（本地仪器）。⑤本轮零 Swift 生产面变更，全量门未跑（跑了目标套件 + `docs-check`/`anchor-check`/`audit`/`format-check` 四道快速门），CI macos-26 仍是权威闸。

**10-20(续10) 会话状态不许冒充代码回归——`AppLifecycleLiveTests` 学会自证前提**(P3 判据可信度 + P0 一致性) — 上一轮把「那三处红是锁屏」写成了文档；本轮把它变成判据本身，并补上此前**没人断言**的另一侧。

- **一手证据（本机实测，非推断）** — 锁屏会话里 `open_app(Finder)` 返回 `app=com.apple.finder running but activate failed (pid 490; never became frontmost (frontmost=com.apple.loginwindow)).`：Finder **确在运行**（pid 490），失败原因自己写着真实占有者 = loginwindow。测试却断言 `out.contains("already running")`（等于要求「已成功激活」），`activate_app` 同样断言「必须 → frontmost」⇒ 只要锁屏，全量门必报三处红（本轮起点 `make test-clt` = 2755 tests / 489 suites、3 issues 全在此），真回归会被这份固定噪音埋掉。
- **改法（`.enabled(if:)` 读实测占有者，两侧各测各的）** — ①`frontmostBlocker`：把 frontmost 的三种占有者各写成原因（`nil` = headless/ssh、`com.apple.loginwindow*` = 锁屏/登录窗、`com.apple.WindowServer`），可上前台则 `nil`；②两条「必须上前台」的测试挂 `.enabled(if: frontmostBlocker == nil)`，**断言一字未放宽**；③新增 `liveActivateAndOpenNameTheirBlockerWhenLocked`（`.enabled(if: frontmostBlocker != nil)`）钉死降级侧：`activate_app` 必须含 `never became frontmost`、`open_app` 必须含 `activate failed`/`never became frontmost`、两条都不得写出成功句式（`→ frontmost` / `→ activated`），且必须点名 `com.apple.finder`（若连工具都没被点名，失败原因就不是「上不了前台」，判据当量级重估而非放过）。两侧互斥，各自只在自己声称成立的前提上开口 ⇒ 没有哪一侧能靠空断言蒙过去。
- **实测（同一 scratch，锁屏会话）** — `swift test --filter AppLifecycle` = **13 tests / 2 suites 通过**：`activate_app(Finder)` 与 `open_app(Finder)` 各报 `➜ Test … skipped.`（在输出里可见，不是静默消失），降级条 4.656 s **真跑**并绿（它确实调了两个工具、读到 loginwindow 的占有并逐条校验措辞）。
- **同一判据的另一侧（解锁会话再跑一次全量做对照）** — 稍后这台机器可上前台，`make test-clt` = **2756 tests / 489 suites、EXIT=0**：本仓在本机**首次零失败全量门**（此前每轮固定三处红）。两条 Finder 断言真跑并绿（`activate_app` 0.079 s、`open_app` 0.059 s），降级条 `➜ Test …skipped.`；全量里 skipped 只有两处——`readTree`（AX 未受信，既有 `.enabled(if:)` 门）与这条降级条。于是「谁的前提谁负责」两侧各有实测记录，而不是纸面设计：锁屏那次是 2 skip + 降级绿，解锁这次是 2 绿 + 降级 skip。
- **为什么这不是放宽** — 会话能上前台时（解锁的开发机、CI macos-26）跑的就是原来那两条断言，一字未改；锁屏时改测「必须诚实降级」，比原判定更严：旧失败只说「没上前台」，新判据额外禁止任何成功句式并强制点名占有者与目标 app。skip 与 fail 的分工从此是**谁的前提谁负责**，而不是让环境替代码顶罪。
- **未证 / 未做（不冒充）** — ①「锁屏会话里 Finder 是否总在运行」未穷举：判据里有「两条回答必须点名 `com.apple.finder`」兜住，不成立时会红而非静默放过；②`.enabled(if:)` 的 skip 不计入 `N tests passed`，只有 `➜ skipped` 行可见——要让 CI 摘要显式统计 skipped 需在 workflow 解析 xunit/`➜`，本轮未动 CI；③屏幕抓取、ChatView/MultimodalControls 等 UI 活验仍挂 §Open（同源不同症：SCStream 在无 GUI 会话起不了流）。

**10-20(续9) 契约文件自己说的话没人读——`Package.swift` 的注记现与 pin 同音**(P0 文档↔代码不一致 + P3 判据补口) — 不变量 1 说的是「判据断言自己的前提」；本轮发现有一处连「有人读」都谈不上：manifest 用一整段注释解释它为什么钉这个版本，而那段话与 pin 已经矛盾，且没有任何判据扫这个文件。

- **一手证据（本轮逐条 grep 实测，非推断）** — pin 之上写着 `pin to the 0.32.2 tag (main HEAD 2b5e877)`，pin 本身却是 `exact: "0.32.3"`（`0401256` 于 10-05 上移，理由=0.32.2 在 macOS/iOS <26.4 启动即崩，CHANGELOG 当轮已裁决）；同一段注记的两条消费面 cite 也早飞了：`EngineInference.swift:3344` 实为 `:3558`（差 **214** 行）、`MLXBridge.swift:1094` 实为 `:1218`（差 **124** 行）。既有版本判据只比包名集合（`ThirdPartyNoticesTests`），anchor 门的扫描集只含 `*.md` 与 `Sources/**/*.swift` ⇒ 两处漂移一路绿过 CI。
- **改法（接进既有两道门，不新造机制）** — ①注记重写：exact 0.32.3（resolved `19601207e`）；为什么不是 0.32.2（上游 0.32.2 release notes 首行就是 "Use release 0.32.3"，#491/#493 与本包声明的 macOS 14 / iOS 17 正面冲突）；floor 论证为何仍成立（lm #646 把自身约束抬到 `.upToNextMinor(from: 0.32.2)`，0.32.3 天然满足，direct pin 与 lm 传递依赖不打架）；0.32.2 时代那两条内容理由（#450 解 `IPHONEOS_DEPLOYMENT_TARGET=27`、cd36d17 让 mlx-c custom-io 返回读写字节）为何仍然相关；②两条 cite 改成 anchor 形式并把 `Package.swift` 纳入 `scripts/anchor-check.sh` 扫描集 ⇒ `make anchor-check` **27 条（local 19 / upstream 8）全绿**；③新 `DependencyPinStatementTests`（4 tests，prose↔pin↔resolved 三处同音 + 「带裸 `file.swift:NNN` cite 必带 anchor」，含 `.package(` ≥8、resolved pins ≥8、两个上游身份必须读出 revision 等自证地板）。root `Package.swift:43` 与 `docs/agent/comparator-repos.md` 的 cite 复核后仍未动（lm pin 还在 43 行），`_lib.sh` 取 pin 用正则不靠行号。
- **门在被写的过程中抓到我自己两次（判据先要证明自己读得对）** — ①`Package.resolved` v3 把 `revision`/`version` 嵌在 `state` 下，直读 `pin["revision"]` 全是 nil：若不额外断言「两个上游身份必须各自读出 revision」，这条门会因为**什么都读不到**而假绿；②新注记里复述旧说法的那句（原样引用 `pin to the 0.32.2 tag`）被同一门的句式判据判红 ⇒ 历史叙述换成不触发判据的写法，判据只钉「声明 pin 的句式」本身。同一族错误还有 `Substring` vs `Comment?`、恒真的 `range(of:)`（漏 `.regularExpression`）——判据编译不过或恒真，比它想防的漂移更坏。
- **反向验证（门真会红）** — 注记改回 `pinned exact 0.32.2` 后 `--skip-build` 重跑（测试读文件而非编译产物）⇒ `Package.swift prose says 0.32.2 while the pin/resolution says 0.32.3`；cite 改回 `:3344` ⇒ `DRIFT … really line 3558 of 4951`。两处恢复后全绿。
- **未证 / 未做（不冒充）** — ①prose 门只钉 `exact:` / `revision:` 两种约束形态（本包需要钉的就是这两条上游轴），`from:`/`branch:` 形态暂无对应断言；②注记转述的上游事实（#491/#493/#646/#450/cd36d17）未在本轮逐条对上游 HEAD 重核，只核了 pin 本身——`git ls-remote` 现测 mlx-swift-lm `origin/main` == pin `48114eedf`（**无漂移**），mlx-swift `origin/main` 已到 `35c10b495`（我们钉的是 tag 0.32.3=`19601207e`，是否跟进另轮按 bump 协议裁决）；③其余依赖暂无「关于版本的 prose」，也就没有可钉之处——将来谁在 manifest 里写版本理由，这条门得先长出手。

**10-20(续8) video 的断言跟着交付走，不跟着池子走**(P0 行为不一致 + P3 可观测性) — §Open 那条「guided-gen / MTP 提前 release 的轮次漏记 video」是**按管线形状推断出来的**，逐行读守卫即知它不成立；真正的漏报在另一条车道上，本轮把它活体量了出来。

- **先证伪自己写过的话** — guided 分支守卫 `mlxMessages.allSatisfy { images.isEmpty && videos.isEmpty && audios.isEmpty }`、MTP 分支同一形状（`EngineInference.swift:3270` / `:3328`）⇒ 带媒体的轮次根本进不了这两条路；grammar + 媒体是**落到 ChatSession 并丢掉约束**（日志 `Dropping grammar constraint for multimodal message`）；ANE 见到媒体就回落 GPU（`:1615-1659`）；FM 只吃 `fmPromptText`。四条早退路径都不携带帧，也就无从漏记。`VideoDeliveryLedger.swift` 头部那段据此起手改写——「关于管线的断言」必须能被它声称读到的量读出来。
- **一手证据（活体 · 新探针 17 · `OCOREAI_SESSION_POOL=0`）** — 无池车道先自证前提：启动日志 `MLXSessionPool disabled … — OCOREAI_SESSION_POOL=0`，同一会话第二轮 `cached_tokens=0` 且日志 0 条 `Session pool HIT`。交付：无 clip 基线 `prompt_tokens=712` → 红帧 `856`（**+144**），答 `Red`（无 clip 时答「I require context…」）。**修复前**同一台服务器 `/v1/models` 仍报 `videoInput=not_observed`（探针 17 = 7 passed / **2 failed**）；**修复后** `delivered`，证据行 `delivered in 1 completed turn(s), 1 video part(s), last prompt_tokens 856 on this server`（9 passed / 0 failed）。
- **根因（一句）** — 记录点原先坐在 `releasePoolSlotWithAssistant` 的 `if let pool …, let pooled …` 里：池不存在时整块是 no-op。两条车道没有池——CPU 车道 `poolRef = nil`（`:1947`，HardwareRouter 压力降级）与关池引擎 `sessionPool = nil`（`EnginePool.swift:408`）——而它们照样把每一帧交给 processor。于是客户端拿到正确答案，选型却看着 `not_observed`：不变量 2 的反方向，且既有判据全跑在有池的车道上，所以全绿。
- **改法（一个家）** — `recordVideoDelivery(promptTokens:)`（`EngineInference.swift:3240`）在推理体正常收口处调用（`:4691`，紧接 `releasePoolSlotWithAssistant`），`items > 0` 守卫与那句日志一并搬进 helper：池的归还与断言的落地就此解耦，`videoDeliveries.record(` 全树只剩这一处。仍**刻意不记**「交了帧却一个字没答」的轮次——`delivered` 的语义是收帧且答出，方向写在文件头部。
- **新增开关（这条车道必须随时走得通）** — `SessionPoolPolicy`（`Engine/SessionPool.swift`）：`OCOREAI_SESSION_POOL=0|false|off|no` 关池；config 关掉的池不许被环境反向打开；未识别的值不禁用（`ture` 是 `true` 的笔误，不是关池请求），且启动日志必须点名是哪个开关关的，探针据此自证前提而不是假设走到了。
- **门（回归时谁变红）** — 新 `Tests/ocoreaiTests/SessionPoolPolicyTests.swift`（6：每种 off 拼写逐值、config 为 nil = 无池、`ture`/空串不改行为且 override=nil、环境不得打开 config 关掉的池、变量名钉死）＋新 `Tests/ocoreaiTests/VideoDeliveryPathTests.swift`（6：全树扫描并地板 >150 个文件、`videoDeliveries.record(` 全树恰一处且必须在 helper 内、`releasePoolSlotWithAssistant` 体内**不得**出现记录、调用恰一处且位于 RAII catch 与 release 之后、guided/MTP 守卫仍含 `.videos.isEmpty`（媒体守卫总数 ≥2 作地板——将来谁给这两条路开媒体，这里先红并逼他重看记录缝）、断言日志句恰一处）。**反向验证**：把记录搬回池内 release 重编译 ⇒ 静态门 **3/6 变红**（含 `!release.contains("videoDeliveries.record(")`），探针 17 活体 **2 failed**；恢复后 22 tests / 3 suites 全绿。文档同轮改写：`Sources/ocoreai/Engine/AGENTS.md` 视频节 + anchor `:3232`→`:3242`，root §Open 撤回旧结论（净字节不增）。
- **未证 / 未做（不冒充）** — ①内存压力那条 CPU 车道仍无法主动制造，本轮走的是同一条 `poolRef/sessionPool == nil` 的等价车道（判据也仅此所能）；②「交了帧但没答出」是否该记，未测；③`delivered` 至今度量的是「把部件交给模型」，服务端不校验 processor 是否真把帧展开进 prompt（+144 由探针在活体上量，引擎内没有同会话的无媒体基线）；④guided/MTP 若将来放开媒体，记录缝必须同步重看。
- **顺带（harness）** — `lower()` 与 clip 渲染上收到 `scripts/probes/_lib.sh`（探针 08/17 共用）：macOS 默认 bash 3.2 没有 `${VAR,,}`；而 helper 若在 `$(…)` 子壳里 `probe_fail`，计数会随子壳一起消失、坏夹具照样报绿——故字节数改由 `PROBE_CLIP_BYTES` 传出，失败返回非零由调用方 `probe_summary` 收口。

**10-20(续7) 一个工具只投一次：谁写这条声明，由 checkpoint 的模板实测说了算**(P0 上游偏离 + P2 重复抽象收口 + P1 执行链 + P3 可观测性) — 接上一轮那台仪器：数字钉住了缺陷，本轮把刀下在缺陷处，并用同一支探针证明它不再复现（XFAIL 随缺陷一起消失）。

- **一手证据（本机 `mlx-community/gemma-4-e2b-it-4bit`，temp 0，活体）** — 装载即决策：日志 `Tool prose skippedTemplateRenders for mlx-community/gemma-4-e2b-it-4bit — this checkpoint's chat template renders tools itself…`。逐轮：①声明 1 条工具 ⇒ 日志 `0 ## Tool: block(s) written`，交付 `prompt_tokens` +95（模板 `<|tool>` 约 51 + 本服务 action directive 约 44），**修复前同一轮是 +116 tokens / +302 chars，其中我们的 `## Tool:` 块约 21 tokens**（上一轮把整个 +302/+65 都叫「prose」，本轮拆开：guidance 约 44、prose 约 21、模板约 51）；②声明 2 条 ⇒ 仍 0 块、+147（第二条再 +52）⇒ 一次一条且随 surface 线性；③调用照旧落地：探针 11 **20 passed / 0 failed**（`arguments` 是 JSON 对象 `{"city":"Paris"}`、`tool_choice:"required"` 强制得出调用、SSE `tool_calls` delta、`toolCallDelivery=parsed` 证据行点名 `get_weather`），探针 13 **37 passed / 0 failed**，探针 16 **6 passed / 0 failed / 0 known-open**（上一轮的 XFAIL 不再出现）；④GUI 全表面 39 工具：`prompt_tokens 774 → 6519 (+5745)`，这 5745 现在全是模板渲染的原生 schema，不再叠我们的散文。
- **改法（一个家 = `ToolProseLedger`）** — ①`Engine/ToolProseLedger.swift`：`ToolProseMode` 三值闭集（`skippedTemplateRenders` / `injectedTemplateIgnores` / `injectedUnmeasured`）+ 纯函数 `ToolProseRule.decide(Bool?)`（**`nil` ≠ `false`**：没测过不等于不渲）+ actor 账本；句子措辞住在 mode 上（`logLine`），装载处与逐轮处打印同一个句子，两处各自组装必然各说各话。②`Engine/MLXBridge.swift` `chatTemplateRendersTools()`：同一份「一条消息」的 feed 走 `applyChatTemplate` 两遍（带 / 不带一条探针工具），比 token 长度——量的是渲染结果，不是 config 键（`processor_class` 那种「关于类的断言」正是本仓拒绝公布的东西）。③`Engine/EnginePool.swift`：装载完测一次并写日志，`unloadModel` 里 `forget`——这条答案属于这副权重，不许越过它的寿命。④`Handlers/MessageBuilder.swift` Phase 5：**只有测得「本模板不渲 tools」才写 prose**；未测得照旧写（默认等于旧行为，不是猜），并把这一轮真正写了几个 `## Tool:` 块直写进日志。
- **上游对照** — vllm（`entrypoints/openai/chat_utils.py`）与 sglang（`srt/entrypoints/openai/protocol.py`）都只有一条缝：`tools[]` 变成模板变量交给渲染器，不存在第二份人手写的声明。AGENTS.md policy 3 说的就是这种情形。
- **判据本身先错过一次（记下来，判据只能读它声称能读的量）** — 探针 16 最初拿「system 消息增长 ≤8 chars」当重复判据，实测每条工具都 +215 chars：那 215 全数来自 `SystemPromptBuilder.toolActionDirective`（有 tools 的每轮都加、**不点名任何工具**）⇒ 判据把普通提示文本误读成重复声明，把正确的修复判成 FAIL。改成日志直写 `N ## Tool: block(s) written`，字符增长降级为 NOTE；探针 13 §11 同步改判。
- **门（回归时谁变红）** — 新 `Tests/ocoreaiTests/ToolProseLedgerTests.swift`（11 tests / 2 suites：真值表逐值断言、`nil≠false`、闭集词汇按序、reason 措辞必须分得出「测过」与「没测」、装载→隔离→遗忘、两条自带前提地板的源码扫描——一个生产者（`EnginePool.record`）与一个消费者（`MessageBuilder.mode`）各恰一处、`if proseMode.injectsProse {` 恰一处且 `Available tools:` 恰一处）；探针 16 重写为契约判据（前提轮拿不到 `tool_calls` 就整支判红；`skipped` 下块数 >0 或交付增量 <16 判红；`injectedTemplateIgnores` 下块数为 0 判红；模型已装载却在回答时仍是 `injectedUnmeasured` 记 XFAIL）；`make probes` = **16 支全绿**（探针 16 的 known-open 归零）；`make test-clt` = **2739 tests / 486 suites，3 处失败全在 `AppLifecycleLiveTests`**（报 `never became frontmost (frontmost=com.apple.loginwindow)` = 屏幕锁着/停在登录窗，本轮 diff 不含任何 AppLifecycle/Computer 文件，同 scratch 单跑 `--filter AppLifecycleLive` 同样三处红，而 07:16 那次同命令 2728/484 全绿）⇒ 会话状态的门，判据与同源条目写进 `docs/agent/build-gate-reality.md`。
- **未证 / 未做（不冒充）** — ①「模板渲不渲 tools」只在装载时测一次：它不随消息内容变，但逐轮未重测，且换 checkpoint 需重新测（账本按 modelId 存、unload 清空）；②本轮没有把 `toolProse` 发到 `/v1/models` 或 `/v1/capabilities`——那是要新增对外断言，另轮按 `CapabilityMeasurementHonestyTests` 的规矩做；③我们仍为「有 tools 的每一轮」投 ~215 chars 的 action directive（不点名工具）：它不是重复声明，是否该随 surface 收窄未测；④GUI 端到端仍零活验（§Open 原样未动）。
- **顺带记一笔 harness 现象（原因未证）** — `bash scripts/probes/run.sh 11 13 16` 一次跑三支时，11 与 13 出现整片失败；同一批逐支单独跑全绿（11=20/0、13=37/0），`make probes` 全 16 支单轮顺序跑亦全绿 ⇒ 疑为连续装载同一模型时的内存/驱逐压力，未取到直接证据（`MemoryTracker`/`OOMGuard` 侧日志未与失败轮逐条对上），留作 harness 侧待查而非代码缺陷。

**10-20(续6) 同一个工具被投喂两次：一条声明，两套方言**(P0 上游偏离 + P2 重复抽象 + P3 可观测性) — 本轮只交付仪表与判据，不改行为：按 AGENTS.md policy 4，答案的第三问（哪道门变红）有确定答案之前，它记作未决项 + 一台能定案的仪器；仪器已上线并当场把数字钉住（XFAIL 持证据）。

- **一手证据（本机 `mlx-community/gemma-4-e2b-it-4bit`，temp 0，新探针 `scripts/probes/16-tool-declaration-duplication.sh`）** — 同一条 `get_weather` 声明：交付 `usage.prompt_tokens` 707 → 823（**+116**），而本服务披露行用同一把 tokenizer 算这段 prose 只到 702 → 767（**+65**，`systemChars` +302）⇒ 剩下 **+51** 是 checkpoint 自己把同一个工具又渲了一遍；再加第二条工具：交付 +185、ours +82、residue **+103**（比单工具再 +52）⇒ 逐条成立，不是一次性的模板开销。前提节 §1 先证明这台机器上这条声明真的能出 `tool_calls`（finish_reason=tool_calls、`choices[0].message.tool_calls` 计数 1），否则 §2 就是在量一个模型根本看不到的面，探针判红而非静默通过。
- **机制（两条缝同时投喂）** — ①本服务：`Handlers/MessageBuilder.swift` Phase 5 把 `Available tools:\n## Tool: <name>\nDescription: <desc>` 追加进 system 消息；②上游：`chatSession.tools`（`EngineInference.swift:3156`）经 mlx-swift-lm `Gemma4.swift:2192` `tools: input.tools` 进 `tokenizer.applyChatTemplate`，而该 checkpoint 的 `chat_template.jinja` 在 system turn 内逐条渲 `<|tool>format_function_declaration(tool)<tool|>`（本仓可读文件实测：`~/.ocoreai/models/mlx-community/gemma-4-e2b-it-4bit/chat_template.jinja` 第 196-203 行）。**模型因此拿到同一工具的两套方言**：训练时见过的原生声明 + 我们自造的一段散文。
- **上游对照** — vllm / sglang 只有一条：`tools[]` 解析成模板变量交给渲染器（vllm `entrypoints/openai/chat_utils.py`、sglang `srt/entrypoints/openai/protocol.py`），不存在第二份人写的声明。AGENTS.md policy 3 写的正是这种情形：上游已有答案，就不该本地再造一份。
- **为什么不顺手删（留人拍板，不臆改）** — 「谁的声明该消失」是 **per-checkpoint** 事实：模板渲 `tools` 的 checkpoint 上删 prose 纯属省 token；模板忽略 `tools` 的 checkpoint 上删了就等于什么都没声明（与视频那条同一家族：不许按架构推断，只按实测）。且删之后工具调用是否仍落地需要活体证明（探针 11/13/14 全部断言投递）。可能的落点已想清楚但本轮不动刀：模型装载时用 `applyChatTemplate` 渲两次（带/不带一条探针工具）量出 `templateRendersTools`，进 ledger、由 Phase 5 消费，未知即保持现状并如实标注。
- **门（回归时谁变红）** — 探针 16：§1 前提缺失即整支判红；§2 判据是 `|Δdelivered − Δours| ≤ 16` 才算「一次声明」，超出记 **XFAIL open**（退出码仍 0，数字留在日志），**一旦 prose 收窄、residue 塌到阈值内，harness 记 XPASS 并计一次失败**——过期的例外必须吵，不许悄悄停摆（沿用 10-20(续4) 的 `probe_xfail` 机制）；§3 额外断言 residue 随 surface 增长，否则「逐条投喂」这条归因本身站不住就判红。`scripts/probes/README.md` 补 16 行。
- **诚实边界** — residue 是把「交付增量」减去「自家估算增量」归因给模板的**推断**，虽与 checkpoint 模板文件里读到的 `<|tool>` 循环互证，但没有逐 token 反查渲染后的序列（本机无「渲染后提示词」端点）；另外 +51/条只在 `gemma-4-e2b-it-4bit` 上量过，换 checkpoint 的斜率未测。AGENTS.md § Open 的 `tools[]` 条已把这份数字与探针号写进去（root 50681/50681，为挤进 shrink-only 上限，把刚落地那条指令通道的具体数字收回 `docs/agent/instruction-channel.md`、并压掉若干 CHANGELOG 已有家的日期复述与一条无决策价值的 Coverage 占位）。

**10-20(续5) 客户端的 `system` 文本被计数却从未送达：一条指令通道，一个身份门**(P0 行为不一致 + P1 状态管理 + P2 重复抽象收口 + P3 可观测性) — 第一性问：客户端写下的指令，到底有没有进到模型？OpenAI 线上用得最多的那个字段，本机收了、算了、然后丢了。

- **一手证据（本机 `mlx-community/gemma-4-e2b-it-4bit`，temp 0，探针 15 活体；修复前 → 修复后）** — ①`messages[0]` = 996 字符 `system`：送达 `usage.prompt_tokens` **705 → 886（+181）**，修复前与「不带 system」的同款请求**逐字节相同（差值 0）**；②`role:"developer"` 同样 **+181**（此前它穿过引擎的 role switch 落到 `default: .user`，被当成用户说的话）；③两面同内容同数：OpenAI 886 / Anthropic 886、无指令 705 / 705（修复前 Anthropic +182、OpenAI +0 ⇒ 同一个服务两副面孔）；④组装披露 `systemChars=` 2758 → 3756（+998，客户端文本 996 字符），披露角色序列从 `[system,system,user]` 变回 `[system,user]`；⑤指令身份真的决定复用：同指令重放 `cached_tokens=728`，改写 system 文本后 `cached_tokens=0`，并且日志里恰好只在被拒那一轮出现一行 `Session pool entry … not reusable: instructions changed`（同指令会话 0 行）。
- **根因（结构性，不是解析漏网）** — 引擎只从**第一条** `system` 消息读常驻指令（`EngineInference.swift:1791` → `ChatSession(instructions:)`），随后把全部 `system` 角色从渲染喂料里过滤掉（`:1805`），过滤后的 role switch 只认 `assistant`/`tool`，其余一律 `.user`（`:1812`）——上游 `Chat.Message.Role` 本身就没有 `developer`（`Chat.swift:120-124`）。而 `MessageBuilder.buildMessages` 把本服务自己的提示插在 index 0、把客户端那条留在列表里 ⇒ 客户端文本坐在 index 1：**估算器算它，渲染器不看它**；`developer` 更是两头落空。
- **上游对照** — vllm 把两个角色都路由进 developer 通道（`entrypoints/openai/responses/harmony.py:128`、`entrypoints/openai/parser/harmony_utils.py:436`），sglang 把两者都当普通消息角色收（`srt/entrypoints/openai/protocol.py:727-729`）；两边都不把指令从渲染里剥掉，也不存在「算了但不发」这一族问题。
- **改法（一个家）** — `Handlers/MessageBuilder.swift`：`instructionMessageRoles = ["system","developer"]` + `splitInstructionMessages(_:)` 按调用方自己的顺序把指令角色摘出会话（空串丢弃而非造空轮）；Phase 3 把「顶层 `system` 字段 + 内联指令」合成 `clientInstructions`，排在 workspace/skills/memory 之前，进**唯一**那条 generation 会读的 system 消息；Phase 7 的兜底改读过滤后的会话，纯 system 请求不再被当成用户提问打分。`Engine/SessionPool.swift`：`canReusePooledSession` 加第二条前提 `instructionsMatch`——`ChatSession.instructions` 是存储属性、由 processor 在 prefill 前置，活到下一轮的会话会用它**出生时**那份指令作答；磁盘路径从一开始就按同一身份拒绝（`SnapshotRefusal.instructionsChanged`），内存路径此前绕过了它 ⇒ 一条规则两处家。现在两面同调一个判定，且拒绝**说得出原因**（并把这行日志从 debug 提到 info：命中是 info，而拒用正是这一轮为什么要付整轮 prefill——只在调高日志级别时才现身的解释等于没有解释）。
- **同一族第二处（顺手收口）** — `stop` 的 wire 形状：规范写 `string | array[string] | null`，SDK 按调用方写的原样发，本机只按 `[String]` 解 ⇒ `{"stop":"END"}` 吃 400。更难看的是同一 target 里 `prompt` 早就做了 `string | [string] | [int]` 的 union，隔壁字段没做——**一条规则两处实现必然各走各的**。抽 `decodeStopUnion(from:forKey:)`（`Models/OpenAIModels.swift`）让 chat/completions 两面同调；`absent`/`null` = 无停止串，数字/对象**照旧抛**，绝不把畸形请求变成静默 no-op（invariant 2 的红线：调用方的 bug 只许损失一次取整，不许损失这台服务器）。vllm `StopParam` = `str | list[str] | None`（`entrypoints/generate/base/protocol.py:26`）、sglang `Optional[Union[str, List[str]]]`（`srt/entrypoints/openai/protocol.py:368`、`:894`）同判据。
- **本轮必须先记一笔纪律失效** — 接手时代码、门、文档、探针都已写完，唯独 `swift build` 从未跑过，于是带着两处编译错误：`KeyedDecodingContainer.decodeNil(forKey:)` 在本工具链是 `throws`（裸调用不过），而 `#expect` 第二参数是 `Comment?`（传 `String` 变量不隐式转换，须走字符串插值）。AGENTS.md policy 2 与「Build verification is MANDATORY」写的就是这件事——**写文档不能代替跑门**，本轮最早变红的门就是 `swift build`。
- **门（回归时谁变红）** — 新 `Tests/ocoreaiTests/SystemInstructionDeliveryTests.swift`（9：切分语义——顺序/大小写/空文本/`tool`·`function` 角色原地不动/角色集本身，外加两条自带前提地板的源码扫描：`splitInstructionMessages(context.rawMessages)` 恰好一次、`var messages = context.rawMessages` 零次）；`SessionIsolationTests` +1（含只有指令前提才能拒的空 transcript 情形，以及 `KVCacheManifest.reuseDecision` 必须报 `.instructionsChanged` 而非 `.notAPrefix`）；`StopSequenceDeliveryTests` +5（chat/completions 两面五种合法拼写逐个精确断言 + 两面不得对同一 `stop` 值各说各话 + 非字符串非数组照旧抛）。全量 `make test-clt` = **2728 tests / 484 suites** 绿（上一轮 2707/481）；`make probes` = **15 支全绿**（新探针 15 = 9 passed / 0 failed / 10 measured / 0 known-open；§5 自带地板：同指令那一半若没测出复用就整节判红，防「后半截站在死前提上」）；`docs-check`/`anchor-check`/`audit`/`format-check` 全绿。
- **未证（写清楚，不冒充）** — ①**指令是否被遵循**：token 差值只证明文本进了 prefill，不代表模型照做（本机 `gemma-4-e2b-it-4bit` 在 temp 0 会忽略 persona 措辞），本仪表最远只到「送达」；②**拒绝复用的代价真实且会重复**：728 cached → 0，即整轮重 prefill（付 754 prompt token 而不是 22），拿性能换正确性，且与磁盘路径早已执行的同一条规则；③**本服务自己的指令每轮都在变**：声明一个工具就让合并后的 system 消息 +299 字符（探针 13 §11：3026 → 3325），交替声明/不声明的会话从此每轮丢缓存——收窄那份文本是 § Open 上 `tools[]` 那条未决项，不是本规则；④多条指令用 `\n\n` 并成一块，vllm 在 harmony 里每条一个通道，分开是否改变行为未测。
- **文档同轮落点** — root AGENTS.md § Endpoint Promises 加「调用方的指令只有一条送达缝，指令身份决定缓存能不能用」（root = **50677**/50681：把 ThinkingBudget 那条的四行 cite 交回 `Engine/AGENTS.md` 的 anchor 门、并压掉 SessionPool 里已在 CHANGELOG 有家的日期复述，腾出字节）；`Engine/AGENTS.md` 补两行 `components:` anchor；长文 = `docs/agent/instruction-channel.md`（缺陷表、结构性根因、上游、改法、证到哪一步）；`scripts/probes/README.md` 补探针 15 一行（表落后目录 = 又一处「两处维护必然漂移」）。

**10-20(续4) 上一轮把预算留给了下一轮：knob 住在被复用的对象上，不在调用里**(P0 行为不一致 + P1 状态管理 + P3 可观测性) — 接上一轮留下的那条 §Open。第一性问：`max_tokens` 从 wire 到生成到底经过谁，每一跳能不能自己报数。上一轮把探针钉成 XFAIL 时还不知道原因，只知道 wire 说 8、引擎说 8、正文却付了 64。本轮把三跳各自装上仪表，一次跑完就把漏点夹住了。

- **一手证据（同一 harness，本机 `mlx-community/gemma-4-e2b-it-4bit`，temp 0，每模式独立 session；修复前 → 修复后）** — ①`response_format:json_object`@64 → 19/stop，紧接同会话纯文本@8：**64/length → 8/length**；②`tools[]`@64 → 28/tool_calls，紧接同会话纯文本@8：**64/length → 8/length**；③对照（首轮就是纯文本）@60 → 60/length、@8 → 8/length（修复前后都守约，这正是它躲过所有静态审计的原因）；④同会话连续变预算 @220 → 220、@20 → 20、@150 → 150（缩小与放大都守约）。修复后日志里那一行恰好只出现在曾漏的两轮上：`Session pool HIT …:sessF — this turn overrides the knobs it was created with: maxTokens`（sessH 同理），I/J 组没有这行 ⇒ 机制与症状一一对上，不是巧合。
- **根因（为什么只有 guided/tool 会话漏）** — 上游把采样参数**存在会话对象上**：mlx-swift-lm `ChatSession.swift:370` 是 `public var generateParameters`，`streamMap` 在起流时把它放进 Task 的捕获列表（`:981-987`，`generateParameters` 在 `:985`），而 `streamDetails(to:)` 根本不接参数 ⇒ **谁复用会话，谁就得负责把这一轮的 knob 换上去**。`MLXSessionPool.acquire` 命中时只换了 `additionalContext`/`tools`/`toolDispatch`（EngineInference 那三行），从没换过 `generateParameters` ⇒ 复用即沿用第一轮的预算。纯文本轮替它打了掩护：`release` 带 `assistantMessage` ⇒ 池里留下 transcript，下一轮的前缀共同点比缓存短，`canReusePooledSession` 拒复用、拿到干净会话；而 guided/MTP 的提前释放送 `assistantMessage: nil` ⇒ `messageHistory=[]` ⇒ `canReuse(cached 0, common 0)` 恒真，于是下一轮捡到一个装着别人预算的会话。这也解释了为什么 wire 与引擎两行日志都说 8：丢失发生在 `makeGenerateParameters` **之后**。
- **上游对照** — vllm / sglang 没有「按会话复用的生成对象」，per-request 参数直接进采样器，不存在这一族问题；mlx-swift-lm 自己把这个字段声明成 `var`（而非 `let`），并在 `ChatSession.swift:1052` 起做「cache 相关参数变了就从保留的 transcript 重建缓存」——**「调用方可能换参数」本就是上游的设计**，我们只是从未换过。
- **改法（一个家 `Sources/ocoreai/Engine/SessionPool.swift`）** — `acquire` 命中路径在交还会话前 `pooled.session.generateParameters = genParams`，并把被覆盖的 knob 名字写进 HIT 日志；判定本身装进纯函数 `MLXSessionPool.staleSamplingFields(before:after:)`，覆盖 15 个逐轮 knob（`maxTokens`/`temperature`/`topP`/`topK`/`minP`/`seed`/`logProbabilities`/三个 penalty + 三个 contextSize/`prefill.stepSize`/`toolCallPolicy`）。**cache 相关字段（`maxKVSize`/`kvBits`/`kvGroupSize`/`quantizedKVStart`/`kvScheme`/`kvCache`）故意不进这个名单**：上游自己按 plan 变化重建缓存，把它们报成漂移等于宣称一个上游已处理的缺陷。范围诚实标注：这行代码同时修好 `temperature`/`seed`/penalty 的同类残留，但**只有 `max_tokens` 是活体实测过的**，其余是同一家族的推断，未逐条测。
- **可观测性（P3，本轮新增且留下）** — 三跳各报一次数：handler `Assembled prompt … wireMaxTokens=`（客户端要多少）、引擎 `Generation budget: maxTokens= optionsMaxTokens= guided=`（生成拿到多少）、池 `Session pool HIT … overrides the knobs it was created with: …`（复用的会话原来带着多少）。上一轮查不动就是因为每行只说一段且互不矛盾；本轮一次跑完就定位，靠的是第三行。
- **门（回归时谁变红）** — 新 `Tests/ocoreaiTests/PooledParameterDriftTests.swift`（6 tests：全 knob 集按名按序 + 地板 15、同参不改、实测的 64→8 只许报 `maxTokens`、`temperature` 单动也须报、cache 字段不得报成漂移、以及自带前提地板的源码扫描——刷新必须在 `acquire` 体内、赋值与判定各恰好一处，模式一旦不再匹配先红在地板上）。探针 14 §7 从 `probe_xfail open` 改成硬断言（超预算即 FAIL，grammar-first 与 tools-first 各一次），同一次提交删掉 AGENTS.md §Open 那条 ⇒ 例外不能比缺陷活得久。`_lib.sh` 的 `probe_xfail`（XPASS 记失败）留在原地给下一条已知缺陷用。全量 `make test-clt` = **2713 tests / 482 suites** 绿（+6 tests / +1 suite）；探针 14 = **21 passed / 0 failed / 25 measured / 0 known-open**（修复前 19 passed / 2 known-open）；`make docs-check` ✅（root 50675/50681、claims 12/12、suites 28→29）、`make anchor-check` ✅ 19/19、`make format-check` ✅、`make audit` ✅。
- **文档行号随仪表顶格（anchor 门抓的）** — 新增的三行日志把 `EngineInference.swift` 顶高 13 行，`make anchor-check` 当场报 6 条漂移（steer 排空 `:3000`/`:3620`、thinking budget `:4225`/`:3721`、视频记账 `:3219`、`caughtError` `:4726`），已逐条重钉为 `:3013`/`:3633`/`:4238`/`:3734`/`:3232`/`:4739`，并连带校正 root AGENTS.md 与 Package.swift 注释里的同族裸行号；重跑 ✅ checked=19 drift=0。
- **对照仓库名单补齐（把「两处维护必然漂移」掐在源头）** — owner 10-20 扩大参考集，AGENTS.md item 6 现点名 vllm / sglang（OpenAI+Anthropic 兼容基准）+ vllm-metal / omlx / mlx-serve / MTPLX / ollama / TensorFold / Strata / hermes-agent / deepseek-harness；逐仓库「各自所长」的长话装进新 `docs/agent/comparator-repos.md`，每条都是从本机 clone 实测（ollama 同时钉 llama.cpp `b11669` 与 MLX C `a341b492…`，是 MLX+CoreAI 双路最接近的公开对照；TensorFold 带 `NOTICE`+`THIRD_PARTY_NOTICES/`+`RUNBOOK.md`+`SECURITY.md`，正是我们第三方面子与发布件纪律的邻居；Strata 有写死的 `docs/BENCHMARK_PROTOCOL.md`——引用数字之前先写怎么产出它，这条我们没有；deepseek-harness `dsh` 的 everything-is-a-plugin 是 skill/插件面的另一条轴）。审计状态用可重跑的 `grep -c -- <name> CHANGELOG.md` 记录（vllm 15、sglang 12、omlx 11、hermes-agent 5、ollama 4、mlx-serve 2、vllm-metal 1，MTPLX/TensorFold/Strata/deepseek-harness 均 0 ⇒ 挂名未用，要么用要么从 root 摘掉）。**`harness2` 已指定但本机 `~/references/` 没有**（14 个目录，无此名）⇒ 不可引用、不可判，clone 之后先上图。root 挤到 50681/50681：下一轮往 root 加话，必须先减话。
- **边界 / 未决** — ①同族未穷尽：`ChatSession.components`（thinking budget / reasoning 组件）与 `speculativeDecoding` 同样只在创建时给一次，若将来同一会话要逐轮改推理，同一漏法会在那儿复现；本轮只接 `generateParameters`，因为那是唯一实测到会漏的一组。②GUI 面（不经 HTTP）仍零活体验证，本门的活体一半只覆盖 `/v1/chat/completions`。③漏的是 knob，不是 KV：修复后同会话仍复用缓存（`prompt_tokens` 不变），代价没有变贵。

**10-19(续3) 工具轮对自己说的三句话，两句是编的：并行、终词，外加把预算漏给下一轮**(P0 行为不一致 + P0 上游偏离 + P1 执行链) — 第一性问：一个工具轮在响应里对自己做了哪些断言，客户端据此决定「还能不能继续读」「这份调用列表要不要执行」「这次是答完了还是被切了」。实测三条里有两条在无门状态下说谎，而 2688 个测试没有一个变红。

- **一手证据（修复前，本机 `gemma-4-e2b-it-4bit`，temp 0）** — ①`parallel_tool_calls:false` ⇒ 仍交回 2 个 `tool_calls`（Paris + London），Anthropic 面 `tool_choice.disable_parallel_tool_use:true` ⇒ 仍交回 2 个 `tool_use` 块：两副面孔都把标志解了码，然后一起没读。②`max_tokens:25`（该题两调用答案自然 28 token）⇒ `completion_tokens:28` + `finish_reason:"tool_calls"`：被预算拦腰砍断的一轮自称「调用列表完整」，客户端会照单执行一份它无法知道被切的列表。③SSE：`tool_calls` 那个 delta 自己带着 `finish_reason:"tool_calls"`，终块又说 `stop`——流式面否认 JSON 面承认的调用，而按「读到第一个非空 `finish_reason` 就停」写的 SDK 永远看不见调用之后的正文。④`tool_choice` 的 OpenAI 规范形状 `{"type":"function","function":{"name":X}}` ⇒ `400 {"message":"Coding key `name` not found."}`（把内部键名吐给客户端），而我们自造的扁平别名反倒能用；`"banana"`、数组、有 `tool_choice` 却没 `tools[]` 一律 200 答完。
- **上游怎么做** — vllm 把三个决定装进一个模块：`maybe_filter_parallel_tool_calls`（`entrypoints/serve/utils/tool_calls_utils.py:24-43`，`parallel_tool_calls:false` ⇒ 只留第一个调用）、`resolve_finish_reason`（`:47-65`，只在这一轮真的产生了调用时把 `stop` 升成 `tool_calls`）、Anthropic 的 `disable_parallel_tool_use` → `parallel_tool_calls`（`entrypoints/anthropic/serving.py:698-700`）；具名工具的 `{"type":"function","function":{…}}` 与其字符串别名见 sglang `srt/entrypoints/openai/protocol.py:829-833`、`:901`、`:1020-1027`，而升级终词的条件写得很清楚：「有调用 **且自然停下**」（`srt/entrypoints/openai/serving_chat.py:2149-2152`）。
- **改法（三个决定一个家 `Sources/ocoreai/Models/ToolCallWire.swift`，~195 行）** — `resolveFinishReason(engineReason:toolCallsMade:)`（只有「做了调用且引擎自己停下」才给 `tool_calls`，被切就是 `length`）、`terminalFinishReason(…terminal:)`（非终块一律 nil）、`limitsToSingleCall(parallelToolCalls:)`/`limitedToolCalls(_:parallelToolCalls:)`（三态：nil=随模型、true=全给、false=只留第一个，且留的是模型自己的第一个而非排序第一个）、`normalizedNamedToolChoice(type:flatName:nestedName:)`（规范嵌套形状 + 旧扁平别名都认）、`toolChoiceWithoutToolsError(toolChoice:toolCount:echo:)`（一切拒绝都走 `AppError.invalidParameter(param:"tool_choice", …)`，回显送值，不再有 `Coding key` 泄漏）。两面对齐同一函数：OpenAI 面在 `numericDomainError()` 之后加「有 `tool_choice` 无 `tools[]` ⇒ 400」，非流式 `emittedToolCalls` 过 `limitedToolCalls`，流式两处发射点送 `finishReason: nil`、FINAL 块才定终词；Anthropic 面解出 `disable_parallel_tool_use` → `parallelToolCalls`（此前 `toChatCompletionRequest` 硬写 `true`），`stop_reason` 走 `openAIToAnthropicStopReason(resolveFinishReason(…))`，`tool_choice`-无-tools 同判据。
- **明确不采纳上游一条**（记 §Open，不臆采）：vllm 在 `tool_calls_utils.py:53-57` 把「强制具名工具」的轮保持 `stop`——那条规则的前提是服务端自己执行工具后再循环一轮，本机这台的强制力受 checkpoint 限制、不可观测 ⇒ 不抄、不猜。Anthropic 未知 `tool_choice.type` 目前仍被宽容，同样留 §Open。
- **门** — 新 `Tests/ocoreaiTests/ToolCallWireContractTests.swift`（5 suites / 19 tests / 36 断言：终词真值表、非终块必须 nil、三态并行、保留的是模型第一个调用、`tool_choice` 解码矩阵与四类拒绝、回显值、Anthropic 标志映射、自带地板的源码扫描、两条 HTTP 面的具名 400）。全量 `make test-clt` = **2707 tests / 481 suites** 绿；新探针 `scripts/probes/14-parallel-and-terminal-word.sh` = **19 passed / 0 failed / 25 measured / 2 known-open**，全部 14 支探针 ✅ 绿。
- **修探针时扒出自己的 harness 缺陷（它一直在掩盖真缺陷）** — `fresh_session()` 把 `SESSION_SEQ=$(( SESSION_SEQ + 1 ))` 写在函数体内，而调用点是 `s="$(fresh_session)"`：自增发生在命令替换的子 shell，父壳永远看不见 ⇒ 整支探针 12 个「各自独立会话」的对照其实共用同一个会话，§1 的对照组与 §3 的截断轮互相污染。计数器改住进文件（`mktemp` + `probe_atexit` 清理），并且 §3 不再记某个 checkpoint 的 token 数，改按实测关系判：`completion > max` ⇒ 预算没到引擎（红）、`==` ⇒ 必须是 `length`、`<` ⇒ 不许是 `length`，外加一条地板「整节没有任何一轮落在预算上就报 §3 什么都没判」。同一序列改口后：`max=25`→25/`length`/1 调用、`max=20`（无工具）→20/`length`、`max=220`→14/`tool_calls`。顺带修 harness：`probe_exe_of`/`probe_exe_is_ours`（相对路径起的服务器从前门逃过 reaper，把 240 s 就绪超时误诊成「Metal 不可用」）。
- **新抓到的 P0（未决，探针以 XFAIL 持证据）** — **一个语法/工具约束轮会把它的 `max_tokens` 漏给同一会话的下一轮**：`json_object`@64 → 19/`stop`，紧随其后的明文轮 @8 → **64**/`length`；`tools[]`@64（自然 28/`tool_calls`）之后明文轮 @8 同样 → **64**；对照（同会话但前面没有约束轮）@8→8、@60→60。客户端要 8 个 token、付了 64 个，同一份响应体里 `usage.completion_tokens=64` 与 `max_tokens=8` 自相矛盾（invariant 2 的红线）。线侧不是丢的地方（`Handlers/ChatHandler.swift:582-583` 每请求解析、`Engine/MLXBridge.swift:954` 写进 `GenerateParameters`），`Engine/GuidedGeneration/` 里也没有任何跨轮共享状态 ⇒ 遗留点在「guided/tool 轮归还/新建 pooled 会话」那一步，根因未定。为此给 harness 加了 `probe_xfail VERDICT MESSAGE`：仍复现记 XFAIL（退出 0，数字留在日志里），**不再复现记 XPASS 并计一次失败**——过期的例外等于悄悄停止检查的探针。`probe_summary` 行加 `known-open` 字段（`run.sh` 按退出码判定，不受影响）。
- **文档同轮改口** — AGENTS.md §Endpoint Promises 加「一个工具轮三句自我断言，只许一个家」；§Open 加「A guided turn leaves its budget to the next turn」（含复现数字与 XPASS 收口机制）。root = **50667**/50681（上限未动，棘轮继续）：付账的是把 CoreAI 掩码常数的逐条分析、本地门禁的 host forensics 移进 `docs/agent/build-gate-reality.md`，并压掉若干已在 CHANGELOG 有家的复述（claims 12/12、suites 28、anchors 19/19 无漂移）。`scripts/probes/README.md` 补上探针 14 一行（表落后目录一行 = 又一处「两处维护必然漂移」）。

**10-19(续2) 同一个引擎的两副面孔：`/v1/messages` 少喂 750 token、少一条 steer 缝、少一条 reasoning 通道**(P0 行为不一致 + P0 上游偏离 + P1 执行链) — 第一性问：同一个模型、同一个请求，两条线各自把什么喂给了模型、各自又报出什么数？上一轮修好了这一面的工具接缝，却把「这一面根本没用共享组装」留在原地，而 2659 个测试没有一个变红——它们都说 OpenAI 那条线的话。

- **一手证据（修复前，同机 `gemma-4-e2b-it-4bit`，temp 0）** — ①**reasoning 从未到引擎**：`thinking:{type:"enabled",budget_tokens:400}` ⇒ 38 个输出 token、无 thinking 块；同题 `/v1/chat/completions` `reasoning:true` ⇒ 335。handler 组装 `InferenceOptions` 时压根没有 `enableReasoning` 一项，且 `type:"disabled"` 被映射成 `true`（要求关掉思考 = 打开思考）。②**两副组装**：同一句单轮请求 `prompt_tokens=774`（chat）vs `input_tokens=24`（messages）——这一面自己拼消息列表（client messages + `system` 字段），从未调用 `MessageBuilder`，skills 目录/工作区段/召回记忆/推理脚手架一律缺席；问「你有哪些 skills」，chat 面答 terminal/file/search/memory，这一面答「处理并理解自然语言……」。少 750 token 只是账面，答成另一个产品才是 invariant 2 的红线；`systemPromptBuilder` 在这一面是带下划线的形参 = 死注入。③**steer 被吞**：`/v1/steer` 的路由文档点名 `/v1/messages`，而这一面没有任何 `SteerQueue.drain` 调用点——实测排队后 `/v1/messages` 回 "Please provide more context"（19 input tokens），chat 面同一序列答出 ORIOLE。④**工具历史走错了信道**：`tool_result` 以 `[tool_result · call_x] 17C, light rain` 的标签文本塞回 user 轮，而非引擎工具信道（`EngineInference.swift:1811 case "tool": .tool`、`:1818 Chat.Message.assistant("", toolCalls:)`、`:1822 Chat.Message.tool(contentStr, id:)`）⇒ 按模板 tool 角色读输出的 checkpoint 什么也看不见。
- **上游怎么做** — thinking 在 Anthropic 协议里是一等内容块：vllm 生成 `thinking` 块并配 `signature=uuid4().hex`（`entrypoints/anthropic/serving.py:855-862`）、流式发 `thinking_delta`（`:1061-1083`）、在 `content_block_stop` 之前发 `signature_delta`（`:945-961`）、`_handle_thinking` 统一分发（`:629-649`）；delta 联合的四成员见 sglang `srt/entrypoints/anthropic/protocol.py:402-426`，块开/关与索引见 `serving.py:880-935`、`:1194-1220`。
- **改法（收成一处真值）** — ①`AnthropicMessage.toInternalMessage()` → `toInternalMessages()`：一次 Anthropic 轮次可展开成多条引擎轮次——`assistant` 的 `tool_use` → `Message(toolCalls:)`，每个 `tool_result` 自占一条 `role:"tool"`+`toolCallID` 且排在本轮散文之前（`[tool…, user]`，反过来会渲染出悬空 tool 轮），只有缺关联 id 才回落成文本，`is_error` 以文本随车（引擎 tool 轮没有错误位）。②handler 形参 `systemPromptBuilder _: SystemPromptBuilder` → `messageBuilder: MessageBuilder`，Phase 2 = `anthropicConversationMessages()` + `messageBuilder.buildMessages(…)`，并在同一处排空 steer、`mergingSteeredTurn` 于头部（异常路径回灌，steer 不因此丢失）。③Phase 3b `InferenceOptions.enableReasoning = chatRequest.reasoning`；`reasoningEnabled` 三态（enabled/disabled/缺省 = nil，缺省交给模板）；`budget_tokens` 不再参与 `max_tokens` 封顶，改用 Anthropic 自己的配对规则：`enabled` 且 `budget ≥ max_tokens` ⇒ 400 点名 `thinking.budget_tokens`。④非流式 `content` = `thinking` 块（若本轮想了）→ `text` 块 → `tool_use` 块，reasoning 与答案分开累加、各自过输出护栏（只拦答案会放走违规的思路）；流式 `AnthropicStreamEmitter` 加 `feedReasoning`，thinking 块先 `signature_delta` 再 `content_block_stop`。⑤`signature` 解码并回写，但按它真实身份标注：**本地生成的不透明 id**（与 vllm 同法），我们不签名也不验签，注释写明客户端不得据此读出完整性。⑥`usage.input_tokens` 改取引擎 `.done` 报的实测 prefill（`observedPromptTokens ?? inputTokenCount`），与 chat 面 `prompt_tokens` 同源。⑦`count_tokens` 路由改数同一份组装列表，并在路由文档写清它是**下界**——消息 tokenizer 数不出模板每轮 framing（实测 769 计数 vs 774 实收，差 5）。
- **新仪器：每请求一行组装披露** — `Handlers/MessageBuilder.swift` 新增 `logAssembledPrompt(…)`，两面各在 token 计数之后吐一行 `Assembled prompt [chat|messages]: N message(s) [roles] systemChars=… promptTokens=… enableReasoning=on|off|default declaredTools=…`。活体（同请求、同 session）：两行 `systemChars=3026 promptTokens=769` 完全相同、`usage` 同为 774；此前 774 vs 24 那种差异，如今是一次 grep 就能定位的事，而不是几天的推理。
- **本轮被自己的门抓回来的两条假断言** — ①探针 02 把两个端点钉成「同一句话必须同一个数」：`/v1/count-tokens` 是 tokenizer 服务（数你发的字节：17），`/v1/messages/count_tokens` 是 `/v1/messages` 的预检（数这条线要喂给模型的东西：700，随后实收 774）。这一面变诚实后反而变红 ⇒ 相等只在端点内成立，端点间改成 `raw < pre-flight` 的下界；`system` 块计入的断言同样拆成两端点各自成立（原先 `min(+system) > max(bare)` 是巧合通过：512 > 17，而预检的 700 被放进了 bare 组）。②探针 13 §8 原以「答案里有没有数字 9」判「旋钮不伤答案」，读的又是 240 字符预览：同一 prompt/temp 在不同次启动里 209 token `end_turn`、335、499、512 token `max_tokens` 都出现过，结论位置随 checkpoint 漂移 ⇒ 断言改为 temp 0 下 A/B **全文逐字节相等 + `output_tokens` 相等**（本轮实测 499=499、1571 字符一致），结论位置只记录不宣称；`text_block_text` 加可选 limit 参数，默认预览 240 不变。
- **门（回归时谁变红）** — 新 `Tests/ocoreaiTests/AnthropicThinkingAndToolChannelTests.swift` = 4 suites / 24 tests：`thinking.type` 三态判别表、`budget ≥ max_tokens` 必 400、budget 不再封顶输出、`thinking`/`signature_delta` 线形（各自只带自己那一份 payload）、发射器序列精确比对（thinking 先于答案、签名先于块关、块编号 0/1、reasoning 与答案永不同块、thinking-only 不补空块、迟到的 reasoning 自开一块）+ 自带地板的源码扫描（两面各须出现 `enableReasoning:`、`case .reasoning(let`、`observedPromptTokens ?? inputTokenCount`；steer 排空与 `mergingSteeredTurn` 须在；`systemPromptBuilder _:` 这类死注入不得复现；两面必须各调 `logAssembledPrompt`）。聚焦（`Anthropic|ToolCallDelivery|ToolDeclarationSurface|ToolsWireDecode|GrammarSchema|InferenceOptionsToolRouting`）= 126 → **155 tests / 16 → 20 suites** 绿；全量 `make test-clt` = **2688 tests / 476 suites** 绿。探针 13 由 §1–§6 扩到 §1–§11 = **36 passed / 0 failed / 13 measured**（§7 `tool_result` 续轮：答 "The weather in Paris is 17C with light rain."、`stop=end_turn`、882 vs 772 token——历史进了 prompt 且未重发调用；§8 三态 + 400；§9 两线同组装同报数 + `count_tokens` 下界；§10 steer→ORIOLE；§11 声明一个工具 ⇒ system 3026→3325）；探针 02 修正后 **16 passed / 0 failed**（原 14/1）；全套 13 条探针全绿。
- **AGENTS.md 记账** — 根文件 50674 → **50664**（cap 50681，ratchet 只减）。加：兼容面规则（同一次组装 + 同一个 steer 缝 + 披露行 + 新门名）、§Open 的 Phase 5 重复项；付：在 CHANGELOG 另有完整落点的旧日记（10-18 旋钮轮的过程句两处、HIG 的字节数日记、mirror caveat 的过程句、`Package.swift 只留 pin + 指针` 的同句重复、`§ Wiki` 并入 `Host-local ≠ project truth`、`Who works here` 的结语），并把因本轮改动漂移的 `AnthropicModels.swift:850` 重钉至 `:1059`。`make docs-check` = root 50664/50681、claims 12/12、gateable-refs 67、suites 26（新门名可解析）；`make anchor-check` = 19/19。
- **顺手记下、未修（只记不宣称）** — ①共享组装 Phase 5 在两面都把声明工具写成无参数 schema 的 `## Tool:` 文本（实测 +299 字符/工具），同一份 spec 却又结构化交进 `chatSession.tools`（`EngineInference.swift:3143`）⇒ 模型看见两份、其一无参，而 vllm/sglang 只交结构化那一份；删除需 A/B（仪表=探针 13 §11）。②调用轮上的 assistant 散文会被 `Chat.Message.assistant("", toolCalls:)` 丢弃（两面同此）——保留与否待上游缝或产品定。③本 checkpoint 模板无 reasoning 通道：`thinking` 三态在两条线上都不改输出，delivery 证据是组装行而非 token 差；换带 thinking 的 checkpoint 才测得出行为差。④同一 prompt/temp 的输出长度随启动漂移（209/335/499/512 皆出现过）⇒「跑一次定结论」的断言一律不写进探针。
**10-19(续) `/v1/messages` 两条路都交不出工具调用——Anthropic 面的六道伤在同一条接缝**(P0 上游偏离 + P0 行为不一致 + P2 重复声明) — 第一性问：客户端按 Anthropic 协议声明了 `tools[]` 并明确要求调用，那么「把声明送给模型」和「把模型的调用送给客户端」这两步，各是哪一行代码在做？两条线在本机都是断的，而当时 2633 个测试没有一个变红——因为仓库里所有 tools 测试都说 OpenAI 那条线的话。

- **一手证据（修复前，同机 `gemma-4-e2b-it-4bit`，temp 0）** — 非流式 `POST /v1/messages` 带 `tools:[get_weather]` + “Use the get_weather tool to check the weather in Paris.” 回 `stop_reason:"end_turn"`、`content:[{"type":"text","text":"Which city are you interested in? Please specify the city name."}]`（既没调用，也没回答被问的问题）。流式同一题：`message_start → content_block_start → content_block_delta×11 → content_block_stop → message_delta(end_turn) → message_stop`，原始事件里 `content_block_start` 只有 `{"type":"content_block_start","index":0}`——没有 SDK 用来开块的 `content_block`，全程没有 `tool_use`、没有 `input_json_delta`。
- **四条根因** — ①**声明没到引擎**：handler 的 `inferenceOpts` 只填 `maxTokens/includeLogits/headless`，`tools[]` 被渲染成 system 文本（`## Tool: name\nDescription: …`，连参数 schema 都不带），`declaredToolNames`/`declaredToolSpecsJSON`/`hasNativeTools`/`grammarSchema` 全空 ⇒ 引擎的工具面 `resolveToolSurface` 根本没跑，模型看见的是「名字的无参副本 ×2，真 schema 0 份」。②`.toolCall` 在非流式与流式两处 `break` 丢弃。③响应没有 `tool_use` 形状，`content_block_start` 不带 `content_block`。④`AnthropicToolInputSchema.toOpenAIParameters()` 只返回 `properties`，丢掉 `type` 与 `required`——而 `required` 在**更早的解码处就已丢失**：`AnyCodable` 把 `["city"]` 解成 `[AnyCodable]`，`as? [String]` 恒失败（这条是新门第一次跑就抓出来的额外伤，`required` 丢两次 ⇒ 强制调用可以任意省略必填参数）。
- **上游怎么做** — vllm `_convert_tools` 把 `input_schema` 原样放进 `function.parameters` 且 `req.tools = tools`（`entrypoints/anthropic/serving.py:762-791`），`tool_choice` 四值映射 auto/none/required/pinned（sglang `srt/entrypoints/anthropic/serving.py:685-720`）；非流式 `content` 追加 `{"type":"tool_use",id,name,input}`，空回应补一个空 text 块（vllm `serving.py:870-883`）；流式 `content_block_start(content_block=…)` + `input_json_delta(partial_json=…)`，每个调用自占一个 `content_block_index`（sglang `serving.py:880-935`、`1194-1220`）。**两边都不把工具渲染进 system 文本。**
- **改法（收成一处真值）** — handler 新增 Phase 3b：`declaredTools = chatRequest.tools`、`toolChoice = request.toolChoice?.openAIVocabulary`（`any→required`、`tool→function:<name>`、`none→[]`），强制仍走唯一的 `shouldConstrainOutput`，grammar 由声明构建，`hasNativeTools`/`declaredToolNames`/`declaredToolSpecsJSON` 与 `/v1/chat/completions` 用同一组 helper；`buildAnthropicMessageList` 里的工具文本注入整段删除。交付：非流式「结构化事件优先、`parseToolCalls` 兜底」，`content` = text 块 + `tool_use` 块（`input` 是对象不是字符串；参数不是 JSON 对象 ⇒ 丢弃该块并 `logger.warning`，绝不洗成 `{}` 让客户端执行模型没要求的参数），交付即 `stop_reason:"tool_use"`。流式新增 `AnthropicStreamEmitter`（`internal`，可单测）唯一拥有块开/关、索引与**文本暂存**。
- **第五条伤：这一面的文本通道不过 settle** — 修复后活体仍失败，抓到真因：语法强制让模型**把调用写成正文**（实测 35 个 `text_delta` 逐字拼出 `"name": "get_weather"`，随后 `end_turn`，全程没有 `.toolCall`），而 Anthropic 面对引擎文本是**来一个发一个**；对照同机同题的 `/v1/chat/completions` 流式：3 个事件、`tool_calls` 一个 delta、**正文零泄漏**（它的 content 通道按设计在 `StreamOutputFilter.finish()` 才结算）。⇒ 这是两面行为不一致的另一处，修在唯一的发射器里：首字符是 `[`/`{` 的文本判为「尚未定型」暂存，非调用形状的散文首字符即放行（不换回全量延迟），流末整段 `parseToolCalls` 定案 ⇒ 判定为调用则暂存文本**丢弃不发**，客户端只拿到结构化块。
- **门（回归时谁变红）** — `AnthropicSSEWireShapeTests.textDeltaShape` 从钉住 `content_block_delta` 改钉 `text_delta`（判别符一旦回归即红）；新 `AnthropicToolDeliveryTests`（4 suites / 26 tests：`tool_choice` 四值映射表、`required` 穿过 `AnyCodable` 装箱、无键 schema 保持开放、null schema 不伪造、`content_block_start` 带 `content_block.type`、`tool_use` 块编码、`input_json_delta/partial_json`、参数非对象 ⇒ nil、以及自带地板的源码扫描（两种模式各须有一处 `.toolCall(let tc)` 与 `recordToolCallDelivery`；必须出现 `shouldConstrainOutput(` 与 `declaredToolSpecsJSON:`；`"Available tools:"` 不得再现）+ 发射器精确序列单测（暂存/放行/块编号/暂存文本丢弃/空回应补块）。聚焦跑 Anthropic+tools 面 = 126 tests / 16 suites 绿；全量 `make test-clt` = **2659 tests / 472 suites** 绿。新探针 `scripts/probes/13-anthropic-tool-delivery.sh`（实测 **21 passed / 0 failed / 4 measured**）：§1 非流式 `tool_use`（id/name/`input` 对象）+ `stop_reason:"tool_use"`；§2 流式块形状 + **「调用方言不得作为正文泄漏」**；§3 两条控台（未声明 / `tool_choice:"none"`）；§4 声明而不强制 ⇒ 仍答 4；§5 纯文本流的 `content_block_start` 也带 `content_block` 且答案仍送达；§6 这一面交付推动共享仪表 `toolCallDelivery=parsed` 且 evidence 点名 `get_weather`。
- **第六条伤（活体探针抓的：判别符写成了事件名）** — §5 控台（纯文本、无工具）报「正文为空」，但 seq 明明有一个 text delta：`{"index":0,"delta":{"type":"content_block_delta","text":"4"}}`。Anthropic 的 content-block delta 是**按 `delta.type` 判别的联合**（`text_delta`/`input_json_delta`/`thinking_delta`/`signature_delta`，sglang `srt/entrypoints/anthropic/protocol.py:402-426`），而我们把事件名 `content_block_delta` 同时填进了判别符位 ⇒ 落在联合之外：**按 `delta.type` 分发的 SDK 读不出任何正文**。更刺目的是：既有门 `AnthropicSSEWireShapeTests.textDeltaShape` 当年把 `d["type"] == "content_block_delta"` 钉成了断言——钉住偏离的门比没有门更糟，它让错误有了「已被测试」的护身符。已改为钉 `text_delta`，并在注释里写清这条曾经错过什么。

- **文档同轮改口** — `count_tokens` 路由注释原写「system 与工具定义都按将付出的代价计入」⇒ 改为「计入 system 与会话；`tools[]` 在本服务器不是消息文本（这也是 `/v1/chat/completions` 同样不计它的原因）」；既有测试 `sharedBuilderIncludesSystemAndTools` 改写成 `sharedBuilderCountsMessagesNotToolText`（旧断言正是把第二真值钉成门的那条）。`scripts/probes/README.md` 的探针表补齐 09–13（表落后目录四行，是又一处「两处维护必然漂移」）。
- **AGENTS.md 的账（棘轮，不是口头话）** — 新规则「兼容面必须复用主面的组装，并吐出规范自己的判别符」要进 root，就得有别的东西出去：`InferenceOptions` 组装面从「两个」改成「三个」时删掉了 GUI 偏离的复述（历史归 CHANGELOG）、删掉 #700/#622 的逐条摘要（rounds 9–15 的家在 CHANGELOG）、删掉探针 11 §7 与 screenStatus 的判据细节（门自己写着）。root 50486 → **50674**（上限 50681 未动，claims 12/12、suites 24→25）。
- **边界 / 未决** — ① SSE 的 key 顺序在本服务器不固定（同一事件一次是 `{"index":0,"delta":…}`、一次是 `{"type":…,"index":0,…}`），⇒ 探针一律按 JSON 解析后再断言，不做两键 substring（探针 11 首跑读错键那次是同一族）。② `toolCallDelivery` 现在两面共同记账（同一事实的两个入口，不是两个事实）。③ **`thinking` 在本面未接到底层**：`thinking.budget_tokens` 只用来截 `max_tokens`（`toChatCompletionRequest`），`enableReasoning` 没进 `InferenceOptions` ⇒ 声明 thinking 不会真的打开推理；而且非流式把 `.reasoning` 并进 `content`、流式直接丢弃 reasoning，三面各一种说法。要对齐 Anthropic 得连 `thinking`/`signature` 块语义一起定（vllm `serving.py:855-862` 发 `thinking` 块并自造 signature——那一步是能力承诺，留人拍板），本轮只记录不动。④ `tool_choice:"any"` 在模型抗拒的题上仍可能零 token（per-checkpoint，探针 §1 用明确要求调用的题）。⑤ GUI 面零活体验证。

**10-19 `response_format: json_object` 交付的是 `{}`——四份同一兜底把键全禁了**(P0 上游偏离 + P0 行为不一致 + P2 重复抽象) — 第一性问：客户端说「给我 JSON」却没给 schema 时，是谁在决定约束是什么？答案是我们自己的兜底串，而它写的是 `{"type":"object","properties":{}}`：`properties` 点名了零个键 = 告诉语法「任何键都不合法」，于是模型唯一能吐的就是 `{}`。

- **一手证据（同机同题 temp 0，提示词点名 answer/unit 两键）** — `json_object` → `content:'{}'`、`completion_tokens=2`；`json_schema` 带 `{"type":"object"}` → `content:'{"answer": 8, "unit": "planets"}'`、`completion_tokens=20`；`json_schema` 带 `{"type":"object","properties":{}}` → 又是 `'{}'`/2。三方对照把责任钉死在 `properties:{}` 这一段：JSON 合法、信息为零、HTTP 200、`finish_reason:"stop"`，任何面上都没有声音（invariant 2 的反面教材）。
- **上游怎么做** — vllm 把 `json_object` 映射成 `JSONSchemaFormat(json_schema={"type": "object"})`（`vllm/parser/abstract_parser.py:277`），sglang 直接 `sampling_params["json_schema"] = '{"type": "object"}'`（`python/sglang/srt/entrypoints/openai/protocol.py:1191`）。两边都**不带** `properties` 键。
- **根因是重复抽象（P2）** — 同一个兜底串在仓库里有四份：`Models/OpenAIModels.swift`（wire 兜底）+ `Engine/EngineInference.swift` 的三条约束解码路（`_runPipelinedConstrainedDecoding`／`_runLegacyConstrainedDecoding`／`_runConstrainedDecoding`）。四份 = 四次「静默返回 `{}`」的机会，而且没有一份写着它为什么长这样。
- **改法：一个家 + 与上游同一形状** — 新增 `jsonObjectSchema = #"{"type":"object"}"#`（`Models/OpenAIModels.swift`，doc 注释带着上面那组实测与两条上游行号），wire 兜底与三条引擎路全部改指它。客户端自己声明的零键 schema 照旧 obey——那是调用方的意思，不是我们的兜底；这条区别被写成探针 §4 的控台，用来证明修复不是「把语法整体放松」。
- **门（回归时谁变红）** — `GrammarSchemaRegressionTests`：`json_object` 必须是开放对象 `{"type":"object"}` 且不得含 `properties`；无 schema 的 `json_schema` 走同一兜底；再加一条自带地板的源码扫描（扫过 ≥200 个 Swift 文件、注释先剔除，`{"type":"object","properties":{}}` 出现在任何代码里即红 ⇒ 第二份长不出来）。新探针 `scripts/probes/12-json-mode-delivery.sh`（实测 6 passed / 0 failed / 4 measured）：§1 `json_object` 必须解析为 JSON 对象；§2 必须与 `{"type":"object"}` **行为一致**——我们拥有的是这条等价式（它就是上游的映射），不是「键数 > 0」：开放文法的最小合法解本来就是 `{}`，把「模型肯不肯填键」写成断言就是替别人的事实定红；§3 声明了 required 键的 schema 必须真带回那两个键；§4 调用方钉零键 ⇒ 仍得 `{}`。
- **顺带修掉两条早就错位的引用（暴露出一个覆盖缺口）** — `SessionPool.swift:1086` 的注释指向 `EngineInference.swift:2982`、`ThinkTagParser.swift:78` 指向 `:299/797`：**这两条在本轮动手之前就已错位**（对着 HEAD 看是无关行），因为 `make anchor-check` 只认带 `<!-- anchor: -->` 标记的引用。已改钉真实位置：`:3135` = `newMessages = Array(mlxMessages[divergenceIndex...])`；`:356`/`:809` = 两条 `primedInside` 检测路。同一天 `ARCHITECTURE.md` 的风险表也照了镜子：本轮把自己的 −11 位移补正（1118、1171-1195），`caughtError` 改钉到真实点 4726，另外两行（`stopReason` 874-878 与 `deltaOffset`——后者在文件里已经不存在）**拒绝继续供给假精度**，改为 `stale cite — re-audit`。**同一轮把口子堵上了**：`scripts/anchor-check.sh` 的扫描域原本只有 `AGENTS.md` + `docs/agent/*.md` + `Sources/**/AGENTS.md` + `Sources/**/*.swift`——`ARCHITECTURE.md` 与两份 README 整体在门之外；现已纳入扫描域，并把表里三条尚可核对的引用钉成锚点（`checked` 16→19，drift 0）。剩下两行仍写 `stale cite — re-audit`：机器只能钉住还存在的机制，「那条风险还在不在」要人重审（invariant 1 的又一例：没有门的数字必然漂移）。
- **边界** — 三条引擎约束解码路都在 `@available(macOS 27.0, iOS 27.0, *)` 内，本机只编译验证；`{"type":"object"}` 与 `properties:{}` 的行为差异在可跑的 std guided 路上实测（同一 XGrammar 语义）。

**10-18(续4) GUI 给每条白话都上了 calls-only grammar——强制规则收进唯一的家**(P0 行为不一致 + P2 重复抽象) — 第一性问：用户在 GUI 里敲一句话，走的是哪条路？不是 `/v1/chat/completions`，是 `DirectInferenceClient`；而续3 的三处修复只落在 `ChatHandler` 上。

- **一手证据（把 GUI 自己的输入原样重放）** — `GET /v1/tools` 发布的就是 `ChatViewModel` 每轮交给引擎那份注册表（实测 39 个工具），把它贴回 `/v1/chat/completions`：装上 calls-only grammar 的那条路，对 "What is 2 + 2? Answer with the number only." 回 `finish_reason:"tool_calls"` + `content:""`，调的是问题里从没提过的工具——两次跑出 `exec_command` 与 `echo`（两个名字都真在注册表里，不是幻觉，是「必须调用」的语法在注册表里任选）；同一份声明不装语法则 `finish:"stop"` 直答。`tool_choice:"required"` 是 wire 上唯一能表达该需求的方式，复现同一形态。**这在 GUI 里不会停在响应字段上——它会真的执行。**
- **根因是重复抽象（P2）** — `InferenceOptions` 由两个面各自组装：`ChatHandler`（wire，续3 已接 `toolChoiceDemandsCall`）与 `DirectInferenceClient`（GUI 快路，两处仍 `request.tools.map { !$0.isEmpty } ?? false`）；而 `InferenceRequest` 根本没有 `toolChoice` 字段 ⇒ GUI 既无法表达需求、又总是被强制。同一条用户意图在两面得到两种行为 = 用户看得见的那一面不一致。
- **改法：强制判断只许有一个家** — 新 `shouldConstrainOutput(declaredTools:responseFormat:toolChoice:)`（`Models/OpenAIModels.swift`，与 `toolChoiceDemandsCall` 并排）：只有**需求**（`required`／pinned function／JSON `response_format`）才约束，声明本身从不约束。两个组装面同调它，GUI 快路的 `grammarSchema` 只在需要约束时才构造。今天 `InferenceRequest.toolChoice` 缺席是**当前正确的默认**（GUI 从未要求强制），不是待补的遗漏——真给这个旋钮时再加参数，不预先造抽象。
- **门（回归时谁变红）** — `ToolDeclarationSurfaceTests`：规则表 12 行逐值（1/39 工具 × absent/`auto`/`none`/`required`/pinned、0 工具、nil 工具、`json_object`/`json_schema`/`text`）＋ `bothFacesUseTheOneForcingRule`：两个文件必须出现 `shouldConstrainOutput(`，旧式 `request.tools.map { !$0.isEmpty } ?? false` 或 `return hasTools || hasJsonSchema` 一出现即红。探针 11 §7 新增第三条断言：声明全注册表后 `prompt_tokens` 必须显著上涨（实测 **813 → 9103**）——schema 没进模型的声明是装饰，而只看 content 看不见这件事。
- **顺手换掉会被缓存骗的仪表数字** — §7 首版直接报 `usage.prompt_tokens`（6514），同一请求冷缓存却是 9103：前缀缓存命中会让这个数字自己动（invariant 1）。改成在同一轮里量**边际**（声明 − 不声明 = **+8290** prompt tokens），并把「这题从 `4` 退化成 `2 + 2` 即止（`completion_tokens=4`）」记在断言之外的 NOTE——答得好不好是 checkpoint 的事实，不是本服务器的合同。
- **测出来的新产品缺口（留拍板，不臆改）** — `ChatViewModel.swift:1115` 每轮无条件把 `activeToolRegistry?.toToolDefs()`（全 39 工具）塞进 prompt：一行问题因此多付 ~8.3k prompt tokens，且小模型在这份拥挤下答得更差。vllm／sglang／codex 都按轮收窄工具选择（检索／路由／白名单）。收窄是产品判断，需要用户研究，不是这一轮能替用户拍的板。
- **诚实边界** — GUI 端到端**零验证**：`DirectInferenceClient` 不经 HTTP 可达、本机起不了 GUI、测试文化不加载模型 ⇒ 该面只有静态门 + 用 `/v1/tools` 原样回放的 wire 代理（§7）。一次真实 GUI 会话才是这项的终验。

**10-18(续3) 「模型把工具调用写成散文」的真根因有三处，全在我们自己的缝上**(P0 上游偏离 + P0 行为不一致 + P3 可观测缺口) — 第一性问：一个 coding agent 最该先跑通的是「客户端给 `tools`、模型说要调用、客户端拿到可执行的 `tool_calls`」。上一轮把这条记成「模型发自造方言，本机单模型无法定论」；本轮一手证据推翻该推断——模型会调用，是我们分三处把它丢了。

- **根因① 客户端声明从未进 prompt** — `ChatHandler` 把 `request.tools` 与本地 `ToolRegistry` 求交、未注册名整条丢弃：`get_weather` 不在注册表 ⇒ `grammarSchema=nil`、`hasNativeTools=false`，底层 `resolveToolSurface` 又只做「注册表 spec ∩ 声明名」⇒ surface=∅ ⇒ chat template 里一个 `<|tool>` 块都没有（日志指纹 `Tool surface [whitelist route (0/1 resolved)]: 0/…`）。即使走 guided 路，`handleGuidedGeneration` 造的 `UserInput(prompt:.chat(messages), processing:)` 也**从不传 `tools:`**。契约对齐 OpenAI/vllm/sglang：**真相集是声明**（surface/grammar/上游校验同一集合；`resolveToolSurface(declaredSpecsJSON:)` 让注册名用注册表 schema、未注册名用客户端原样 spec、声明序去重），能否本地执行是另一根轴（只有本地名装 `toolDispatch`，其余原样交回 `tool_calls`）。
- **根因② 引擎已认出的调用在非流式响应里被扔掉** — 非流式出口只 `parseToolCalls(from: finalContent)`，而 `detectedToolCalls`（`.toolCall` 事件自 L1002 起就在收集）只喂了一个计数指标。上游消费并剥离原生方言（`ToolCallFormat.gemma4` = `<|tool_call>call:NAME{…}<tool_call|>`），交回的 `finalContent` 因此是空串 ⇒ 解析无物 ⇒ 客户端拿到 `content:""` + `finish_reason:"stop"` + 无 `tool_calls`：既无答案也无调用，仍是 200 OK；同一请求把 `stream:true` 打开就看得见调用（SSE 路径直接发事件）——两面不一致的直接证据。改法：非流式优先取 `detectedToolCalls`，文本解析只作方言兜底。
- **根因③ 强制与否属于 `tool_choice`，不属于「有没有声明」** — `useGuidedGeneration` 原为 `hasTools || hasJsonSchema`，即声明即上 calls-only grammar。实测：声明 `get_weather` 后问「What is 2 + 2?」约束解码**零 token**（无 tools 的对照答 `4`）——强制语法把答案挤没了。OpenAI 把强制放在 `tool_choice`（absent/`auto`=可直答；`required`/`{"type":"function",…}`=必须调），vllm/sglang 同样只在被要求时强制。新增单一判定 `toolChoiceDemandsCall(_:)`（`OpenAIModels.swift`），guidance 只跟它走。
- **修好后的实测（一并定论上一轮的悬案）** — gemma-4-e2b-it-4bit **不加语法约束**即发模板教的原生方言并被解析交回：`tools:[get_weather]` + 「Use the get_weather tool…」⇒ `tool_calls[{function:{name:"get_weather",arguments:"{\"city\":\"Paris\"}"}}]` + `finish_reason:"tool_calls"`；SSE 同词；`tool_choice:"none"`/不声明均不调用；auto + 算术题答 `4` 且不调用。「方言路能否交付」由此从推断变成事实（交付走解析路，不是 grammar 路）。
- **定音的仪表（能力只按实测公布）** — 新 `ToolCallDeliveryLedger`（记在 `EnginePool`，unload 即归零）：`/v1/models` 每模型 `toolCallDelivery: parsed|prose_only|not_observed` + `toolCallEvidence`（交付轮次/声明轮次/真回来的工具名；`/v1/models` 物体键一律 camelCase，snake_case 只属于 capabilities 的 row NAME）；`/v1/capabilities` 加聚合行 `tool_call_delivery`，`available` 跟**交付**走而非跟流量走——声明了却只拿回散文必须读作 false。
- **门（回归时谁变红）** — 新 `ToolDeclarationSurfaceTests`（声明穿透/注册名 schema 压过客户端谎报/声明序/nil 与 `[]` 仍是零工具/JSON 载体往返/`tool_choice` 六值参数化/非流式必须取结构化调用）+ 新 `ToolCallDeliveryDisclosureTests`（闭集词表、状态优先级、evidence 文案、聚合数学、unload 归零、prose 判定正反例、`/v1/models` 键名 camelCase 且 snake_case 不得泄漏）；`CapabilityMeasurementHonestyTests` 由「加一行」改「加两行」并新增 `tool_call_delivery` 跟随交付（它本轮先抓到我"`available` = 有流量即 true"的过度声明）。探针 `scripts/probes/11-tool-call-delivery.sh`（实测 18 断言全绿 + 5 条如实 note，此前 10 条探针无一覆盖 tools）。全量 `make test-clt` = **2629 tests / 468 suites**。
- **留人拍板 / 已知限制** — ① `tool_choice:"required"` 在模型抗拒调用的题上（"2+2"）约束解码出空：强制力是 per-checkpoint 事实，本服务器只保证**不伪造调用**并把缺口 `logger.warning` 出来（探针 §3d 如实记录）；「强制失败是否重试/报错」属产品判断。② 混合面把调用交回客户端后，上游 restart 循环仍会续写一轮 ⇒ 客户端同时看到 `content` 与 `tool_calls`（合法但噪）；真停在调用点需要上游 `ChatSession` 给「不执行即终止」的缝（与 §轮内即时转向同一类）。③ `response_format: json_object`（无 schema）交付 `{}`——**当时把它记成「JSON 合法而空，拒绝还是重试属产品判断」，这个诊断是错的**（10-19 一手复核）：空不是模型的选择，是我们的兜底串 `{"type":"object","properties":{}}` 点名了零个合法键 ⇒ 语法只允许吐 `{}`。已由 10-19 修（同一个兜底串在仓库里有四份），并把「调用方自己钉零键仍得 `{}`」留作控台对照（探针 12 §4）。④ guided-gen 的 `stop` 仍是该路第二真相（自用 `hasSuffix` + 命中重发 trimmed 整段），统一进 `EnginePool.firstStopOccurrence` 时要用探针防回归。⑤ **GUI 快路的 grammar 半边确是修前的样子**：`DirectInferenceClient` 的 `useGuidedGeneration` 仍写作 `request.tools.map { !$0.isEmpty } ?? false`（L408/L786 ⇒ 声明即强制），已由续4 修。**但本子条目当时另一句写错了**（续4 复核一手代码后自纠）：`ChatViewModel` 并非「仍以 `parseToolCalls(from: responseText)` 认调用」——它的主路是结构化事件 `.toolCall`（`ChatViewModel.swift:1192`，另见 :917/:932/:1319），`parseToolCalls(from:)`（:1329）只是代码里写明的「事件缺元数据时」兜底；即根因② 在 GUI 面本就不存在，错的只有 grammar 那一条。本机起不了 GUI、探针也不覆盖 GUI ⇒ 该面仍缺活体验证（续4 给了静态门 + 用 `/v1/tools` 原样回放的 wire 代理门）。
- **仪表自身的一次自纠（同轮）** — 探针首跑 5 条 FAIL，根因是探针读错键：`/v1/models` 物体是 camelCase（`toolCallDelivery`），而它读了 snake_case；两个 helper 又把 `PROBE_BODY` 写成未定义的 `BODY` ⇒ 恒空。修探针的同时补了两条能变红的门（单元测试钉住 `/v1/models` 键名 camelCase、且 snake_case 不得泄漏），并把 HIG 那条已漂移的 grep 计数（3/15/264 → 实测 5/17/278）从 AGENTS.md 撤下：没有仪器跟着的数字必然腐烂。

**10-18(续2) 引擎日志写着「已停」,客户端却收到全文:`break` 在 `switch` 里出不去生成循环**(P0 行为不一致 + P1 执行链) — 第一性问:`stop` 是客户端用来「就此打住」的旋钮;那么 `.done(.stopSequence)` 发出去之后,是谁还在继续吐字?

- **实测缺陷(修复前,一手)** — `POST /v1/chat/completions` 带 `stop:["2"]` 打在数数题上,回 `1 2 3 … 20` 全文 + `finish_reason:"stop"`;同一次运行的服务器日志里躺着一行 `stopmatch=2 len=3`(临时诊断行,提交前已删):引擎早已判定要停,循环当没听见。第二个形态更安静:`stop:["banana"]` 的输出比同题无 stop 的对照**少一个 banana**——命中落在 offset 0 时整块文本被丢弃 ⇒ 客户端要求切,结果既没切、又丢了本该保留的字,而且没有任何信号。
- **根因两条,都在四条路径共用的那个 helper** — ① `checkStopSequence` 的 9 处调用点一律 `if shouldBreak { … break }`,而它们全都位于「生成 for 循环 → `switch generation` →(内层 segment `for`/`switch`)」的深处:Swift 的 `break` 只离开最近的 `switch`,外层循环照常继续(标量证据:`completion_tokens` 与不带 stop 的对照完全相同)。② 匹配条件是 `accumulated.hasSuffix(stop)`:stop 若在解码块中间到达就永远看不见;命中在 0 号位时 `trimmed` 为空 ⇒ 整块不发。
- **改法(一处判定 + 标签 break + 正确的词)** — 新 `EnginePool.firstStopOccurrence(in:sequences:)`:在全文里找最早命中(同一位置并列取先列者,空串不算),取代 suffix 判断;只上交「既新又在切点之前」那一段(不是整块,也不是把 trimmed 重发一遍),然后 `.done(.stopSequence)`;三条生成循环加标签并真正退出:`break mtpGenerationLoop` / `break stdTokenGenerationLoop` / `break streamDetailsLoop`。OpenAI 线上把 stop-string 终止改报 `"stop"`——它的 `finish_reason` enum 只有 `stop | length | tool_calls | content_filter`,而本仓反方向早就把 `stop_sequence` 译成 `stop`(`Sources/ocoreai/Models/AnthropicModels.swift:726`):同一事实两种拼写就是自己跟自己不一致。Anthropic 线经 `openAIToAnthropicStopReason` 仍得 `end_turn`,这条前提写进断言,免得共享 helper 的改动悄悄改到另一条线。
- **惩罚符号(上轮残留 ① 本轮落地)** — `> 0` → `!= 0`,对齐 pin `48114ee` 的上游 `Libraries/MLXLMCommon/Evaluate.swift:345/:355/:365`(三条全是 `!= 0`)与 `:614`(减法),三条 penalty 收敛进 `upstreamPenalty` 一处。**同时把「±2.0 有没有改变输出」从断言降级为实测记录**:同一个上下文窗口内的惩罚是均匀的,不改变这些 token 之间的相对次序 ⇒ greedy 输出不变是这类题的正常结果,既不能证明旋钮失效、也不能反证生效(`repetition_penalty=50` 输出不变同理:对负 logits 做除法反而抬升)。真正的钉子是映射层单测 + 上游行号;本机要直接看 logits 只能走 `/v1/completions` 的 logprobs,而它在 macOS 26 回 501 ⇒ 没有仪表就不承诺 logits 层的效果。
- **顺手修掉一条证据层的空过** — `scripts/probes/run.sh` 的枚举 glob 是 `0*.sh`,只看得见 00–09:十号探针存在、却从未被跑过,"8/8 全绿"一直在描述一个少了一个成员的覆盖面(改 `[0-9]*.sh` 并留注释;invariant 1 的同一族:扫描先看没看见自己的成员)。
- **门** — 新 `Tests/ocoreaiTests/StopSequenceDeliveryTests`(8 条:全文最早命中、并列取先列者、offset 0 全切、空序列/空串不切、多字节按 Character 而非字节切,外加 finish_reason 词形两条 + Anthropic 侧不变的前提一条)+ 新活体探针 `scripts/probes/10-sampling-knob-delivery.sh`:断言 `stop:["2"]` 的内容必须是 `1`、`completion_tokens` 必须显著小于未切对照(实测 **3 vs 50**)、`finish_reason` 必须是 `stop`、从未出现的 stop 一个字节都不能切、流式与非流式必须给出同一个切点。

**10-18 一个负数把服务打死了**：wire 层第一次有数值域门，错误体第一次说出是哪个字段（P0 行为不一致 + P1 执行链） — 第一性问：客户端发一个越界的数字，服务器该回什么？活体实测的答案是「什么都不回」。

- **缺陷与根因** — `POST /v1/chat/completions {"max_tokens":-5}` ⇒ 进程 `EXC_BREAKPOINT (SIGTRAP)`，栈顶 `SchedulerActor.dispatch()`：`UInt64(request.tokenBudget)` 对负数 trap。一次畸形请求带走整台机器上所有会话，客户端拿到空响应——没 status、没 `error_code`、没 remediation，而 trap 不是拒绝。安静的兄弟更隐蔽：`max_tokens:0` 回 200 + 空补全（surface 宣称生成过东西，实际什么都没生成 = 之前未守住的第二条不变量）。
- **一处 checker、三份 forwarder、per-wire 边界**（P0 根因 + P2 顺手清重复抽象） — 新 `Sources/ocoreai/Models/SamplingDomain.swift`：`SamplingKnobs`（`temperatureRange`/`topKMinimum`/`nMaximum` + 命名 counts 列表）与 `firstViolation` 把规则只写一遍，三个 forwarder（`ChatCompletionRequest`/`CompletionRequest`/`AnthropicMessageRequest`）只声明自己那条线的边界差：OpenAI `temperature` [0,2] vs Anthropic [0,1]；`top_k` 0 在两条线都是「关闭」——因为本引擎就是这么用它的（`CompositeSampler.swift:138` 只在 `topK > 0` 时过滤，故 0 合法、负数越界，与 vllm 同语义）；`n` 在 chat 必须是 1（该端点一次只回一个 choice），而 `/v1/completions` 真的顺序生成 n 份（`CompletionsHandler.swift:348` 的 `0 ..< n`）⇒ **按端点定范围，不按品牌定范围**。三条 handler 首行调用（model 解析之前、内容安全之前、向调度器预留之前）：越界的数字在变成内部计数之前就被点名挡下。
- **错误体第一次可机读地点名字段**（P0 兼容，对齐 vllm/sglang） — 新 `AppError.invalidParameter(param:message:value:)` → 400，JSON body 加 `param` + `value`，并把 400 的 `type` 从万能的 `app_error` 改成两份 spec 共用的 `invalid_request_error`（vllm 引用侧：`vllm/sampling_params.py:630-712` 定范围、其 validation handler `handlers/validation.py:171-186` 把字段名放进 `param`）；文案同式：`top_p must be in (0, 1], got 0.`。一个 20 字段 body 上的 400，如果不说是哪个字段，客户端只能字符串猜。
- **地板**（P1：caller bug 不再等于进程死亡） — 新 `Sources/ocoreai/Scheduler/KVCacheBudget.swift` 统一原先各自维护的两份 `KBPerToken`（`AdmissionGate` 与 `SchedulerActor` 各一份，靠注释「对齐」= 等着漂移的第二个真相），`bytes(_:)` 以 `max(0, tokens)` 兜底（沿用「生产代码只断结构性不变量」的规矩，不引 precondition）；`dispatchBatch` 的 `0 ..< count` 也不再被负数 Range trap；`estimatedCost` 改成两项分别兜底，负输出预算不再给真存在的输入打折。
- **门** — 新 `Tests/ocoreaiTests/RequestNumericDomainTests.swift`（26 条，均精确值）：逐字段越界点名 + 边界放行（`max_tokens`1、`temperature` 0/2、`top_p`1、`top_k`0、penalties ±2、`seed`0）、`max_completion_tokens` 用哪个拼写就怪哪个、同一个 1.5 在 OpenAI 线合法 / Anthropic 线越界、`estimatedCost` 负输出不减输入、`dispatchBatch(-1)` 返回空、`submitAndDispatch(tokenBudget:-5)` 必须活着回来；另有 HTTP 层五条（三端点发真实 body，断言 400 + `param` + `type` + 回显值，且门必须在需要模型的一切之前点火，否则无模型时会退化成 503 而门静默空转）。新活体探针 `scripts/probes/09-malformed-request-honesty.sh`（24 断言）：八次「越界→400→紧接着一次真实生成仍拿到代码词」的存活检查、`max_tokens:0` 不再是 200、同一温度在两条线一个合法一个越界、八连发畸形 body 之后服务照旧出真活。
- **证据层自身两处缺陷（同轮修，不是产品代码）** — (a) macOS 自带 bash 3.2 会把 `cmd "$(other …"k"…)"` 这种嵌套引号命令替换解析坏，把截断的 messages 递给 helper：首个 run 唯一那条 FAIL 出在 harness 而不是服务器（改单引号拼接，与 01 探针同法）。(b) `_lib.sh` 的 `probe_boot` 把「端口被别人抢在 bind 前取走」报成「Metal 不可用或模型加载卡死」并白烧 240 s（04 探针这轮就是这么红的）：现在识别 `already in use`、说清是抢绑定失败、换端口重试（最多 3 次），模型加载真卡死才印那条 remedy。

**同会话门禁计数**：全量 `make test-clt` = **2583 tests / 462 suites / 402.1 s** 全绿（上一轮 2557/457 ⇒ 恰 +26/+5 = 本轮新 suite）· focused `swift test --filter 'NumericDomain|TokenFloor|MalformedRequest'` = 26 tests / 5 suites 全绿 · `swift build` exit 0 · 活体 `bash scripts/probes/run.sh` = **9/9 全绿 = 203 断言 0 失败**（01=12、02=15、03=29、04=40、05=34、06=22、07=12、08=15、09=24）· `make format-check` 0 改动（先 `make format` 收 4 个文件）· `make audit` 全绿（Class-I 35 行）· `make docs-check` root=50254/50681 + claims 12/12 + gateable-refs 64(≥50) + routing 5 · `make anchor-check` 16 锚 0 漂移 0 跳过。

**残留(不静默扩大范围)**：① 惩罚项门槛 `> 0` **本轮已修**（见上一条 10-18(续2)：`!= 0` + `upstreamPenalty` + `PenaltySignDeliveryTests`）。当年定位记录留档：惩罚项的门槛在 `Sources/ocoreai/Engine/MLXBridge.swift:1007/:1010/:1013` 全是 `> 0`，而 pin `48114ee` 的上游 `Libraries/MLXLMCommon/Evaluate.swift:345/:355/:365` 全是 `!= 0` ⇒ **负的 `repetition_penalty`/`presence_penalty`/`frequency_penalty` 在 wire 上合法（本轮新门放行 [-2, 2]）却在引擎被静默丢弃**，客户端拿不到任何信号 = 不变量 2 的又一处违例；改法是对齐上游改 `!= 0`，门 = 同 seed 下 ±0.8 penalty 必须产出可区分的生成 + 映射单测。② chat 的 `n>1` 现在是点名拒绝（诚实但不交付）：`/v1/completions` 已能顺序生成 n 份，chat 要真做 n 份需先定会话与流式语义，留人拍板。③ GUI Settings 仍只读 tier truth（未注入本轮的实测 overlay）。④ `_applyBitmask` 常数等 macOS 27 实跑；iOS 运行时零验证；coverage 报告仍缺。

**10-17(续3) 上游三个提交全部零消费面；真正的 P0 在本仓——能力面第一次按实测降级，并第一次说出「能不能收视频」**（P0 行为不一致 + P3 可观测性） — 第一性问：这个 `true` 到底是「编译进去了」还是「这台机做到过」。`/v1/capabilities` 是客户用来路由的面，它却只报机制：`macOS` 上 `screenshot_capture` 恒 `available:true`，note 只写「Screen capture via ScreenCaptureKit SCStream (macOS only)」，而**同一台机**的 `/v1/multimodal/status` 报 `screenStatus=blocked`/`screenDelivery=failed`（10-15 实测原话「无法开始流播放」）——同一个矩阵里 `local_stt`/`tts_speech` 早就把 note 写成「tier floor + 去 /v1/multimodal/status 看本机实测」，独这一行没有：两种诚实度共存于一份矩阵。第二条更直接：整个能力面对「能不能收视频」只字未提（`video_generation` 说的是**输出**），round 14 给 `/v1/models` 补了 per-model 实测行，server-wide 那半仍是空洞，探针 08 §4 当时只能记一条 NOTE。

- **能力矩阵的 tier 真相不动，实测另开一层 overlay**（P0 根因） — 新增 `RuntimeCapability.measured(_:)`：`lines`（`static let`，prompt / `info` 工具 / Settings 共用的那一份不可变矩阵）保持不变——**把实测塞进 `static let` 会让答案随「首次读发生在尝试之前还是之后」而变**，那是用顺序偶然性造第二个真相。只有 `/v1/capabilities` 改发 overlay：`screenshot_capture` 在本机测到失败时降成 `available:false` 并**引用框架原话**（不意译），且**不粘滞**：下一次尝试覆盖记录，权限修好不必重启；新增 `video_input` 行取 `VideoDeliveryLedger.aggregate`，聚合语句只长在 `VideoDeliveryAggregate.evidenceLine` 上（两处措辞 = 两个真相），未观测显式发 `not_observed`（它只说本进程没跑过，不评价 checkpoint 能不能看）。铺路规则写进 `lines`：`macOS` 分支的 note 现在写明 tier 与实测去哪读，所以即使不做 overlay 的消费者（prompt/`info`/GUI）也不会把它当成交付承诺。顺手清掉零消费者的 `RuntimeCapability.wirePayload`：它自称 wire-facing payload，而 wire 已不等于 `lines`，留着就是新的不一致。
- **门**（含现场对照） — 新 `CapabilityMeasurementHonestyTests`（15 条，全精确值）：零证据时不改一个 `available` 也不改一句 note、**永远不升级** tier 已关的行、失败降级并引原话、拿到帧才能重新说 true（带延迟）、聚合数学（models/turns/items 分开数）、`forget` 后聚合归零、两粒度句子必须不同且都来自 ledger、router 源码扫描带自身下限（扫不到 = 红，不是空过）。探针 03 新节「capability rows must agree with the surfaces that measured them」：现场把 `video_input` 对照 `/v1/models` 的 per-model `videoInput`、把 `screenshot_capture` 对照 `/v1/multimodal/status` 的 `screenDelivery`，并给 verdict 数设下限；探针 08 §4 那条 NOTE 升成硬断言（实测后必须 `available:true` 且带「delivered across …」证据句）。
- **上游 round 15：pin `6e338e5df` → `48114eedf`（= clone HEAD，`api.github.com` 亦此），三条逐一裁决均零消费面**（P0 上游偏离审计） — **#705** `fix(fusion): Preserve scaled NVFP4 projections`（`Libraries/MLXLMCommon/FusedQuantizedLinear.swift` +2：带 global scale 的投影不再被融合）是 `package func`，本仓在 `Sources/` 零引用 ⇒ 正确性由上游承担；**#697** Mellum 2.1（新 `Libraries/MLXLLM/Models/Mellum.swift` 426 行 + registry `mellum` + `LLMRegistry.mellum2_1_12b_a2_5b_thinking_6bit`，另把 `QuantizedVocabularyProjection` 的 bits 放宽到 4/6/8）——本仓**没有架构白名单**，新架构自动可用，能力照旧只按实测公布、不据上游注册表推断 ⇒ 零改动；**#695** LFM2-VL 读 transformers-5 的三个键（`intermediate_size`/`rope_parameters`/顶层 `tie_word_embeddings`，`Libraries/MLXVLM/Models/LFM2VL.swift` +69−34）——本仓只把 LFM2 当 **embedding** 模型用（`LFM2.5-Embedding-350M`），不解析 LFM2-VL config，且本地读的键是 `max_context_length`/`max_position_embeddings`/`n_ctx`，不在被改的三键里 ⇒ 零消费面。notices 表随 pin 走：重跑 `scripts/collect-third-party-licenses.sh` → `NOTICES.md`/`manifest.json` 同步为 `rev 48114eedf3c3`（deps=34，missing=none）。
- **回归** — 全量 `make test-clt` = **2557 tests / 457 suites / 280.7 s** 全绿（上一轮 2542/456 ⇒ 恰 +15/+1 = 本轮新 suite）· focused 69 tests / 7 suites 绿 · `swift build` 绿（94.63 s，含新 pin 全部依赖）· 活体 `bash scripts/probes/run.sh` **8/8**，方案总数 **179 断言**（上轮 176 ⇒ +2 探针 03 新节、+1 探针 08 §4 由 NOTE 转硬断言；单跑复核 03=29/0、08=15/0）· `make format-check` 零重排 · `make audit` 绿（Class-I 35 行）· `make docs-check` 绿（root 50677/50681、claims 12/12、gateable-refs 61）· `make anchor-check` 16/16 0 漂移（新 pin 下 `ChatSession.swift:1110/:1724` 仍在原位）。
- **本轮的文档账**（shrink-only 棘轮，不是口头话） — 新规则要进 AGENTS.md，就得有别的东西出去：本轮把幻灯片式证据推回它们该待的地方——CoreAI 文件数目录（无门复测的计数本身就是腐化源）、DocC 快照的字节数与 topicSections 枚举、Local gate reality 与 build-gate-reality.md 重复的叙述、notices 段落里可一跳读到的组成详情、以及身份句的定版历程。新规则进去、这些出去，root 50589 → **50677**，上限 50681 不变。
- **未决** — ① `video_generation`（输出路）仍是 tier 断言（#avail 27+，本机不可实测）：overlay **只降级已测的轴、从不无证据升级**，所以 macOS 26 上它恒 false，这与 `model_fidelity` 一样是诚实负向而不是缺口；② Settings 面板仍读 `lines`（tier truth，其 note 已写明实测去哪读）——要让 GUI 在同一面板直接显示实测结论，需把 `EnginePool`/`ScreenDeliveryRecord` 注入 SwiftUI 层，属结构改动，留人拍板；③ guided-gen / MTP 提前 release 的轮次仍不记 video（漏报方向，延用 round 14 已知边界，写死在 `VideoDeliveryLedger.swift` 头部）。

**10-17(续) 「看得见视频」终于由实测说出口:`/v1/models` 开始发 `videoInput`/`videoEvidence`;而刚立的 anchor 门第一轮就红了,红在它自己的改动上**(P0 行为不一致 + P3 可观测性) — 上一轮探针 08 已经量到红/蓝短片各自答对、`prompt_tokens` 712→856(+144 帧真进 prompt),但发现面一个字都没提:**不过宣是必要的,不是充分的**,在同机两个模型之间做选择的客户端读不到「这一个看得见」。invariant 2 是双向的。

- **`video_input` 只按本进程的实测轮次公布**(P0) — 新增 `Engine/VideoDeliveryLedger.swift`(与 `PrefixReuseLedger` 同族:值类型活在 `EnginePool` 的 actor 隔离里、per-model、closed vocabulary `{delivered, not_observed}`、`unload` 即 `forget`)。记录点选在唯一一条同时满足「帧进了模型」与「这一轮产出了 assistant message」的缝:`releasePoolSlotWithAssistant`(`EngineInference.swift:3163`);计数在 media 交付处(`result.video != nil`),所以不经 spool 的 `file://` 那条也算数。三条一手细节才让这块能落地:① `ModelObject` 的键是 **camelCase**(`ownedBy`/`weightsDir`/`contextLength` 是既有约定)⇒ 新字段叫 `videoInput`/`videoEvidence`,别按别处 payload 的 snake_case 类推;② **`GET /v1/models/:model` 这条路由根本不存在**(只有 `/sampling` 与 `/kv-cache`),§4 起初读到 `<absent>` 就是撞在这上面 —— 发现面在 list 上;③ 证据句里的 prompt 数取上游 `completionInfo.promptTokenCount`(经 `stdPromptTokenCount` 带到 release 缝),不是 bytes/4。负向**显式**发 `not_observed`:「字段缺失」与「想过但没观测到」对客户端是两回事;`videoEvidence` 为 nil 就整条不出字段。证据句子只长在 record 上(`evidenceLine`),router 只能引用不能重拼 —— 两处措辞就是两个真相。**已知不覆盖**:`guided-gen`/MTP 提前 release 的轮次既不延长 pooled history 也不记 video ⇒ 那两条路上仍是漏报(诚实方向),这条写进 `VideoDeliveryLedger.swift` 头部,不藏在心里。门禁:`VideoDeliveryDisclosureTests`(10:精确累积/零项不记/跨模型隔离/forget/证据句逐字/closed vocabulary/router 两个词都发且真读 ledger/DTO camelCase 且 nil 不出字段/记录点在成功缝)+ 探针 08 §4 从 NOTE 升成硬断言(实测后必须 `delivered` 且带证据,并加一组对照组)。活体:`mlx-community/gemma-4-e2b-it-4bit` → `videoInput=delivered ; evidence=delivered in 3 completed turn(s), 3 video part(s), last prompt_tokens 856 on this server`,同一进程对照组 `mlx-community/LFM2.5-Embedding-350M-4bit` → `not_observed`(探针 08:14 断言 0 失败,其中 5 条实测)。
- **anchor 门第一轮就抓住 4 处漂移,全是本轮自己插的行**(P3) — std 路径上方插 4 行(声明 `stdPromptTokenCount`)+ release 签名拆 3 行 + 记录 1 行 ⇒ steer 排空 `2940→2944`/`3556→3563`、ThinkingBudget `4161→4168`/`3657→3664`,连带 root AGENTS.md 的 `components:` 两条 `4176→4183`/`3680→3687`。这正是 round 14 立这个门要防的那类事:**改代码的人不会主动想起文档**,门替他记着。修完复跑 `checked=16 drift=0`,并给新缝补一条锚点(video 记录点 3163)+ `Sources/ocoreai/Engine/AGENTS.md` 新规则「Video is disclosed where a turn completes, not where bytes arrive」。

- **回归**:全量 `make test-clt` = **2542 tests / 456 suites / 218 s** 全绿(round 14 记 2528/454;+14/+2 = 本轮 `VideoDeliveryDisclosureTests` 10/1,加上一条提交自带的 `ProbeHarnessHygieneTests` 4/1 —— 那个数是在它落地前测的)· focused 67 tests / 11 suites 绿 · 活体 `bash scripts/probes/run.sh` **8/8 全绿 = 176 断言 0 失败**(01=12、02=15、03=27、04=40、05=34、06=22、07=12、08=14;round 14 记 168 ⇒ +4 是 01–04 现在能验到「二进制的 pin 与 checkout 洁净」这条前提、+4 是 08 §4 从 1 条 NOTE 变 4 条硬断言)· `make format-check` 零重排 · `make audit` 绿(Class-I 35 行)· `make docs-check` 绿(root 50589/50681、claims 12/12、gateable-refs 60、routing 5)· `make anchor-check` **16 锚点 0 漂移**。

**10-17 三个最大的洞都不在功能里,在「引用」与「生命周期」里:一段视频把整条会话永久毒死、探针跑的是五天前非 pin 的二进制、`docs/` 整层证据从来没进过 git**(P1 执行链 + P0 上游偏离/行为不一致 + P3 可观测性) — 三条的共同点是:任何静态读代码的人都看不出错了,因为错在「谁引用谁、活多久、在不在版本控制里」。

- **媒体字节的寿命 = 引用它的那个会话的寿命,不是那个请求的寿命**(P1,根因钉死) — 实测:同一段红色 clip,`data:` URL 发过去第一轮 200 且答对(`Red`,`prompt_tokens` 712→856 = +144 真帧),**此后这条会话的每一轮都是 `500 Generation failed: Inference failed: The operation could not be completed`,永久**;同一 clip 换 `file://` 一切正常且第 2 轮还能回忆。根因:请求尾的 `defer` 把解码出来的 temp 文件删了,而上游 `ChatSession` 保留收到的 message(含已解析的媒体路径)并在**每一轮**把整段 transcript re-feed 给 `processor.prepare`(`ChatSession.swift:1110` @pin `6e338e5df`:`templateMessages = leadingMessages + currentConversation.messages`)⇒ 删掉的不是临时垃圾,是会话自己的记忆。落码: `Engine/MediaSpool.swift`(内容地址 `<16hex fnv1a64>-<bytes>.<ext>`;owner = 池化会话、pin = 在飞请求、兜底 = idle TTL + 字节预算)、`Multimodal/ChatMediaResolution.swift`(`data:` 不检查、`http(s)` 交上游、本地路径必检)、`AppError.mediaUnresolvable` 400 / `.mediaLost` 500(都带 remediation)、`ChatHandler` 在 safety/scheduler/engine 之前退、`EngineInference` 不再删而是 `pin/unpin` 并在 release 时把 `mediaFiles` 交给池、`SessionPool` 新增 `mediaIdleTTLSeconds=3600`/`mediaMaxBytes=512MiB`/`mediaPolicy`(下限 `sessionTTL+60`)+ 六处 discard + acquire 处 sweep。门禁:`MediaLifetimeTests`(15)、`ChatMediaResolutionTests`(12)、`PerceptionMediaDeliveryTests` 改钉 `spooledURL`;探针 08 十断言五实测(spool 2 文件 8.0K ⇒ 下一轮仍答 `Red` ⇒ 同一会话第二条 clip 也读得到 ⇒ 缺文件 400 `media_unresolvable`)。**测试逼出来的六个自伤**(全部真实修掉):`URL.deletingLastPathComponent()` 会补回 `/` ⇒ containment 判定恒假 ⇒ 删除静默不执行;`/var`↔`/private/var` 拼写不一致 ⇒ pin 键对不上;`discard` 缺形状域(会删到别人名字格式的文件);探针把 500 当成「诚实拒答」记 PASS(假绿);探针所有轮共用 `session_id:""`(会话根本没串起来);正则里裸 `[`(`subtraction with '-'` 不支持)。

- **探针跑的是哪条二进制?——注释承诺「最新」,代码执行「第一个存在」**(P0 上游偏离) — SwiftPM 6.4 的产物在 `<scratch>/out/Products/<config>/ocoreai`,而候选列表第一条 `.build-clt/debug/ocoreai` 自工具链升级起就不存在 ⇒ 默认落到 `.build/debug/ocoreai`:**10-12 构建、上游 `7eb77efa`,而 pin 是 `6e338e5df`** ⇒ 那样一遍活体测的是本仓根本不编译的代码。连带:`probe_require_clean_dependency_checkout` 的 scratch 用固定 `dirname/../` 推导,新布局下指到 `.build-clt/out/Products` ⇒ pin/洁净这两条前提每次都打印「not verifiable」而不是成立。第三条更阴:`05-hearing.sh` 自带 `trap 'rm -f "$AIFF"' EXIT INT TERM`,bash 每个信号只保留一个 handler ⇒ `_lib.sh` 的 `probes_cleanup` 被顶掉 ⇒ 它的 server 从没收到 TERM,`Core/SingleInstanceLock.swift` 的 flock 一直被占 ⇒ 06/07/08 各烧满 240 s ready 超时,报成「Metal unavailable or model load stuck」——一次进程泄漏被误诊三遍。落码:候选按依赖树评分选择(2=干净且在 pin / 1=不可验证 / 0=脏或偏离 pin),**同分才比 mtime**;`probe_scratch_for_binary` 逐级上溯到 scratch 根(两代布局都覆盖);`probe_atexit` 提供可叠加钩子(05 改用它);启动前只回收本仓 build 目录里的残留 `ocoreai`,别人起的只报 pid 与补救、绝不动手。门禁:`ProbeHarnessHygieneTests`(4 条,含用合成 git checkout 真跑「pin 优先于 mtime」的行为测试,并给扫描设下限)。

- **行号引用需要一个会红的门;而 `docs/` 整层从来没进过 git**(P3 + P0) — `make docs-check` 的 P3 只能问「行号在不在文件里」,所以一条偏了 21 行的引用照样算通过。本轮数了一遍:**15 处引用是错的** —— ThinkingBudget `4119→4146`、`3615→3642`、`4134→4161`、`3638→3665`(round 14 在其上方插了 ~27 行,而 round 13 刚把这些号钉过)、steer 排空 `2908→2933`/`3514→3541`、`sample(from:)` `198→207`、`Application.swift:31→38`(print 面)、pin 行 `Package.swift:41→43`、`CoreAIPipelinedEngine.swift:53/601→631/:958`(MPSGraphSamplers 真实消费点)、上游 `KVCacheRuntime.swift:155→KVCacheConfiguration.swift:486`(文件已迁名)、`pull_request.yml:216→214`、以及本轮新写的注释里 `ChatSession.swift:1131→1110`(在 pin 和 clone HEAD 上都对不上)。落码:`scripts/anchor-check.sh` + `make anchor-check` —— 标记语法 `anchor:<repo|.> path:line[-end] token`,本地锚走工作树、上游锚走 `Package.resolved` pin 的 `git show`(与那个 clone 此刻 checkout 了什么无关),本地锚下限 6,上游树缺失时 SKIP 计数 + WARN(既不误红,也不静默绿);进 `ci-local` 与 CI audit job;`Engine/AGENTS.md` 钉 9 个锚、`EngineInference.swift` 注释里钉 1 个,证明门会红(把 `1385` 手改成 `1384` ⇒ DRIFT 报「really line 1385 of 4812」exit=1)。顺手修 `agents-md-contract.sh` 的两处环境推断:`~` 与上游 clone 树只问 `$HOME`,而 CLT/sandbox 配方把 HOME 指去 `/private/tmp/codexhome` ⇒ 每条上游引用都判 unresolved(狼来了式误红);改 `$HOME`+passwd 双源并一并扫 `.build*/checkouts`,摘要新增 `upstream-trees=78`。**最大那条是结构性的**:`.gitignore:36` 的 `docs/`(挂在「Reference repos」标题下)把项目自己的证据层整层吞掉 —— AGENTS.md 路由进去的三份 guide(~19 KB,正是它要求「长证据挪到一跳之外」的地方)在本机存在、在任何 clone 与 CI 里不存在,而 P7 只跟磁盘比对所以永远看不见。改 `docs/*` + `!docs/agent/**`、三份 guide 入库,并加 **P9:路由目标必须 `git ls-files` 可解析** —— 它第一次跑就红了,红得准:点名那三份文件。

**同会话门禁计数**:全量 `make test-clt` = **2528 tests / 454 suites / 403 s** 全绿(round 13 基线 2502/449),合同 `swift=6.4 sdk=26.5 coreai=no metal=ok-probed`;活体两遍合计 **8/8 探针全绿 = 168 断言 0 失败**(01=11、02=14、03=26、04=39、05=34、06=22、07=12、08=10);`make format-check` 0 改动、`make audit` 全绿(Class-I 35 行)、`make docs-check` root=50613/50681 + claims 12/12 + refs 60(≥50) + routing 5、`make anchor-check` 15 锚 0 漂移 0 跳过。

**残留(不静默扩大范围)**:① 探针 08 §4 —— 视频是**实测可交付**(红蓝各答对、+144 tok),但 `/v1/models` 的 `video_input` 与 `/v1/capabilities` 的 video 字段都不提 ⇒ 不是过宣,是**漏报**,客户端无从得知;下一刀按 `processor_class` 逐 checkpoint 发布实测 `video_input`,把 §4 从 NOTE 升级成硬断言。② 一次编辑仍付一次全量 prefill(实测 752 tok,prefixReuse 三态已公布)。③ `_applyBitmask` 常数等待 macOS 27 实跑;iOS 运行时零验证;coverage 报告仍缺。④ 新发现未动:`AudioIO.swift` 的录音器把 `ocoreai_audio_*.caf` 落在 temp(本机开机即见 9 个),属同一族「谁写的字节谁负责」的账,单列一刀。


**10-16 上游 8 个提交里藏着 P1 的真答案:热轮次 `cached_tokens` 从 0 → 710/733,顺带纠正我们把根因读错的那条**(P0 上游偏离 + P1 执行链) — 第一性问仍是「客户端发出去的历史,模型这次真的重刷了吗」。`Package.swift:43` 的 pin 从 `4cc550451` bump 到 `6e338e5df`(= clone HEAD,pin 是 HEAD 祖先、checkout 干净,由 `scripts/probes/_lib.sh` 当场断言)。逐条裁决(全量证据在 `.build-clt/checkouts`,镜像 = `/Users/uingei/references/mlx-swift-lm`):

- **#700 Drop the attention mask from text-only VLM prompts** — 就是这一条解开了我们的 P1。`Gemma4Processor`/`Gemma4UnifiedProcessor`/Gemma3/FastVLM/Mistral3/SmolVLM 此前给**每个** prompt 配一条全 1 mask,而 `ChatSession` 把「带 mask」读成不可续用(`carriesAttentionMask`),于是 `ExtendCachedPrefixRule` 在每个纯文本轮直接 bail。
- **#622 Fix exact prefix rewinds in rotating KV caches** — 公开面变化:`KVCacheConfiguration.rewind: Rewind?`(opt-in)、`KVCacheConfigurationError.invalidRewindCapacity`/`.incompatibleRewindCapacity`、`PromptCacheState.isTrimmable` → `maxTrimCount`、`KVCache.maxTrimCount`、`RotatingKVCache(maxSize:keep:rewindCapacity:)`。我们的 `makeKVCacheConfiguration(strategy:)` 走带默认值的 label init ⇒ 源码兼容;reserve 是否要接 = 新的开放项(见 AGENTS.md § Open)。
- **#696 Fix the two tests failing on main** — 不止测试:`SpeculativeTokenIterator.finalizeGeneration()` 现在把「全接受」那一轮遗留的最后一个 draft 喂回 draft cache,此前 draft 缓存落后 1 token ⇒ 下一个 ChatSession 轮双缓存 rebuild。直接利好我们的 MTP 路(`generate(::mtpDrafter:)`)。
- **#699 Omit empty text from message content parts** — assistant 只有 tool call 时不再产生 `{"type":"text","text":""}`,模板 re-render 与缓存对齐(Qwen3-VL 此前每次 tool 后续全量 prefill)。**与前一天我们在 `/v1/messages` 闭掉的同一族缺陷互为印证**:一个在 wire 侧把块型收窄,一个在模板侧把空部分当有内容。
- **#698 Throw MLX errors raised on the loader's threads** — checkpoint 并发读、异步 `loadWeights`、按需组件加载这三条线程上的 MLX 错误(分配失败、sanitize 形状错)此前落到默认 handler **直接终止进程**,现在在各自 `withError` 作用域里抛出 ⇒ 我们的 `EnginePool` 加载路径真正拿到可报告的错误。
- **#619 Allow tokenizers to provide streaming detokenizers** — `Tokenizer.makeStreamingDetokenizer()` 与 `StreamingDetokenizer.finish()` 都带协议扩展默认值 ⇒ `TokenizersMLXTokenizerAdapter` 无需改动(编译面已证)。未覆写 `finish()`,留作后续。
- **#693 / #701** — guided-gen 诊断日志按 `diagnosticLog` 收敛;scripted-model 测试支撑(`KVCacheTypeRegistry`/`AuxiliaryKVCache`/`TranscriptKVCache`,`package` 面)。零消费。

**根因读错了:我们钉的是不该钉的那条规则**(invariant 1 的同族错误 —— 断言把前提外包给了环境)。AGENTS.md 与 `PrefixReuseLedger.swift` 头部此前写着「根因已钉死:`PromptCacheReusePolicy.canRewind` 要求 `cache.isTrimmable`,而 `BaseKVCache.isTrimmable=false`」。但**只增长的会话轮不到 `RewindToCommonPrefixRule`** —— 它先由 `ExtendCachedPrefixRule` 裁决,而那条规则压根不看 trimmability,它卡在 `carriesAttentionMask`。#700 去掉 mask 之后复用立刻落地,就是这次读错的判决性证据。可迁移的规则写进了 `PrefixReuseLedger.swift` 头部:**要钉一个复用的前提,先说清这一轮由哪条规则裁决**;`isTrimmable`/`maxTrimCount` 属于发散(rewind)路,不属于续写路。

**顺带收掉两处账本沉默与重复(P2/P3)**:前缀账此前只有一条路会说话 —— 标准路在 `cached==0` 时打 WARN,而 MTP 路只 `record` 不 `log`,于是热轮次无论省没省都静默。现两条路统一调 `EnginePool.accountPrefixReuse(convKey:modelId:withheldMessages:prefilled:cached:promptSeconds:)`:同一对上游数字同时喂给 per-model ledger(⇒ `GET /v1/models/:model/kv-cache` 的 `prefixReuse`)与一行日志(⇒ 二者不可能对不上一个轮次);判据与措辞收在纯函数 `PrefixReuseStatement.decide`(无 Metal、无模型即可钉)。日志两个方向都给:`notice` = 复用多少,`warning` = 全量重刷。

**探针 01 升级**:①「热轮次」定义改准 —— 只数 `Session pool HIT … withholding them`(= 真的扣了消息),此前松匹配把 `divergence=0` 那次会话复用也算成热轮,却去向引擎要一行它有权不写的账;②断言 C 从「至少说一次」升级成**逐轮对应**:`noReuse + reused == 热轮数`,多一行也红(引擎在叙述没发生过的轮次);③断言 B 改双向:引擎说 0 而线上给了 >0 = 线上替引擎撒谎;引擎报了省而线上没体现 = 日志在吹。默认硬门打开:`OCOREAI_REQUIRE_PREFIX_REUSE` 现默认 1(落地那天的回归门今天生效),不能复用的主机必须显式 `=0` 才算说了话;并要求复用量 ≥ 本轮实付(700 个 token 的会话「复用了 1 个」是能力化妆成 rounding error)。④新增第四轮**改写历史后重发**:`canReusePooledSession` 拒发散会话 ⇒ 全量重建,打印的 `cached_tokens` 就是今天改一次历史的代价 —— 这是 rewind reserve 那条开放项的决定性数字,只测不钉 —— 今天该轮实测 `prompt_tokens=752`、`cached_tokens=0`,即改一次历史 = 全量重刷 752 token。

**全量套件抓到一条假断言(它昨天是绿的)**:`make test-clt` = **2502 tests / 449 suites**,唯一红 = 上一轮(209d789)自带的 `ChatAudioIngestionTests.swift` 「splicing nothing leaves the conversation byte-identical」。现场取证:`sameWire` 拿两个 `JSONEncoder()` 实例各编一次比字节,Foundation 不保证跨实例 key 顺序,同一值两次编成 `{"content":[…],"role":"user"}` 与 `{"role":"user","content":[…]}`(内层 audio part 同病)⇒ 断言的前提是编码器根本没承诺的性质。修 = `outputFormatting = [.sortedKeys]`,并把测量现场写进注释;教训与上面同一条:**门若把前提外包给环境,它就随环境一起烂**。

**分发 notices 也要跟着 bump**(AGENTS.md 的不变量,今天实测补全其触发条件):pin 一改,`ThirdPartyNoticesTests` 的「exact set equality」立刻红 —— `THIRD-PARTY-LICENSES/` 的表把每个依赖的 pin 记在案(`rev 4cc550451253`),重跑 `scripts/collect-third-party-licenses.sh` 后 `NOTICES.md`/`manifest.json` 同步为 `rev 6e338e5df494`(deps=34, texts_missing=none),该套件 11/11 绿。**门**:`PrefixReuseLedgerTests` 8 → 11 条(新增:只有扣了消息的轮次必须说话/静默 4 参参数表 + 两条**精确措辞**断言,并钉住探针 01 依赖的两条 regex —— 措辞一改而探针没跟上,红在这里而不是在 CI 的 grep 里);`ChatAudioIngestionTests` 13/13 绿(`.sortedKeys`)。**活体对照(同机同脚本同模型 `mlx-community/gemma-4-e2b-it-4bit`)**:修复前 `prompt_tokens` 每轮 `[708, 730, 749]`、`cached_tokens` 0/0/0、`prefixReuse.status=no_reuse_observed`、promptTime 107/182 ms;修复后 `[708, 20, 16]`、cached 0/710/733、`status=reuse_observed`、promptTime 83/88 ms。诚实边界:省下的是随历史长度增长那一项(每轮重刷 700+ token),每轮仍有 ~80 ms 固定开销,700 token 量级的绝对收益只有几十毫秒 —— 值钱的是 30k 上下文不再每轮必付 4.4–7.3 s。探针 01 终局 **12 passed / 0 failed / 5 measured**。

**10-16 `/v1/messages` 的一个封闭枚举把整条消息抹平了 — 改成「块全解码 + 能带的带上、带不动的点名拒」,并让安全闸与真正投喂共用同一份渲染** — 第一性问仍是「客户发的那段内容,模型收到没有」。缺陷藏在元素类型上: `AnthropicContentBlock.type` 是 `enum BlockType { case text, toolUse }`,而数组解码是全有全无 ⇒ 只要块里出现任何一个 spec-legal 但枚举没列的类型(`image`/`document`/`tool_result`,或今年之后新发明的任何一种),整个 `content` 数组解码失败,`AnthropicContent` 兜底把**整条消息**变成 `.text("")`。活体实测(新探针 `scripts/probes/07-anthropic-blocks.sh`,本机自启服务):`[{"type":"text",…},{"type":"image",…}]` → HTTP **200**、`usage.input_tokens` **10**(同一句指令以纯字符串发出是 **22**)、答「Please provide the input you would like me to process」。也就是说 `image`、`document`、`tool_result` 三种形状无一幸免,而 `tool_result` 正是 Anthropic 官方 SDK 继续 tool loop 必发的形状 ⇒ 一条 Anthropic 客户的多轮工具链在第二轮就被静默掏空,客户端完全无法把它与「模型就是没话说」区分。对照:`[{type:text}]` 纯文本数组完好(22/22、答 KESTREL),证明断的不是数组分支本身,是元素枚举。

**改法**:`type` 改回原始 `String`(未知类型因此「可表示」而非「具破坏性」,明年 Anthropic 新增块型也不会再掏空一条能用的请求);`tool_result.content`(string｜blocks)与 `image`/`document` 的 `source{type,media_type,data|url}` 一并补上解码;裁决收在一处 `AnthropicMessage.toInternalMessage()` —— **能带**:text 按原序拼接、`image` 走引擎既有的 inline-vision 路(`image_url` + data URL,与 `/v1/chat/completions` 同一形状)、`tool_result`/`tool_use` 渲染成 `[tool_result · id] …` / `[tool_call · name · id] {args}` 标签文本(本路注入 tool 定义本来就是文本,历史调用与结果用同一介质才诚实;把历史塞回可派发的 `toolCalls` 会诱使引擎重跑已完成的调用,测试 `#expect(converted.toolCalls == nil)` 钉住这条边界)、`thinking`/`redacted_thinking` 写 `[prior thinking omitted by this server]`(本服务不支持 extended thinking,不回灌不透明回显,但回合里如实说明,不留给模型和读记录的人猜);**带不动**:`document`/`search_result`/任何不认识的类型 ⇒ `invalid_request` **点名拒绝**,而不是丢进 prompt 后照常作答(与 `AudioTranscription.unsupportedField` 对字段的做法同一条规则);用户消息的数组若解析后什么都读不到 ⇒ 400,而不是拿空提示去生成(assistant 只有 tool_use 无文字仍合法)。

**顺带消掉一份重复(P2)**:块→文本的渲染此前有 **4** 处各写一遍(handler 的安全闸、injection 检测、调度用的 promptText、`buildAnthropicMessageList`,外加 `toChatCompletionRequest` 第 5 处),规则一旦分叉,安全闸审的文本和模型吃的文本就会不一致。现收敛成 `AnthropicContentBlock.promptTextContribution` 唯一渲染 + `AnthropicMessage.plainText`/`toInternalMessage()` 两个出口,`toChatCompletionRequest` 也改走同一映射并随主路一起 `throws`(`make audit` 无新债,`swift-format` 零重排)。

**门**:新 `AnthropicBlockHonestyTests` 14 条(六种块全解码并逐个取证 + text 保序 + image→inline part / `source.url` 透传 / 无 source 点名拒 + tool_result 两形都进 prompt + 空 tool_result 明写 no output + tool_use 渲染为标签且 **不**伪造可派发调用 + thinking 如实标注省略 + document / search_result 点名拒 + 空 user 数组 400 而空 assistant 合法 + plainText 与 prompt 同源 + system 块数组仍摊平 + 两个 mapper 对同一条消息给出同一 prompt + 请求边界也拒),`AnthropicRequestDecodeTests` 4 处调用随签名加 `try`。focused `AnthropicBlockHonesty` **17 tests 绿**(含一组 2 参参数化)。探针 07 自身 9 条 verdict(下限 7),并内置前提下限闸门:基线不可用即中止,不允许在缺失前提下发 PASS(本探针首跑正是被这道闸当场逮住:脚本自己的基线 body 拼坏,7 条里 4 条是假绿 → `FAIL|only 5 verdicts issued (< 6)`)。

**活体(修复后,本机探针自启服务,模型 `mlx-community/gemma-4-e2b-it-4bit`)**:探针 07 = **12 passed / 0 failed / 12 measured**。逐条:纯字符串基线 200 / `input_tokens=22` / 答 `KESTREL`;`[{type:text}]` 22/22 同答 ⇒ 断的从来不是数组分支,是元素枚举(修复前同一族形状是 **10 tok + 「Please provide the input you would like me to process」**);`image` → **200 且答回 KESTREL**(指令确实进了 prompt),同一张 8×8 纯红 PNG 走跨路对照直接 **答出「Red」** ⇒ 探针 04 在 `/v1/chat/completions` 上量到的同一份「能看」,如今在 Anthropic 路上也真通(修复前同一请求答的是「Please provide the input」);`tool_result` → 200、`input_tokens` **22→43**(块的文本进了 prompt);`document` 与假想的未来块 `search_result` → **400 点名拒绝**(`Unsupported Anthropic content block type 'document' — …`),不再掉进 200-盲答。顺带复跑 03(**27 passed / 0 failed / 8 measured**,端点索引 note 改动未破一致性)与 06(**22 / 0 / 16**,上一轮 chat-audio 未受影响)。

**回归**:全量 `make test-clt` **2499 tests / 449 suites / 400.4s** 绿(基线 2482/448 ⇒ 恰 +17 用例 +1 suite = 本轮新 suite)· `swift build` 绿(60.95s)· `make format-check` 零重排 · `make audit` 绿 · `make docs-check` 绿(§ Wire DTOs 的多态规则补上「数组元素类型」这一半,同时把上一轮 chat-audio 那句收紧,root 50672→**50665/50681**,预算反而净缩 7 B)。

**未决(留人拍板)**:拒绝式前向兼容 vs 忽略式前向兼容 —— 现按仓内既有规则(`AudioTranscription.unsupportedField`)对不认识的块 **400 点名**,好处是客户端立刻知道要剥什么、坏处是 Anthropic 未来新增的「本可安全忽略」块型(如 `server_tool_use`/`web_search_tool_result` 这类历史回显)会让老 ocoreai 直接拒单。改成「已知可忽略族 silently ignore + 响应侧披露」需要先给 `/v1/messages` 找一个不违 Anthropic 形状的披露位(现无),故不臆改。

**10-15 `/v1/chat/completions` 收了 audio 却听不见 — 接上「听见即原位转写、听不见即拒」两条诚实路,并顺手对齐两条语音路对同一个失败的 400/503** — 第一性问:「这条路由拿到一段语音,模型到底收到没有」。上游证据(pinned `4cc550451` = `.build-clt` 正在编的那份): `audios` 在 `Libraries/` 只出现在 `Chat.swift`/`UserInput.swift`/`ChatSession.swift`(全是把数组搬来搬去的 plumbing),而 `Libraries/MLXVLMCommon` 里 `audio` 命中 **0** ⇒ 没有任何 `UserInputProcessor` 消费波形,波形在今天的引擎里根本进不了模型。活体前态(本机): 一段 1.5s 话语以 `audio_url` 投进 `/v1/chat/completions` → HTTP **200**、`prompt_tokens` 反而从 743 掉到 705、模型答「Please provide the audio」。收了、答了、把客户唯一的载荷丢了 = 不变量 2 装了个喇叭: 客户端无法把它和成功区分,用户拿到一句从来没人听见的问题的自信回答。

**改法(把第三条路做成不可达)**: 新 `Multimodal/ChatAudioIngestion.swift` — `ChatAudio.modelConsumesAudio == false` 钉死(上游哪天长出 audio `UserInputProcessor`,翻它是次带证据的决定,不是行为漂移),`audioParts`/`spliced`/`report`/`ingest` 四件;解码、容器嗅探、尺寸帽与失败→状态映射复用 `AudioTranscription`,ASR 那一趟连同权限(静默读取、绝不弹窗)、locale、子进程探活门复用 `Hearing` ⇒ 一套词表,专用端点与 chat 路不许对 `speech_denied` 各说各话。**听见** ⇒ audio part 原位换成 `[heard · <locale>] <文本>`(测出静音写 `[heard no speech detected]` 并继续,「听了没听出话」是测量不是故障);转写落回载荷原来占的槽位而不是追加在尾部 ⇒「翻译这句 ⟨audio⟩ 成法语」这类夹写次序保得住。**听不见** ⇒ typed `error_code` + `remediation` 抛出,位置在 safety guard 之前、scheduler 与引擎句柄之前(实测 34–36ms 落地,一次 prefill 都没花);单请求 > 8 个 audio part 整单拒绝,绝不做「听一半、丢一半」。`ChatCompletion.audio_input`(snake_case;请求里没有 audio 时**缺席**而非 null —— 「没 audio」与「audio 已送达」是两件事)披露 `parts/transcribed/engine/locales/characters` ⇒「模型答了你说的话」与「模型答了 OS ASR 听到的字」在响应体里可分辨。流式不发明客户没见过的 SSE 字段,同一事实写进 log metadata;而真正保护客户免于盲答的那一半(拒绝)在两模式同码同体 —— 它发生在产出任何 token 之前。

**顺带钉掉一处 P0 状态不一致**: `AudioTranscription.status(for:)` 明判 `.undecodableAudio` 是客户的 **400**,抛出点手上却只有 `.transcriptionUnavailable`(**503**)⇒ 同一张表的两半互相打脸,而 503 是在教客户去重试一批永远解不开的字节。新增 `AppError.transcriptionRejected`(400,与 503 同带 `error_code`+`remediation`)+ 唯一工厂 `AudioTranscription.appError(for:)`,两条语音路都从它出 ⇒「客户的字节」与「服务状态」这两层语义再不可能各走各的状态码。

**门**: 新 `ChatAudioIngestionTests` 13 条(词表钉 `false` + 抽取保序带消息下标 + 原位替换/多段各自保序 + 静音照实披露 + 零听见即 wire 字节恒等(按编码字节比,不给 `Message` 硬塞 `Equatable`)+ `report` 分计 parts/字数/locale + 远端 URL/坏 base64/超量三种载荷必拒且 400 带码 + 纯文本零改动零披露 + `audio_input` snake_case 与缺席规则)、`AudioTranscriptionTests` 增 1 条(全举 11 个词表项比对 table 与 thrown 状态、`undecodable_audio`→400 带码带 remediation、权限/引擎→503),focused `ChatAudioIngestion|AudioTranscriptionTests|V1EndpointCatalog` **48 tests** 绿;新探针 `scripts/probes/06-chat-audio.sh`(自身 19 条 verdict,下限 16)= **22 passed / 0 failed / 16 measured**,`run.sh` 自动纳入、README 表格已登记。

**活体(本机,探针自启服务,模型 `mlx-community/gemma-4-e2b-it-4bit`)**: 纯文本基线 200 / `prompt_tokens=709` 且响应**没有** `audio_input`;`https://…`、坏 base64、9 个 part 三种载荷 → **400 + `undecodable_audio` + remediation**,34–36ms(在 scheduler 之前,没碰引擎句柄);`say` 合成的 148,408 B AIFF 真话语 → **503 `speech_not_determined`** + 设置面板指引(154ms),流式同码同 0 个 data chunk;`/v1/multimodal/status` 同一轮读到 `hearing.verdict=blocked`、`transcriptionStatus=blocked` —— 一个麦克风,两面旗必须一致;`/v1/capabilities` 索引里 `/v1/chat/completions` 的 note 现写明 `audio_url is heard to text or refused, never dropped`(索引 34 行,自带 ≥30 前提下限)。**未测**: 本机 Speech Recognition = `notDetermined` ⇒ 200 带 `audio_input` 的 delivery 分支活体一次都没跑过,探针如实打印「拒绝是本机预期结果」,本轮任何文案都没有宣称已经把话听成了字;授权之后重跑 06,该分支的两条硬断言(`prompt_tokens` 高于同一轮纯文本 + 回答回显话语)自动生效。

**回归**: `swift build` 绿(92.02s)· focused 48 tests 绿 · 全量 `make test-clt` **2482 tests / 448 suites / 400.0s**(基线 2468/447,恰 +14 用例 +1 suite = 本轮新增的两处) · `make format-check` 零重排 · `make audit` 绿(Class-I notices 35 行)· `make docs-check` 绿(不变量 2 的 corollary 追加 chat `audio_url` 一句,root 50607→50672/50681,预算仍顶格)。

**10-15 AGENTS.md 引用的上游 pin 落后一个 bump — 改对之外再加一道 P8 门** — `Package.swift` pin 的是 `4cc550451`(正在编译的 `.build-clt/checkouts/mlx-swift-lm` 解析出的就是它),而每轮会话最先读到的 AGENTS.md 仍写着「Pinned upstream `mlx-swift-lm` at `7eb77ef`」(round 9 那一刀,`.build` 那份没再解析的旧 scratch 里还留着 7eb77ef,探针 04 已如实报 STALE NOTE)。bump 协议第一步是 `git log <old>..origin/main`,而 `<old>` 就从这句话取 ⇒ 陈旧 pin 不只是读着别扭:它把下一次上游审计瞄准错误的 commit。修法:`7eb77ef`→`4cc5504`(等长替换,净 0 字符,root 预算仍顶格),并在 `scripts/agents-md-contract.sh` 新增 **P8**:从 manifest 正则取 `mlx-swift-lm … revision:`,与 AGENTS.md 那句引用的短 SHA 做前缀互认,不符即红、那句消失也即红。**负例实测**: 把 SHA 改回 `7eb77ef` → `P8 AGENTS.md quotes pin 7eb77ef but Package.swift pins 4cc550451`;改回即绿。

**10-15 `screenStatus: ready` 是授权给的,不是帧给的 — 给屏幕通道补上「出帧」这条轴,并让 status 与刚跑完的抓取腿互相核对** — 第一性问题「这台机器能看屏幕吗」有两个答案:授权答第一个,帧答第二个,而面上此前只带第一个。本机实测第一条真、第二条假:`CGPreflightScreenCaptureAccess()`=authorized、`SCShareableContent` 数得出显示器,`SCScreenshotManager.captureImage` 仍回 `音频/视频捕捉失败，无法开始流播放`(同一进程相机 1102ms 出帧 ⇒ 与 TCC 无关,是 SCStream 在无 GUI 会话里起不了流)。于是同一个进程里 `/v1/multimodal/status` 先答 `screenStatus: ready`,下一次 `capture {"type":"screen"}` 答「No screen frame captured」——不变量 2 的现行现场,也正是「能看」这条产品断言最不该失守的地方(相机/麦克风两条腿各有 device/voice 计数轴,屏幕当时是 `authorized` 一票通过)。

**改法(加轴,不是把 `ready` 改口)**: `MultimodalDeviceFacts` 新增 `screenDelivery`(`notAttempted`/`captured`/`failed` 封闭词表)+ `screenDeliveryError`/`screenDeliveryLatencyMs`(缺席而非 null);`ScreenshotService` 两条真出帧的路径(one-shot 与 SCStream 帧回调)都写进程内 `ScreenDeliveryRecord`(MainActor,只记最近一次:失败不成永久裁决、修好不必重启,但也绝不猜没发生过的尝试);`screenStatus` = 权限 ∧ 出帧 —— denied/restricted→blocked、unsupported→unsupported、authorized∧未试→unknown、authorized∧失败→blocked,并把框架原话写进 `limitations`:授权已经打开时再指设置面板,等于把人领到一个已开着的开关前。**只动「说什么」,不动「做不做」**: `capture` 那条腿仍由 `captureAttempt`(权限)裁决,全仓 `screenStatus` 仅 facts 与 handler 两处消费(grep 核实)⇒ 没有把 unknown 变成拒绝,也没有新增任何拒绝。

**门**: 新 `ScreenDeliveryHonestyTests` + `ScreenDeliveryRecordTests`(2 suites)= 权限×出帧 21 组全举、`ready ⇒ authorized ∧ captured` 属性(自带 `checked == 21` 前提下限,防「扫描停摆即通过」)、四支 limitation 逐字钉原文、wire 缺席规则(失败才发 error,缺席不发 null)、词表钉死,加记录器行为往返(`.serialized`);并改掉 `MultimodalStatusHonestyTests` 里那条恰好就是旧断言的用例(`facts(screen:.authorized).screenStatus == .ready` → 现要求出帧)。探针 04 新增 3b 段:抓取腿跑完再读一次 status —— 出过帧必须 `screenDelivery=captured`,拒过帧则 verdict 须 `blocked` 且带原因,前提下限 18→22。**活体**(本机,探针自启服务): 首读 `screenPermission=authorized` 而 `screenStatus=unknown` + 「`ready` waits for a delivered frame」;拒帧后 `screenStatus=blocked`、`screenDelivery=failed`、原因 `SCScreenshotManager: 音频/视频捕捉失败，无法开始流播放` 随 limitations 上线 → **04-multimodal-honesty: 40 passed / 0 failed / 8 measured(37 verdicts)**。首跑因脚本自身把 delivery 段放在 `doc` 解析之前,只出 15 条 verdict → `FAIL|only 15 verdicts issued (< 22)`:前提下限当场逮住「这次扫描没跑到」,正是这类下限存在的理由。**回归**: `swift build` 绿 · focused `MultimodalStatusHonesty|ScreenDelivery` 26 tests 绿 · 全量 `make test-clt` **2468 tests / 447 suites / 400.0s** 绿 · `make format-check` 零重排 · `make audit` 绿 · `make docs-check` 绿(AGENTS 那条屏幕 open item 就地改写,净 −2 字符,预算仍 50681 上限)。

**10-15 「能听」真正接通 — `POST /v1/audio/transcriptions` 上线,并把「OS 说可以」降级成测量;活体测出 Speech 框架在子进程里 SIGTRAP(rc=133),证明子进程探活不是洁癖而是必需** — 上一轮把「能看/能说」钉成实测,本轮补最后一轴。**缺口先实测**: 10-15 `POST /v1/audio/transcriptions` = 404,能力(`LocalSTT` + `transcribe_audio` 工具)在进程里有、在面上不可达。**判据先钉死**: 本机两个可用性 API 都说可以(`SFSpeechRecognizer(locale:.current).supportsOnDeviceRecognition`=true、`SpeechTranscriber.supportedLocale` 回 zh_CN/en_US),而 `--probe-hearing` 子进程实测 **rc=133(SIGTRAP)**,stdout 只有 `{"stage":"pre-analysis",…,"authorization":0}` —— 权限还是 `notDetermined` 也照样在分析那一趟里被框架带走。结论两条: ①OS 可用性 API 不是证据;②trap 与权限无关,生产路径上唯一挡住它的是 `Hearing.attempt` 的权限门(活体 wire 正确回 503 `speech_not_determined` + 指明设置面板),子进程只是把「万一绕过」从「整个 App 连引擎池一起没」降级成「一次可恢复的拒绝」。**落地**: `Multimodal/HearingReadiness.swift`(三轴测量 + 每进程熔断 + `verdict`/`reason` 纯函数)、`Multimodal/HearingEngineProbe.swift`(re-exec 自己跑一趟:`terminationHandler` + 截止 + exactly-once `ProbeLanding`,与摄像头那条腿 `cdd4cc7` 同形)、`Multimodal/HearingSelfProbe.swift`(子进程侧 `--probe-hearing`,JSON 走 `FileHandle` 不占 stdout 产品面)、`Handlers/AudioTranscriptionHandler.swift`(multipart 与 JSON base64/url 两形、`error_code` 封闭词表 + `remediation`、`/v1/multimodal/status` 新增 `hearing` 块并取代 snapshot 那一行)、`scripts/probes/05-hearing.sh`。

**途中修掉的真缺陷(每条带测量,序=发现序)**: (1) **这批「能听」代码此前从未编译通过** —— 6 处:`Process.kill()` 在 macos14 target 不存在、`DispatchSemaphore.wait` 在 async 上下文不可用(×2)、`Data` 没有 `hasPrefix`/`hasSuffix`、`boundary(from:)` 漏写限定名、两处跨 `@Sendable` 捕获非 Sendable(`[String: Any]` / `some Encodable`)。「已实现」在 `swift build` exit 0 之前一律算空话,这条就是不变量 1 的现场教学。(2) **探活会在测试宿主里 fork 测试运行器**:`isInTestRunner` 的两条枚举信号本机全假(`Bundle.main=/Library/Developer/CommandLineTools/usr/libexec/swift/pm`、无 `XC*` 环境变量),实测 `HearingEngineProbe.run()` 返回 `.ok`(= 真起了子进程)。判据换成白名单:只允许 re-exec 名为 `ocoreai` 的产物(`swift build` 产物名与 `scripts/build-app.sh:74` 的 `CFBundleExecutable` 同名),`candidateExecutable()`(我会 re-exec 谁)与 `selfExecutable()`(准不允许)拆开;枚举检查降为第二道保险 + 操作员 kill switch `OCOREAI_DISABLE_ASR_PROBE`。理由:枚举「哪些宿主不许」的判据,在新宿主出现那天静默失效,而这是实测过的失效。(3) `dataURLMimeType` 用 `index(after: startIndex)` 剥 `data:` 前缀,只跳 1 个字符而不是 5,实测得 `ata:audio/webm`,容器全靠「串里还留着 wav 字样」巧合选对 → 改 `offsetBy: "data:".count`。(4) 容器名与自述不符:`audio/aac` 被折进 `m4a`、`audio/opus` 折进 `ogg`;改成容器优先于 codec(`ogg` 先判、aac 独立)。(5) multipart 的 `name` 只认引号形态而 `filename` 认两种(RFC 2045 允许 token),未加引号的 part 整条被丢 → 两个 key 同规则解析;顺带钉死「未闭合引号不猜」与 `filename=` 不得命中 `name=`。(6) **端点文件头承诺的 `speech_detected: false` 从未发出**:`failureBody` 恒发 nil,于是「静音」这个 200 对「听没听见」保持沉默 —— 恰是本文件存在的理由所要拦的那类过度声明;新增 `TranscriptFailure.detectedSpeech`(noSpeechDetected→false、emptyTranscript→true、其余 nil=根本没听)。(7) `probe: .unavailable`(这台机器测不了)竟判 `.ready`:一条没有证据的轴不该产出能力断言 → 改判 `.unknown`。(8) 子进程 stdout 落进临时文件后**父进程读都不读就删**:现在子进程先写 `stage:pre-analysis`,父进程在终止回调里读回 ≤4 KiB 打进日志(`ocoreai.hearing.probe`),于是 `engineFault` 能说清死在哪一步,而不只是「死了」。(9) `#if os(macOS)` 的 `HearingEngineProbe` 被未门控代码引用(`HearingProbeState.once`、`HearingSelfProbe` 取 flag)⇒ iOS 腿 `build-ios` 编不过(代码层推断,门 = CI job `build-ios`):协议常量(flag / env marker)移到两平台都可见的子进程侧,`once()` 在非 macOS 显式 `.unavailable` 而非 `.notRun`(「测不了」与「还没测」是两句话,`verdict` 对二者裁决不同)。(10) 清死局部变量 `multipartBoundary`(只写不读)。

**门**: `AudioTranscriptionTests` + `HearingHonestyTests` + `HearingProbeState` 共 **56 tests 全绿**(全 `#expect` 精确值;`verdict` 另加 336 组合穷举属性: `ready` 当且仅当 tier ∧ 授权 ∧ `probe==ok` ∧ locale 已测 ∧ 解析出结果;classify 10 行含「截止压过信号、信号压过退出码」优先级;词表自证 floor `TranscriptFailure.allCases.count == 11`、`EngineProbeOutcome` 词表逐位钉;fork-bomb 门以行为断言落地:`!isProductBinary` ∧ `selfExecutable()==nil` ∧ `run()==.unavailable`)。活体 `scripts/probes/05-hearing.sh` = **34 assertions / 0 failed / 8 measured**(premise floor 31,两轮一致):refusal 全部带 `error_code`+`remediation` 且无 500、`transcriptionStatus` 与 `hearing.verdict` 必须一致、`ready` 必须有 `probe: ok` 背书、两种 body 形态同字节同答案、`--help` 不漏内部 flag、子进程 stage 记账复现 trap 签名。全量 `make test-clt` = ****2461 tests / 445 suites 全绿 / 400.3s**(沙箱外,CLT 路线;计数随每轮新增套件浮动)**。

**门的门 — `make audit` 的两处静默失效(同轮实测)**: 收尾跑 `make audit` 红 15 条 Class-B,顺着查出两件比红更糟的事。①**白名单文件从未被读**:`scripts/audit.swift_patterns.sh` 声明 `WHITELIST=scripts/audit_whitelist.txt` 并 `touch` 它,文件头承诺「one excluded path per line … the audit grep will skip via -F match」,而 `check()` 只用第 3 个内联参数 —— 往那个文件加一条豁免,买到的是并不存在的沉默。②**Class-B 名为 view layer 却扫全 `Sources/`**:实测 97 命中、97 条全在白名单、视图层命中 0(`Sources/ocoreai/UI` 46 个 .swift,其中 26 个带 SwiftUI body),即它历史上只能捞 Engine/Video/Multimodal/Capability 里的 `errorDescription` 与领域标签,再逐条被豁免;豁免率 100% 的门抓不到它名字里那件事,白名单已取代了扫描。**改法**:`check()` 现同时读内联参数与白名单文件(路径级豁免连同理由进文件,行形态豁免留在调用点),每类打印 `raw → whitelisted → violation(s)`,让「0 violations」与「15 命中全豁免」不再长同一张脸(不变量 2:面不许说自己比门查到的更强);Class-B 改扫模块边界 `Sources/ocoreai/UI`,并按不变量 1 自证前提 —— 视图层文件数下限 40(现 46),不满足即红,UI 搬家那天不许静默通过;历史 30 条文件级豁免随作用域修正一并撤掉(它们所防御的串按构造已在视图层之外,不再需要豁免)。**负例实测**: 注入 `Sources/ocoreai/UI/__audit_negative_probe.swift` 返回 `"Hardcoded label"` → `❌ 1 violation(s)` 附 file:line;root 改成不存在路径 → `❌ view layer missing`;撤探针 → `✅ Clean (46 view files scanned, 0 hardcoded display returns)`。视图侧文案经 `StringKey.xxx.l`(`String(localized:` 在 `UI/` 下 0 次),这条门保的正是该约定。**溯源**: 其中 4 条 `MultimodalDeviceFacts.privacyPane` 命中随 `cdd4cc7` 早已入库,即 `make audit` 在 `4ff79b3` 上本就红,非本轮引入。

**未决(不静默)**: ①本机 Speech Recognition 权限 `notDetermined` ⇒「说出来→听到」端到端这一腿**在这台机器上验不了**,探针按设计报 NOTE 不报 PASS(`say` 已能产 148,408 字节 AIFF,缺的只有那次授权);要真验需人工在系统设置里授权,留人做。②`response_format: text` 的成功路径、`verbose_json`/timestamps 的真缺,同样要授权后才测得到。③chat 的 `audio_url` 仍不进模型(mlx-swift-lm 无 `UserInputProcessor` 读 `input.audios`,10-15 实测 `prompt_tokens` 反降 38 并回「Please provide the audio」),本端点走 OS ASR→text,不假装喂给了模型。

**10-15 「能看能听能说」第一次有了可复跑的证明:多模态面全改成实测事实,证明过程中抓到摄像头抓取永挂(修好后 1102ms 出帧)** — 第一性原理追问只有一个:用户能读到的每一句「能看/能听/能说」,引擎真的做到了吗?量完发现三处不说真话,以及藏在其后的一个硬 bug。**① status 只发开关,不发事实**:`POST /v1/multimodal/status` 在端点索引里登记为「permission + device status」,载荷里却只有三个 UI 布尔。开关是意图,权限与设备是事实,本机两者常年不一致(实测:相机 `notDetermined`→探针期间用户授权后 `authorized`、麦克风 `authorized`、语音识别 `notDetermined`、录屏 `notGranted`、装机语音 180 个)。新增 `Sources/ocoreai/Multimodal/MultimodalDeviceFacts.swift`:四轴权限一律用**不弹窗**的读法(`AVCaptureDevice.authorizationStatus` / `SFSpeechRecognizer.authorizationStatus()` / `CGPreflightScreenCaptureAccess()`,对齐 `PersonalVoiceTTS.isAuthorized` 既有先例——`requestAccess` 会把模态框拍在用户脸上,状态查询不能这么做);设备/语音数用 `Optional`,**nil 与 0 是两句不同的话**(「这里数不出来」≠「数了没有」,沿用 `ModelObject` 省略约定);每通道给 `ready|blocked|unknown|unsupported` 裁决 + `limitations` 逐条说原因,词表由 `DevicePermission.vocabulary`(7)/`ChannelReadiness.vocabulary`(4) 封闭,单测与探针共用同一张表。`makeMultimodalStatusResponse(toggles:facts:)` 是纯接缝,硬件不参与断言。**② capture 的 `success` 与字节脱钩**:麦克风两阶段那一腿历史上回 `success:true` + `dataURL:null`——信了 `success` 的客户端写出一个空样本还不自知。改法按构造封死:新增 `CaptureResponse.init(dataType:dataURL:message:)`,`success` 由 `dataURL != nil` 推导,六条抓取腿全走它。**③ 抓取路径会弹窗并把请求停死**:探针第一次跑就撞出来——`{"type":"camera"}` 卡满 45s 不返回。表层原因是 `startCapture()` 走 `requestAccess`(相机权限未定时弹模态框,socket 那头的客户端永远答不了):新增 `captureAttempt(channel:permission:)`,wire 侧按实测权限决定要不要碰硬件,不碰就把改法说清(系统设置或 App 内开关;GUI 那条路保留弹窗——用户拨开关本身就是「来问我」)。**④ 真缺陷:摄像头抓取永不着陆**。授权之后同一条腿仍卡 ≥45s。根因:`capturePhotoFromSession()` 把 AVFoundation 回调包进无期限 `withCheckedContinuation`,而 delegate 是**内联临时对象**——`AVCapturePhotoOutput.h:58-67` 只写「An object conforming to the AVCapturePhotoCaptureDelegate protocol… May not be nil」,通篇不提接收方持有 delegate,调用方才拥有这段生命周期。回调没人接 ⇒ continuation 永不 resume ⇒ 请求永久悬挂(顺带:2s 后台采样循环一起停摆,`latestFrameDataURL` 从此不再更新)。**改法**:`pendingFrameDelegates` 持有 delegate 直到落地 + `fire()` 在锁下 exactly-once + 8s deadline 谁先到谁定;另加「同一时刻只允许一次抓取」防积压。**实测**:同一探针同一条腿,修复前 ≥45s 无响应,修复后 **20,423 字符 JPEG / 1102ms**,三轮运行稳定。**⑤ 失败必须自带原因**:`os.log` 落在 unified log,HTTP 客户端和探针都读不到,所以把原因搬上 wire——`CaptureService.lastFrameError`(未开/限流/无 photo output/在途/超时,五种各一句)、`ScreenshotService.lastError`(直接用 SCK 错误原文,本机实测回 `SCScreenshotManager: 音频/视频捕捉失败，无法开始流播放`)。服务侧观察 > OS 事实 > 兜底文案。**⑥ TTS 诚实**:`AudioIO.speak` 空文本静默 return,端点却回 `success:true`;现空/纯空白直接拒,`speechVoiceCount == 0` 也拒(层级支持 ≠ 这台机器能说话),探针另加 NOTE 明说「发声无法在无头环境验证,所以这里不宣称听到」。**⑦ 两条能力位注记在说谎**:`screenshot_capture` 写「via AppKit」,实为 ScreenCaptureKit `SCStream`;`tts_speech` 把层级支持与设备事实混在一句里,现指向 status 端点。**⑧ 成本**:设备枚举 + 语音清单实测 ~284ms,不该出现在每次抓取之前,故拆 `permissionsOnly()`(零枚举)与 `gather()`。**新增 `scripts/probes/04-multimodal-honesty.sh`**(36 assertions / 0 failed / 7 measured,三轮一致):status <10s(证明它读权限而不是问权限)、两张词表逐字段、`ready` 必须有证据、计数缺失必须是省略而非 null、任何抓取腿不得 `success:true`+空 dataURL、每条腿 15s 天花板、空文本必须拒、端点索引 note 必须说清载荷,以及唯一无法静态得出的那条——内联 base64 PNG(自制 8×8 纯红)走 `/v1/chat/completions`,`mlx-community/gemma-4-e2b-it-4bit` **5524ms 答出「Red」**。**新单测** `MultimodalStatusHonestyTests` 19 tests / 41 cases:裁决表 10 行、两套 NS_ENUM 映射(Speech 的 denied=1 而 TCC 的 denied=2,不靠猜)、抓取门决策表 9 行、未测即不宣称、以及一条**自检式扫描**(status/capture 源码禁用三个弹窗 API,并用同目录 `AudioIO.swift` 确有 `requestAccess` 钉住扫描器仍能匹配;首版扫描把「陈述这条规则的文档注释」也判红,已按仓库既有约定改为剥注释)。**顺带**:AGENTS.md 一条悬空引用(`§ Open → 活体探针`,该项已解决)修掉;四条 live 缺陷明细表从 root 移入 `docs/agent/build-gate-reality.md`(为 byte 预算让路,不是删信息)。**未决**:录屏在无 GUI 会话里起不了流(权限已给、有显示器),`screenStatus` 现按权限判 `ready`——说的是「已授权」,不是「这一轮会成功」;两条语义是否分开,留人拍板。**门禁**:`swift build`(CLT)绿;`swift test --filter "MultimodalStatusHonesty|MultimodalState"` → **24 tests / 3 suites 全绿**;`make probes` 四支全绿(01/02/03/04);`make format-check` 0 重排;`make docs-check` 绿(root **50,647/50,686**,新增两条规则的同时靠压缩叙述净减)。

**10-14(深夜) 把 P1 从「只有日志知道」搬到「客户端读得到」:新增 `prefixReuse`,并抓到 kv-cache 第二个 id 缺陷** — 承上前一轮钉死的根因(该模型缓存不可 trim ⇒ 上游只能 `.rebuild`)。第一性原理追问:既然引擎每一轮都知道复用有没有发生,为什么客户端只能从几百个响应里猜?**① 新增 `GET /v1/models/:model/kv-cache` → `prefixReuse`**(`Sources/ocoreai/Engine/PrefixReuseLedger.swift` 新文件 + `EnginePool.prefixReuse`):三态 `not_observed`/`no_reuse_observed`/`reuse_observed`,配 `warmTurns`/`turnsWithReuse`/`lastPrefilled`/`lastCached`/`lastPromptMs`。三条设计约束:状态**只由计数器推导**(wire 不可能宣称一个计数器不支持的能力);**冷轮不算证据**(只有 pool 扣了消息的热轮才计入,否则第一轮就把好端端的缓存判成坏);**没观测过就说 `not_observed`,绝不猜 `supported`**。数据只取上游 `GenerateCompletionInfo.cachedPromptTokenCount`,标准路径与 MTP 路径各记一次;`unloadModel` 调 `prefixReuse.forget`——换过一次拓扑/量化的旧观测不再冒充新模型。**刻意不做**:不在本地按缓存 kind 反推 trimmability,那是手写第二套能力真值,正是本仓反复点名的反模式。**② 又抓一个真缺陷:`/v1/models/:model/kv-cache` 的 id 两种形态都解析不了**——verbatim 被 router 挡(:model 只吃一段),`%2F` 则因该路由漏了 router 里已有的统一 choke(`resolvedSamplingModelId`,10-06 为 DELETE 幽灵键建的)而把编码串原样交给 pool,实测 `Model mlx-community%2Fgemma-4-e2b-it-4bit not found`。修法零新逻辑:helper 更名 `resolvedPathModelId`(它的职责从来是「解析路径里的模型 id」,不只是 sampling),kv-cache 改走同一个 choke。**③ 探针跟着长**:`01-prefix-accounting.sh` 新增「surface 必须说引擎实测过的事」——取 `prefixReuse` 并与本轮亲眼所见对照(全轮 `cached=0` 却报 `reuse_observed` 即红;status 与自身计数器矛盾即红),并加前提地板(热轮计数 < 2 即红,防 `not_observed` 靠没记录而空过);`03-capabilities-models-consistency.sh` 把 `:model` 检查从单路由扩到 `sampling`+`kv-cache` 全家,并学会分辨两种 404:`route_not_found` 信封=没注册,handler 内抛的 404=路由通而引擎回绝(如 kv-cache 需先装载模型)——顺带修掉一处自己造成的假红。**验证(同会话输出)**:`swift build`(CLT)→ `Build complete! (76.37秒)`;`swift test --filter "PrefixReuseLedger|V1EndpointCatalog|KVCache"` → **18 tests / 3 suites 全绿**(新套件 8 条含状态表参数化、冷轮不算证据、复用恰好一次、模型互不污染、forget、wire 省略未测字段——该条首版断言 `lastPrefilled:null` 被自己的测试打回,事实是可选字段整体省略,已按仓库既有约定改正);`make probes` → `01: 10 passed/0 failed`、`02: 15 passed/0 failed`、`03: 27 passed/0 failed`,线上实测 `prefixReuse status=no_reuse_observed warmTurns=2 turnsWithReuse=0`,与同轮 730/749 tok 全量 prefill 一致。**回归门**:`PrefixReuseLedgerTests` 钉状态机与 wire;`make probes` 钉「surface 说的 = 引擎做的」与 `:model` 全家可达性;`make docs-check`(root **50,570 B**,较本轮起点再降 81)。

**10-14(晚) 探针第一次跑绿,顺手把 P1 的根因钉死** — 承接同日上午「探针入库、零次绿色运行」。unsandboxed `make probes` 首次全跑,一遍抓到六件事。**① P1 根因(此前两条候选双双排除)**:在依赖 checkout 内临时插桩直读上游裁决(测后 `git checkout --` 还原),命中轮打印 `cache=.kvcache ledger=710 planMatch=true hasTranscript=true transcriptBuilt=true processed=710`,紧接 `decide=rebuild prompt=730 cached=710 commonPrefix=710 trimmable=false`——公共前缀 710/730 完好、plan 与 transcript 俱在,上游仍判 `.rebuild`。原因在 `PromptCacheReusePolicy.swift` 的 `canRewind` 合取式要求 `cache.isTrimmable`,而 `BaseKVCache.isTrimmable=false`(`KVCache.swift:239`;只有 `KVCacheSimple`/`QuantizedKVCache`/部分 `RotatingKVCache` 覆写 true)。⇒ 此前 § Open 列的两条候选都不成立:`ChatSession.swift:1052` 的 plan/kind 重建一次未触发(`REBUILD@c1052` 零打印),`:1212` 给的也不是 `.prefillAll` 而是 `.rebuild`。同轮 `promptTime=127–131ms` = 5,718–5,748 tok/s ⇒ 30k 上下文 ≈ **5.2s/轮**,AGENTS.md 旧记「3–4s」偏乐观,已按实测改。**可做**(未动):`/v1/models/:model/kv-cache` 如实公布该模型缓存能否 rewind,或多轮会话改选可 trim 的缓存类型(旋转窗有取舍);该模型下喂全量与喂后缀无差别 ⇒ 不改喂法。**② 真缺陷 · 参数化路由不收原样模型 id**:`/v1/models` 发布 `org/name`(两段路径),`:model` 只匹配一段 ⇒ 实测 verbatim 404、`org%2Fname` 200、裸 `name` 404。已在 `V1EndpointCatalog` 四条 `:model` note 写明须 percent-encode,并让探针 03 钉住(verbatim 仍 404 且 note 丢了 encoding ⇒ 红)。**③ 依赖 checkout 被留下的 21 行未提交调试**(`.build-clt/checkouts/mlx-swift-lm/…/ChatSession.swift`)——git 看不见、CI 看不见(GitHub 按 pin 解析),AGENTS.md「clone HEAD==pin==checkout 逐字节相同」当场为假(clone `c53d7d4`=pin+1 #696;`.build/` 还停在上一 pin `7eb77ef`)。已还原干净,并把「被测二进制所出自的 checkout 必须干净且就在 pin 上」做成 `_lib.sh` 开机前提(其余 scratch 目录的滞留报成 NOTE)。**④ `Package.swift` 指向已删除的文档**(注释写 `docs/agent/upstream-audit-log.md`,该文件同日写下又删掉)——改回 AGENTS.md + CHANGELOG,并注明「一本日记只住一个地方」。**⑤ 探针自身四处缺陷**(第一轮全红的真因):`set -u` 下一行 `PAD="$probe_pad_text"` 引用了不存在的变量;`python3 - args <<PY` 把程序本身喂进 stdin,再 `sys.stdin.read()` 只能拿到空串(改走 argv);`IFS=$'\t' read` 会吞掉空字段,导致 `vlm` 缺失时整行列位左移、把 contextLength 当成 vlm 判过;以及两个 wire 误判——`/v1/capabilities` 用 camelCase `tokenizerBackend`(逐对象约定,与 `/v1/count-tokens` 的 `tokenizer_backend` 不同),而本 server 的 JSON 把 `/` 转义成 `\/`,裸 grep 永远搜不到 `/v1/capabilities`(改走 JSON 解码读 `error.message`)。**⑥ 断言校准**:`vlm`/`contextLength` 缺失是 `ModelObject` 明写的诚实形状(unknown ≠ 0/false),据此从 FAIL 降为 NOTE;count-tokens 的「同文不同形状」比较从 ±20% 容差改成**要求完全相等**(bare 五形状同报 17、+system 三形状同报 512;`input:[String]` 因其本就多带文本而排除),并新增「system 块必须计进 prompt」的断言。**验证(同会话输出)**:`swift build`(CLT 路线)→ `Build complete! (93.41秒)`;`make probes` → `01-prefix-accounting: 8 passed / 0 failed`、`02-count-tokens-shapes: 15 passed / 0 failed`、`03-capabilities-models-consistency: 22 passed / 0 failed`(P1 三次复测 cached=0、730/749 tok 全量 prefill;`.build` 滞留 7eb77ef 以 NOTE 报出);`make docs-check` ✅(root **50,651 B** ≤ cap、claims 12/12、gateable-refs 54、suites 14、routing 5);依赖 checkout `git status --porcelain` = 0。**回归门**:探针 01 的 wire↔引擎一致性(声称 `cached>0` 而引擎说 0 即红)+ dedupe 前提地板(零 HIT 即红)+ `_lib.sh` 的 clean-at-pin 前提;探针 03 的 index 地板(≥20)、逐条 GET 解析与 `%2F` note 断言;`make docs-check` P2(文档点名的探针文件被删即红)。

**10-14 把活体探针钉进仓库(`scripts/probes/` · `make probes`)——文档从此指向脚本名,而不是故事** — 承接同日 § Open 第一条:本仓此前当作证据引用的活体脚本(`live24.py`·port 8124·同会话 3 轮;count-tokens 三查·port 8157)既不在 `git ls-files` 也不在磁盘 ⇒ 谁也无法复跑,结论随临时目录一起蒸发。学 mlx-serve 把探针写成 `tests/test_*.sh` 的做法,落成 `scripts/probes/`:`_lib.sh`(自举**专属** server:OS 分配空端口,不蹭别人开着的 GUI;stdin 必须 `/dev/null`——`HeadlessServer` 的 stdin-EOF 停机看门狗会把后台脚本自己杀掉;`/health` 轮询超时判红并打印 remedy,绝不静默跳过;JSON 取值不带 traceback;收尾 TERM→KILL)、`01-prefix-accounting.sh`(P1 的仪器:同会话三轮,断言 ① dedupe 路径确实被走到 ② wire 上 `usage.prompt_tokens_details.cached_tokens` 不得超出引擎日志所述——wire 说谎即红 ③ HIT 轮零复用必须有 `def1964` 那条 WARN;并打印每轮 prefilled/cached/promptTime 与 30k 外推;`OCOREAI_REQUIRE_PREFIX_REUSE=1` 把测量升级成硬门,留给 P1 修好那天当回归门)、`02-count-tokens-shapes.sh`(`prompt` / `input` 的 string·[String]·[{role,content}] / `messages` / `system` 字符串与 block 共 7 形状,加 Anthropic `/v1/messages/count_tokens` 两形状,加空体负例:必须 4xx 且点名可接受形状,200 与 500 皆红;再加覆盖地板——可用形状 < 7 判红)、`03-capabilities-models-consistency.sh`(endpoint 索引地板 ≥ 20;索引里每条 GET 真打一次,404 即「索引与运行中 router 不符」;`/v1/models` 报 ready 的模型必须接受 `/v1/count-tokens`;每个 model 行必须显式给 `vlm`/`contextLength`,每条 capability 行必须给 `available` + 理由;404 信封仍指向 `/v1/capabilities`,且本轮已验证那条路真的通)、`run.sh`(串跑、支持前缀过滤、零匹配判红)、`README.md`(运行条件、逐支脚本「何时判红」、旋钮表、加探针的六条规矩)。**为什么单测替代不了它们**:`V1EndpointCatalogTests` 钉的是编译期注册表;只有跑起来的 server 能暴露「注册了却 404」(中间件、顺序、handler 抛错)。**验证(同会话输出)**:`bash -n` 五支脚本全过;`make docs-check` ✅(root **50,678 B** ≤ cap 50,686、gateable-refs **58**、claims 12/12、suites 14、routing 5);`make -n probes` 解析到 `bash scripts/probes/run.sh`。**诚实边界(关键)**:三支探针本会话**一次都没跑绿过**——agent 沙箱内 MLX `No Metal device available`,server 起不到 ready,而探针按设计对这种情形判红而非跳过 ⇒「仪器有效」目前是推断不是实测,故 § Open 那条改写为「探针已入库,零次绿色运行」而非删除;关闭条件(unsandboxed `make probes` 三项全绿)就写在那条 item 里。**回归门**:`make docs-check` P2 ——文档现已点名 `scripts/probes/run.sh` 等路径,文件被删即红;探针自带的 P1 式地板(零断言即红、形状 < 7 即红、索引 < 20 即红、零 GET 探到即红)保证它们不会空过。


**10-14 学以致用：把 `AGENTS.md` 从「日志」改回「合同」，并给它装上会红的门（`make docs-check`）** — 参照 `~/references` 的四份 AGENTS.md（hermes-agent：根 11,952 B + 13 份分区向导 + `python scripts/check` 硬性预算；mlx-serve：「不是日记」成长政策与「把探针钉进仓库」；mlx-swift-lm：注释标准 Good/Bad 例；codex `sandbox_integrity`：deliberate approximation 的评审边界），落成三件事。
① **新门 `scripts/agents-md-contract.sh`（`make docs-check` / `make docs-budget`；CI `audit` job 新 step + 进 `ci-local`）**：B1 根文件预算（shrink-only 棘轮）、B2 根+向导链预算、P1 扫描自身下限（正则失配必须红，不许空过）、P2 文档点名的每个路径必须存在（本仓 / git basename / 本地上游 clone / 同行声明缺失 四者之一）、P3 `file:line` 锚点落在行内、P4 `<!-- claim:id OP N :: cmd -->` 逐条真跑（方向语义：`>=` 守不得缩小的下限、`<=` 守不得长高的卫生上限、`=` 只留给「改这份文档才会变」的事实）、P5/P6 `make` 目标与测试套件真实、P7 分区向导必须有路由行。**反向自测**：临时加一段死路径 + 假断言 + 超预算文本 → B1/P2/P4 三线同红，还原后绿（`cmp` 验字节一致）。
② **注入层瘦身 64,591 B → 50,694 B（−21.5%）**：日期化取证按原文迁到 `docs/agent/build-gate-reality.md`、`docs/agent/third-party-notices.md`、`docs/agent/closed-items-log.md`，根文件只留结论 + 指针 + 断言；新增 § Two invariants（① 一条断言的价值 = 它坏掉时能让哪道门红；② 界面不得超出引擎实测）、§ Rules that apply everywhere（11 条，逐条注明在此仓库为何吃重）、§ Read on demand、§ Routing table、§ Docs Contract、§ Taste test；新分区向导 `Sources/ocoreai/Engine/AGENTS.md` 与 `Sources/ocoreai/UI/AGENTS.md`（分区规则只在进入该区时进上下文，这正是根文件得以变短的机制）。
③ **门禁第一轮即抓到三条「已核」数字过期**：`Engine/*.swift` 44→53（改为不钉清单数、以文件系统为准）；`precondition` 「12 sites / 9 files」→ 实测 **14 sites / 11 files**（漏了 `CompositeSampler`、`CoreAISequentialVLMEngine`）；`print()` 号称 0 而实存 **2**（`Sources/ocoreai/UI/Application.swift:31` = CLI `--version`/`--help` 输出、`Sources/ocoreai/Headless/HeadlessServer.swift:141` = headless banner；旧命令 `git grep 'print('` 还把 `fingerprint(` 数进去）。前两条已改真并钉上限；`print` 暂记 `<=2`，是否改走 logger 留使用者拍板。**另抓到文档地图 4 行指向仓库里从未存在的文件**（`docs/precise-tasks.md`、`docs/prompt-ocoreai.md`、`docs/plans/*`；`git log --all -- docs/` 只有 `11dd586` 一条，且它删的是 `docs/CONTEXT.md`）与一个不在本机的 `~/wiki` vault ⇒ 全部改为删除线 + 事实注记，`~/wiki` 明确降级为「主机本地、CI 不可验证」（warn 而非 fail）。**自我纠正一条**：本次先将上游逐轮裁决搬成 `docs/agent/upstream-audit-log.md`，随即发现 `CHANGELOG.md` 早已承载 round 9–12 逐条裁决 ⇒ 重复面即异味，删该文件、指针改回 `CHANGELOG.md`（一本日记只住一个地方）。**访问/漂移快照（原文迁出前实测，存此以免丢失）**：Apple DocC `coreai.json` HTTP 200 / 19,684 B；HIG 页 HTTP 200 且四条 `/tutorials/data/documentation/design/human-interface-guidelines*.json` 全 404；`api.github.com` 可达；`mlx-swift-lm` HEAD `4cc550451253` == `Package.swift:41` pin ⇒ 0 drift；`coreai-models` HEAD `bd61eb182a02` == 基线 ⇒ 0 drift；`codex` HEAD `20b4ff2f35f2` = 基线 `efa159f7aa` +8 ⇒ 8/8 consumer-transparent；本地镜像落后基线（`references/coreai-models` `be11f01`、`references/codex` `b043762f9e`）——mirror 只证内容不证 HEAD，但 `LICENSE` 两处同 SHA（`90ff40ae9088…`, 1,455 B）仍可用于 BSD-3 逐字节比对。
**验证（同会话输出）**：`make docs-check` ✅（claims 12/12、gateable-refs 53 ≥ floor 50、suites 14、routing 5 ≥ floor 4；`make docs-budget` 把 cap 由 64,591 钉到 50,694 B）；反向自测三红后还原并复绿；逐项 `git grep` 复现：Apple 派生 **44**、`coreai-models` 提及 **58**（其中 29 记名 / 15 未记名）、`Sources/lib` 头文件 **2**（`dlpack.h` = dmlc/dlpack Apache-2.0，`xgrammar_c_bridge.h` = Apple BSD-3）、`THIRD-PARTY-LICENSES` **38** 文件、`MPSGraphSamplers.swift` **1511** 行、`Engine/CoreAI*` **×14**、路由注册 **33** 行、`TODO` **1**。**回归门**：`make docs-check`（CI `audit` + `ci-local`）——文档数字过期、路径失效、预算变大、向导失路由，任一发生即红。

**10-14 token-count 面补齐(三形状 + Anthropic 预检 + 端点索引)，并把它做成会红的门** — 昨日尾注记的那条「`/v1/count-tokens` 与 `/v1/messages/count_tokens` 的字段形状缺陷仍在」本轮动手，动因仍是第一性三问里最贵的一问(哪个门会红)。**改善了什么(行为面)**: ① `POST /v1/count-tokens` 不再只认 `{model,prompt}` —— `CountTokensRequest` 改手解，收 `prompt`(原有契约，逐字节不变) / `input`(OpenAI: string｜`[String]`｜`[{role,content}]`) / `messages`(+`system`，字符串与 text-block 两形皆可，Anthropic SDK 带 `cache_control` 时发后者)，多键同体时 `messages`→`input`→`prompt` 取最具体者，无文本可数时 400 直接点名可收字段而非「Prompt must not be empty」; ② 新增 `POST /v1/messages/count_tokens` → `{input_tokens}`，且计数复用 `buildAnthropicMessageList`(`private`→`internal` 并删去未用 handle 形参) —— 预算预检与实际投喂同一个 builder，system 与 tool 定义必被计入，杜绝「预检比请求便宜」的假安全; ③ `GET /v1/capabilities` 起 `endpoints:[{method,path,auth,note}]`(34 条)，`auth` 由 `AuthRoutePolicy`(新: 把 `AuthMiddleware` 的 publicPaths/adminMethods 从泛型实例属性移出成非泛型枚举)推导而非手抄 ⇒ 404 信封里那句「endpoints via GET /v1/capabilities」第一次有东西接着; ④ 两个计数端点都带 `tokenizer_backend: real|heuristic`，且 tokenizer 缺失不再顶着 `modelNotFound` 把 `/v1/models` 声称 ready 模型 404 掉(`EnginePool.tokenize` 的 tokenizer-miss 穿着 model 错误)，改回 heuristic 并当场标注 ⇒ 计数永远是诚实标注的数，估算不再冒充 token 精确值; ⑤ 多轮 `messages` 走 chat template 全量计数 —— 每轮控制 token 不再因「压成单个 user turn」而少算。**凭什么认为改善(同会话输出)**: `swift build`(CLT + `SDKROOT=MacOSX26.5.sdk`，绕开 SDK27 的 CoreAI 变轨) **Build complete! 13.72s**; 三个测试文件 `swiftc -parse` 语法绿。**顺带记**: 计数改走消息列表后 `EngineHandle.countTokens(text:)` 零调用者(把它删掉的补丁已写好又回退 —— 本会话 `swift build` 面随后被 Metal module-cache 沙箱墙卡住，未编译的代码不进树)；清理随首次能编译的 run 一并落，理由是这条 text 形状 helper 把整段对话压成单个 user turn，天生少算每轮控制 token，留着就是下一个 bug 的模板。**诚实缺口(未核)**: 本会话沙箱内 `swift build --build-tests` 撞 clang 写权限墙(`CNIOBoringSSL-t`: `unable to make temporary file: Operation not permitted`; metal 编译: `~/.cache/clang/ModuleCache/*.pcm Operation not permitted`)，而 `make test-clt` 的升级审批又因自动评审后端 404(`codex-auto-review` model not found)未能放行 ⇒ **全量门与活体 `serve`+`curl` 本会话没跑，本条不含任何已验证行为断言**。**如何防退化(门禁)**: `CountTokensWireShapeTests`(13 条: 三形状 + `[String]`/消息数组 `input` + string/block 两形 system + multipart content + 优先级 + 无可数内容 + `model` 必填 + 两端点 wire 键 `prompt_tokens`/`input_tokens`/`tokenizer_backend`) + `V1EndpointCatalogTests`(6 条: 扫源码比对路由，含「扫描自身命中数 ≥30」floor —— 正则失效不许把等式混成绿灯 —— 以及 auth 列抽样与 public 面全覆盖、payload 仍接 `V1EndpointCatalog.lines`) + `AnthropicRequestDecodeTests` 新增 3 条(system 两形/缺失 + builder 含 system 与 tool)。下一轮第一步 = `make test-clt` 令上述 22 条真绿，再补活体三查(`messages` 体 200 / `count_tokens` 200 且 `input_tokens>0` / `capabilities.endpoints` 行数 == 注册路由数)。


**10-14 历史审计:重复故障的公分母是「不自检的门」+ 工具链契约落地(三问标准入 CONTRIBUTING/AGENTS)** — 从 `git log` 与代码差异重建因果(不按提交说明取信),重复出现的不是同一类 bug,而是同一个元问题:**断言早于证据**。四个已证实家族:① *谎报面*(wire/log/capability 宣称运行时不做的能力:5 个 tool 假 schema、`tok/s` 实为 req/s、`vlm:false`、interrupted 气泡、`freed pointer` 崩溃前的 prewarm 宣称…);② *归因错*(8.36s→0.25s 读成前缀复用 —— 10-14 已否证,落差是装载/预热);③ *门跑不动却以为在跑*(swift-format 本地不可执行 → 样式债进 CI;metallib 靠 Xcode 遗留产物 → 发布腿险些裸奔;drift cron 无网成 no-op;`xcodebuild` 本地报 workspace 错误);④ *规则只写进文档*(`stream` 必填缺陷修了并立规,同族的强制键在 `/v1/count-tokens` 上仍把规范合法的 `messages`/`input` 请求 400 掉)。**本轮选中的瓶颈有当日可复现证据,是第③族的最新实例**:06:45–06:46 一次 Xcode/CLT 更新把 CLT 默认 SDK 由 26.5 改指 **27.0**(实测 `MacOSX27.0.sdk` 含 `CoreAI.framework`、`MacOSX26.5.sdk` 不含)、swiftc 6.3.3→6.4、Metal 组件缺失 ⇒ `make test-clt` 名义上的「macOS 26 / no-CoreAI」路线静默变轨(`canImport(CoreAI)` 翻真,macOS 27-only 块编进交付形状),且 `swift build` 因缺 shader 编译器整体不可执行(错误只说 `unable to spawn process 'metal'`,不指名根因)。**改善了什么**:验证门不再靠环境推断 —— 新增 `scripts/toolchain-contract.sh` + `make toolchain-check`,R1「交付 SDK 不含 CoreAI」为硬门(并入 CI `audit` job,runner 镜像升级当场红),R2「shader 编译器可用」为建议项(`--require-metal` 升硬);`make test-clt` 的两条 swift 调用与 `audit-facts.sh` 显式携带 `SDKROOT=<最新无 CoreAI 的 SDK>`。**凭什么认为改善(同会话输出)**:本机 `make toolchain-check` exit 1 并给出两条精确 remedy;传 `SDKROOT` 确实改变编译形状(失败命令行的 `-isysroot` 由 `MacOSX27.0.sdk` 回到 `MacOSX26.5.sdk`);负向对照(伪造 SDK 26 无 CoreAI + `metal` shim)exit 0 ⇒ 该门不是恒红;`OCOREAI_TARGET_SDK=macos27` 显式 opt-in exit 0;`bash scripts/audit-facts.sh` 现打印 `sdk_default_coreai` / `sdk_no_coreai` / `metal` 事实行。**如何防退化**:CI `audit` job 新增 `Toolchain contract` 步骤(秒级、无构建)+ `make toolchain-check` 可显式调用 + fact sheet 事实行。**同时清理**:一次性探针 `TempWireSweepTests` 在沙箱内会以 `MLX … No Metal device available` 中止整个测试进程(实测),加 `MTLCreateSystemDefaultDevice()` 自跳过,不再污染本地过滤运行。**未了/未知**:本机重编 `.metal` 仍需 `xcodebuild -downloadComponent MetalToolchain`(要联网授权);P1 每轮全量 prefill 归因仍未钉死 —— 候选已按上游 `PromptCacheReusePolicy`(pin `4cc5504`)收窄到四个入口(`carriesAttentionMask`、`plan`/layer-kind 变更致 `cachedTokens.removeAll()`、账本与冷渲染分歧致 `starts(with:)` 失败、`isTrimmable` 为假),区分需在依赖 checkout 内打印 `decision`(`internal` 不可注入),或按 P1 结论改为喂全量、把复用交还上游自管;`/v1/count-tokens` 与 `/v1/messages/count_tokens` 的字段形状缺陷仍在(下轮连活体环一起做)。

**10-14 联网后第一次真漂移自检 + 两条假前提退休（`Apple 文档要登录`、`本机无网`）(round 11 裁决：coreai +2 / codex +25 全透明)** — 承接 `a80629c`。**① 假前提两条**：`developer.apple.com/documentation/coreai` 实测 HTTP 200 无重定向，且 DocC JSON 可机读（`/tutorials/data/documentation/coreai.json` = 19,684 bytes，title `Core AI`，abstract "Run AI models in your app on Apple silicon."，topicSections = Essentials / Inference / Multidimensional arrays / Configuration / Debugging and performance / Errors）⇒ AGENTS.md 里那句「requires login」是无人复核的转述，白扔了一手资料；同一天另一条也被推翻：`本机无 DNS` 在 AGENTS.md 出现两处，实际 DNS 正常、`api.github.com` 亦回 200 —— 真正的拦阻是 **agent 沙箱**，与 10-12 那条「全量门跑不动是沙箱不是平台」同型；沙箱内的 mirror 通道仍必要，但联网动作（`git push` / `gh api` / drift 的 api 通道）该在沙箱外跑。**② round 11 裁决**：`scripts/upstream-drift.sh check` 首次经 api 通道跑通（`resolved_via=api` ×3）。`mlx-swift-lm` api HEAD == pin `4cc5504` ⇒ 0 新；`coreai-models` `be11f01..bd61eb1` = +2（`#347` PR 模板、`#348` CODEOWNERS）全是 `.github/` 元数据 ⇒ 透明；`codex` `b043762f9e..efa159f7aa` = 25 commit，逐轴双根 grep 判 **25/25 consumer-transparent、0 强制缺口**（零消费计数：`guardian`/`exec.?server|app.?server`/`background.?turn`/`replay.?cache`/`daybreak|cyber` 均 0；`subagent*`=3 是既有未实现钩子名枚举；TUI/Rex 轴 SwiftUI 无消费）。唯一同轴候选 `#53670`「Account for token usage from incomplete responses」实读其 diff 后判「原则已在本地」：ocoreai 取消路 `.done(cancelled)` 传真实 `tokenCount`，prompt/cached 未知即省略（`OpenAIModels.swift:918` `cachedPromptTokens.map`），硬编码 `reasoningTokenCount: 0` 仅限本路不分离 reasoning 的两处 ⇒ 与上游原则一致，0 生产面变更。**③ 基线纪律**：codex 基线只钉到最后逐条读过的 `efa159f7aa`，不跟 adopt 当时已前进的 api HEAD `4d82d36cc`；钉到未读点会把尾段伪装成已裁决（本仓反复警告的时龄失真），复跑 `check` 现如实报 `+1 commits vs base=efa159f7a`。**验证**：`bash scripts/upstream-drift.sh check` 两跑（裁决前 `+2 / +25`，基线纠正后 `codex +1` 如实顶出）；本轮为纯文档与基线状态变更，未动 Swift 源码（上一条 `def1964` 的全量门 2335 tests / 436 suites 绿仍覆盖当前代码态）。

**10-14 实测否证「前缀复用省下 prefill」:所谓 HIT 只省了把消息再传一遍,KV 每轮仍在整段 prefill(改日志 + 立 P1)** — 上一轮把 `Session pool HIT … already cached, feeding the suffix` 与 8.36s→0.25s 记成「前缀复用确实在跑」,并把 `usage.prompt_tokens_details.cached_tokens=0` 判成 wire 谎报。本轮不再推断,直接读上游 `GenerateCompletionInfo` 原值(默认模型 `mlx-community/gemma-4-e2b-it-4bit` · port 8147/8149/8151 · 同会话 3 轮 · `max_tokens=1` 与 `max_tokens=40` 各一组 · 附「冷会话·同长度提示」对照组):**`prefilled=918 / 939 / 928`,`cached=0`,`promptTime=0.12–0.29s`**,而对照组(冷会话、模型已热、928 token)`promptTime=0.145–0.175s` —— 同一量级 ⇒ **命中轮上游把整段 prompt 全量 prefill,KV 前缀复用没有发生**;8.36s→0.25s 的落差是模型装载与预热(同一次运行日志 `Model mlx-community/gemma-4-e2b-it-4bit prewarmed in 8s`),不是省下的 prefill。两条旧结论同时了结:① `cached_tokens=0` **与引擎实态一致,不是谎报**(10-13 记的那条 wire 待修项据此撤销,不要再拿近似数去"修"它);② 真问题是 **P1:长会话每轮付全量 prefill** —— 本机 900 token 约 0.13–0.29s 尚可忍,按同速外推 30k 上下文 ≈ 3–4s/轮。**本轮只落诚实与可见性,不动复用主路**:① `SessionPool.swift` 那条 INFO 的原文是「this is the turn where the prefix cache actually saved a re-prefill」+「already cached, feeding the suffix」,与本轮自己否证的结论正面矛盾 ⇒ 改为只陈述它确实成立的事实(这些消息已在该会话 transcript 里、本轮不再重复喂入),不再宣称省下 prefill;② std 路 `.info` 新增一条 WARN —— 当本轮从 feed 里扣了消息、上游却报 `cachedPromptTokenCount == 0`,直接打出 `Prefix cache reused no tokens for <conv>: withheld N message(s) from the feed, upstream prefilled all M prompt tokens (cached=0, promptTime=Xms)`;这正是本轮花掉数小时才看见的东西,此后每次发生都写在日志里。**未做且不该偷做**:把复用真正修好。根因尚未钉死,两条候选修法的代价与语义不同 —— 上游 `ChatSession.swift:1052` 在 `stored.main.plan != kvCachePlan` 或 realized layer kinds 变化时 `restored.cachedTokens.removeAll()` 重建,`:1212` 的 `promptCachePolicy.decide` 也能直接判 `.prefillAll`;要区分需要在依赖 checkout 内打印 `decision`,而 `.build-clt/checkouts/mlx-swift-lm` 是只读(`PermissionError` 已证)。下一轮的正确顺序是:先钉上游归因,再决定 ocoreai 是否改喂全量、把前缀复用交给上游自管(上游本就为此设计了 `cachedPromptTokenCount` 与 `.trimToCommonPrefix`,而 ocoreai 目前在调用方另起一套 divergence 跳过)。**验证**:`swift build` → `Build complete! (11.97s)`;`make format-check` → zero files reformatted;聚焦门 `SessionIsolation|SteerQueue|StdToolCallRecovery|EnginePoolLoadingGate` = **56 tests / 6 suites 全绿**(纯日志语义,不改判定);活体 `live29.py`(port 8151)命中轮打出 WARN 原文 `Prefix cache reused no tokens for WARM29: withheld 2 message(s) from the feed, upstream prefilled all 939 prompt tokens (cached=0, promptTime=128ms)`,且同一次运行 3 轮只有命中轮出这一条(冷轮不误报)。**边界**:全量 `make test-clt` 与 CI(macos-26)仍是最终权威;本机无 DNS,提交未 push。

**10-13 活体否掉了自己刚记下的「可消费上游能力」:`PrefillParameters.prefix` 在 ocoreai 的 std 路恒报 0(承接 `18e6fe9` 的更正)** — 上一轮 bump 审计把 mlx-swift-lm `#644` 记为下一步:「GUI 于 prefill 早期上报复用 N token 上下文」。本轮真做下去(引擎新事件 + client/UI 两段 phase + en/zh 文案 + 4 条单测先全绿),再在默认模型上跑同会话 3 轮活体:T1 `prompt_tokens=918`/8.36s → T2 939/**0.25s** → T3 961/**0.35s**,引擎日志两条 `Session pool HIT … already cached, feeding the suffix` ⇒ 前缀复用确实在跑。但 `#644` 的回调三轮**全部报 0**:为区分「没被调用」与「调用报 0」,把日志改成无条件打印复验 = `PROBE prefix positions=0` ×3(另:上游 `prefill.prefix?(cacheStorage.processedTokenCount)` 在 `TokenIterator.prepare` 内,读的是「传进 iterator 的 cache」)。结构原因 = ocoreai 的复用发生在 `ChatSession` 私有 KV 层(其 `kvCache` 非 public),`generateTokensTask` 每次只见新 cache ⇒ iterator 视角没有前缀。同一原因使 `usage.prompt_tokens_details.cached_tokens` 在 HIT 轮仍报 0,即对 OpenAI 兼容客户端谎报「无缓存」。**处置**:整条投机管线回退(不在只会被喂 0 的路径上留一个永远不亮的指示器,也不让文档继续承诺一个测不出来的数);结论 + 两条候选修法(SessionPool 在 park/restore 时记 KV `offset`——`SessionPool.swift:799` 已有 `restoredTokenCount` 这条真数,沿 `.done` 上报 / 或把恢复出的 cache 显式传进 iterator)写进 `AGENTS.md`(Audit #1 + Open),并把「`cached_tokens` 在复用轮谎报 0」列为待决缺陷:两条路都要先与 `RotatingKVCache` 的截断语义核对,**不做近似数冒充精确数**。**验证**:`live24.py` 输出(T1/T2/T3 三行 + `PROBE prefix positions=0` ×3 + pool HIT ×2);回退后 `swift build` 绿(21.76s)、`strings` 复验二进制内 `PROBE prefix` 计数 0、`git grep prefillCacheReused` 0 命中。

**10-13 `/v1/steer` 收下的转向语可能永远进不了模型:唯一的轮内排空点在 tool 循环里,没有 tool 调用的轮次把它留在队列中(`905492e`)** — 端点文档写着「此刻没有活轮次 ⇒ 转向语存活并并入同一会话的下一次请求」,但没有任何代码执行这个承诺:全仓 `SteerQueue.drain` 只有三个调用点,两个在引擎的 tool 派发边界(`EngineInference.swift:2908` 非 MTP 路的 tool-result 尾巴 / `:3514` MTP 轮内),一个是 GUI 的 turn-end flush 退回输入框(`ChatViewModel.swift:229`)。⇒ 对 wire 客户端:一条以 200 收下、`session_id` 合法的 steer,若本轮**没有发出任何 tool 调用**(纯问答,最常见形态),就没有代码路径把它放进 prompt,也没有任何东西把它退回客户端——GUI 尚有输入框兜底,HTTP 侧什么都没有。**改法**:在契约自己声明的位置落刀——`chatCompletionsHandler` 于 `fullMessages` 建好、tokenize 之前排空该 `session_id` 的待投递 steer,经纯函数 `mergingSteeredTurn` 追成**一条** user 轮(标记一次、多条以换行合并),`prompt_tokens` 随之如实增长;`catch` 路径把 steer 回灌队列,轮次出错也不吞。去重:尾条 user 消息已含同一文本(或剥掉 `[mid-turn user steering]` 标记的正文)时不重复注入。`/v1/messages` 经 `metadata.session_id → ChatCompletionRequest.sessionID`(`AnthropicModels.swift:427`)自动同享此路;GUI 不受影响(GUI 不走 HTTP 路由,且自身 flush 使队列在下一轮前为空 ⇒ 一份经 SQLite 落进历史,仍是单次投递)。**验证**:新 `SteerRequestHeadTests` 7 tests + 既有 `SteerQueueTests` 9 = **16 tests / 2 suites** 绿(精确值:空输入恒等;两条合成一条尾 user 轮且队列归零;尾条 assistant 后仍追加;两种去重形态;去重只看尾条;失败回灌保序)。活体(`.build-clt` 二进制 · 端口 8123 · gemma-4-e2b-it-4bit):A 无 steer → `NONE`(prompt_tokens 723);B steer「The code word is PARAPET.」→ **`PARAPET`**(744);C 再 steer `KESTREL` → **`KESTREL`**,且 `/v1/steer` 回 `queued_count=1`(只有 B 的 steer 真被消费才成立);D 隔离:steer 落 ST-5、问 ST-6 → `NONE`(不跨会话泄漏);E 两条 steer → **`BRICK MARBLE`**(747)。全量门 `make test-clt` **2335 tests / 436 suites / 400.727s** 绿;`make format-check` 零重排。**已知边界**(已写进端点文档):一轮若不发 tool 调用,`ChatSession` 标准生成循环没有 message 注入缝,转向语只能延到下一次请求头,做不到轮内即时——列为开放项,不本地自建会话循环。

**10-13 每日上游自检其实一直在空转:`upstream-drift.sh` 只认 GitHub API,无网机器三源全 skip(`b4e2f91`)** — 实测 `bash scripts/upstream-drift.sh check` 在本机输出三行「api 失败(网络/auth),跳过」+ 结论「检查不完整」exit 1:近三轮的基线都只能手写 state 文件。**改法**:加本地 clone 回落(`~/references/<repo>`,`OCOREAI_REFERENCES_DIR` 可覆盖)——HEAD/base..head/messages 全部本地算(`rev-parse origin/HEAD|main|master`、`rev-list --count`、`git log --format=%s`),并在输出行标 `src=local clone`、`adopt` 把来源写进 state 的 `resolved_via`:**clone HEAD 不是 GitHub 权威,只代表该 clone 最后一次 fetch 的时刻**,联网后须再跑一次 api 通道确认。**验证**:`bash -n` 通过;`check` 三源全部解析成功并报「0 new ✓ 与基线同点」exit 0(改前 = 三 skip + exit 1);窗口分支用临时把 codex 基线指回 `a9b081516` 实测 → `+31 commits vs base=a9b081516` 并列出 50 条窗口,与本轮 Audit #3 逐条裁决的 31 个 commit 一字不差,验完还原基线(复核 `codex = b043762f9e`)。

**10-13 mlx-swift-lm 第 10 轮 pin bump:`7eb77ef → 4cc5504`(+7,逐条裁决,`18e6fe9`)** — 区间 60 files/+7726/−896,上游自身 `Package.swift` 0 变更(无需跟随的依赖地板)。**唯一有实质消费意义的一条**:`#412` honor `suppress_tokens` + 屏蔽多模态占位 token——给 Gemma4 家族种 `SuppressedTokensProviding`(把 `<image|>`/`<audio|>` 这类 prompt 侧软 token 在采样时置 `−inf`),而 ocoreai 默认模型正是 `mlx-community/gemma-4-e2b-it-4bit` ⇒ **纯消费受益、本地 0 引用、0 处需要接线**(此前这些占位符可能被采出来混进正文/被 TTS 念出)。其余:`#644` `PrefillParameters.prefix` 在首次 prefill 前报告「缓存已复用的位置数」(新参数可选,ocoreai 只传 `progress` ⇒ 不破坏编译)——记为**可消费的下一步**:GUI 于 prefill 早期就能上报「复用 N token 上下文」,而不是等 `cached_prompt_tokens` 在收尾才出现;`#301` VLM processor TODOs、`#580` 组件按需加载(MuseGlimmer 视觉编码器)、`#684` EmbeddingGemma2(ocoreai 默认 `LFM2.5-Embedding`)、`#545` Qwen3.8 text/VLM/MTP(ocoreai 的 MTP 注册表在本地,不会自动获得)、`#690` 修测试 ⇒ 全部 consumer-transparent。区间新增/改动的公开名在 ocoreai 逐个 0 消费(`git grep -c -w` = 0):`Gemma4Unified`/`Gemma4VisionConfiguration`/`eosTokenIds`/`stopStrings`/`aspectPreservingTargetSize`/`GenerationConfigFile`/`SuppressedTokensProviding`/`EmbeddingGemma2`/`MuseGlimmer`/`FastVLM`/`SmolVLM2`/`Qwen38`/`Qwen3VL`/`suppress_tokens`。**验证**(本机无 DNS,解析走本地镜像 `file:///Users/uingei/references/mlx-swift-lm` + `--disable-automatic-resolution --force-resolved-versions`,镜像配置在 gitignored 的 `.swiftpm/configuration/mirrors.json`;CI 仍从 GitHub 取该 pin,`4cc5504` = clone 的 origin/main):`swift build` **Build complete! (57.09s) EXIT=0**;`make test-clt` **2328 tests / 435 suites / 399–403s** 绿(bump 当轮数,后续 `905492e` 再加 7 项至 2335);活体烟测 `end_turn`、json_schema 24/32/48/64 全合法、前缀复用 HIT 2/3·4/5·6/7、`PARAPET` 召回、后续轮 225–290ms。

**10-13 严格 JSON 在小 `max_tokens` 下产乱码:zone reserve 把整条请求推进了「强制收尾区」(`ed6ad1d`)** — 实测 `response_format:{type:"json_schema",strict:true}` + `{"answer": integer}`:`max_tokens` **24/32 → `{"answer"\n  \n:1111…`**(temp 0 与 0.7 同形、永不闭合,引擎日志 `GuidedGenerationError … grammarTerm=false`);**48/64/128/不设 → 合法 `{\n  "answer": 7\n}`**。根因:`completionReserve = max(structural×3, maxTokens÷4)` 配 `hardReserve = structural×8`(逐字照抄上游 `MLXLanguageModel.swift:1411-1415`),小预算时 `hardReserve ≥ maxTokens` ⇒ **从第 0 个 token 起就在硬区**(每步加 `which(bias .> 0, 0, −10000)`:数字/引号/括号 +0、其余 −10000)。但硬区按上游自己的定义是「最后 `hardReserve` 个 token」的兜底、且 `hard < completion`(`GuidedGenerationLoop.swift:231-245`)——区是尾巴,不是全程。**改法**:新增纯函数 `guidedCompletionReserves(maxTokens:structuralReserve:)`,两个区都 clamp 进预算,硬区收成「语法闭合真正需要的 `structuralReserve` 个 token」;大预算数值与上游完全一致(4096 → 1024/7)。**同路再修终态**:`absorbGuidedGenerationPartialOutput` 吸收半截输出后,成功收尾块位于 `catch` 之前会被跳过 ⇒ 流里**没有任何 `.done`**,`ChatHandler` 便把「语法未收敛 + 预算耗尽」的轮次按默认值报成 `finish_reason:"stop"`(修复前实测:`finish_reason=stop` + `completion_tokens=24` + 乱码正文,客户端无从识别截断);现补发 `.guidedGenDiagnostic` + `.done(.maxTokens)`,与成功路同序。**验证**:`GuidedCompletionReserveTests` 4 tests(5 组预算精确值 24/32/48→21/7、128→32/7、4096→1024/7;`1..<200` 不变量扫描 `hard ≤ completion ≤ maxTokens` 且 `structural < maxTokens` 时 `hard < maxTokens`;退化输入归零;预算小于最小结构时等预算强制收尾)。活体同 schema:`max_tokens` **24/32/48/64 全部 `{"answer":7}` 合法、`grammarTerm=true`**(24/32 修复前是乱码);会话前缀复用未回归(`Session pool HIT 2/3、4/5、6/7`、`PARAPET` 召回正确)。

**10-13 `POST /v1/messages` 拒绝省略 `stream`——Anthropic 客户端根本打不进来(`915e108`)** — 实测 `{"model","max_tokens","messages"}` → `400 Coding key \`stream\` not found.`。Anthropic 规范里 `stream` 可选(缺省 false)。根因是 wire DTO 建模:`AnthropicMessageRequest` 用**合成** `Decodable`,本 target 的合成解码器要求所有非 Optional 键存在——`var stream: Bool = false` 的默认值救不了线上缺键;`ChatCompletionRequest` 能省略 `stream`,纯粹因为它手写 `init(from:)` 并 `decodeIfPresent(…) ?? false`(`OpenAIModels.swift:240`)。**改法**:字段改 tri-state `Bool?`(nil = 未设),转 `ChatCompletionRequest` 时 `?? false`;消费侧本就写 `request.stream == true`(`AnthropicMessagesHandler.swift:250`)。**验证**:新 `AnthropicRequestDecodeTests` 2 tests(缺键解码为 nil 且映射成 false、显式 true/false 往返)——修复前同一解码以 keyNotFound 'stream' 失败(已记录);活体 `POST /v1/messages {model,max_tokens,messages}` → **200 `stop_reason=end_turn` text='HI'**。本轮全量门:`make test-clt` **2324 tests / 434 suites / 398.862s** 绿。

**10-13 首条 chat 请求的 120 秒假等待:引擎池「等别人装载」的循环睡到了窗口末端,而不是一个轮询片** — round 15 留下的 P1 定位到行。现象是 5 个独立冷进程 120.5/120.7/120.5/120.6/121.1s,之后每请求 0.2–0.3s;根因在 `EnginePool.waitForLoading`(`EnginePool.swift:628`):`while loadingModels.contains(modelId)` 循环里写的是 `Task.sleep(until: deadline)`,即**一次睡满整个 120s 窗口**(注释还写着「suspend for 1 s」)。触发条件是设计内的正常状态——`prewarmDefaultModel` 刻意持有 loading 槽免得同一份权重被装载两次(`EnginePool.swift:549-552`),于是任何在预热完成前到达的首条请求都被停车到窗口末端。算术吻合:`live15b.log` 里 dispatch 05:54:27 → `Session acquired` 05:56:27 = 整 +120s,而模型 05:54:34 早已就绪。**改法**:每片睡 `min(deadline, now + 100ms)`(`EnginePool.loadingPollInterval`),装载完成即放行;窗口语义不动(超时仍 `AppError.modelLoading`,让客户端轮询而非放弃)。顺带修 `prewarmDefaultModel` 的文档自相矛盾:注释说预热模型「NOT registered in loadingModels」,代码两行之后就是 `loadingModels.insert`。**验证**:`swift build` 绿(36.50s);新增 `Tests/ocoreaiTests/EnginePoolLoadingGateTests.swift` = **5 tests / 1 suite / 1.406s** 全绿,分别钉住「装载完成即放行」「无在途装载时不等待」「按 modelId 分键、互不阻塞」「窗口边界仍准点抛 `.modelLoading`(实测 1.002s)」「 parked 等待可被即时取消(0.152s)」;测试用 `setLoadingForTesting` 造在途状态(沿用 `InstrumentsProfiler.swift:221` 的 `forTesting` 先例),不需要 Metal 或下载。**活体复测**(同机同模型 `serve`+`curl`):首条请求 **8.327s**(原 120.5s,约 14×),第 2/3/4 条 0.204/0.305/0.271s,`Session acquired` 与 `prewarmed in 8s` 同秒完成;另跑标准多轮累积历史探针确认前缀复用未回归——`Session pool HIT 2/3、4/5、6/7 messages already cached`,`prompt_tokens` 706→730→750→776,末轮回溯 `PARAPET` 正确。**遗留**:首请求余下 ~8.5s 是真实冷启动而非缺陷(权重装载 3.3s + tokenizer 注册 ~2–3s + Metal warmup 1s + 其余 ~1.5s),还能压但不是 bug;`/v1/count-tokens` 探针返回 400 仍未定论,不下结论。

**10-13 活体回路跑通:前缀缓存确实省下 prefill;同时抓到「首条 chat 请求固定等 ~120 秒」的 P1(已定位到层,未修)** — 用本机就绪的 `gemma-4-e2b-it-4bit`(3.3 GB,`~/.ocoreai/models`)起 `ocoreai serve` 打真请求,把 2f326d6 的主张逐条落到实测。**① 前缀复用成立**:同一会话按标准客户端方式重放历史,第 2/3/4 轮日志 `Session pool HIT … 2/3、4/5、6/7 messages already cached, feeding the suffix`;固定 `max_tokens=1` 的纯计时下,后续轮 0.347 / 0.272 / 0.347s,而 `prompt_tokens` 仍完整上报 733/756/779 ⇒ 少付的是 prefill,不是上下文。**② 上下文没被跳过**:另一组 `max_tokens=24` 的四轮对话,`6912`、`10` 正确,第 4 轮仍答出 `PARAPET`。**③ 落盘配对成立**:强制 LRU 淘汰后缓存目录出现 4 份 `.safetensors` + 4 份 `.manifest.json` 严格配对,manifest 内是真实 role/contentHash/hasMedia/hasToolTraffic。**④ 拒绝即删两条触发都验到**:伪造 sidecar(modelId=bogus-model)的请求打出 `KV snapshot discarded (…): stamped model bogus-model, request wants mlx-community/gemma-4-e2b-it-4bit` 并删掉缓存与 sidecar;另一会话重启后因 `system prompt changed` 被拒并删除。**⑤ 隔离未回归**:三条匿名单消息 = `19122` / `10` / 「你的第一个问题是 "What was my first question?"」,`prompt_tokens` 718/712/708 稳定。**⑥ round 14 三条修复复验**:`buffer cache 256 MB (single owner: MLXModelLoader), device ceiling 121 GB` 与 `Memory pressure (memory) ignored: ours 0.0/70.4 GB of budget — prefix caches kept`(本机仍被游离进程占 ~113 GB,但不再替别人降级)。**新 P1**:每个新进程的第一条 chat 请求固定等 ~120s(5 个独立进程:120.5 / 120.7 / 120.5 / 120.6 / 121.1s),而模型装载只 3.3s、预热 1s(日志自称「first request will be fast」),`/v1/capabilities` 7ms;`a792a66` 加的分段计时修正单位后**不触发**,证明推理体内(含 `pool.acquire`)不足 1s ⇒ 120s 花在 **chat handler 进入引擎之前的准备段**(会话建立 / 压缩器 / 系统提示装配 / 记忆召回这一族),且该段全程零日志。下一步定位只需在 handler 入口取时间戳打到调用引擎之后,或对候选项逐个旁路;修法待定(定长 120s 更像某处网络/权限等待,而非计算)。**顺带修的自身错误**:`Duration.components.attoseconds` 除以 10⁹ 得到的是纳秒(第一版插桩打出 421375ms 这类假数字),正确式与仓库既有 `TimingHooks.overallMs` 一致:`秒×1000 + 阿秒/10¹⁵`,离线实测 1.25s → 1252ms 钉死。**未据此下结论**:`/v1/count-tokens` 在本探针返回 400,极可能是探针按 OpenAI 习惯传 `messages` 而该端点要 `input`,未复测不改口。

**10-13 落盘的 KV 快照必须先证明「这是谁的会话」(顺带修掉一处让构建变红的引用)** — 承接 round 14 残留项 #1。上游只存原始 KV、transcript 归调用方(「A restored raw cache therefore uses fragment-based continuation」`ChatSession.swift:1710-1716`),所以 `loadPromptCacheSnapshot` 带回的文件无法对照 chat template;上一轮判定「要换持久哈希,独立一轮」,本轮落地。**改**:① 新增 `DurableHash`(FNV-1a-64,全仓唯一算法)统一三处身份——会话 seed、消息键、快照 manifest;`MessageHistoryKey` 改为 `Codable` 并新增 `hasMedia`/`hasToolTraffic`(媒体轮的像素不进 manifest、工具轮会往 prompt 渲染控制文本 ⇒ 两类都无法复核)。② 新增 sidecar `KVCacheManifest`(`x.safetensors.manifest.json`,原子写)= modelId + instructionsHash + 消息键序列;`reuseDecision` 五档拒绝 `unusableManifest`/`modelMismatch`/`instructionsChanged`/`mediaTurn`/`notAPrefix`,每档带 `logText`,**拒绝即删除缓存+manifest**(孤儿快照不许下一轮再把它捡起来)。③ 内存台账补上 prompt 侧:此前 `updateAfterTurn` 只追加 assistant 键,于是合法的第二轮被算成「缓存 1 条 vs 公共前缀 0」⇒ 整段重新 prefill(round 14 活体测到 1.219s / 1.247s / 1.178s);现在台账 = prompt 键 + assistant 键,且只在「本轮正常答完且为纯文本」时采信,不可信的一轮什么都不主张(复用照样发生,只是把整段历史交回 ChatSession 自己对齐,不做无法证明的跳过)。④ 磁盘恢复改判为真命中(`isHit` / `divergenceIndex` 带复用条数),日志不再谎报「restore loses transcript」。**修的构建错误**:在途代码调用 `manifest(for:)`——该函数根本不存在(`SessionPool.swift:775`)⇒ `swift build` 直接红;改为 `readManifest` 单次读取,并把「缓存存在但 sidecar 缺失/不可解码」并入 `unusableManifest` 的拒绝+删除路径,不再留下无人认领的缓存文件。**验证**:`swift build`(CLT 路线)→ `Build complete! (89.44s)`;新增 13 test——FNV-1a-64 参考向量 `""`→`cbf29ce484222325`、`a`→`af63dc4c8601ec8c`、`hello`→`a430d84680aabd0b`、`foobar`→`85944171f73967e8`(已用**另一套独立实现**逐位核对,round 14 就是靠这类向量抓到质数抄错)、seed/fingerprint/消息键同源、拒绝矩阵五档 + 优先级(模型不符先于前缀算术)、前缀算术边界(空/包含/错一位/同文不同 role)、媒体与工具标记、旧版本 manifest 经 JSON 解码必拒、`logText` 逐字钉死;聚焦门 `SessionIsolation|MemoryPressureCorroboration|HardwareRouter|EnginePoolRouting` = **79 tests / 15 suites 全绿**(round 14 为 66/15,增量正是本轮 13 条);`make format-check` 绿。**诚实边界**:前缀复用的**提速幅度**没在活体模型上复测——agent 沙箱内 Metal 不可用(见 AGENTS.md 本轮更正),单元层只钉住判定语义,不宣称已加速。

**10-13 iOS 编译面三处修复(逐条以 iPhoneOS SDK 一手证据核对,不是凭印象)** — 全包扫描 + SDK interface 逐条确认三处 macOS/新系统专有用法未门控:`HSplitView` 在 iPhoneOS 是 `@available(iOS, unavailable)`(`SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`)⇒ `ProjectsView` 双栏必须改 `#if os(macOS)` 双实现(iOS 走 list-over-detail 堆叠);`navigationSubtitle` = `@available(iOS 26.0, macCatalyst 14.0, macOS 11.0, *)` 而本包 target 是 `.iOS(.v17)` ⇒ 门控到 macOS,计数在 iOS 仍逐项目可见;`UIPasteboard` 只有 `dataForPasteboardType:`(UIKit `UIPasteboard.h:79`;`dataForType:` 是 AppKit 拼法,UIKit 上从不存在)⇒ iOS 分支改 `data(forPasteboardType:)`。**排除的误报**(曾疑 macOS-only,SDK 证明可用,不改):`keyboardShortcut` = `@available(iOS 14.0, …)`、`UTType`、`AVCaptureDevice.requestAccess`、`.help` = `@available(iOS 14.0, …)`;复扫未见其它未门控的 iPhoneOS 不可用面。另:`.gitignore` 补 `.build-ios/`(iOS 编译尝试的 scratch 目录,此前一直作为未跟踪噪声挂在 `git status`)。**诚实边界**:iOS 腿本地跑不了——沙箱内 `xcodebuild` 连 workspace 都无法初始化(`xcodebuild: error: 'ocoreai.xcworkspace' is not a workspace file`),且本机只装 iPhoneOS 27 SDK;该腿仍以 CI job `build-ios`(`exit 65` 不吞错)为权威,iOS **运行时**行为零验证。

**10-13 `make format-check` 只要有在途改动就永远红** — 旧判定是「格式化一遍,然后数 `git diff --name-only -- Sources/ Tests/`」,把未提交的**功能改动**当成未格式化。实测:功能改动本身已完全符合 `.swift-format` 时,它仍报 `❌ swift-format would reformat 5 file(s)`——一个开工中就必红的门等于没有门(round 14 之前那 5 个漂到 CI 的文件正是这么来的)。**改**:判定改为比较格式化前后的全量文件哈希(`shasum` 快照 → `swift-format --configuration .swift-format` → 再快照 → `join` 比对),只点名内容真被改写的文件,并保留 CI-parity 的「不盲目 checkout」语义。**验证**:正例——带 5 个未提交功能改动的当前树输出 `✅ swift-format: zero files reformatted`(exit 0);负例——在 `/private/tmp` 复刻同款逻辑并塞入一个坏缩进文件,输出 `FAIL-detected: Sources/Sub/probe.swift`,只点名该文件、不误伤同目录干净文件。

**10-12 三处 UI 在声称一次从未发生的设备切换（顺带：SF Symbol 名被当可见文字渲染）** — 实证（读码三验 + 上一轮活体日志）：Metal 设备在 `ModelContainer` 装载时绑定、运行期从不切换（`EngineInference.swift:1521-1523` 自己写明「per-request device switching 不可能」），而界面上有四处把它当成会切：① `ChatView.swift:545` 注释「user sees which accelerator handled the request」+ 徽章直接把 `.cpu` 渲染成 `CPU`；② `DashboardView.swift:99-110` 徽章把**轮询级 advisory**（整机口径）当已发生的路由展示；③ `ChannelShiftToastOverlay` 画 `GPU → CPU` 的 A→B 迁移图，文案 `channelShiftThermal/Memory` 叫「热力切换/内存切换」；④ Settings 页 `routingPolicyFooter` 向用户承诺「Balanced shifts to CPU at thermal pressure…」。另抓到同一段里的渲染缺陷：`Text("arrow.right")` 是 **Text** 而非 Image ⇒ 吐司上会显示字面量 `arrow.right`。**修**: `.cpu` 这档改名 `Guard`（图标 `exclamationmark.triangle.fill`，它真正的含义是护栏启动：关掉前缀缓存复用与投机解码；`.gpu`/`.ane` 保持真名，且 `.ane` 在 CoreAI 运行期/资产缺失时引擎已归一成 `.gpu`，徽章拿到的就是归一后的真实档位）；吐司去掉 A→B 迁移图只留单标记，文案改「内存/热力护栏启动」，a11y 同步（`%@ → %@ — %@` → `%@ — %@`，en/zh 同改）；新增 `A11y.MemoryGuard`「Memory guard active / 内存护栏已启动」；`routingPolicyFooter` 改写成「越早收紧前缀缓存与后台采样；计算设备本身不会切换」；Dashboard 徽章只在**引擎真的降级过**时才出现——`AppState.onThermalPressureEvent(_:actioned:)` 由 `EnginePool` 对账结果决定（整机读数多为他人进程的 GPU 锁定页，见上一条），未过账不再往屏幕上贴徽章/吐司。**验证**: 新增 `AcceleratorClaimHonestyTests` 4 test（`.cpu` 文案必等于 `Guard` 且不含 `CPU`、两真档保持 `GPU`/`ANE`、图标不再是 `cpu` 字形、全档非空）；`baseTableSpansAllKeys` + `zhTableSpansAllKeys` 全绿 ⇒ 新键在 en/zh 两表齐备无孤儿；聚焦门 `AcceleratorClaimHonesty|SessionIsolation|MemoryPressureCorroboration` + Locale 系 33 tests/7 suites 全绿；`swift build`（CLT `.build-clt`）→ `Build complete! (23.50s)`；swift-format idempotent。诚实边界：徽章/吐司的**像素**仍未活验（GUI 交互未活验，与既有 open 项一致）；`actioned` 判据本身已活验（同一判据打印 `Memory pressure (memory) ignored: ours 0.0/70.4 GB of budget — prefix caches kept`）。

**10-12 `/v1/chat/completions` 跨会话串味 —— 无 `conversationId` 的请求全部共用同一个 ChatSession** — 实证（本机活体，`gemma-4-e2b-it-4bit`，三条互不相关、各只带一条消息的 POST）：A「1234 plus 5678」→ `19122`；B「9 plus 1」→ `10`；C「我第一个问题是什么？」→ **原样引用 A 的问题**。根因两层：`EngineInference` 用 `conversationId ?? "<model>:ephemeral"` 把所有无状态请求折进同一个池 key，而 `ChatSession` 自带 KV 与 transcript；`acquire()` 命中后只看 `divergence > 0` 就复用，**从不检查缓存历史是否真是来话的前缀**。修：① 无 id 时改用内容派生身份 `ConversationIdentity.seed`（首条 user 消息的 FNV‑1a‑64：跨轮稳定 ⇒ 标准「重放整段历史」的 OpenAI 客户端仍享前缀缓存；跨会话互斥 ⇒ 不再共用会话或其落盘快照；刻意不用 `hashValue`，它按进程播种，会让落盘快照换个进程就找不回名字）；② 新增硬闸门 `MLXSessionPool.canReusePooledSession(cachedMessageCount:commonPrefixCount:)`——来话必须覆盖缓存里的全部历史才可复用，否则丢弃重建（同一闸门顺带堵住 GUI Edit&Resend 的分叉：旧 KV 描述的是改之前的会话）。**验证**: 新增 `SessionIsolationTests` 8 test——钉 FNV‑1a 标准向量（`""`→`cbf29ce484222325`、`hello`→`a430d84680aabd0b`）+ 两条真实提示词向量、system 消息不参与身份、跨轮身份不变、分叉/碰撞必须拒、`canReuse` 边界；**这组向量当场抓出我自己的错**：质数被写成 `0x1000_0000_0000_01b3`（多出一组 `0000`），修正为 `0x1_0000_0001_b3` 后 Swift 与标准向量逐位吻合（低 32 位巧合相同、高 32 位全错，正是乘数高次项丢失的特征）。活体复跑：C 不再知道 A（答「你第一个问题就是『What was my FIRST question…』」），三条独立请求 `prompt_tokens` 稳定 718/712/710（改前会随串味累积，与实际送入模型的上下文不符）；同一会话重放历史依旧正确（第 4 轮答出 `PARAPET`）；聚焦门 66 tests/15 suites 全绿。**已知残留（不静默扩大范围）**: 落盘快照恢复出的 wrapper 其 `messageHistory` 为空，闸门对它恒判「可复用」；两条首条消息逐字节相同、同模型的匿名会话理论上仍可能撞同一 key 并从磁盘快照带回上下文。彻底堵住需把历史键随快照持久化，而 `MessageHistoryKey.contentHash` 现用按进程播种的 `hashValue`（跨进程不可校验）——留作下一条独立工作。

**10-12 整机内存压力不再替别人的进程买单 —— 降级先与**自己**的占用对账** — 实证（M5 Max / 128 GB，本机当时有个游离 `python3.11` 进程占着 ~79 GB）：`memoryUsageFraction()` 读到 ~74% ⇒ level 3 ⇒ `route()` Tier‑1 判 `.cpu` ⇒ 每个请求 `poolRef = nil`（KV 每轮重建）+ 关投机解码，而 ocoreai 自己只用了 3.5 GB / 70 GB 预算。**关键事实**: Apple Silicon 的 `wire_count` 含**所有进程**的 GPU 锁定页，这个数字根本证明不了「是我们的压力」；而且这次降级既没换来内存（绕过 SessionPool 反而增加分配抖动），却把吞吐花光了。**修**: ① 新增纯函数 `HardwareRouter.pressureIsOurs(gpuFraction:reclaimableBytes:memSizeBytes:)`——只有自己占掉 ≥½ 预算，或整机可回收内存（free+inactive+speculative，不加 `purgeable` 以免与 inactive 重复计）低于 max(1 GiB, 物理/16)，才算「我们的」；未知输入按我们的处理（宁可保护内存）；② `route()` Tier‑1 必须同时满足严重度与对账（新增形参 `pressureIsOurs` 带默认值 ⇒ 旧调用语义不变）；③ `EnginePool` 的轮询回调不再无条件 `flushing entire session pool`，先对账，不过账就只记一条 `Memory pressure (memory) ignored: ours … GB of budget — prefix caches kept`；④ 日志不再声称换了设备——设备在 `ModelContainer` 装载时就绑定，`.cpu` 这一档实际只关掉前缀缓存复用与投机解码。**验证**: 新增 `MemoryPressureCorroborationTests` 11 test（½ 预算边界含等号、可回收下限在 8 GiB/1 GiB 机型上的取值、未知即保护、对账不过时 `route()` 留在 `.gpu`、同一读数确属我们时仍降级、热档不被掩盖、默认参数保旧语义、读器与 `ProcessInfo.physicalMemory` 逐值一致）；聚焦门 `SessionIsolation|MemoryPressureCorroboration|HardwareRouter|EnginePoolRouting` = **66 tests / 15 suites 全绿**；活体对照：改前每请求一条 `HardwareRouter → CPU`（3 次）且 4019-token 提示重复三次 0.91/1.01/1.24 s **毫无缓存收益**，改后同一压力只出 `lane advisory gpu → cpu (degradation gated on corroborated footprint)` + `ignored: ours 0.0/70.4 GB`，CPU 降级 0 次。

**10-12 MLX 缓冲缓存上限有两个写主 —— 日志里的「budget: 70 GB」从未生效（实测 256 MB=42-46 tok/s vs 4 GB=23.7 tok/s）** — 实证: 启动日志 `Hardware: 128 GB RAM, budget: 70 GB` 之后，`EnginePool` 里的 `MLXModelLoader.init`（`Engine/MLXBridge.swift:108`）无条件把 `MLX.Memory.cacheLimit` 写成 256 MB，晚于 `App.swift` 的 `Memory.cacheLimit = Int(memBudget)` ⇒ App 那次写入**从未生效**（临时探针实证: loader-init 之后 `cacheLimit = 256 MB`）。**为何这是 bug 而非只是死代码**: `cacheLimit` 管的是 MLX 的**可回收缓冲池**——上游 `mlx-swift Source/MLX/Memory.swift:37-56` 写明 cache = 「已释放但留着复用」的设备内存，上限越大越不回吐；把调度预算当缓存上限写，语义和后果都错。**本机实测**（M5 Max / 128 GB · `mlx-community/gemma-4-e2b-it-4bit` · greedy 160 tokens × 3）: 256 MB = 43.3 / 43.3 / 44.1 tok/s，4 GB = 23.7 / 23.7 / 43.5 tok/s ⇒ 预算尺寸的缓存不只是无效，而是**更慢**（回吐被留住）。**修**: `Memory.cacheLimit` 单一写主 = `MLXModelLoader`（值仍取上游 `MLXLanguageModel.configureGPUCacheOnce` 的 256 MB，注释记下本轮实测）；App 侧删除该写入并写明「budget 是调度记账，不是设备上限」；`EnginePool` 初始化后新增一行**生效值**日志。**验证**: 改后启动日志 `MLX memory — buffer cache 256 MB (single owner: MLXModelLoader), device ceiling 121 GB (Metal recommended max working set)`（顺带证实 70 GB 预算从来不是设备上限）；新增 `Class-H` 审计门钉死第二写主——负例（临时在 `Core/` 放一个含 `Memory.cacheLimit =` 的文件）报 `❌ 1 violation(s)`，删除后 `✅ All audits passed`；`swift build` → `Build complete! (11.78s)`；swift-format 二次运行零改动。**留给人拍板**: MLX 设备上限 121 GB vs 应用预算 70 GB——是否把预算落成 `Memory.memoryLimit`（小内存机型会因此提前拒载大模型，故本轮不静默改）。

**10-12 样式门在本地根本跑不动 ⇒ 漂移直落 CI** — 实证: `make format-check` 在本机报 `make: swift-format: No such file or directory`（这台机器只有 `xcrun swift-format`，brew 不在场），而 CI 的 `Static Audit` job 先 `brew install swift-format` 把它放上 PATH、再要求 `swift-format format --in-place --recursive Sources/ Tests/` 零 diff。4c1b4ad/1139ecd/2a4ce5a 一直只在本地，b683836 是它们第一次进 CI，格式门当场抓到 5 个文件（`SQLite/ProjectStore.swift`、`UI/ViewModels/ChatState+ComposerIngest.swift`、`UI/Views/ProjectsView.swift`、`ComposerIngestTests.swift`、`ProjectStoreTests.swift`）。**根因不是手滑，是门不可运行**: push 前本地没有任何入口能查这一条。**修**: ① Makefile 新增 `SWIFT_FORMAT ?= $(shell command -v swift-format … || echo "xcrun swift-format")`，`format`/`format-check` 统一走它（参数与 CI 逐字相同，不做第二套规则）；② `bfcfb4b` 把 5 个文件按 `.swift-format` 归位——纯换行 / 多行尾逗号 / import 序 / `#if os(macOS)` 内被缩进的 `import AppKit` 归零列，零语义变更。**验证**: 改前 `xcrun swift-format` 重排 Sources+Tests 全部文件中的**恰好这 5 个**（其余零改动 ⇒ 真漂移而非版本分歧）；重排后 `swift build`（CLT `.build-clt`）→ `Build complete! (22.03s)`；提交后 `make format-check` → `✅ swift-format: zero files reformatted`；`make audit` → `✅ All audits passed`。

**10-12 macOS 26 上真正的分词器被编译掉了 —— `canImport(CoreAI)` 冒充了 `canImport(Tokenizers)`（活体 404 → 200）** — 实证链（本轮首次在本机跑通 `serve` + Metal，见末条）: `GET /v1/models` 报 `mlx-community/gemma-4-e2b-it-4bit` `state:"ready"`，**同一个 id** `POST /v1/count-tokens` 答 `404 {"message":"Model mlx-community/gemma-4-e2b-it-4bit not found"}`；chat 能出字但 `usage.prompt_tokens` 是字节启发式；`EnginePool.swift:1009` 还无条件打印 `Tokenizer registered … — context wall on real token counts`。**根因（编译期三验）**: `Sources/ocoreai/Tokenizer/TokenizerManager.swift:19` 用 `#if canImport(CoreAI)` 包住整套真分词器（`AutoTokenizer`/`DirectTokenizer`/`StreamingDetokenizer`），可它唯一的依赖是 swift-transformers（`Package.swift:97` 无条件 product），CoreAI 是**另一条轴**（Apple CoreAI，macOS 27 SDK）；macOS 26 交付面上 `canImport(CoreAI)==false` ⇒ `Models/InferenceStubs.swift:521` 的 stub `TokenizerManager`（`registerTokenizer(for:tokenizerPath:)` = `{}`、`getTokenizer` = nil）顶替真身：注册「成功」是假的，查询恒 nil。**为何全门看不见**: `Tests/` 有 20 个文件整体 `#if canImport(CoreAI)`，CLT 路上编译为空，而 stub 与真身同名，互比型断言无从分辨。**探针实证**（临时 `Core/_GateProbe.swift` 用 `#error` 读出即删）: 本机 CLT `canImport(CoreAI)==false`、`canImport(Tokenizers)==TRUE`。**修**: 真身改 `#if canImport(Tokenizers)`；stub 大块按依赖拆两半（tokenizer stub → `!canImport(Tokenizers)`，CoreAI 类型 stub 仍 `!canImport(CoreAI)`）；两侧各加 `isRealTokenizerBackend`（真=true / stub=false），`/v1/capabilities` 落 `tokenizerBackend: real|heuristic`，日志只在真后端才声称 real counts。**验证**: 新增 `Tests/ocoreaiTests/TokenizerBackendTruthTests.swift` 3 test——① 后端链接断言 ② 不存在的 tokenizer 路径**必须抛错**（stub 是 `{}` 全吞，抛错即「非 stub」的正证）③ hermetic WordPiece fixture 精确 `ids == [2, 3]` + detokenize 回文；活体 `/v1/count-tokens` 由 404 → `{"prompt_tokens":19}`、`capabilities.tokenizerBackend=real`、整段运行日志 `Tokenization failed, using heuristic estimate` 计数 **6 → 0**、同一句 chat 请求（`Count from 1 to 60…`）`usage.prompt_tokens` 由 708（改前=字节启发式）变 713（改后=真 token 数）。**影响面**: 上下文墙、`usage`、auto-compaction 触发点全部从「字节/3-4 估算」切回真 token 数。

**10-12 一个事实两套谓词 —— 图像能力在 wire 上说谎（`vlm:false`，可同一个模型答对了图）** — 实证: 同一权重目录（含 `processor_config.json`、**不含** `preprocessor_config.json`）里，引擎侧 `VLM model detected — using VLMModelFactory`，真发一张 448×448 红底圆 PNG 问「什么颜色」⇒ 答 `Red`（`prompt_tokens` 960，视觉塔确实跑了）；而 `GET /v1/models` 对同一模型发布 `vlm:false`。**根因**: 一个事实两套残缺谓词——发现侧 `ModelStore.discoverReady()` 5 处只测 `preprocessor_config.json`（`:393/:412/:438/:468/:486`），加载侧 `MLXBridge.swift:115` 只测 `processor_config.json` ⇒ 双向都错: 新式 checkpoint（Gemma 4 / Qwen3.5 系）加载成真 VLM 却对外宣称纯文本（标准 OpenAI 客户端按 `vlm` 决定能否附图 ⇒ 有能力强拒附图）；旧式 checkpoint（Gemma 3 / Qwen2.5-VL / SmolVLM2）对外宣称 VLM 却按 LLM 加载（真附图直接不支持）。**第三处**: UI 解析 `ModelMemoryInfo.swift:87`、`ModelsViewModel.swift:38` 把 `entry["specialized"]` 当 VLM——`specialized` 是 CoreAI ANE 专用标志（`EnginePool.swift:1113-1117`，仅 `canImport(CoreAI)` 时写入），macOS 26 恒缺 ⇒ 模型列表对每个 MLX 视觉模型都显示成非视觉（`ModelView.swift:673` 图标、`:688` 徽标）。**修**: `ModelStore.hasVisionProcessor(at:fileManager:)` 成为全应用**唯一**谓词（两文件名皆收，镜像上游 mlx-swift-lm `VLMModelFactory.loadProcessorConfig`（`Libraries/MLXVLM/VLMModelFactory.swift:549-556`）preprocessor→processor 的接受集与优先序），`discoverReady` 5 处与 `MLXModelLoader.isVLMModel` 全部改为委托；两个 UI 解析器改读 `"vlm"`；MLXBridge 三处「via `preprocessor_config.json`」过期注释改成真描述。**验证**: 新增 `VLMCapabilityTruthTests` 6 test（无配置 / 仅 legacy / 仅 modern / 皆有 / **「加载器与发现必须逐目录一致」** / wire 键 `"vlm"` 解析且缺省不为真）；`PipelineCoverageTests.fromList*` 原本正钉着 `"specialized"` 的旧行为，本轮按更正后的契约改判并加断言: `specialized:true` 单独出现**不得**判为 VLM，两键并存时以 `vlm` 为准；活体 `/v1/models` → `vlm=True`。

**10-12 语法约束轮跑完不关流，落回已释放的 ChatSession ⇒ 成功的轮次统一 500** — 实证: `response_format:{type:"json_schema", strict:true, …{"result":integer}}` → `500 Engine internal error: no active chat session`；`tools:[…,"required":[]]` 同 500。日志三连: `Routing through GuidedGenerationLoop with grammar constraint` → `Guided gen diagnostics: … grammarTerm=true tokens=7 sampled=6 ff=1 incomplete=false` → `Standard ChatSession path entered with nil chatSession`。**根因**: guided 分支进入前把池化 session 归还并把 `chatSession` 置 nil（`EngineInference.swift:3052-3066`，注释自陈「guided 不能复用 ChatSession 缓存」），`handleGuidedGeneration` 产出 tokens + `.guidedGenDiagnostic` + `.done` 之后**从不 `continuation.finish()`**（全函数 0 处 finish），调用点也不 `return` ⇒ 控制流继续向下撞进标准 ChatSession 路径（`EngineInference.swift:4252`）在 nil 上追加一条 `.error`；非流式聚合里这条 `.error` 赢者通吃——文本已生成、JSON 已合法，客户端仍拿 500。另两处 grammar 构建失败早退（`:1962`/`:1985`）同样只 yield `.error` 不 finish，过去全靠这条错误 fall-through 兜住。**修（谁拥有这轮流谁收尾）**: `handleGuidedGeneration` 成功/吸收路径末尾 `continuation.finish()`（`finish()` 幂等，已收尾的错误路径不受影响），两处早退补 finish，调用点在 guided 之后 `return` 不再落到标准路径。**验证（同一二进制前后活体对比）**: `json_schema` → `200 {"result": 4\n}` `finish_reason=stop`；`curr_time`（空 schema）→ `200 finish_reason=tool_calls tool_calls=[{"name":"curr_time","arguments":"{}"}]`；`nil chatSession` 计数 0（改前 2/2 必挂）。**边界**: 该路径要求 Metal + 真模型才可达，20 个 CoreAI 门控测试与 CI 沙箱都进不来，所以 2277 tests 全绿也能一路带着它跑——列为后续「活体优先」固定项。

**10-12 prompt 命令模型「用你的工具跑命令」，可这一轮根本没有工具 ⇒ 模型编造 terminal 输出；有工具时编造「我已经搜索过」** — 零工具轮实证: 客户端未声明 `tools[]`，引擎日志 `Tool surface [no-tools route (client declared no tools[])]: 0/39 injected`，但 base prompt 仍含 `Assume the user wants code changes … use your tools to actually implement changes and run commands`；问 `Count from 1 to 60, space separated, nothing else.` ⇒ 答 `terminal\ncommand: "seq 1 60"\nstdout: "1 2 3 …"`——伪造命令输出冒充执行结果，正是 identity 句禁的 fabricate。有工具轮实证: 声明 `web_search` 后两次运行均无 tool call，却写 `I have searched the web for the latest MLX release notes… (Source: https://mlx.studio/)`——叙述式假装完成 + 编造引用。**根因**: `codingAgentBase` 把身份与行动指令焊死，`MessageBuilder` Phase 1 建 prompt 时还不知道本轮工具面（tools 要到 Phase 5 才注入），而 10-06 那轮已把 wire 默认工具面收成 0 ⇒ 指令与能力分叉。**修**: 拆三段——`codingAgentIdentity`（身份+求真，恒在）/ `toolActionDirective`（仅当真有工具，且末句加 claim-discipline「声称某动作 = 调用过该工具并见过结果」）/ `noToolsDirective`（无工具改为直答，并明令不得伪造命令输出/终端转录/diff）；`build(includeCategories:hasTools:)` 负责组装，**`hasTools` 进 `computeHash`**（否则 agentic 轮会命中缓存的 no-tools prompt，反之亦然）；`MessageBuilder` 用与 Phase 5 同一字段 `context.tools?.isEmpty == false` 传真实面（`nil`/`[]` 在 `resolveToolSurface` 都等于零工具）；`App` 注入 base 改为 identity-only；`codingAgentBase` 保留为 `basePrompt(hasTools:true)` 别名，既有行动优先契约断言一字不降。**验证**: `SystemPromptContractTests` +3 test（无工具轮必含 `no tools`/`never pretend to run a command`、不得含 `use your tools`/`run commands`；有工具轮保留 action-first 与 claim-discipline；**工具面进缓存键**——交替 build 两组结果稳定不串味）；活体同型请求 → 直答 `1 2 3 … 60`，伪造指纹检测 False；`web_search` 声明轮两次均 `finish_reason=tool_calls` 真发调用，叙述式假装 0 次。

**10-12 本机全量门其实能跑（AGENTS.md 旧记录是沙箱属性，不是平台属性）** — 本轮把全量测试跑在了本机 macOS 26 CLT 路上: **2277 tests / 428 suites**，400s 跑完（唯一 1 处 failure 是本轮 UI 键位改判牵连的 `PipelineCoverageTests.fromList`，已按更正契约修）。此前记录「`swift test` 非门、全量权威只在 CI（macos-26）」的全部原因是**进程被沙箱挡住 GPU**: 沙箱内 `MLX error: [metal::load_device] No Metal device available`（死于首个碰 MLX 的套件），沙箱外同一二进制 GPU 可用、`serve` 正常载模型出字。也据此修正了两条更旧的判断: metallib 只解决 shader 加载、不解决 device 可用性（沙箱内两者都无），而 GUI 活体验与 `/v1/*` 线级活体在本机同样可行（本轮即靠活体抓到 count-tokens 404、`vlm:false`、guided 轮 500、伪造命令输出四条静态审计看不见的缺陷）。已写回 `AGENTS.md` Build / Test / Lint 段。

**10-12 全局全文搜索 100% 必挂 — JOIN 内两表都有 `content`，谓词必须点表名（红→绿钉死）** — 实证: `GET /sessions/search?q=…`（对外承诺见 `README.md:101` / `README.zh.md:86`）不带 `&session=` 时走 `FTS5Search.search()` 的 `WHERE content MATCH ?`，而该 SQL 是 `FROM messages_fts fts JOIN messages m ON fts.rowid = m.id`；`messages_fts`（`SQLiteStore.swift:423` 声明 `session_id UNINDEXED, content`）与 `messages` 同时暴露 `content` ⇒ 以生产同款 schema 用 sqlite3 复现: `Error: in prepare, ambiguous column name: content`，再经 `AppError.inferenceFailed("Search failed: …")` 冒到 HTTP 层。上一轮只把带 `session` 的分支限定为 `fts.session_id`/`fts.content`，默认（无 session）分支——恰是文档示例形态——仍然必挂。**为何此前无人发现**: `git grep -n "\.search(" Tests/` = 0，既有 `SQLite FTS5` 套件只用整表 MATCH 语法 `WHERE messages_fts MATCH …` 打裸 SQL，`search()` 的两个分支从未被任何测试调用。类扫描: `git grep -n "MATCH" Sources/ocoreai/SQLite` 8 命中逐条判 —— `searchByContent`（`:126` 已 `m.session_id`+`fts.content`）/ `searchMemoryEvents`（`SessionCompressor.swift:1128`/`:1137` 用整表名 MATCH）/ `countMatches`（单表 FROM ⇒ 无歧义）皆安全，唯 `search()` 两处中招。**修**: `whereClause = "WHERE fts.content MATCH ?"`（谓词全部点表名，MATCH 留在索引侧），并把「只有一支会挂」的旧注释改成该类的真描述。**验证（先红后绿）**: 新增 `Tests/ocoreaiTests/FTS5SearchTests.swift` 9 test（跨会话命中 · 每条命中自带 `sessionId`+`messageIds` 归属 · `limit` 精确封顶 · absent 词得空集而非抛错 · snippet 恰 200 字符 · 作用域排除他馆 · `searchByContent` 不出界 · `countMatches` 两档与 `search` 对齐）；将该行改回未限定形态重跑 ⇒ 5 test 全红且逐条报 `ambiguous column name: content`；还原修复态 ⇒ `--filter FTS5` **11 tests / 3 suites 全绿**。**诚实边界**: 证明止于 SQLite 层——`ChatCompletionsRouter.swift:756` 起的 HTTP 线级用例未加，因现无「不经推理即可写入 message」的路由（唯一写入口是 `/v1/chat/completions`），为一句话转发翻倍 E2E harness 不划算。

**10-12 env 守卫的盲区: 契约是背下来的，代码新增的键它看不见（已闭合 + `.env.example` 失真改真）** — `Tests/ocoreaiTests/EnvKeysDocumentationTests.swift` 自称锁死「本文件键集 == Sources/ 读键集」，但 4 条断言全是**两个各自声明的列表互比**: 硬编码 `expectedKeys`（23）vs `.env.example`。native 直连搜索落地时新增的 4 个键 `OCRE_SEARCH_MODE`（`DirectWebSearch.swift:529`）/ `_ENGINES`（`:324`）/ `_MAX_HITS`（`:567`）/ `_DIRECT_TIMEOUT`（`:568`）既没进契约也没进文档，两侧**对称缺失** ⇒ phantom/missing 双向皆空 ⇒ 门照绿。实证: 从 `Sources/` 派生 `environment["KEY"]` 字面量集合 = 21 键，其中 4 个不在契约内。修: ① 契约补 4 键（23→27）；② 新增断言 5 `noLiteralReadIsMissingFromContract()` —— 用最笨的子串扫描（刻意不用 regex）从 `Sources/` 派生大写键（`OCOREAI_`/`OCRE_`/`HF_`/`MODELSCOPE_`），任何未列入契约的键直接红；先断言派生数 ≥21，防「扫描坏掉看起来像绿」；插值读取（`environment["\(envPrefix)BACKEND"]`）的 token 含反斜杠被有意跳过，那一路由断言 3 覆盖。**证明它会咬**: 把 4 键从 `expectedKeys` 删除重跑 ⇒ 红并逐名列出 `[OCRE_SEARCH_DIRECT_TIMEOUT, OCRE_SEARCH_ENGINES, OCRE_SEARCH_MAX_HITS, OCRE_SEARCH_MODE]`；还原 ⇒ `EnvKeys` 4 tests 绿。**同批把 `.env.example` 按其自订契约改真**（头部明写「行尾 `# 默认:` 是代码当前实际默认值，行号 = 真实来源」）: 搜索段仍写 `默认 http://192.168.101.146:11434/v1 … [MUST-OVERRIDE]`，真值 `WebSearchTool.swift:345` = `http://127.0.0.1:11434/v1`（loopback 才是多数人的正确默认，「必改」是错引导）；段名仍叫「本地 ollama 后端」而默认 `native` 根本不需要后端；行号过期 5 处（`268/269/270/242` 与 `WebFetchTool.swift:76` → `345/346/347/319` 与 `:237`）；`OCOREAI_APPROVAL_POLICY` 指 `Approval.swift:116`（真读点 `SettingsStore.swift:386` + `ConfigSystem.swift:214`）；`OCOREAI_ENABLE_HTTP` 指 `App.swift:593`（常量在 `HttpBridgePolicy.swift:17`，读于 `App.swift:605`）。4 新键补齐，注释列按 awk 校准至 43 与全文件一致。

**10-12 AGENTS.md 把「写代码的模型」当成了「搜索后端的模型」— agent 运行环境段按现况重写** — 该文件 L204-217 声称「本环境跑在 **Ollama**（provider `ollama-launch`, model `qwen3.8:27b-mtp`），不支持并发模型调用，`delegate_task`/嵌套 `skill_view` 会失败」，并要求每轮先读 4 个技能。实证: ① 真实 coder = **Codex**（CLI + 桌面 app），工具面是 `exec_command`/`apply_patch` + harness 注入的 MCP，`~/.codex/skills/.system` = imagegen·openai-docs·review-agent·skill-creator·skill-installer；② `find ~/.codex /Users/uingei/ocoreai -type d -name <skill>` 对 `single-pass-orchestration`/`code-review-discipline`/`hermes-agent`/`ocoreai-dev` **4/4 全 0 命中** = 死指针（与前轮清理的 `engineering-grilling`/`code-audit-methodology` 同病）；③ `qwen3.8:27b-mtp` 实为 `OCRE_SEARCH_MODEL`（`WebSearchTool.swift:346`），只在 `OCRE_SEARCH_MODE=backend|auto` 时由 `DirectWebSearch.swift:532`/`:540` 调用，默认 `native`（`:529`）不需要任何本地服务——它从来不是写代码的模型；④ `.hermes/` 已 gitignore（`.gitignore:29`）且今天只剩 `.hermes/plans/` 一份路线图，L171 所称 `.hermes/audits/` 不存在。后果: 每轮冷启动注入一段与自身工具面矛盾的「平台物理约束」，并把 agent 指向不存在的技能——AGENTS.md 自己点名 wiki 的 time-aging distortion，它正在犯（其文档地图要求本文件 line-accurate）。重写为 `## Agent Runtime Reality (Codex)`: coder 身份/工具面/技能权威来源 + 死指针清除留痕 + 「sub-agent 可用但默认仍单趟」的两条**换了工具也成立**的理由（owner 逐 commit 审 ⇒ 无人读的 fan-out 不增加保障；本地 `swift build`/`swift test` 共用 scratch path `.build`/`.build-clt` ⇒ 并行只争锁不省时间）+ 不变的门（三层验证 / `swift build` exit 0 / `make test-ci` 权威 / CHANGELOG 必带 commit ref）；L3 与文档地图 L142 的 `Hermes` 一并改真。**诚实边界**: 本轮改的是开发期 agent 指令，未触碰运行时注入的 `SystemPromptBuilder` / `ToolEntry` schema，故不需推理回归；磁盘技能目录与运行时注入清单不完全一致（磁盘多一个 `review-agent`），文中分行陈述、不做合并断言。

**10-12 transcript 文本可选 — 读得到的字就该选得中** — 缺口实证: `git grep -n "textSelection" Sources/` = 仅 2 处（`FileDiffCard.swift:149` / `MarkdownMessage.swift:80`），且 `MarkdownMessage` 只在 **markdown 解码成功**的分支挂 `.textSelection(.enabled)`，`try?` 失败后的 fallback `Text(content)` 不挂；`ChatMessageInner` 的 user 分支是裸 `Text(text)`，完全没有选择能力。后果 = 自己敲进 composer 的路径/报错串无法框选（只能整条 Copy 或重打一遍），而 markdown 解码失败的那批 assistant 消息**静默失去**选择——恰恰是最需要复制其中片段的长文。修: `.textSelection(.enabled)` 挂到 `ChatMessageInner` 容器（user/assistant 两分支继承）+ `MarkdownMessage` fallback 分支。第一性: HIG「可读文本即可选」；Bionic / ChatGPT / Codex app 的 transcript 均可框选。**同轴来源**: 本轮 codex drift 窗口 `#53152`（Allow selecting and copying TUI turn tips）——轴本身是 TUI、ocoreai 0 消费，但抽出的原则在本地落刀。**诚实边界**: view modifier 无法单测断言，未活验 macOS 实机框选与既有整条 Copy 右键菜单的交互（选中态下系统可能优先弹文本选择菜单，同 ChatGPT 行为——未实测不声称）；iOS 侧仅编译通过。

**10-12 drift 轮 10（离线，源 = 本地 references clone）— AGENTS.md 三条上游事实全部失准，逐条改真 + 11 commit 裁决** — 实证: `references/{mlx-swift-lm,coreai-models,codex}` ref mtime 当日 11:01–11:09（= 本会话开始前），`origin/main` 分别 `7eb77ef` / `52dbd93` / `a9b0815167`。而 AGENTS.md 仍写 ① pin `ee673d6`（真身 `Package.swift:41 revision: "7eb77efa4"`，round 9 `80f0c01` 10-11 已采纳 `7eb77ef`；`git rev-list --count ee673d6..7eb77ef` = **35**）② coreai-models HEAD `e7b24da`（基线早已 `52dbd93cb`，`b9c61e7` 10-11 吸收 +5）③ codex 基线 `1cc7e2361`（state 文件 10-11 即 `cc7ba3360`）。**AGENTS.md 是每轮注入的 agent-facing 文件，自身规则要求 line-accurate——它正在犯它点名 wiki 的那条 time-aging distortion**。修: 三条换成当前真值并保留前序 SHA 作 provenance；另补记 `b9c61e7` 那轮 codex **+160 只落 state 文件、未写 AGENTS.md 与 CHANGELOG**（脚本 L128 明令 adopt 后须补 AGENTS 审计行 + CHANGELOG 行——流程欠账，本次清）。新窗口 `cc7ba3360..a9b081516` 11 commit 逐条 consumer-transparent 双根全扫：TUI 轴 5（`background.?server`=0 · `subagent|sub_agent|delegate_task`=0 · `\bvim\b`=0）/ app-server-remote 轴 3（`app.?server` Sources 全扫 = **0**，ocoreai 生命周期自有语义 = cancel+await `EnginePool.swift:1412`，无 remote 事件队列面）/ CLI 轴 1（Swift-Darwin 默认 SIGPIPE=ignore，真正吃管道的是子进程 stdin，`ExecSessions.swift:125` 已处理）/ draft-vim 轴 1（其轴早已消费：composer draft 上收 `ChatViewModel.swift:157`）⇒ **11/11 consumer-transparent，0 强制缺口，0 ocoreai 生产面变更**；抽原则 1 条落刀（可读即可选 → 上条 textSelection）；显式**不采纳** 1 条：`#53150` 授权跨冷重启持久化——ocoreai 审批刻意按 turn 清场（`ChatViewModel.swift:1543` → `ApprovalBroker.cancelAll()`），跨重启回填授权 = 信任模型变更，留人拍板。**验证**: 三源窗口实数逐条 `git rev-list --count`（35 / 5 / 11）+ 双根 grep 逐词留痕；`.upstream-baseline.json` codex → `a9b081516`（`scripts/upstream-drift.sh adopt` 需 `gh api`，本机无网络 ⇒ 按脚本同款 schema 手写并在 `adopt_provenance` 字段记明离线源）；`swift build --target ocoreai` exit 0（9.43s）。

**10-12 编辑并重发（Edit & Resend）— 用户自己的话可就地改，废弃分支从内存和 SQLite 一起消失** — 缺口实证: `git grep -E "editMessage|beginEditing" Sources/` = 0。transcript 只有 Regenerate（同一句话原样重跑），于是模型因指令不准而跑偏时，唯一补救是在下面**追加**一句纠正——错误指令永久留在上下文里，此后每一轮都为它付 token。Bionic / Codex app / ChatGPT 同轴能力是「就地改指令，从该点重跑」。修: ① 纯策略 `Core/TranscriptEdit.swift`（只有 user 消息可编辑·空编辑不点火·目标缺失如实 notFound 不猜·`dropCount = 转录长度 − index`）；② `SessionCompressor.dropTranscriptTail(sessionId:count:)`：`ORDER BY id DESC LIMIT ?` 只砍尾，SQL `LIMIT` 天然封顶 ⇒ 库里行数少于转录时砍掉存在的、绝不回溯更多，并返回真实 dropped 数（不是请求数）；③ `ChatState.truncateTranscript(from:includingMessage:)` 成为 Regenerate 与 Edit 的**唯一**截断原语（false 保锚点 = 重跑同一句 / true 连锚点一起删 = 改完再发），且**镜像到 SQLite**——此前截断只动内存：推理读内存（`chat()` → `cleanMessages(messages)`）所以当下行为正确，但库里那行还在，**下次打开会话时废弃分支连同改之前的措辞一起复活**；④ 就地编辑器（HIG: 不弹 sheet——把用户正在修的东西留在原位；进编辑即抢焦点，⌘↵ 重发、Esc 取消；故意不用 `.defaultAction`，默认按钮会吃掉整窗 ↵ 使本编辑器无法换行），行内铅笔常显（低透明度）+ hover 提亮 + 右键菜单 Edit & Resend；⑤ 重发把原附件带回去（旧 resend 硬传 `attachments: []`：气泡里看得见图、模型收不到图 = 静默上下文丢失，一并接回）；⑥ 编辑态上收 `ChatState`，行重建/切会话不得吞掉半截修改（`reloadSession` / `resetConversation` / `undoReset` / `resetForTesting` 四点清理）。**同刀修掉一条活的公开面缺陷**：`FTS5Search.search(sessionId:)` 谓词 `WHERE session_id = ? AND content MATCH ?` 未加表限定，而 `messages_fts` 与 `messages` 同名列 ⇒ SQLite `ambiguous column name`，**任何带 session 过滤的全文搜索必然失败**（HTTP `/v1/search?q=…&session=…` 直达 500）；改 `fts.session_id`/`fts.content` 把过滤留在索引侧。全 `Tests/` grep `searchFTS5(` 仅本刀新增两处调用——既有测试从未以 `sessionId ≠ nil` 走过这条路，故缺陷长期潜伏。**验证**: `swift build --target ocoreai` exit 0（10.22s）；CLT 门 `swift test --filter 'TranscriptEdit|DropTranscriptTail|ChatStateEdit|ComposerIngest|ContextWindow|LocaleResolution|ReasoningPersistence|ToolCallRecordRoundTrip'` = **85 tests / 20 suites 全绿**（新增 20 例：plan 逐值覆盖 notUser / notFound(含 −1、越界、空转录) / emptyText(空格·制表·裸换行) / 内部换行保真；dropTail 存活内容逐值 + 短库只砍 1 + 零不删 + 跨会话不外溢 + 编辑废弃轮在 FTS 不留幽灵且保留句命中 1；ChatState 编辑态开/关/拒 6 例）；`swift-format` 二次运行零改动（idempotent）。诚实边界: GUI 活点击（铅笔 hover、⌘↵ 焦点抢占）与 iOS 门控未活验，本轮不声称；编辑重发对 SessionPool 前缀缓存的失配代价未量（前缀变了自然失效，属预期）。

**10-12 输入门前刀 — drop / 粘贴 / 选文件三门口径统一，"Attach Files" 名副其实** — 缺口实证: `grep -rn "dropDestination|onPasteCommand" Sources/` = 0，且 `ChatView.pickImages` 把 `allowedContentTypes` 钉死 `[.png,.jpeg,.heic,.webP]`、`canChooseDirectories=false`，而按钮标签一直叫 "Attach Files"——手里是 `.py`/`.log`/`.csv`/`.pdf` 的用户没有门，只能手抄绝对路径，而 `read_file` 这三类都能原生读（含 09-28 PDF 文本层刀）。修: ① 纯策略 `Core/ComposerIngest.swift`（零 UI，一次 stat）按**引擎能消费什么**路由——图片走既有 `compressImage`→`ContentPart.image_url`；文本/代码/PDF/文件夹进 composer 文本的自描述绝对路径 token `" [Attached file] /abs/path"`（与既有 `" [Voice Input]"` 括号惯例同族，agent 用 `read_file` 自己开窗，UI 绝不二次 slurp 字节进上下文；不用尖括号——那是推理/工具标记专用），且同一路径不重复投递；② 三门共用漏斗 `ChatState.ingestFileURLs`（`.dropDestination(for: URL.self)` + `.onPasteCommand(of:[.fileURL,.image,.png,.jpeg,.tiff,.heic])` + NSOpenPanel），策略写一次、三门口径结构上不能再分叉；拖入选中纯文本 = 内容，不是拒绝；③ 诚实拒绝: 每条点名文件与理由（不支持类型 / 超 10MB 原始字节上限 / 不可读），替换原先 `catch {}` 静默吞文件；④ 面板可选类型**由策略派生**（`ComposerIngest.allowedContentTypes` 含 `.folder`），"面板给什么"与"引擎收什么"从此同源；⑤ HIG: 拖拽悬停时输入区现 dashed 描边 + 胶囊提示（拖放目标必须看起来像拖放目标）；⑥ 加 Edit ▸ **Paste Image or Files（⇧⌘V）** 兜底路（⌘V 常被 field editor 自己吃掉，⇧⌘V 永不与之相撞）。**验证**: `swift build --target ocoreai` exit 0（8.91s）；`swift test --filter 'ComposerIngest|ContextWindow|LocaleResolution'` **60 tests / 15 suites 全绿**（`ComposerIngestTests` 分类精确值 / 拒绝必须点名文件 / MB 精确渲染 / 漏斗 exact counts）。

**10-12 有效上下文窗口 — 模型自己声明的窗口成为预算（拍板项显式标注，未静默扩大）** — 缺口实证: 所有预算面（ChatView 水位 / `get_context_remaining` / 自动压缩 / 400 墙）只读 `EnginePool.getSamplingConfig(modelId:).maxContextWindow`，该值在人类发过 `PATCH {"max_context_window":N}` 之前恒为 nil，而 GUI 里没有这个入口；本机 `~/.ocoreai/models/mlx-community/gemma-4-e2b-it-4bit/config.json` 明写 `text_config.max_position_embeddings = 131072`，行为上却等于"容量不可知"——水位隐藏、模型被告知 unknown tokens left、压缩永不触发、超长 prompt 直撞引擎，而真值一直躺在磁盘和 `/v1/models` 上。修: ① 新增纯函数 `Engine/ContextWindowPolicy.swift`（覆写 → 声明 → 未知，provenance 随值走 `.requested`/`.modelDefined`/`.unknown`，镜像上游 `mlx-swift-lm` `KVCacheLayerStatus.CapacitySource` 同一 provenance 轴上移一层）；② `EnginePool.effectiveContextWindow(modelId:)` 用 `ModelStore.discoverReady()` 解析并缓存声明值，双 id 拼写（`hf:`/`huggingface:`/`mscope:`/裸 canonical）全命中，查找顺序由 `candidateKeys` 钉死，模型集变更时 `invalidateDeclaredContextWindows()` 清缓存（陈旧数字不得给重新下载的模型定容量）；③ `ChatHandler` Phase 3.5 与 `DirectInferenceClient` 两条 Fast Path 一律改读有效窗口，400 墙日志带 `windowSource`；④ 未知仍是未知，绝不编造默认。**验证**: `swift build` exit 0；`ContextWindowPolicyTests` 逐值钉死（嵌套 `text_config` 131072 / key 优先级 / 非正值不得 mint 成上限 / 覆写保留 provenance / Int64 溢出边界）。**未决（不静默替用户拍板）**: 继承声明窗口会 **arm** 两条此前惰性的面（规则压缩 + HTTP 400 墙），而 `Scheduler/` 只按 MB 记账（`AdmissionGate.swift:131`）从不给窗口尺寸封顶，于是 131072-token prompt 从此可达——"是否再加一刀本机内存夹逼"待拍板；09-28 已把该决策留给人，本轮做的是让它**可见可改**（见下条），而不是继续藏着。

**10-12 上下文窗口进 GUI — 看得见、说得清来源、改得动** — 缺口实证: `grep maxContextWindow Sources/ocoreai/UI/` = 0（窗口此前只能靠 `PATCH /v1/models/:model/sampling` 改），模型页只贴 `contextString`（"131K"）= **声明值**，一旦有人覆写就和实际预算悄悄不一致（本仓自称的 "wire liar" 类），水位条也只报 used/limit 而不报这 limit 是谁定的（上一轮自陈 open follow-up）。修: ① `ModelParamsView` 新增 **Context Window** 卡——值渲染 `"131K · from model"` / `"32K · set by you"`，留空即继承，hint 直接报出模型声明的具体数字（未声明则明说"设置后才启用预算"），落库走**既有** `SettingsStore.saveSamplingConfig` → `EnginePool.updateSamplingConfig`，零新机制，且 "Defaults" 语义 = 继承模型声明而非"无上限"；② `ModelManager.resolvedContextWindow(for:)` 转发 `EnginePool.effectiveContextWindow`，GUI 与引擎用**同一个解析器**（引擎未起 → unknown，不猜）；③ 水位条加来源小标，且仅当池报的窗口 == 正在计量的窗口时才贴（给错来源比没来源更糟）；④ 纯面新增 `ContextWindowPolicy.parseOverride`（`32768`/`32K`/`1M`/千分位；空、垃圾、≤0 一律 nil = 继承，绝不等价 0 token；超 Int64 拒而不 trap）、`shortTokens`（与 `ModelID.contextString` 同记法，同一个数不在两块屏幕上长成两个样）、`provenanceLabel`（未知 → nil，连标签一起消失）；⑤ i18n 新增 5 键 en/zh 双表齐备。**验证**: `swift build --target ocoreai` exit 0（8.91s）；**60 tests / 15 suites 全绿**（含 `LocaleResolutionTests` 的 en/zh 漂移门 + 新增溢出/记法/provenance 精确值套件）；`xcrun swift-format --configuration .swift-format` 二次运行零改动（idempotent）。诚实边界: GUI 活点击与 iOS 门控仍需 GUI 活体验，本轮未声称。

**10-11 schema 谎言二刀（官方 DMG 活体实证后）** — 下载 v0.1.12 官方 DMG（sha256 `ae3f4c82…` read-back 一致）、冷启动 `serve` 拉 `/v1/tools`：39 工具中 `info/skills_list/skills_lookup/skills_view/echo` 5 个仍 `properties:{}`——argsType 明有存储成员（topic/category/name/file+name/message），模型看不到键名只能瞎猜。10-10 修的是 update_plan 一条，其余从未进视野。逐工具补忠实 schema（必填精确到键：仅 `skills_view.name` required；`skills_lookup` 走"声明即必填"旧惯例；可选键 `required:[]` 如实为空），零参工具（curr_time/system_info/observe_state/get_context_remaining/check_tools/get_plan）空 schema = 真相，白名单锁死。新增 `BuiltinSchemaTruthTests`（生产同款 bootstrap，逐键精确断言 + 全 registry 谎言不变量：任何非白名单工具空 properties 直接红——未来新谎言物理拦截）。**验证**：活体复拉 + 3 套件聚焦测试 + 全门 `make test-clt`。

**10-11 CLI 信息面 + release 韧性双修** — ① **`--version`/`--help` 从物理上不存在的补上**（活体实证：0.1.10 二进制 `--version` 完整启动引擎——crash handlers/SQLite/memory tracker 全跑、永不回答，最终被 harness 击杀；HEAD 同）。`HeadlessMode` 当初只解了 `serve`，信息 flag 依旧无人解析。新增 `CLIMode`（`Core/CLIMode.swift`，纯分类器零 I/O）：`-v/--version` 打印 `AppInfo.shortVersion` 单一真值，`-h/--help/help` 打印只含真实行为的 usage（每个 env 名 grep 过 Sources 消费点：HOST/PORT/ENABLE_HTTP/API_KEYS/DATA_DIR/MODELS_DIR，零幻觉 flag）；入口先判信息 flag 再走原 serve/GUI 路由，`serve` 永不被截获（`Application.swift:27`）。**验证**：CLT 路 `CLIModeTests+HeadlessServeModeTests` 10 tests/2 suites 全绿；活体 `swift build` 二进制 `--version` 2s 内 exit 0，`serve` 回归无损（health_ok=1, SIGTERM exit=0, 'headless serve starting' 在日志）。CLI 测试断言全 let-bound 单行——CI swift-format 钉 603.0.0 vs 本机 main，多行 `#expect` 换行规则不同，单行两版不动。② **release 交付链韧性**（两次同点失败实证：v0.1.12 attempt1 run 38088968566 + attempt2 run 38124243007，annotations 同死 `ArtifactService/CreateArtifact Request timeout`——GitHub 容量事件，action 内部已重试 5×，重跑 job 进同一堵墙）。根修三分离：job-artifact 降级 `continue-on-error`（便利副本，永不拦截交付物）；publish 拆分 ceremony（release 元数据创建幂等 + asset 独立 3× 退避重试，走 uploads.github.com 而非死掉的 twirp ArtifactService）；read-back 哈希校验保持不变仍是最终裁决。**验证**：YAML lint 绿；v0.1.12 re-trigger run 38124243007 全 job 绿（含 DMG 构建），待本修复 push 后的新 tag/release 轮闭环。

**10-10 drift round 9 — LM `a1f575d→7eb77ef`(+12, pin bump) · CA `1953c4f→52dbd93`(+5, transparent adopt) · CX `18e28fe→c3d3b14`(+149, transparent adopt)** — 问答触发审计："ocoreai 保留三参照原汁原味了吗？"答=机制原味（上游 pin 零 fork、逐条 drift 裁决制度化），但 LM 轴停 10-07 已落后 3 天——当场补齐。① **mlx-swift-lm（SPM 轴，bump `Package.swift:41` `a1f575d→7eb77ef`）**：#663 Qwen reasoning history 修正 + #672 causal LM hidden-states/logits 投影分离 = 正落我方热路径（`ChatSession` 直接构造 `LoadedModel.swift:481`/`SessionPool.swift:289`，`generate`×33/`loadModel`×8/`GenerateParameters`×10 grep 实证原生 API 正门消费）→ 透明受益即采纳；#623 GLM-4 markerless tool-call / #627 Qwen3VL PreparedInputSplitting / #662 Qwen3.5 VLM compiled decode / #633 GDN eps / #654+#685 EmbeddingGemma / #641 ChatSession fork / #680 scripted Tokenizer / #675 Gemma4 softcap——消费面 grep（`GatedDelta|GLM|scripted|\.fork(`）全 0 → transparent。② **coreai-models +5（参考轴，无 SPM 链接）**：#269 stop-token 统一、#320 cosineSimilarity parity helpers 合并——我方 `cosineSimilarity` 是本地私有实现（`SemanticSearch.swift:159`），上游是 Python/swift 参考仓库 churn；#333/#336 ruff CI 纯 Python；#269 KV-cache 函数化待 macOS 27/CoreAI 轴唤醒才有消费点 → transparent。③ **codex +149 纯参考轴**：零链接（`grep codex Package.swift`=0），保留的是产品形状（审批 banner/exec_command 名/intersect-before-constrain/失败直出原文），永不污染编译面。**验证**：`swift package resolve` checkout `7eb77ef` 实证；CLT `build-tests` 76.4s RC=0；**全量测试 2124 tests / 397 suites 全过（396s，+120 tests/+24 suites 相对 round 8 的 2004/373——测试面自身在长）**。**结论入账**：原汁原味=制度化（upstream pin + 逐轴裁决 + 零 fork），本轮关闭 LM 轴 12-commit 缺口。

**10-07 drift round 8 — LM `ecd8e88→a1f575d`(+3, pin bump) · CA `61a1b2f→1953c4f`(+1, transparent) · CX `822e58c→18e28fe`(+65, transparent adopt)** — 逐轴裁决：① **mlx-swift-lm（SPM 轴，bump `Package.swift:41`）**：#670 tokenizer flush（streaming 结束冲刷 held text——我方 detokenizer 是自有实现 `TokenizerManager.swift:33`，但热路径走 `engine.generate()`(EngineInference:359)/`MLXLMCommon.generate()`(:3505)，上游内部 flush 修正经该路径透明受益，正是"复杂度住上游"的正例）；#671 GLM4MoELite quantized KV——本机模型池零 GLM、Sources grep 零 → transparent；#625 perf tool end-tag scan——上游 `ToolCallProcessor` 内部，我方 `OpenAIModels.swift:497` 仅 mirrors 语义注释零直接调用 → transparent/perf 受益。② **coreai-models #332**：Gemma 4 PLE sidecar → `metadata.json` `auxiliary_assets`——我方 metadata 消费只读 `assets` 键（`CoreAIEngine.swift:508`），`auxiliary_assets|sidecar|PLE` grep 全 0；且 CoreAI bundle 池本机为空（macOS<27 轴休眠）→ transparent。③ **codex +65 纯参考轴**：Guardian v2 review/subagent forks/shell snapshots——全落 codex 自有 Rust 内部（SPM 零链接实证 `grep codex Package.swift`=0；multi-agent 轴 09-29 已裁"主动排除"），0 强制缺口。**验证**：`swift package resolve` → checkout HEAD `a1f575d5d` 实证（github.com:443 掐断窗口经 mirror `insteadOf` SSH 通道 fetch 成功——push transport fork 规则再证）；CLT `swift build` RC=0。**运输插曲**：api.github.com 未认证限额 60/h 当日耗尽（GFW 模式：git/codeload 死、api 半活），drift 脚本三轴 api 失败跳过 = 已知诚实降级，裁决真值改由 SSH git fetch 取得。

**10-06 工具面单一真值集（P0, `09005a2`）** — wire 客户端声明未注册工具名（`shell`/`terminal`；真名 `exec_command`）触发三层真值分裂：grammar 按 raw wire tools[] **强制**产 tool-call ↔ session.tools=whitelist(registry∩declared)=0/39 注入 ↔ 上游每轮 `undeclared_tool` 拒绝 → recovery 耗尽 → 模型已产出的正确调用被吞、wire 答案变废话（实测 `'I understand. I will await…'`）。修法：intersect-before-constrain——`grammarSchema`/`hasNativeTools`/`declaredToolNames` 全部改由 `executableTools = registry∩declared` 导出；交集空→tool-guided 关闭（无工具可执行时强制=必然死路）；dropped 名进可行动 warning。四面活体验证（实例 E）：`shell`/`terminal`→dropped 无死循环；`exec_command`→1/39 注入真实执行、headless fail-closed 拒、模型如实引用拒绝零编造；`read_file`→**多轮 agentic loop wire 首次闭环**：结果回喂、二次决策逐字复述防幻觉标记 `marker_7391_roundtrip_ok`。CLT 2004/2004 绿。

**10-06 embedding 冷加载熔断（"natively local" 网络失败面首修, `1908488`）** — HF 不可达活体复现（`hf.co=000` vs `api.github=200`）：EmbeddingService 容器 lazy → 每条 GUI 消息 fire-and-forget `embedMessage` 重跑双候选 HF 下载超时（实测每消息 ~6s 网络等待 + warning 风暴 ~3s/条持续数小时, C.log 26+ 条）。修于唯一咽喉 `ensureContainer()`：全候选失败→开闸 300s（窗口后自愈探测），成功→关闸；消费面零影响（`embedMessage` 走 `try?`，消息照常入库仅缺向量，语义检索优雅降级——`SemanticSearch.search()` 调用点全为模型目录/文件工具，不经 EmbeddingService）。+5 exact-value 纯谓词测试（含窗口边界）。**验证**: CLT 全门 `2004 tests/373 suites passed, 0 fail, 214s`（唯一 ✘ 字形 = config-recovery 故意 warning, skill 已记载假阳性）。同轮排除两案:① 89034 凌晨退场 = AppKit 干净 `Termination complete`（终端会话回收, 非 crash/jetsam, 环境物理）② `rejected tool call attempt 1/3 tool=nil` = 上游 by-design（ChatSession.swift:1439 `failOnRejectedToolCall||toolDispatch!=nil` 抛）+ 三角实测 0/9 不可复现 plain-session 污染——bounded recovery 单 pass 代价，wire 答案正确，不追。

**10-05 Recover 活体验证轮（零代码变更，纯证据入账）** — 产品定义 `Execute→Verify→Recover` 的 Recover 段首次 live 闭合，单实例实例 `pid 89034`（二进制 @abe885b）:① **诚实失败恢复** — `web_search` 后端离线，registry 日志 `Tool call: web_search — success in 3.3ms`（执行层不抛、快速失败返 error 文本，`WebSearchTool.swift:16` 失败诚实契约兑现），wire 上模型原文引用 `error: search backend offline` 并明确拒绝编造（"我无法提供…因为工具执行失败了"）→ 失败不造假 = Recover 的底线行为成立。② **工具结果 byte-exact 回填** — 预置唯一标记 `紫色恐龙在跳舞-恢复测试-2247`（pbcopy 于 22:47），`read_clipboard` 往返后模型逐字复现含生成时刻的时间戳 — 模型不可能凭空获知，闭环自证。③ **HIG 审计销账** — 字号 36 处全语义 text styles（.caption×21/.title×8/.subheadline×5/.callout×1/.headline×1），硬编码 size 仅 1 处 11pt（AppKit smallSystemFontSize 徽章 = Apple 官方面板同款）；硬编码色值 0；AX 标注 102 处;DynamicType 缺口 = macOS 桌面语义（NSFont 体系）天然覆盖,iOS 面待 app target。**观察入账（不追）**:无 tools 请求上出现 `rejected tool call attempt 1/3 incomplete_output` detection 假阳性,落 prose 无害——tools-less 请求不应进 tool-call 检测路径,留待 ChatHandler 检测门细化。【10-06 复核修正:非假阳性检测——引擎全量注入 39 工具（EngineInference.swift:2266 local-first 契约）+ 上游 ChatSession.swift:1439 `failOnRejectedToolCall||toolDispatch!=nil` 按文档设计抛；小模型偶冒 tool-open token 被截断→bounded recovery 多跑一 pass,wire 答案实测正确。by-design,销案。】**签名轴物理前提**:钥匙串 `0 valid identities` — 公证/开发者 ID 需 Apple Developer 账号 enrollment（用户在场）,脚本 `OCOREAI_SIGN_IDENTITY` 分支已就位。

**10-05 round 7 drift 真检出 + 通道根修 + HardwareRouter 归因日志修正** — ① `scripts/upstream-drift.sh`: 无 `gh` 主机三源全静默 skip（覆盖缺口，10-05 实测踩中）→ 新增 `api()` gh/curl+python3 双通道回落（未认证限额 60/h，全程 ≤15 req）。② 修通后首次真检出 `LM +12 / CA +7 / CX +215`，逐轴裁决：LM 12 条 = mlx-swift `exact 0.32.3` 已满足 #657 硬约束 + #642 MTP/#650 WHT/#667 Metal sync 全为上游内部实现（消费面 grep `WHT|fusedGDN|argmaxFloat|rerank|Segmentation` 全 0 穿透）；CA rename 轴（`LanguageBundle→LanguageModelBundle` 等）在 HEAD 时点已于 10-05 早轮完成注释锚点上移，无新代码穿透；CX 215 条纯参考轴（TUI/rollout/Windows/multi-agent Rust churn，SPM+Sources 引用零）。adopt 三轴基线。③ `EngineInference.swift:1499` 路由日志改用 `queryWithState`：CPU 移位日志此前只打 GPU 分数（`gpu: 0.0/70.4 GB`），真实触发是 Tier-1 内存压力（本机 119/128GB）——误导性归因耗掉一轮排查，现日志携带完整 `hwState`（thermal/mem/GPU/cores）。**验证**: `bash -n` ✓、`swift-format` 零 diff、drift 脚本 adopt 后实跑 exit 10→adopt→绿。

**10-05 主轴消费：mlx-swift-lm `0dcfe2f→5e46681b`（12 commit）** — 窗口内容逐 commit 审计: #642 MTP weights（ speculative decoding 权重装载，我方 omlx 侧 DFlash A/B 同域）、#650 WHT quantization、#657 + #667 `synchronize`（与在跑 PR #657 同号同域 — attention fast-path）、#628 fused attention 后续、3× docs/CI hygiene。我方消费面 grep：无 API 改名穿透。验证：`swift build` CLT 路 736/736 ✓；`swift test --skip CoreAI/Metal/Kernel/Inference` 203✔/0✘ 至已知 metallib 墙（CLT 无 Metal，非回归）；`.upstream-baseline.json` 三轴同步记账（CA `3efa838→52c84ba8` 7 commit — #306 `PipelineDescriptor→DiffusionBundle`/`DiffusionPipeline→ImageDiffusionPipeline`、#307 `LanguageBundle→LanguageModelBundle`、#318 `argmaxFloat`、#301/#302 Gemma4 iOS — 我方 `LanguageBundle` 命中全部为注释引用（`CoreAIEngine.swift:710/746`、`VLMBundleDetector.swift:6-63`），代码零穿透，注释锚点上移为 `LanguageModelBundle`；codex `bcd6d9ab→7f892275` = 209 commit 纯参考轴，TUI(33)/rollout(22)/Windows(16)/multi-agent(8) churn，SPM 依赖与 Sources 引用均为零，吸收轮待专项）。**验证边界**: 完整执行门 = CI（macOS-14 runner 已确认可用，扩矩阵待批）。

**10-05 本地测试门三分叉根修 + mlx-swift 0.32.3 启动崩溃修复（macOS/iOS <26.4）** — 五条独立验证链:① **`cdba6a6`** testTarget 硬编码 CLT `-F` unsafeFlags 移除 — Xcode 27 libTestingMacros 展开 `__SourceBounds` vs CLT Testing build 1902(`nm` 0 符号)= 454 编译错全目标死;移除后 `swift build --build-tests` **EXIT=0**、`make test-ci` TEST BUILD SUCCEEDED。② **`dc5ba91`** test-ci 注释修正 — macOS<27+Xcode27 主机上 SDK27-only 二进制 weak-link CoreAI.framework,`xcrun xctest` 在 `realizeAllClasses()` 启动期 SEGV(Error 139,`--filter`/`#available` 皆 post-realize 无解);本机 xcodebuild 路径自此不是完整门,全量执行=CI(ci.yml:148-152 MetalToolchain)。③ **`ed511de` `make test-clt`** — CLT(SDK 26.5,`canImport(CoreAI)=false`)26-native 部分门,call-site `-F`+双 rpath(Testing 1902+lib_TestingInterop 实测在 `CommandLineTools/Library/Developer/usr/lib`);**首次本机真执行 326 ✔/0 ✘**(clt-test6)后死于 lazy metallib(CLT 无 Metal 编译器,`xcrun -find metal` 实证缺)。④ **`bf17bfc`** PlanCard `#Preview` 注释化(对齐仓内 4 处先例,CLT 无 PreviewsMacros)。⑤ **`0401256`** mlx-swift `exact 0.32.2→0.32.3` — 上游 0.32.2 release notes 首行 "Use release 0.32.3":link 0.32.2 的 app 在 macOS/iOS **<26.4 启动即崩**(#491/#493),直接否定 Package.swift:8-9 的 macOS 14/iOS 17 声明;LM 约束 `.upToNextMinor(from:"0.32.2")` 天然满足零连锁。**验证**:`swift package resolve` → mlx-swift@`19601207`(0.32.3);Xcode 27 `xcodebuild -destination generic/platform=iOS` **BUILD SUCCEEDED**(0.32.3 iOS 面);CLT 二进制 `vtool` minos 14.0/sdk 26.5/`otool` CoreAI=0 引用。**诚实边界**:本机从未同时拥有 SDK26+Metal→单路全绿不存在,CI 权威不变;5 commit 待 push(钥匙串需用户在场)。

**09-30 round 6 drift 裁决 — LM `0dcfe2f` 0 new · CA `3efa838` 0 new · CX `90abcfac→bcd6d9ab` +1(`#49489`,transparent adopt)** — `bash scripts/upstream-drift.sh` 三轴复检:mlx-swift-lm/coreai-models **与基线同点**(0 drift,无 bump)· codex +1(`#49489` Add regression coverage for account switches between analytics batches)。**逐文件裁决 = consumer-transparent**:3 改动全落 codex 自有 Rust 内部轴 — `codex-rs/analytics/src/client_tests.rs`(+108,analytics account-switch 回归测试,`auth_mode=chatgptAuthTokens`/`chatgpt-account-id` 头断言)、`codex-rs/core/src/tools/registry.rs`(删 1 行 unused import `ToolCallSource`)、`codex-rs/login/src/internal_identity.rs`(删 1 行 diagnostics 文件)**——0 Swift、0 ocoreai API 消费面**(双根 `analytics|account.?switch|auth_mode|registry|internal_identity` Sources+Tests 全 0 ocoreai 生产面命中)。**adopt**:`.upstream-baseline.json` codex `90abcfac→bcd6d9ab`(LM/CA 基准不动)。**验证**:零 Swift 生产面变更(纯 adopt),门复用 round 5 `eba9243` CI 6/6 真门绿;adopt 后 drift 复检三轴 **0 new**。

**09-30 round 5 闭环 — test 目标 #535 断裂修复(CI 真门实证) + CA `e1df4c8→3efa838` `#303` 吸收 + CX `ab84d71f→90abcfac` +13 adopt** — 三件事:① **`f7036b5` 前置:CI `5b83e5c` 两 job (macos-26 + macos-26-beta) 同因失败根因修复** — #535(`UserInput.Image/Audio/Video` enum→`struct{source}`)源码断言,断裂点 **6 处全在 `PerceptionMediaDeliveryTests.swift`**(旧 `if case .ciImage/.url(let u)` 枚举模式匹配 → 走 `.source`;Optional 场 `img?.source` / `result.audio?.source`)。教训:`swift build` 不编 Tests + 陈旧 DerivedData = 假绿,**CI 干净编译才是真门** —— 消费面裁决必须扫 Sources **+ Tests**。顺修 3 处 bump 暴露的 latent warning(LLM `tokenizer` 非 throwing:`try→await` + `_ = try getOrCreateGrammarTokenizer`(该 fn 实证 `throws`,try 保留)/ `sampler.encode` 非 throwing 删 `try` / `URL(string:)` 非 throwing 删 `try?`)。**验证**: `swift build --build-tests` RC=0 + `make test-ci` RC=0(测试目标重编全绿)· `f7036b5` push + CI。② **CA `#303` 吸收(语义对齐,非编译 break)** — 上游**主动移除** `.aimodelc` 静默回退(metadata.json 必须命名实际出盘文件;编译版由用户显式改 metadata,静默找兄弟文件被删;`verify()`→`verifyAssetsExisting()`、`missingAsset(key:path:)`→`(key:url:)`)。ocoreai **非** SwiftPM 依赖 coreai-models(0 API 消费面,不破坏编译)但 in-tree 镜像了两处静默回退:`VLMBundleMetadata.componentPath`(L83-93)+ `PreparedModel.resolveCoreAIModelURL`(CoreAIEngine L482-525)—— 按「上游已解决→吸收;本地自研=偏差」铁律**两处回退全删**,metadata 声明文件即实际加载文件、缺失由 `requireComponent` 抛精确 load error。**测试同步翻转**: `VLMBundleDetectionTests.componentPathCompiledFallback`(原断言回退命中 `.aimodelc`)→ `componentPathCompiledFallbackRemoved`(同 fixture 断言 **`nil`** — 回退已移除,行为变更由测试锁定);`ANEVLMFactoryRoutingTests` 注释同步。生产实况不受影响:`CoreAILiveAimodelcBundleTests` 显示 bundle 的 metadata 声明 `.aimodel` **且该文件在盘**(回退非承重,只是兜底)。**验证**: build-tests RC=0 + `make test-ci` RC=0(3 受影响测试全过)。③ **CX +13(`#49424..#49475` + `#49478/#49480`)全 transparent,adopt** — 13 条全落 codex 自有轴(Windows UNC 路径 `#49424` / log-prune `#49425` / daemon analytics `#49426` / bootstrap-auth `#49432` / TUI 音频设备 `#49437` / retry-advice `#49441` / JSONL `memrchr` `#49444` / login-shell path `#49467` / server-authoritative 权限 TUI `#49472` / rmcp enterprise-token `#49473` / turn-abort 回调序 `#49475` / MCP auth-server 发现 `#49478` / thread-prediction protocol `#49480`);双根消费面扫全 0:retry 轴 ocoreai 自有 429 `RateLimitMiddleware`(独立实现,非 codex 协议消费)/ `MCPBridge`-`MCPStdioClient` 2 处 `rmcp` = **注释假阳性**(provenance 标注)/ turn-abort / server-permission / thread-prediction 全 0。**基线**: LM `0dcfe2f` · CA `e1df4c8→3efa838` · CX `ab84d71f→90abcfac`(轮询期间 +2:90abcfac,#49478+#49480 一并纳入)。

**09-30 D1 release-warnings 批次 — ocoreai Sources/ 35+ warning 全清(零行为变更)** — `swift build -c release`(优化开启)首轮实证 ocoreai 自研面 **35+ warning**(150 总数里 147 为 mlx-swift C 头 `static_assert` 生成噪声、2 SPM 信息性,非我方可修;真可清集 = ocoreai Sources)。逐 site 编译器诊断取真值 + 上下文核验,分四类修:**① 死变量删** — `DirectInferenceClient.capturedChannel`(write@channel 事件,0 read)/ `CoreAIPipelinedEngine.resolvedSize`(声明后无消费,非「分支消费」误判)/ `warmupStart`(唯一消费者 `warmupElapsed` 已删)/ `StateHandler.isDynamicKV`(恒真分支)/ `FMToolBridge` 冗余 `guard-let-nil` 回退分支。**② 冗余算子/级联收敛** — `CoreAIPipelinedEngine.existingTemp ?? 0`(分支内已 unwrap 成非 Optional `Double`)/ 错误串 optional 插值 `\(temperature)`→`\(temperature ?? 0)` 显式 / `OpenAIModels errorDescription as Any`→直接(已 `String?`)/ `ConfigRecovery try decode(at:)`→`_ = try`(只取 throw-safety)/ `ChatViewModel withJSONObject: v`→`v as Any` 显式箱(**`v` 实为 `Any?`,前次删 `as Any` 误,已实证还原**)/ `MPSGraphSamplers guard let penaltyPlaceholder`→`!= nil` / `ConversationCompaction region.reduce(0){...}` 加括号消尾闭包歧义。**③ 冗余 `await` 删(编译器证 UnnecessaryEffectMarker — sensor 已同步非隔离)** — `NetworkSensor.update`/`InternetSensor.contextText`+`isReachable`/`SpeakerFeedbackSensor` 两读/`PerceptionEngine` 4 处 sensor 读/`SpeakerFeedbackSensor` 读 — 全部 `#main-actor 已满足` 证明 `await` 多余。**④ switch 穷尽 + `var→let`** — `KVCache.mpsDataType` `@unknown default` 对 non-`@frozen` 不解决穷尽 → **plain `default`**(前次误加 sub-byte case 已回退)/ `CoreAISequentialVLMEngine var destView`→`let`(2)/ `SessionPool for (key,entry)`→`(_,entry)`(key 未用)。**⑤ 冗余 `guard #available` 删** — `RealVideoBackend.generate` 外层已 `@available(macOS 27.0, iOS 27.0, *)`(L150 实证),内层 `guard #available` 恒真,编译器 Unreachable 证之;`case .ok` 未用绑定 `url/frameCount` 收敛为 `case .ok`。**修中纠错(诚实边界)**: 前轮 3 处误判已按编译器真值修正 — (a) `resolvedSize` 非「分支消费」实为死,删;(b) `KVCache @unknown default` 不解决 non-`@frozen` 穷尽 + 我猜的 sub-byte case 名不属实,退 plain `default`;(c) `ChatViewModel v` 实为 `Any?`,前次删 `as Any` 为误,还原显式箱。**验证(全实跑)**: `swift build`(debug) **RC=0, 0 ocoreai 源 warning/error** · `swift build -c release` **RC=0, ocoreai Sources/ warning = 0**(150→0 自研面;剩余 147 mlx-swift C 头 + 2 SPM 非我方可修)· `make test-ci` **2138 tests / 395 suites 全绿 RC=0** · `git diff --stat` 18 files +53/−71,逐 hunk 核对零行为变更(仅删死码/去冗余/消歧义)。AGENTS.md / wiki 无相关行需更新(D1 属打磨非上游 drift)。**CI**: 本轮 commit 待 push 后 GH 门确认(前三 `f7197eb`/`f701336`/`d7d4b3c` 均 success,含本基线 `d7d4b3c` 刚 completed success)。

**09-30 上游 drift 裁决闭环(round 4b — LM `c043fb3→0dcfe2f` +2(#535 `#653`,0 ocoreai 消费面,bump lm pin)· CA `e1df4c8` 0 drift · CX `eefe0ce1a→ab84d71f` +3(#49414/49415/49416,全 transparent,adopt))** — `bash scripts/upstream-drift.sh` 复检三轴:**mlx-swift-lm +2(#535 named image / #653 tool schema bool→Swift Bool)**——#535 将 `UserInput.Image/Audio/Video` 从 enum 重构为 `struct{source}`;ocoreai 仅在 `makeMLXImage/Audio/Video` free fn 中 **构造** `.ciImage(...)/.url(...)` 静态兼容构造器(未 `switch` 旧枚举 case,双根 `case \.?url\(|case \.?ciImage|case \.?data\(` 全 0),故 consumer-transparent;Package 已 bump `c043fb3→0dcfe2f`,`swift build` RC=0、`make test-ci` RC=0(2138/395 全绿实证)。#653 = `ToolCallingConversions.unboxingBooleans` 内部 helper(swift-jinja Int-before-Bool 修复),ocoreai 无 swift-jinja 消费面,transparent。AGENTS.md 审计行(round 4 `ceea671→eefe0ce1a8` 6 commit 补录)同轮 patch **待用户在场轮**走审批门(cron/无交互轮被 agent-instruction-file 保护门拦截,未绕门),同 09-27/09-28/09-30 round-3 已落模式。

**09-30 上游 drift 裁决闭环(round 3 — LM `c043fb3` 0 drift · CA `e1df4c8` 0 drift · CX `bd4204e→ceea671` 5 commit)** — `bash scripts/upstream-drift.sh` 复检三轴:**mlx-swift-lm 0 新 commit**(pin = origin/main = `c043fb3`,0 drift,无 bump)· **coreai-models 0 新 commit** (= 基线 `e1df4c8`)· **codex +5**(`#49384/#49388/#49389/#49392/#49395`;初检 4 条,adopt 时上游再推进 `#49395`,窗口 4→5 一并裁决)。**codex 5 commit 逐条 consumer-transparent 双根全扫(Sources/ + Tests/)= 5/5 transparent,0 强制缺口,0 ocoreai 生产面变更**——全落 codex 自有轴:① **MCP OAuth credential-storage 轴**(`#49384` credential load/save/delete/fallback-file 结果 + secure-store 失败 redaction · `#49392` MCP OAuth 存储 telemetry/policy/pinned-store/client attribution)——ocoreai MCP = **tools-only stdio**(`Sources/ocoreai/MCP/` stdio 6 文件,0 `oauth|keyring|token.?refresh|secure.?store|pinned.?store|storage.?policy|originating.?client` 命中);Sources 2 处 `credential` = **假阳性**(`SettingsViewModel.swift:420` Hub-token「sensitive credentials」注释 + `ModelDownloadHandler.swift:164` 下载凭据注释,均非 OAuth/keyring storage)。② **codex Windows 路径/sandbox 轴**(`#49388` UTF-16LE opaque-URI slash-prefix vs POSIX root 区分 · `#49389` Windows sandbox 共享 elevated 账户 file-lock 串行化)——ocoreai = **macOS-only SwiftUI**,双根 `UTF-?16LE|opaque.?URI|UNC.?prefix|Windows.?(drive|namespace)|elevated.?account|Nextest` **0 命中**(Tests 4 处 = **假阳性**:`NDArrayHelpers.prefixCount` + `ModelIdentity.prefixedId*`,`prefix` ≠ Windows-path);sandbox 轴 0(09-27 `#48565` seatbelt 全仓 0 命中同判)。③ **codex TUI 渲染轴**(`#49395` 移除会话头 randomized greeting,raw header 统一含 `model:`/`directory:`)——ocoreai = SwiftUI 活体 GUI,双根 Rust-TUI 标记 `crossterm|ratatui|session.?(header|banner)` **0 命中**;Sources 2 处 `greeting` = **假阳性**(`ComplexityAnalyzer.swift:402/481` 是**输入复杂度分类器的「Casual/greeting」类别标签**,非 TUI 会话头 greeting)。**结论 5/5 consumer-transparent,0 强制缺口,adopt only(无 Swift 生产面变更,无 build/测试门)**。**adopt**: 三轴基线 → LM `c043fb3`(不变) / CA `e1df4c8`(不变) / CX `bd4204e→ceea671`(`.upstream-baseline.json`,`bash scripts/upstream-drift.sh adopt`)。**验证**: adopt 后 `bash scripts/upstream-drift.sh` 三轴 **0 new / EXIT 0**(实证);ocoreai 树零 diff(仅 `.upstream-baseline.json`),纯基线状态轮无 build/测试需求,前置 `f701336` 门(2138/395)已绿。AGENTS.md 审计行(round 3 `bd4204e→ceea671` 5 commit 补录)同轮 patch 被 **Hermes agent-instruction-file 保护门拦截**(cron 无交互审批,`OS W_OK=True` 但 tool 层拒,**未绕门**),待**用户在场轮**补录 AGENTS.md line 129 codex 语义轴行(`1cc7e2361→ceea671` + round-3 5 commit 逐条明细),同 09-27/09-28 已落模式。

**09-29 上游 drift 二轮裁决闭环(同日复查) — LM `c043fb3` 0 drift · CA `4192217..e1df4c8` (#298) · CX `7e049b3..bd4204e` (10 commit)** — `scripts/upstream-drift.sh` 复查窗口:**mlx-swift-lm 0 新 commit(pin=origin/main= `c043fb3`,mlx-swift 0.32.x 线 tag 仍仅 `0.32.2`)** · **coreai-models +1(`#298` Remove Stable Diffusion support)** · **codex +10(`#49330/#49332/#49339/#49345/#49353/#49357/#49360/#49361/#49369/#49379`)**。**coreai-models `#298` 裁决 = transparent**:commit 删除 StableDiffusionPipeline/SD3Pipeline/PNDM+DPMSolverMultistep 调度器与 stable-diffusion* PipelineType 案例;commit 消息明断「**FLUX.2, Sana/SanaSprint, and Wan are unaffected**」,且默认调度器改 discreteFlow(=ocoreai 已吸收的 `DiscreteFlowScheduler`)。双根实证 ocoreai 消费面 **0 命中**:`StableDiffusionPipeline|SD3Pipeline|PNDMScheduler|DPMSolverMultistepScheduler|stable-diffusion-15|stable-diffusion-35` 全 0;ocoreai video 轴 = **Wan 2.1**(`Sources/ocoreai/Video/{DiscreteFlowScheduler,WanPipeline,Wan21VideoContract}.swift` in-tree 衍生,不依赖上游已删的 SD 符号)。#298 是上游「删自己」而非「改共享面」,ocoreai 0 改动, **adopt only**。**codex 10 commit 双根全扫 = 10/10 transparent**:全落 codex 自有轴(hook matcher 编译 `#49379` · multi-agent V2/Bedrock GPT-6 目录 `#49369/#49345/#49339` · credential 文案 `#49361` · shell invocation metadata `#49360` · blockquote paste `#49357` · filesystem 审批 `#49353` · exec-server RPC 取消 `#49332` · remote reconnect backoff `#49330`);ocoreai 侧 grep 全 0——唯一近邻命中: `ExecTools.swift:14` 「user mandate: no multi-agent surface」(ocoreai **主动排除**multi-agent 轴,与 #49369/#49345 反向)、`SettingsStore/App/MLXBridge` 的 env-first keychain 注释(ocoreai 策略 = 不用 keychain token,与 #49361 无关)、`ModelScopeDownloader` 的下载重试 backoff(网络轴,与 #49330 的 remote-control reconnect 非同轴)。**0 强制缺口, 0 生产面变更, adopt**。基线 → LM `c043fb3`(不变) / CA `e1df4c8` / CX `bd4204e`(`.upstream-baseline.json`)。**验证**: ocoreai 树零 diff(纯 adopt);本轮无 build/测试需求(无 Swift 变更),前置 `f701336` 门已绿(2138/395)。

**09-29 上游 drift 裁决闭环 + mlx-swift-lm `#646` 吸收 + 2 轴 transparent — `ee673d6..c043fb3` (LM) · `e7b24da..4192217` (CA) · `1cc7e2361..7e049b3` (CX)** — 三轴 `bash scripts/upstream-drift.sh` 检出新窗：**mlx-swift-lm +1（`#646` pick up mlx-swift 0.32.2）** · **coreai-models +1（`#291` Update Core AI Wheel Versions）** · **codex +36（`#48895/#48973/.../#49097/#49098/#49099/#49100/#49102/#49103`）**（codex 在审计窗口推进至 `7e049b3`，全 36 已逐条裁决）。**mlx-swift-lm `#646` 裁决 = 强制 gap（bump 修）**：lm `#646` 把自身 mlx-swift 约束从 `.upToNextMinor(from:"0.31.6")` 抬到 `.upToNextMinor(from:"0.32.2")`，而 ocoreai `Package.swift` 直 pin mlx-swift `9019419`(=0.31.6+22, 0.32.2 tag `2b5e877` 的**祖先**)——两者同 pin 同一 package 必须同轨，否则 SwiftPM 解析失败。lm `#646` 自有 `Stream()→Stream.defaultStream()` 改名仅在其 `Evaluate.swift`(3 处)+`CancellationTests`+`concurrency.md` skills 参考文档，ocoreai **0 触**。ocoreai 直接 MLX 消费面 grep 双根全扫：`import MLX`(5 文件 App/LoadedModel/MLXBridge/EngineInference/EngineInferenceSupport) + 实际 API 仅 `Stream.gpu.synchronize()`(`EngineInference.swift:3331`) + `result.eval()`(`MLXBridge.swift:1094`)——2 API 在 0.31→0.32 双稳定（`Stream.gpu` 是 static 存根、`MLXArray.eval()` 是基础方法），0 消费者 `withNewDefaultStream|Distributed|convolve`。mlx-swift `9019419..0.32.2` 增量 = `cd36d17`(#476 mlx-c custom-io: I/O callback 返回值语义收紧)+`2b5e877`(tag 收口)；ocoreai 直接消费 `MLX` 但**不**消费 Cmlx 层 Cmlx custom-io 回调——`import MLX` 是 Swift 侧 API。**修**：`Package.swift` 双 pin 同步—lm `ee673d6→c043fb3`、mlx-swift `9019419→2b5e877`(=0.32.2 tag)；Package.swift pin 注释同步消费面审计 + bump 理由。`Package.resolved`×2 同步重解。验证: `swift build --target ocoreai` exit 0（41.82s, mlx-swift-lm c043fb3 + mlx-swift 0.32.2 双新 pin 解析成功+编译过）；`make test-ci` = **2138 tests / 395 suites passed, 44.77s（exit 0）**——LM 从 2080→2138 测试增量 = lm `#646` 引入的 KVCache/Sample 新测试面全过，零回归。`FMToolBridge.swift:135` `[String:any Sendable]` → `[String:Any]` 警告 = 本地参数形 `json: [String: any Sendable]`(ocoreai 自有代码) 的 Swift 协变固有 warning，与本次 bump **无关**（该函数签名 `tryToBuildSchema(from:name:logger:)` 在 bump 前已存在，bada388 引入；0.31→0.32 未改 `[String: Any]` 协变契约）。**coreai-models `#291` 裁决 = transparent**：`git show 4192217 --name-only` 27 文件全在 `models/*/export.py` + `python/` + `uv.lock` + `skills/`——**0 `.swift` 文件**。ocoreai in-tree 衍生走 **Swift SDK 侧**（Apple CoreAI.framework 系统 framework，CoreAI 14 .swift 在 Engine/），上游 wheel 版本 bump = Swift 侧无关消费面，**consumer-transparent**。**adopt only**。**codex `1cc7e2361..7e049b3` 36 commit 双根全扫裁决 = 36/36 transparent**：全落 codex 自有轴（Guardian review 子系统 6 commit `#49036/#49038/#49057-49065` · SQLite pool/vacuum 3 commit `#49032/#49069/#49102` · app-server running-turn `#49084` · plugin/HTTP pool 2 `#49099/#49100` · Windows PowerShell sandbox `#49098` · TUI 渲染 5 `#48895/#49037/#49041/#49083/#49082` · compaction lifecycle `#49097` · Bazel 构建 3 `#48974/#48976/#49103` · 消息复制 2），双根全扫实证 ocoreai **0 消费**：`guardian|handoff.?aware|reviewAgent|guardianHistory` → 仅 `ApprovalTests.swift:453` provenance-注释引用 codex #41846（非同轴, ocoreai `ApprovalBroker` 走审批态轴）；`auto_vacuum|incremental_vacuum|freelist|wal_autocheckpoint` → 0（ocoreai `SQLiteStore` 单连接非 pool）；`runningTurn|threadWatch|runtimeByThread` → 0；`plugin.?manifest|pluginWorkflow|ConnectionPool` → 0；`mermaid` → 0；`usage.?limit.?notif` → 0（ocoreai `ConversationCompaction.compact` = 纯函数, `ApprovalTests` 已钉纯函数不变量 ≠ codex turn-lifecycle ext）。**36/36 consumer-transparent, 0 生产面变更, 0 强制缺口。** **adopt**：三轴基线 → LM `c043fb3` / CA `4192217` / CX `7e049b3`（`.upstream-baseline.json`，`bash scripts/upstream-drift.sh adopt`）。**AGENTS.md 审计行补录 pending（用户在场轮）**：4 处 patch 全被 Hermes agent-instruction-file 保护门拦截（cron 无交互审批），OS 级 `W_OK=True` 但 tool 层拒——同 09-28 09-22 已落模式（见 CHANGELOG 09-28 codex 26 commit 条目尾注 + 09-28 用户在场轮 `98fcbc5` 实际补录先例）。本轮未绕门（AGENTS.md 保护性铁律 + 工具层指令双确认），用户在场轮补录 4 段（line 41 指针 + line 127 LM pin 行 + line 128 CA ref 行 + line 129 CX 语义轴行），patch diff 已备齐（见本轮 report 附 AGENTS.md 待补段）。**验证**：`git diff Package.swift` 显示双 pin 精确变化；`Package.resolved` mlx-swift = `2b5e877`(0.32.2 tag) + mlx-swift-lm = `c043fb3`；`swift build --target ocoreai` exit 0（41.82s）；`make test-ci` 2138/395 绿 exit 0；`bash scripts/upstream-drift.sh`（adopt 后复检）= 三轴 0 new，EXIT 0。

**09-28 工具契约描述面补全 — 模型可见能力契约对齐(能力→感知断点闭环)** — 缺口实证: 全库 `ToolEntry.typed` 注册 17 处逐一核, **7 个工具零 `description`**(`info`/`echo`/`read_file`/`search_files`/`skills_list`/`skills_lookup`/`skills_view`)— 而同文件 `write_file`/`edit_file`/`exec_command`/`exec_shell` 全有 = **契约面不一致**。wire 实证: `toToolSpecs()`(`ToolRegistry.swift:570`)对无描述工具只发**极薄 fallback** `"Tool: read_file [files]"`(3 个词,模型学不到用途),`toToolDef()`(`ToolEntry.swift:185`)回退合成行(略好但仍非能力描述)。真实断点: 上轮 `a619d59` 给 `read_file` 加了 PDF 原生能力,但 wire 上模型看到的 read_file 描述里**没有 PDF 信号** → 模型不知道 read_file 能读 PDF,回退 `exec_shell` 或回「读不了」= 能力已修但**感知没修**,「开箱即用」的「答」卡一半。修: 7 处 `typed()` 补真实 `description`(逐 handler 语义核实,非模板套) — `read_file` 带 **PDF 能力信号**("PDFs are read natively via their text layer")使上轮 PDF 能力进入模型契约面。零新工具/零新机制 — 复用既有 `description:` 参数与双 wire 路径。验证: 新增 `supplementedToolDescriptionsSurviveToWire`(生产 `bootstrapBuiltInTools` 全量 registry × `toToolSpecs` wire 断言: 7 工具描述全在 wire 上 + 无一落 `"Tool: "` 薄 fallback + read_file 描述含 "PDF")全绿; `ToolSpecFullRegistry|ToolEntrySpec|ToolRegistry|FileTools|WebSearch` 71 tests/13 suites 全绿零回归; `swift build --target ocoreai` exit 0。诚实边界: 工具「能力」与「描述」是两层,本轮只补描述层(契约面,无新行为); 全库剩余无描述工具 = 0(精确值门锁死, 未来新增工具漏描述该测试红)。

**09-28 `web_search` 默认去 LAN-IP 化 — 开箱即用对齐「natively local」** — 缺口实证: `web_search` 一等工具(handler/协议/parser/probe/诚实降级全在),但**默认后端硬编码 `http://192.168.101.146:11434/v1`**(用户私有 LAN 拓扑 + ollama),违反「natively local / 开箱即用」身份。实证: ① `.146:11434` = HTTP 000 timeout(当前不可达),而用户 LAN 上**实际有 ollama v0.34.4** 跑在 `.144:11434`(curl 200 + `/api/version` 实证); ② 用户 `env`/`launchctl` **0 处 `OCRE_*` 覆盖** → 开箱即「每次 web_search 挂 180s probe timeout → `error: LAN 不通`」; ③ omlx 无 web_search 实现(pyproject.toml 仅 pydantic 名命中,`*.rs`/`*.toml` 0 实现) → 上游不对位。修: `WebSearchTool.swift` 默认 base `.146:11434` → `127.0.0.1:11434`(本机 ollama 官方缺省,语义 = "natively local" → 指向自己); doc 注释同步; `Tests/WebSearchToolTests.swift` 9 处 URL 构造断言同步(纯函数,逻辑不变)。零新能力/零新工具/零新机制,`web_fetch`(WebKit WKWebView)已是 100% 本地不动。诚实边界: 本机 ollama 进程不存在 → 开箱默认 `127.0.0.1` 不可达属**预期诚实**(「natively local」指向自己,自己没 ollama 就如实 `error`)——用户真实 ollama 在 LAN `.144`,设 `OCRE_SEARCH_BASE_URL=http://192.168.101.144:11434/v1` 一行即通; 完整端到端(web_search 真实答案)需「可达 ollama」单条件,本轮不跑 liveness 测试(避免依赖外网/特定主机,纯函数面已覆盖)。验证: `swift build --target ocoreai` exit 0(7.27s); 18 tests/4 suites 全绿(request construction / probe / parser / toolEntry schema)。

**09-28 `read_file` 原生 PDF 文本层抽取 — 开箱即用断点补齐** — 缺口实证: `read_file` 对 PDF 一律拒（`FileTools:76` null-byte guard 先于扩展名校验，PDF 含 NUL 必被拒为 binary），而 `pdftotext`/`qpdf`/`pypdf` 本机均未装（`which` 空），模型只能靠 `exec_shell` 间接抽 = 不开箱即用。Bionic 基线: PDF 读取是「read 文档」的自然能力面，不该是 shell 绕路。修: ① `FileTools.read()` 顶部加 PDF 分支（先于 null-byte check 命中 `.pdf`）→ `readPDF()`（`#if canImport(PDFKit)` import，系统框架零第三方依赖，macOS 14 部署线全过）；per-page `PDFPage.string` 抽文本层，输出复用既有 `N|line` 窗口化（`offset`/`limit` 同语义，`[PDF p<n>]` 每页头标注）；② 诚实契约: **PDF 无文本层**（扫描件/图像内嵌）→ 抛 `.invalidParameter` 带明确指引（"attach the file for the VLM / 使用 `view_image`"），**绝不**伪造 "0 lines" 或静默返回空窗；③ `search_files` content-mode 顺手补上 PDF 内容抽（复用同一 `readPDF`，零新机制）—— 非 PDF 文本搜索逻辑零变更。Ground truth 实测（headless-safe fixture: Python 手写 PDF 对象树 + `Tj` 文本算子，避 `NSView.dataWithPDF` headless 不序列化字的陷阱）: 文本层 PDF → `PDFKit page.string` = `"Hello ocoreai PDF text layer 12345"` 精确全文；无文本层 PDF → `page.string` = `""` 诚实空不 crash。验证: `swift build --target ocoreai` exit 0（增量 8.x s）；新增 `PDFReadFileTests` 3 精确值用例全绿（happy path 全文精确 / 无文本层诚实抛错含 `view_image` 指引 / search content-mode 命中 `real.pdf` 不命中 `notext.pdf` 且 `total: 1`）；原 `FileToolsBehaviorTests` 8 用例零回归；`#expect(throws:)` 宏形态不稳（返回 `ToolError?` 给非 optional 编译红），改用 `try?` + 显式 `ToolError?` 捕获断言 message。诚实边界: `image attachment` 已完备（`AttachedImage`→`ContentPart.imageUrl`→VLM 预览），不动；OCR 双引擎（`DocumentOCR`/`VisionOCR`）既有能力，不在本轮重造。零新工具、零新机制、零第三方依赖、i18n 文案走 `StringKey`（无新增）。

**09-28 会话上下文水位 (session introspection 第一刀: 上下文预算对用户可见)** — 缺口实证: 数据面早已就位（`ContextStatusStore` 两条路线 per-turn 写真值 used/window；`ContextRemaining.tokensRemaining` codex 逐字对齐 0.150.1；`get_context_remaining` 工具闭环）但**零 UI 消费**——Bionic「session introspection」里用户真正缺的一块 = 当前会话占了多少窗口/还剩多少。修: ① `ChatState` 加 `contextUsedTokens`/`contextWindowLimit`（会话态, **不**入每轮遥测清块）+ `contextRemainingTokens` 计算位直接调 codex 对齐的 `ContextRemaining.tokensRemaining`（UI 与工具一个 number, 0 内联算术）; ② `ChatViewModel.chat()` 公共收口读 `ContextStatusStore.shared.peek()` 桥入（读即得真值, 不造 seam）; ③ `ChatView` 输入条上方水位条（progress + `ctx: used/limit (remaining left)`）, 走 `StringKey.contextMeter`（en/zh）; ④ 语义对齐 codex `unknown` 路径: 窗口未配置 → **整条隐藏**, 绝不伪造预算; ⑤ `ChatState.init` private→internal（测试隔离实例, 同 `ContextStatusStore` 既有模式）。新增 `ContextWatermarkBridgeTests` 4 精确值用例（exact/clamp0/nil-unknown/fresh-nil）。诚实边界: `maxContextWindow` 默认 `nil`（omlx 式显式 per-model 配置, 上游对齐）——默认用户未设窗口前水位条隐藏是**正确**行为（窗口数确实未知）；从本地 config.json `max_position_embeddings` 自动解窗口 = 独立产品决策（连带默认 400 墙 + 规则压缩 blast radius），未静默做, 留拍板。验证: `swift build --target ocoreai` exit 0（26.56s）; 17 tests/4 suites 全绿（13 既有 + 4 新增）

**09-28 codex 新窗口裁决 + adopt — `99f7758..1cc7e2361` 8 commit（用户在场轮，补录 AGENTS.md 审计行）** — `bash scripts/upstream-drift.sh` 检出 codex +8（轴词粗筛 0/8，粗筛仅提示不作裁）。**8 commit 逐条 consumer-transparent 双根全扫**：`#48807` turn-duration footer · `#48814` Mermaid 标签标点 · `#48827` Ghostty/Kitty hand pointer · `#48830` TUI interruption notice → ocoreai = SwiftUI GUI，`mermaid|ghostty|kitty|hand.?pointer|interruptionNotice` 双根 = **0**（TUI 渲染轴无消费面）；`#48812` prewarming for idle threads → ocoreai 77 处 `prewarm` 全是**模型引擎预热**轴，≠ codex TUI 会话线程轴，**同名不同义**（仅轴词粗筛会误判有面）；`#48819` histogram tool/skill context metrics → ocoreai `Metrics/Metrics.swift` 22 处 histogram 是**自有 engine 指标面**，`tool|skill` = 0，非同轴；`#48824` voice RTP 20ms → ocoreai `AudioIO`/`SpeechTools` 9 处是**自有实时音频轴**，非 codex voice-agent 轴；`#48828` archive thread before first turn → ocoreai 会话语义 = turn 落库才成会话（`SessionManager` SQLite），`archive.?thread|archiveSession` 双根 = **0 消费**；`#48829` Windows sandbox provisioning service → ocoreai 无 sandbox 轴（09-27 `#48565` seatbelt 同判），`sandbox.?provisioning|provisionService` 双根 = **0**。**8/8 consumer-transparent，0 强制缺口，0 生产面变更。adopt**：codex 基线 `99f7758 → 1cc7e2361`；mlx-swift-lm `ee673d6`/coreai-models `e7b24da` 双轴 0 new 基线不动。门：adopt 后复检三轴 **0 new**（实证）。补录 09-27 cron 轮 pending 的 AGENTS.md 审计行 + `.upstream-baseline.json` adopt。零 Swift 变更轮，无 build gate。

**09-28 上游 drift 裁决闭环：codex `985cf47..99f7758` 26 commit 全窗 + adopt（cron 只读自检轮）** — 三轴 `bash scripts/upstream-drift.sh` 复检：mlx-swift-lm `ee673d6`（= SPM pin，0 new）· coreai-models `e7b24da`（0 new，上轮 17 commit 已逐条核验）· codex **+26**（`985cf47..99f7758`，adopt 前 25 + adopt 时增量 `#48807` TUI turn-duration footer）。**codex 26 commit 逐条裁决（consumer-transparent by axis，0 强制缺口）**：全窗落 codex 自有轴——① TUI 渲染/session-switch（`#48621` follow-up 建议移除 · `#48623/#48800` Markdown 列表符号 · `#48626/#48628` TUI session 切换/空 session · `#48754/#48757` `/status` 渲染 · `#48761` 紧凑活动行 · `#48775/#48776` transcript header/badge · `#48799` Windows SGR 鼠标 · `#48805` 模态内滚轮 · `#48807` 完成 footer）——ocoreai UI = SwiftUI/AppKit 活体 GUI，0 Rust-TUI 消费面；② macOS CLI provisioning（`#48611` persistent mode · `#48643` bundle 名 ChatGPT）——ocoreai 非 Rust-TUI、非 CLI provisioning；③ Linux/Windows 测试设施（`#48724/#48727` ETXTBSY races · `#48772` Unix socket 长 symlink · `#48746` command-center test）——ocoreai MCP = macOS stdio subprocess（`MCPStdioClient.swift`），0 Unix-socket 消费面；④ Guardian/Code-Mode/circuit-breaker（`#48725` 守护评审保留 · `#48779` Guardian 历史跨压缩 · `#48796` structured errors）——ocoreai `EngineCircuitBreaker`（`App.swift:65`）= 引擎启动保护既有机制，非上游 Guardian-Code-Mode 轴；⑤ MCP 工具轴（`#48764` resource URI 不改默认 display mode · `#48783` single-server MCP status discovery + thread connection reuse · `#48686` WS header/tool-payload 脱敏 · `#48604` 移除 plugin-creator skill）——双根全扫实证：`listResources|readResource|resourceUri` = 0（ocoreai MCP = tools-only）、`WebSocket` = 0、ocoreai MCP status 面已有 `$bridge/status` + `statusSummary()` + 子进程退出自动重连（`MCPStdioClient.swift:26/120/134/359`）= 同面不重造、`plugin-creator` = 0（ocoreai Skills 系统无此 skill）。**adopt**：codex 基线 `985cf47 → 99f7758`（`.upstream-baseline.json`，mlx-swift-lm/coreai-models 基线不动）。门：`bash scripts/upstream-drift.sh` 三轴 **0 new / EXIT 0**（adopt 后复检实证，25+1 全窗已裁）。诚实边界：本轮零 Swift 生产面变更——26 commit 全在 codex 自有 TUI/CLI-provisioning/Linux-Windows 测试/Guardian 轴；若 ocoreai 未来引入 Unix-socket MCP / TUI 渲染层 / Guardian-Code-Mode 轴，此窗口须重裁。AGENTS.md 审计行同轮更新被受保护文件审批门拦截（cron 无交互审批），待用户在场轮补录。

**09-28 首启确定性崩溃根修 — 干净机器首启从「必死」到「可走通」** — 现场复现: `OCOREAI_MODELS_DIR`+`OCOREAI_DATA_DIR` 双隔离的零模型环境启动 release 二进制 → 默认模型自动下载 2.9GB → `loaded in 427651ms` → `prewarmed … first request will be fast` → **紧接着 `freed pointer was not the last allocation` SIGABRT，进程死**（两次独立复现同帧 exit 132）。崩溃帧全部落在 `OcoreaiDownloadProgress.finish()` 的 reaper 闭包 `Task { @MainActor in try? await Task.sleep(for: .seconds(2)); _progress.removeValue(...) }`（捕获 @MainActor 隔离的 self，Swift 并发运行时在 `swift_task_dealloc` 时触发 heap 断言）；同崩溃类高频雷 = ModelScope `progressHandler` 每个 tick 都 `Task { @MainActor in update(...) }`。上游对位: swiftlang/swift #87481（同条 fatal，async 闭包回收触发）/ #67702（heap 不变量）——上游 open，本地消触发面。第一性修法: 进度 store 本质是「跨线程共享的只读快照」而非主线程状态机 → `OcoreaiDownloadProgress` 去掉 `@MainActor`/`@Observable`，改 `NSLock` 同步容器（`@unchecked Sendable` + 注释），`start/update/updateBytes/finish/clear/progress/isDownloading` 全同步；`finish(success:true)` 即时驱逐（「2 秒完成闪现」零 UI 消费者——ModelView 门控在 `modelManager.downloadingModelId`，`completed`/`allEntries` 全库无读者），reaper Task 删除；MLXBridge ModelScope+HF+HF-poller 8 处调用点去 `MainActor.run` 改同步直调 → 热路径零并发闭包，崩溃触发面消失。验证: `swift build --target ocoreai` exit 0（8.36s）；新增 `DownloadProgressConcurrencyTests`（8 worker × 500 it 混合 start/update/updateBytes/finish/读 压力 + `finish` 即时驱逐精确断言）全绿；下载设施 28 tests/6 suites 全绿。**诚实边界: 修复后的首启全链（干净 HOME→下载→加载→finish 不崩→能答）需修复后二进制复跑确认，CI gate 进行中**

**09-27 发布链 metallib 根修 — v0.1.1 首个正式 DMG Release 闭环** — 根因: `swift build --traits appStore`（build-app.sh）链过 382/382 但 SwiftPM 不编译 `.metal`（CI 日志 0 metal step），metallib 只有 xcodebuild（Xcode 工程 target `mlx-swift_Cmlx` → `MetalLink default.metallib`）产出；本地能出 DMG 全靠 09-23 xcodebuild 遗留产物。修: Release 腿先 `xcodebuild build -configuration Release` 自产 metallib 置 build-app.sh 候选路径再打包（Metal shader trait 无关，已注释）。验证: tag run `e878575` 全绿 → GitHub Release `ocoreai v0.1.1 (macOS)` + `ocoreai-0.1.1.dmg`（24MB, sha256:86a87650…）→ 实下载 → 挂载终验: metallib 双路在场（2389928B CI 新编 @13:05）、binary 100755 可执行、版本 0.1.1/ad-hoc 签名 → E2E 活体: 引擎 `127.0.0.1:8080` 起、gemma-4-e2b-it-4bit 真推理 HTTP 200/25 tok/stop（9.8s），测后双验清理 0 残留

**09-27 首启断点修复 — 无模型用户「发第一句」不再是死路** — `AppError.modelNotFound` 在 Chat 层识别（同 target 模式匹配，未动引擎），错误条获得「前往模型页」下一步动作（`modelNotReady` 标志 + 2 个新 StringKey，en/zh-Hans 双表）；非 modelNotFound 错误仍走原「生成失败」+ 重试。`swift build --target ocoreai` exit 0（25.13s）

**09-27 开箱即用 (第一性公理: 装-开-模-答-错) — 补「装」这条唯一断点** — 逐条实证后唯一缺口是无安装产物（用户只能 `git clone + swift build`）；本次补齐：
- ➕ `scripts/build-dmg.sh`：`.app` → 拖拽式 DMG（`hdiutil`，零外部依赖），挂载自验可执行位
- ➕ `Makefile`：`make app` / `make dmg`
- ➕ `ci.yml`：`v*` tag → `build-and-test` 门后发布 DMG 至 GitHub Release（`OCOREAI_SIGN_IDENTITY` 可选正式签名，默认 ad-hoc）
- ✏️ README×2：Quick Start 主路径改为「双击 DMG → 拖入 Applications」，源码构建降为开发者路径
- ✅ 端到端实证（本机）：`bash scripts/build-dmg.sh` → `dist/ocoreai-0.1.0.dmg` (24MB) → `open` → `/Volumes/ocoreai` → 拖入 `/Applications` → 启动 → 中文仪表盘首屏 → 清理
- 其余公理已实证在位：**开**（App 首屏）、**模**（`defaultModelId` 内置 + `prewarmDefaultModel` 首启预热 + 推荐列表下载入口）、**答**（真模型流式 + 工具回路 T1–T3）、**错**（`OcoreaiErrorBanner` 引导）
- 澄清（撤回上轮误判）：appStore trait 关 HTTP 桥 = **审核合规设计**（`HttpBridgePolicy`，`OCOREAI_ENABLE_HTTP=1` 可 opt-in），非缺陷；本地化 = **完整**（UI 480 处 `.l` + 1476 行翻译表 + zh-Hans 完整键表）

**09-27 身份 canonical 定版（用户三度给出，headline 句为定版）** — 全载体对齐同一身份，headline 位 = 用户原句，09-27「complete agentic system / frontier models / coding and knowledge work」作为兼容完整化表述并列（非互斥、不淘汰）：
- ✏️ canonical 句（headline 位，用户 09-27 定版）：`ocoreai is an agent for open models. Natively local. Built for creativity, work, and code.`
- ✏️ `SystemPromptBuilder.codingAgentBase`：`You are oCoreAI — an agent for open models, natively local, built for creativity, work, and code; a complete agentic system designed for coding and knowledge work.` + 求真/好奇/诚实原则 + action-first + 验证汇报。
- ✏️ README.md / README.zh.md：标题「开放模型的 Agent · 原生本地」+ 方向行（coding 最深切片 + creativity/knowledge work 一等产品面）+ 参照物清单（Apple Dev / mlx-swift-lm / coreai-models / codex / HIG + vLLM/vLLM-Metal/SGLang/omlx/OpenClaw/Hermes）。
- ✏️ AGENTS.md Identity：canonical 句 + 兼容并存说明。
- ✓ 契约网：`SystemPromptContractTests.agentIdentity` 正向断言 8 词（an agent for open models / natively local / creativity, work, and code / complete agentic system / coding and knowledge work）+ 负断言「intelligent assistant」泛化；`buildKeepsContract` 同步。
- 参照物：Apple Developer Documentation / mlx-swift-lm / coreai-models / codex / HIG（一级）+ vLLM / vLLM-Metal / SGLang / omlx / OpenClaw / hermes-agent（二级）—— 遇事回到第一性原理，上游对齐优先不自造。
- 验证：`swift build --target ocoreai` exit 0（8.14s）；`swift test --filter SystemPromptContract` **7/7 绿**；全仓「frontier」残留 = 0（AGENTS 已对齐）。

**09-27 身份表达「complete agentic system for open frontier models / coding and knowledge work」（用户定调，是 09-23「agent for open models / creativity, work, and code」的更完整表述，两者兼容并存、非互斥——见 09-27 用户纠正：不锁死单一措辞/不淘汰旧表述）** — 身份面各载体改用 09-27 更完整表述；09-23 表述依然有效：
- ✏️ `SystemPromptBuilder.codingAgentBase`：`You are oCoreAI — a complete agentic system for open frontier models, natively local, built for coding and knowledge work.`（原 `an agent for open models ... creativity, work, and code (code is the first, deepest slice)`）；注释同步 09-27 定位。
- ✏️ README.md / README.zh.md：标题 + 「为编码与知识工作而生」+ 方向行（knowledge work=一等产品面；coding=最深切片）。
- ✏️ AGENTS.md Identity：标注 09-27 更完整表述（当前仍含旧「取代/回流禁令」措辞，属受保护文件待审批更新为兼容并存）。
- ✓ 契约网：`SystemPromptContractTests.agentIdentity` 正向断言身份 4 词（complete agentic system / open frontier models / coding and knowledge work）+ 负断言「intelligent assistant」泛化；**不加旧措辞负断言**（两表述兼容并存非互斥，见 09-27 用户纠正）；`buildKeepsContract` 同步。
- 验证：`swift build --target ocoreai` exit 0（Build complete 8.46s）；`swift test --filter SystemPromptContract` **7/7 绿**（移除旧措辞负断言后重跑确认）；两身份表述兼容并存、非互斥，09-23 表述不淘汰。
**09-27 drift 裁决闭环：codex `6a39914..985cf47` 5 commit 全窗 + adopt（「自主推进」轮）** — 三轴 `scripts/upstream-drift.sh` 复检：mlx-swift-lm `ee673d6`（= pin，0 new）· coreai-models `e7b24da`（0 new，上轮 17 commit 已逐条核验）· codex **+5**（`6a39914..985cf47`，含 cron 昨日已暂存未提交的 `e8fdbf1` 窗口 + 新增 `#48562`）。**codex 5 commit 逐条裁决（consumer-transparent by axis，0 强制缺口）**：`#48562` TUI borderless session header（TUI 轴，ocoreai UI = SwiftUI/AppKit，0 Rust-TUI 消费面）· `#48565` macOS TLS trust in network-enabled Seatbelt profiles（sandbox 轴——ocoreai exec 面 = local `Process()`（`ExecTools.swift:158`），全仓 `seatbelt|sandbox-exec` = 0 命中，无 sandbox 消费面）· `#48568` exec-server 代理 permitted private IPs（cloud-executor 轴——ocoreai web 面 = 直接 `URLSession` 客户端，无执行代理/上游代理机制）· `#48574` deferred tool namespace 名优先于描述保留（codex `world_state/tools` 渲染预算轴——ocoreai 工具面 = **全量 31 tools 常驻**（用户锁面），无 deferred-tools/namespace 预算机制；`deferred|tools_budget|world_state` 双根全扫 = 0 功能面命中，15 处 `deferred` 均为无关注释）· `#48575` provisioned executor 上线时限（cloud-executor 轴，ocoreai 无 remote/provisioned executor）。**adopt**：codex 基线 `6a39914 → 985cf47`（`.upstream-baseline.json`）。门：`bash scripts/upstream-drift.sh` 三轴 **0 new / EXIT 0**（adopt 后复检实证）。诚实边界：本轮零 Swift 生产面变更；5 commit 全在 codex 自有 TUI/seatbelt/cloud-executor 轴，若 ocoreai 未来引入 sandbox-exec / remote executor / deferred-tools 面，此窗口须重裁。

**09-27 上游 drift 持续跟进机制化（「持续跟进」轮）** — 把三源上游跟踪从**手工审计轮**升级为**可重复机制**，交付物 = 2 个版本化文件 + 1 定时任务，**零 Swift 生产面变更**：
- **`scripts/upstream-drift.sh`**（check/adopt 双模式）：`check` 拉三源 HEAD 对 `.upstream-baseline.json` 基线，用完整 SHA `compare` 判 ahead/behind（短 SHA 单点解析、compare 用 full SHA——短 base 会 404，本轮实证踩过）；`adopt` 把 HEAD 推为新基线。退出码语义：`0`=0 new / `10`=新窗口待裁决 / `1`=异常（基线新于 HEAD、非线性分叉、gh api 失败）。轴词粗筛**只是提示**，权威裁决仍是 consumer-transparent 双根全扫（`Sources/`+`Tests/` 符号命中，同义词全扫+既有机制先查）——写死在脚本头注释，不发明弱门禁。
- **`.upstream-baseline.json`**：版本化基线（入库可复现），当前 `mlx ee673d6` / `coreai-models e7b24da` / `codex 6a39914`；post-adopt `check` 三轴 **0 new / EXIT 0** 实证闭环。
- **Hermes cronjob**：每日只读自检（无 drift 静默，有 drift 回报裁决清单）——「持续跟进」的落地形态。
**codex `7ed14a27d..6a39914` 5 commit 裁决**（本轮窗，含 adopt 后即时新窗）：`blossom replay` / `table cell source metadata` / `markdown copy` / `math rendering` / `working tips stable during transcript (#48560)`——**全 TUI/onboarding/tips 轴**，ocoreai 无 Rust-TUI 消费面（UI = SwiftUI/AppKit），consumer-transparent by axis（`#48560` 双根 grep `working.?tip|transcript` 唯一命中 ocoreai `TranscriptPart` 消息结构块，非同概念），基线已推至 `6a39914`。诚实边界：AGENTS.md「机制行」因保护审批超时**未落**（待 user 在场补一行指向 `scripts/upstream-drift.sh` + state 文件，非阻塞）。门：`bash scripts/upstream-drift.sh` 三轴 0 new / EXIT 0。

**09-27 上游 drift 审计闭环 + AGENTS.md 审计行对齐（「继续推进 ocoreai」轮）** — 按 `make` 协议做**主动 audit**（非「还有失真吗」轮，而是把上游 HEAD 与 ocoreai pin 的漂移窗口逐条核验）。**上游两源实证**（本机无 references/ clone，`gh api` 是正确通道）：
- **mlx-swift-lm**：`origin/main` = `ee673d6`（#603 "Extract the model cache"，2026-09-18）——与 `Package.swift` pin `ee673d6` **完全同点，0 drift**。无 bump 必要。
- **coreai-models**：本地 pin `89ba0d4`（09-18 对齐时的 origin/HEAD），`origin/main` 已推进到 `e7b24da8`（#266 "--replay"，2026-09-26）——**17 commit 漂移窗口** `89ba0d4..e7b24da`。
**逐条核验 17 commit**（consumer-transparent 判据：同义词全扫 `Sources/ocoreai` + `Tests/ocoreaiTests` 双根）：
- **ocoreai 已有 = 3**（本轮不重复吸收）：`#265` seeded sampling (`4cd0d36` 已落)、`#268` KV growth (`e4def0d` 已落)、`#274` prefill threshold (`85a85f5` 已落)——三者都是 `e4def0d` → `85a85f5` 期间已吸收的 commit。
- **Python / diffusion / SAM3 / noise-source / quantization-recipe 轴 = 8**（ocoreai 无 Swift/Python 消费面，consumer-transparent by axis）：`#259` Sana model、`#260`/`#261`/`#262`/`#264`/`#265`/`#269`/`#272` 的 `python/` 树 commit（部分含 Swift CoreAI 文件——已核对 ocoreai 命中数 0）。
- **Swift consumer 面 = 6 候选，全部 0 ocoreai 消费面**（grep 实证，非推断）：
  - `#271` broaden tool-calling for Phi/Qwen3-Coder（`xmlFunction`/`ToolCallDetection`/`injectToolsIntoSystemMessage`/`PhiFamily`）：全 ocoreai 命中数 `#271 ToolCallDetection` 是 test-struct 同名碰撞、非 #271 的 Swift 类型；`injectToolsIntoSystemMessage|PhiFamily` = **0**。Qwen3-Coder 模型不在 ocoreai 已知模型清单（`Tools/RecommendedModels`/`CatalogModelProvider` 无该 surface）。
  - `#267` honor `reasoningLevel` in CoreAI executor：ocoreai 已有 `ContextOptions.thinkingEnabled?` + `ReasoningResolution.thinkingEnabled(reasoningLevel:enableReasoning:)`（09-24 落地，三态 + FM/MTP 双路统一）——**本地语义等价更强**（显式 `reasoning` 三态 > 仅 level），不吸收。
  - `#258` make generation idempotent + `IdempotentEngine`/`GenerationSessionState`：ocoreai 已有 `SessionPool` prefix-match + 同会话 id 路由；`IdempotentEngine|GenerationSessionState` = **0**（无对应 consumer）。
  - `#266` `llm-server --replay`：`Tools/llm-server` Swift 树，ocoreai 非 server（0 ocoreai hits）。
  - `#290` dead code removal：`ReasoningEffort` / `ModelConfig` 死代码，o-coreai 0 命中。
  - `#275` `llm-server` streaming（`Tools/llm-server`）：0 ocoreai hits。
**结论：3 已吸收 + 0 强制缺口 + 0 行为分叉。** 合法 zero-forced-gap 闭环（判缺口纪律：同义词全扫 + 既有机制先查全部跑完，未捏造缺口）。**AGENTS.md `coreai-models` 审计行**升级：从 `89ba0d4` 钉点 → `origin/main HEAD e7b24da`（**17 commit 逐条结论** + 3 已吸收 + 0 行为分叉）；**mlx-swift-lm 行**维持 `ee673d6` 0 drift（本轮无 bump，pin = origin/main）。门：`git status --porcelain` 仅 AGENTS.md 单行 +1/-1；CI 36271762442 success（`f472759` 测试 sweep 轮）。诚实边界：本轮零 Swift 代码变更；「审计无发现」≠「上游无变化」——8 commit 的 `python/` 轴 + 5 commit 的 `Tools/` 树轴 = ocoreai 当前消费面不触达，若未来引入 server / diffusion / 新模型族消费面时需重新过 audit。

**09-24 系统 prompt 身份面对齐 09-23 对外定版（「按需优化 prompt」轮）** — 第一性审计 prompt 认知层时发现**活漂移**：`SystemPromptBuilder.codingAgentBase` 首句仍是 `a coding agent running on Apple hardware`，而 canonical 定版（AGENTS.md「What it is」+ README + 用户 09-23 定调）= **an agent for open models, natively local, built for creativity, work, and code**（code 第一切片）。全源码 grep 实证：定版三域词（creativity/work/open models）在 `Sources/*.swift` **0 命中**，身份面唯一载体就是这条 base prompt —— 其余「coding agent」出现均为源码内部角色引用（描述 code 切片内的角色需求），非漂移。修复：首句对齐定版 + 保留 code 第一切片语义（小模型行为契约要求短祈使、直给命令，不灌政策长文），契约测试 `SystemPromptContractTests` 同步改为锁 09-23 身份面（`agent for open models` + `creativity, work, and code`，保留 `!intelligent assistant` 反漂移锁）；`use your tools` / 求真原则 / 破坏性命令不内置 等既有锁定全部不动。真实现状：模型认知层（prompt）→ 工具面（31 tools 全 isDestructive 审计）→ 回路（ChatHandler 迭代闭环 `416222e`）→ 审批（ApprovalBroker chokepoint 单点）→ 管线，全链实证无缺口；本轮补平的是认知层与定版的措辞漂移。

**09-24 `routingPolicy` UI 面接线：Settings 算力路由策略 Picker 落地（config 面 `f421b0b` 的收尾闭环）** — 审计发现 Sync #102 只落了 config 面，而 `RoutingPolicy` 的 `CaseIterable` 标记**唯一用途就是驱动 SwiftUI `Picker`/`ForEach`**——类型系统声明了 UI 意图却零 UI 面命中（全仓 `grep routingPolicy` UI/Localization 0 结果）= 设计意图未兑现的半成品。修法 = **镜像既有 `specDecoding`/`kvCache` bridge 范式**（不造新机制）：①`SettingsStore` 新增 `routingPolicy`（setter 对 `RoutingPolicy` 白名单，篡改键注入非法 raw 自动落 `balanced`）+ `routingPolicyIsSet` 三态（区分「用户选过」vs「从未触碰」——未触碰时启动桥保留手写 YAML 值，**不造第二份真相**）；②`ConfigStruct.swift` 新增**纯函数** `pureRoutingPolicyUIOverlay(config:uiPolicy:)`（`nil` 保留 authored / 非 nil 覆盖 + 不碰 `BackendConfig` 任何其他维度，同 `pureSpecDecodingUIOverlay` 可精确值测试）；③`App.swift` 在 **L409 `HardwareRouter` 构造之前**应用 overlay（`policy` 是 `let`、无热切换，此点即唯一生效点）；④`SettingsView` 新增 `routingPolicySection`（`ForEach(RoutingPolicy.allCases)` Picker，选项清单与枚举**编译期同构**不可漂移）+ `SettingsState` 绑定 + `reloadFromStore`/`resetToDefaults` 两处同步防漂移；⑤i18n en+zh 各 5 键（`LocaleTableCompletenessTests` 锁定 `all == covered`，缺任一表即红——完整性守卫直接生效）。新增 `RoutingPolicyUIOverlayTests` **8 条精确值断言**（3×3 全格覆盖：UI×authored 任一格错即红 + untouched 维度零改动 + store 白名单/IsSet 三态/删除键恢复未触碰语义）。门：`swift build --target ocoreai` exit 0；定向 17/17 绿（新 8 + locale 完整性 4 + 既有 locale 5）。诚实边界：**启动时生效**（与 specDecoding/kvCache 同模式，footer 文案如实标注「下次启动生效」）；`HardwareRouter.policy` 是 `let` = 架构内无热切换面，非本补丁引入。

**09-24 `reasoning` 三态契约修复 + FM/MTP 双路解析统一（`enable_thinking` 不再静默回落模型默认）** — 全链审计 `reasoning:false` 契约抓到一个**三态被坍缩 + engine 不 consult 布尔**的真实缺口：wire `reasoning: Bool?`（absent/`false`/`true` 三态，boolprobe 实证 `Bool? = false` absent→nil 非 false）在 `ChatHandler`/`DirectInferenceClient` 被 `request.reasoning == true` **坍缩成二态**后塞进 `InferenceOptions.enableReasoning: Bool = false`；engine 侧 `reasoningLevel==nil` 时**根本不读这个布尔**——`thinkingEnabled` 直接 nil → 落 promptStrategy `defaultOn`（Qwen3 家族 = **ON**），用户显式 `reasoning:false` 被**静默吞成开启**，与 wire doc 自造的「`false` = reduced budget」语义（上游 `thinkingEnabled: Bool?` 只有 on/off，无 budget 概念——本地发明）双双矛盾。修法第一性原理两步：①**三态透传**——`enableReasoning` 升 `Bool?`（absent→nil→模板默认；`false`→显式 OFF；`true`→显式 ON），全链 6 文件去 `== true` 坍缩；②**消除双份漂移温床**——FM 路与 MTP 路两份内联闭包（各自解读、已现缩进畸形）收敛为单个可单测纯函数 `ReasoningResolution.thinkingEnabled(reasoningLevel:enableReasoning:)`（`InferenceStubs.swift`），语义逐 case 对齐旧行为：light/moderate/deep→ON；**非空未知级名（`no_think`/空白词）= 禁用信号**→`enableReasoning ?? false`（显式 bool 可覆盖，absent→OFF，**绝不**回落模型默认——`no_think` 单独传绝不 ON）；级名缺失/空白→`enableReasoning` 裸传（nil→模板默认）。`CompletionsHandler`（`/v1/completions` wire 无 reasoning 契约）显式 `false`→`nil` 修正——旧行为 = 模型默认，显式 false 会凭空捏造用户意图。新增 `ReasoningResolutionTests` 10 条**精确值断言**（三态每格 × level 缺席/已知/未知/大小写/空白边界，任一语义再漂移即红）——此前 `enableReasoning` 三态 **0 测试钉位**。门：`swift build --target ocoreai` **exit 0**；`make test-ci` 全量 2106 tests / **`ReasoningResolution.thinkingEnabled` suite 10/10 绿**（3 红全在 `AppLifecycleLiveTests` 活体 GUI 时序 flake——**单独复跑 5/5 绿**实证非本 patch 回归，属全量并发下 Finder frontmost 收敛窗口抖动，环境面非代码面）；基线 2093/388 + 本 10 + suite 数不变。

**09-24 路由策略接线：`routingPolicy` 升为用户可配算力偏好（config 面落地，默认 `balanced` 不变）** — 第一性原理审计抓到一个**类型系统早已备好却无人接线的半成品**：`RoutingPolicy`（`balanced`/`performance`/`efficiency`）声明了 `CaseIterable: String, Codable, CaseIterable`——`CaseIterable` 的唯一用途就是驱动 SwiftUI `Picker`/`ForEach`，说明设计意图是**用户面性能旋钮**；但全仓 `grep` 实证 `policy: .balanced` 在 `App.swift:410` 被**硬编码**，config.yaml 与 UI 双双无入口 → 生产路径被锁死在 `balanced`，与 omlx（生产参照：内存/ANE 分片/prefill 限制器**全部是用户手动开关**）+ HIG「性能项由用户控制」的参照面相悖。修法 = 对齐 `approvalPolicy` 既有范式（owner 键优先、宽限解码、类型安全）：`BackendConfig` 新增 `routingPolicy: RoutingPolicy`（存强类型枚举而非 String，比 `approvalPolicy: String + parsed` 更类型安全），全链路 Codable（decode 缺失/非法值宽限回落 `.balanced`，不 break 既有 config）+ `validate()` 显式校验 + `App.swift:410` 改从 `_configSnapshot.backend.routingPolicy` 读取（`_configSnapshot` 在 router 构造前 L318 已就绪，同 actor 同步读）。**默认行为零变化**（未配即 `balanced`），纯**增加**可配面。新增 `ConfigValidationTests` 4 条钉死：默认值、三值显式解码、未知 raw 回落 `balanced`、encode→decode roundtrip。门：`swift build --target ocoreai` exit 0（7.44s / 2 预存 warning 非新增）；**canonical 门 `make test-ci` 待绿**（本 4 条并入）。诚实边界：热 reload 时 `_configSnapshot` 不自动回灌 router（configSystem L171 只刷自身，App 快照需 reload 事件——既有架构缺口，非本补丁引入），故 policy 按**启动时**生效，与 `specDecoding`/`kvCache` 等既有 owner 键一致。

**09-24 HardwareRouter 内存压力口径修复：可回收缓存页不再虚高压力级（GPU 路由层被架空堵死）** — 活体路由实证（实例 stdout `HardwareRouter → CPU (gpu: 0.8/2.6GB)`）+ `vm_stat` 真值（16GB/page=16KB：free 3.49G / active 4.27G / **inactive 3.97G** / wired 2.30G / compressor 1.35G）把 GPU 路由债钉成**架构级 bug**：`memoryUsageFraction()` 把 `inactive_count`（内核可按需即时回收的文件磁盘缓存，非真实压力）计入"已用内存"，现代 macOS 稳态下 inactive 缓存必然大 → 压力级被系统性虚高 → `route()` Tier-1（`policy.memoryShiftLevel` 门）几乎恒定强制 `.cpu`，把本应走 GPU/ANE 的推理全压 CPU（实测单步 60-120s）。修法 = 口径对齐内存语义，非改阈值：`usedFraction` 分子只计**不可回收驻留页**（`active + wired + compressor`），`inactive` 剔出，把原 3 行内联表达式抽成**可测试纯函数** `usedFraction(active:wire:compressor:pageSize:memSize:)`（`memSize==0` 保持中性 0.5）。实测影响（本机 2026-09-24 读数）：0.8109→L3 → 0.5630→L2；**`.performance` 策略（阈值 3）由「锁死 CPU」恢复「放行 GPU/ANE」**。诚实边界：默认 `.balanced` 阈值 2，L2 边界值仍可能触 CPU——阈值是独立设计决策，本次只修口径虚高这一实证 bug，不擅改阈值。新增 `HardwareRouterPressureRegression` 4 条（纯函数数学契约 + 行为门：缓存页排除、正确口径严格轻于旧口径、旧口径在本机读数达 L3 钉住 regression、memSize guard）：单 suite 4/4 绿。门：`swift build --target ocoreai` exit 0；**canonical 门 `make test-ci` 2093 tests / 388 suites，0 failed，35.6s**（基线 2089/387 + 本 4）。

**09-24 work 面工具契约修复：12 处 schema 类型自相矛盾堵死（数值型参数全族 `.string` → `.integer`）** — 活体重探 work 面（`list_apps` 闭环）抓到一个**ocoreai 自有契约 bug**，与模型能力无关：`ToolEntry.typed` 把**同一个工具**的两条路径割裂——**声明给模型的 wire schema 说 `type:"string"`，而 `Args` 字段是 `Int?`/`Int`**。模型遵守 schema 发出字符串数字（`"50"`），ocoreai 侧 `JSONDecoder` 按 `Int?` 解码必抛 `The data couldn't be read because it isn't in the correct format.`，工具回路进入 `invalidParameter → loopDetected` 死循环重试（实测 0.8B VLM 10 分钟空转）。两个异构模型（Qwen3.5-0.8B VLM + gemma-4-e2b non-VLM）在同一工具上报同一错误 → 排除「小模型能力不足」假设，钉死为契约自相矛盾。**全扫**（非抽样）18 个 `ToolEntry.typed` 文件 / 46 个工具块，精确命中 **12 处**，全在 work 面（`computer` toolset 即 09-23 定版「为工作而生」核心面）：`list_apps.limit`、`read_clipboard.max_chars`、`inspect_ui.depth`/`max_nodes`、`move_mouse.x`/`y`、`click.x`/`y`、`drag.x1`/`y1`/`x2`/`y2`。修法 = schema 声明对齐 `Args` 字段真实类型（`.integer`），对齐上游 JSON Schema 语义 + 同文件已在用的正确范式（`web_fetch.timeout`/`read_file.offset` 均 `Int?`+`.integer`，且已知 good 模型实证能跑）；decoder 侧零改动（`Int?` 字段解码 JSON number 本正确）。新增 `WorkToolSchemaTypeRoundTripTests` 2 条**契约钉死**：12 个数值字段逐个断言 schema 类型 == `.integer`（任一字段或 schema 单侧再改 type 即红）+ `list_apps` 整数 payload 经 registry 真实 dispatch 成功并断言行数钳制（回归测试只读零副作用）。门：`swift build --target ocoreai` exit 0；新测试 2/2 绿；**canonical 门 `make test-ci`（xcodebuild → xctest）2089 tests / 387 suites，0 failed，36.2s**（基线 2087/386 + 本 2 条）。注：`swift test` 路径因 metallib 运行时分限报红为**已知限制**（Makefile test-ci 注释 + AGENTS.md L112-115），非测试失败——`xcrun xctest` 路径下全绿为权威判据。

**09-23 mlx-swift-lm pin bump `c6446cf → ee673d6`（#603 Extract the model cache，吸收；本轮补录漂移）** — `790d4df`（09-23 已提交，当时漏走「审计行记入本节 + CHANGELOG」的 bump 协议后两步，本轮按协议补齐）：#603 吸收 = ModelCache 抽出独立文件，`evictAll()/evict()` 真取消 in-flight load（此前丢弃注册但任务续跑，调用方 await 永不返回 + coalesced load 一起卡死）、`MLXDownloadProgress` 按 model-id 分桶（此前并发 download 共用单 fraction、cancelled load 永远 active、进度报告顺序无保证）、`GrammarConstraint.clone()` 只 catch `GrammarError.forkFailed`（此前 blanket `try?` 静默吞新失败模式）。消费面审计：ocoreai 不直接调用 #603 改名符号（`docs/prompt-ocoreai.md` L86 consumer 审计行）；`import MLXFoundationModels` FM 路径仅经 `MLXLanguageModel` 管线消费 → 受益非破坏（commit message 实证 "No release contains this type... cannot break a consumer"）。门：`swift build --target ocoreai` 26s exit 0；xcodebuild + `xcrun xctest` **2080 tests / 385 suites PASS 42.77s**（基线无回归）；CI `790d4df` success（21m38s）。

**09-24 测试隔离修复：`CoreAIModelIdRoutingGateTests` 补 `.serialized`（单跑绿/并跑红的三重人格堵死）** — 全量门首跑抓到 `CoreAIModelIdRoutingGateTests` 3 项红（got 全部落到真实 `~/.ocoreai/models/...`），单 suite 单跑却 7/7 绿 ×3——**进程级全局 env 竞争**：该 suite（与 5+ 处既有测试同用 `setenv("OCOREAI_MODELS_DIR")` 重定向 `ModelStore.root` 惯例）漏了 `.serialized`，Swift Testing 默认并发跑，一个测试的 `defer unsetenv` 在另一个测试读 env 的间隙清掉 → 回落真实 home → 断言失败。同库 `ModelStoreTests`（同惯用法、带 `.serialized`）恒绿 = 对照组坐实。修法一行：`@Suite("…", .serialized)`（沿用库内既有硬惯例，非新造机制）。门：`make test-ci` 全绿（同 commit 一并验证），单 suite 7/7 ×3 + 4-suite 混跑 23/23。

**09-24 对外定位定版落地（09-23 用户定调）** — 产品一句话定版为「**an agent for open models · natively local · built for creativity, work, and code**」，取代旧「reliable execution layer / first product = Coding/Computer Agent」的排他措辞。语义是**扩展非推翻**：code 仍是第一切片、Execute→Verify→Recover 执行层继承、五要素 / 基准位阶 / 安全原则不变，仅「第一产品」从排他放宽为三域产品面（创作 / 工作 / 代码）。落点 = `README.md` + `README.zh.md`（title + 首句 + Direction/方向 段）+ `AGENTS.md`（Identity 段 L19）+ `CHANGELOG`。文档型变更，无 Swift 代码；门：`swift build --target ocoreai` **exit 0**（零代码变更，复证工具链绿）。

**09-24 KV cache 增长丢上下文修复（对齐 coreai-models #268）** — `GrowingNDArrayState`（CoreAI 引擎 KV state handler）的 `ensureCapacity` 扩容时分配全新 NDArray **不拷已编码 K/V 行**、`reset()` 依赖分配器零初始化——任何触发 KV 增长的场景（chunked prefill：prompt > ~2×chunk；多轮历史；长 decode）都会**静默丢弃全部上下文**；BFloat16 KV 模型还可能在 typed-view 路径 trap。修：增长时按 `sequenceDim` 轴逐块拷旧行（per-position run = 轴后乘积，不越界、通用布局）+ `reset()` 走显式清零；scalar 分型 f16/bf16 走 raw view（bf16 typed-view trap = #268 修的那一类）。`StateHandlerGrowthTests` 7 精确值用例（f32/f16/bf16 × 增长保持旧行 / 无越界复制 / reset 清零，非零特征值断言——「没拷贝」或「碰巧零初始化」均 fail）。门：build exit 0；**`make test-ci` 2087/386, 0 failed, 37.5s**（基线 2080/385 + 本 7）。

**09-21 i18n 死键清除（`c33b45a`）— 436 live → 363 live** — i18n 表长期靠「人眼对数」保完整性，死键（声明了 case、en/zh 两表都有翻译、但 UI/引擎/测试零引用的孤儿键）无声堆积。逐一 `grep StringKey.<name>` + rawValue 字符串跨全库 Sources+Tests 验证引用——首扫误报 74，二次碰撞剔除 `proactiveDraft`（经 `?? .proactiveDraft` 动态存活）后**精确 73**：`send`/`stop` 已被 SwiftUI `.submitLabel(.send)` / `chatState.stop()` 取代，`modelSearch*`/`metric*`/`a11y*`/`perception*`/`system*` 等组随视图重构遗留。三处（enum + en + zh 表）同删，diff = **219 纯删除 / 0 新增**。门：build exit 0；`make test-ci` **1988/1988 (368 suites)**。

**09-21 i18n 字典提升 + 完整性不变量锁死（`cedadf7`）** — 第一性修复「缺完整性测试」这一类漏洞：`base`/`zh` 两份 ~436 条目字典从 `L10nTables` 函数体内提到**模块级 `enum L10nTables { static let base/zh }`**——每次 `localized(for:)` 不再重建字典（进程期一次构造，O(n)→O(1)），过 Swift 6 并发门。新增 **4 条完整性不变量**（`LocaleTableCompletenessTests`）：en 表 / zh 表各**恰好覆盖 `StringKey.allCases` 全集**（双向：不缺 + 无孤儿）、无空白翻译值、含 CJK 的 zh 值必须 ≠ en 值（抓「zh 直接复制 en」假翻译）。这 4 条把「表完整性」从人眼对数变成**编译期可验证的持续守卫**，后续加/删键若漏改任一处表，测试即红——死键/孤儿键漂移整类堵死。门：build exit 0；4 条测试全绿；**CI `cedadf7` success**（本地绿 ≠ CI 绿，双门都过）。

**09-21 系统版本 floor 单源对齐（14.0）——闭合 09-19「4 源对齐」遗留漂移** — 09-19 条目（本文件 L75）已审计「系统版本 floor 自相矛盾」并声称「4 源全对齐 14.0」，但 `git log -S"LSMinimumSystemVersion', '14"` 在该修复涉及的活动文件上命中为空——**该对齐从未真实提交到活动路径**。活体复核（`git show HEAD:<file>`）确认三处仍与 `Package.swift: .macOS(.v14)` / README「macOS 14+」/ 本地 `Info.plist: 14.0` 自相矛盾：
- **`.github/workflows/ci.yml:375`（`release` job 的真·release 产物 Info.plist）**：`LSMinimumSystemVersion` 写 `15.0` —— 每个发布包强制 macOS 14 用户「系统版本过低」，**直接违反 North Star「macOS 14.0+」**；
- **`Localization.swift:996/1508`（en + zhHans About 对话框，用户可见）**：`.aboutVersion = "v1.0.0 · macOS 15+ / iOS 17+"`；
- **`Application.swift:3`（产品入口源码注释）**：`/// Application entry point — macOS 15+ / iOS 17+ / iPadOS 17+`。

**代码层本就 14 兼容**：唯一 macOS 15+ API `AudioIO.swift:126`（`AVCaptureDevice.requestAccess(.audio)`）已用 `if #available(macOS 15, *)` 运行期门控；`AudioStack.swift:87` 的「macOS 15+」是**功能能力阶梯描述**（15+ = enhanced mic 档位），非产品 floor，正确保留。→ 纯配置漂移，非运行时依赖。**修法**：三处 `15.0`/`macOS 15+` → `14.0`/`macOS 14+`（ci.yml 1 处、Localization 2 处、Application 1 处），floor 单一真源回归 **14.0**。门：`swift build --target ocoreai` **exit 0**；`make test-ci` **1984/1984 (367 suites) 全绿**；全库 floor sweep（Package/README/README.zh/ci.yml/Localization/Application）现**全 = 14.0/14+**，无测试断言 `15.0`（`grep Tests` 命中为空，安全改）。

**09-19 mlx-swift pin bump `ab924c82`(#450) → `90194196`(origin/main, #477 era)** — 持续跟进 MLX 内核层：`git ls-remote` 发现 mlx-swift 远端 main 前进 9 commit（`ab924c82..90194196`）。逐条审计消费面（`git diff --stat` + Sources grep）：`#472` Stream 池化 + Device 继承修复（mlx#2118：Streams 是有限资源且泄漏 OS/Metal 句柄，池化复用——**长时自主推理的 GPU 资源热路径**）、`#471` 取消时 wired-memory ticket 生命周期修复（长程 decode 被取消不再留悬挂 ticket）、`#466` convolve even-kernel 修复（op 级）、`#477/#482/#479/#484/#473` 测试基建/分布式 API/日志 shim（0 行为面）。**破坏性变更核查**：`Device.deviceType` Optional→non-Optional + `Hashable` 化——grep 实证 ocoreai Sources 对 `Device.deviceType`/`convolve`/`Distributed`/`MLX.Stream` **零直接消费**（唯一 `deviceType` 命中是 `AVCaptureDevice` 无关 API），MLX 访问全经 MLXLM/MLXNN/MLXLMCommon 桥，变更透明。修法 = 纯 pin bump（`Package.swift` 注释同步记录 9 commit 审计 + 零消费面证据），本地自研零。门：`swift build --target ocoreai` **exit 0**；`make test-ci` **1948/1948 tests green（09-19，#472/#471 不炸宿主且全测试回归绿）**；iOS 27 xcodebuild 复验（pin 立足点）同批跑。

**09-19 能力矩阵 UI 面闭环：SettingsView 徽标改为读单源（消灭第二份本地真相）** — 第一性审计抓到一个真相分叉：UI 层**零处**消费 `RuntimeCapability`（`grep RuntimeCapability Sources/ocoreai/UI/` = 空），SettingsView About 区却**自造第二份真相**——本地 `#if canImport(CoreAI)` + `#available(27)` 重判（仅显 2/9 个 surface，且 `// MLX always available` 是对**档位**的事实断言、并非对**本机**的观测——macOS 15 / 26 的 4 档里 MLX 也在线，但 CoreAI/FM/video 的真实可用状态被整个遮住）。模型读 9 面真值、用户读一个写死的子集，正是「诚实 / 最大求真」在产品面的洞。修法 = 纯消费既有单源，不造新机制、不新增本地门：

- **`RuntimeCapability.Line.label`（计算属性，非存储）**：9 个 surface 各得稳定显示名（`MLX` / `CoreAI` / `FoundationModels` / `Local STT` / `Speech TTS` / `Video` / `MCP stdio` / `Screenshot` / `Agent Loop`）。**计算属性不进 Encodable wire 形**——`GET /v1/capabilities` 的 JSON 字节面零变化（`{name, available, note}`）。单源同时承载**显示名**，UI / prompt / wire 渲染同一名字，**任何视图内禁止再做第二张 name→label 映射表**。
- **`SettingsView` About 区**：`capabilityBadges` 改写为读 `RuntimeCapability.lines`，按 `available` 分组两段——ENABLED 行（绿）/ UNAVAILABLE 行（灰，每 pill 的 accessibility label 携带该 surface 的 `note`，向 VoiceOver / 屏幕阅读器讲清「哪面没开、why」）。**不再有任何 `#if canImport(CoreAI)` UI 层重判**（UI 唯一职责 = 渲染单源，门控全在 `RuntimeCapability` 内）。
- **i18n（en + zhHans 必填）**：5 个新 `StringKey`——`capabilityUnavailable`（"不可用"）/ `capabilityOn`（"启用"）/ `capabilityOff`（"未启用"）+ 两条 VoiceOver 模板 `capabilityA11yOn/Off`（"项已启用 / 项未启用"），渲染句 `"N 项已启用, M 项未启用"`。
- **新增守卫 2 条（11/11 绿）**：`labelsEverywhere`（label 非空 + 非 snake_case——钉死"显示名 map 丢了 track 的 `default: return name` leak"）、`labelsUnique`（9 个 pill 不可能出现两个相同显示名）。
- **交付门（含 4 档可交付性）**：`swift build --target ocoreai` exit 0（11.1 s）；**`swift build --triple arm64-apple-ios17.0-simulator --sdk …/iPhoneSimulator27.0.sdk --target ocoreai` exit 0**（10.0 s）——把 4 档阶梯底（iOS 17）的 SwiftPM 交叉编译门**第一次实证**为绿（此前 macOS 侧 CI 绿、iOS 编译从未真正被跑过）。
- 零行为漂移：`/v1/capabilities` wire JSON 逐字节等价（label 非存储字段）；prompt / info tool / HTTP client / UI 四个消费面现读**同一份** `RuntimeCapability.lines`，UI 无本地 gate、无第二份真相表。

**09-19 能力矩阵单一真源：模型 / UI / 客户端同读一份运行时事实（4 档 OS 阶梯）** — 第一性原理：ocoreai 不是"macOS 应用 + iOS 分支"，而是**一个 agent 运行时横跨四档 capability tier**（macOS 14/iOS 17、15/18、26/26、27/27）。审计前能力真相只活在编译期 `#if` 门里——模型不知道这台设备哪些能力离线、UI 不知道、HTTP 客户端更不知道；且 base prompt 硬编码 `running on macOS`（iOS 上失真，正是"最大求真"所禁止的）。修法是把能力真相从编译期门提升为**运行时单一真源**，三个消费面同读一份：

- **新增 `Sources/ocoreai/Capability/RuntimeCapability.swift`**（能力矩阵单一真源）：9 个 surface（`agent_loop`/`mlx_inference`/`foundationmodels`/`coreai_ane`/`local_stt`/`tts_speech`/`video_generation`/`mcp_stdio`/`screenshot_capture`）逐一标注 `available` + 人读 `note`。判定沿用各 surface 现有真实门（`#if os()` / `#if canImport(FoundationModels,_version:2)` / `#if FoundationModelsIntegration` / `#available(27)` / `#available(26)`），不新造任何可用性逻辑——**矩阵值与运行时门逐一对齐**。
- **消费面 1（模型）**：`SystemPromptBuilder.build()` 注入 `## This device (capability matrix …)` 段（ENABLED / UNAVAILABLE 两清单 + 4 档阶梯契约），模型据此"不 claim 没有的能力、明说离线能力"。
- **消费面 2（info 工具）**：`info` 工具 + `capabilities`/`capability` topic，返回 `Runtime on <os> <ver> (<arch>); capabilities: name=on/off…`。
- **消费面 3（客户端）**：`GET /v1/capabilities`（公开路由，入 `AuthMiddleware.publicPaths`），wire JSON `{os, version, arch, capabilities:[{name,available,note}]}`。
- **base prompt 诚实化**：`running on macOS` → `running on Apple hardware (macOS or iOS)`（iOS 上不再撒谎；不破坏 `SystemPromptContractTests` 任何断言——其 pin 的是 "coding agent"/"use your tools" 等，非 OS 名）。
- **OS 事实真值**：`osName` 用 `#if os()`（非字符串 parse——Foundation 的 `operatingSystemVersionString` 形状随 SDK 变化，macOS 27 已返回 "Version 27.0 (…)" 无系统名，字符串匹配会失真）；`osVersion` 归一为 `<osName> <major.minor> (Build …)` 稳定形。
- **新增守卫 `RuntimeCapabilityTests`（9 测试，精确 contract）**：9 surface 名全在、无重名、note 非空、`agent_loop`/`mlx_inference`/`tts_speech` 恒在（4 档底）、`tierTruthSection` 载明 4 档、prompt 真带该段、os 事实非占位、`info` 工具已注册。
- 门：`swift build --target ocoreai` exit 0；`RuntimeCapabilityTests` 9/9 绿 + `SystemPromptContractTests` 7/7 绿；全量 `make test-ci` 见基线。零行为漂移：未新增任何推断/运行时逻辑，仅把既有编译期门语义收敛为一份可读真源 + 暴露面。

**09-18 主配置面 12-factor：最小手写 config.yaml 不再被静默丢弃 + known-good 语义门（D10-ext 同类收口到主面）** — D10-ext 只修了审批策略单键；同类病还在主配置面：**13 个结构体全是合成严格 `Codable`**——owner 手写一个只含 `server:`+`agent:` 的部分 config.yaml（12-factor 惯用写法）触发 `DecodingError.keyNotFound('backend'/'models'/…)`，`ConfigSystem.load` 整份失败 → recovery → `saveDefault` 把 owner 文件**覆盖掉**（last-known-good 成了唯一幸存者，而它本身也可能来自一次未经验证的 raw-copy）。修法是行为超集 + 一条新语义门：

- **13 结构体全部改「写下的值生效、未写下的键取文档化默认」的宽容解码**（`AppConfig`/`ServerConfig`/`BackendConfig`/`WiredMemoryConfig`/`SpecDecodingConfig`/`KVCacheQuantizationConfig`/`SafetyConfig`/`AgentConfig`(已)/`ModelConfigEntry`/`SamplingConfig`/`MemoryConfig`/`MetricsConfig`/`PrefillConfig`）：owner 写了 `port: 9100` → 生效、其余键默认；未写的块 → 该块 `.default`。全量哨兵 round-trip 测试保证「宽容 ≠ 丢字段」。
- **单一解码漏斗 `decodeVerifiedConfig`**（`load` 与 `ConfigRecovery.decode` 共用）：宽容解码 + **识别键探针**——文档至少含一个识别的顶层键（7 键之一）才接受；无识别键的文档（裸标量 `42`、`broken:`、空文件、纯注释）**拒绝而非默认采纳**，堵死「垃圾文件被 default-adopt 成 known-good」的翻转。
- **`snapshotGood` 补语义验证门**：拷贝进 good 之前先过 `decode + validate`——坏文件（含「语法能 parse 但语义非法」「部分解析的残缺」）不得晋升 known-good；此前 good 只是 raw byte copy，一次坏写就污染恢复基线。
- `models.<id>` 的 `modelId` 保持必填（它是 entry 身份）——缺失时退化整个 `models` 块到默认并留痕，而不是丢弃用户其他块的配置。
- 新增守卫 **`ConfigDecodingLeniencyTests`**（6 测试，精确值）：①agent-only 最小 yaml 解码成功且 owner 值生效、未写键=文档化默认；②`server:` 部分块 owner 值生效；③`modelId` 缺失 → `models` 块退化但 agent 块存活；④**全量哨兵 round-trip 精确相等**（无字段被丢）；⑤校验仍是独立步骤（port 999999 宽松 decode 过、`validate()` 必红）；⑥**无识别键文档被漏斗拒绝**（4 种垃圾形态）。
- 门：`swift build --target ocoreai` exit 0；回归面（recovery/corruption/unified/lentiency）**23/23 绿**；全量 `make test-ci` 见基线。
- 零行为漂移：任何**完整、合法** config.yaml 的解码结果与逐字节等价（哨兵 round-trip 测试钉死）；`validate()` 拒绝坏值的语义不变；「owner 部分文件不再被 recovery 级联丢弃」是目标行为。

**09-18 审批策略单源真值：GUI / headless 两入口统一（D10）** — 活体实证抓到「同一 owner 意图按入口分裂」：GUI domain 存 `interactive`、bare CLI domain 存 `auto`，`UserDefaults.standard` 按 bundle/executable 域分裂，owner 在 GUI 做的选择在 server/API 模式下被静默丢弃。修：`~/.ocoreai/config.yaml → agent.approvalPolicy` 升为单一真源，`SettingsStore.approvalPolicyUnified` 四档解析（yaml > GUI domain > 本表面 legacy > `interactive`），`AppConfig` 新增 `AgentConfig` + `OCOREAI_APPROVAL_POLICY` env override + `.env.example` 第 22 键。

- `ConfigStruct.swift`：+`AgentConfig`（`Sendable/Codable/Equatable`，`approvalPolicy: String`，默认 `interactive`，`validate()` 白名单 interactive/auto/never），`AppConfig` 集成（`public var agent` + init 默认 + validate + CodingKeys）。
- `ConfigSystem.swift`：`applyEnvOverrides` +`OCOREAI_APPROVAL_POLICY`（`lowercased` 后写入 `agent.approvalPolicy`）。
- `SettingsStore.swift`：`approvalPolicy` getter 改走 `approvalPolicyUnified`（yaml 优先）；setter 双写（legacy domain + yaml `agent:` 块，**已存在 agent 块的 yaml 永不覆写**——用户手工编辑优先）；`resolvedConfigYamlPath()` + `testsHomeOverride`/`resetTestState()` 测试注入口。
- 新增守卫 **`UnifiedApprovalPolicyTests`**（5 测试）：①yaml 压制 GUI+own 两 domain；②非法 yaml 值回落默认；③零存储→`interactive`；④setter 首次写入创建 `agent:` 块；⑤已存在 `agent:` 块不被覆写。mutant 验证：yaml/gui 优先级交换→test 1 红→还原绿（非死门）。
- 自主回路活体实证（本轮，磁盘 ground truth）：`auto` 策略下 `write_file` 真执行（文件落地 `LIVE_PROOF_OK`，非模型自报）；`interactive`+headless 下 `write_file` **fail-closed 拒绝 + 诚实回传模型 + 磁盘无假写入**——两条权限路径端到端绿（对齐 codex `codex_delegate.rs:63`「无 UI → AskForApproval::Never」）。
- 门：`swift test --filter UnifiedApprovalPolicyTests` **5/5 绿** + mutant 红→还原绿；`swift build --target ocoreai` exit 0；全量 `make test-ci` 见基线。

**09-18 审批 tier-1 放宽：12-factor 最小手写 config.yaml 被采纳（D10 扩展）** — D10 交付后的根因审计坐实一处行为与声明不一致：tier-1（yaml 单真源）此前用**整份 `AppConfig` 严格解码**，而 `ServerConfig`/`BackendConfig` 等兄弟子结构是合成严格 `Codable`——owner 手写一个只含 `agent:` 块的最小 config.yaml（12-factor 最常见写法）会触发 `DecodingError.keyNotFound('server')`，**owner 明确写下的 `approvalPolicy` 被静默丢弃**，掉到 GUI domain fail-safe。诊断实证（独立测试）：最小 yaml 严格解码 `FAIL` / 宽松单键解码 `auto` ✓ / 完整 app 生成 yaml 两者皆可——修复是行为超集（凡整份可解码的宽松必能读出），零回归风险。
- `SettingsStore.approvalPolicyFromYaml()`：整份 `AppConfig` 解码 → **宽松单键解码**（`AgentPolicyKey`/`AgentBlock` 最小结构体），与兄弟键完整性解耦；整份校验留在真正需要它的地方（`ConfigSystem.load`：parse + `validate()` + last-known-good 快照）。
- 新增第 6 守卫 **`minimal hand-authored agent-only yaml is honored (12-factor)`**：手写最小 `agent:`-only yaml（`never`）必须被采纳。
- mutation 真门：源码头改回 strict 整份解码 → **test 6 确红**（`resolved == "never"` 断言失败）→ 还原 → 6/6 复绿。非死门成立。
- 门：`UnifiedApprovalPolicyTests` **6/6 绿** + mutation 红→还原绿；`swift build --target ocoreai` exit 0；全量 `make test-ci` 见基线。

**09-18 配置面单一真源：21 个环境变量收口 + `.env.example` 回归门（D9）** — 实证取证发现 ocoreai 实际读 **21 个环境变量**（17 个静态 `environment["KEY"]` 字面量 + 4 个 `ConfigSystem` 里 `\(...)HOST/PORT/BACKEND/MAX_SESSIONS/DEFAULT_MODEL/MEMORY_ENABLED` 的 prefix 拼接键），但 README「Configuration」只文档了 YAML + 2 个 auth 键，其余 19 键零文档、磁盘 0 个 `.env.example` —— 全新 clone 根本无从知道运行时配置面。且 `OCRE_SEARCH_BASE_URL` 默认指向作者演示机的局域网地址，他人开箱即失效却无任何标注。

- 新增 **`.env.example`**：21 键全覆盖，按 Server/Auth/Backend/Model-store/HF/ModelScope/web-tools 分组；**每一键的代码实际默认值 + 行号来源**（禁占位符，全部取自代码实测：`OCOREAI_HOST=127.0.0.1`(App.swift:816)、`OCOREAI_PORT=8080`、`OCRE_SEARCH_TIMEOUT=180`(WebSearchTool.swift:270) 等）；优先级链说明（env > `~/.ocoreai/config.yaml` > 内置默认）；`[MUST-OVERRIDE]` 标注 `OCRE_SEARCH_BASE_URL`（代码默认指向他人局域网机）。
- 新增守卫 **`Tests/ocoreaiTests/EnvKeysDocumentationTests.swift`**（3 测试）：①`.env.example` 键集 == 契约期望键集（**双向**——phantom 键、漏文档键都红）；②每期望键在 `Sources/` 真实被读（**同时接受静态字面量与 envPrefix 拼接两种读法**——4 个 `OCOREAI_*` 动态键源码里没有完整字面量，naive `contains` 会误杀，按行匹配 `envPrefix`+suffix）；③`.env.example` 无重复键行。
- 守卫真门验证（mutant 双向）：删一个 `.env.example` 键→**确红**（`HF_TOKEN` 报 phantom 缺失）→还原绿；向契约键集塞 `OCRE_FAKE_NEW_KEY`（模拟代码新增未同步文档）→**确红**→还原绿。证明非死门。
- README「Configuration」补 **完整 env 变量参考指针**（21 键面 + 链到 `.env.example` + 守卫测试说明）。
- 零行为漂移（纯文档+守卫，不动任何运行时读取逻辑、不动 env 优先级链）。
- 门：`swift test --filter EnvKeysDocumentationTests` **3/3 绿** + mutant A/B 双向红→还原绿。

**09-18 ModelScope 端点单一真源收口（「两次数据不一致→不信任」硬化为回归门）** — 同一 `MODELSCOPE_ENDPOINT` 语义在三个文件里给了两个不同的默认端点（`ModelScopeSearchClient → modelscope.cn` vs `ModelScopeDownloader`(73/98) + `HubConfigFetcher`(25) → `www.modelscope.cn`），且拼接方式也不一致（`URL.append(path:)"api/v1"` vs `String + "/api/v1"` 字符串拼接）——违反仓库自定的「两次数据不一致→不信任」铁律。根因不是没设计:`HubConfigFetcher.modelScopeEndpoint()` 注释明写 *"Shared with ModelScopeDownloader and ModelScopeSearchClient"*,单一共享解析器**已存在,却没接线**——另两处各自硬编码了自己的默认。

- 真源下沉到 `ModelStore.modelScopeDefaultBaseURL`(该 `enum` 已是 ModelScope 路径的单一真源:`msSubRoot`/`msRoot`,同一 `Models` 命名空间,三文件都同 target 可引用)——值取 `https://modelscope.cn`(与上游 omlx Python SDK `ms_downloader.py` 3:2 占优值一致、与 `HubConfigFetcher` 注释里的根域表述一致;`www.` 是别名根域,两域都可达,选 canonical 更稳)。
- 三处消费方 `ModelScopeSearchClient.defaultBaseURL()`、`ModelScopeDownloader.init` + 自定义端点判定(`!=` 比对)、`HubConfigFetcher.modelScopeEndpoint()` 全部改读 `ModelStore.modelScopeDefaultBaseURL`,**不再自带端点字面量**。
- 新增回归守卫 `Tests/ocoreaiTests/ModelScopeEndpointSourceTests.swift`(3 测试):①真源默认值 = 精确值校验;②`HubConfigFetcher.modelScopeEndpoint()` 与真源**API 级**一致(防未来加一个 `func modelScopeEndpoint()` 又硬编码回去);③**全库字面量守卫**——用 `NSRegularExpression` 扫 `Sources/` 全部 `.swift`,匹配 `"https?://…modelscope\.cn"` **双引号字符串字面量 URL 默认值**,除 `ModelStore.swift`(真源,豁免)外出现即红。正则只咬代码默认值(双引号包裹),不误报注释里的域(如 Downloader:49/58 的反引号 docstring、HubConfigFetcher:6 的路径示例)。
- 守卫真门验证(mutant 注入法):在 `HubConfigFetcher.swift` 追加一行 `let __mutant_bad_default = "https://modelscope.cn/…"` → 守卫测试**确为红**(`offenders → ["HubConfigFetcher.swift (1)"]`)→ 还原后**确为绿**。证明不是死门,真能锁住"端点默认只允许出自单一真源"。
- 零行为漂移(两域功能等价,只是字符串归一);`MODELSCOPE_ENDPOINT` env 覆盖路径不变(三处都是 `?? ModelStore.modelScopeDefaultBaseURL`,env 优先级保持)
- 门:`swift test --filter ModelScopeEndpointSourceTests` **3/3 绿** + mutant 红/还原绿双向证明

**09-18 交付物硬伤修复（App 图标缺失 + 系统版本 floor 自相矛盾）** — 两个「可交付产品」最显性的交付缺陷，逐个核到根因再落地。

- **App 图标缺失**：`.app` 无 Dock/Finder 标识，App Store 直接 Defect 1051 "No icns file" 硬驳回。根因不是没设计，是 `scripts/build-app.sh` 的 `Info.plist` 声明了 `CFBundleIconFile=AppIcon.icns`，却**从未把任何 .icns 放进 bundle**——全仓 0 个 .icns、全 git 史 0 次。落地：新增 `scripts/make_icon.swift`（纯 Apple `CGContext` 自绘产品 mark：深蓝 tile + 同心「执行环」+ 亮核心 + 右上「agent 节点」，零三方依赖、可复现重建）→ `sips` 出 10 尺寸 rep → `iconutil` 成 `resources/AppIcon.icns`（297KB，含 ic12/1024）→ build-app.sh 新增步骤 4 把它拷进 `Contents/Resources/`。
- **系统版本 floor 自相矛盾**：`Package.swift` 声明 `.macOS(.v14)`、README 徽章「macOS 14+」，但 4 个 `Info.plist`/打包脚本 `LSMinimumSystemVersion` 全写 `15.0`——同一产品对最低系统给两个答案。全库审计：代码本就 14 兼容（唯一 macOS15+ API `AudioIO.swift:126` 已用 `#available(macOS 15, *)` 运行期门控），floor 差异 = 纯配置漂移。4 源全对齐 `14.0`。
- 门：`swift build --target ocoreai` exit 0（21.85s，纯打包层改动零代码回归）；交付 `.app` `LSMinimumSystemVersion="14.0"` + icon 10 维 rep 在位 + `codesign --deep` 后 `valid on disk` + `satisfies its Designated Requirement`。

**09-18 FM 流式路 delta 语义修复（红→绿，未提交 WIP 收口）** — 上一轮把 `fmEmit` 从单参 `responseText` 改成 `fullText`/`deltaText` 双参（`ReasoningEventEmitter` 是有状态扫描器，喂 fullText 会重复路由；reasoning entry 需在快照间去重），但两个 `collect()` 调用点停在旧签名——会话开始时工作树是红构建（`missing argument for parameter 'deltaText'`），HEAD 本身是绿的。本轮验证 `collect()` 语义 = 一次性全量（无增量快照序列，与 `L2745` 注释"本机 macOS 27 下 SDK 的 AsyncIterator 不产出 snapshot"一致）→ 两处调用点按"全量=full,全量=delta"收口：

- guided 支（`L2735`）：`fmEmit(fullText: text, deltaText: text, entries:)`（`text = (try? String(full.content)) ?? ""`）
- regular 支（`L2758`）：`fmEmit(fullText: deltaText: full.content, entries:)`
- 零行为变化（单快照 full==delta 是恒等喂入）；红构建归零，交付面恢复"build exit 0"基线。
- 门：`swift build --target ocoreai` exit 0（6.8s）；`make test-ci` **1914 tests / 355 suites 全绿，MAKE_EXIT=0**（含 CoreAI 活体生成段）。

**09-17 安全原则落行为面（`safe and helpful` → 三原则）** — 声明的原则与真正注入模型的措辞脱节：`SafetyConfig`（代码默认 `enabled: false`，"no category is non-negotiable"）和注释都写死了"最大求真 + 最大好奇心 + 诚实，而非人类偏好对齐"，但每次会话实际灌进的 base prompt（`SystemPromptBuilder.codingAgentBase`，`App.swift:324` 唯一注入点）第二句还是 `"You are expected to be precise, safe, and helpful."` —— "safe and helpful" 正是偏好对齐措辞，三原则字一个没进。本轮把声明打进落点：

- `codingAgentBase` 行为定调替换为三原则的模型可执行形式：`maximize truth-seeking, curiosity, and honesty above pleasing anyone… never hide, soften, or fabricate results`；action-first / 验证报告 / 破坏性命令 guard 契约全部保留（6 条既有断言锚点零改动）。
- 契约测试 `SystemPromptContractTests` 新增 `principleNotPreferenceAlignment`：锁 `truth-seeking / curiosity / honesty / never hide, soften, or fabricate` 存在 + `safe, and helpful`、`safe and helpful` **不得回流**（防静默回退门）。
- 全仓复查：`safe (, )?and helpful` 注入面 0 残留（仅剩注释引用/断言字面量）；`precise, safe` 0 残留；并行 system-prompt 注入点 0 处（唯一调用点 `App.swift:324`）。
- 门：`swift build --target ocoreai` exit 0（7.67s，仅存量 warning）；`swift test --filter SystemPromptContract` **7/7 绿**（含新契约锁）。
- 与 `SafetyConfig` 的关系：代码默认（filter 关）= 原则默认；base prompt = 原则的行为化注入；契约测试 = 不得回落到偏好对齐措辞。三层一致，声明与落点闭合。

**09-17 upstream pin audit (11-reference-repo sync)** — 11 仓全量 ff 对齐 origin/main 后核对消费面：

- **mlx-swift-lm `3e6ea1e → c6446cf`（#620，吸收）** — `TokenIterator.next()` 的 buffer-cache 清理改为**首 token 即清**（检查移在 `tokenCount += 1` 之前，对齐 mlx-lm 节律）；此前短生成（<256 token）从不释放 buffer，反复短请求 cache 无界增长。ocoreai 消费面 = ChatSession/generate 内部 `TokenIterator`（无自建迭代器），pin bump 即吸收，零 in-tree 改动。`swift build --target ocoreai` exit 0；`make test-ci` **1880/1880 tests / 350 suites 全绿**（含 CoreAI 活体生成段）。
- **coreai-models `e282dbd(旧基线) → 7359dbc(新 HEAD)` 4 commit 逐条核验** — `#250`(257008b) llm-server async request queue = 上游工具树(`Tools/llm-server`)，ocoreai 0 消费，consumer-transparent；`#237`(62ff88b) pipelined prefix last-token clamp **已吸收**（`cd9e901` + `Pip5PrefixClampTests` 5 精确值锁）；`#248`(3e172fb) static-shape 引擎 guided-gen support 报表短路（`loadedEngineIsConstrainedCapable` 非 nil 即早退，logits-only fallback 永不跑）—— ocoreai 派生走 capability-first dispatch（`EngineInference.swift:513-514` `grammarSchema != nil || useGuidedGeneration` → `as? ConstrainedGenerationCapable` → 否则 sequential CPU 路），**无该报表 wrapper**，bug 不存在；`#249`(7359dbc) VLM sequential 引擎共享 KV/`GenerationTokenBox`/`runChunkedPrefill` 重构 = 行为等价的内部抽象（ocoreai `CoreAISequentialVLMEngine` 的 hand-rolled KV 语义与上游重构前一致，growth 2x/initial 256 不变）。**结论：0 新增吸收、0 行为分叉。**
- **其余 8 仓（mlx-swift `2bebe4e` / mlx-swift-examples `378f244` 已 HEAD / vllm `fc8132a5` / vllm-metal `176bad6` / sglang `b02e16a8` / omlx `65c65e3` / codex `fd346b8dba` / openclaw `f9a7f104c22` / hermes-agent `47685348ea`）** — omlx 增量全落 serving 面（MTP cache rebuild / OQ imatrix calibration / admin dashboard / zh-Hans i18n / Qwen tool-call 流恢复 `_NakedFunctionBoundary` 自研路径）；ocoreai Qwen tool-call 走 upstream `ChatSession` 原生 parser，omlx 该恢复器为 omlx 自有 XML 路径的补强，**非 ocoreai 消费缺口**（ocoreai 无同款 naked-function fallback 路径可对齐）。vllm/vllm-metal/sglang 落服务端（ROCm/EPD/router），0 Swift 消费面。codex 增量落 TUI/daemon/Guardian/sandbox 面（`#45987` Guardian action prep 集中化 / `#45820` daemon restart 续做），ocoreai Agent 轴已吸收面（turn/sleep/approval/compaction）不变；Windows/WSL sandbox 面 ocoreai 无对应物（macOS/iOS only）。

**09-17 ANE-VLM factory lane (detector→factory gap closed)** — 09-16 落的 `VLMBundleDetector` 的 docstring 自始就引用着一句还没写的 `EngineFactory.createVLMEngine`；本轮把断口补上：

- `EngineFactory.createVLMEngine(config:metadata:bundleURL:options:)` — 三组件（main/vision/embedding）asset 解析（`.aimodel`/`.aimodelc` 双形态，`componentPath` 缺件 → 精确 `modelNotFound` 命名缺失 role）→ 三个 `PreparedModel.prepare`（沿用 LLM 路的 structure probe + specialization options ANE-rewrite 崩溃守卫）→ `CoreAISequentialVLMEngine`。
- **vision-block 契约对齐上游 `LanguageBundle`(L52-53)** — `kind == .vlm && visionConfig == nil → missingField("vision")`：`VLMBundleMetadata.isVLMBundle` 只查 asset key（宽松检测），工厂 re-enforce vision block，缺 vision block 的 bundle 在此以精确 `invalidArgument` 失败，不猜 CLIP 默认值造垃圾 embedding。
- `EngineFactory.createEngine` 入口加 lane 推理 — VLM bundle（`VLMBundleDetector.load` 非 nil）走 `CoreAISequentialVLMEngine`，LLM bundle 走原 structure-detect 三变体（零行为变化）。
- `EngineInference` ANE gate 措辞刷新（回退保留）— `VLMBundleDetector.swift:124` 已坐实 ANE+multimodal 无消费方时 GPU 回退正确；本轮工厂侧补完后，剩余缺口收窄为一条：**多模态消息 →（placeholder tokens + `InputEmbeddings`）组装**（上游 llm-runner `runVLMGeneration` 的 in-tree 对位）—— 需活体 VLM `.aimodelc` bundle 做验证门，落码前不动手（09-17 纪律）。
- 测试：`ANEVLMFactoryRoutingTests`（VLM bundle → `isVLMBundle==true` + 三角色路径全解析 / LLM-only bundle → `load==nil` 走 LLM 路 / 无 metadata → `load==nil` / VLM 检测过但缺 vision block → 工厂精确 `invalidArgument`，断言错误文案含 `missing 'vision' block in metadata.json`）。
- 顺手清 `EngineInference.fmEmit`（L2608）冗余 `#available(macOS 27.0, *)`（外圈 L2396 scope 已保证）—— 构建 0 项目警告。

**09-17 ANE-VLM 装配层（上游 llm-runner 纯函数面对位）** — 把上面"剩余缺口"再拆一层：缺口 = **纯 token 序列装配**（可验，不需 VLM bundle）+ **运行时接线**（`encodeImage`→`scatterMerge` E2E，需活体 VLM `.aimodelc` 验证占位符数与 vision 编码器逐图 token 数一致）。本轮落前者：

- `VLMTokenAssembly.assembleVLMPrompt(tokenizer:promptText:imageTokenId:imageTokenCount:)` — 1:1 对位上游 `buildVLMPromptFromChatTemplate`(L1263-1282) + `runVLMGeneration` fallback(L1138-1143)：模板含 1 个 placeholder → 展开 N 份保留前缀；**模板缺失或模板无 placeholder 双双回落 fallback**（`USER: <N×placeholder> ASSISTANT:` 字面形，精确复刻上游 L1280 `guard foundPlaceholder`）；多 placeholder 只展第一个；count0 移除占位符。
- 纯函数 + `VLMTokenizerOperations` 闭包注入（`encode(text:addSpecialTokens:)`/`applyChatTemplate` 与 swift-transformers `Tokenizer` API 1:1），tokenizer 可注/可验，无 `#if canImport` 门、全平台可测。
- `EngineInference` ANE gate 收紧 — `gate = runtimeAvailable && !hasMedia && hasCoreAIAsset`：任何媒体请求不再可能落到 ANE 纯文本分支（此前 `!hasMedia || supportsMultimodal` 措辞曾把 media+VLM-engine 放行进文本路 = 静默丢媒体，已修正），回退 GPU（MLX 路消费媒体正确）；gate 失败日志按"无 asset / 带媒体"两分支精确化。
- 测试：`VLMTokenAssemblyTests` 8 个精确值断言（展开位置保持 / 多占位符只展第一个 / count0 移除 / 无 placeholder fallback 全串逐段匹配 / 模板存在但无占位符 fallback / fallback 多行形 / 纯函数幂等）。
- 门：`make test-ci` **1884→1892 tests / 352 suites MAKE_EXIT=0**；构建 0 项目警告（4 个存量 `destView`/`resolvedSize` 警告在未触碰的 CoreAI 引擎文件）。
- **诚实边界**：装配层仍未接入 ANE 运行时（接线需活体 VLM bundle 做 `encodeImage` → placeholder 数一致性验证门，本机全盘 find 无 `.aimodel`/`.aimodelc` 资产 = 硬环境约束）；gate 保证 media 请求零静默降级。

**Security: headless approval fail-closed (codex `codex-rs/exec/src/lib.rs:566` alignment)** — wire-HTTP consumers are external processes; the `.interactive` (`.ask`) approval verdict can no longer park them on the in-app broker (who would approve for a foreign process?). The gate now coerces `.ask` → fail-closed denial on the headless surface, before any broker routing:

- `InferenceOptions.headless` (default `false`) carries the surface flag from the three wire handlers (Chat/Completions/Anthropic) through `EngineInference` toolDispatch closure + `FMToolProxy.tools` (macOS 27 FoundationModels path) to `ToolRegistry.call(..., headless:)` → `securityGate`.
- MCP external path (`securityPrecheckExternal` / `securityElicitationAccepts`) keeps its existing broker semantics (`headless: false`) — no behavior change there; local-UI/DirectInferenceClient paths are byte-identical (`headless: false` default).
- New gate branch tested by 3 exact-value tests in `ApprovalTests` (headless `.ask` → denied with exact reason + no broker row created; `.deny` hook authority survives headless; in-process `.ask` still parks + resolves via GUI broker). `make test-ci` 1842→1845.
- Live E2E (gemma-4-e2b, loopback wire): external `write_file` request → immediate `denied: interactive approval is not available on this (headless) channel` surfaced as a tool-result, **HTTP 200 in 6.1s** (pre-fix RED: HTTP 000 / 25s client timeout / indefinite broker park). GUI park-and-approve flow unchanged.

**Security hardening** — three commits close real trust-model gaps identified in 09-13 audit:

- `d01d01e` **Security (server):** refuse non-loopback bind without `OCOREAI_API_KEYS` — new `ServerAuthGate` middleware (`Sources/ocoreai/Middleware/ServerAuthGate.swift`) + `App.swift:799` wiring; throws `RefusedToServeError` on non-loopback/auth-off cell (omlx `09a7c43` baseline). README/CONTRIBUTING auth lines updated.
- `eadd36d` **Security (memory):** SecretRedactor baseline at the tool-result chokepoint — verbatim port of the four regexes from codex `codex-rs/secrets/src/sanitizer.rs` (order + replacement marker kept), openclaw `dcf3baa8535` (#146596) as the independent second reference; closes the shell/.env/config → tool-result → model-context leak (previously zero masking on that path).
- `a2fe611` **Security (memory):** treat recalled memory as *data*, not instructions — closes prompt-injection-via-memory surface.
- `2451d15` **Docs:** add `SECURITY.md` (threat model + reporting); fix stale ANE-VLM fallback log wording.

**CoreAI VLM absorb (coreai-models `cc81207`)** — 4 commits bring sequential VLM engine + foundation layer into ocoreai:

- `4517ca3` **Core (VLM foundation):** absorb `VisionConfig` / `ImageStrategy` / `ImagePreprocessor` / `VideoInput` / `InputEmbeddings` + 19 exact-value tests (Foundation layer only, no `.aimodel` floor).
- `bcc55fb` **Feat (CoreAI):** absorb `CoreAISequentialVLMEngine` from coreai-models HEAD.
- `979e6aa` **Fix (CoreAI):** gate `CoreAISequentialVLMEngine` behind `#if canImport(CoreAI)` (macOS 27 floor, matches upstream).
- `3af3227` **Audit:** add `CoreAIVideoInput` / `CoreAIImagePreprocessor` to Class-B vendored-file whitelist.

**09-11 upstream pin audit (mlx-swift-lm / coreai-models / codex)** — `e21bb3d` bump `mlx-swift-lm` pin `4c3d793 → 604fae7` (+4 commits, all fix): `#584` RotatingKVCache trim wrap-aware (correctness), `#597` LoRA config metadata discovery, `#611` generation worker cooperative-scheduling, `#615` Gemma4 VLM float32 softcap fusion. `Package.swift` no new deps; ocoreai does not in-tree override any touched file. `7fb6b67` **Docs:** coreai-models 引用基线刷新 `cc81207` (09-11) — `b91bb18..cc81207` 8 commit 全核, 新 5 个消费面 0 吸收 0 缺口 (`#238/#214/#242/#239/#229`).

**CoreAI absorption (coreai-models #240 / #244)** — two correctness fixes from upstream:

- `e45d8ee` **Core (CoreAI #240):** layered prefill chunking (`0d6c0bf`) — large-prompt prefill no longer OOMs on long-context models.
- `49c3998` **Fix (sampling, coreai-models #244):** feed neutral penalty tensor on non-penalty paths (previously `RepetitionPenaltyGPUState` saw uninitialized refCounts → sampling drift).

**CoreAI sequential/pipelined engines + guided-gen — 09-07 `5e45dd0` / `f385c2f` + 09-10 `3dd27c4`:**

- `5e45dd0` **CoreAI pipelined (#212):** the old pipelined engine sized `S=1`/`GDN` models on the 256-row static `[1,1,vocab]` logits descriptor → `init` crash (qwen3.5 GDN class triggers immediately). `InputLayout` ported (name-resolution `in_new_token_ids`/`pos_ids` + strategies; static detection pins `chunk(1,1)`) + the 3 pipelined gates read layout; `InputLayoutTests` 8 cases, `make test-ci` 1590/298 全绿.
- `f385c2f` **CoreAI sequential (#227):** the follow-up absorption (upstream: "All three engines now use it") — name extraction `inputNames[0]/[1]` / `outputNames[0]` → `InputLayout.analyze` (`in_new_token_ids`/`pos_ids` variants no longer position-crash). static-shape verified to have no counterpart (no gap).
- `3dd27c4` **Guided-gen:** absorb `incompleteOutput → keep emitted partial text` (upstream alignment).

**MCP spec alignment (codex axis, 2025-06-18 spec)** — 09-07 four commits close consumer-side gaps:

- `3ef0aa9` **MCP wire:** align spec `2025-06-18` — `elicitation` capability + `elicitation/create` method name + version negotiation.
- `f289b15` **MCP (codex `555b82afa9`):** elicitation inbound request response surface — user-verification absorbed.
- `12b96b1` **MCP `structuredContent`:** 2 decode sites were silently dropping it — unified to `decodeToolCallResult` single-source (codex `models.rs:2258-2297` priority chain `structured > content`, arbitrary JSON `Value` serialization); `JSONValue` type-identity fix for `NSNumber`/`Bool` bridge; local-dispatch protocol-level failure guard (close `.never` safety-bypass regression); 9 exact-value tests, `make test-ci` 1603/300 全绿.
- `c0f613c` **MCP param-shape fidelity (Red→Green):** `number → .number` (float, not truncated int) / `object` recursive `properties + required` (not flat string) / `array` items / `required` subset pass-through (not all); `MCPSchemaFidelityTests` 5 tests; `make test-ci` 1582/297 全绿.

**Tool-calling surface** — 09-06 4 commits + 09-13 `2fd463f` wire the tool surface end-to-end:

- `bada388` **Tools:** 25/27 tools with real schema through the full pipeline — `DynamicGenerationSchema` path + `toToolSpecs` `items/required/properties` fill + full test-gate.
- `448b587` **Fix (Tools):** `ToolEntry` missing `description` field (typed side dropped it on receive) + `toToolSpecs` double-backslash escape (source text leaking to model) + MCP external-tool description pass-through; RED→GREEN 3 new tests (10/10); `make test-ci` 1576/295 全绿.
- `5939fd7` **FM tool-call fixes (3):** `Arguments` `String → GeneratedContent` (correct contract channel).
- `3fc02fd` **FM `capabilities`:** add `.toolCalling` — missing declaration caused tool-carrying requests to 500/0-token; upstream baseline `MLXLanguageModel.swift:313`.
- `2fd463f` *(09-13)* **Extract `StdToolCallRecovery` policy** + 6 exact regression-trap tests (previously inline in `EngineInference`).

**Reasoning / think-tag alignment** — 09-11/12 four commits close the think-marker fork:

- `74247c5` **Fix (parsing):** align think-tag markers to the Qwen3.5 model family (upstream-verified; `ThinkTagParser` literal `think` byte-identity with upstream confirmed by hexdump `3c 74 68 6e 6b 3e`; ocoreai's `"<think" + ">"` concatenation is an ocoreai convention, functionally equivalent).
- `53965bb` **Fix (wire):** non-stream content fallback when the reasoning channel carries the whole answer.
- `4b806b7` **Fix (wire):** streaming fallback for the same case.
- `eb7d1a5` **Fix (reasoning):** separate non-streaming reasoning from content; audit sub-second duration.

**Wire / stream hygiene** — 09-09 6 commits:

- `e00f50b` **Wire:** `OutputSanitizer` non-stream output purge — byte-level marker evidence, strip thinking span + fake tool-array.
- `4e2535f` **Wire:** streaming purge `StreamOutputFilter` — any-chunk `content ≡ strip(whole)`, thinking flows via `reasoning_content`.
- `efbddfa` **Wire:** SSE terminator unified on a single source of truth — fix `ChatHandler` lowercase `[done]` drift.
- `3466cc9` **Wire:** context-exhaustion wall upgraded to typed `400` (hermes-agent `#106260` three-part absorption).
- `f45bb39` **Fix (http):** structural `model-id 404`, stop masking as `503 engine-unavailable`.
- `c55d1d3` **Close GAP-4 chain:** budget-truncation badge reaches the user (previously the token budget exhausted silently).

**Agent loop / recovery (codex axis)** — 09-09/09-10 5 commits:

- `df67fda` **Agent-loop:** tool-handler failure → surface to model for recovery (codex semantics; previously the failure aborted the turn).
- `d5f5b55` **Fix (config):** `models.<id>.enabled` dead field wired to consumption + download log honesty.
- `8622818` **Fix (FMToolBridge):** tool-handler failure feeds back `[tool_error:]`, eliminate FM/MLX behavior fork.
- `6071133` **Fix (engine):** silent-failure three fixes — warmup fake-success honest log + late-`markActive` downgrade + tokenizer registration wiring.
- `d019be2` **Fix (stream):** `.error` event no longer injected into assistant content — SSE diagnostic marker, align non-stream self-correction semantics.

**Video / media** — 09-08 3 commits close the VLM media path:

- `311be24` **VLM wire:** vision silently dropped — root cause `CodingKeys` + direct path with image + wire contract lock.
- `68a3088` **Media routing gate** extended to video/audio (previously only `image` was routed).
- `cdd2f34` **Video E2E real:** `VideoURL.maxFrames` non-optional poisons array decode + `makeMLXVideo` `data-URL → temp file` + `real-client-shape` contract tests.

**Model download** — 09-11 3 commits close the HF/MS layout fork:

- `448605a` **Model download (M8):** HF flat layout + local-first short-circuit (`ReadyHubDownloader.flatRoot`).
- `456ebdc` **Model download (M8 follow-up):** point HF progress poller at the flat dir.
- `71b2885` **Models:** stop `ensureLayout` pre-creating provider subdirs (`huggingface/modelscope/local`) — single root `models/<org>/<name>/`, omlx-aligned.

**Scheduler / memory** — 09-14 2 commits:

- `1c5628b` **Feat (scheduler):** typed OOM refusal with budget snapshot (previously the OOM was a bare `500`).
- `361da25` **Test (scheduler):** live-chain coverage for typed OOM refusal (新行为类型无测试 = 未交付).
- `9c7844f` **Sessions:** session↔worktree binding persists via conditional migration (on top of `a1f81dd` per-session worktree workspace seam, codex `new_worktree` parity).
- `121d8d9` **i18n:** wire remaining hardcoded UI strings into `StringKey` (en + zhHans full tables); `066607b` the last 3 hardcoded VoiceOver labels (en + zhHans).
- `7be6f76` **Hygiene:** drop two dead `await` on synchronous `@MainActor` call sites. `4f89cc1` two compile-warning anti-patterns removed from `ConfigRecoveryTests`.
- `6061278` **Docs:** 6 文件漂移修复 — AGENTS pin/行号/计数+Documentation Map, README/README.zh, CHANGELOG, CONTRIBUTING CLI/PR 模板, ARCHITECTURE LOC 刷新.
- `2765a83`/`1bf1932`/`06a4e78` **CI:** Static Audit 白名单补齐 (SessionWorkspace `errorDescription` = LocalizedError 先例) + 收 Static Audit 一直掩盖的两处编译断裂 — ① macOS 腿 `defer { await store.close() }` 移至函数尾; ② iOS 腿 `Foundation.Process` 加 `#if os(macOS)` 门控 (同 ExecTools 先例). 26 步全绿.
- `4dd3582` **Fix (UI/wire):** 对话气泡多余输出双根因 — ① `removeToolCallArrays` 假 tool-plan 数组泄漏进气泡; ② think-tag 正则 `regexEscape` 双重转义 + `splitThinkingTags` `|` 未转义致答案被吞. `OutputSanitizerTests` 全绿.
- `ce19f98` **Refactor (parsers):** 三份重复 think-tag 清洗栈收敛为单一 `OutputSanitizer`（家族表 + `scanThoughts`/`stripThinking`/`splitThoughts`）— 成为 wire 唯一契约; `ChatViewModel`/`TTSCleaning`/`StreamOutputFilter` 全部委托; 黄金不变量 `StreamOutputFilter.concat(deltas) == OutputSanitizer.strip(raw)` 锁死 + 新增 UI↔wire parity suite. `make test-ci` 1837/1837 全绿 + CI 5 jobs 全绿.
- `cd9e901` **Fix (CoreAI, coreai-models #237) + upstream pin bump:** absorb the pipelined-prefix last-token clamp (`commonPrefix.count` 先 clamp 到 `history.processedTokenCount` 再 `.prefix`, `lastPrefixHitCount` 移至 clamp 后) — 上游 `#237` fixes `#234`（pipelined 引擎 prefix clamp 越界）; in-tree 派生不跟 SPM 走, 逐行核对派生段现状后移植 10 行, 新增 `Pip5PrefixClampTests` 5 精确值回归锁（用生产 `TokenHistory.resolve` 断言, 比上游 MockEngine 复制更强）。**Upstream pin:** mlx-swift-lm `604fae7 → 3e6ea1e`（`#548` + `#515` 纯上游增量, 零新增 API, ocoreai in-tree 不 override 任一触达文件）; `62ff88b` 为 coreai-models 关键基线。本地 `make test-ci` 1842/1842 全绿。
- `d412efe` **Fix (tests, floor-SDK):** `Pip5PrefixClampTests` 整块 `@Suite` 套 `#if canImport(CoreAI)` — 修掉 `cd9e901` 在 **macos-26 地板腿**的编译断裂 `cannot find type 'TokenHistory'`（`TokenHistory` 在 CoreAI 门控内, 地板腿 Xcode 26.6/SDK 26.5 无 CoreAI → 类型不存在）; 本地真门用 Xcode 27 RC（有 CoreAI）故此前 1842 全绿的假象掩盖。抄既有范式 `CoreAIVisionConfigTests` L133-307。CI 5 jobs 全绿。教训: 本地真门只覆盖顶配 SDK, **引用 CoreAI 符号的测试必须 `#if canImport` 门控**, 地板形态由 CI macos-26 腿裁定。
- `0cbb833` **Fix (tests, ExecSessions cascade 竞态):** `spawnExitCascade` 删掉对 `spawn(yieldMs:500)` 结果 `res.completed` 的 in-window 硬断言 — yield 契约是 best-effort, CI runner reaper 合法 >500ms 时 `drainBlocking` 正确返回 `completed:false`（codex regime 语义）, 原断言在罚正确行为 → 反复 CI flake（也正是 `cd9e901` 地板编译错被误读为 "runner wedge" 的干扰源）。保留精确退出码 7–11 + 15s 有界守卫（08-26 无限挂死回归防线）, 把完成性断言改落在 **poll** 上（empty-stdin regime clamp 5s finalize 窗口; 已 finalize session 在 `writeStdin` L344 短路直返 → 确定性）。Locally: build exit 0, ExecSessions 19/19, `make test-ci` 1842/1842 全绿。


**Also in this window (09-05 → 09-14):**

- `7060acd` **Agent:** coding-agent base prompt 行为契约 (codex 轴对齐).
- `8f7a511` **P0-2:** `tools` 请求路由回 native tool-dispatch loop + OpenAI wire 蛇形键补全. `fe9b4bd` **P0-3:** 尊重客户端 `tools[]` 白名单语义 (声明则收敛注入面, 零声明则 registry 全量, 本地优先).
- `d599904` **Fix:** grammar schema JSON 崩溃 — `flattenSchemaJSON` 递归全深度扁平化. `d4b2546` **Fix:** `ContextStatusStore` 并发污染 — `enforceContextWindow` 加 store 注入缝, 测试全套私有化.
- `4c11b16` **Engine:** bounded rejected-tool-call recovery on std path (500→200). `60460ab` 推理错误面保留原错误语义 (`GuidedGenerationError` 不再被吞).
- `3ae9f24` **Fast path:** 原生路径对齐 HTTP 工具路由契约 — `hasNativeTools`/`declaredToolNames` 镜像 ChatHandler, UI 接线注册表工具面.
- `59df1f8` **Workspace:** working-directory + `AGENTS.md` injection (codex `agents_md.rs` baseline).
- `b5a0c47`/`b5ea073`/`6a8d974` **VLM 根修三连:** `isVlm` 判定从下载前改为下载后重判 (`.vision` 无条件声明); modelURL 幻影目录 (CWD 相对) → 就绪目录解析; `listLocalFiles` 前缀双斜杠致快路径永不命中 → 重下载根修.
- `1377ea6` **UX:** 347s 冷启动零反馈修复 — 启动后台预热 + state 可见 + 瞬态可重试语义分离.
- `2765a83` **CI:** defer 内裸 async → `Task` 包裹, 修 macos-26 权威门 defer-await 编译错.
- `605acbd` **Fix (engine):** FM 路 thinking/response 事件流补齐 — 0-token 根因闭环 + `collect()` 消费. `5d84073` **Fix (Tools):** `checkFn` 注册失败补可见 warning (27 处 `try?` 不再静默吞错).
- `b22ee53` **Docs:** ANE-VLM gate 措辞纠错 (behavior zero). `33e8735` `EngineVariantRouting.fullCompatibilityTable` 注释修正 (收窄到 LLM 变体并标注 ocoreai 特异分支).
- `8b2e1ab` **Tooling:** format-check 去 `git checkout` 还原 (CI 对等, 不盲 checkout — 09-06 事故根因修复). `f1832bf` dead `jsonSchemaType` helper 删除 (09-06 code-as-doc audit).
- `2142d5f` **Docs:** `AGENTS.md` coreai-models 基准 pin 陈旧纠正 (`b91bb18→df81198`). `5a6ad81` 审计落点归位 wiki KB (`~/wiki/audits`), 移出仓内.
- `a0025e6` **Chore:** 本地隔离目录 git status 忽略.

---

## 2026-08-14 → 2026-09-04

### Features

- **MTP 投机路径补 ThinkingBudget（MLX 轴消费缺口吸收，非自造）** — 上一轮把「Dynamic Type」当真缺口（列 #2），读源后证伪：全部 `.font()` 都走集中工厂 `Theme.swift:190` 已是 `.system(textStyle(for:),design:,weight:)` 语义样式、天生随 Dynamic Type 缩放，真违规仅 1 处 `.custom()`/`.system(size:)`。本轮发现一处真 MLX 轴吸收缺口：`EngineInference` 的 **std 推理路径喂了 `applyingThinkingBudget` 组件，MTP 投机路径却喂 `components: .init()` 空组件** → Qwen3 类 reasoning + MTP 投机启用时 thinking 预算完全不生效。参照真身 = 上游 `MLXLMCommon/ThinkingBudget.swift:476 applyingThinkingBudget`（ocoreai std 路径已消费、非自造）→ MTP 路径同形接上，`guard let rc = mtpReasoningConfig` 非空才应用、`catch → .init()` 回退（与 std `L3645` 同语义）。验证：`swift build --target ocoreai` exit 0 + 全量 `make test-ci` **1568/294 全绿**（无模型集成测试无法在本机跑 MTP reasoning + budget 通电断言，待有 MTP reasoning checkpoint 后补）。

- **审批回路闭合：Stop/重置/切模型/重发 ⇒ 挂起审批一律 deny 清场（codex `Abort` 语义吸收）** — 上轮实证审批等待态的停止缺口：`cancelInference()` 是全停止路 funnel（stop/resend/switch/reload/reset 五路都过它 `ChatViewModel:374/1060`）,但此前只 cancel 推理流 + 停 TTS,审批回路（`ApprovalBroker`）不在停止路径上 → `.interactive` 策略下用户按 Stop 无法解除 `await broker.request`（`ToolRegistry:222`）挂起,只能手动 Deny。对齐 codex 真参照 `ReviewDecision::Abort → Err(ToolError::Codex(CodexErr::TurnAborted))`（`codex-rs/core/src/tools/approvals.rs:488`）:turn 终结 ⇒ 挂起裁决一律 deny。`cancelInference()` 内接 `clearApprovalSession()`（既有安全网:每行 `.denied("session-ended")`,broker 缺席时静默 no-op,`Approval.swift:207-213`）+ 可注入 seam `turnEndApprovalClosureHook`（照 `turnEndVoiceStopHook` 先例）。**不加入自造超时 timer**:codex 交互审批面自身也无超时（`history_cell/approvals.rs` 真源 0 timeout 命中）,90s `GUARDIAN_REVIEW_TIMEOUT` 是 guardian 自动审核专属（`guardian/mod.rs:62`）——按「上游未解决→不自造」不跟。`ChatStateTurnEndApprovalClosureTests` **3 条全绿** + 全量 `make test-ci` **1568/294 全绿**。

- **mlx-swift-lm pin `5694a2f` → `e3d4a20`（#602 Gemma4Text loraLayers + #589 Qwen35/3Next 编译态 + #605 await 修 + #471 ParoQuant MoE）— 上游已提交 → 必吸收 (upstream-alignment 铁律)** — 4 个 commit 全为 `MLXLMCommon`/`MLXLLM` additive 或 perf-only，逐条核 public API surface：#602 `Gemma4Text` 增 `loraLayers`（MLP adapter 加载面，ocoreai 经 `Gemma4AssistantRegistration` 注册、零直接引用 `loraLayers`）· #589 `Qwen35.swift`/`Qwen3Next.swift`/`LoRAContainer.swift`/`CompiledDecodeSegments`/`CompileOverloads`/`CompiledTrace`/`ModelConversion`/`ParoQuantLoader` 编译态重构（decode 段 perf 路径、无公共 API 移除）· #605 IntegrationTesting tests only（`await loadWeights` 5 处、非 source）· #471 `ParoQuant` MoE 扩展 + `PairwiseRotation`/`RotateSwitchGLU` + `PreparedCheckpoint`（perf、无 ocoreai 消费面）。ocoreai 消费面核验（`grep -lh` on `Sources/ocoreai/`）：`MTPDrafterModel`/`SpeculativeDecodingConfig`/`UserInput`/`loadWeights`/`Gemma4AssistantRegistration` 全 `e3d4a20` 存活（`Libraries/` 内 public refs 分别 8/2/18/2 命中）；`ParoQuant`/`Gemma4`/`Qwen3Next`/`CompiledDecode` 全 0 引用。本地门:`swift build --target ocoreai` exit 0 (20.3s,4 deps 重编译通过)。coreai-models 同步核查:上游 3 新提交(#206 ATEM / #198 Gemma 3n / #223 flaky 测试禁用),均无 ocoreai-facing parser 行为变化(ocoreai vendored `ToolCallParser`/`ThinkTagParser` 手动选择、非 auto-detect 路径), 零 API 吸收面。
- **SessionCompressor recall 三真 bug 修 + `recallPermanentMemory` minConfidence SQL bind 测试钉** — 上批 `e5ff71e` 把 `minConfidence 0.5→?` 接线为真(无 query 分支 `confidence >= ?` + `ChatHandler:617-618` 传 0.6),但 Tests/ 0 条 recall 测试钉 → 本批写 4 条精确值(阈值 0.60 真滤 0.40/0.72 / 0.05 全召回 / `>=` 边界 / memory_type 过滤)— 测试首跑就炸: **`near "?"` syntax error**。追根 = 3 个真 bug(非测试坏):
  1. **FTS5 MATCH 操作数用 join 别名**(`SessionCompressor.swift:962/1017/1026`):`AND fts MATCH ?` / `WHERE fts MATCH ? AND ...` 在 `INNER JOIN memory_events_fts fts ON ...` 上下文里**必炸 `no such column: fts`** — 探针实证:`fts MATCH 'retry'` FAIL / `memory_events_fts MATCH 'retry'` OK count=2。修复:3 处 MATCH 操作数改真实 FTS 表名 memory_events_fts。受影响:
     - `recallPermanentMemory(query: 非空, ...)` — `ChatHandler:617` **主召回路径(每回合用户 prompt FTS 检索 0.6 阈值)** 之前**必炸**,用户记忆召回链路完全断; 
     - `searchMemoryEvents(query:)` — `UI/ViewModels/SessionManager.swift:104/114` 的 UI 记忆搜索**必炸**。
  2. **`boostRecalled` SQL IN 占位符拼接**(`SessionCompressor.swift:844`):`String(repeating: "?", count: n).split(separator: ",").map { String($0) }.joined(separator: ", ")` — `repeating` 生成 N 个连贴 `?`,后接 `.split(",").joined(", ")` 是**死代码**(串里没逗号) → N>1 时生成 `IN (??)` **必炸**;N=1 偶然不炸。修复:`Array(repeating: "?", count: n).joined(separator: ", ")`。受影响:`recallPermanentMemory(无 query)` 命中 ≥2 条时 `boostRecalled` 必炸。
  3. **同模式 `expandByCues` Phase 2 context spread**(`SessionCompressor.swift:884`):同款死代码 → N>1 时 `IN (??)` 必炸;同款修。
  5 条全绿(阈值 0.60 / 0.05 / 边界 / memory_type 过滤 / **query 多行命中 expandByCues 多占位符不炸** 回归)。

- **`ThinkTagParser` 吸收 coreai-models #206 `b91bb18`（agentic mode 流式硬化 + `stripReasoning` 静态 API）** — 上游 `b91bb18` 对 agentic 路径做 5 条硬化：`consumeEntryMarker`（同时处理 first-turn ` to=<target><|message|>` 和 continuation-turn `<|start|>assistant to=<target><|message|>` 两种 routing-header 前缀，失败不破坏 buffer）· `isPartialRoutingHeader`（流式中 routing header 跨 consume 边界未收全时 hold back，防 `<|sta`/`assistant ` 半 token 泄漏到用户面）· `drainAgentic` 重写为这两者驱动 · `static stripReasoning(from:format:)` 统一 tagPair + agentic 的整串剥离（`#206` 把它从 executor 私有提为公共 API）· `ATEM` 函数调用块（`<atem:invoke>`/`<atem:parameter>`）路由为 text 而非 reasoning。ocoreai vendored（2026-08-21 仅并入 #182 base）对这 5 条全为 **0/0/0/0 缺失**，上游 `b91bb18` = **2/2/1 + 2 静态方法**。本批按 copy-first 逐字吸收 `ThinkTagParser.swift:118-152` / `156-171` / `173-219` / `280-290`，保留 ocoreai-ahead 的 `promptEndsInsideReasoning`（`EngineInference:435/890/1027` 消费）+ `init(primedInside:)`（上游 684ae8e 无同物）。新增 `Tests/ocoreaiTests/AgenticThinkTagParserVendoredTests.swift` — 上游 `AgenticThinkTagParserTests`（111 行）8 条精确断言搬入 `ocoreai` target（`@testable`）：first-turn 路由 · 首 turn 推理后 ATEM 透传为 text · continuation-turn bare eom · **streaming 分片 routing header 不丢不串** · **streaming 半 header hold back 防泄漏** · generic `to=<tool>` 路由 · `stripReasoning` agentic 抽 user 面 · tagPair 回归护。重写既有 `ThinkTagParserAlignmentTests.swift` agentic 段的 `to-self`/`to-user` 假 marker（无生产消费者走此路径 — `EngineInference` 全 tagPair + `primedInside`，`grep -rnE "Format\.agentic"` sources 零命中）为 #182 真协议 `to=self<|message|>` 形式，保留 protocol-leak 守卫（用户面不得见 `to=self`/`<|message|>`/`<|start|>`/`<|eom|>`/`<|eot|>` 任何一 token）。`swift build --target ocoreai` exit 0 (8.30s) · `swift test --filter ThinkTagParser` **15/15 pass**（5 tagPair-ahead + 8 #206 vendored + 2 protocol parity）· `swift build --build-tests` exit 0 (19.46s)。CoreAI 路径 `CoreAIEngine.respondVanilla` 未通电 `Format.agentic`（`EngineInference` 全 tagPair），本批为 parser 库面吸收，非行为变更。

- **`MemoryEvent.computeDedupKey` 真 bug 修 + 跨进程稳定性测试钉 — dedup_key 用 `String.hashValue` 持久化** — 自主开发扫 recall 相邻段(storeMemoryEvent upsert 分支)发现: `MemoryEventModel.swift:133` `raw.hashValue.description` 直接拼进 dedup_key 落 SQLite(`memory_events.dedup_key` 唯一索引 + `storeMemoryEvent` `ON CONFLICT(dedup_key) DO UPDATE` 去重键)。但 Swift `String.hashValue` **进程间随机化**(HashDoS 种子上次跑/这次跑实测 `5574914235216148489` vs `6832846833449623354`, 同一字符串两次不同)→ **app 进程重启后同一 (context,cause,entities) 生成不同 dedup_key, `ON CONFLICT` 永不命中, 永久记忆(fact/pattern/preference)去重彻底失效 + `MAX(confidence)` 合并语义失效, 重复行无限堆积**。现有测试只钉硬编码字面量撞唯一索引(同进程恒等), 从未钉 computeDedupKey 跨进程稳定。修复: `stableHash64` FNV-1a 64 确定性哈希(无种子, 跨进程/跨平台稳定)替 `hashValue.description`。全库 `.hashValue` 清单扫证: 其余 `SkillModels:122`/`ToolRegistry:265`/`SessionPool:82`/`EngineInference:3977` 均为进程内缓存 key(不落 DB, 无持久化失真), 唯一持久化点已修。`ComputeDedupKeyStabilityTests` **4 条全绿**(确定性同输入→同 key / FNV-1a 锚点 / 不同 context→不同 key / storeMemoryEvent upsert 真合并 n=1+confidence max=0.90) + `swift build --build-tests` exit 0。

- **handler 通电测试 — `check_tools`/`get_plan` 真跑 handler 闭包 (seam 注入源, `Tools/VerifyTools.swift:120` + `Tools/PlanTools.swift:267`)** — 上批两刀 26 测试全在测**纯函数**（`CheckVerify.*`/`PlanRead.*`），handler 闭包那条"handler→真值源"接缝（JSON→Args 解码 + `await PlanTaskStore.current`/`AuditTrail` 跨 actor await + 读源 + render）**从没被真跑过**：纯函数全绿也测不到"读错源/await 丢值/解码失败"。本批照 `GetContextRemainingClient` 的 `store:` 先例（`ContextRemainingTools.swift`）给两个 client 加 seam 参数（`entry(store:)`/`runForTool(store:)`，nil-default → 行为对生产零变化；非 nil → 注入源离线可测）。**5 通电测试(1 suite)全绿**（`HandlerWiringTests`：get_plan 注入快照→精确渲染串端到端 / 空 store→诚实缺席 / check_tools seed 2 条(1 success+1 error)→精确四态计数+明细 / status=error 过滤→仅 error 条目 / 空 trail→诚实缺席）+ `swift build --target ocoreai` exit 0（6.70s）+ `swift test --filter HandlerWiring` **5/5 全绿**（0.001s）。

- **`check_tools` first-class tool — Verify 段 agent 消费面闭合 (审计真值源首个非 UI 消费者)** — 六段环 Verify 段此前零 agent 消费者: `AuditTrail` 写入完整（`ToolRegistry` 每次执行 `beginCall`/`completeToken` 双写内存环 + SQLite `audit_traces`, commit `7676ac5` durable），查询面完整（`AuditTrail.recent`/`recentPersisted`/`queryTool`/`queryCaller`, `Security/AuditTrail.swift:209-223`），merge 读面存在——但**全库唯一读方 = UI 展示**（`SystemViewModel:46-47` `loadAudit`），`grep auditTrail Sources/ocoreai/Engine Sources/ocoreai/Handlers` 非 write 调用 **0 命中**。模型无法回答"我刚才那批工具调用哪些失败、为什么"——只有自身不可信复述。本批把既有真值源暴露给 agent（**不造新账本、不新增权限、零 Apple 硬件依赖**）: `AuditVerify.filterAndSort`（窗口边界含端点精确 ±2s / `tool`/`status` 过滤 / ts 倒序 + id 倒序 tiebreak / `limit` clamp 1...500）· `AuditVerify.reduce`（内存环 ∪ 持久面, 按 id 去重, 内存面优先——`AuditTrail.merge` 先例, `AuditTrail.swift:377`）· `AuditVerify.render`（4 状态计数 + 逐条明细「工具 状态 时长 摘要 160 字符硬截断」, 缺席诚实报 `no tool executions` 同 `observe_state` 纪律）· `CheckToolsClient.toolEntry`（`verify` toolset, 三参数 schema `window_seconds:5...3600 默认 300` / `tool` / `status:success|error|cancelled|timeout`, `ToolEntry.typed` 范式）· `runForTool`（真值源 = `OcoreaiEngine.shared.activeAuditTrail` L101, 与 UI 读面同一 actor 实例; 只读零副作用; 存储未初始化 → 诚实 absent）。注册于 `bootstrapBuiltInTools`（`BuiltInTools.swift` observe_state 之后, toolType `.query`）。**17 精确值测试(5 suite)全绿**（filterAndSort 5: 窗口边界 / tool 过滤 / status 过滤 / ts+id 双排序 / limit 截断; reduce 3: 并集 / id 冲突内存优先 / 空安全; render 3: 4 状态计数精确 + 缺席诚实 + 摘要截断 160; client 6: 参数 clamp 15/7200/300 / 注册面 verify toolset / 三参数 schema / status 白名单 / 窗口边界精确）+ 局部回归 `CheckTools|Memory|PerceptionTools|BuiltInTools` 31/31 无回归 + `make test-ci` **1536 tests / 286 suites 全绿** (exit 0) + `swift build --target ocoreai` exit 0 + swift-format 603.0.0 hook 幂等。
- **minConfidence 假参数接线 — `recallPermanentMemory` 名义过滤变真过滤** — 上批六段环逐行核实抓出: `SessionCompressor.recallPermanentMemory` 签名 `minConfidence _: Double = 0.5` **下划线 = 参数被丢弃**, 无 query 分支 SQL 写死 `AND confidence >= 0.5`, 而调用方 `ChatHandler:620` 传 `minConfidence: 0.6` **根本没进 SQL**——API 面与行为不一致（调用方以为在调阈值, 实际恒 0.5）。接线为真: 签名 `minConfidence: Double = 0.5` + `let minConf = minConfidence`, 无 query 分支 SQL 改 `AND confidence >= ?` + `parameters: [minConf, limit]`。语义变化: ChatHandler 召回过滤 0.5 → **0.6**（调用方声明值首次生效, 行为向声明对齐）。局部回归 `Memory|PerceptionTools|BuiltInTools` 31/31 + `make test-ci` 1536/286 全绿。
- **`get_plan` first-class tool — Recover 片 1 的模型侧读面闭合 (`update_plan` durable 快照读回, `PlanPersistence.swift:11` 点名的"后续切片")** — 上批六段环逐行核实 + 本轮实证: plan 状态 durable（`plans` 表 `PlanTaskStore.persist` + `rehydrate` 会话激活后 hydrate）但**只喂 UI 面板（`PlanCard`）**, **模型侧零读面**（grep `get_plan`/`plan_status`/`read_plan` 全库 = 0 命中）: 模型自己的任务态只活在对话历史里（会被 compaction 剥掉）, 而 durable 副本就在 `PlanTaskStore.shared.current`（与 UI 面板同源的 SSOT）。本批把该读回暴露给模型——断点续跑时模型自问"我做到哪步了、哪些 pending", **决策权仍在模型**（只读、零副作用、不自动 resume、不改 plan）。形态先例 = 第一刀 `check_tools`（审计真值源首个非 UI 消费者）: seam 分离全离线可测（不触 `PlanTaskStore`/SQLite/wall clock）: `PlanRead.render`（混合 3 状态计数精确 `plan — N steps: A completed, B in_progress, C pending` · step 1:1 顺序 · 三状态 tick 记号 `[x]`/`[>]`/`[ ]` 精确 · note 有/纯空白省略 · 未知状态显式 `[?]` 不静默吞 · step 原文逐字透传 · 缺席诚实报 `no plan recorded in this session — call update_plan to create one`）· `PlanRead.utcTime`（`curr_time` 同纪律 en_US_POSIX+GMT 固定 formatter, epoch 精确锚点 0/86400/31536000/1788415211）· `GetPlanClient.toolEntry`（`plan` toolset, **零参** schema, 只读 `isDestructive=false`）· 闭包真值源 = `PlanTaskStore.shared.current`（`@MainActor`, `await` 跨 actor）。注册于 `bootstrapBuiltInTools` **同门控** `updatePlanEnabled`（codex `#41744` 基线 opt-in: plan 命名空间 off-path 则读写面一起消失, 避免"读面开着写面关着"不一致, 与 `update_plan` 同 `if` 分支）。**9 精确值测试(3 suite)全绿**（render 6: 混合计数+顺序+tick/note 有/缺席诚实/空 items/纯空白 note 省略/未知状态显式标记/step 原文透传; utcTime 2: epoch 锚点 ×4 精确 + 非午夜精确; client 1: 注册面 `get_plan`/`plan`/零参/非 destructive）+ 局部回归 `Plan|BuiltInTools|CheckTools` **49/49 全绿** + `swift build --target ocoreai` exit 0。

- **Fast Path per-model 采样级联 + 上下文墙 parity — 修双推理路径行为分叉 (per-model settings 审计 P1)** —「model management / per-model settings 完善度」审计(用户点名)实证地基完整(ModelManager SSOT / per-model 持久化 / EnginePool 热切 / wire 路径全字段级联 + 400 墙 + compaction),**不完善真身 = 两条推理路径行为分叉**:wire 路径(`ChatHandler`/`Anthropic`)per-model 采样全字段消费,但 Fast Path(UI 原生 `DirectInferenceClient` stream/complete)`SamplingConfiguration(...)` 只装 temperature/topP/topK/stopSequences,**静默丢弃 10 个 per-model 字段**(seed/mode/minP/presence+frequency+repetition penalty+window/prefill/maxKVSize/context×3)→ 同一设置 HTTP 生效、UI 聊天不生效;且 Fast Path 无 `max_context_window` 400 墙(`promptExceedsContextWindow` 零命中)。omlx 基准 `model_settings.py`(三件 + `max_context_window` 三级 fallback)佐证 per-model 双路径必齐。修复:`SamplingConfiguration.fastPathDefaults(_:)`(`InferenceStubs.swift` 新增, internal, 两条 Fast Path 共享单一事实源)10 字段级联齐全 + penalty `0→nil` 哨兵语义与 wire 路径一致(MLXBridge 0.0≡nil 消费实证, nil 不强制) + `penaltiesDisabled`/`contextFieldsDisabled` 哨兵位防"全 0 默认"误伤;`enforceContextWindowCap`(`DirectInferenceClient.swift` 新增, **复用** package 可见 `ChatHandler.promptExceedsContextWindow` + 共享估算 `ConversationCompaction.estimatePromptTokens`, 不造轮子)两条 stream/complete 组装点接 400 墙, `AppError.invalidRequest` 诚实归因(含 prompt/limit 精确 token 数)。全库 `SamplingConfiguration(` 8 组装点清点确认无同类缺口(Anthropic 请求 schema 自身字段面有限非缺口; SummarizerActor 后台摘要固定采样策略)。`PerModelSettingsTests` 新增 **6 精确值回归测试**(10 字段全级联·penalty 四路 0→nil·request 层优先·defaults no-op·prefill+maxKVSize·context×3; Float 源字段容差断言) + 关联 `PerModel|ModelManager|DirectInferenceBehavioral|ChatPipelineBehavioral|ConversationCompaction|EnginePool` 套件 **45/45 全绿** + `swift build --target ocoreai` exit 0 (5.8s) + swift-format 603.0.0 in-place 幂等零 diff。

- **mlx-swift-lm pin `db767ef` → `37688d2`（#572 Qwen GDN input projections 融合 + #573 Qwen direct-reduction）** — 上游已提交 → 必吸收(upstream-alignment 铁律):两个 decode 段均为 Qwen3.5 核心家族性能面(正是「持续优化 Qwen3.5/3.6/3.8 支持」目标轴),非行为分叉而是 free-rider 提速。Consumer-transparent 实证:ocoreai 对 `prepareInferenceState`/`materializeModelForInference`(package-scoped,跨包不可见)与 `FusedQuantizedLinear`(Qwen35 内部类型)零直接引用(grep 全库 0 命中);#573 唯一公共面增量 `public func callAsFunction(_ x: MLXArray, _ indices: MLXArray)` 为**新增非破口**。本地门:`swift build --target ocoreai` exit 0(25.09s,对 #572/#573 重编译) + Qwen3.5 decode 路径直触套件 `MTPDrafter` 17/17 + `ModelIdentity` 18/18 全绿。coreai-models 同步核查:上游 HEAD 仍 `7062017`(0 新提交),无吸收面。
- **`generate_video` first-class tool — 视频生成轴(五要素④)的 agent 可触面 (基设已建、补 agent 面)** — Wan 2.1 运行时管线(`WanPipeline` coreai-models conformer @available 27.0 → `VideoWriter` 纯 AVFoundation 落盘 mp4/gif/apng/webp)上批已吸收, 但**模型无法调度它**——五要素里最后一块无 agent 工具面的感知产线。形态先例 = `transcribe_audio`/`speak`(音频轴)与 `view_screen`(视觉轴)的「基设已建、补 agent 面」:纯核对层离线可测, 真实 I/O 收口一个 seam。seam 分离全离线可测(不触 CoreAI、不需要 `.aimodel`):`GenerateVideo.build`(prompt trim 缺省 `cinematic` · numFrames clamp **5...81** + VAE 时间压缩对齐 `(frames-1)%4==0`(81→81 · 77→77 · 80→77 · 82→81) · fps clamp **1...60**(默认 16) · width/height clamp **32...1280**(默认 832×480) · steps clamp **1...60**(默认 50) · seed 默认 **42** · format 小写解析 mp4|gif|apng|webp, 未知→mp4)· `GenerateVideo.report`(两行精确形态 `generate_video OK — N frames written` + 输出路径, 对齐 transcribe_audio OK 报告)· `GenerateVideo.errorReport`(统一前缀)· `VideoGenOutcome` **5 态**(`ok`/`belowFloor`/`coreAIUnavailable`/`weightsMissing`/`failed`)honest outcome, 低于 floor / 无 CoreAI / 权重未部署 → 诚实上报不静默 · `VideoGenerationBackend` 协议 seam + `RealVideoBackend`(`#if canImport(CoreAI)` + @available 27.0, 消费 `WanPipeline.generateVideo` → `VideoWriter.write`, 权重目录约定 `~/Library/Application Support/ocoreai/wan2.1` 3×.aimodel) + `PlatformVideoBackend`(无 CoreAI 平台 → `.coreAIUnavailable`)· `GenerateVideoClient.selectedBackend()` 平台选型 + `toolEntry`(`video` toolset, `ToolEntry.typed` Codable Args 范式, 8 参数 schema)。注册于 `bootstrapBuiltInTools`(`BuiltInTools.swift`, `video` toolset, toolType `.action`)。**14 精确值测试(3 suite: build 7 + report 2 + client 5)全绿** + 顺带修 2 声明≠内容(错误报告权重路径误写系统级 `/Library/...` → 用户级 `~/Library/...` 与 `RealVideoBackend.defaultWeightsURL()` 真读路径一致, 断言升级为含精确路径的 `==`; 工具 description `16-60 fps`/`~90s render` 无凭据 → 改为与 clamp 常量逐字一致的 `1...60`/`32...1280`) + `swift build --target ocoreai` exit 0(6.7s) + `audit.swift_patterns.sh` 全 ✅(补 `VideoWriter|VideoTools` Class-B 白名单: errorDescription + domain label 判例, 同 `Wan21VideoContract`/`CoreAIDiffusionModelFunction`) + swift-format 603.0.0 in-place 幂等零重排。真运行时(denoise + 3D-VAE decode)需 macOS 27 / iOS 27 + Wan 2.1 权重部署, 本批 seam 离线可测 + 生产路径已接线。
- **`get_context_remaining` 一等工具 — codex `context` namespace 上下文窗口余量读数 (0.150.1 HEAD)** — Agent←codex 基准对齐轴第二个真实语义 gap 闭合：codex 暴露**无参通用 agent-loop 原语** `get_context_remaining`（→ `context_window_token_status(session, turn)`，基准 `core/src/tools/handlers/get_context_remaining.rs` + `core/src/session/context_window.rs` + `core/src/context/token_budget_context.rs:170-172`）——ocoreai 此前 agent **没有任何手段感知自己的上下文余量**（只能事后撞 `context-window-exceeded` 400 墙被动学习）。真源映射与 codex `Option<i64>` 同型：`used` = ChatHandler 本轮已计 prompt token（`promptTokenCount`，L282 400 墙同域判据）· `limit` = `getSamplingConfig(modelId:).maxContextWindow: Int?`（EnginePool:803，`nil` = 模型未声明窗口 = codex `None` 语义）。纯计算逐字移植：`tokens_remaining(limit, used) = limit.map { max(0, $0 - used) }`（codex `saturating_sub(used).max(0)` clamp 语义，**不产生负数**），无窗口 → `unknown`。报告字符串 codex 逐字原形：`You have {n} tokens left in this context window.` / `You have unknown tokens left in this context window.`（token_budget_context.rs:170-172）。唯一结构性 gap——codex 进程内持 `Session`，ocoreai 工具派发 stateless（`ToolEntry` 闭包无 `invocation`）——以 `clock` 的 `ClockTimeProvider` 同族 provider seam 解：`ContextStatusStore` actor（**模块级 canonical 单例 `nonisolated static let shared`**，消实例穿越：ChatHandler 写、工具读、boot 兜底共享一份）· `set(usedTokens:windowLimit:)`（ChatHandler L284 每轮注入，prompt token 与窗口上限同域，真值点非失败分支）· `peek() async`（工具闭包读，无轮次写入/未知窗口 → honest unknown，非编造 0）· `GetContextRemainingClient.toolEntry(store:)`（`context` toolset 注册）。**13 精确值测试 (3 suite) 全绿**（compute 5：used<limit 精确差 · used==limit → 0 · used>limit clamp→ 0 非负 · nil limit → nil ×2 · 首/末 token 精确 · report 3：known/zero/unknown 逐字 · client 5：known 精确余量 · 超用报 0 不报负 · nil limit 逐字 unknown · 未写入诚实 unknown · 名称 + `context` 命名空间注册面）+ `swift build --target ocoreai` exit 0 (7.67s) + `swift test --filter ContextRemaining` **13/13 pass** + `audit.swift_patterns.sh` 全 ✅ + swift-format 603.0.0（版本 pin 与 CI 同源）in-place 幂等无漂移。真运行时（每轮 `set` 真值流）依赖 ChatHandler 每轮必经的 prompt-token 计点，本批离线 seam 可测 + 生产路径已接线（`.shared` 单点）。
- **`curr_time` + `sleep` 一等工具 — codex `clock` namespace 两个 agent-loop 原语逐行对齐 (0.150.1 HEAD)** — Agent←codex 基准对齐轴首个真实语义 gap 闭合：codex 0.150.1 HEAD 暴露两个通用 agent-loop 原语 ocoreai 此前 0 注册——`clock.curr_time`（无参，返回 `YYYY-MM-DD HH:MM:SS UTC`，基准 `current_time.rs`）与 `clock.sleep`（`duration_ms` 1..43,200,000 = 12h，越界拒绝，报告 `Wall time: {:.4f} seconds`，基准 `sleep.rs`）。ocoreai 此前 agent 读时间只能靠 `info` 工具的 uptime 间接推、等只能走 `exec sleep` 起子进程——本批补一等原语。工具名/取值/报告形态逐行对齐 codex `TOOL_NAME` 原值（同 `unified_exec` 工具名、`view_image` 同形对齐先例）。seam 分离全离线可测（不 touch wall clock、不真等）:`ClockCurrentTime.report`(固定 UTC formatter, en_US_POSIX + UTC, 精确锚点 `2026-08-27 12:34:56 UTC` 可断言)· `ClockSleep.build`(`nil`/0/负/超 43_200_000 四路拒绝, 不静默 clamp, 诚实报越界)· `ClockSleep.report`(codex 原形两行)· `ClockSleep.outOfRange`(拒绝报告精确形态)· `ClockTimeProvider` + `SystemClockTimeProvider`(生产读 `Date()`)· `SleepBackend` + `SystemSleepBackend`(`Task.sleep(nanoseconds:)` 不阻塞 actor executor, CancellationError 吞掉 = 提前终止语义)· `CurrTimeClient`/`SleepClient`。注册于 `bootstrapBuiltInTools`（`clock` toolset）。诚实边界：codex「新输入提前唤醒」依赖 per-turn activity 订阅，ocoreai ChatHandler 无同形状信号 → 记后续批次，本工具诚实报 `Sleep completed.`。**14 精确值测试(5 suite)全绿** + `swift build --build-tests` exit 0。注册后内置工具 = 21（`registry.register(` 实证计数）。

- **`transcribe_audio` 四档矩阵闭合 — <macOS 26 / <iOS 26 降级到 Speech 云引擎, 不再硬失败** — 上批交付的 `transcribe_audio` 在 **macOS 14/15、iOS 17/18 直接回 `.belowFloor` 硬失败**(`SpeechTools.swift:111` `guard #available(macOS 26.0, iOS 26.0, *)`),但用户点名"14/15/26/27 四档都考虑了吗"后全档核验发现: `SFSpeechURLRecognitionRequest` **macOS 10.15+ / iOS 13+ 全档可用**(头文件实读 `API_AVAILABLE(ios(10.0), macos(10.15))`)、 `SFSpeechRecognizer` 同 10.15+, 代码库 UI 侧(`AudioIO`+`SettingsStore.sttEngine` auto/cloud/local)早已消费这条 ladder, 唯独 agent 工具面没接通。修复三件: **① `PlatformSTTTranscriber`** 平台分叉(26+/iOS 26+ → `LocalSTT` 离线; catch/low-floor → `transcribeCloud`; cloud = `SFSpeechURLRecognitionRequest` + `shouldReportPartialResults=false` + result/error 回调 → `STTOutcome`, 授权缺失/服务不可用/locale 无引擎三档诚实 reason); **② `NSSpeechRecognitionUsageDescription`** 三个跟踪中的 Info.plist 全部补齐(macOS 10.15+ 系统强制键, 缺则系统拒调用, 四档真前提); **③ 工具 description + `belowFloor` 错误文案** 改为"优先离线, 低 OS 自动降级云, 失败报诚实 reason"——不再误导"只有 macOS 26+ 可用"。**新增 3 精确值测试**(`cloudAuthorizationDenialReportsHonestReason` / `cloudServiceUnavailableReportsLocaleAndNetworkHint` / `cloudSuccessUsesSameReportShapeAsLocal`(两行形态+22-char 精确计数+正文原样))+ 改写 `belowFloorMapsToHonestError` 断言新精确文案(双引擎均不可用)。**32 测试 / 6 suite 全绿**(原 25 + 新增/改写 7)+ `swift build --target ocoreai` exit 0 (1.65s)+ swift-format 603.0.0 in-place 零重排。四档矩阵现全绿:T1(14/17)=cloud✅ / T2(15/18)=cloud✅ / T3(26/26)=local→cloud✅ / T4(27/27)=local→cloud✅。
- **`transcribe_audio` + `speak` first-class tools — 听觉感知 & 语音反馈轴的 agent 可触面 (复用既建音频基设, 非新造)** — 产品目标第一/二/三要素里唯二仍无 agent 工具面的是**听觉**（听音频→文字）与**语音反馈**（把回答读出来）。上批 `view_screen` 刚闭合视觉的"声明≠消费"缺口；音频是同一形态——ocoreai 音频基设早已完整且被 UI/passive 侧消费：`AudioIO`(490L, `speak` 已含 `PersonalVoiceTTS` 个人音色优先)、`LocalSTT`(163L, macOS 26+/iOS 26 离线识别)、`SpeakerFeedbackSensor`(208L) — 但**模型无法调度它们**（既无 `transcribe_*`/`speak` 工具）。**基准归属**：这是 **Apple 原生轴**（`Speech` 框架 `SFSpeechTranscriber` 文件路径 + `AVSpeechSynthesizer` 读回），codex/mlx-swift-lm/coreai-models 三仓均无音频工具面——故无三仓行为分叉风险，纯 ocoreai 产品目标自有面。seam 分离全离线可测（不触 OS Speech/TTS）:`TranscribeAudio.build`(locale 缺省=应用 locale、`maxChars` clamp 100…8000、0/负→按 100)· `TranscribeAudio.report`(两行精确形态 `ok:N chars(locale=L)`+trim 正文、超 cap 截断+`…`、无语音/平台 floor/文件缺失/失败 4 种诚实归因)· `STTTranscriber` 协议 + `LocalSTT.transcribe`(L3 真身, 后端可换 fake)· `TranscribeAudioClient.runForTool` · `Speak.build`(trim/空→拒绝/超 8000 截)· `Speak.report`(`speak OK — N chars enqueued`)· `TTSBackend` 协议 + `PersonalVoiceTTS`→`AudioIO.speak` 链(后端可换 fake, OS 语音合成可关闭) · `SpeakClient.runForTool`。注册于 `bootstrapBuiltInTools`（`BuiltInTools.swift`, `speech` toolset）。**25 精确值测试(5 suite)全绿** + 音频轴既有 `Multimodal|Perception|Speaker|AudioIO|LocalSTT|PersonalVoice|TTS|TranscribeAudio|Speak` **71 测/16 suite/0 failed 无回归** + `swift build --target ocoreai` exit 0（6.73s）+ `audit.swift_patterns.sh` 全 ✅ + swift-format 603.0.0 in-place 幂等零 diff。真运行时（OS 语音合成发声 / 离线 STT 真识别）需 macOS 26+ 运行时权限, 本批 seam 离线可测 + 生产路径已接线。
- **Wan 2.1 数值面吸收（#190 scheduler + tiled-VAE 数学 + `VideoPipeline` 协议）— 闭合契约层的"声明≠消费" gap** — 上批交付的 `Wan21VideoContract.swift` 自带注释"推理运行时 → Batch 2"，但**纯数值层**（sigma schedule / 分块 VAE 数学 / pipeline 协议形面）上游早已提交且零平台门：`coreai-models` `#190`（`DiscreteFlowScheduler` sigma 修正：`sigmaMax` 上限 img2img 调度 + 0.0 终态 sigma）、`TiledDecode3D.swift`（`computeTileStarts`/`extractLatentSubTensor`/`padLatentTile`/`blendWeight`/`blendTileIntoOutput` 5 函数，纯 Float 数学）、`VideoPipeline.swift`（`VideoGenerationResult`/`VideoProgress`/`VideoPipeline` 协议 + `generateVideo(configuration:progressHandler:)` 形面）。本批逐字吸收三文件（`DiscreteFlowScheduler.swift` 147L 含 `SchedulerMath.linspace`；`TiledDecode3D.swift` 189L；`VideoPipeline.swift` 58L），`public` 化供 `ocoreaiTests`（独立 target）与未来 `WanPipeline` 运行时消费。**纯 Foundation + Accelerate：无 CoreAI.framework、无 `.aimodel`、无平台 floor**（macOS 14 floor 可编译）——正是"上游已提交 → 必吸收"与"确定性数值可离线精确值测试"的交集。18 精确值测试全绿（8+8；`Wan21SchedulerTests` 8：diffusers FlowMatchEuler 4-step parity ×6 sigma 精确值 / 50-step & 20-step 端点 / Euler step 公式（σ 表自调度器）/ `addNoise` 0.0·0.5·1.0 精确值 / `sigmaMax` 约束调度 / `linspace` 均匀性与端点精确值；`Wan21TiledDecodeTests` 8：tile grid 单块 & 全幅覆盖 / sub-tensor 精确区域提取 / padding 零填充与 identity / `blendWeight` 首块=1.0 与线性斜坡 / 非重叠块=clean copy / 重叠块边界线性混合）。+ 既有 `Wan21VideoContractTests` 55 断言无回归。**18 新测试全绿 + `swift build --target ocoreai` exit 0（7.4s）+ `audit.swift_patterns.sh` 全 ✅**。真运行时（denoise loop + CoreAI `AIModel` + 3D-VAE decode + `VideoWriter`）仍需 `.aimodel` 权重 + CoreAI.framework（macOS 27 floor）→ 后续批次。
- **`web_search` first-class tool — 信息获取 (user-named axis: "Apple 原生 beyond CoreAI")** — codex baseline 把 web 搜索做成一等工具（`codex-rs/tools/src/tool_spec.rs:39` `ToolSpec::WebSearch`，provider 代其检索；`tools/src` "外部 web 访问 vs 索引 web 访问" 注释）。ocoreai 推理跑本地（MLX/CoreAI/FoundationModels），无 provider 代搜 → 等价路径＝注册 `web_search` 工具，handler 调本地 ollama `/v1/responses` `web_search` 端点（协议与已实跑验证的 `ollama-search.py` 逐字段一致；实跑 `What is the capital of Ethiopia?` → **Addis Ababa**，2.98s，exit 0）。seam 分离便于离线精确值测试（无网络）：`WebSearchRequest.build`（URL 补 `/v1` + 精确请求体 + 空 query/model 拒绝）· `WebSearchParser.parse`（Responses API 逐字段解析 `web_search_call.action.query` + `message.content[].output_text.text` + usage；顶层 error 对象逐字上报；空 answer 拒绝诚实）· `WebSearchClient.toolEntry`（工具面契约 `query:string` + `max_output_tokens:integer`）· `WebSearchClient.search/runForTool`（async `URLSession` 网关；后端 env 可注入 `OCRE_SEARCH_BASE_URL/MODEL/TIMEOUT`，失败诚实不吞）。注册于 `bootstrapBuiltInTools`（`BuiltInTools.swift`）。**13 精确值测试（3 suite）全绿** + ToolRegistry/ToolDispatch 桥 19 测无回归 + `swift build --target ocoreai` exit 0。
  **Apple 原生轴结论（代码实证）**：Apple 无给 agent 的 web 搜索原生 API（FoundationModels=推理、Siri=不可编程进 agent loop、Core Spotlight `CSSearchQuery` 官方原文只搜"本应用自己注册的条目"且 ocoreai 0 条目 → 系统级文件 Spotlight 无公开 API 给第三方；Private Cloud Compute=推理服务）。故"获取系统信息"分类：本机文件/代码→ocoreai 已有 `search_files`（纯 Swift 递归，已够）；外网发现→**走网络客户端接搜索后端**（即本工具）；**已知 URL 的渲染页面读取→`web_fetch`（WebKit，本批交付，见下）**。⚠️ 早期"WebKit=红鲱鱼"判断已证伪并修正：WebKit 是"读取已知 URL 渲染内容"的 Apple 原生正解（本机 CLI 进程实证 developer.apple.com 9277 字符完整抓取）；"驱动真实浏览器"才是 CDP/MCP 轴（codex `full_cdp_access` 基准），两者正交。
- **`web_fetch` first-class tool — 读取已知 URL 的渲染内容 (WebKit 后端，用户命名: "获取网页内容总可以吧?" → 实证成立)** — `WebKit` `WKWebView` + 主线程 `RunLoop` 泵循环抓取（`didFinish` → `evaluateJavaScript` 取 `document.title` / `document.body.innerText`；超时/导航失败/空页均诚实非零）。**基准实证**：本机 CLI 进程抓取 `https://developer.apple.com/documentation/foundationmodels`（plain HTTP 拿不到内容的 JS 渲染站）→ TITLE "Foundation Models \| Apple Developer Documentation"，BODY **9277 字符**，0 error。与 `web_search` **正交**：search=不知站点→找答案；fetch=已知 URL→读页面。seam 分离离线可测：`WebFetchRequest.build`（http/https 白名单 + scheme 小写规范化 + 无 host/空串拒绝 + timeout clamp 1...120）· `WebFetchParser`（归一化 trim / 空页→`emptyPage` 显式错误 / 紧凑报告 `status·title·body_chars·BODY`，失败报告 `reason` 逐字）· `WebKitBackend`（`WebFetchBackend` 协议实现，`MainActor.run` 包泵循环；fake 可注入）· `WebFetchClient.fetch/runForTool`（async；后端可注入，失败一律 `error: ...` 前缀诚实，`OCRE_FETCH_TIMEOUT` 可覆写）。注册于 `bootstrapBuiltInTools`（`BuiltInTools.swift`，紧跟 `web_search`，同 `web` toolset）。**13 精确值测试（3 suite）全绿** + web_search 13 + ToolRegistry/ToolDispatch 桥 19 共 **45 测 / 10 suites / 0 failed** + `swift build --target ocoreai` exit 0（7.09s）。
- **`view_screen` first-class tool — 视觉感知轴的 agent 可触面 (截屏 + Vision OCR → 屏幕文字,文本通道内)** — 产品目标第一要素"视觉感知"在 agent 面的缺失:16 工具里 `view_image` 只读**磁盘已保存**的图片、`web_fetch` 只读**网页**;`ScreenshotService`(ScreenCaptureKit)+`VisionOCR` 设施已存在且被 `PerceptionEngine` 被动消费,但 agent 无法**主动"看当前屏幕"**(wiki 08-26 "proactive agent-proactive 仍是缺口")。**基准归属**:Apple 原生轴(ScreenCaptureKit + Vision),非 codex 造轮子——codex `codex-rs/tools` 11 个新 commit 无屏幕工具,此能力是 ocoreai 产品目标自有面;MLX 工具通道 text-only 约束下,正确形态=**截屏→Vision 文本识别→返回屏幕文字**(复用 PerceptionEngine 已验证的"屏幕文字"消费范式,~97% token 省,绝不吐 base64 像素)。seam 分离全离线可测:`ScreenCapture.build`(OCR on/off、`maxOCRChars` clamp 200...8000,0/负=关)· `ScreenCapturePure.pngSizeFromJPEG`(ImageIO 像素尺寸)· `ScreenCapturePure.trimmedOCRText`(trim+截断,空→`""`)· `CaptureBackend` 协议(截图 data URL + 屏幕文字,fake 可注入)· `OSCaptureBackend`(macOS 13+ ScreenCaptureKit 显示列表→`ScreenshotService` 主屏截图 + `VisionOCR.extractText`,非 macOS/无屏幕/无权限均**诚实非零**非静默)· `CaptureClient.runForTool`(后端可注入,成功 `ok:`+尺寸+可选 `screen_text:`,失败一律 `error: ...` 前缀诚实)。注册于 `bootstrapBuiltInTools`(`BuiltInTools.swift`,同 `screen` toolset)。**22 精确值测试(3 suite)全绿** + web_fetch/web_search/ToolRegistry/ToolDispatch 共 **73 测 / 14 suites / 0 failed** + `swift build --target ocoreai` exit 0(2.72s)。
- **Qwen3.5 / Qwen3.6 MTP self-speculative decoding — registration + guard alignment** — The engine guard at `EnginePool.swift:643` previously hard-encoded "Gemma-4 only" and warned out Qwen3.5/3.6 requests even though ocoreai's own `ConfigStruct` doc and the pre-feature CHANGELOG advertised Qwen MTP ("use `mode: 'mtp'`" for Qwen3.5). Two fixes:
  1. Register the upstream `Qwen35TextMTPRegistration` (type strings `qwen3_5` / `qwen3_5_text` / `qwen3_5_moe` / `qwen3_5_mtp`) and `Qwen35VLMMTPRegistration` in `EnginePool.init`, alongside the existing `Gemma4AssistantRegistration`. Qwen3.6 rides the same `qwen3_5*` type family in the upstream registration comments.
  2. Extend the guard at `EnginePool.swift:643` to branch on both Gemma-4 **and** Qwen3.5/3.6 model ids (`lowerId.contains("qwen3.5") || lowerId.contains("qwen3.6")`). For Qwen, pass the **same `modelId`** to `loadMTPDrafter` — the drafter is self-spec, pulling `mtp.*` weights from the main model's own checkpoint (upstream `Qwen35MTPDraftModel` only attaches `@ModuleInfo(key: "mtp")` and sanitizes the rest away). Gemma keeps the dedicated `*-assistant-bf16` checkpoint path.
  Exact-value surface test (`MTPDrafterRegistrationSurfaceTests`, 7 cases): `MTPDrafterTypeRegistry.shared.contains(_:) == true` for `qwen3_5`, `qwen3_5_text`, `qwen3_5_moe`, `qwen3_5_mtp`, `gemma4_assistant`; `== false` for `qwen3_4`, `llama4`. Closes the ocoreai-vs-`ConfigStruct` doc fork.
- **Pin bump: mlx-swift-lm `1441444` → `6745899`** — absorbs upstream commits since 08-25: #575 parallel byte-balanced weight loading (measured 1.8× faster model loads, ~5.9 GB/s on M4 Pro — free consumption, no ocoreai code), #329 variance-normalized KV cache (new opt-in strategy; ocoreai `makeKVCacheConfiguration` dual-path unchanged — explicit, not exhaustive switch, zero drift), #576 LFM2VL image-token-id-from-vocab (no LFM2VL consumers in ocoreai), #571/#574 SSM gradient fix+tests (training-side)。事件面核对: `.rejectedToolCall` 已在两处消费（EngineInference.swift:3349/3914），无 `TokenStreamEvent` exhaustive switch——pin bump 无事件面断裂。
- **MCP tool results: non-text content preserved, no more hard-fail (codex `75cb7c9` / #40737 baseline)** — `MCPBridge.renderToolResultBlocks` 静态核心: text 块逐字拼接（`\n---\n` 分隔），非 text 块（`image`/`audio` 等）渲染为显式占位符（`[image]`…）而非 `throw "No text content"` / 静默 `(no content)` / 丢弃。三条工具结果通路统一接线（forward、registered-handler、local-call）。8 个精确值测试（`MCPToolResultRenderingTests`）。

- **Context-window compaction before the 400 wall (codex `compact.rs` 范式)** — `ConversationCompaction`（`Reasoning/ConversationCompaction.swift`，197 行，确定性 LLM-free 核心）：当 prompt 估算超过 per-model `max_context_window` 时，从 OLDEST 完整可移除单元开始压缩，保护前缀 system + 最近 N 轮，且绝不把 tool result 与其发起的 assistant 轮拆散（原子单元移除）。Token 估算与 Phase 3 heuristic 逐字一致（UTF-8 bytes/4，CJK>1.5 走 /3），驱动 wall 与 budget 的是同一个数。接线于 `ChatHandler` Phase 3.5：压缩 → 重估 → 若 fit 则按压缩后 transcript 继续，否则 wall 仍持 400。11 个精确值测试（`ConversationCompactionTests`，含 CJK 公式 / nil-budget / at-budget 边界 / tool-call 原子性 / boundary / reserve / deterministic 共 11 条）。

- **Pin bump: mlx-swift-lm d661402 → `1441444`** (72bbfbe) — absorbed upstream #544 (MLXFoundationModels β5-SDK compilation fix: `capabilities:` extraneous label :565, `ConvertibleToGeneratedContent` dict :718). ocoreai 0 true consumers of either changed symbol; the module must compile for ocoreai to build. β5 standalone: d661402 FAILS (2 errors) / 1441444 PASSES. Unblocks local build + test run.
- **CoreAI GPU repetition penalty (#176 alignment)** — `RepetitionPenaltyGPUState` (125 LOC, verbatim port from upstream coreai-models) + `MPSGraphCompositeSampler` penalty stage (graph Step-0 `select(logits>0, logits/p, logits*p)` sign-aware divide/multiply, compiled into the feed tensors) + `CoreAIPipelinedEngine` wiring (`recordToken` in the completion callback, `buffer(forStep:)` at encode time, `reset()` clears the ring + buffers). `MPSGraphSamplerFactory.makeSampler` threads `config.repetitionPenalty != nil` → `penaltyEnabled`. Sequential path already covered by `RepetitionPenaltyProcessor` (unchanged).

- **Wan 2.1 video consumption contract surface (user-named Wan 2.1/2.2 axis)** — `Sources/ocoreai/Video/Wan21VideoContract.swift` (285 lines): the request/config/constants layer for the **Wan 2.1 text-to-video** pipeline, copied value-for-value from coreai-models `CoreAIVideoDiffusionPipeline` (`VideoConfiguration.swift` + `WanPipeline.swift` #191) per "上游已解决 → 吸收不造轮子". Pure Foundation (no CoreAI framework, no `.aimodel` dependency), so it compiles on the macOS 14 floor with **no `@available` gate and no platform-floor bump**. Three public types + one public enum:
  - `QualityPreset` — 3-tier enum (`fast`/`balanced`/`best`) with `steps` (12/30/50), `numFrames` (33/81/81), `cfgCutoff` (0.5/0.5/nil), copied verbatim from upstream `VideoConfiguration.swift:9-37`.
  - `VideoConfiguration` — 14 public fields (prompt/negativePrompt/seed/stepCount/guidanceScale/numFrames/fps/width/height/dumpDirectory/loadNoisePath/vaeTileSize/vaeTileOverlap/cfgCutoffFraction) with exact upstream defaults (`42` seed, `50` steps, `5.0` guidance, `81` frames, `16` fps, `832×480`, `4` tile overlap) + `from(preset:prompt:...)` resolution rule (`stepCount`/`numFrames`/`cfgCutoffFraction` fall back to preset; `guidanceScale` keeps its own `5.0` default and is **never** preset-sourced) — both copied verbatim from upstream `VideoConfiguration.swift:40-129`.
  - `WanError` — 3-case enum (`invalidMetadata(String)` / `invalidConfiguration(String)` / `cancelled`) with `LocalizedError` surface, copied verbatim from upstream `WanPipeline.swift:672-687`.
  - `Wan21` — public constants + math + validation gate (all from upstream `WanPipeline.swift`): `spatialCompression=8`, `temporalCompression=4`, `latentChannels=16`, `textSeqLen=226`, `vaeTemporalFrames=21`, `vaeTemporalOverlap=1`, defaults (`defaultSteps=50` / `defaultGuidanceScale=5.0` / `defaultShift=3.0` / `defaultFrameCount=81` / `defaultWidth=832` / `defaultHeight=480` / `defaultSeed=42` / `defaultFps=16` / `defaultVAETileOverlap=4`), latent-shape math (`latentFrames = (n-1)/4+1`, `latentHeight = h/8`, `latentWidth = w/8`, `latentSize = C·T·H·W`), `maxOutputFrames()` = `(21-1)·4+1` = **81**, and the 6-rule validation gate with **upstream's verbatim** error messages (order: `numFrames>0` → `stepCount>0` → `width%8==0` → `height%8==0` → `(n-1)%4==0` → `n≤81`).
  **55 exact-value assertions across 7 suites / 55 green** (presets ×9 + config defaults ×13 + `from(preset:)` resolution ×5 + architecture constants ×9 + latent-shape math ×8 incl. `16·21·60·104 = 2,096,640` + validation gate ×7 incl. all 6 exact error messages + first-violation-wins + `WanError` LocalizedError surface ×3). Inference runtime (denoise loop + CoreAI `AIModel` + 3D-VAE decode + `VideoWriter`) needs real `.aimodel` weights + `CoreAI.framework` (macOS 27 floor) → **Batch 2**, not pre-built here.
- **CoreAI grammar → GPU pipelined constrained path (#170 wire)** — `EngineInference` CoreAI grammar branch now dispatches by `ConstrainedGenerationCapable` capability (aligned with upstream coreai-models `CoreAILanguageModel` L582-596) instead of the hard `as? CoreAISequentialEngine` cast. This activates the previously absorbed-but-unwired `PipelinedConstrainedDecodingStrategy` (#146/#170 bitmask per token). Sequential constrained path unchanged.
- **EngineFactory fallback layer removed** — `resolveVariantWithFallback` (dynamic→sequential silent fallback) deleted; auto-detect is now honored directly (dynamic→pipelined, chunkedStatic→staticShape), aligned with upstream `EngineFactory` (which has no fallback). `EngineFactory.{Variant, autoDetectVariant, checkVariantCompatibility, resolveVariant}` bumped `private`→internal for test access (`EngineVariantRoutingTests`).
- **CoreAI grammar constrained decoding** (b69b934) — `TokenizersMLXTokenizerAdapter` (swift-transformers → `MLXLMCommon.Tokenizer`, no MLX tensor deps) unblocks the CoreAI bootstrap guard; `CoreAISequentialEngine.startConstrainedDecoding`/`feedToken` decode-step loop drives xgrammar (`MLXCXGrammar` C shim) mask/acceptToken/rollback. GuidedGeneration 13/13 green. Replaces the 2026-08-13 "fails on CoreAI path" finding.
- **CoreAI .pipelined variant wired** (c4c0a43) — `CoreAIPipelinedEngine` (1,352 LOC) constructed like .sequential/.staticShape (was: `engineUnavailable` throw). Grammar stays on the sequential path (tracks upstream coreai-models #146/#170 GPU bitmask on pipelined); a grammar request hitting the pipelined engine warns and runs unconstrained. _(Superseded 2026-08-22: see "#170 wire" above — grammar now routes to the pipelined GPU bitmask loop when the engine conforms to `ConstrainedGenerationCapable`.)_
- **ThinkingBudget hard budget** (686161c) — upstream `ThinkingBudgetProcessor` wired into the std reasoning path via `GenerationComponents.applyingThinkingBudget` (EngineInference.swift:3345); orthogonal to the ocoreai ThinkingBudget actor.

### Bug Fixes

- **macos-26 CI test-hang: unbounded `Process.waitUntilExit()` removed from `ExecSessions`** — 自 08-22 起 29 连红的 macos-26 真值门(`macos-26-arm64` 20260728 镜像,Xcode 26.6)根因:spawn/kill/eviction 三条 finalize 路径在 `isRunning()` 已 reap 子进程后**再次**调用无界 `Process.waitUntilExit()`——第二次 `waitpid` 在坏 runner 上无限挂死,`spawnExit7` 挂 51min 烧穿 60min job 预算(build-for-testing 实为 success,非级联取消)。两处实证:本地 probe(`scripts/proc-status-cache-probe.swift`)`isRunning()==false` 后 `terminationStatus` 已缓存(exit 7/0/SIGKILL 9 均直接读出,零 `waitUntilExit`);上游 `Process` 文档确认 `waitUntilExit` 为 blocking API。修复:`drainBlocking` 直接读缓存 status(删除调用);`kill`/`makeRoom` 的 SIGKILL 后 reap 改为 `isRunning()` + 2s deadline 有界轮询。回归测试 `spawnExitCascade`(5 轮连续 spawn→poll,精确 exit 7/8/9/10/11,15s 墙钟)。
- **EngineVariantRoutingTests: 3 false-compatible assertions corrected** (72bbfbe) — `checkVariantCompatibility(variant:*, structure: .unknown)` was asserted `.compatible` for all 3 variants; upstream `EngineFactory` and ocoreai mirror both say non-LLM structures are compatible with NONE (default → `false`). Fixed: 3 assertions `== false` with segmenter-comment. Exposed by first-ever local full test run (macos-26 compiles CoreAI tests out via `canImport`; xcode-27 has Testing-macro drift).
- **RepetitionPenaltyGPUState: eviction-order race fixed** (72bbfbe) — `buffer(forStep:)` applied dirty lists in evicted→added order; a token recorded-then-evicted within one flush interval kept its stale penalty and could never be cleared (out of ring → never evicted again). Fixed: flush applies per-token state by CURRENT refcount (`refCount > 0` = in-window). 7 sibling tests confirm no regression. Upstream has the same defect.
- **Multi-tool-call append** (773eeda) — ChatHandler tool-call collection appends instead of overwriting; `ToolCallParser.flush()` can yield multiple tool calls per turn (all-but-last were silently dropped).
- **CoreAI sampler error propagation** (773eeda, MPSGraphSamplers #169 alignment) — completion `(Int32) -> Void` → `(Int32, Error?) -> Void`; 16 failure paths now classify into typed `MPSGraphSamplerError`s instead of silent `completion(0)`; `CoreAIPipelinedEngine` propagates via `continuation.finish(throwing:)`.

- **ToolRegistry loop net: failure path now records attempts** — `recordExecution`（`checkLoop` 数据源）此前只在成功路径（`do` 块）调用，`catch` 路径完全漏记 → 一个持续抛错的工具用同一组入参反复重试时，循环网永远"看不见"它，声明的「≥ maxHistoryDepth 相同调用」阈值对坏工具形同虚设（agent 可无限磨坏工具）。修复：`catch` 块内补 `recordExecution(name, hash:)`，失败尝试与成功同样计数。精确值锁：`repeatedFailuresAreLoopDetected`（坏 handler 相同入参 ×3 为普通 failure，第 4 次 `ToolError.loopDetected`）；既有 `loop detection blocks maxDepth+1 identical calls`（成功路径）与 `different input bypasses loop detection`（不同入参不触发）零回归。
- **Exec-host failure breaker — 连续 handler 失败熔断 (absorbs codex #41454)** — 工具级 loop 网只认「相同入参重复」这一形状，**不同入参的连环 exec 失败不在其面域**（每换一个写法都是"新调用"），agent 对着坏 exec 宿主换参数磨下去，产品「可靠执行/恢复」的承诺在此无网。吸收 codex `ext/goal` 失败会计（`GoalAccountingState`，`62b458c931`）语义：**仅 exec 宿主面**（`exec_shell` / `write_stdin` / `exec_poll`，`destructiveBlacklist` 成员；codex 只计 `exec` 且 `handler_executed`）· **仅 handler 执行失败计**（notFound / denied / loop 等前置拒绝在 `do` 前 throw，codex 的 `Blocked`/前置失败同样不计）· **3 连续失败 → 第 4 次调用在 handler 运行前拒绝** · **任一工具成功即重置**（非仅 exec 面）· **60s TTL 过期清零**（与 loop 网同窗约定，`.zero` 注入 = 确定性测试过期分支）。新增 `ToolError.breakerEngaged`（独立于 `loopDetected`：这是熔断拒绝而非同参循环，agent 换工具/换路径后一次成功即解锁）。`ToolRegistry.init` 新增 `execFailureTTL: Duration = .seconds(60)` + `execHostTools: [String]`（默认三件套）；`call` 前置 0a 守卫点查表；成功路径 `resetExecBreaker()`；`catch` 路径 `recordExecFailure`（仅 exec 宿主名 + 超窗重置/递增）。4 精确值测试（3 败→第 4 次拒 · 成功重置不触发 · 非 exec 坏工具 5 败不侵蚀 exec 宿主满 3 次容忍 · TTL `.zero` 过期分支）+ `ToolRegistryTests` **20/20 全绿** + `swift build --target ocoreai` exit 0 + swift-format 603.0.0 in-place 幂等零重排。

### Refactoring / Cleanup

- **Orphaned "Voice Input" a11y labels removed** — `voiceInputLabel` / `voiceInputHint` (`A11y.VoiceInputLabel`/`A11y.VoiceInputHint`, en+zh) referenced nowhere: not in any view, test, or raw a11y-ID string (6 self-contained occurrences in `Localization.swift` only). The label text "coming soon" / "即将推出" is stale — voice input is already wired end-to-end (`MultimodalControls` start/stop → `LocalSTT.transcribe` → `MultimodalState.pendingVoiceTranscript` → `ChatView.sendVoiceMessage` → chat). Removed the case decls + en + zh string values. No behavioral change; kills a misleading dead label on the UI/UX + i18n axis.
- **4c231d3 dead-code + print removal** (4c231d3) — `AgentLoop` enum runner + `AgentLoopConfig` pruned (523→44 LOC; zero callers after the engine iteration loop moved to `DirectInferenceClient`); `AgentLoopResult`/`AgentLoopIterationLog` kept (consumed by ThinkingTelemetry). `StatsReporter` table-display chain removed (~180 LOC — upstream llm-runner-CLI-only, zero refs). `print()` in Sources/ 18→0 (MPSGraphSamplers 6 + InstrumentsProfiler 12; MPSGraphSamplers errors already propagate to `onSamplingDone`, InstrumentsProfiler deinit rewritten as swift-log `Logger(label:)`).

### Tests

- **#176 GPUState + #170 routing tests** — `RepetitionPenaltyGPUStateTests.swift` (6 contract tests: fresh-is-noop, recorded-is-penalized, dedup, window scoping, out-of-range ignored, reset-clears-all) + `MPSGraphCompletionOrderingTests` (16-encode ordering sentinel — guards the completion-ordering assumption `RepetitionPenaltyGPUState` relies on; ported from upstream `CoreAIPipelinedTests.swift`). Both `.enabled(if: MTLCreateSystemDefaultDevice() != nil)` (CPU-only/CI-VM skip). `EngineVariantRoutingTests.swift` (8 tests: dynamic→pipelined, chunkedStatic→staticShape, unknown→sequential, explicit override, incompatible overrides throw, unknown string throws, full compatibility table) — `@available(macOS 27.0)` guard in each test body (no `@available` on macros, skill §6.1).

### Tooling / CI

- **4c231d3 CI test gate** (4c231d3) — `swift build --build-for-testing -scheme ocoreaiTests` (was `ocoreai`, which had NO test action) + a `Run tests (xcrun xctest)` step. Previously the 757 Swift Testing tests silently never compiled/reran in CI. Local gate: `swift build --build-tests` + `xcrun xctest` = 757 tests / 136 suites passed.
- **Pin guard** (773eeda) — Package.swift: DO NOT bump mlx-swift-lm past `d667610`. Upstream `d7dc03d` (#512) adds `TokenStreamEvent.rejectedToolCall`; the FM-trait switches at `MLXLanguageModel.swift:1890/1943` don't handle it → build-fail under `FoundationModelsIntegration && canImport(FoundationModels, _version: 2)`. _Superseded (2026-08-23, 72bbfbe): pin now at `1441444`; upstream #544 resolved the β5-SDK blocker; no active pin guard._
- **pre-commit** — scope swift-format to staged files (5741015), apply to 9 files (ea79b2a), restore hook verbatim from mlx-swift-lm (e8dc47f).
- **QC zero-crash-risk gates** (4624d29) — `.swiftlint.yml` crash rules pinned (`fatal_error_message` = error; `force_unwrapping`/`force_cast`/`force_try`/`implicitly_unwrapped_optional` = warning), CI gates wired. `Sources/` now: 0 `fatalError`, 1 `precondition` (CoreAIPipelinedEngine.swift:285, structural invariant on init), 2 debug-only `assert` (Tools/ToolEntry.swift:74, Engine/KVCache+CoreAI.swift:541). _Superseded (2026-08-17): swiftlint removed to align with upstream (mlx-swift-lm / coreai-models ship no swiftlint); `.swiftformat`-era `make format` also replaced with swift-format. Crash-safe coding remains a code convention, no longer a CI gate._

### Documentation

- **AGENTS.md 想当然清除第 2 轮**（2026-09-04，4 次"最值得做"命题触发的全量重扫）— ① `ANE path` 引用假 commit `031cb54`（`git rev-parse` 报 unknown revision）→ 实为 `256e704`（penalty routing + ConstrainedGenerationCapable dispatch，`git log --follow MPSGraphSamplers.swift` 实证）+ `c4c0a43`（CoreAI .pipelined wired）；② `precondition` 计数错写 "(8 sites)" + 逐文件错 → 实证 **12 处 / 9 文件**（新增 `XGrammarWrapper`×2 + `TokenizerInfo`×1;`DiscreteFlowScheduler` 改 `preconditionFailure ×3`→`precondition ×2`;`CoreAIStubs` 改 `×1`→`×2`）。前轮已修：`sampleToken` 失实引用（真身 `InferenceStubs.swift:194 sample(from:)`）+ ThinkingBudget ❌→✅（std L3663 + MTP L3181 双路实证 wiring）+ MLXBridge `L635`→`L669/L671`。
- **Baseline accuracy pass** (this entry) — AGENTS.md / README.md / README.zh.md corrected: CoreAI grammar + pipelined now wired, pin state, LOC/counts, platform floor (macOS 14 / iOS 17), model name.

---

## 2026-08-13

### Upstream Sync

- **mlx-swift-lm pinned d667610** — mlx-swift→0.31.6, Qwen3.5 JSON tool-call fallback (#529), Qwen3.5 MTP speculative decoding (#351), ThinkingBudget enforcement (#521), KVCache limits (#514), TurboFlash (#520), ChatConventions migration (#502), CacheConfiguration engine (#514)
- **CoreAI SDK** — macOS 27 system framework, not SPM package (imported via `#if canImport(CoreAI)` guards). Derived code from coreai-models BSD-3-Clause (not a dependency — not in Package.swift)
- **mlx-swift pinned da31870** — JIT source auto-derive, fp8 conversion, Muon optimizer, LR schedules

### Features

- **Upstream alignment verified** — Full source-level audit of MLX/CoreAI/upstream alignment. ReasoningEventEmitter ✅ (7 code refs), KVCacheRuntime ✅ (turboQuant/affine via MLXBridge L635). AgentLoop gap: dead code (556 LOC, 0 callers — removed from inference pipeline; module still present). CoreAI grammar: `_runConstrainedDecoding` uses MLX grammar stack (`MLXGuidedGeneration`); fails on CoreAI path (`mlxModelHandle=nil`). Upstream coreai-models has independent grammar stack (`CXGrammar` → `ConstrainedGenerationSession`) not yet consumed. *(Superseded 2026-08-15: see [Unreleased] above — b69b934)*
- **macOS/iOS dual deploy target** — `Package.swift` declares macOS 14 + iOS 17 minimum. iOS build skips HTTP bridge (L500 `#else`), runs SwiftUI-only Fast Path. CoreAI gate: `#if canImport(CoreAI)` + `@available(macOS 27.0, iOS 27.0, *)` dual-gating
- **P0: Compute channel visibility** — Live `ComputeChannel` badge in ChatView streaming indicator + Dashboard health bar, wired from `HardwareRouter` → `EnginePool` → `AppState` (EN/ZH i18n)
- **P1: Thermal-pressure channel-shift toast** — Auto-dismiss toast on thermal/memory pressure events with from→to channel icons; `ChannelShiftToastOverlay` at ChatView bottom; toast i18n for trigger reason + VoiceOver a11y label
- **P1: Settings capability pills** — MLX/CoreAI pills in About section with `#if canImport(CoreAI)` + `#available(macOS 27.0)` dual-gating; CoreAI grays out on pre-27 platforms
- **P1: Thermal callback fan-out** — `EnginePool.setThermalCallback` closure fans out to both `SessionPool` (session eviction) and `AppState` (UI toast broadcast) via `@MainActor`-aware `await` bridge
- **Swift 6.2** — Upgraded `swift-tools-version` 6.1 → 6.2 (align with mlx-swift-lm #519)
- **MLX typed KV cache + TurboQuant** — Full `KVCacheConfiguration` support with `.turboQuant` and `.affine` strategies via `makeKVCacheConfiguration` (MLXBridge)
- **SessionPool prefix reuse** — Message divergence tracking for prefix-level prompt cache reuse; pooled sessions only re-prefill the diverging suffix
- **SessionPool HardwareRouter eviction** — GPU pressure events trigger aggressive cache eviction before OOM
- **SessionPool state restore** — `loadPromptCacheSnapshot` restores LMOutput.State alongside KV cache for correct position anchoring
- **Persistent-perception system** — PerceptionEngine (13 files, 3,045 LOC in `Multimodal/`): full 7-channel scheduler (camera, screen, network, filesystem, internet, system, speaker) with adaptive sampling, RingBuffer + TTL, inference-aware lock-free snapshot, P-S1/P-S2 perception context injection in tool dispatch loops, cross-platform gates (screen macOS-only).
- **CoreAI sequential engine family alignment** — Option A p1: align CoreAI engine types with upstream sequential/variant architecture
- **MTP speculative decoding** — `generate(::mtpDrafter:)` path with streaming reasoning events
- **Upstream pin d667610** — mlx-swift-lm synced 2026-08-14: Qwen3.5 JSON tool-call fallback, Qwen3.5 MTP speculative decoding, ThinkingBudget enforcement, KVCache limits, TurboFlash, CacheConfiguration engine, KVCacheRound staged rounds. ReasoningEventEmitter ✅ (12 refs), KVCacheRuntime ✅ (turboQuant/affine). Gaps at time of entry: ThinkingBudget hard-budget ❌ (✅ wired 08-14, 686161c), CoreAI grammar ❌ (✅ wired 08-15, b69b934 + c4c0a43 pipelined), AgentLoop gap: dead code

### Bug Fixes

- **P0: Release-safe error handling** — All `precondition` calls removed from production hot paths (28 → 0); replaced with guard/throw/clamp in Metrics, RateLimitMiddleware, TokenizerManager, EnginePool, CoreAIEngine, CoreAISequentialEngine, AgentLoop, AuthMiddleware, EngineLifecycleState, TimingHooks. Tool dispatch `fatalError` replaced with graceful error response. Build verified: 0 errors.
- **Concurrency** — Replaced `os_unfair_lock` raw pointer with `NSRecursiveLock`; extracted Mutex shim for macOS 26 CI compile compatibility
- **Session lifecycle** — P0: 3 fixes including TokenHistory growth bounded to `maxContextLength`
- **CoreAI macOS 26 crash** — Removed `Synchronization` dependency, added Mutex shim, fixed `MLXSamplingMode`/`topK`/tuple enum partial match in MLXBridge
- **CoreAI path metrics** — `reasoningTokenCount`/`promptTokPerSec` now tracked via `ThinkTagParser` with `primedInside` detection
- **toolParser flush** — P0-2: residual event handling + dynamic reasoning detection
- **MLXBridge safety** — `try!` → `do-catch` on KVCacheConfiguration init; all force patterns eliminated
- **ModelScope download** — Strips `mscope:` prefix in `EnginePool.loadModel()`
- **Platform channel state** — P0: iOS picker + i18n hardcoded string fixes

### Refactoring

- **Dead code removal** — `sample(from:)` in CoreAIEngine; consolidated MLX KV cache path

### Documentation

- **AGENTS.md** — Updated Known Gaps, upstream audit status, architecture notes
- **README** — Swift 6.2, typed KV cache, SessionPool improvements

---

## [v0.1.0] — 2026-07-05 → 2026-08-09

### Features

- **Typed tool factory** — `Codable` argument decoding, following the `Tool<Args, Output>` pattern
- **Task-aware prompt engineering** — P0 optimization for prompt quality
- **Gap analysis P0/P1/P2 fixes** — xet disable, cancel cleanup, config TTL cache, parameter estimation, adapter block, mtime stall detection
- **HardwareRouter** — Adaptive GPU/ANE/CPU routing with agent loop token budget 2× compensation and broken-chain repair
- **WiredMemory GPU isolation** — Real-time GPU telemetry and memory isolation
- **WiredMemory** — Policy ID stability and cancel-safe ticket lifecycle
- **Vision multimodal** — OCR + VLM dataURL→CIImage inference path
- **Voice-to-voice loop** — 16 kHz STT + i18n TTS voice + camera integration

### Bug Fixes

- **Request pipeline** — Scoping guard chain to tool path only; non-tool requests no longer blocked
- **Compute channel** — Wired computeChannel to session pool + speculative decoding
- **HardwareRouter data flow** — Wired HardwareRouter → inference pipeline (P0 disconnect fix); wired submitAndDispatch to activate admission gate + hardware router
- **Download pipeline resilience** — Retry logic, stall detection, endpoint config, HF progress, cache integrity; ModelScope temp-file-before-handle and 'blob' type acceptance
- **Scheduler** — Fixed state leak in ChatHandler + AnthropicMessagesHandler
- **EnginePool** — Eliminated force unwrap; tightened CI crash-risk gate; removed leftover `source:` param from `mlxModelLoader.load()`
- **Error mapping** — Wired SchedulerError → AppError in handlers
- **Security** — Closed 2 P0 vulnerabilities from code review
- **Build fixes** — Resolved build break, release warning, and release-mode crash
- **Miscellaneous** — Removed dead HF_ENDPOINT check and dead firstError variable in MCP routeParallel
- **SessionPool cross-session leakage** — Pool release cleared `tools`/`toolDispatch` but missed `additionalContext`, causing reasoning context from a prior request to bleed into the next pooled session (SessionPool.swift L252)
- **CoreAI variant compatibility** — Chunked-static ANE model structure fell back to `sequential` engine, violating upstream `checkVariantCompatibility` (sequential + chunkedStatic = incompatible). Now throws a clear error instead of running an incompatible engine (CoreAIEngine.swift L445-450)
- **CoreAI vocabSize hardcoding** — Config fallback default was Qwen3-specific (151,936). Replaced with model-agnostic 32,768 via `defaultVocabSize` constant; actual vocab size probed from logits descriptor at engine init time (CoreAIEngine.swift L554)

### Refactoring

- **Engine load API** — Removed `source` parameter; `defaultHub` property is sufficient; eliminated prefix-based routing

### Documentation

- Synced README with recent changes (HardwareRouter, AdmissionGate, ThinkingBudget, VLM/OCR, Profiling, 6-language i18n)
- Added tuning-knob documentation for admission gate abort margin fraction
- Fixed misleading comment about per-request device switching

### Chores

- Added complete code review infrastructure (governance)
- Ran SwiftLint: errors → 0, hardened config thresholds, fixed style violations
- Resolved deprecations and renamed symbols

---

## 2026-10-06 — /v1/embeddings 上线（本地 embedding 对外可用）
- **OpenAI 兼容 `POST /v1/embeddings`**：LFM2.5-Embedding-350M（1024d）对任意标准客户端可用（RAG 工具 / 向量库）。
- **单一事实源**：与 GUI 语义搜索共用 EmbeddingService actor —— 同一个熔断器、同一个 HF endpoint，不产生第二个无节流打手；断网 → 诚实 503，绝不伪造向量。
- **truthful wire**：响应 model 字段报告实际跑的 embedder，不回显客户端请求名；`usage` 为真实 embed tokenizer 计数。
- **honest reject**：token-id 数组输入直接 400（异源 tokenizer 的预切 id 只会产生垃圾向量）。
- 6 条线契约单测（多态 input 解码、空输入、身份真实、float32 round-trip）。CLT 2010/2010 绿。

## 2026-10-06 — embedding 能力面闭环（可发现 + 可路由 + 不误用）
- **`GET /v1/models` 列 embedder**：`capabilities:["embed"]` + 诚实 `state`（hub 缓存软链解析 = ready，否则 download_required）——标准客户端能力探测可见。
- **chat 路由 capability gate**：embed id 打 `/v1/chat/completions` → 即时 400 + 可行动指引（修复 90s 挂起：embed 模型无生成头，CPU 加载后无法产出 token）。
- 活体：embed→chat=400/1.7ms；embed→embeddings=200/14ms(warm)；chat 回归 200/0.9s；`/v1/models` 双条目正确。CLT 2010/2010 绿（一次 frontmost 干扰按规程复跑裁决）。
- **Embedding cache-first load（本轮）**：完全物化的 hub 快照（refs→snapshot→blob 软链全解析）重写为 `ModelConfiguration(directory:)` 直接磁盘加载，零 revision 网络往返 — 冷启动 60.7s→0.58s（GFW 断网日实测，日志 `served from local cache (no network)`）。未缓存机器原样走 hub 下载路径。CLT 2010/2010 绿。
