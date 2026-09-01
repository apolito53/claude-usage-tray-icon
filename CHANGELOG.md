# Changelog

## 0.2.1 - 2026-09-01

- Show the time left in the current five-hour window next to the percentage in
  the macOS menu bar (for example `75% 2h14m`), with the precise reset time and
  a long-form countdown in the menu. The status item now sizes itself to its
  content and stays at its original width when no reset time is known.
- Recompute that countdown locally every 20 seconds. `resets_at` is absolute,
  so the displayed time stays current without extra polling, and a stale
  reading keeps counting down behind its offline badge.
- Fix the macOS menu-bar app crash-looping with SIGSEGV on launch. The broad
  `kSecMatchLimitAll` Keychain sweep used to find the hash-suffixed
  `Claude Code-credentials-<hash>` item corrupts the process heap when built
  with `swiftc -O` on macOS 26. The damage surfaced away from its cause: first
  as SIGSEGV in the next single-item Keychain read, and once that was moved
  away, as a malloc freelist trap inside CFNetwork on the first HTTP request.
  All Security-framework calls therefore now run in a short-lived child process
  (`--emit-credential`) that resolves the credential, writes the selected
  service name and access token to the parent over a pipe, and `_exit`s without
  running teardown on the damaged heap. Nothing is written to disk, and neither
  the service name nor the token is logged.
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
