# Changelog

## 0.2.1 - 2026-09-01

- Fix the macOS menu-bar app crash-looping with SIGSEGV on launch. The broad
  `kSecMatchLimitAll` Keychain sweep used to find the hash-suffixed
  `Claude Code-credentials-<hash>` item corrupts the process heap when built
  with `swiftc -O` on macOS 26; the crash surfaced in the next
  `SecItemCopyMatching`. The sweep now runs in a short-lived child process
  (`--list-credential-services`) that prints only service names and exits, so
  the damaged heap never outlives it.
- Narrow the macOS menu to the current five-hour session window. Weekly and
  per-model entries were removed; `--check` still prints every window.

## 0.2.0 - 2026-09-01

- Add a native macOS AppKit menu-bar implementation with a compact template
  icon, usage menus, stale/offline state, and manual refresh.
- Read Claude subscription OAuth from legacy and hash-suffixed macOS Keychain
  items without persisting a copy; cache it in memory to reduce prompts.
- Add a Swift build, mock-response check, per-user LaunchAgent installer, and
  macOS uninstaller.
- Make the root install and uninstall scripts dispatch by operating system.
- Add Ubuntu and macOS GitHub Actions validation.

## 0.1.0 - 2026-09-01

- Add an Ubuntu AppIndicator showing the percentage remaining in Claude's
  five-hour subscription window.
- Show all-model and model-specific weekly limits with local reset times.
- Read Claude Code's OAuth credential without modifying or logging it.
- Add stale/offline behavior, rate-limit-aware backoff, autostart management,
  private rotating logs, and single-instance locking.
- Add mocked coverage for usage parsing, credential safety, HTTP behavior,
  retry policy, SVG rendering, and desktop integration.
