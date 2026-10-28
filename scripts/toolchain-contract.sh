#!/usr/bin/env bash
# Toolchain contract — asserts the platform premise every local gate in this repo rests on.
#
# Why this exists (verified 2026-10-14, on this host, mid-session):
# An Xcode/CLT update landed at 06:45-06:46 local and silently changed three things
# that Makefile/AGENTS.md state as fact rather than check as fact:
#   1. `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` re-pointed 26.5 -> 27.0,
#      and SDK 27 ships `System/Library/Frameworks/CoreAI.framework`. `DEVELOPER_DIR`
#      alone therefore stopped selecting the macOS-26 shape: `canImport(CoreAI)` flipped
#      true on the route documented as "the 26-native, no-CoreAI path", so every
#      `#if canImport(CoreAI)` block started compiling into what we call the delivery
#      build. Same failure family as the `canImport(CoreAI)` tokenizer rule in AGENTS.md:
#      a capability compiled on/off by an axis nobody verified.
#   2. CLT swiftc went 6.3.3 -> 6.4 (captured from a swift-frontend crash log at
#      06:2x the same morning), and SwiftPM 6.4 compiles `.metal` sources natively,
#      so `mlx-swift_Cmlx` now needs a shader compiler during `swift build`.
#   3. That compiler is gone: `metal` is absent from CLT, and Xcode's `metal` answers
#      "cannot execute tool 'metal' due to missing Metal Toolchain; use:
#      xcodebuild -downloadComponent MetalToolchain".
# Net effect: `swift build` — the check AGENTS.md calls MANDATORY before any claim of
# completion — could not run at all, and nothing in the repo said *why* or *which*
# premise broke. Gates that infer their platform from a symlink rot silently.
#
# Contract (the shape the repo's docs and CI assume):
#   R1  the SDK in use contains NO CoreAI framework  (delivery target macOS 26;
#       CoreAI blocks are macOS 27 and must be compiled out; opt out with
#       OCOREAI_TARGET_SDK=macos27 for the deliberate macOS-27 route). HARD: this is
#       about the shape of what we ship, so every leg that builds must hold it.
#   R2  a Metal shader compiler is spawnable. ADVISORY by default: it only matters
#       when `.metal` sources actually have to compile, and a leg whose Cmlx artifacts
#       are already built (or whose SwiftPM predates native Metal support) builds fine
#       without it. Pass --require-metal when a rebuild is on the table. Pass
#       --probe-metal to judge R2 (and R3) by DOING — compile a trivial kernel with
#       every reachable `metal` — instead of trusting `metal --version`, which answers
#       differently depending on whether cryptexd has the asset mounted right now.
#   R3  the .metal rebuild route is walkable HERE — spawnable is not enough, the job
#       must also be able to WRITE its clang module cache. ADVISORY (same conditions as
#       R2), checked by the same `--probe-metal` compile: the probe writes into a temp
#       dir but the compiler's module cache is outside it, so an unwritable cache shows
#       up as metal=compile-failed with the EPERM in the log. Measured 10-14 on this
#       host: SwiftPM resolves that cache under the REAL
#       user home (`/Users/<user>/.cache/clang/ModuleCache/…`, via getpwuid — not
#       $HOME), so inside a sandbox whose writable roots exclude the home every
#       CompileMetalFile task dies with `unable to open output file
#       '/Users/<user>/.cache/clang/…pcm': Operation not permitted` while R2 still
#       answers metal=ok-cryptex. Same .metal file, three runs, one variable:
#         HOME=<tmp>      metal -c …           → ok  (arg_reduce.air produced)
#         -fmodules-cache-path=<tmp>/mc       → ok  (metal accepts the flag)
#         default cache, home excluded       → EPERM
#       So the compiler, the SDK and the cryptexd asset are fine; the blocker is the
#       cache location SwiftPM picks, and `-Xcc -fmodules-cache-path=…` does NOT reach
#       a metal task (SwiftPM does not forward cFlags to CompileMetalFile — observed
#       command line), which leaves only procedural fixes: build `.metal` unsandboxed
#       once, or keep a scratch whose app-variant Metal node stays warm.
# Exit: 0 = contract holds, 1 = violated (message names the remedy).
set -u

