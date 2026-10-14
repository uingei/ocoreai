#!/bin/bash
# bundle-licenses.sh — ship third-party license texts inside a .app bundle.
#
# Why: the product is distributed as .app/.dmg, and BSD-3 clause 2 /
# Apache-2.0 section 4 require the license text to travel *with* the
# distribution. A text that only lives in the git repo satisfies nobody.
#
# Usage: bash scripts/bundle-licenses.sh [path/to/ocoreai.app]   (default build/ocoreai.app)
# Called by scripts/build-app.sh; runnable standalone to verify packaging
# without paying for a release build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/ocoreai.app}"
RES="$APP/Contents/Resources"
[ -d "$RES" ] || { echo "❌ $RES missing — create the bundle first (scripts/build-app.sh)"; exit 1; }

# 1. Refresh texts from the resolved checkouts (byte-verifies Apple's BSD-3
#    text against the coreai-models clone when it exists, and fails the build
#    outright if any dependency has no text).
zsh scripts/collect-third-party-licenses.sh

# 2. Copy the whole notices folder into the bundle.
SRC="THIRD-PARTY-LICENSES"
DST="$RES/THIRD-PARTY-LICENSES"
rm -rf "$DST"
mkdir -p "$DST"
cp "$SRC"/*.txt "$SRC/NOTICES.md" "$SRC/manifest.json" "$DST/"

# 3. Verify what the GUI actually reads, from inside the bundle.
python3 - "$DST" <<'PY'
import json, os, sys
dst = sys.argv[1]
m = json.load(open(os.path.join(dst, "manifest.json"), encoding="utf-8"))
apple = m["apple"]["licenseFile"]
missing = [f for f in [apple, "NOTICES.md", "manifest.json"] if not os.path.isfile(os.path.join(dst, f))]
missing += [d["textFile"] for d in m["dependencies"]
            if d["textFile"] != "(not collected)" and not os.path.isfile(os.path.join(dst, d["textFile"]))]
if missing:
    for f in missing:
        print("FAIL bundled notices missing file: %s" % f)
    sys.exit(1)
if os.path.getsize(os.path.join(dst, apple)) < 500:
    print("FAIL %s looks truncated" % apple)
    sys.exit(1)
print("verified: %d deps + Apple %s + NOTICES.md inside the bundle" % (len(m["dependencies"]), apple))
PY

echo "✅ third-party notices bundled → $DST ($(ls "$DST" | wc -l | tr -d ' ') files)"
