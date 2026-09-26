#!/bin/bash
# Builds XRealDesk.app (release) into ./build. Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/XRealDesk.app
VERSION=1.0.0

swift build -c release --product XRealDesk
BIN=$(swift build -c release --product XRealDesk --show-bin-path)/XRealDesk

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XRealDesk"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.xrealdesk.app</string>
  <key>CFBundleName</key><string>XRealDesk</string>
  <key>CFBundleDisplayName</key><string>XRealDesk</string>
  <key>CFBundleExecutable</key><string>XRealDesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>XRealDesk shows your virtual screens inside your XREAL glasses.</string>
</dict>
</plist>
PLIST

IDENTITY="XRealDesk Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
  echo "Signed with '$IDENTITY'"
else
  codesign --force --deep --sign - "$APP"
  echo "Ad-hoc signed (run scripts/make-signing-cert.sh once so permissions survive rebuilds)"
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x XRealDesk 2>/dev/null && sleep 1 || true
  rm -rf /Applications/XRealDesk.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/XRealDesk.app"
fi
echo "Built $APP"
