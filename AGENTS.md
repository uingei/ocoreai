# ocoreai — Project Context for AI Agents

> This file is loaded by the coding agent (Codex — CLI and desktop app) on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.
>
> **It is not free.** Every byte here is paid for on every session, so this file carries judgment,
> invariants and verdicts and pushes long-form evidence one hop away (§ Read on demand, § Routing
> table). `make docs-check` enforces a shrink-only cap and re-runs every number claimed here.

---

## AI Contribution Policy

This project is developed with heavy AI assistance. The rules:

1. **Every line in git is reviewable** — AI-generated or not, the owner approves each commit. "It came from the model" is never an exception to a rule in this file.
2. **No claim without a check** — "verified", "fixed", "aligned" in a commit message or doc must be immediately backed by command output (build/test/grep) in the same session.
3. **When in doubt, point outward** — if an upstream repo (mlx-swift-lm / coreai-models / codex) already has an answer, consume/reference it instead of authoring a local variant; cite the upstream file:line.
4. **An improvement answers three questions** — *what* behaviour improved, *what output* makes you think so (same-session command output; label inferences as inferences), and *which gate goes red* if it regresses. No answer to the third ⇒ it is a claim, not a change: record it as an open item plus the instrument that would settle it. Full text: `CONTRIBUTING.md` → "The three questions". The gate must assert its own premises too (`make toolchain-check`), because a check that infers the platform from its environment rots silently when the toolchain updates.

---

## Identity

