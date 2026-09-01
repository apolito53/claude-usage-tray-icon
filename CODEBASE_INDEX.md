# Codebase index

- `linux/claude_usage_tray.py`: OAuth usage client, parser, status icon,
  GTK/AppIndicator application, startup registration, diagnostics, and CLI.
- `macos/ClaudeUsageTray.swift`: native AppKit status item, macOS Keychain
  credential reader, usage client/parser, diagnostics, and CLI checks.
- `macos/build.sh`: native Swift compilation.
- `macos/install.sh` and `macos/uninstall.sh`: per-user binary and LaunchAgent
  lifecycle.
- `install.sh` and `uninstall.sh`: platform dispatch plus the Linux
  desktop/autostart lifecycle.
- `tests/test_linux.py`: Mocked parser, credential, HTTP, retry, icon, and
  desktop integration tests, plus macOS source-contract assertions.
- `tests/fixtures/usage_response.json`: shared offline usage response for both
  implementations.
- `.github/workflows/ci.yml`: Ubuntu tests and native macOS Swift compilation.
- `README.md`: Cross-platform behavior, security boundary, setup, and known
  live-testing limitations.
- `VERSION` and `CHANGELOG.md`: release metadata.
