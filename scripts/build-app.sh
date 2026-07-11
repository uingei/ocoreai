#!/bin/bash
set -euo pipefail
VERSION="0.1.0"
BUILD="1"
APP_NAME="ocoreai"

# 1. Clean release build
echo "🔨 Building release..."
swift build -c release --traits appStore

# 2. Create .app bundle
echo "📦 Creating $APP_NAME.app..."
APP_DIR="build/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. Copy binary
cp .build/release/ocoreai "$APP_DIR/Contents/MacOS/"

# 4. Generate Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>oCoreai</string>
    <key>CFBundleExecutable</key><string>ocoreai</string>
    <key>CFBundleIdentifier</key><string>com.ocoreai.ocoreai</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>ocoreai</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>NSCameraUsageDescription</key><string>ocoreai uses your camera for vision input and multimodal interaction.</string>
    <key>NSMicrophoneUsageDescription</key><string>ocoreai uses your microphone for voice input and real-time audio processing.</string>
    <key>NSMainStoryboardFile</key><string></string>
    <key>NSAppleEventsUsageDescription</key><string>ocoreai needs to access Apple Events for system integration features.</string>
</dict>
</plist>
PLEOF

# 5. Copy Privacy manifest
if [ -f "PrivacyInfo.xcprivacy" ]; then
    cp PrivacyInfo.xcprivacy "$APP_DIR/Contents/Resources/"
    echo "✅ PrivacyInfo.xcprivacy copied"
else
    echo "⚠️ PrivacyInfo.xcprivacy not found"
fi

# 6. Copy entitlements reference
if [ -f "ocoreai.entitlements" ]; then
    cp ocoreai.entitlements "$APP_DIR/Contents/Resources/"
    echo "✅ entitlements copied"
fi

echo "🎉 $APP_NAME.app ready at $APP_DIR"
ls -la "$APP_DIR/"