**What it is:** an agent for open models, natively local — built for creativity, work, and code; a complete agentic system designed for coding and knowledge work. (09-27 canonical，用户三度给出此句为定版。09-27「open frontier models / coding and knowledge work」是其完整化表述，兼容并存、非互斥，不淘汰任一表述。） coding 最深切片 = Coding/Computer Agent (reliable Execute → Verify → Recover)；knowledge work / creativity (Apple 原生感知/多模态) = 一等产品面. Dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline. One binary.

**Tech stack:** Swift 6.2 · SwiftPM · Hummingbird 2.26 · SwiftUI · SQLite + FTS5

**Key modules:** subdirectories under `Sources/ocoreai/`: Engine, Agents, Client, Scheduler, MCP, Tools, UI, SQLite, Config, Multimodal, Reasoning, Profiling, Tokenizer, Security, Skills, Video, etc. (the full set is the directory listing itself — not counted here).

---

## Two invariants

Almost every rule below is a corollary of these two. When a shortcut and an invariant collide, the invariant wins.

1. **A claim is worth exactly the gate that goes red when it breaks.** A fix with no gate is a claim; a gate that infers its own premises from the environment rots the day the toolchain moves (SDK 26.5 → 27.0 flipped `canImport(CoreAI)` mid-session); a scan that stopped matching passes vacuously unless it floors its own hit count; and a doc whose numbers nobody re-greps drifts — three "verified" numbers here had already moved when `make docs-check` was written. Corollaries: policy 2 + 4, `make toolchain-check`, `V1EndpointCatalogTests`' floors, § Docs Contract.
2. **The surface never claims more than the engine delivered.** ocoreai's product is a GUI that sees, hears, speaks and codes, so every capability statement a user can read (`/v1/models`, `/v1/capabilities`, the dashboard, a tool result, the composer, a localization string) must be *measured*, and must degrade honestly where the backend is absent. Corollaries: `tokenizerBackend: real|heuristic`, `vlm:` from the manifest, the endpoint index behind the 404 hint, `/v1/steer` delivering on the next request, chat `audio_url` heard-or-refused, no fabricated `terminal command:` output on zero-tool turns. When authority is unclear: run it and read what came back.

---

## Architecture (3-Layer Stack)

```
HTTP API Layer (Handlers/) → Router/Middleware
    ↓
Engine Layer (Engine/) — EnginePool(actor) → EngineInference → MLX/CoreAI backend
    ↓
Scheduler Layer (Scheduler/) — SchedulerActor, AdmissionGate, MemoryTracker, OOMGuard
    ↓
UI Layer (SwiftUI) — ChatViewModel, SessionManager(SQLite)
```

**Dual Path reality:**
- `EnginePool` uses inline `#if canImport(CoreAI)` branches (`BackendProtocol` deleted 2123143, 0 refs remaining)
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (wired, both MLX + CoreAI paths), KVCacheRuntime ✅ (`turboQuant`/`.affine` 双路: `MLXBridge.swift:771 case "affine"` / `:773 case "turbo-quant"` → `.turboQuant(:820/:863)` / `.affine(:828/:833/:870)`). Pinned upstream `mlx-swift-lm` at `6e338e5` (10-16 round 13, 8 commits。头条 **#700**: text-only VLM prompt 不再配全 1 attention mask ⇒ 只增长的会话真正复用前缀（实测见下条 SessionPool）；并给旋转缓存精确 rewind（**#622**，`KVCacheConfiguration.rewind` opt-in、`isTrimmable`→`maxTrimCount`）。其余逐条裁决 = CHANGELOG rounds 9–13。) **ThinkingBudget** ✅ (两路皆接，10-16 重钉行号: std `EngineInference.swift:4119 .applyingThinkingBudget` + `:4134 components: genComponents`; MTP `:3615 .applyingThinkingBudget` + `:3638 components: mtpGenComponents`; `guard mtpReasoningConfig` 非空才接, `catch → .init()` 回退与 std 同语义).
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement. Engine/ contains CoreAI* ×14 + StateHandler(+ ×3) + MPSGraphSamplers(1511L) + KVCache/TensorStorage(+CoreAI) (Engine/ 44 .swift total); + Tokenizer/TokenizersMLXTokenizerAdapter.
- **ANE path:** CoreAI `MPSGraphSamplers` (`MPSGraphSamplers.swift` 1511 行实存, `CoreAIPipelinedEngine.swift:53/601` 消费) wires MPS constrained argmax/composite/sampler — the GPU-based constrained decoding path
- **MTP path:** `_runInferenceWithMessages` → `generate(::mtpDrafter:)` — bypasses ChatSession, tool calls collected + dispatched per-iteration (aligned with upstream `MTPSpeculativeTokenIterator`)
- **SessionPool:** message-level *feed* dedupe (divergence tracking). Whether the KV cache skipped a prefill is upstream's decision, reported only via `.info.cachedPromptTokenCount`; the engine logs it per turn (`EnginePool.accountPrefixReuse`) and publishes it per model (`prefixReuse` on `/v1/models/:model/kv-cache`). **Measured 10-16 at pin `6e338e5`** (probe 01, gemma-4-e2b-it-4bit, one conversation): HIT turns went `cached=0` → `710/730` and `733/749`, promptTime 107/182 ms → 83/88 ms. 省的是随历史长度增长那一项，每轮仍剩 ~80 ms 固定开销。改历史的 resend 另议（§ Open）。HardwareRouter pressure events still trigger aggressive eviction; `loadPromptCacheSnapshot` restores LM state + KV cache (disk identity/refusal semantics: CHANGELOG 10-13)

**Key:** `#if canImport(CoreAI)` single-layer compile-time gate; token sampling → `argmax`(greedy) / `multinomialSample`(temperature>0) — 真身 `Models/InferenceStubs.swift:198 sample(from:)`(temperature/topK/topP/minP filters, 对上游 CompositeSampler 算法).

**Upstream alignment:**
- `KVCacheRound` / `TurboFlash` / `TurboQuant`: consumed internally by upstream `generate*()` — no downstream intervention needed
- `KVCacheConfiguration`: full `.turboQuant` + `.affine` dual-path via `makeKVCacheConfiguration` (MLXBridge)
- `toolDispatch`: ocoreai closure → `ToolRegistry.call()` wired through ChatSession restart loop
- `MTP toolCall dispatch`: collected per `Generation.toolCall`, dispatched after each iteration, results appended to message history

---

## Build / Test / Lint

```bash
swift build -c release                    # production build
swift build --traits appStore            # App Store build (traits: appStore | FoundationModelsIntegration)
swift test                               # full suite — runs locally on macOS 26 IF the process is not sandboxed (Metal needed); CI macos-26 remains the authoritative gate
swift test --enable-code-coverage        # with coverage
swift test --filter SystemContextSensor  # one suite (substring match)
```

**Local gate reality (corrected 10-12, and it was wrong for weeks):** the full suite
**does** run on this host — `2378 tests / 442 suites` in ~45 s on the CLT route
(`make test-clt`; the count moves with each added suite). The blocker was never the
platform, the metallib, or macOS 26 but the **agent sandbox**: inside it MLX logs
`[metal::load_device] No Metal device available` and the first MLX-touching suite dies;
unsandboxed the same binary loads a model and streams tokens. The consequence that
matters more than the count: `ocoreai serve` + live `curl` on `/v1/*` is available
locally, and that loop caught four defects no static audit here had (the four, each with
its fix: `docs/agent/build-gate-reality.md`). **Prefer a live check over an inference
whenever a claim is about behaviour.**

**Gate tiering — the decision. Full host forensics (the `default.metallib` layout archaeology, the module-cache/`TMPDIR` shape, the toolchain bump that flipped `canImport(CoreAI)` mid-session): `docs/agent/build-gate-reality.md`.**
- **sandbox** → app-target build + non-Metal suites: `HOME=<canonical writable path> DEVELOPER_DIR=/Library/Developer/CommandLineTools SDKROOT=<latest SDK without CoreAI> swift build --scratch-path .build-clt --disable-sandbox`. `--disable-sandbox` drops only SwiftPM's own nested sandbox; the harness sandbox still denies `~/.cache/clang`, which is why `HOME` must move — and it must be the canonical path (`/tmp` vs `/private/tmp` yields two same-named `.pcm` and swift-frontend SIGSEGVs).
- **escalation** → `make test-clt` (full suite) + `make probes` (live `/v1/*`, `scripts/probes/`).
- **CI only** → the `xcodebuild` legs (`test-ci`, `build-ios`).
- If the sandbox route suddenly dies on `CompileMetalFile`: stale Metal node + unwritable module cache, **not** a code regression. One unsandboxed build fixes it — do not revert code to "fix" it.
- `make toolchain-check` evaluates **both** candidate routes (Xcode and CLT) rather than the ambient `DEVELOPER_DIR`, and settles Metal by *compiling a kernel*, never by `metal --version` (whose answer tracks whether cryptexd has the asset mounted this second). A warning that fires every run is a warning nobody reads when it becomes true.
- **CLT SDK 27 no longer matches the CLT compiler (measured 10-14):** leave `SDKROOT` unpinned and even the *manifest* compile dies — `could not build Objective-C module 'SwiftShims'`, because `MacOSX.sdk` → 27.0 (swiftinterface built by swiftlang 6.4.0.31.4) while CLT's compiler is 6.4.0.34.1. clang also resolves its module cache to the real user home whatever `HOME` exports. The sandbox recipe that actually completes: `SDKROOT=<CLT SDK without CoreAI>` **plus** `CLANG_MODULE_CACHE_PATH=<writable>` (`swift package dump-package --disable-sandbox` → exit 0, verified).
- **Shader payload:** `Sources/ocoreai/Engine/MetalShaderLibrary.swift` resolves `default.metallib` down an ordered candidate ladder (SwiftPM's own freshly compiled bundle → Xcode DerivedData → pip wheel, last) and hands it to MLX through `MLX.GPU.metallib`; `$OCOREAI_METALLIB` overrides. Never stage it *into* a signed bundle — a `.metallib` under `Contents/MacOS` is a nested code object and CodeSign dies. Gate: `MetalShaderLibraryTests`, which pins the candidate order against a synthetic SwiftPM 6.4 layout, so the day the layout moves again is a red build.

**Linting:** none — aligned with upstream (mlx-swift-lm / coreai-models ship no swiftlint). swift-format via `.swift-format` (pinned 603.0.0) is the only style gate, enforced in CI and pre-commit. Crash-safe coding (no `try!`/`as!`/`fatalError` in Sources/) is a code convention, not a CI gate.

**Distribution licenses (CI-gated):** the artifact is MIT **plus** third-party code under its own terms; BSD-3 cl.1/cl.2 and Apache-2.0 §4 attach to the notice, so those texts travel with the binary. The invariant: **adding a dependency, bumping a pin, or vendoring a header ⇒ re-run `scripts/collect-third-party-licenses.sh` and commit its output** (the table records each pin — 10-16: the round-13 bump went red on `ThirdPartyNoticesTests` until it was re-collected); `scripts/bundle-licenses.sh <app>` copies `THIRD-PARTY-LICENSES/` into `Contents/Resources/` and re-reads it *from inside* the bundle. Two gates keep it true: `ThirdPartyNoticesTests` (needs no checkouts ⇒ runs on every CI leg; pins `Package.resolved` ↔ manifest set equality, with scan floors so a narrowed scan cannot pass vacuously) and `scripts/audit.swift_patterns.sh` **Class-I**. GUI: Settings → About → Third-Party Notices — absent texts are stated, never blank. Composition, the Apple-vs-`coreai-models` metric warning and the vendored-header table: `docs/agent/third-party-notices.md`.
<!-- claim:apple_derived_files>=44 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation). Every `@unchecked Sendable` declaration carries a justification comment.
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).
- **A continuation wrapped around an SDK callback needs a deadline, and the caller owns the callback object's lifetime.** `AVCapturePhotoOutput.capturePhoto(with:delegate:)` documents no retention of its delegate, so an inline temporary can leave nothing to call back — the continuation never resumes and the request hangs. Measured 10-15: `POST /v1/multimodal/capture {"type":"camera"}` parked ≥45 s *with the camera authorized*; retained delegate + exactly-once `fire()` + an 8 s deadline ⇒ a frame in 1.1 s. Without the deadline, "stalled" is indistinguishable from "still working".
- **A polling loop sleeps one poll interval, never the deadline.** `Task.sleep(until: deadline)` inside `while <still pending>` parks the waiter for the whole window regardless of when the condition clears. `EnginePool.waitForLoading` did exactly this (10-13: the first chat request cost 120 s for a model ready in 8 s; fixed to `min(deadline, now + 100 ms)`, release timing pinned by `EnginePoolLoadingGateTests`). Sleeping to the deadline is correct only in a single-shot watchdog — see `EngineInference.swift:149`.

### Compile-time gates
- **A `#if canImport(X)` must name the dependency the code inside actually uses.** Gating on a framework the block does not import silently deletes working code on every platform where that framework is missing. Concrete failure this rule comes from (10-12): `Tokenizer/TokenizerManager.swift` was gated `canImport(CoreAI)` while its only dependency is swift-transformers `Tokenizers` (unconditional product, `Package.swift:97`) — CoreAI is macOS 27 only, so on the macOS 26 delivery platform the real tokenizer was compiled out and a same-named no-op stub in `Models/InferenceStubs.swift` took its place (`registerTokenizer` = `{}`, `getTokenizer` = nil), while the log still claimed "context wall on real token counts".
- **A stub that replaces a real component must be detectable at runtime, not only at compile time.** `TokenizerManager.isRealTokenizerBackend` (true in the real actor, false in the stub) is the pattern: published on `/v1/capabilities` as `tokenizerBackend: real|heuristic`, it decides which wording the engine may log, and a test asserts it — so a silent substitution fails the gate instead of shipping.
- **Never gate a capability surface on a backend axis.** `canImport(CoreAI)` means "this SDK has CoreAI"; it says nothing about Metal, vision processors, or tokenizers. When a gate is about a capability, gate on that capability's real requirement.

### Wire DTOs
- **A field the spec calls optional must be Optional in the DTO** (or hand-decoded with `decodeIfPresent(…) ?? default`). The synthesized `Decodable` in this target requires every non-Optional key, so a default on a non-Optional property does not make the key optional on the wire. Concrete failure (10-13): `AnthropicMessageRequest.stream: Bool = false` still answered `400 Coding key `stream` not found.` for spec-legal clients, while `ChatCompletionRequest` survived only because it hand-decodes (`OpenAIModels.swift:240`). Pin every such field with a decode test that omits the key.
- **A field the spec calls polymorphic must decode every shape (and every block type) the spec names.** One shape typed in the DTO is a 400 for the clients that sent the other. Concrete failures (10-14): `AnthropicMessageRequest.system: String?` rejected `[{"type":"text","text":…}]` (the form Anthropic's own SDK emits once a system block carries `cache_control`), and `CountTokensRequest{model,prompt}` rejected `messages`/`input`, so the endpoint that exists to size a request was the one OpenAI/Anthropic clients could not call. Fixes: `AnthropicSystemContent` (string | text blocks) and a hand-decoded `CountTokensRequest` (`prompt` | `input` | `messages`, precedence `messages`→`input`→`prompt`), each pinned by a decode test that sends the shape which used to fail.

### Endpoint Promises
- **A hint that names a discovery route needs an index behind it, and the index must be checked against the router.** A 404 that says "enumerate endpoints via GET /v1/capabilities" while that payload has no endpoint list is a dead end dressed as guidance. `V1EndpointCatalog` is the list; `V1EndpointCatalogTests` scans `ChatCompletionsRouter.swift` for `routes.<method>("<path>")` and asserts set equality *plus* a floor on the scan's own hit count, so a regex that stopped matching cannot pass the equality vacuously. The `auth` column comes from `AuthRoutePolicy` (the sets `AuthMiddleware` enforces with), never from a hand-copied list.
- **A surface that documents where its input goes needs an executable delivery seam, a test that pins it, and a live probe that proves it.** A docstring describing delivery is not delivery. Concrete failure (10-13): `POST /v1/steer` promised "if no turn is live, the steer survives and merges into the NEXT request", but every `SteerQueue.drain` site sat inside a tool-dispatch loop (`EngineInference.swift:2908`/`:3514`) or the GUI composer flush (`ChatViewModel.swift:229`) — a wire client's steer on a no-tool turn reached neither the model nor the client. Fixed at the seam the contract names (`mergingSteeredTurn`, head of `chatCompletionsHandler`, `905492e`) + `SteerRequestHeadTests` + live probe (steer a code word, then ask for it). Ask of any accept-then-deliver surface: which line delivers this on the next request? If none, the contract is fiction.

### Error Handling
- Precondition near-free: production code uses precondition/preconditionFailure only for structural invariants and upstream-verbatim numeric/speech surfaces; new code must not add them. **Full-scan: 14 sites / 11 files** — the "12 sites / 9 files" ledger this file carried had silently gained `CoreAISequentialVLMEngine` and `CompositeSampler`; `make docs-check` re-measures it on every docs edit, which is the only reason a stale ledger can no longer survive:
  - Engine/GuidedGeneration — `XGrammarWrapper` ×2, `TokenizerInfo` ×1, `PipelinedConstrainedDecodingStrategy` ×1
  - Engine — `CoreAIStubs` ×2, `CoreAIPipelinedEngine` ×1, `CoreAISequentialVLMEngine` ×1, `CompositeSampler` ×1, `KVCache+CoreAI` ×1
  - Video — `DiscreteFlowScheduler` ×2, `TiledDecode3D` ×1
  - Multimodal — `StreamingWindow` ×1
<!-- claim:precondition_sites<=14 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:precondition_files<=11 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | cut -d: -f1 | sort -u | wc -l -->
- **Zero `try!`, `as!`, `fatalError`, `assert` outside comments.** Counted excluding comment lines: six `try!` occurrences are prose *inside* doc comments ("全 Safe API, 无 as!/try!"), so the naive grep is not the instrument.
<!-- claim:try_excl_comments<=0 :: git grep -n 'try!' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:fatalerror_as<=0 :: git grep -nE 'fatalError\(| as! ' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- **`print()` — 2 sites, both CLI/stdout product surface**, not debug logging: `Sources/ocoreai/UI/Application.swift:31` (`--version`/`--help` report) and `Sources/ocoreai/Headless/HeadlessServer.swift:141` (headless `serve` banner). Its old instrument was wrong too (`git grep 'print('` matches `fingerprint(`). Ceiling is 2 until the owner rules whether either belongs on the logger — then take it to 0.
<!-- claim:print_sites<=2 :: git grep -nE '(^|[^A-Za-z0-9_.])print\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- `try?`: used as the defensive-fallback pattern; `try?` stays acceptable where a real fallback follows.
- `ErrorContext.swift` does not exist (grep = 0).
- `Profiling/` contains **2 files**: `TimingHooks.swift` + `PerformanceMetrics.swift`.

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- TODO 计数 = **1**: `CoreAIInputEmbeddings.swift:36` (origin 系 `4517ca3` from coreai-models absorb)。原 3 → #206 后 `1bef69b`/`088a0b7` 各清 1（09-22 定版；10-14 起由 `make docs-check` 复测，不再靠手感）。
<!-- claim:todo_sites<=1 :: git grep -n TODO -- Sources | wc -l -->

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions.
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (Mirror + Integration — see table below).
- **A scan-based test asserts its own premises:** find the repo root by searching, never by fixed `deletingLastPathComponent()` hops (three "passing" assertions here were really ENOENT), and floor the scan's own hit count so a regex that stopped matching fails instead of passing vacuously. `V1EndpointCatalogTests` is the pattern.
- **Commit the probe.** Anything that proves behaviour against a live server ships as a script — cf. `scripts/proc-status-cache-probe.swift`, mlx-serve's `tests/test_*.sh` — so the claim outlives the session that made it.

---

### Open (currently unresolved — the only items worth prose)

- **`/v1/models/:model/…` 不收原样模型 id**（Handlers/）— `:model` 只匹配一段，而 `/v1/models` 发布的 id 是 `org/name`（两段）⇒ verbatim 一律 router-404；`%2F` 形态下 sampling 200，而 kv-cache 曾连 `%2F` 也 404——它漏了 router 里统一的 id 解析 choke，把编码串原样丢给 pool。已修：kv-cache 改走 `resolvedPathModelId`（四条 `:model` 路由同一个 choke），并在 `V1EndpointCatalog` 四条 note 写明须 percent-encode，探针 03 逐条 suffix 钉住可达性、探针 01 钉 kv-cache 真出数据。未决：是否直收带斜杠 id——Hummingbird `**` 会连 `/v1/models/download` 一起吞，代价是再造一层路由真值，留人拍板。

- **CoreAI 约束路的掩码常数**(`EngineInference.swift:1385`,**本机 macOS 26 不可运行验证**)— `_applyBitmask` 自己的文档写「disallowed tokens → -inf」,代码却是 `Float.leastNormalMagnitude * -1` ≈ −1.18e-38(加法掩码下几乎等于 0 ⇒ 等于没掩);且循环内 `guard tokenIdx < vocabSize, tokenIdx < logits.count else { return }` 会在首个越界索引处**整个函数返回**,跳过后续掩码字。唯一调用点在 `@available(macOS 27.0,*)` 的 `_runConstrainedDecoding`(L1080/L1223)。改法显然(`-Float.infinity` + `continue`),但在 macOS 27 上跑通前不臆修、不宣称已修。

- **iOS UI parity** (UI/) — 09-22 实证：工具层平台门控已核 = 正确（10 个 macOS-only：move/click/drag/scroll/type/key + inspect_ui(AX) + open/activate/list_apps(NSWorkspace)，均 macOS 平台语义）。10-13 落三处编译门，逐条以 iPhoneOS 27 SDK 一手证据核对（不凭印象）：`HSplitView` = `@available(iOS, unavailable)`；`navigationSubtitle` = `@available(iOS 26.0, macCatalyst 14.0, macOS 11.0, *)` 而 target 是 `.iOS(.v17)`；`UIPasteboard` 只有 `dataForPasteboardType:`（`UIPasteboard.h:79`；`dataForType:` 是 AppKit 拼法）。复扫排除的误报（`keyboardShortcut`/`.help`/`UTType`/`requestAccess` 均可用）见 CHANGELOG 10-13。仍开 = iOS **运行时**零验证（沙箱内 `xcodebuild` 起不来，编译面由 CI job `build-ios` 把关），MCP/Security on iOS TBD，ChatView/MultimodalControls 的 UI 门控仍需活验。
- **Reasoning `<thinking>` parse** (Engine/) — 字符串协议状态机（`ThinkTagParser`，0 处 regex，#206 后 15/15 绿），无 AST。
- **Hygiene — do not add new**: `precondition` (structural invariants + upstream-verbatim); scattered `try?` defensive fallbacks (~316 in Sources/); 2 bare `empty catch {}` in the EngineInference watchdog.
- **轮内即时转向需要 tool 调用**（Engine/）— 10-13 实证：`SteerQueue` 的轮内排空点只有 `EngineInference.swift:2908`（tool-result 尾巴）与 `:3514`（MTP 轮内）。上游 `ChatSession` 的标准生成循环**不暴露 message 注入缝** ⇒ 「一轮之内、无 tool 调用」时无法把转向语塞进正在生成的上下文。`905492e` 已把这类 steer 改为下一次请求头部并入（活体 `PARAPET`/`KESTREL` 实证）= **最坏延迟一轮，不再丢失**。要做到真·即时打断，需上游给 ChatSession 一个注入缝、或本地弃用 ChatSession 自建循环 —— 后者=重复造上游已有的会话层，留人拍板。
- **改历史的那一轮仍付全量（rewind 储备未接）**（Engine/）— 10-16 #700 落地后，只增长的会话已真正复用（探针 01: cached 710/730、733/749）。仍开的是**发散**会话：`SessionPool.canReusePooledSession` 在 `cachedHistory > commonPrefix` 时丢掉缓存重建（正确 —— 旧 KV 描述的是改前的会话），代价是 `RewindToCommonPrefixRule` 在我们这里永远轮不到。上游 #622 给了机制：`KVCacheConfiguration.rewind(maxTokens:)` 为旋转层保留额外历史行（成本 = 每层 `batch·kvHeads·maxTokens·(kDim+vDim)·bytes`，例 128 tok/8 头/64 维/16bit ≈ 256 KiB/层），`ChatSession` 按 `maxTrimCount` 先校验，旋转层不满足即 `incompatibleRewindCapacity` 抛错。**未接的理由**：无「用户改历史」的实测频次 ⇒ 默认吃这份内存就是未经测量的能力承诺。**测量已就位**：探针 01 第四轮（改写历史后重发）实测 **752 tok 全量重刷、`cached_tokens=0`** = 今天改一次历史的代价。
- **屏幕抓取起不来流（Multimodal/）** — 10-15 实测：`screenPermission=authorized` 且有显示器，`SCScreenshotManager.captureImage` 仍回 `无法开始流播放`；同机相机 1102ms 出帧 ⇒ 不是 TCC，是 SCStream 在无 GUI 会话起不了流。`screenStatus` 不再单凭授权判 `ready`：出过帧(`screenDelivery=captured`)才算，未试=unknown、失败=blocked 带原话；门=`ScreenDeliveryHonestyTests`+探针 04。未决：headless `serve` 能否抓屏。
- **Coverage report** — Tests/CoverageReport missing (no live data).

**Resolved items**: not restated here (the names live in `CHANGELOG.md`, and a list maintained in two places is a second truth that drifts).

---

### Upstream Audit Dependencies

**Five empirical sources** (the owner's first-principles reference set, reaffirmed 10-14). Round-by-round verdicts per upstream commit live in `CHANGELOG.md` (rounds 9–13) — one diary, one home; this section keeps only the current pin and the rules that transfer.
1. **mlx-swift-lm** — the pin in `Package.swift:41` (`revision:`) is the contract; `Package.swift` keeps pin + pointer, never a per-commit diary.
**Bump 协议**：`git log <old>..origin/main` 逐条审计消费面 → bump `.revision` → `swift build` + `make test-ci` 绿 → 逐轮裁决写进 `CHANGELOG.md`（唯一落点，不在本节重复），本节只留当前 pin 与可迁移规则；`Package.swift` 只留 pin + 指针。
   **Layout + mirror caveat (verified 10-14, re-walked 10-16 at `6e338e5`):** upstream moved its sources from `Sources/` to `Libraries/`, so `grep -r … Sources` against the clone returns nothing and reads as "API missing" (it cost a wasted audit round; `saveCache` is at `Libraries/MLXLMCommon/ChatSession.swift:1724`). Grep `Libraries/`. And this clone *is* the build source — `.swiftpm/configuration/mirrors.json` (gitignored), consulted per revision rather than per file — so reading the clone equals reading what we compile only while clone, pin and checkout agree, which on 10-14 they did not (all three differed; CHANGELOG same day). What actually holds is **pin is an ancestor of clone HEAD** (`git merge-base --is-ancestor`); pin + cleanliness of the checkout a binary was built from is asserted by `scripts/probes/_lib.sh`, not by prose.
2. **coreai-models** — Apple's reference tree, consumed here as the local `Engine/CoreAI*` derivation (BSD-3; types redefined locally to dodge the macOS 27 requirement). Python/export-side commits are consumer-transparent: ocoreai has no Python or export surface.
3. **codex** — semantic axis reference (Rust, not linked, nothing redistributed, no per-commit copying).
4. **Apple Developer Documentation** — **public, no login** (corrected 10-14; the old "requires login" note was an unverified carry-over that quietly cost us a primary source). Verified from this host the same day: `https://developer.apple.com/documentation/coreai` → HTTP 200, no redirect, and the DocC JSON is machine-readable at `https://developer.apple.com/tutorials/data/documentation/coreai.json` (19,684 bytes; title `Core AI`; abstract "Run AI models in your app on Apple silicon."; topicSections = Essentials / Inference / Multidimensional arrays / Configuration / Debugging and performance / Errors). Division of labour: DocC for intent and semantics, the SDK's `.swiftinterface` for exact signatures and `@available` gates, and **live execution** for behaviour — the CLT SDK has no CoreAI, so CLT-route builds compile every `canImport(CoreAI)` branch out and macOS 26 can never run them (SDK-level numbers: `docs/agent/build-gate-reality.md`). Fetch pattern: `curl -sS https://developer.apple.com/tutorials/data/documentation/<topic>.json`.

5. **Human Interface Guidelines** — <https://developer.apple.com/design/human-interface-guidelines>: the only one of the five that judges **the GUI itself** rather than the engine, so on anything user-visible HIG is the authority — not upstream codex. It is **not DocC**: the page returns HTTP 200 (17,663 B, verified 10-14) while every `/tutorials/data/documentation/design/human-interface-guidelines*.json` variant returns 404 ⇒ cite the specific section, there is no machine index to grep. What it judges here: ⌘ coverage + focus order, Settings hierarchy (`Cmd+,`, grouped), `textSelection` on anything readable, a11y labels, dark mode + Dynamic Type, destructive-confirmation wording, replying in the medium the user used. Measured thinness on this axis (grep, 10-14): `keyboardShortcut` in 3 files and `accessibilityLabel` in 15, across 264 Swift files — that gap is a HIG defect, whatever upstream does.
6. **Auxiliary references (owner-designated 10-15)** — vllm / vllm-metal / sglang / omlx / hermes-agent: serving/agent-loop comparators, not pins: nothing is linked or redistributed, and a verdict borrowed from one stays an inference until a file:line in our own build says otherwise.

**Mirror ≠ HEAD:** a clone under `~/references/` proves *content*, never HEAD — `api.github.com` is authoritative for HEAD and compare windows (the local clones lag the baselines here). A mirror *is* valid for byte-checking Apple's BSD-3 `LICENSE`, and that is what it is used for.
**Host-local ≠ project truth:** `~/wiki/concepts/*` (the upstream consumption matrices) lives outside this repo and is absent on some hosts, this one included — cite it as host-local colour, never as project evidence (§ Wiki).
<!-- claim:doc_pin_is_the_pin>=1 :: grep -c 'revision: "6e338e5df"' Package.swift -->

**Wiki:** `~/wiki/concepts/` — host-local (absent on this host today) per-pin consumption matrices; the verdicts that bind the repo are in `CHANGELOG.md`, not here.

---

## Read on demand — detail one hop away

- `docs/agent/build-gate-reality.md` — why the local gate is tiered: sandbox / Metal / metallib / module-cache / toolchain-bump forensics.
- `docs/agent/third-party-notices.md` — license composition, the `coreai-models` metric warning, the vendored-header table.
- `docs/agent/closed-items-log.md` — verdicts § Open used to carry prose for (resolved / retracted / phantom).
- `~/references/*`, `~/wiki/*` — host-local clones / notes; absent on some hosts (§ Upstream, § Wiki).

## Routing table — working in X → read this first

| Area | Read | Covers |
|---|---|---|
| `Sources/ocoreai/Engine/**` | `Sources/ocoreai/Engine/AGENTS.md` | backend gates, metallib, KV/prefix accounting, steer seam, constrained decoding |
| `Sources/ocoreai/UI/**` | `Sources/ocoreai/UI/AGENTS.md` | SwiftUI state authority, HIG duties, iOS-parity reality, focus discipline |
| `Sources/ocoreai/Handlers/**`, `Router/`, `Models/` | § Wire DTOs + § Endpoint Promises below | wire shapes, discovery contract |
| `Tests/**` | § Testing Quality below | exact-value assertions, scan floors, self-premise checks |
| this file, `docs/**` | `scripts/agents-md-contract.sh` (`make docs-check`) | budgets, dead pointers, claim reproduction |

Areas without a guide (Scheduler, MCP, Tools, Skills, Multimodal, Video, Security): start from § Code Conventions plus the code. When an area accumulates three dated notes, give it an `AGENTS.md` and a row here — a guide costs context only inside its subtree, which is the whole point.

## Docs Contract — how this file stays true

`make docs-check` (`scripts/agents-md-contract.sh`; CI: the `audit` job) asserts, sub-second and with no build:
**B1** root byte budget, shrink-only — adding text means removing text, and `make docs-budget` only ever lowers the cap · **B2** root + guide chain budget · **P1** the scan's own floors, so a regex that stopped matching fails loudly instead of passing vacuously · **P2** every file named here resolves — in this repo, by basename in git, in a local upstream clone, or is declared absent on the same line · **P3** every `file:line` anchor points at a line that exists · **P4** every `<!-- claim:id OP N :: command -->` runs and holds · **P5/P6** every `make` target and every test-suite name is real · **P7** every area guide on disk has a routing row.

A claim sits on the same line as its instrument, and the operator is part of the meaning: `>=` a floor that must not shrink, `<=` a ceiling that must not grow, `=` only for facts that move when this file is edited. Pinning equality to an inventory count is a churn generator — name the command instead. Long form: `CONTRIBUTING.md` → *The three questions*.

---

## Documentation Map — Agent-facing vs Human-facing

**Rule of thumb:** if the text is *injected into the model's context at runtime*, it is **Agent-facing** — changes alter model behaviour and require an inference regression. If it is read by people (humans or future agents) to understand the project, it is **Human-facing**.

| Doc | Audience | Why | When to touch |
|---|---|---|---|
| `AGENTS.md` (this file) | **Agent** (Codex, every session) | Injected as project context on cold start | Conventions / architecture facts drift — keep line-accurate |
| `Sources/ocoreai/Engine/AGENTS.md`, `Sources/ocoreai/UI/AGENTS.md` | **Agent** (auto-loaded inside that subtree) | area contracts: backend compile gates, metallib, KV/prefix accounting / GUI state authority + HIG duties + iOS-parity reality | a rule that only bites inside one subtree belongs there — that is what keeps this file short |
| `docs/agent/*.md` | **Human + Agent** (one hop away) | the long form this file used to carry: build-gate forensics, upstream audit log, license composition, closed items | when a verdict needs more than 3 lines, move it there and leave a pointer here |
| `Sources/ocoreai/Skills/SystemPromptBuilder.swift` | **Agent** (LLM context) | Builds the base + skills system prompt | Prompt-wording changes = behaviour changes — needs inference regression |
| `Sources/ocoreai/Tools/ToolEntry.swift` (+ `Tool*.swift`) | **Agent** (LLM context) | `description` / JSON schema are consumed by the model as function-calling contracts | schema/wording changes = tool-call behaviour — test with live model |
| `Sources/ocoreai/Parsers/*` (`ThinkTagParser` etc.) | **Agent** (implicit) | Defines what the model may emit (marker tags) | marker changes break both parse and parse-back — hexdump-verify parity with upstream |
| `README.md` / `README.zh.md` | **Human** | Entry point for humans | Feature surface changes |
| `CHANGELOG.md` | **Human** | Per-feature provenance, commit refs | Every user-visible change (see Workflow) |
| `CONTRIBUTING.md` | **Human** | How to contribute | Process / tooling changes |
| `ARCHITECTURE.md` | **Human** (historical) | Point-in-time architecture review (2026-07-26) | Do not edit — superseded by `AGENTS.md` + `CHANGELOG.md` |
| `SECURITY.md` | **Human** | Threat model + reporting | Trust-model / network-surface changes |
| ~~`docs/CONTEXT.md`~~ | — | v2 context from 2026-06-24; **removed from the repo at `11dd586`** and still cited by this map for weeks | do not cite |
| ~~`docs/precise-tasks.md`~~ | — | **never tracked**: `git log --all -- docs/` returns exactly one commit (`11dd586`, which deleted `CONTEXT.md`) — the map cited a file the repo never had | re-create deliberately, or leave the row struck |
| ~~`docs/prompt-ocoreai.md`~~ | — | the 自主推进协议 this file told agents to maintain **does not exist in git** (same check as above); its substance is now § Core Principles + § Rules that apply everywhere | restore it only as a real file, with its own gate |
| ~~`docs/plans/agent-os-dual-mode-architecture.md`~~ | — | never tracked; a plan that exists nowhere cannot gate anything | write it as a file or drop it |
| `CHECKPOINT.md` | **Agent (transient)** | Live-work checkpoint, overwritten each round | Not stable — do not cite as source of truth |
| `~~.status.md~~` | — | Tracked in git (listed in `.gitignore` L37 but committed earlier) — status snapshot | Do not cite — point-in-time |

**Agent-facing change discipline:**
1. Identify the behaviour that will change (tool schema / prompt wording / marker).
2. Add or extend a regression test (exact-value `#expect`, not `count > N`).
3. If it touches `SystemPromptBuilder` or `ToolEntry` description/schema: run `make test-ci` — the model-behaviour tests in `Tests/ocoreaiTests/` pin the contract.
4. **Never** change a marker literal (e.g. `think`) without hexdump-pairing it against the upstream reference (display layers strip angle brackets — see `ThinkTagParser` audit).

---

## Wiki / Knowledge Base

- **Location:** `~/wiki` (Obsidian vault) — **host-local, and absent on this host today** (`ls ~/wiki` → *No such file or directory*, 10-14). It is not in this repo, cannot be checked out on CI, and is therefore never project evidence: cite `CHANGELOG.md` + the code. `make docs-check` reports `~`-rooted refs separately from failures so the distinction is mechanical, not rhetorical.
- **Known issue:** Time-aging distortion — wiki pins HEAD but repo advances. Concept pages say "implemented" ≠ actually in Engine.
- **Verification:** `git merge-base --is-ancestor $wiki_head $real_head` + grep for file existence + symbol grep
- **Local scratch dir is not truth:** `.hermes/` is gitignored (`.gitignore` L29) and today holds only `.hermes/plans/2026-10-09_first-principles-roadmap.md`; there is **no** `.hermes/audits/` (10-12 `ls`). Untracked files cannot be shared project evidence — cite `CHANGELOG.md` + `~/wiki/concepts/*` instead, and treat that roadmap as historical wherever it conflicts with this file.

---

## Workflow

- **Direct commits to `main`** — no branch ritual; the CI gate (`make test-ci` equivalent on macos-26) is the authority, run green before push
- Every commit message: what changed + verification evidence (test count / command output)
- One logical change per commit
- `CHANGELOG.md` updated with every user-visible change (commit reference mandatory)
- Editing `AGENTS.md`, `docs/**` or an area guide ⇒ `make docs-check` green before push (sub-second, no build)

---

## Rules that apply everywhere

Distilled 10-14 from `~/references` (hermes-agent, mlx-serve, mlx-swift-lm, codex); each kept because it changes a decision here.

- **When this file and the code disagree, trust the code** — then fix whichever is wrong. Never break an invariant to make a change easier.
- **Before you call it a bug, verify the claim *and* the intent** (`git log -p -S "<symbol>"`). Isolation and absence are often the design, and this repo has produced three phantom findings (`kvCacheRuntimeReport`, MLXFoundationModels per-token, the `docs/*` rows above).
- **Footprint ladder — take the highest rung that solves it:** consume upstream → extend an existing seam → opt-in flag/trait → tool or skill → new module → new core or agent-facing surface. A new surface needs a consumer that exists today, not one imagined for tomorrow.
- **Decide state by authority, and put the scope in the key.** Engine actors own engine/model truth; `SessionManager` + SQLite own durable sessions; SwiftUI owns this window's presentation; a wire client owns its own view. Persisted keys declare their scope (global | session | model | window) — a wrong scope is how one session's setting bleeds into another.
- **Respect the person using it.** Never navigate, refocus, open a pane or announce because something *happened* in the background — offer, don't hijack. Empty / loading / reconnecting / degraded-stale / exhausted-recovery are five different experiences, each needing honest copy and a way out. On anything user-visible the HIG is the authority, not codex.
- **One resolver, one ladder.** Prefer an ordered candidate list — precedence as data, a candidate trusted only once probed, a failed *read* falling to the next rung, a failed *authoritative write* surfacing or rolling back, bounded retries that end in a recovery affordance — over an if-ladder of booleans. `MetalShaderLibrary` is the pattern.
- **Not a diary.** A root rule is ≤3 lines: what + the one-line evidence + the gate. Dates, round-by-round verdicts, measurements and host forensics go to `CHANGELOG.md` / `docs/agent/` next to the claim they came from — the same rule this file already imposes on `Package.swift`.
- **A cited artifact travels with the claim.** A probe, patch or log named in a doc must be committed, or the claim decays into faith in a deleted file — hence `scripts/probes/`.
- **Comments say the WHY the code cannot, in 1–3 lines.** No bug history, PR numbers, dates or audit trails inside source comments — that is the commit message. Upstream standard with a Good/Bad example: `~/references/mlx-swift-lm/AGENTS.md` → *Code standards*.
- **Diffs are read by a human. Keep them small.** One logical change per commit; grow `AGENTS.md` only by shrinking it (B1 of `make docs-check` is a ratchet, not a suggestion).
- **No new defensive clutter:** no wrapper or `try?` around code that cannot fail, no flag nobody sets, no capability wired before its consumer exists. `try?` needs a real fallback on the next line.

---

## Core Principles

1. **First-principles thinking:** Reason from goals + constraints, not from habit or template-matching. If the goal is ambiguous, stop and confirm before guessing; if the goal is clear but the path is suboptimal, propose the shorter, cheaper, more readable alternative directly.
2. **Precision:** Touch only what must be touched. Do not refactor code that isn't broken, do not improve adjacent comments/formatting without explicit permission.
3. **Terminology:** Use the vocabulary already in the repo. Before introducing a new symbol, grep for existing mechanisms first — avoid the "false-negative then reinvention" failure mode (e.g., seeing no `Compact*` and creating `InferenceCompactor` when `ConversationCompaction` + hooks already exist).
4. **Honesty:** Maximum truth-seeking, maximum curiosity, honesty — not human-preference alignment. Failure means reporting the failure accurately; never fabricate a success, never dress up a broken result as working.
5. **Simplicity:** Solve the problem with the minimum code; any extension must serve the stated question.

These complement — and are not replaced by — the existing Rule 3 (upstream alignment) / Rule 5 (citations) above.

## Agent Execution Rules

1. **Three-layer verification mandatory:** grep → compile verify → read matched lines. Single-layer check = speculation, not fact.
2. **Code changes require `swift build` verification.** exit code 0 = done.
3. **Never introduce `try!`, `as!`, `fatalError`, `assert`, `precondition`, or `print()` into production code.**
4. **Cross-actor calls must use `await` or `SerialAccess` pattern.**
5. **Audit conclusions must cite file:line + commit hash.** "Based on code evidence" vs "inference" must be explicit.
6. **Upstream API verification:** Before citing an API as available/missing, check all 3 upstream sources.
7. **All findings verified via tool output** — no speculation, no estimation.

## Agent Runtime Reality (Codex)

**Who works here:** the coding agent is **Codex** (CLI + desktop app), model family `gpt-6.x`, driving this repo through `exec_command` / `apply_patch` plus the MCP tools the harness lists. It is **not** Hermes and it is **not** served by Ollama. The id this section used to name (`qwen3.8:27b-mtp`) is `OCRE_SEARCH_MODEL` — ocoreai's opt-in web_search backend model (`Sources/ocoreai/Tools/WebSearchTool.swift:346`), reached only from `Sources/ocoreai/Tools/DirectWebSearch.swift:532`/`:540`, i.e. `OCRE_SEARCH_MODE=backend|auto`; the default `native` path (`:529`) needs no local server. It was never the model writing code — that conflation is why the old constraint read as platform physics when it was not.

**Skills:** the authoritative list is the one the runtime injects into its own system prompt. On disk, `~/.codex/skills/.system` = imagegen, openai-docs, review-agent, skill-creator, skill-installer (10-12 `ls`). All four names previously listed here — `single-pass-orchestration`, `code-review-discipline`, `hermes-agent`, `ocoreai-dev` — are **dead pointers**: `find` over `~/.codex` and this repo returns 0 hits (10-12; same class as the earlier `engineering-grilling` / `code-audit-methodology` cleanup). Nothing was lost by deleting them — their substance is already this file (Build / Test / Lint + Agent Execution Rules).

**Sub-agents:** Codex *can* fan out (`spawn_agent`, parallel tool calls). The default stays one-pass — intent → plan → implement → review → verify → commit inside a single response, and no sub-agent unless the owner asks. Two reasons survive the tooling change: the owner reviews every commit, so a fan-out nobody reads adds no assurance; and local verification is serialized regardless — `swift build` / `swift test` share one scratch path (`.build`, `.build-clt`), so parallel jobs contend a lock instead of saving time.

**Unchanged gate:** three-layer verification (grep → compile → read the matched lines), `swift build` exit 0 before any completion claim, `make test-ci` as CI authority, and a CHANGELOG ref for every user-visible change.

**Escalation review is broken on this host (10-13):** `approvals_reviewer = auto_review` asks the configured provider (`~/.codex/config.toml` → `model_provider = omlx`, `base_url = http://127.0.0.1:8000/v1`) for a model named `codex-auto-review`, which that server does not serve → `404 … Model 'codex-auto-review' not found`, and the escalated command never runs (two calls rejected this way; a review-service failure, not a safety verdict). Consequence for this repo: anything needing Metal or `xcodebuild` currently cannot be verified locally at all — use the sandboxed route above and leave the Metal-heavy full suite and the `xcodebuild` legs to CI. The fix is host config outside this repo (serve/alias that model on the provider, or repoint the reviewer): owner's call, not something to route around.

---

## Taste test before you hand off

- Does every piece of state live with its authority, at the narrowest scope that can still be right?
- Can any sentence a user can read promise more than the engine measured?
- Would a background event steal focus, navigate, or announce?
- Does each resolver/fallback have one home, a validated ladder, and a bounded, recoverable end?
- Does async failure leave a usable UI and a way forward?
- Do the numbers in this file still reproduce (`make docs-check`), and does every new claim carry a gate (policy 4)?
- Is the hot path still cheap under *realistic* content — long transcript, warm KV, a real model — not the empty demo?
- Did `swift build` exit 0, and does `CHANGELOG.md` name the commit?

If any answer is "not sure", that is the part to go verify.
