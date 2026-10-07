#!/bin/bash
# Assemble dist/Portree.app from a release build — no Xcode involved.
# Usage: scripts/make-app.sh <bin-path from `swift build -c release --show-bin-path`>
set -euo pipefail

BIN_PATH="${1:?usage: make-app.sh <release bin path>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Portree.app"
VERSION="0.2.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Portree" "$APP/Contents/MacOS/Portree"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Portree</string>
    <key>CFBundleIdentifier</key><string>com.kashfi.portree</string>
    <key>CFBundleName</key><string>Portree</string>
    <key>CFBundleDisplayName</key><string>Portree</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/assets/AppIcon.icns" ]; then
    cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "note: assets/AppIcon.icns missing — run 'make icon' first for a proper icon"
fi

codesign --force --sign - "$APP"
echo "Built $APP (ad-hoc signed)"
