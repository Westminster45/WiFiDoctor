# Contributing

Thank you for your interest in WiFi Doctor.

## Reporting a problem

Open an issue using the bug report template. Include your macOS version, the WiFi Doctor version number (after "Version" at the bottom of the window) and the sentence in bold that WiFi Doctor showed, without the text below it. Issues are public, so do not paste the saved report, IP addresses or network names.

## Suggesting a change

Open an issue using the feature request template before starting work on anything large, so it can be discussed first.

## Making a change

1. Fork the repository and create a branch.
2. Make your change. Keep it focused on one thing.
3. Build and run the built-in checks:

   ```bash
   ./build.sh
   ".build/WiFi Doctor.app/Contents/MacOS/WiFiDoctor" --selftest
   swift test
   ```

4. Open a pull request and fill in the template.

## Style

- Text shown in the app uses British English and plain language.
- Follow the existing code style. The app has no third-party dependencies, and new ones are unlikely to be accepted.

## Licence

WiFi Doctor is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). By contributing, you agree that your contribution is licensed under the same terms.
