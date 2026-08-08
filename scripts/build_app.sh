#!/usr/bin/env bash
# Build ClaudeOMeter.app (a menu-bar agent, no Dock icon) from the SwiftPM executable.
set -euo pipefail

cd "$(dirname "$0")/.."

# Use $VERSION if set (e.g. from CI tag), otherwise fall back to a local timestamp.
APP_VERSION="${VERSION:-dev}"
APP_NAME="ClaudeOMeter"
BUNDLE_ID="net.celadora.claudeometer"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$BIN_PATH/$APP_NAME" "$MACOS/$APP_NAME"

# Copy the SwiftPM resource bundle (contains pricing.json) to Contents/Resources/.
# The SwiftPM-generated Bundle.module accessor looks for the bundle at Bundle.main.bundleURL
# (the .app root), which codesign rejects. We instead use Bundle.main.url(forResource:subdirectory:)
# in Persistence.loadPricing(), which searches Bundle.main.resourceURL = Contents/Resources/.
if [ -d "$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle" ]; then
  cp -R "$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle" "$RES/"
fi

# Also copy icon assets directly to Contents/Resources/ so SwiftUI's Image("name") can
# find them via Bundle.main without needing to look inside the SwiftPM sub-bundle.
for img in "claude-icon.png" "claude-icon@2x.png" "claude-code-icon.png" "claude-code-icon@2x.png" "AppIcon.icns"; do
  SRC="$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle/$img"
  [ -f "$SRC" ] && cp "$SRC" "$RES/$img"
done

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Claude-o-Meter</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Local cost tracker for Claude Code.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so notifications behave on a local machine.
# Sign the binary, then the .app wrapper. The resource bundle sits at the .app root
# (outside Contents/) so codesign does not seal it — no bundle is needed in the sequence.
codesign --force --sign - "$MACOS/$APP_NAME"
codesign --force --sign - "$APP"
echo "==> signature:"
# Deliberately not `|| true`: a broken seal should fail the build rather than ship
# silently. Same checks as before, only the result is no longer discarded.
codesign --verify --verbose "$APP"

echo "==> done: $APP"
echo "    Run:    open $APP"
echo "    Install: cp -R $APP /Applications/"
