#!/bin/zsh
# Builds "WiFi Doctor.app" in .build/ and, with --install, copies it to /Applications and deletes .build/. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
# The version lives in Sources/WiFiDoctor/Version.swift; the build number counts commits, so every installed build differs.
VERSION="$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/WiFiDoctor/Version.swift)"
[[ -n "$VERSION" ]] || { echo "Couldn't read appVersion from Sources/WiFiDoctor/Version.swift" >&2; exit 1; }
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/WiFiDoctor"
APP=".build/WiFi Doctor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WiFiDoctor"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WiFi Doctor</string>
  <key>CFBundleDisplayName</key><string>WiFi Doctor</string>
  <key>CFBundleIdentifier</key><string>local.wifidoctor</string>
  <key>CFBundleExecutable</key><string>WiFiDoctor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>WiFi Doctor uses Location access only to read the name of the WiFi network you are on. macOS hides it otherwise.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>WiFi Doctor uses Location access only to read the name of the WiFi network you are on. macOS hides it otherwise.</string>
</dict></plist>
PLIST
# Hardened runtime needs the Location entitlement, or macOS refuses the request for the network name.
ENT=".build/WiFiDoctor.entitlements"
cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.personal-information.location</key><true/>
</dict></plist>
ENTITLEMENTS
# Ad hoc by default. To share the app, set SIGN_ID to a "Developer ID Application: …" identity, then notarise with xcrun notarytool.
SIGN_ID="${SIGN_ID:--}"
SIGN_ARGS=(--force --options runtime --entitlements "$ENT" --sign "$SIGN_ID")
if [[ "$SIGN_ID" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP"
echo "Built $PWD/$APP (version $VERSION, build $BUILD)"
# Also removes the copy installed under the app's earlier name, "Wi-Fi Doctor", then deletes .build/
# (the Swift build cache, which can run to hundreds of MB) once the app is in Applications.
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/WiFi Doctor.app" "/Applications/Wi-Fi Doctor.app" && cp -R "$APP" /Applications/ && echo "Installed to /Applications"
  rm -rf .build && echo "Removed build files"
fi