MODE="check"
REQUIRE_METAL=0
PROBE_METAL=0
for arg in "$@"; do
  case "$arg" in
    --require-metal) REQUIRE_METAL=1 ;;
    --probe-metal) PROBE_METAL=1 ;;
    check | report | print-sdk-root | print-metal-bin | print-delivery-env) MODE="$arg" ;;
    *)
      echo "usage: $0 [check|report|print-sdk-root|print-metal-bin|print-delivery-env] [--require-metal] [--probe-metal]" >&2
      exit 2
      ;;
  esac
done

DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [ -z "$DEV_DIR" ] || [ ! -d "$DEV_DIR" ]; then
  echo "❌ no usable DEVELOPER_DIR (set it or run xcode-select -s)"
  exit 1
fi

# SDK search dirs for a macOS toolchain: Xcode.app layout and CommandLineTools layout.
sdk_dirs() {
  for root in \
    "$DEV_DIR/Platforms/MacOSX.platform/Developer/SDKs" \
    "$DEV_DIR/SDKs"; do
    [ -d "$root" ] && ls -d "$root"/MacOSX*.sdk 2>/dev/null
  done
}

sdk_version() { basename "$1" .sdk | sed 's/^MacOSX//'; }
has_coreai() { [ -d "$1/System/Library/Frameworks/CoreAI.framework" ]; }

# The SDK whose shape we ship: newest MacOSX*.sdk without CoreAI. Never trust the
# `MacOSX.sdk` symlink — an update can (and did) repoint it under us.
delivery_sdk() {
  sdk_dirs \
    | grep -vE 'MacOSX(1[0-4]|1[0-4]\.[0-9])\.sdk$' \
    | while read -r s; do has_coreai "$s" || echo "$(sdk_version "$s") $s"; done \
    | sort -V \
    | tail -1 \
    | cut -d' ' -f2-
}

CURRENT_SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
CURRENT_VER="$(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
SWIFT_VER="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)"
PINNED_SDK="$(delivery_sdk)"
WANT="${OCOREAI_TARGET_SDK:-macos26}"

# Is the Metal Toolchain mobile asset installed? Parse `Status:`, never the exit code:
# `xcodebuild -showComponent MetalToolchain` exits 0 and prints "Status: uninstalled"
# when the component is absent, so an exit-code guard succeeds and the build dies much
# later, on the first CompileMetalFile, with "cannot execute tool 'metal'". This is
# upstream's own parse — mlx-swift-lm .github/workflows/pull_request.yml:221-229 (local
# clone at 4cc5504), where the same trap cost them a green-then-red pipeline.
metal_component_status() {
  xcodebuild -showComponent MetalToolchain 2>&1 \
    | awk -F': *' '/^Status:/ { print tolower($2); exit }'
}

# Verdict vocabulary:
#   ok                        this route spawns `metal` and it answers
#   ok-cryptex              the route's stub refused, but the asset is mounted and
#                           runnable on the cryptexd mount (PATH injection fixes it)
#   ok-probed               a kernel actually compiled (set later, strongest)
#   component-installed-*   asset installed, no spawner visible on this route, no
#                           compile requested — advisory only
#   component-<status>      authoritative status says it is not installed
#   absent                  nothing to spawn and no status to quote
metal_probe() {
  local bin out
  bin="$(xcrun -f metal 2>/dev/null || true)"
  [ -n "$bin" ] || bin="$(command -v metal 2>/dev/null || true)"

  if [ -n "$bin" ]; then
    out="$("$bin" --version 2>&1 || true)"
    case "$out" in
      *"missing Metal Toolchain"*) ;;  # stub present, asset not mounted on this route
      "") ;;                         # nothing runnable here
      *) echo "ok"; return 0 ;;
    esac
  fi

  # The asset may be mounted and runnable even where this route's stub refuses
  # (measured 10-14: `metal --version` from the cryptexd mount answers fine). Upstream's
  # `-downloadComponent` remedy would buy nothing in that state, so say which fix applies.
  if [ -n "$(cryptex_metal_bin)" ]; then echo "ok-cryptex"; return 0; fi

  case "$METAL_STATUS" in
    installed) echo "component-installed-unprobed"; return 1 ;;
    "") echo "absent"; return 1 ;;
    *) echo "component-$METAL_STATUS"; return 1 ;;
  esac
}

