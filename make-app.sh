#!/bin/bash
# Builds Proxlet.app (with proxlet-mcp inside) and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Proxlet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Proxlet .build/release/proxlet-mcp "$APP/Contents/MacOS/"

# App icon from icon.jpg → AppIcon.icns (all sizes).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift icon.jpg build/AppIcon.png
for size in 16 32 128 256 512; do
  sips -z $size $size build/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Version comes from Paths.appVersion (ProxletCore/Paths.swift); the build number is the commit count.
VERSION=$(sed -nE 's/.*appVersion = "([^"]+)".*/\1/p' Sources/ProxletCore/Paths.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Proxlet</string>
  <key>CFBundleDisplayName</key><string>Proxlet</string>
  <key>CFBundleIdentifier</key><string>com.git.proxlet</string>
  <key>CFBundleExecutable</key><string>Proxlet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$APP"
rm -rf /Applications/Proxlet.app
cp -R "$APP" /Applications/
echo "Installed /Applications/Proxlet.app"
echo "MCP: claude mcp add proxlet -- /Applications/Proxlet.app/Contents/MacOS/proxlet-mcp"
