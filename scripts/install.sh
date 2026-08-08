#!/usr/bin/env bash
# One-line installer for Claude-o-Meter.
# Usage: curl -fsSL https://raw.githubusercontent.com/celadorastudios/claude-o-meter/master/scripts/install.sh | bash
set -euo pipefail

REPO="celadorastudios/claude-o-meter"
APP_NAME="ClaudeOMeter"
INSTALL_DIR="$HOME/Applications"
MIN_MACOS=14

# Require macOS 14+
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( OS_MAJOR < MIN_MACOS )); then
  echo "error: Claude-o-Meter requires macOS $MIN_MACOS or later (you have $(sw_vers -productVersion))" >&2
  exit 1
fi

# Resolve latest tag by following the /releases/latest redirect — no python3/jq needed.
echo "==> Fetching latest release..."
RESOLVED=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
TAG="${RESOLVED##*/tag/}"
if [[ -z "$TAG" || "$TAG" == "$RESOLVED" ]]; then
  echo "error: Could not determine latest release tag from: $RESOLVED" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$APP_NAME.zip"

echo "==> Downloading $APP_NAME $TAG..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --progress-bar "$DOWNLOAD_URL" -o "$TMP_DIR/$APP_NAME.zip"

echo "==> Extracting..."
unzip -q "$TMP_DIR/$APP_NAME.zip" -d "$TMP_DIR"

# Locate the .app — handles zips with or without a subdirectory wrapper.
APP_SRC=$(find "$TMP_DIR" -maxdepth 2 -name "$APP_NAME.app" -type d | head -1)
if [[ -z "$APP_SRC" ]]; then
  echo "error: $APP_NAME.app not found in downloaded archive" >&2
  exit 1
fi

echo "==> Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Quit any running instance before replacing the bundle.
if pgrep -x "$APP_NAME" &>/dev/null; then
  echo "==> Quitting running instance..."
  pkill -x "$APP_NAME" || true
  sleep 1
fi

rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_SRC" "$INSTALL_DIR/"

echo "==> Clearing Gatekeeper quarantine..."
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

echo "==> Launching $APP_NAME..."
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "    Claude-o-Meter $TAG installed to $INSTALL_DIR/$APP_NAME.app"
echo "    The menu-bar icon will appear within a few seconds."
