#!/usr/bin/env bash
# install.sh — the terminal install path, the pattern every installable tree in the field runs
# (ollama's install/, opencode's install script): newest release DMG → read-only mount → copy →
# detach. Terminal downloads carry no com.apple.quarantine, so the browser path's right-click
# workaround is not this path's story; the signature is ad-hoc until notarisation (owner call) —
# the same trust as downloading from the Releases page, stated there too. Removal story:
# scripts/uninstall.sh. Target: $OCOREAI_INSTALL_DIR, default /Applications.
set -euo pipefail
REPO="uingei/ocoreai"
PREFIX="${OCOREAI_INSTALL_DIR:-/Applications}"
TMP="$(mktemp -d -t ocoreai-install-XXXXXX)"
MNT="$TMP/mnt"
cleanup() { hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

URL="$(curl -fsSL --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" \
      | python3 -c 'import json,sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if a["name"].endswith(".dmg"):
        print(a["browser_download_url"]); break
else:
    raise SystemExit("no .dmg asset on the latest release — nothing to install")')"
echo "downloading ${URL}"
curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "$TMP/ocoreai.dmg" "$URL"

mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$TMP/ocoreai.dmg" >/dev/null
if [ ! -x "$MNT/ocoreai.app/Contents/MacOS/ocoreai" ]; then
  echo "FAIL: the mounted volume carries no executable bundle — the artefact is broken, not this script" >&2
  exit 1
fi
if pgrep -x ocoreai >/dev/null 2>&1; then
  echo "ocoreai is running — quit it first, the copy would land under a live bundle" >&2
  exit 1
fi

mkdir -p "$PREFIX"
rm -rf "$PREFIX/ocoreai.app"
cp -R "$MNT/ocoreai.app" "$PREFIX/ocoreai.app"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
       "$PREFIX/ocoreai.app/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "installed ocoreai ${VER} at ${PREFIX}/ocoreai.app — launch from Applications or:"
echo "  open '${PREFIX}/ocoreai.app'"
