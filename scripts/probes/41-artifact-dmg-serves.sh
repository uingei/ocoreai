#!/usr/bin/env bash
# 41-artifact-dmg-serves.sh — does the .dmg a stranger downloads actually serve?
#
# ### Why this probe exists
# Every other live probe here boots a binary that lives under `.build`, so they judge the WORKING
# TREE. Nobody judged the artefact: the bundle a person drags into Applications is assembled by
# `scripts/build-app.sh` (binary + metallib + Info.plist + icon), wrapped by `build-dmg.sh`,
# ad-hoc signed, then mounted — four steps between "the tree serves" and "the DMG serves". The
# release leg that ships those steps has died on two of them (metallib 09-27, artefact upload
# v0.1.12 ×2) and has never produced a release: `git ls-remote --tags origin` is empty and
# `/releases` is `[]` (measured 10-29). AGENTS.md invariant 2 says the surface may not claim more
# than the engine delivered — this is the same rule applied to the shipping medium.
#
# ### What is asserted (§ in order)
#   §0 premise — the tree that BUILT the artefact is at the pin and clean. A mounted volume sits
#      outside any scratch, so `probe_scratch_for_binary` cannot name it: the builder's scratch is
#      therefore named by hand here rather than excused as "not verifiable".
#   §1 the bundle's own facts — the executable bit, the drag-target /Applications symlink, the
#      shader payload *inside* the bundle (the 09-27 failure, judged where it ships), a signature
#      that verifies, and the version string the artefact reports.
#   §2 it serves — boot the binary from inside the mounted, read-only volume: /health answers with
#      nothing resident, the handlers answer on /v1/models, and the log carries no metallib failure.
#   §3 it stops — SIGTERM drains to exit 0 with the completion line, so a harness that pipes the
#      daemon gets an orderly end rather than a killed process.
#
# ### Premise, and what happens without it
# The artefact is the input: `$OCOREAI_ARTIFACT_DMG`, else the newest `dist/ocoreai-*.dmg`. No
# artefact is a red with the remedy, not a skip — a probe that reports success because its subject
# was absent is the vacuous-pass family this suite was built to refuse. `$OCOREAI_ARTIFACT_VERSION`
# pins §1's version verdict; without it the number is printed, not judged (an off-pin check stays
# advisory). Owned by `.github/workflows/package.yml`; `make probes` on a host with no DMG built
# has every right to go red here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="artifact-dmg-serves"

DMG="${OCOREAI_ARTIFACT_DMG:-}"
if [ -z "$DMG" ]; then
  DMG="$(ls -t "$PROBE_REPO_ROOT"/dist/ocoreai-*.dmg 2>/dev/null | head -1 || true)"
fi
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "FAIL  no artefact to judge (OCOREAI_ARTIFACT_DMG unset, no dist/ocoreai-*.dmg)"
  echo "      remedy: bash scripts/build-dmg.sh   (or run this probe from the packaging lane:"
  echo "      .github/workflows/package.yml, which builds it on a clean runner)"
  exit 1
fi

BYTES="$(wc -c < "$DMG" | tr -d ' ')"
probe_require_int "artifact bytes" "$BYTES"
probe_note "artefact $DMG · $BYTES bytes"

MNT="$(mktemp -d -t ocoreai-dmgmnt-XXXXXX)/mnt"
mkdir -p "$MNT"
if ! hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" > /dev/null 2>&1; then
  echo "FAIL  hdiutil cannot mount the artefact — nobody else can open it either"
  exit 1
fi
probe_atexit "hdiutil detach '$MNT' -force > /dev/null 2>&1 || true; rm -rf '$(dirname "$MNT")'"
probe_ok "the artefact mounts read-only"

APP="$MNT/ocoreai.app"
BIN="$APP/Contents/MacOS/ocoreai"
METAL="$APP/Contents/MacOS/mlx.metallib"

# ── §0 the tree that built this artefact ──────────────────────────────────────────────────────
probe_section "§0 the builder's tree (a mounted volume names no scratch)"
probe_require_clean_dependency_checkout "$PROBE_REPO_ROOT/.build"

# ── §1 the bundle's own facts ─────────────────────────────────────────────────────────────────
probe_section "§1 what is inside the volume"
if [ -x "$BIN" ]; then
  probe_ok "Contents/MacOS/ocoreai is present and executable"