# The Metal Toolchain installs as a mobile asset mounted by cryptexd OUTSIDE
# DEVELOPER_DIR (verified 10-14): `<search-path>/Metal.xctoolchain/usr/bin/metal`
# runs fine (Apple metal version 32023.921) while the DEVELOPER_DIR stub refuses.
# The mount directory carries a session-specific suffix (`…v27.1.266.1.HjWWNl`
# today) — it changes across remounts/reboots, so discover it, never hardcode.
# SwiftPM spawns `metal` by PATH lookup ("unable to spawn process 'metal'"), so
# prepending this dir to PATH is what makes `.metal` compile; `make test-clt` does
# exactly this via `print-metal-bin`.
cryptex_metal_bin() {
  # Try every candidate; accept the first with a runnable `metal`. The old shape
  # asked xcodebuild first and only fell back to the glob when its answer was EMPTY —
  # but `xcodebuild -showComponent` can answer a search path that EXISTS and still has
  # no runnable metal (measured 10-14, Xcode route: cryptex mount present at
  # `/private/var/run/…MetalToolchain-v27.1.266.1.*/Metal.xctoolchain` while the route
  # reported metal_cryptex_bin=none). An unusable first answer must not veto the
  # second; that short-circuit is what made R2 say component-missing on a host where
  # `metal` compiled kernels fine one directory over.
  local sp
  for sp in \
    "$(xcodebuild -showComponent MetalToolchain 2>/dev/null \
       | awk -F': ' '/Toolchain Search Path/{print $2}' | head -1)" \
    $(ls -d /private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v*/Metal.xctoolchain 2>/dev/null); do
    [ -n "$sp" ] && [ -x "$sp/usr/bin/metal" ] && { echo "$sp/usr/bin"; return 0; }
  done
  return 1
}

# Every `metal` this route can reach, best candidate first.
metal_candidates() {
  local bin cb
  bin="$(xcrun -f metal 2>/dev/null || true)"
  [ -n "$bin" ] || bin="$(command -v metal 2>/dev/null || true)"
  [ -n "$bin" ] && [ -x "$bin" ] && echo "$bin"
  cb="$(cryptex_metal_bin)"
  [ -n "$cb" ] && [ -x "$cb/metal" ] && echo "$cb/metal"
}

# R2/R3 by execution, not inference (10-14). `metal --version` and the cryptexd
# listing both INFER availability, and both flip with the environment — measured on
# this host within one minute: `report` answered metal=ok-cryptex inside the agent
# sandbox (the cryptex mount is visible there) and metal=component-missing outside
# it, while llbuild compiled arg_reduce.metal successfully in that same unsandboxed
# run. The question R2 actually asks is "can a .metal be compiled here", so compile
# one: a trivial kernel through every reachable `metal` into a temp dir.
#
# This also settles R3, which the header documents and nothing implemented: the
# failure that kills a sandboxed .metal rebuild is the clang module cache resolving
# under the real home (`~/.cache/clang/…pcm`, via getpwuid — not $HOME), and the
# probe hits that same wall, so `probe=fail` with an unwritable cache is visible
# here instead of 400 s later inside `swift build`.
metal_compile_probe() {
  local bin="$1" tmp rc=0
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  tmp="$(mktemp -d 2>/dev/null)" || return 1
  printf '%s\n' \
    '#include <metal_stdlib>' \
    'using namespace metal;' \
    'kernel void ocoreai_toolchain_probe(device const float* in [[buffer(0)]],' \
    '    device float* out[[buffer(1)]], uint i[[thread_position_in_grid]]) {' \
    '  out[i] = in[i] * 2.0f;' \
    '}' > "$tmp/probe.metal"
  "$bin" -c "$tmp/probe.metal" -o "$tmp/probe.air" > "$tmp/probe.log" 2>&1 || rc=$?
  PROBE_LOG="$(cat "$tmp/probe.log" 2>/dev/null | head -3 | tr '\n' ' ')"
  rm -rf "$tmp"
  return $rc
}

