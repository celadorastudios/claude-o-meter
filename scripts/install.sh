#!/usr/bin/env bash
# One-line installer for Claude-o-Meter.
# Usage: curl -fsSL https://raw.githubusercontent.com/celadorastudios/claude-o-meter/master/scripts/install.sh | bash
#
# Environment:
#   CLAUDEOMETER_INSECURE=1     install even if build provenance cannot be confirmed.
#                               Last resort for a GitHub outage; see the provenance
#                               section below for why this is not the default.
set -euo pipefail

REPO="celadorastudios/claude-o-meter"
APP_NAME="ClaudeOMeter"
INSTALL_DIR="$HOME/Applications"
MIN_MACOS=14

# Guard rail for every recursive delete in this script. A path is only removed if it is
# absolute, at least two levels deep, and free of "..". If $HOME or a temp path ever came
# back empty or malformed, this deletes nothing instead of something catastrophic.
safe_rm() {
  target="${1:-}"
  case "$target" in
    ''|'/')  return 0 ;;
    *..*)    return 0 ;;
    /*/*)    rm -rf "$target" ;;
    *)       return 0 ;;
  esac
}

# $HOME is used to build the install path, so refuse to continue if it is unusable.
case "${HOME:-}" in
  ''|'/') echo "error: \$HOME is not set to a usable directory" >&2; exit 1 ;;
esac

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
trap 'safe_rm "$TMP_DIR"' EXIT

curl -fL --proto '=https' --tlsv1.2 --progress-bar "$DOWNLOAD_URL" -o "$TMP_DIR/$APP_NAME.zip"

# The .app is ad-hoc signed, so its own signature says nothing about who built it.
# GitHub build provenance does: the release workflow records an attestation binding this
# exact file digest to the commit and workflow run that produced it.
#
# We ask api.github.com whether such an attestation exists for this digest under $REPO.
# That is not an offline Sigstore verification, but the trust anchor is TLS to GitHub,
# which is already what we trust to serve the download itself. Someone who swapped the
# release asset cannot mint a matching attestation without running the workflow in this
# repo. It needs only curl and shasum, both of which ship with macOS, so there is nothing
# extra for the user to install.
#
# Verification is required, not advisory. Every release that ships this installer also
# ships provenance, so there is no "old release" case to exempt, and a way to skip the
# check is worth more to an attacker than it is to us.
#
# Echoes exactly one of: attested | unattested | indeterminate
#
# The last two are kept apart deliberately. "unattested" is HTTP 404, GitHub's verified
# answer for a digest it has never attested, and is a statement about the file. Anything
# else with no usable answer (transport failure, 403 rate limit, 5xx, a body we cannot
# read) is a statement about the network, so it is retried and reported differently.
# Collapsing the two would accuse a user of holding a forged download during an outage.
check_provenance() {
  local digest="$1"
  local attempt response http payload

  for attempt in 1 2 3; do
    response=$(curl -sS --proto '=https' --tlsv1.2 --max-time 20 \
      -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: ClaudeOMeter-installer" \
      "https://api.github.com/repos/$REPO/attestations/sha256:$digest" 2>/dev/null || true)

    http="${response##*$'\n'}"
    payload="${response%$'\n'*}"

    case "$http" in
      200)
        if printf '%s' "$payload" | grep -q '"bundle"'; then echo attested; else echo unattested; fi
        return 0
        ;;
      404)
        echo unattested
        return 0
        ;;
    esac

    # Only an indeterminate answer is retried; a definitive one never changes.
    if [[ "$attempt" -lt 3 ]]; then
      sleep "$(( attempt * ${CLAUDEOMETER_RETRY_DELAY:-2} ))"
    fi
  done

  echo indeterminate
}

echo "==> Verifying build provenance..."
DIGEST=$(shasum -a 256 "$TMP_DIR/$APP_NAME.zip" | cut -d' ' -f1)
PROVENANCE=$(check_provenance "$DIGEST")

if [[ "$PROVENANCE" == "attested" ]]; then
  echo "    Verified: built by $REPO in GitHub Actions."
elif [[ "${CLAUDEOMETER_INSECURE:-0}" == "1" ]]; then
  echo "    WARNING: provenance could not be confirmed ($PROVENANCE)." >&2
  echo "             CLAUDEOMETER_INSECURE=1 is set, so installing anyway." >&2
elif [[ "$PROVENANCE" == "unattested" ]]; then
  echo "error: no build provenance found for this download." >&2
  echo "       GitHub holds no attestation for sha256:$DIGEST." >&2
  echo "       Either this file was not built by $REPO's release workflow," >&2
  echo "       or it was modified after it was built. Refusing to install." >&2
  exit 1
else
  # Fails closed on purpose. Anyone able to substitute the release asset is also able to
  # block api.github.com, so treating an unreachable API as a pass would hand the very
  # adversary this check exists to stop a one-host bypass.
  echo "error: could not reach GitHub to verify this download." >&2
  echo "       This does not mean the file is unsafe, only that it could not be checked." >&2
  echo "       Check your connection and run the installer again." >&2
  echo "       To install without verification, accepting the risk:" >&2
  echo "         CLAUDEOMETER_INSECURE=1 bash install.sh" >&2
  exit 1
fi

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

safe_rm "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_SRC" "$INSTALL_DIR/"

echo "==> Clearing Gatekeeper quarantine..."
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

echo "==> Launching $APP_NAME..."
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "    Claude-o-Meter $TAG installed to $INSTALL_DIR/$APP_NAME.app"
echo "    The menu-bar icon will appear within a few seconds."
