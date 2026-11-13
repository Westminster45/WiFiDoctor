# WiFi Doctor

WiFi Doctor is a Mac app that works out why public WiFi isn’t working, for example in a café, hotel or on a train, and fixes it where it can.

It checks each step of the connection in turn: WiFi, router, internet and websites. It then tells you in one sentence what’s wrong and offers a button to fix it. It also detects login pages that haven’t appeared and checks your DNS settings and iCloud Private Relay, both of which can stop public WiFi working.

You can also run a speed test and save the results as a text file (⌘S).

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

Command-line options on the app binary (`WiFi Doctor.app/Contents/MacOS/WiFiDoctor`): `--selftest` runs built-in checks, `--once` prints a text report, `--json` prints the diagnosis as JSON, `--version` prints the version.

## How it was made

For transparency, WiFi Doctor was written with [Claude Code](https://claude.com/claude-code), Anthropic's AI coding tool. You can see this in the commits, which list Claude as co-author.
