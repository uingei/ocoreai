# Build / test gate reality — host forensics

> The long form behind § *Build / Test / Lint* → "Gate tiering" in `AGENTS.md`, moved out of the
> injected layer on 10-14 so the root file keeps judgment and verdicts. Every number here was
> measured on the owner's host (macOS 26 · CLT + Xcode); CI remains the authoritative gate.
**10-14: a toolchain update invalidated the route premises, so they became assertions.** One Xcode/CLT
update repointed CLT's `MacOSX.sdk` from 26.5 to **27.0** (SDK 27 ships `CoreAI.framework`, measured:
absent in `MacOSX26.5.sdk`) and moved swiftc 6.3.3 -> 6.4, so `DEVELOPER_DIR=…/CommandLineTools`
**no longer** meant the "macOS 26 / no-CoreAI" route — `canImport(CoreAI)` silently flipped true and
macOS 27-only blocks compiled into the shipping shape — and `swift build` stopped being executable
because `metal` is not installed. Full incident (times, negative controls, remedies): `CHANGELOG.md`,
grep `toolchain-contract`. Two rules came out of it and both still hold: a route is *asserted*, never
inferred from the environment (`scripts/toolchain-contract.sh`; R1 "the shipping SDK carries no CoreAI"
is a hard gate that also runs in CI's `audit` job), and `make test-clt` passes
`SDKROOT=<newest CoreAI-free SDK>` explicitly instead of trusting the symlink. Sandbox gotcha that cost
a session: `HOME` must be the canonical `/private/tmp/…` — `/tmp/…` leaves two same-named `.pcm` files
in the clang module cache and swift-frontend SIGSEGVs on `_DarwinFoundation1`.

**Sandboxed route = compile + non-Metal tests, no approval needed (verified 10-13):** a compile gate does *not* require escalation. `HOME=<writable-dir> DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path .build-clt --disable-sandbox` goes green inside the agent sandbox. `--disable-sandbox` drops only SwiftPM's *own* nested sandbox for the
package-manifest compile (nesting is impossible here: `sandbox-exec: sandbox_apply: Operation not permitted`); the outer harness sandbox still applies — the same run is denied writing `~/.cache/clang`, which is exactly why `HOME` must point somewhere writable. `make test-clt`'s `-F`/`-rpath` flags are still required for the Testing library, and `DEVELOPER_DIR` keeps it on the
macOS-26 (no-CoreAI) route. Inside the sandbox pure-logic suites really run — `--filter 'SessionIsolation|MemoryPressureCorroboration|HardwareRouter|EnginePoolRouting'` = **79 tests / 15 suites green** — while Metal suites self-skip (`.enabled(if: MTLCreateSystemDefaultDevice() != nil)`) and `xcodebuild` cannot run at all (`xcodebuild: error: 'ocoreai.xcworkspace' is not a
workspace file`), so the `test-ci` and `build-ios` legs stay CI's job. Tiering: sandbox → build + non-Metal suites; escalation → full suite + live `serve`/`curl`; `xcodebuild` legs → CI.

**The sandbox route is conditional — the Metal node must be clean (10-14, reproducible).** The Metal
toolchain's clang resolves its module cache to the *real* user home (`/var/folders/<…>/C/clang/
ModuleCache/*.pcm`) whatever `HOME` the caller exports — not `~/.cache/clang`, and a gate naming the
wrong path sends the next reader hunting in the wrong directory (measured by executing the compile: the
probe log names `…/C/clang/ModuleCache/EZOWFP9CXT4Z/metal_types-1GW5E2293HVCX.pcm`). So once
`mlx-swift_Cmlx`'s `CompileMetalFile` node goes dirty, `swift build --scratch-path .build-clt
--disable-sandbox` fails with `unable to open output file '…/.cache/clang/…pcm': Operation not
permitted`, and no `-Xcc -fmodules-cache-path=` helps because a Metal job is not a SwiftPM clang job.
What dirties it: `swift build --build-tests` in the same scratch, and adding `-Xcc` flags.
`--build-tests` also needs clang temp files and jobs run with cwd `/Users/uingei`, so `TMPDIR` must be
the canonical `/private/var/folders/<…>/T` (a `TMPDIR` under `/private/tmp` still died with
`unable to make temporary file`). **Practical rule:** keep the sandbox for the app-target build and run
the test gate unsandboxed (`make test-clt`); when the sandbox route suddenly dies on `CompileMetalFile`
it is a stale Metal node plus an unwritable module cache, not a code regression — one unsandboxed build
fixes it, do not revert code to "fix" it.

**Shader payload (10-14): why the test binary could not find `default.metallib`.** `make test-clt`
died 352 tests in with `MLX error: Failed to load the default metallib` — a process abort, not a skip,
with no cause named. MLX's `load_default_library` (mlx `mlx/backend/metal/device.cpp:196-244`) searches
five PATH SHAPES (colocated `mlx.metallib`, `Resources/mlx`, a **loaded** `mlx-swift_Cmlx` bundle under
`Bundle.main`/`allBundles`/`allFrameworks`, `Resources/default`, then the compile-time default), and
SwiftPM 6.4 puts the runner three levels below its resource bundle, so all five miss even though the
payload demonstrably exists in the products dir. mlx-swift-lm never sees this: it tests through
`xcodebuild build-for-testing`, which puts resources within reach of its own runner. So the payload is
resolved upstream-first and handed to MLX through the API built for it — `MLX.GPU.metallib`
(mlx-swift `Source/MLX/GPU+Metal.swift:54-73`, "set early in the process to override or provide the
metallib load path"), once at `EnginePool.init` via `MetalShaderLibrary.swift`, with
`$OCOREAI_METALLIB` as the explicit override. Copying it *into* the bundle is not available: a
`.metallib` under `Contents/MacOS` is a nested code object and CodeSign dies with
`code object is not signed at all`. Gates: `MetalShaderLibraryTests` pins the candidate order against a
synthetic SwiftPM 6.4 layout (red the day the layout moves), `$OCOREAI_METALLIB` precedence, and "never
hand back an unverified path" — and it reads the Makefile, so "don't stage into a signed bundle" stays
a red build rather than a comment. The ladder itself is `scripts/resolve-metallib.sh`.

**R2 must not infer (10-14):** `metal --version` and a listing of the cryptexd mount both flip with the
environment — the same `report` answered `metal=ok-cryptex` inside the sandbox and
`metal=component-missing` outside it within a minute, while llbuild compiled `arg_reduce.metal`
successfully in that unsandboxed run. The stable fact is upstream's:
`xcodebuild -showComponent MetalToolchain` → `Status: installed` (parse `Status:`, never the exit code,
which is 0 even when uninstalled — mlx-swift-lm `pull_request.yml:221-229`). `make toolchain-check`
asks that question on **both** candidate routes rather than the ambient `DEVELOPER_DIR` — the old
single-route check declared "this host cannot produce the macOS-26 shape" as fact while the CLT route
still held a CoreAI-free SDK 26.5, and a warning that fires every run is a warning nobody reads when it
becomes true — and `--probe-metal` settles R2 and R3 by compiling a kernel.

## The four defects the live loop caught (dated table: `CHANGELOG.md`)

All four were found by running `ocoreai serve` and calling `/v1/*` on this host — a route-level
audit of the same code missed every one of them, which is the entire argument for treating a
live check as a different instrument rather than a nicer-looking grep. The dated table (wire
statement vs engine fact vs where the fix landed) is diary and lives in `CHANGELOG.md`,
grep "live loop caught".


The generalization, which is what to carry forward: **a defect in the *mapping* from engine
state to wire statement is invisible to any static reading of either side.** Both sides are
individually correct; only the pair fails. So the standing gate for capability surfaces is a
live assertion about the pair (`scripts/probes/`), not a test of the handler alone.

## Anchors for the cites above (`make anchor-check`)

<!-- anchor:mlx-swift-lm .github/workflows/pull_request.yml:214-237 Infra: install MetalToolchain -->
<!-- anchor:mlx-swift-lm .github/workflows/pull_request.yml:221-229 Status: -->
<!-- anchor:mlx-swift-lm .github/workflows/pull_request.yml:250 xcodebuild build-for-testing -->
<!-- anchor:mlx-swift Source/MLX/GPU+Metal.swift:54-55 metallib load path -->

## 本地全量到底能不能跑（moved out of AGENTS.md 10-19(续3), byte ratchet）

the full suite **does** run on this host — ~2.7k tests / ~480 suites on the CLT route (`make test-clt`).
The blocker was the **agent sandbox**, never the platform, metallib or macOS 26: inside it MLX logs
`No Metal device available` and the first MLX suite dies. And `ocoreai serve` + live `curl` on `/v1/*` work
locally — the loop that caught defects no static audit here had (see «The four defects the live loop caught»).
**Prefer a live check over an inference whenever a claim is about behaviour.**

## CoreAI constrained decoding: the span this host can never run (moved out of AGENTS.md, byte ratchet)

`Engine/CoreAI`'s `_applyBitmask` (`EngineInference.swift:1386`) contradicts its own doc in two places:

1. The doc says "disallowed tokens -> -inf"; the code writes `Float.leastNormalMagnitude * -1`
   (about -1.18e-38), which under an additive mask is ~0, so a "banned" token keeps almost its whole
   logit through softmax.
2. `guard tokenIdx < vocabSize, tokenIdx < logits.count else { return }` inside the loop returns from
   the whole function at the **first out-of-range index**, skipping every mask word after it where the
   semantics want `continue`.

The only caller is `_runConstrainedDecoding` (`@available(macOS 27.0,*)`; defined :1081, mask call
:1223). The CLT SDK has no CoreAI and macOS 26 neither compiles nor runs this, so the fix is obvious
(`-Float.infinity` + `continue`) but is neither made nor claimed until it runs on macOS 27 - the
same-named § Open item keeps only the criterion and the pointer. Gate: the floored source-scan style of
`V1EndpointCatalogTests` would fit, but it pins unrunnable code; a behavioural gate needs CI's macOS 27
leg.

Two more sites sit behind the same wall, so they are unverifiable here and unclaimed: the fp8->fp16 KV
conversion, which sits *before* Apple's own fix in the reference tree, and the FoundationModels-block hub
fallback (one `HubReachability` site), whose `canImport(FoundationModels)` block is SDK-gated out.

## Test runs on this host (measured 10-26)

**A local test run must name its shader payload, or it reports nothing (measured 10-26).**
Letting MLX search for the library dies at the first Metal allocation
(`Failed to load the default metallib`, Cmlx `mlx-c/memory.cpp:69`) thousands of lines in, exit 1,
**no summary**: neither a pass nor a fail. `make test` exports `$OCOREAI_METALLIB` from
`scripts/resolve-metallib.sh`, the one ladder. It prints the rung that won and exits 1 naming
`xcodebuild -downloadComponent MetalToolchain` when nothing is usable; `make test-clt` stages the
winner beside the products dir instead (a payload inside a signed bundle fails the sign step).
Same tree, both routes: **CLT (SDK 26.5, `--no-parallel`) 3180 tests / 562 suites green in 429 s**;
**Xcode (ambient SDK 27, parallel) 3343 / 588**. Three of its reds are the platform talking, not the
tree: `requires macOS 27 / iOS 27` (`LegacyConstrainedDecodingStrategyTests` ×2,
`CoreAILiveGenerateTests`) — SDK 27 compiles them in and macOS 26 will not run them, so one local red
there is two verdicts (skip-instead-of-fail sits in § Open). The rest are wall-clock budgets losing to
parallelism, green standalone in seconds and drifting in set from run to run: `MCPStderrDiagnosisTests`
loses a child's stderr, and `EngineBusyAdmissionTests`, `SleepSteerWakeTests` and one exec-reap test
miss a beat. A former round blamed these on four suites sharing one seeded file in
the repo workspace — wrong, each seeds its own temp dir; the cause was an unleased
`SessionWorkspace` setter, now owned by `ProcessGlobalLease` and floored by
`ProcessGlobalLeaseDisciplineTests`.
**`swift test --filter` needs `--disable-xctest`**: filtered `swift test` `signalled(11)` inside
`swiftpm-xctest-helper`, which serves only the XCTest half; with it off `make test FILTER=<Regex>`
answers in seconds and `make test-clt FILTER=<Regex>` covers the rest. Both cite swift-testing **IDs** —
a suite *type* name, not its display text.

**A lease must not span live network (measured 10-26).** Making the workspace anchor exclusive put every
env-touching suite behind one lock, and the run went 122 s -> 370 s with 9 false reds: three
`ReadyHubDownloaderFlatTests` cases deliberately take the network path, each holding the lock through
122 s of connect timeout against a hub this host black-holes. `HubClient` reads `HF_ENDPOINT` at
construction (swift-huggingface `Sources/HuggingFace/Hub/HubClient.swift:116`, `detectHost()` at :189),
so that suite now pins it to a port that refuses on loopback — same five tests, same assertions,
366.0 s -> 0.03 s, and they no longer depend on whether the machine has a network. Full run:
122 s -> 15 s. `ProcessGlobalLease.waitBudget` is 60 s and on expiry *records and proceeds*: a leaked
lease is a named red, never a hang (before the deadline it hung 13 min with 19 cooperative threads
parked on the lock and `sample` named the holder).

**A process-global singleton is the same hazard as an env var.** `PerceptionEngine.stop()` fires a
detached `SystemContextSensor.shared.stop()` (`PerceptionEngine.swift:292`) that lands whenever the pool
likes, so the live sensor suite read `no context` on one full run and passed the next. `pollLoop`
published to `Self.shared` rather than `self`, so no second instance could be driven; it publishes to its
own instance now and the suite owns its sensor, and reverting the publish target turns that suite red —
both directions measured 10-26. Shipped behaviour is unchanged: `shared` is the only instance
production starts (`PerceptionEngine.swift:265`).