# Only an Xcode-ish DEVELOPER_DIR can answer the component query (CLT has no
# xcodebuild); asking it anyway costs seconds and returns nothing.
METAL_STATUS=""
[ -x "$DEV_DIR/usr/bin/xcodebuild" ] && METAL_STATUS="$(metal_component_status)"
METAL="$(metal_probe)"
METAL_BIN="$(cryptex_metal_bin)"

# `--probe-metal`: replace the inferred verdict with a compiled one. Opt-in because
# a leg whose .metal artifacts are warm does not need a shader compiler at all.
PROBE="not-requested"
PROBED_BIN=""
PROBE_LOG=""
if [ "$PROBE_METAL" -eq 1 ]; then
  while IFS= read -r CAND; do
    [ -n "$CAND" ] || continue
    if metal_compile_probe "$CAND"; then
      PROBE=ok
      PROBED_BIN="$CAND"
      METAL="ok-probed"
      break
    else
      PROBE=fail
      [ -n "$PROBED_BIN" ] || PROBED_BIN="$CAND"
    fi
  done < <(metal_candidates)
  [ "$PROBE" = "not-requested" ] && PROBE=none-found
fi

# An executed failure outranks an optimistic inference: the stub could print a fine
# `--version` and still be unable to emit a kernel.
if [ "$PROBE" = fail ] && [ "$METAL" != "ok-probed" ]; then METAL=compile-failed; fi

# Advisory: R2 without --require-metal — a rebuild may not even be on the table.
metal_holds() {
  case "$METAL" in
    ok | ok-probed | ok-cryptex | component-installed-unprobed) return 0 ;;
    *) return 1 ;;
  esac
}
# Strict (--require-metal): proof that a kernel compiles, not a promise that a
# component exists. A route whose stub refuses and whose asset is merely mounted
# still has to show the compile, because that is the task llbuild will attempt.
metal_strong() {
  case "$METAL" in ok | ok-probed) return 0 ;; *) return 1 ;; esac
}

report() {
  echo "developer_dir=$DEV_DIR"
  echo "swift=$SWIFT_VER"
  echo "sdk_default=$CURRENT_SDK (version $CURRENT_VER)"
  echo "sdk_default_coreai=$( { has_coreai "$CURRENT_SDK" && echo yes; } || echo no)"
  echo "sdk_no_coreai=${PINNED_SDK:-none-found}"
  echo "metal=$METAL"
  echo "metal_component_status=${METAL_STATUS:-unknown}"
  echo "metal_cryptex_bin=${METAL_BIN:-none}"
  echo "metal_probe=$PROBE${PROBED_BIN:+ ($PROBED_BIN)}"
  [ "$PROBE" = fail ] && [ -n "$PROBE_LOG" ] && echo "metal_probe_log=$PROBE_LOG"
  return 0
}

if [ "$MODE" = "report" ]; then report; exit 0; fi
if [ "$MODE" = "print-sdk-root" ]; then
  [ -n "$PINNED_SDK" ] || { echo "❌ no MacOSX SDK without CoreAI under $DEV_DIR" >&2; exit 1; }
  echo "$PINNED_SDK"
  exit 0
