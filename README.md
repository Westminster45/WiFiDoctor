# WiFi Doctor

A native Mac app (SwiftUI) that diagnoses public WiFi problems: router and internet reachability, DNS settings, login page (captive portal) detection, and iCloud Private Relay.

The main window says in one sentence what's wrong, offers the button that fixes it, and shows how far the connection gets (WiFi, Router, Internet, Websites). After a fix, or once you've opened a login page, it checks again by itself. The sidebar has a page for each check showing what it found, plus Connection Information and every fix. **Speed Test**, under Performance, measures download and upload speed, responsiveness, and how quickly the router and the internet respond, using the networkQuality tool built into macOS. It runs only when you ask, because it takes about 30 seconds and can use a few hundred megabytes. **Save Report…** at the bottom of the window (or File > Save Report…, ⌘S) saves the diagnosis as a text file.

## Install on a Mac

1. Install the Xcode Command Line Tools:

   ```bash
   xcode-select --install
   ```

2. Install [Homebrew](https://brew.sh) (paste the install command from that page into Terminal), then the GitHub CLI:

   ```bash
   brew install gh
   ```

3. Log in to GitHub (needed because this repo is private):

   ```bash
   gh auth login
   ```

4. Download the code, build the app and install it into Applications:

   ```bash
   gh repo clone Westminster45/WiFiDoctor ~/WiFiDoctor
   cd ~/WiFiDoctor
   ./build.sh --install
   ```

5. Open **WiFi Doctor** from Applications. Allow Location access if asked: macOS hides the WiFi network name without it.

To update later: `cd ~/WiFiDoctor && git pull && ./build.sh --install`

`--install` deletes the build files in `~/WiFiDoctor/.build` once the app is in Applications, so each update rebuilds from scratch. If you have run `./build.sh` without `--install`, or `swift test`, remove them with `rm -rf ~/WiFiDoctor/.build`.

Requires macOS 14 or later. No other dependencies.

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
| `build.sh` | Builds the app into `.build/`; `--install` copies it to Applications and deletes `.build/`. |

Command-line options on the app binary (`WiFi Doctor.app/Contents/MacOS/WiFiDoctor`): `--selftest` runs built-in checks, `--once` prints a text report, `--json` prints the diagnosis as JSON, `--version` prints the version.

The version number is set in `Sources/WiFiDoctor/Version.swift`. `build.sh` copies it into the app, and uses the number of commits as the build number.

## How it was made

WiFi Doctor was written with [Claude Code](https://claude.com/claude-code), Anthropic's AI coding tool. Claude wrote the code, tests and this README under the direction of the repository owner. Commits made with Claude carry a `Co-Authored-By: Claude` line.
