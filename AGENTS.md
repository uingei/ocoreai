# ocoreai — Project Context for AI Agents

> Loaded into the coding agent's context every session (Codex CLI + desktop): conventions, architecture, known issues — zero cold-start tax.
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
4. **An improvement answers three questions** — *what* behaviour improved, *what output* makes you think so (same-session command output; label inferences as inferences), and *which gate goes red* if it regresses. No answer to the third ⇒ it is a claim, not a change: record it as an open item plus the instrument that would settle it. Full text: `CONTRIBUTING.md` → "The three questions".

---

## Identity

**What it is:** an agent for open models, natively local — built for creativity, work, and code; a complete agentic system designed for coding and knowledge work. (canonical 09-27；variant = CHANGELOG 09-27) coding 最深切片 = Coding/Computer Agent (reliable Execute → Verify → Recover)；knowledge work / creativity (Apple 原生感知/多模态) = 一等产品面. Dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline. One binary.

**Tech stack:** Swift 6.2 · SwiftPM · Hummingbird 2.26 · SwiftUI · SQLite + FTS5

**Key modules:** subdirectories of `Sources/ocoreai/`; § Routing table names those with their own guide.

---

## Two invariants

Almost every rule below is a corollary of these two. When a shortcut and an invariant collide, the invariant wins.

