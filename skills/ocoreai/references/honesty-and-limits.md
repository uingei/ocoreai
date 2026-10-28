# Honesty fields, and what this build has not measured

The rule this project lives by: a surface never claims more than the engine delivered, and a claim is
worth exactly the gate that goes red when it breaks. Both halves matter to a caller — including the half
where the server refuses to over-state its own *gaps*.

## Where the truth is published

| field | served at | values | who measures it |
|---|---|---|---|
| `engineBackend` | `GET /v1/capabilities` | `mlx` \| `coreai` \| `scripted` | the backend that answered; `scripted` = replay fixture, nothing measured |
| `tokenizerBackend` / `tokenizer_backend` | `/v1/capabilities`, both count-token routes | `real` \| `heuristic` | the counter that produced the number |
| `reasoningEffort` | `/v1/models` rows | `honored` \| `template_ignores` \| `not_observed` | load-time render of the checkpoint's own template (`EnginePool.swift:237`) |
| `toolCallDelivery` | `/v1/models` rows | `parsed` \| `prose_only` \| `not_observed` | `ToolCallDeliveryLedger.swift:78-80` |
| `videoInput` | `/v1/models` rows | `delivered` \| `not_observed` | per checkpoint: `VideoDeliveryLedger.swift:68-69` |
| `screenStatus` | `/v1/perception`, `/v1/multimodal/status` | `ready` \| `blocked` + the framework's own words \| `unknown` before the first attempt | an actual capture attempt (`ScreenDeliveryHonestyTests`, probes 04/26) |
| `capabilities[].available` + `note` | `/v1/capabilities` | bool + reason | the build's traits and the OS it is running on |
| `endpoints[].auth` | `/v1/capabilities` | `public` \| key \| admin | the router and `AuthRoutePolicy`, checked by `V1EndpointCatalogTests` |
| `prompt_tokens_details` | chat/completion responses | present only when prefix reuse was measured | `PrefixReuseLedger.swift:59-65` |

`not_observed` is not an error and not a zero. It means: nobody measured this on this build with this
checkpoint — so do not upgrade it into "unsupported", and do not upgrade it into "supported" either.

## What is not measured here (say it, don't imply it)

- **iOS**: compile-validated only (`generic/platform=iOS` in CI). No iOS runtime has been executed by this
  project, so any iOS capability sentence is a declared floor from `Package.swift`, not a measurement.
- **macOS 14/15**: never executed on hardware; the suite and probes run on macOS 26.
- **CoreAI / macOS 27 items**: unverifiable on a host without that SDK (`PlatformPremise.hasMacOS27`); the
  CLT compile route compiles every `canImport(CoreAI)` block out.
- **Screen capture**: cannot stream headlessly; a frame must actually be delivered for `screenStatus` to
  claim anything.
- **Video**: published per checkpoint (`VideoDeliveryLedger`), never as a global capability.
- **Tool surface**: the task scoreboard exercises a subset of the advertised tools, so a score is not
  "every tool works"; `OCOREAI_EVAL_TOOLS=all` is the full-surface lane.
- **Task success itself**: one scoreboard run is a sample (k repeats, exact McNemar; the thresholds live
  in `scripts/eval/README.md`). A single green run is not a rate.

Every item above has its evidence sentence, owner and instrument in `docs/agent/open-items.md`; the
round-by-round verdicts are in `CHANGELOG.md`.