fi
if [ "$MODE" = "print-metal-bin" ]; then
  # Contract consumer (Makefile): prepend this dir to PATH and `metal` spawns.
  if [ -n "$METAL_BIN" ] && [ "$METAL" != "ok" ]; then echo "$METAL_BIN"; exit 0; fi
  exit 1
fi

if [ "$MODE" = "print-delivery-env" ]; then
  # One home for the DELIVERY ROUTE, printed as shell to eval. What decides it is the artefact's
  # shape, not the host's newest toolchain: an SDK whose framework dir carries CoreAI builds the
  # macOS-27 form under the same `swift build -c release` name, and `make release` names the
  # CoreAI-free form as what ships. So the route is resolved here (the resolver that already owns
  # print-sdk-root/print-metal-bin) and consumed by `make release` and by scripts/build-app.sh —
  # the script whose output is the .app a stranger drags into Applications.
  CLT_ROOT=/Library/Developer/CommandLineTools
  DELIVERY_SDK=$(DEVELOPER_DIR="$CLT_ROOT" bash "$0" print-sdk-root 2>/dev/null) || DELIVERY_SDK=""
  if [ -z "$DELIVERY_SDK" ]; then
    echo "❌ no CoreAI-free MacOSX SDK under $CLT_ROOT — the delivery artefact's shape cannot be" \
         "built here; install the SDK the contract names (see 'make toolchain-check')" >&2
    exit 1
  fi
  DELIVERY_METAL_BIN=$(bash "$0" print-metal-bin 2>/dev/null) || DELIVERY_METAL_BIN=""
  CLT_FRAMEWORKS=$CLT_ROOT/Library/Developer/Frameworks
  CLT_USR_LIB=$CLT_ROOT/Library/Developer/usr/lib
  echo "export DEVELOPER_DIR=$CLT_ROOT"
  echo "export SDKROOT=$DELIVERY_SDK"
  [ -n "$DELIVERY_METAL_BIN" ] && echo "export PATH=$DELIVERY_METAL_BIN:\$PATH"
  echo "export OCOREAI_DELIVERY_FLAGS='-Xswiftc -F$CLT_FRAMEWORKS -Xlinker -F$CLT_FRAMEWORKS" \
       "-Xlinker -rpath -Xlinker $CLT_FRAMEWORKS -Xlinker -rpath -Xlinker $CLT_USR_LIB'"
  exit 0
fi

FAIL=0
if [ "$WANT" = "macos26" ]; then
  if has_coreai "${CURRENT_SDK:-/nonexistent}"; then
    echo "❌ R1 delivery shape: default SDK $CURRENT_VER ships CoreAI.framework ⇒"
    echo "   canImport(CoreAI) is TRUE, so the macOS-27-only blocks compile into the"
    echo "   build. Pin the SDK instead of trusting the MacOSX.sdk symlink:"
    echo "     SDKROOT=${PINNED_SDK:-<newest SDK without CoreAI>}"
    [ -n "$PINNED_SDK" ] || echo "   (no CoreAI-free SDK found under $DEV_DIR — this host"
    [ -n "$PINNED_SDK" ] || echo "    cannot produce the macOS-26 shape; CI macos-26 is the gate)"
    echo "   Or opt in deliberately for the macOS-27 route: OCOREAI_TARGET_SDK=macos27"
    FAIL=1
  fi
fi
if metal_strong; then
  # Proven: `ok` spawned and answered; `ok-probed` actually emitted a kernel.
  if [ "$METAL" = "ok-probed" ]; then
    echo "ℹ️  R2 shader compiler: compiled a probe kernel with ${PROBED_BIN:-metal}"
  fi
