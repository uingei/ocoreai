# Third-party notice composition

> The long form behind § *Build / Test / Lint* → "Distribution licenses" in `AGENTS.md`.
> Regenerate with `scripts/collect-third-party-licenses.sh`; texts live in
> `THIRD-PARTY-LICENSES/`, gated by `ThirdPartyNoticesTests` + `scripts/audit.swift_patterns.sh`
> (Class-I). Every count below is a `<!-- claim:… -->` marker that `make docs-check` re-runs,
> so none of them can rot silently (invariant 1).

**Distribution licenses (CI-gated, 10-14):** the artifact is MIT **plus** third-party code under its own terms, and BSD-3 cl.1/cl.2 / Apache-2.0 §4 attach to the notice, so those texts must travel with the binary. Composition (every number machine-checked below): Apple-derived = files carrying Apple's verbatim BSD-3 header, all 44 of them (29 name `coreai-models`, the rest
Apple-authored files from other Apple trees, e.g. the XGrammar C bridge); vendored headers under `Sources/lib/` = **1** (`dlpack.h`, dmlc/dlpack, Apache-2.0 — attribution lives in the collector's explicit `VENDORED` table, anything outside it fails); deps = **29 Apache-2.0 + 5 MIT**; codex = semantic reference only (Rust, not linked, nothing redistributed → no text ships).
Metric warning: grepping the *repo name* is not the derived count — 59 files under `Sources/` mention `coreai-models`, and only 29 of those carry an Apple copyright notice (the rest name the reference repo in a comment), while 15 BSD-3 files carry Apple's notice without naming coreai-models. Pipeline: `scripts/collect-third-party-licenses.sh` regenerates
`THIRD-PARTY-LICENSES/` (one text per dep + Apple BSD-3 + the dlpack Apache text + `NOTICES.md` + `manifest.json`; **exits 1** if a dep text is missing, no checkouts are present, or a vendored holder is unattributed; idempotent — re-running it on a clean tree changes nothing) → `scripts/bundle-licenses.sh <app>` copies it into `Contents/Resources/` and re-reads it *from
inside* the bundle → called by `scripts/build-app.sh`. **Adding a dependency, bumping a pin, or vendoring a header ⇒ re-run the collector and commit its output.** GUI surface: Settings → About → Third-Party Notices, backed by `Core/ThirdPartyNotices.swift`; when texts are absent the panel says so, it never renders blank.

**Provenance is part of the record now (schema 2, 10-20):** the manifest used to answer "there is an Apple BSD-3 text and one text per dependency" without saying *which upstream revision* the Apple text came from or *what bytes* we ship — for code whose license obligation is precisely "the notice travels with the binary". Discipline borrowed from harness²
(`~/references/harness2`: `third_party/*/PROVENANCE.md` per bundled tree, `dependencies/ASSETS.json` as a path→sha256 map, `scripts/check_provenance.py` exiting 1 on any changed or missing asset, `dependencies/PINNED.md` as the pin table; and it draws the line we had not drawn — release code we rewrote is *not* a vendored asset, so it does not belong in the checksum map):

- **`apple.pin` / `apple.licenseSha256` / `apple.verifiedAgainstPin`** — the upstream revision the shipped text was byte-compared against, plus the digest of the bytes actually in this folder. `pin` and `verifiedAgainstPin` are host-local facts: without the `~/references/coreai-models` clone the collector records `null` rather than guessing a SHA, and `false` means "checked,
and it did not match" — never "the check did not run".
- **`vendored[]`** — one row per third-party file that ships inside our source tree instead of as a SwiftPM dependency (`file` / `upstream` / `license` / `holder` / `textFile` / `sha256`). No package graph resolves these and no build log mentions them, so this record is the only thing stating that the file is not ours.
- **Absent ≠ empty (the 10-13 `stream` rule, mirror side)** — `ThirdPartyNoticesManifest` hand-decodes `vendored` with `decodeIfPresent(…) ?? []`, so a schema-1 manifest or an older bundle still loads, and a missing key never reads as "this build ships no vendored code".
- **GUI disclosure** — the About panel gained `ThirdPartyVendoredSection` (`UI/Views/ThirdPartyNoticesView.swift`, between the dependency and codex rows): path · license · sha256 prefix on the row, full upstream text behind the disclosure, localized in both delivered tables. An empty list renders nothing: that is the collector's measured "none", and Class-I refuses to ship
a manifest predating the field.
- **Gates** — `ThirdPartyNoticesTests` (16 tests, no checkouts needed ⇒ every CI leg) recomputes both digests with `CryptoKit` *from the bytes on disk* rather than reading the recorded value back, floors `vendored` at ≥1 so a collector that finds nothing cannot pass vacuously, pins the absent-key decode, and scans the view source so a deleted section goes red.
`scripts/audit.swift_patterns.sh` Class-I additionally asserts `schemaVersion ≥ 2`, the Apple digest, byte-identity with `git show <pin>:LICENSE` when the clone exists (loud SKIP when it does not) and every vendored row's digest/upstream/text file. Red sample (10-20): zeroing `vendored[0].sha256` in `THIRD-PARTY-LICENSES/manifest.json` made `make audit` exit 1 *and* `swift
test --filter ThirdPartyNotices` fail at `Tests/ocoreaiTests/ThirdPartyNoticesTests.swift:325` — the manifest is read at runtime, so both went red without a rebuild; restoring it returned both to green.
- **Not proven** — the panel has never been rendered by an automated run (no UI-test target), so "the user actually reads the dlpack Apache text in Settings" is an inference from the data + source gates, not a measurement; and the byte-identity-vs-upstream check currently runs only on a host holding the clone — CI prints SKIP for it, which is why `apple.pin` being non-null
in the committed manifest is asserted separately.

<!-- claim:tpn_apple_derived>=44 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:tpn_naming_coreai>=29 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | xargs git grep -l coreai-models | wc -l -->
<!-- claim:tpn_notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->
<!-- claim:tpn_schema=2 :: python3 -c "import json;print(json.load(open('THIRD-PARTY-LICENSES/manifest.json'))['schemaVersion'])" -->
<!-- claim:tpn_manifest_deps>=34 :: python3 -c "import json;print(len(json.load(open('THIRD-PARTY-LICENSES/manifest.json'))['dependencies']))" -->
<!-- claim:tpn_manifest_vendored>=1 :: python3 -c "import json;print(len(json.load(open('THIRD-PARTY-LICENSES/manifest.json'))['vendored']))" -->
<!-- claim:tpn_vendored_text_bundled>=1 :: ls THIRD-PARTY-LICENSES/Vendored-*.txt | wc -l -->
<!-- claim:tpn_gate_tests>=16 :: grep -c '@Test' Tests/ocoreaiTests/ThirdPartyNoticesTests.swift -->
