# WiFi Doctor

A native Mac app (SwiftUI) that diagnoses public WiFi problems: router and internet reachability, DNS settings, login page (captive portal) detection, and iCloud Private Relay.

The main window says what's wrong, offers the button that fixes it, and shows how far the connection gets (WiFi, Router, Internet, Websites). The sidebar has a page for each check and every fix, plus an on-demand **Speed Test**. **Save Report…** (⌘S) saves the diagnosis as a text file.

## Install on a Mac

1. Install the Xcode Command Line Tools:

   ```bash
   xcode-select --install
   ```

2. Build the app and install it into Applications:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Westminster45/WiFiDoctor/main/install.sh | zsh
   ```

   This builds the app in a temporary folder, copies it to Applications and deletes the temporary folder.

3. Open **WiFi Doctor** from Applications. Allow Location access if asked: macOS hides the WiFi network name without it.

To update later, run the same command again.

Requires macOS 14 or later. No other dependencies.

### Working on the code

To change the code, clone the repo into any folder you like, then run `./build.sh` there to build `.build/WiFi Doctor.app`, or `./build.sh --install` to install it.

## Sharing the app

`./build.sh` signs the app ad hoc, which only suits the Mac that built it. To give it to someone else, sign it with a Developer ID certificate and notarise it:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
ditto -c -k --keepParent ".build/WiFi Doctor.app" WiFiDoctor.zip
xcrun notarytool submit WiFiDoctor.zip --keychain-profile <profile> --wait
xcrun stapler staple ".build/WiFi Doctor.app"
```

`<profile>` is a notarisation profile saved once with `xcrun notarytool store-credentials`.

## What's here

| Path | What it is |
| --- | --- |
| `Sources/WiFiDoctor/` | The app: probes, verdict logic, fixes and the SwiftUI views. |
| `Tests/WiFiDoctorTests/` | Unit tests (`swift test`). |
| `Resources/AppIcon.icns` | App icon. |
| `tools/makeicon.swift` | Draws the icon as a 1024px PNG (`swift tools/makeicon.swift Resources/icon1024.png`). |
| `install.sh` | Installer. |
| `build.sh` | Build script. |

Command-line options on the app binary (`WiFi Doctor.app/Contents/MacOS/WiFiDoctor`): `--selftest` runs built-in checks, `--once` prints a text report, `--json` prints the diagnosis as JSON, `--version` prints the version.

## How it was made

WiFi Doctor was written with [Claude Code](https://claude.com/claude-code), Anthropic's AI coding tool. Claude wrote the code, tests and this README under the direction of the repository owner. Commits made with Claude carry a `Co-Authored-By: Claude` line.
