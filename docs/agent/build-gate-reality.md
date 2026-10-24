# Build / test gate reality — host forensics

> The long form behind § *Build / Test / Lint* → "Gate tiering" in `AGENTS.md`, moved out of the
> injected layer on 10-14 so the root file keeps judgment and verdicts. Every number here was
> measured on the owner's host (macOS 26 · CLT + Xcode); CI remains the authoritative gate.
**10-14 工具链前提被更新推翻 —— 已改为断言(`make toolchain-check`)**:今天 06:45–06:46 一次 Xcode/CLT 更新同时改掉下一条的两条前提。① CLT `SDKs/MacOSX.sdk` 由 26.5 改指 **27.0**,而 SDK 27 内含 `System/Library/Frameworks/CoreAI.framework`(实测:`MacOSX26.5.sdk` 无、`MacOSX27.0.sdk` 有)⇒
`DEVELOPER_DIR=/Library/Developer/CommandLineTools` **不再**等于「macOS 26 / no-CoreAI」路线,`canImport(CoreAI)` 静默翻真,macOS 27-only 代码块开始编进所谓交付构建。② CLT swiftc 6.3.3 → 6.4(今晨 swift-frontend 崩溃日志与 `swift --version` 双证),SwiftPM 6.4 原生编译 `.metal`,而本机 `metal` 不可用(CLT 不带;Xcode 侧回 `cannot
execute tool 'metal' due to missing Metal Toolchain`)⇒ 依赖 mlx 的目标一旦 artifacts 失效就编不动,「`swift build` exit 0 = done」当场不可执行。修法:`scripts/toolchain-contract.sh`(R1 交付 SDK 不含 CoreAI = 硬门,CI `audit` job 同跑;R2 shader 编译器 = 建议项,`--require-metal` 升硬)+ `make test-clt` 显式传 `SDKROOT=<最新无 CoreAI 的
SDK>`,不再信 `MacOSX.sdk` 符号链接。本机恢复配方:`xcodebuild -downloadComponent MetalToolchain`,然后 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`(Xcode 只带 SDK 27,故 no-CoreAI 形状要从 CLT 的 26.5 借)。另记沙箱 gotcha:`HOME` 必须用 canonical 路径 `/private/tmp/…`;
写成 `/tmp/…` 会让 clang module cache 出现 `/tmp` 与 `/private/tmp` 两份同名 `.pcm`,swift-frontend 直接 SIGSEGV(`module '_DarwinFoundation1' is defined in both …`)。

**Sandboxed route = compile + non-Metal tests, no approval needed (verified 10-13):** a compile gate does *not* require escalation. `HOME=<writable-dir> DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path .build-clt --disable-sandbox` goes green inside the agent sandbox. `--disable-sandbox` drops only SwiftPM's *own* nested sandbox for the
package-manifest compile (nesting is impossible here: `sandbox-exec: sandbox_apply: Operation not permitted`); the outer harness sandbox still applies — the same run is denied writing `~/.cache/clang`, which is exactly why `HOME` must point somewhere writable. `make test-clt`'s `-F`/`-rpath` flags are still required for the Testing library, and `DEVELOPER_DIR` keeps it on the
macOS-26 (no-CoreAI) route. Inside the sandbox pure-logic suites really run — `--filter 'SessionIsolation|MemoryPressureCorroboration|HardwareRouter|EnginePoolRouting'` = **79 tests / 15 suites green** — while Metal suites self-skip (`.enabled(if: MTLCreateSystemDefaultDevice() != nil)`) and `xcodebuild` cannot run at all (`xcodebuild: error: 'ocoreai.xcworkspace' is not a
workspace file`), so the `test-ci` and `build-ios` legs stay CI's job. Tiering: sandbox → build + non-Metal suites; escalation → full suite + live `serve`/`curl`; `xcodebuild` legs → CI.

**Sandbox route is conditional — the Metal node must be clean (10-14, reproducible):** the Metal toolchain's clang resolves its module cache to the *real* user home (`/var/folders/<…>/C/clang/ModuleCache/*.pcm` — the Darwin user cache. Corrected 10-14 by executing the compile: the probe log names
`/var/folders/dy/hh313rts3g3b7hdwzzw7mwrr0000gn/C/clang/ModuleCache/EZOWFP9CXT4Z/metal_types-1GW5E2293HVCX.pcm`. It is *not* `~/.cache/clang`, and a gate that names the wrong path sends the next reader hunting in the wrong directory) whatever `HOME` the caller exports, so once `mlx-swift_Cmlx`'s `CompileMetalFile` node goes dirty, `swift build --scratch-path .build-clt
--disable-sandbox` fails with `unable to open output file '/Users/uingei/.cache/clang/…pcm': Operation not permitted` — and no `-Xcc -fmodules-cache-path=…` helps, because a Metal job is not a SwiftPM clang job. What dirties it here: running `swift build --build-tests` in the same scratch dir (the `-t` variants rebuild the C/Metal graph) and adding `-Xcc` flags; the
identical command was green earlier the same morning. `--build-tests` additionally needs clang temp files, and jobs run with cwd `/Users/uingei` (not writable), so `TMPDIR` must be the canonical `/private/var/folders/<…>/T` — a `TMPDIR` under `/private/tmp` still died with `clang: error: unable to make temporary file: Operation not permitted` on `CNIOBoringSSL-t`.
**Practical rule:** keep the sandbox for the app-target build, run the test gate unsandboxed (`make test-clt`); when the sandbox route suddenly dies on `CompileMetalFile` it is a stale Metal node plus an unwritable module cache, not a code regression — one unsandboxed build fixes it, do not revert code to "fix" it.

**Shader payload (10-14): why the test binary could not find `default.metallib`, and whose fix this is.**
`make test-clt` died 352 tests in with `MLX error: Failed to load the default metallib` — a process abort, not a
skip, with no cause named. MLX's `load_default_library` (mlx `mlx/backend/metal/device.cpp:196-244`) searches five
PATH SHAPES: colocated `mlx.metallib`, `Resources/mlx`, a **loaded** bundle named `mlx-swift_Cmlx` under
`Bundle.main`/`allBundles`/`allFrameworks`, `Resources/default`, then the compile-time default. SwiftPM 6.4 puts the
runner at `.build-clt/out/Products/Debug/ocoreaiTests.xctest/Contents/MacOS/ocoreaiTests` while its resource bundle
sits three levels up at `…/Debug/mlx-swift_Cmlx.bundle` — that `.xctest`'s own `Contents/Resources/` carries
NIOSSL/Crypto/Hub/ocoreai bundles but no Cmlx — so all five miss even though `default.metallib` demonstrably existed
in the products dir. mlx-swift-lm has no equivalent failure and **zero** `metallib` references in-tree: it tests via
`xcodebuild build-for-testing`/`test` (`pull_request.yml:214-237`, `:250`), where Xcode puts resources within reach
of its own runner, and its whole shader story is "install the Metal Toolchain component, then let SwiftPM compile
`.metal`". So the payload is now chosen upstream-first — SwiftPM's own freshly compiled
`out/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, then an Xcode DerivedData copy (same
repo, possibly older revision), then the pip wheel (different release entirely; last resort) — staged **beside** the
products dir and handed to MLX through the API upstream provides for exactly this purpose (`MLX.GPU.metallib`,
mlx-swift `Source/MLX/GPU+Metal.swift:54-73`: "can be set early in the process to override or provide the metallib
load path"), resolved once at `EnginePool.init` by `Sources/ocoreai/Engine/MetalShaderLibrary.swift`, with
`$OCOREAI_METALLIB` as the explicit override. Copying it *into* the bundle is not available: a `.metallib` under
`Contents/MacOS` is a nested code object, so the build's CodeSign task dies with `code object is not signed at all …
mlx.metallib` (measured). Gates: `MetalShaderLibraryTests` pins the candidate order against a synthetic SwiftPM 6.4
layout (red the day the layout moves again), `$OCOREAI_METALLIB` precedence, and "never hand back a path that was
not verified" — and it reads the Makefile, so "don't stage into a signed bundle" stays a red build, not a comment.

**R2 must not infer (10-14):** `metal --version` and a listing of the cryptexd mount both flip with the
environment — the same `report` command answered `metal=ok-cryptex` inside the agent sandbox and
`metal=component-missing` outside it, within one minute, while llbuild compiled `arg_reduce.metal` successfully in
that unsandboxed run. The stable fact is upstream's: `xcodebuild -showComponent MetalToolchain` →
`Status: installed` (parse `Status:`, never the exit code, which is 0 even when uninstalled — mlx-swift-lm
`pull_request.yml:221-229`). The contract now asks that question, and `make toolchain-check` evaluates **both**
candidate routes (Xcode and CLT) instead of the ambient `DEVELOPER_DIR`: the old single-route check declared "this
host cannot produce the macOS-26 shape" as fact while the CLT route on the same host still had a CoreAI-free SDK
26.5 — and a warning that fires every run is a warning nobody reads when it becomes true. `--probe-metal` closes the
last gap: it compiles a trivial kernel with every reachable `metal`, so R2 answers "can a `.metal` be compiled here?"
by doing, and the same compile settles R3 (module-cache writability) in one shot — it is how both facts above got
measured.


## SDK vs compiler, and where clang really puts its modules (measured 10-14)

`swift package dump-package --disable-sandbox` on the CLT route fails before any target compiles:

```
<unknown>:0: error: unable to open output file
  '/var/folders/<hash>/C/clang/ModuleCache/2IGBZH9CRVPOD/SwiftShims-1WSVJG4746Q51.pcm':
  'Operation not permitted'
…/MacOSX.sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface:5:8:
  error: could not build Objective-C module 'SwiftShims'
…/Swift.swiftinterface:1:1: error: failed to build module 'Swift'; this SDK is not supported
  by the compiler (the SDK is built with 'Apple Swift version 6.4 … swiftlang-6.4.0.31.4
  clang-2100.3.31.1', while this compiler is '… swiftlang-6.4.0.34.1 clang-2100.3.34.1')
```

Two independent causes, both invisible in the message:

1. **SDK/compiler skew.** `SDKs/MacOSX.sdk` now points at 27.0, whose `.swiftinterface` files were
   emitted by a *newer* swiftlang than the CLT compiler in the same toolchain. Pinning
   `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` (the newest SDK without
   CoreAI) selects an interface the compiler can read — and keeps the macOS-26 shape, which is the
   delivery shape anyway.
2. **clang ignores `HOME` for its module cache.** It resolves to the Darwin user cache
   (`/var/folders/<hash>/C/clang/ModuleCache`), unwritable inside the agent sandbox. The knob clang
   does honour is `CLANG_MODULE_CACHE_PATH`, not `-Xcc -fmodules-cache-path` (a SwiftPM manifest
   compile takes neither), and it is the same root cause as the `CompileMetalFile` failure above.

Working recipe, verified exit 0 (12,046 B of manifest JSON) with nothing escalated:

```bash
HOME=/private/tmp/<dir> TMPDIR=/private/tmp \
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLANG_MODULE_CACHE_PATH=/private/tmp/mmcache \
swift package dump-package --disable-sandbox
```

Open question for the owner: wire `CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build-clt/module-cache` into
`make test-clt` and the sandbox build recipe (one line; first run re-builds PCMs, CI is unaffected
because it resolves cleanly). The instrument that would settle it is
`bash scripts/toolchain-contract.sh check --probe-metal`, which already compiles a kernel and
therefore observes module-cache writability directly.

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

## CoreAI 约束解码：本机永不可运行的那一段（moved out of AGENTS.md 10-19(续3), byte ratchet）

`Engine/CoreAI` 的 `_applyBitmask`（`EngineInference.swift:1386`）有两处与自己的文档相反：

1. 文档写「disallowed tokens → -inf」，代码却是 `Float.leastNormalMagnitude * -1` ≈ −1.18e-38 —— 在加法掩码下
   几乎等于 0，等于没掩：被禁的 token 仍以接近原值参加 softmax。
2. 循环内 `guard tokenIdx < vocabSize, tokenIdx < logits.count else { return }` 在**首个越界索引**处整个函数返回，
   跳过其后所有掩码字（正确语义是 `continue`）。

唯一调用点是 `@available(macOS 27.0,*)` 的 `_runConstrainedDecoding`（定义 :1081、掩码调用 :1223）。CLT SDK 无 CoreAI，
macOS 26 既编不进也跑不了这段 ⇒ 改法虽然显然（`-Float.infinity` + `continue`），在 macOS 27 上真跑通之前不臆修、
不宣称已修（AGENTS.md §Open 的同名条目只留判据与指针）。门：`V1EndpointCatalogTests` 那套自带地板的源码扫描风格
适合它，但断言的是一处不可运行的代码 —— 需要 CI 的 macOS 27 leg 才能长出真正的行为门。