1. **A claim is worth exactly the gate that goes red when it breaks.** A fix with no gate is a claim; a gate that infers its own premises from the environment rots the day the toolchain moves (SDK 26.5→27.0 flipped `canImport(CoreAI)`); a scan that stopped matching passes vacuously unless it floors its own hit count; and a doc whose numbers nobody re-greps drifts; an effect reported in a **value** not a code (a pragma's busy column) needs a gate reading it (10-20, SQLite); a comment naming a test suite is a claim about `Tests/` (`make audit` Class-J greps every one). Corollaries: policy 2 + 4, `make toolchain-check`, `V1EndpointCatalogTests`' floors, § Docs Contract.
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
- `EnginePool` uses inline `#if canImport(CoreAI)` branches (`BackendProtocol` deleted 2123143)
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (wired, both MLX + CoreAI paths), KVCacheRuntime ✅ (`.turboQuant`/`.affine` 双路 — 函数与行号见 § Upstream alignment). Pinned upstream `mlx-swift-lm` at `48114eedf` (逐条裁决 = CHANGELOG rounds 9–15)。 **ThinkingBudget** ✅ 两路皆接（std + MTP 各一对 `.applyingThinkingBudget` / `components:` 调用；四行 cite 由 `Engine/AGENTS.md` 的 anchor 门钉住，root 不手抄第二份地图）；MTP 仅 `guard mtpReasoningConfig` 非空才接，回退同 std。
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement. Engine/ contains CoreAI* + StateHandler + MPSGraphSamplers + KVCache/TensorStorage(+CoreAI); + Tokenizer/TokenizersMLXTokenizerAdapter.
- **ANE path:** CoreAI `MPSGraphSamplers` (`MPSGraphSamplers.swift` 实存, `CoreAIPipelinedEngine.swift:547/:874` 消费) wires MPS constrained argmax/composite/sampler — the GPU-based constrained decoding path
- **MTP path:** `_runInferenceWithMessages` → `generate(::mtpDrafter:)` — bypasses ChatSession, tool calls collected + dispatched per-iteration (aligned with upstream `MTPSpeculativeTokenIterator`)
- **SessionPool:** message-level *feed* dedupe. Whether the KV cache skipped a prefill is upstream's decision, reported only via `.info.cachedPromptTokenCount`; the engine logs it per turn (`EnginePool.accountPrefixReuse`) and publishes it per model (`prefixReuse` on `/v1/models/:model/kv-cache`). 复用已落地（逐轮数字 = CHANGELOG 10-16 + 探针 01）：省的是随历史增长那一项，每轮仍剩 ~80 ms 固定开销。改历史的 resend 与跨会话前缀两类代价已测成 `reuseRefusals`（§ Open）。HardwareRouter pressure events trigger aggressive eviction; `loadPromptCacheSnapshot` restores LM state + KV cache (disk identity/refusal semantics: CHANGELOG 10-13)

**Key:** `#if canImport(CoreAI)` single-layer compile-time gate; token sampling → `argmax`(greedy) / `multinomialSample`(temperature>0) — 真身 `Models/InferenceStubs.swift:207 sample(from:)`(temperature/topK/topP/minP filters, 对上游 CompositeSampler 算法).

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
swift test                               # full suite — runs on macOS 26 when unsandboxed (Metal needed); CI macos-26 is the authoritative gate
swift test --enable-code-coverage        # with coverage
swift test --filter SystemContextSensor  # one suite (substring match)
```

**Local gate reality:** the full suite **does** run on this host (`make test-clt`) — the blocker was the **agent sandbox**, and `serve` + live `curl` work locally: **prefer a live check over an inference
whenever a claim is about behaviour.**

**Gate tiering — the decision (the host forensics behind it: `docs/agent/build-gate-reality.md`).**
- **sandbox** → app-target build + non-Metal suites: `HOME=<canonical writable path> DEVELOPER_DIR=<CLT> SDKROOT=<SDK without CoreAI> swift build --scratch-path .build-clt --disable-sandbox`. `--disable-sandbox` drops only SwiftPM's own nested sandbox; the harness still denies the Darwin clang module cache, so `HOME` must move — canonical path only, SIGSEGV mechanism in `docs/agent/build-gate-reality.md`.
- **escalation** → `make test-clt` (full suite) + `make probes` (live `/v1/*`, `scripts/probes/`).
- **CI only** → the `xcodebuild` legs (`test-ci`, `build-ios`).
- `make toolchain-check` evaluates **both** candidate routes (Xcode and CLT) rather than the ambient `DEVELOPER_DIR`, and settles Metal by *compiling a kernel*, never by `metal --version` (whose answer tracks whether cryptexd has the asset mounted this second).
- **CLT SDK 27 ≠ CLT compiler:** leave `SDKROOT` unpinned and even the *manifest* dies (`SwiftShims`), and clang resolves its module cache to the real user home whatever `HOME` exports. Recipe that completes: `SDKROOT=<CLT SDK without CoreAI>` **plus** `CLANG_MODULE_CACHE_PATH=<writable>`.
- **Shader payload:** `Engine/MetalShaderLibrary.swift` resolves `default.metallib` down an ordered ladder (SwiftPM bundle → DerivedData → pip wheel; `$OCOREAI_METALLIB` overrides) and hands MLX `MLX.GPU.metallib`. Never stage it *into* a signed bundle — nested code object ⇒ CodeSign dies. Gate: `MetalShaderLibraryTests` pins the ladder order against a synthetic SwiftPM 6.4 layout.

**Linting:** none — aligned with upstream. swift-format via `.swift-format` (pinned 603.0.0) is the only style gate, enforced in CI and pre-commit. Crash-safe coding (no `try!`/`as!`/`fatalError` in Sources/) is a code convention, not a CI gate.

**Distribution licenses (CI-gated):** the artifact is MIT **plus** third-party code under its own terms
(BSD-3 cl.1/cl.2 + Apache-2.0 §4 make the notice travel with the binary). The invariant: **adding a dependency, bumping a pin, or vendoring a header ⇒ re-run
`scripts/collect-third-party-licenses.sh` and commit its output** (the table records each pin);
`scripts/bundle-licenses.sh <app>` copies `THIRD-PARTY-LICENSES/` into `Contents/Resources/` and
re-reads it *from inside* the bundle. Two gates: `ThirdPartyNoticesTests` (no checkouts needed ⇒
every CI leg; `Package.resolved` ↔ manifest set equality, with scan floors so a narrowed scan
cannot pass vacuously) + `scripts/audit.swift_patterns.sh` **Class-I**. GUI: Settings → About →
Third-Party Notices — absent texts are stated, never blank. Composition, the Apple-vs-`coreai-models`
metric warning, the vendored-header table and the re-collect discipline:
`docs/agent/third-party-notices.md`.
<!-- claim:apple_derived_files>=44 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation). Every `@unchecked Sendable` declaration carries a justification comment.
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- Closure `var` declared inside closure scope (not outer).
- **A continuation wrapped around an SDK callback needs a deadline, and the caller owns the callback object's lifetime.** `AVCapturePhotoOutput.capturePhoto(with:delegate:)` documents no retention of its delegate, so an inline temporary can leave nothing to call back — the continuation never resumes and the request hangs. Measured 10-15: `POST /v1/multimodal/capture` (camera, authorized) parked ≥45 s; retained delegate + exactly-once `fire()` + an 8 s deadline ⇒ a frame in 1.1 s. Without the deadline, "stalled" is indistinguishable from "still working".
- **A polling loop sleeps one poll interval, never the deadline.** `Task.sleep(until: deadline)` inside `while <still pending>` parks the waiter for the whole window regardless of when the condition clears. `EnginePool.waitForLoading` did exactly this (the first chat request cost 120 s for a model ready in 8 s; fixed to `min(deadline, now + 100 ms)`, release timing pinned by `EnginePoolLoadingGateTests`). Sleeping to the deadline is correct only in a single-shot watchdog — see `EngineInference.swift:149`.

### Compile-time gates
- **A `#if canImport(X)` must name the dependency the code inside actually uses.** Gating on a framework the block does not import silently deletes working code on every platform where that framework is missing. The failure this rule comes from (10-12): `Tokenizer/TokenizerManager.swift` was gated `canImport(CoreAI)` though its only dependency is swift-transformers `Tokenizers` (unconditional product, `Package.swift:99`) ⇒ on the macOS 26 delivery platform the real tokenizer compiled out and a no-op stub of the same name in `Models/InferenceStubs.swift` took its place, while the log still claimed "context wall on real token counts".
- **A stub that replaces a real component must be detectable at runtime, not only at compile time.** `TokenizerManager.isRealTokenizerBackend` (true in the real actor, false in the stub) is the pattern: published on `/v1/capabilities` as `tokenizerBackend: real|heuristic`, it decides which wording the engine may log, and a test asserts it — so a silent substitution fails the gate instead of shipping.
- **Never gate a capability surface on a backend axis.** `canImport(CoreAI)` means "this SDK has CoreAI"; it says nothing about Metal, vision processors, or tokenizers. When a gate is about a capability, gate on that capability's real requirement.

### Wire DTOs
- **A field the spec calls optional must be Optional in the DTO** (or hand-decoded with `decodeIfPresent(…) ?? default`). The synthesized `Decodable` in this target requires every non-Optional key, so a default on a non-Optional property does not make the key optional on the wire. Concrete failure (10-13): `AnthropicMessageRequest.stream: Bool = false` still answered `400 Coding key `stream` not found.` for spec-legal clients, while `ChatCompletionRequest` survived only because it hand-decodes (`OpenAIModels.swift:240`). Pin every such field with a decode test that omits the key.
- **init 的默认值不算线上可选**：`init(f: Bool = false)` 与 `var f: Bool = false` 同样让合成 `Decodable` 要求这个键（实测 10-20：`/v1/models/download` 对每个合法 body 答 `Coding key `useLatest` not found.`；同口径清出 6 结构体 16 键，细节=CHANGELOG 10-20(续19)）。门=`WireDTOOptionalityTests`(8)：- **No wire value may own the process.** A bounded numeric knob out of domain is a 400 naming field + range + value sent (`error.param`, vllm's shape) — never a trap. Measured 10-17: `{"max_tokens":-5}` reached `SchedulerActor.dispatch()` and SIGTRAP'd the box (narrative: CHANGELOG). Ranges live in one checker with per-wire bounds (`Models/SamplingDomain.swift`: OpenAI `temperature` 0–2 vs Anthropic 0–1; `top_k` 0 = disable, since `CompositeSampler` filters only when `>0`), and `Scheduler/KVCacheBudget.swift` floors the token→byte math so a caller bug costs a rounding, not the server. Gate: `RequestNumericDomainTests`(26) + probe 09 (refuse, then still serve a real turn).
- **兜底 schema 也是承诺**：`"properties":{}` =「任何键都不合法」⇒ schema-less `json_object` 曾答 `{}`（实测 2 vs 20 tokens）。一个家 `jsonObjectSchema`；门 `GrammarSchemaRegressionTests`+探针 12。

### Endpoint Promises
- **A hint that names a discovery route needs an index behind it, and the index must be checked against the router.** `V1EndpointCatalog` is the list; `V1EndpointCatalogTests` scans `ChatCompletionsRouter.swift` for `routes.<method>("<path>")` and asserts set equality *plus* a floor on the scan's own hit count, so a regex that stopped matching cannot pass vacuously; the `auth` column comes from `AuthRoutePolicy` (the sets `AuthMiddleware` enforces with), never a hand-copied list.
- **A capability row that names a mechanism must name where its delivery is measured, and the routing surface must degrade from that record.** `screenshot_capture: true` said "SCStream is linked" and read as "this box captures". `RuntimeCapability.lines` stays tier truth (prompt / `info` / Settings read that matrix), while `/v1/capabilities` publishes `RuntimeCapability.measured(_:)`: screen degrades on a measured failure (quoting the framework, not sticky), `video_input` carries the ledger aggregate. Gate: `CapabilityMeasurementHonestyTests`(16) + probe 03.
- **A surface that documents where its input goes needs an executable delivery seam, a test that pins it, and a live probe that proves it.** A docstring is not delivery: `POST /v1/steer` promised "merges into the NEXT request" while every `SteerQueue.drain` (`EngineInference.swift:3014`/`:3643`) sat inside a tool loop or the GUI flush — fixed at the seam the contract names (`mergingSteeredTurn`, head of `chatCompletionsHandler`, `905492e`) + `SteerRequestHeadTests` + probe. Ask of any accept-then-deliver surface: which line delivers this on the next request? If none, the contract is fiction.
- **兼容面必须复用主面的同一次组装、同一个 steer 缝，并吐出规范自己的判别符**（Handlers/Models）— `/v1/messages` 曾自建消息列表（同一请求 24 vs 774）、`delta.type` 填成事件名（SDK 按它分发 ⇒ 答对也读不出正文），而全套测试全绿（逐条伤=CHANGELOG 10-19(续2)）。现两面同走 `MessageBuilder.buildMessages`+`mergingSteeredTurn`+`persistConversation`（会话记忆也是同一缝：一面写一面不写 ⇒ `/sessions`、FTS、GUI 只看得见一条线；身份两面同口径 = `session_id`／`metadata.session_id`，缺席即无会话可长），各吐一行 `Assembled prompt [face]: … promptTokens=… declaredTools=…`。门=`AnthropicToolDeliveryTests`+`AnthropicThinkingAndToolChannelTests`(24)+`bothFacesReachTheHop`+探针 13、22。
- **A knob the wire accepts must reach the engine — behaviour ends, and the word is right.** Measured 10-18: penalties gated `> 0` while the pin applies each when merely non-zero (`Evaluate.swift:345/:355/:365`) ⇒ a negative `presence_penalty` ran a whole generation, ignored; `stop:["2"]` came back as the full answer with `finish_reason:"stop"` — the call sites `break`'d the `switch`, not the loop. One home per decision (`upstreamPenalty`, `EnginePool.firstStopOccurrence`), exit with a labeled break, and OpenAI's word for stop-string termination is `stop` (mapped inbound at `AnthropicModels.swift:1059`). Gate: `PenaltySignDeliveryTests` + `StopSequenceDeliveryTests` + probe 10.
- **A usage field carries the quantity its name claims; a breakdown cannot exceed its whole.** Upstream reports only what a turn prefilled (`GenerateCompletionInfo.promptTokenCount`) and keeps the reused prefix in `cachedPromptTokenCount`; publishing it let three warm turns answer `prompt_tokens` 30/44/54 with `cached_tokens: 949` — up to 31x its whole. `PromptTokenAccounting` adds the prefix back (= upstream `totalPromptTokenCount`) at all four sites on both faces, never where no cache was observed. Gate: `PromptTokenAccountingTests`(7) + probes 01/21.
- **A declared tool is written to the prompt once, and the checkpoint decides who writes it.** Measured 10-20: one tool cost +116 delivered `prompt_tokens` — ~51 from its template's `<|tool>…<tool|>` plus ~21 from our `## Tool:` block: the same declaration twice (vllm/sglang put the schema in the template and nowhere else). `ToolProseLedger` measures at load whether this model's template grows when handed a probe tool; Phase 5 writes prose only where it was measured *not* to render, and unmeasured keeps prose rather than silently un-declaring. Gate: `ToolProseLedgerTests`(15) + probe 16, 13 §11.
- **A per-turn knob must be refreshed where the object is reused, not only where it is parsed.** Measured 10-19: the turn after a grammar/tool turn spent the **previous** turn's `max_tokens` though its log said 8 at both hops — sampling lives on the upstream session (`ChatSession.swift:370 public var generateParameters`) and `SessionPool.acquire` returned pooled sessions untouched. One home: `acquire` refreshes and *names* the knobs (`staleSamplingFields`; cache fields stay upstream's rebuild). Gate: `PooledParameterDriftTests`(6) + probe 14 §7 (four measured shapes = CHANGELOG 10-20(续4)).
- **The caller's instructions have one delivery seam, and instruction identity gates cache reuse.** Measured 10-20: a ~1k-char `system` message at `messages[0]` moved the *delivered* `prompt_tokens` by **0** on the OpenAI face (its own disclosure still counted it) while `/v1/messages` delivered it — the engine reads instructions from the first `system` message and filters `system` out of the rendered feed. `splitInstructionMessages` hoists `system`/`developer` into that one channel pre-assembly; `canReusePooledSession` gained `instructionsMatch` (a pooled session renders the instructions it was *created* with), so the disk path's refusal is one rule with one home. Gate: `SystemInstructionDeliveryTests`(9) + `SessionIsolationTests` + probe 15; long form `docs/agent/instruction-channel.md`.
- **A tool turn makes three statements about itself, and all three have one home** (`Models/ToolCallWire.swift`) — parallelism: `parallel_tool_calls:false` and Anthropic's `disable_parallel_tool_use:true` narrow at the emit sites and keep the model's own first call (vllm `tool_calls_utils.py:24-43`); the terminal word: `tool_calls` belongs only to a turn that made a call **and** stopped by itself (`:47-65`; sglang `serving_chat.py:2149-2152`), so a budget-cut turn says `length` even when it delivered a call; the terminal chunk: only the last SSE chunk speaks, deltas carry `finish_reason: null`. Gate: `ToolCallWireContractTests`(19) + probe 14.

### Error Handling
- Precondition: production code uses precondition/preconditionFailure only for structural invariants and upstream-verbatim surfaces; new code must not add them. **Full-scan: 14 sites / 11 files**, re-measured by `make docs-check`:
  - 逐个位置 = 下面两条 claim 用的同一条 `git grep`，不在此手抄第二份地图。
<!-- claim:precondition_sites<=14 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:precondition_files<=11 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | cut -d: -f1 | sort -u | wc -l -->
- **Zero `try!`, `as!`, `fatalError`, `assert` outside comments.** Counted excluding comment lines: six `try!` occurrences are prose *inside* doc comments ("全 Safe API, 无 as!/try!"), so the naive grep is not the instrument.
<!-- claim:try_excl_comments<=0 :: git grep -n 'try!' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:fatalerror_as<=0 :: git grep -nE 'fatalError\(| as! ' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- **`print()` — 2 sites, both CLI/stdout product surface**, not debug logging: `Sources/ocoreai/UI/Application.swift:38` (`--version`/`--help` report) and `Sources/ocoreai/Headless/HeadlessServer.swift:141` (headless `serve` banner); bare `print(` would match `fingerprint(`. Ceiling 2 until the owner rules whether either belongs on the logger; then 0.
<!-- claim:print_sites<=2 :: git grep -nE '(^|[^A-Za-z0-9_.])print\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- `try?`: acceptable where a real fallback follows.

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- TODO 计数 = **1**: `CoreAIInputEmbeddings.swift:36` (`4517ca3`, coreai-models absorb); re-measured below.
<!-- claim:todo_sites<=1 :: git grep -n TODO -- Sources | wc -l -->

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions.
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker / AdmissionGate (partial gaps), HardwareRouter (Mirror + Integration).
- **A scan-based test asserts its own premises:** find the repo root by searching, never by fixed `deletingLastPathComponent()` hops, and floor the scan's own hit count so a regex that stopped matching fails (`V1EndpointCatalogTests`).
- **A fix gates every consumer of the value it changed** — an emit-site pin left `/metrics` and the persisted row on the fixed wire's suffix; gate the hops, not the emit site.
- **Commit the probe.** Anything proving behaviour against a live server ships as a script (`scripts/proc-status-cache-probe.swift`) so the claim outlives its session.

---

- **`/v1/models/:model/…` 不收原样模型 id**（Handlers/）— `:model` 只匹配一段而 `/v1/models` 发布 `org/name`（两段）⇒ verbatim 一律 router-404，须 `%2F`。四条 `:model` 路由已统一走 `resolvedPathModelId`，catalog note 写明须 percent-encode（探针 03/01）。未决：直收带斜杠 id 会让 Hummingbird `**` 连 `/v1/models/download` 一块吞，代价是再造一层路由真值，留人拍板。

- **CoreAI 路上两处「改法显然、本机验不了」**（Engine/）— ① `_applyBitmask`(`EngineInference.swift:1374`) 掩的不是 -inf，越界即 `return` 跳过后续掩码；② fp8→`.float16` 停在 coreai-models #328 修前(`KVCache+CoreAI.swift:618`，fp8 全仓仅此表)。两处皆 `@available(macOS 27.0,*)` ⇒ 本机验不了：不臆修、不宣称已修（①`docs/agent/build-gate-reality.md` ②续17）。

- **iOS UI parity** (UI/) — 工具层平台门控与三处 SwiftUI 编译门已逐条对 iPhoneOS 27 SDK 核过（名单/行号/判据 = CHANGELOG 10-13）。仍开 = iOS **运行时**零验证（编译面 = CI job `build-ios`），MCP/Security on iOS TBD，ChatView/MultimodalControls 仍需活验。
- **Hygiene — do not add new**: `precondition` (structural invariants + upstream-verbatim); scattered `try?` defensive fallbacks (~316); 2 bare `empty catch {}` in the EngineInference watchdog.
- **无 tool 的一轮打不断**（Engine/）— 排空点只有 `EngineInference.swift:3014`（tool-result 尾巴）与 `:3643`（MTP）；**有 tool 的一轮已实测可当场打断**（探针 21：`sleep` 被要求 8000 ms，注入落在 1.5 s，该轮 2651 ms 结束并同轮带回 `[mid-turn user steering]`；另一会话的注入叫不醒它）。剩的那半格 = 上游 `ChatSession` 标准循环不给注入缝，自建会话层 = 重造上游已有之物，留人拍板（`905492e` 已把「丢失」改成「最坏延迟一轮」）。
- **改历史的那一轮仍付全量（rewind 储备未接）**（Engine/）— 只增长的会话已复用（#700）；**发散**会话仍被 `canReusePooledSession` 丢缓存重建（正确：旧 KV 描述改前的会话），代价 = `RewindToCommonPrefixRule` 轮不到；机制上游 #622 已给（`KVCacheConfiguration.rewind(maxTokens:)`）；两类代价自 10-21 起在 `reuseRefusals` 里计数公布，接不接仍待样本。
- **视频公布还差一头（Multimodal/）** — 视频是 per-checkpoint 事实（`Gemma4Processor` 读 `input.videos`、`Gemma4UnifiedProcessor` 不读），不许按架构推断；公布按实测（§ Endpoint Promises）。未决 = 交了帧却一个字没答的轮次不记 video（`delivered` = 收帧且答出，见 `VideoDeliveryLedger.swift` 头部），放宽未测。
- **屏幕抓取起不来流（Multimodal/）** — 授权且有显示器，`SCScreenshotManager.captureImage` 仍回 `无法开始流播放`；同机相机能出帧 ⇒ 不是 TCC，是 SCStream 在无 GUI 会话起不了流。`screenStatus` 只在出过帧时才 `ready`（未试=unknown、失败=blocked；门=`ScreenDeliveryHonestyTests`+探针 04）。未决：headless `serve` 能否抓屏。
- **`tools[]` 的真相集是声明；强制只跟需求，只许一个家**（Handlers/Engine/Client）— 声明即投喂面（本地名装 `toolDispatch`，余者交回 `tool_calls`）；grammar 只跟 `tool_choice`/JSON `response_format` 的需求、绝不跟「有没有声明」，判断唯一落 `shouldConstrainOutput`（`Models/OpenAIModels.swift`），`InferenceOptions` 三个组装面同调（历史=CHANGELOG 10-18(续4)+10-19(续)(续2)）；公布按实测（`ToolCallDeliveryLedger`，unload 归零）。门=`ToolDeclarationSurfaceTests`＋探针 11 §7。未决：GUI 端到端零验证（不经 HTTP ⇒ 只有静态门）；`required` 强制力受 checkpoint 限制。

**Resolved items** 不在此重述（名字在 `CHANGELOG.md`——两处维护必漂）。

---

### Upstream Audit Dependencies

**Five empirical sources** (the owner's first-principles reference set, reaffirmed 10-14). Round-by-round verdicts per upstream commit live in `CHANGELOG.md` (rounds 9–13) — one diary, one home; this section keeps only the current pin and the rules that transfer.
1. **mlx-swift-lm** — the pin in `Package.swift:43` (`revision:`) is the contract; `Package.swift` keeps pin + pointer, never a per-commit diary.
**Bump 协议**：`git log <old>..origin/main` 逐条审计消费面 → bump `.revision` → `swift build` + `make test-ci` 绿 → 逐轮裁决写进 `CHANGELOG.md`（唯一落点，不在本节重复），本节只留当前 pin 与可迁移规则。
   **Layout + mirror caveat (10-14, re-walked 10-16):** upstream moved its sources `Sources/` → `Libraries/`, so `grep -r … Sources` against the clone returns nothing and reads as "API missing" (`saveCache` is at `Libraries/MLXLMCommon/ChatSession.swift:1724`) — grep `Libraries/`. And this clone *is* the build source: `.swiftpm/configuration/mirrors.json` (gitignored) is consulted per revision, so reading the clone equals reading what we compile only while clone, pin and checkout agree (10-14: all three differed). What holds is **pin is an ancestor of clone HEAD** (`git merge-base --is-ancestor`); pin + checkout cleanliness of the built binary is asserted by `scripts/probes/_lib.sh`, not by prose.
2. **coreai-models** — Apple's reference tree, consumed here as the local `Engine/CoreAI*` derivation (BSD-3; types redefined locally to dodge the macOS 27 requirement). Python/export-side commits are consumer-transparent: ocoreai has no Python or export surface.
3. **codex** — semantic axis reference (Rust, not linked, nothing redistributed, no per-commit copying).
4. **Apple Developer Documentation** — **public, no login** (corrected 10-14：旧「requires login」未经核实；forensics = CHANGELOG 10-14). Division of labour: DocC for intent and semantics, the SDK's `.swiftinterface` for exact signatures and `@available` gates, and **live execution** for behaviour — the CLT SDK has no CoreAI, so CLT-route builds compile every `canImport(CoreAI)` branch out and macOS 26 can never run them (SDK-level numbers: `docs/agent/build-gate-reality.md`). Fetch pattern: the same `/tutorials/data/documentation/` path with `<topic>` swapped.

5. **Human Interface Guidelines** — <https://developer.apple.com/design/human-interface-guidelines>: the only one of the five that judges **the GUI itself** rather than the engine, so on anything user-visible HIG is the authority — not upstream codex. It is **not DocC** (its `.json` variants 404) ⇒ cite the section; no machine index to grep. What it judges here: ⌘ coverage + focus order, Settings hierarchy, `textSelection` on anything readable, a11y labels, dark mode + Dynamic Type, destructive-confirmation wording, replying in the medium the user used — counts move, so re-grep before quoting one.
6. **Auxiliary references (owner-designated 10-15, extended 10-20)** — vllm / sglang (the OpenAI/Anthropic compat benchmark) + vllm-metal / omlx / mlx-serve / MTPLX / ollama / TensorFold / Strata / hermes-agent / deepseek-harness / harness2: serving, MTP, packaging and agent-loop comparators, not pins — nothing linked or redistributed, and a borrowed verdict stays an inference until a file:line in our build says otherwise. Per-repo strengths: `docs/agent/comparator-repos.md` (all 12 present on this host, 10-20).

**Mirror ≠ HEAD:** a clone under `~/references/` proves *content*, never HEAD — `api.github.com` is authoritative for HEAD and compare windows (the local clones lag). A mirror *is* valid for byte-checking Apple's BSD-3 `LICENSE`.
**Host-local ≠ project truth:** anything outside this repo (e.g. `~/wiki/…`, absent on this host) is host colour, never project evidence; verdicts binding the repo live in `CHANGELOG.md`.
<!-- claim:doc_pin_is_the_pin>=1 :: grep -c 'revision: "48114eedf"' Package.swift -->


---

## Read on demand — detail one hop away

- `docs/agent/build-gate-reality.md` — why the local gate is tiered: sandbox / Metal / metallib / module-cache / toolchain-bump forensics.
- `docs/agent/third-party-notices.md` — license composition, the `coreai-models` metric warning, the vendored-header table.
- `docs/agent/closed-items-log.md` — verdicts § Open used to carry prose for (resolved / retracted / phantom).
- `docs/agent/instruction-channel.md` — who delivers the caller's `system`/`developer` text, and what refusing to reuse its cache costs.
- `docs/agent/systemone-decisions.md` — upstream's Jev / System 1 decision API (`/v1/systemone`, `/v1/decisions`), what we already have, and the price of the cheapest honest slice.
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
**B1** root byte budget, shrink-only — adding text means removing text, and `make docs-budget` only ever lowers the cap · **B2** root + guide chain budget · **P1** the scan's own floors, so a regex that stopped matching fails loudly instead of passing vacuously · **P2** every file named here resolves — in this repo, by basename in git, in a local upstream clone, or is declared absent on the same line · **P3** every `file:line` anchor points at a line that exists · **P4** every `<!-- claim:id OP N :: command -->` runs and holds · **P5/P6** every `make` target and every test-suite name is real · **P7** every area guide on disk has a routing row · **P9** routing targets are tracked, not merely present · **P10** the READMEs' endpoint table + public-route list equal the router and `AuthRoutePolicy` (both READMEs are in this scan).

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
| `README.md` / `README.zh.md` | **Human** | Entry point for humans | Feature surface changes — P10 diffs the endpoint table + public-route list against router/middleware, so a stale row is a red gate, not a missed read |
| `CHANGELOG.md` | **Human** | Per-feature provenance, commit refs | Every user-visible change (see Workflow) |
| `CONTRIBUTING.md` | **Human** | How to contribute | Process / tooling changes |
| `ARCHITECTURE.md` | **Human** (historical) | Point-in-time architecture review (2026-07-26) | Do not edit — superseded by `AGENTS.md` + `CHANGELOG.md` |
| `SECURITY.md` | **Human** | Threat model + reporting | Trust-model / network-surface changes |
| ~~`docs/CONTEXT.md`~~ | — | v2 context from 2026-06-24; **removed at `11dd586`** yet still cited by this map for weeks | do not cite |
| ~~`docs/precise-tasks.md`~~ | — | **never tracked**: `git log --all -- docs/` returns one commit (`11dd586`, which deleted `CONTEXT.md`) — the map cited a file the repo never had | re-create deliberately, or leave the row struck |
| ~~`docs/prompt-ocoreai.md`~~ | — | the 自主推进协议 this file told agents to maintain **does not exist in git** (same check as above); substance now lives in § Core Principles + § Rules that apply everywhere | restore only as a real file, with its own gate |
| ~~`docs/plans/agent-os-dual-mode-architecture.md`~~ | — | never tracked; a plan that exists nowhere cannot gate anything | write it or drop the row |
| `CHECKPOINT.md` | **Agent (transient)** | Live-work checkpoint, overwritten each round | Not stable — do not cite as source of truth |
| `~~.status.md~~` | — | tracked in git (listed `.gitignore` L37 but committed earlier) — status snapshot | do not cite, point-in-time |

**Agent-facing change discipline:**
1. Identify the behaviour that will change (tool schema / prompt wording / marker).
2. Add or extend a regression test (exact-value `#expect`, not `count > N`).
3. If it touches `SystemPromptBuilder` or `ToolEntry` description/schema: run `make test-ci` — the model-behaviour tests in `Tests/ocoreaiTests/` pin the contract.
4. **Never** change a marker literal (e.g. `think`) without hexdump-pairing it against the upstream reference (display layers strip angle brackets — see `ThinkTagParser` audit).

---

## Wiki / Knowledge Base

- **Location:** `~/wiki` (Obsidian vault) — **host-local, absent here** (`ls ~/wiki` → *No such file*, 10-14): not in this repo, not on CI ⇒ never project evidence — cite `CHANGELOG.md` + the code. `make docs-check` reports `~`-rooted refs apart from failures (mechanical, not rhetorical); until 10-20 `README.md` sourced a test count from this vault.
- **Known issue:** time-aging — the wiki pins HEAD while the repo advances; "implemented" on a concept page ≠ in Engine. Verify with `git merge-base --is-ancestor $wiki_head $real_head` + file/symbol greps
- **Local scratch dir is not truth:** `.hermes/` is gitignored (`.gitignore` L29), holds only `.hermes/plans/2026-10-09_first-principles-roadmap.md`, and has **no** `.hermes/audits/`. Untracked files are not shareable evidence — cite `CHANGELOG.md` + `~/wiki/concepts/*`, and treat that roadmap as historical where it conflicts with this file.

---

## Workflow

- **Direct commits to `main`** — no branch ritual; the macos-26 CI gate (`make test-ci`) is the authority, run green before push
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
- **A file's lifetime is the lifetime of the thing that cites it.** When a transcript or handle outlives the request that wrote the file, deleting at request end makes the *next* use an unreadable-path error, far from its cause and blaming the service. Such bytes need an owner (the session citing them), a pin (the request in flight), and collection by idle TTL + byte budget only. `MediaSpool`; gates: `MediaLifetimeTests` + probe 08.
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

**Who works here:** the coding agent is **Codex** (CLI + desktop app), model family `gpt-6.x`, driving this repo through `exec_command` / `apply_patch` plus the MCP tools the harness lists. It is **not** Hermes and it is **not** served by Ollama. The id this section used to name (`qwen3.8:27b-mtp`) is `OCRE_SEARCH_MODEL` — ocoreai's opt-in web_search backend model (`Sources/ocoreai/Tools/WebSearchTool.swift:346`), reached only from `Sources/ocoreai/Tools/DirectWebSearch.swift:532`/`:540`, i.e. `OCRE_SEARCH_MODE=backend|auto`; the default `native` path (`:529`) needs no local server.

**Skills:** the authoritative list is the one the runtime injects into its own system prompt. On disk, `~/.codex/skills/.system` = imagegen, openai-docs, review-agent, skill-creator, skill-installer. All four names previously listed here — `single-pass-orchestration`, `code-review-discipline`, `hermes-agent`, `ocoreai-dev` — are **dead pointers**: `find` over `~/.codex` and this repo returns 0 hits (10-12; same class as the earlier `engineering-grilling` / `code-audit-methodology` cleanup). Nothing was lost by deleting them — their substance is already this file (Build / Test / Lint + Agent Execution Rules).

**Sub-agents:** Codex *can* fan out (`spawn_agent`, parallel tool calls). The default stays one-pass — intent → plan → implement → review → verify → commit inside a single response, and no sub-agent unless the owner asks. Two reasons survive the tooling change: the owner reviews every commit, so a fan-out nobody reads adds no assurance; and local verification is serialized regardless — `swift build` / `swift test` share one scratch path (`.build`, `.build-clt`), so parallel jobs contend a lock instead of saving time.

**Unchanged gate:** three-layer verification (grep → compile → read the matched lines), `swift build` exit 0 before any completion claim, `make test-ci` as CI authority, and a CHANGELOG ref for every user-visible change.

**Escalation review was broken on this host (10-13), and is not blocking as of 10-18:** `approvals_reviewer = auto_review` asked the configured provider (`~/.codex/config.toml` → `model_provider = omlx`) for a model `codex-auto-review` that server does not serve → `404 … Model 'codex-auto-review' not found`, so the escalated command never ran (a review-service failure, not a safety verdict). This round escalated `make test-clt` and the live probes successfully, so the Metal-heavy gates run locally again; the reviewer model itself is host config outside this repo (owner's call).

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
