# Changelog

## 0.1.0 - 2026-09-01

- Add an Ubuntu AppIndicator showing the percentage remaining in Claude's
  five-hour subscription window.
- Show all-model and model-specific weekly limits with local reset times.
- Read Claude Code's OAuth credential without modifying or logging it.
- Add stale/offline behavior, rate-limit-aware backoff, autostart management,
  private rotating logs, and single-instance locking.
- Add mocked coverage for usage parsing, credential safety, HTTP behavior,
  retry policy, SVG rendering, and desktop integration.
