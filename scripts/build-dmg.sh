#!/bin/bash
# build-dmg.sh — 开箱即用产物: ocoreai.app → ocoreai.dmg (可拖拽安装)
#
# 设计 (第一性): 用户拿到 .dmg → 双击 → 拖到 Applications → 双击图标。
# 零外部依赖: 只用 macOS 自带 hdiutil, 不需要 create-dmg / node。
#
# 用法:
#   bash scripts/build-dmg.sh            # release + appStore trait → dist/ocoreai.dmg
#   DIST="dist" bash scripts/build-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DIST="${DIST:-dist}"
VERSION="${OCOREAI_VERSION:-0.1.1}"
DST="$DIST/ocoreai-$VERSION.dmg"

export OCOREAI_VERSION="$VERSION"

# 1. .app (复用 build-app.sh: release build + metallib + icon + plist)
bash scripts/build-app.sh

APP="build/ocoreai.app"
[ -d "$APP" ] || { echo "❌ $APP missing"; exit 1; }

# 2. 版本对齐 (以 OCOREAI_VERSION 为准, 默认 0.1.0)
PLISTB=/usr/libexec/PlistBuddy
"$PLISTB" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
"$PLISTB" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# 3. 代码签名: CI 上开发者证书 → ad-hoc。两者都让 App 可本地运行。
IDENTITY="${OCOREAI_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --timestamp -s "$IDENTITY" "$APP"
  echo "✅ signed with: $IDENTITY"
else
  codesign --force --deep --options runtime -s - "$APP"
  echo "⚠️ ad-hoc signed (no OCOREAI_SIGN_IDENTITY set) — 本地可用, 分发需正式证书"
fi

# 4. DMG 卷: [ocoreai.app] [→ Applications 软链]
STAGING="$(mktemp -d)/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

VOLUME="ocoreai"
mkdir -p "$DIST"
rm -f "$DST"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ \
  -size 512m "$DST" >/dev/null

# 自验: 能挂载 + App 可执行位完整
MNT="$(mktemp -d)/mnt"
mkdir -p "$MNT"
hdiutil attach -readonly -mountpoint "$MNT" -nobrowse "$DST" >/dev/null
[ -x "$MNT/ocoreai.app/Contents/MacOS/ocoreai" ] || { hdiutil detach "$MNT" >/dev/null; echo "❌ DMG missing executable"; exit 1; }
hdiutil detach "$MNT" >/dev/null

# 清理临时目录
rm -rf "$(dirname "$MNT")"

echo "🎉 $DST"
ls -lh "$DST"
codesign -dv "$APP" 2>&1 | head -3