else
  probe_fail "Contents/MacOS/ocoreai missing or not executable — the volume opens and installs nothing"
fi
if [ -L "$MNT/Applications" ]; then
  probe_ok "the drag target (/Applications alias) is in the volume"
else
  probe_fail "no /Applications alias in the volume — the drag-install instruction on the download page is a lie"
fi

if [ -f "$METAL" ]; then
  MSIZE="$(wc -c < "$METAL" | tr -d ' ')"
  probe_require_int "metallib bytes" "$MSIZE"
  if [ "$MSIZE" -ge 4096 ]; then
    probe_ok "shader payload ships inside the bundle ($MSIZE bytes) — MLX's own search finds it at rung 1"
  else
    probe_fail "shader payload inside the bundle is $MSIZE bytes — too small to be the compiled library"
  fi
else
  probe_fail "no Contents/MacOS/mlx.metallib in the bundle — this is the 09-27 release failure: MLX dies at" \
    "the first Metal allocation with 'Failed to load the default metallib'"
fi

if SIGOUT="$(codesign --verify --deep --strict --verbose=1 "$APP" 2>&1)"; then
  probe_ok "codesign --verify --deep --strict passes on the mounted bundle"
else
  probe_fail "the bundle fails codesign verification — Gatekeeper will refuse it and the release notes'" \
    "right-click workaround will not help: $SIGOUT"
fi

PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
WANT_VER="${OCOREAI_ARTIFACT_VERSION:-}"
if [ -z "$WANT_VER" ]; then
  probe_note "artefact reports version ${PLIST_VER:-<none>} — pass OCOREAI_ARTIFACT_VERSION to judge it"
elif [ "$PLIST_VER" = "$WANT_VER" ]; then
  probe_ok "the artefact reports the version it was built to be ($WANT_VER)"
else
  probe_fail "the artefact reports ${PLIST_VER:-<none>}, not $WANT_VER — a shipped DMG whose About box lies" \
    "is the same defect as a stale version in a doc, one notch worse because it installs"
fi

# ── §2 the artefact serves ────────────────────────────────────────────────────────────────────
probe_section "§2 the binary inside the volume serves"
export OCOREAI_BIN="$BIN"
probe_note "booting the artefact's own binary (nothing resident — no weights are fetched for this)"
probe_boot

probe_api GET /v1/models || true
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "GET /v1/models -> 200 from the mounted bundle (the handlers are wired in the artefact)"
else
  probe_fail "GET /v1/models -> ${PROBE_STATUS:-no response} — /health answered but the API surface did not"
fi

if grep -q "Failed to load the default metallib" "$PROBE_LOG"; then
  probe_fail "the artefact logged 'Failed to load the default metallib' despite carrying the payload"
else
  probe_ok "no metallib load failure in the artefact's log"
fi

# ── §3 the artefact stops ─────────────────────────────────────────────────────────────────────
probe_section "§3 a clean SIGTERM ends it"
kill -TERM "$PROBE_PID" 2>/dev/null || true
STOPPED=0
for _ in $(seq 1 120); do
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then STOPPED=1; break; fi
  sleep 0.5
done
if [ "$STOPPED" != "1" ]; then
  probe_fail "the artefact ignored SIGTERM for 60 s — a daemon a harness cannot stop is a daemon a harness" \
    "will SIGKILL, which skips the MLX cache clear its own shutdown promises"
  kill -9 "$PROBE_PID" 2>/dev/null || true
else
  if wait "$PROBE_PID" 2>/dev/null; then
    probe_ok "SIGTERM exits 0"
  else
    probe_fail "SIGTERM exited non-zero — the process reports failure on an orderly stop"
  fi
  if grep -q "shut down complete" "$PROBE_LOG"; then
    probe_ok "the log carries the completion line the smoke step asserts"
  else
    probe_fail "no 'shut down complete' line — it stopped, but not through the drain its own docs promise"
  fi
fi
PROBE_PID=""

if [ "${OCOREAI_PROBE_KEEP_LOGS:-0}" = "1" ]; then
  probe_note "artefact server log kept at $PROBE_LOG"
fi
probe_summary "$PROBE_NAME"