elif metal_holds; then
  # Reachable but not compile-probed on this route. Upstream stops here too (its CI
  # asserts `Status: installed` and lets SwiftPM compile .metal); `--require-metal`
  # asks for more because that flag means a rebuild is actually on the table.
  echo "ℹ️  R2 shader compiler: metal=$METAL — reachable, not compile-probed."
  if [ -n "$METAL_BIN" ]; then
    echo "   make \`metal\` spawnable: export PATH=\"$METAL_BIN:\$PATH\""
    echo "   (make test-clt does this automatically via print-metal-bin)"
  fi
  [ "$REQUIRE_METAL" -eq 1 ] && { echo "   --require-metal wants the compile, not the promise"; FAIL=1; }
else
  echo "⚠️  R2 shader compiler: metal=$METAL ⇒ mlx-swift_Cmlx (.metal sources) cannot"
  echo "   rebuild here; any target depending on mlx is unbuildable once its artifacts"
  echo "   go stale."
  if [ "$PROBE" = fail ]; then
    # R3, by execution: the compiler resolved and was handed a kernel it could not
    # emit. On this host that is the module-cache wall, not a missing component — the
    # .metal job writes its clang module cache under the REAL home (getpwuid, not
    # $HOME), so a run whose writable roots exclude the home dies with
    # `unable to open output file '~/.cache/clang/…pcm': Operation not permitted`
    # while every inference still answers metal=ok (measured 10-14: ok-cryptex inside
    # the agent sandbox, component-missing outside it, same minute).
    echo "   R3: \`metal -c\` was attempted and rejected on $(printf '%s' "${PROBED_BIN:-?}" | sed 's|.*/||'):"
    echo "     ${PROBE_LOG:-no output}"
    echo "   Remedy: run the leg that dirties .metal unsandboxed ONCE (its module cache"
    echo "   resolves under the real home, not \$HOME); the sandboxed route works again"
    echo "   while those artifacts stay warm. Do not revert code to 'fix' this."
  elif [ -n "$METAL_BIN" ]; then
    echo "   Remedy: prepend to PATH — the component IS installed, the stub just cannot"
    echo "   resolve it: export PATH=\"$METAL_BIN:\$PATH\""
  else
    # Authoritative: the component status says it is not there (or nothing can answer
    # for it). This is upstream's remedy for exactly this state.
    echo "   Remedy: xcodebuild -downloadComponent MetalToolchain"
    echo "   (component status = ${METAL_STATUS:-unanswerable from $DEV_DIR}; hosted macOS"
    echo "    images ship without it — mlx-swift-lm's CI installs it for the same reason)"
  fi
  # Prebuilt shader artifacts do NOT substitute for the compiler, and this is easy to
  # mistake for "we already have Metal" (cost a debugging loop on 10-14): a stale
  # mlx.metallib / default.metallib is a RUNTIME payload MLX loads by path, while
  # SwiftPM 6.4 emits CompileMetalFile tasks llbuild must run itself; and the .air
  # files a build has left behind cover only the slice that was compiled (observed:
  # 30 .air under Debug-iphoneos, none for the macOS target).
  # Discover, never hardcode: SwiftPM 6.4 moved the products dir (see Makefile's
  # metallib staging — the same class of rot).
  prebuilt="$( { find .build-clt -path '*/Products/*' -name 'mlx.metallib' 2>/dev/null
      ls -1 ~/Library/Developer/Xcode/DerivedData/ocoreai-*/Build/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib 2>/dev/null; } | head -2)"
  if [ -n "$prebuilt" ]; then
    echo "   (found prebuilt shader payloads — they do not satisfy the build-time task:"
    echo "$(printf '%s\n' "$prebuilt" | sed 's/^/     /')"
    echo "    and the per-file .air left in DerivedData covered only Debug-iphoneos,"
    echo "    not the macOS target — observed 10-14, a clean rebuild needs the compiler)"
  fi
  [ "$REQUIRE_METAL" -eq 1 ] && FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "✅ toolchain contract holds (swift=$SWIFT_VER sdk=$CURRENT_VER coreai=$( { has_coreai "${CURRENT_SDK:-/nonexistent}" && echo yes; } || echo no) metal=$METAL)"
  exit 0
fi
echo "--- toolchain facts ---"
report
exit 1
