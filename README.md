# Claude Usage Tray

A tiny Linux tray indicator and macOS menu-bar app that keeps Claude
subscription usage visible without opening Claude Code's `/usage` screen.

The icon shows the percentage remaining in the current five-hour window.

The macOS menu is scoped to that five-hour session window only:

- current-session usage and local reset time;
- online, stale, or offline status;
- manual refresh, login-startup, logs, and exit controls.

The Linux menu additionally shows seven-day all-model usage and any Opus,
Sonnet, or overage-specific weekly windows returned by the account. On both
platforms `--check` still prints every window the endpoint returns.

On Linux, usage above 50% remaining is green, 21-50% is amber, and 20% or less
is red. macOS uses a native template image so the number follows the system's
menu-bar tint. If a refresh fails after a successful reading, the last value
stays visible with an offline badge instead of disappearing.

## How it works

Claude Code documents subscription percentages in its interactive `/usage`
screen and in the JSON supplied to custom status-line scripts, but it does not
currently expose a supported non-interactive `claude usage --json` command.
This app calls the same read-only endpoint currently used by Claude Code:

```text
GET https://api.anthropic.com/api/oauth/usage
```

The OAuth access token comes from the credential managed by Claude Code:

- Linux: `~/.claude/.credentials.json`, or
  `$CLAUDE_CONFIG_DIR/.credentials.json`.
- macOS: the `Claude Code-credentials` generic-password item in the login
  Keychain, including current `Claude Code-credentials-<hash>` variants, with a
  credential-file fallback for installations that have one.
- Either platform: `CLAUDE_CODE_OAUTH_TOKEN`, when explicitly present in the
  process environment.

The app:

- keeps the token in memory only;
- never logs it or an endpoint response body;
- never writes or refreshes Claude's credential;
- never sends a prompt or makes a model inference request;
- polls every five minutes by default;
- honors `Retry-After` and backs off for at least 10 minutes after HTTP 429.

On macOS every Keychain call is made by a short-lived child process
(`--emit-credential`) that prints the chosen service name and access token to
the parent over a pipe and exits. This is a workaround, not a preference: the
match-all Keychain sweep needed to find the hash-suffixed
`Claude Code-credentials-<hash>` item corrupts the heap of whichever process
runs it when built with `swiftc -O` on macOS 26, and the resulting crash lands
somewhere unrelated later. Confining it to a child that exits immediately keeps
the menu-bar process clean. Nothing is written to disk, and neither the service
name nor the token is ever logged.

The endpoint is an internal Claude Code dependency, not a documented public
Anthropic API. A future Claude Code release can rename or reshape it. The app
fails closed when the response no longer matches the expected schema.

Subscription windows are available only for eligible Claude.ai OAuth plans.
API-key, Bedrock, Vertex, and Foundry authentication do not expose this quota.
See Anthropic's [authentication documentation](https://code.claude.com/docs/en/team)
and [status-line field reference](https://code.claude.com/docs/en/statusline).

## Install

Clone once on either supported platform:

```bash
git clone git@github.com:apolito53/claude-usage-tray-icon.git
cd claude-usage-tray-icon
./install.sh
```

`install.sh` detects Linux or macOS, installs the native implementation, enables
startup, and launches it. Use `./install.sh --no-startup` to install without
login startup.

### Linux requirements

- Ubuntu or a compatible Linux desktop with GTK 3
- Python 3.8 or newer
- `python3-gi`
- AppIndicator3 or AyatanaAppIndicator3

On Ubuntu 20.04:

```bash
sudo apt install python3-gi gir1.2-appindicator3-0.1
```

On distributions packaging Ayatana AppIndicator instead:

```bash
sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
```

The Linux installer copies the launcher to `~/.local/bin/claude-usage-tray`
and registers a GNOME autostart entry.

### macOS requirements

- macOS with Apple's Command Line Tools or Xcode
- Swift compiler discoverable through `xcrun`

Install Command Line Tools if needed:

```bash
xcode-select --install
```

The macOS installer compiles the native AppKit source, validates it with a mock
usage response, installs it under
`~/Library/Application Support/ClaudeUsageTray`, and registers the per-user
LaunchAgent `com.apolito.claude-usage-tray`.

The first Keychain read can show a macOS approval dialog. Claude Code sometimes
rewrites its Keychain item during OAuth refresh, which can cause macOS to ask
again. The menu-bar app minimizes that friction by caching only the access token
in memory and re-reading Keychain only after launch or HTTP 401. Selecting
**Always Allow** can help, but Claude Code controls the item's ACL.

## One-shot checks

Linux:

```bash
./linux/claude_usage_tray.py --check
```

macOS, after installation:

```bash
"$HOME/Library/Application Support/ClaudeUsageTray/ClaudeUsageTray" --check
```

The macOS parser and binary can be tested without credentials or a network call:

```bash
./macos/build.sh /tmp/ClaudeUsageTray
/tmp/ClaudeUsageTray --mock-response tests/fixtures/usage_response.json
```

Override the five-minute refresh interval with a value of at least 60 seconds:

```bash
CLAUDE_USAGE_TRAY_REFRESH_SECONDS=900 claude-usage-tray
```

The installed macOS LaunchAgent intentionally uses the default interval and
does not persist OAuth or configuration environment variables in its plist.

## Diagnostics and privacy

Private rotating logs live at:

- Linux: `${XDG_STATE_HOME:-~/.local/state}/claude-usage-tray/usage-tray.log`
- macOS: `~/Library/Logs/ClaudeUsageTray/usage-tray.log`

Log directories are mode `0700` and logs are mode `0600`. Logs include only
window identifiers, percentages, and sanitized error summaries. OAuth tokens
and HTTP response bodies are deliberately excluded.

If a saved token expires, open Claude Code so it can refresh its own credential,
then select **Refresh now**. This app intentionally does not implement OAuth
refresh-token rotation.

## Testing

Linux and source-contract tests:

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh uninstall.sh macos/build.sh macos/install.sh macos/uninstall.sh
python3 -m py_compile linux/claude_usage_tray.py
```

The GitHub Actions workflow repeats those checks on Ubuntu and compiles the
AppKit executable on a native macOS runner, then runs its mock-response check.

The parser, credential boundary, HTTP behavior, rate-limit backoff, icon, and
desktop integration use mock responses. The original development machine uses
Vertex authentication rather than Claude.ai subscription OAuth, so a successful
live subscription response remains intentionally unverified. The
non-subscription failure path can still be tested without making a model call.

## Uninstall

```bash
./uninstall.sh
```

The script detects Linux or macOS. Pass `--purge-logs` to also remove private
diagnostic logs.
