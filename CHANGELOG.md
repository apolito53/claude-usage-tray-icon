# Changelog

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
