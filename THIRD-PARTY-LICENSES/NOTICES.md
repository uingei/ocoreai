# Third-party notices for ocoreai

ocoreai's own code is MIT (see LICENSE). This product additionally ships:

## 1. Apple-derived source (BSD-3-Clause)

- Verbatim license text: `Apple-coreai-models.txt`, byte-compared against upstream `apple/coreai-models`' `LICENSE` by `scripts/collect-third-party-licenses.sh` whenever that clone is reachable.
- 49 files under `Sources/` retain Apple's copyright notice together with its verbatim "BSD-3-clause ... can be found in the LICENSE file" header. Detection: `git grep -l "Copyright 2026 Apple Inc" -- Sources`.
- Of those, 35 name `coreai-models` in the header; the rest are Apple-authored files from other Apple trees (e.g. the XGrammar C bridge under `Sources/lib/CXGrammar/`), covered by the same BSD-3 text. `git grep -il coreai-models -- Sources` is deliberately NOT used as the count: 60 hits include files that only mention the reference repo in a comment.
- The repo root `LICENSE` is MIT and covers only ocoreai's own code; here the BSD-3 conditions live in `NOTICES.md` + `Apple-coreai-models.txt`, next to this file. In the shipped app the folder sits at `ocoreai.app/Contents/Resources/THIRD-PARTY-LICENSES/`, and the GUI renders it under Settings → About → Third-Party Notices.

## 2. Linked SwiftPM dependencies

| dependency | pin | license | text |
|---|---|---|---|
| async-http-client | 1.36.0 | Apache-2.0 | async-http-client.txt |
| eventsource | 1.4.2 | MIT | eventsource.txt |
| hummingbird | 2.26.0 | Apache-2.0 | hummingbird.txt |
| mlx-swift | 0.33.0 | MIT | mlx-swift.txt |
| mlx-swift-lm | rev f5b0677f6b52 | MIT | mlx-swift-lm.txt |
| swift-algorithms | 1.2.1 | Apache-2.0 | swift-algorithms.txt |
| swift-asn1 | 1.7.1 | Apache-2.0 | swift-asn1.txt |
| swift-async-algorithms | 1.1.5 | Apache-2.0 | swift-async-algorithms.txt |
| swift-atomics | 1.3.1 | Apache-2.0 | swift-atomics.txt |
| swift-certificates | 1.19.4 | Apache-2.0 | swift-certificates.txt |
| swift-collections | 1.6.0 | Apache-2.0 | swift-collections.txt |
| swift-configuration | 1.2.0 | Apache-2.0 | swift-configuration.txt |
| swift-crypto | 4.5.1 | Apache-2.0 | swift-crypto.txt |
| swift-distributed-tracing | 1.4.1 | Apache-2.0 | swift-distributed-tracing.txt |
| swift-http-structured-headers | 1.7.0 | Apache-2.0 | swift-http-structured-headers.txt |
| swift-http-types | 1.6.0 | Apache-2.0 | swift-http-types.txt |
| swift-huggingface | 0.9.0 | Apache-2.0 | swift-huggingface.txt |
| swift-jinja | 2.4.2 | Apache-2.0 | swift-jinja.txt |
| swift-log | 1.15.0 | Apache-2.0 | swift-log.txt |
| swift-metrics | 2.11.0 | Apache-2.0 | swift-metrics.txt |
| swift-nio | 2.101.3 | Apache-2.0 | swift-nio.txt |
| swift-nio-extras | 1.34.3 | Apache-2.0 | swift-nio-extras.txt |
| swift-nio-http2 | 1.45.0 | Apache-2.0 | swift-nio-http2.txt |
| swift-nio-ssl | 2.37.2 | Apache-2.0 | swift-nio-ssl.txt |
| swift-nio-transport-services | 1.28.0 | Apache-2.0 | swift-nio-transport-services.txt |
| swift-numerics | 1.1.1 | Apache-2.0 | swift-numerics.txt |
| swift-service-context | 1.3.0 | Apache-2.0 | swift-service-context.txt |
| swift-service-lifecycle | 2.11.0 | Apache-2.0 | swift-service-lifecycle.txt |
| swift-syntax | 603.0.2 | Apache-2.0 | swift-syntax.txt |
| swift-system | 1.8.0 | Apache-2.0 | swift-system.txt |
| swift-transformers | 1.3.3 | Apache-2.0 | swift-transformers.txt |
| xgrammar | 0.2.2 | Apache-2.0 | xgrammar.txt |
| yams | 5.4.0 | MIT | yams.txt |
| yyjson | 0.12.0 | MIT | yyjson.txt |

## 3. Vendored headers under `Sources/lib/`

- `Sources/lib/CXGrammar/include/dlpack/dlpack.h` — vendored from dmlc/dlpack (Copyright (c) 2017 by Contributors), Apache-2.0. Full text: `Vendored-dlpack-Apache-2.0.txt`.
- Rule: a copyright holder under `Sources/lib/` that is neither Apple nor the ocoreai author must be listed here, and the listed text file must exist. `scripts/audit.swift_patterns.sh` (Class-I) enforces it on every push.


## 4. openai/codex

- Not a dependency and not linked: codex is Rust. It is a **semantic** reference only; ocoreai contains behaviour equivalents, each cited in source comments (see `git grep -i codex -- Sources`). No codex source is redistributed, so no codex license text is bundled.

## 5. Apple frameworks (CoreAI etc.)

- System frameworks are linked at runtime by the OS and are not redistributed with this app; they are subject to Apple's platform terms.

