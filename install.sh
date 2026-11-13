#!/bin/zsh
# Installs or updates WiFi Doctor the way other Mac apps install: only the app is left behind, in Applications.
# It downloads the code into a temporary folder, builds and installs the app with build.sh --install,
# then deletes the temporary folder, even if the build fails or is stopped. Run it again to update.
# Usage: curl -fsSL https://raw.githubusercontent.com/Westminster45/WiFiDoctor/main/install.sh | zsh
set -euo pipefail

# Everything runs inside main, so the whole script is read before anything starts (it arrives on stdin through a pipe).
main() {
  local repo="${WIFIDOCTOR_REPO:-https://github.com/Westminster45/WiFiDoctor.git}"
  xcode-select -p >/dev/null 2>&1 || { echo "Install the Xcode Command Line Tools first: xcode-select --install" >&2; exit 1; }

  TMP="$(mktemp -d -t wifidoctor)"
  trap 'rm -rf "$TMP"' EXIT
  trap 'rm -rf "$TMP"; exit 130' INT TERM HUP

  echo "Downloading WiFi Doctor into a temporary folder…"
  # A full clone, not a shallow one: build.sh counts commits for the build number.
  git clone --quiet "$repo" "$TMP/WiFiDoctor" </dev/null
  "$TMP/WiFiDoctor/build.sh" --install </dev/null
  echo "Deleting the temporary folder. Open WiFi Doctor from Applications."
}

main "$@"
